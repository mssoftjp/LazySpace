import CoreGraphics
import Foundation

/// Decides what the pass-through tap does for posted hotkeys (macOS "Switch to Desktop N" and "Move left/right a Space"; `SpaceControl.sendHotkey`).
/// Both the tap callback and the operations queue touch it, so it is lock-protected.
///
/// Keys WindowServer consumes as hotkeys never reach an annotated-session tap; keys it does not consume (pass-through) do.
/// - Tag (`eventSourceUserData`): bits 48-63 are `marker` (an attempt tag; `SpaceControl.isSynthetic` accepts it and InputMonitor does not count it as user input),
///   bits 16-47 the owner (process pid, all 32 bits), and the low 16 bits a process-wide attempt number (cycling 2...0xFFFF).
///   It never collides with stepping's older tag (`syntheticTag`, bits 48-63 zero).
/// - Owner: LazySpace and lzprobe (different pids) running together never swallow or count each other's attempts. The pid is not truncated,
///   so owners cannot collide. SpaceControls in one process share attempt numbers, so a tag is not reused until the counter wraps.
///   After a wrap (65534 attempts), an extremely late old event with the same number and key could be mistaken for evidence of the current attempt.
///   Swallowing depends only on the owner, so nothing leaks. Events seconds late after 65534 switches are not expected, but this is not a guarantee.
/// - Swallowing: every event with this owner's attempt tag, of any type, is swallowed, even after the attempt ends (for as long as the tap exists),
///   so late events never leak. Other events (user input, stepping's own `syntheticTag`, other owners' attempts) pass through.
/// - Evidence: only the main keyDown of the attempt in progress counts. Modifier flagsChanged appear even when registered, so they do not count. Ended attempts' events do not count.
/// - Damaged attempt: if the system disables the tap during an attempt, that attempt stays damaged (swallowing may have had a gap).
public final class PassThroughFilter {
    public struct Attempt: Hashable {
        public let tag: Int64
        public let mainKey: UInt16
        public init(tag: Int64, mainKey: UInt16) { self.tag = tag; self.mainKey = mainKey }
    }

    /// Attempt tag marker (bits 48-63): "LZ".
    public static let marker: Int64 = 0x4C5A
    /// Owner of this tap (process pid).
    public let owner: Int64
    private let lock = NSLock()
    private let now: () -> Date
    private var active: Attempt?
    private var mainKeyDown = false
    private var compromised = false
    private var lastActivity: Date?

    private static let counterLock = NSLock()
    private static var counter: Int64 = 1

    /// Process-wide attempt number (cycling 2...0xFFFF); SpaceControls in one process never overlap.
    public static func nextAttempt() -> Int64 {
        counterLock.lock(); defer { counterLock.unlock() }
        counter = counter >= 0xFFFF ? 2 : counter + 1
        return counter
    }

    public init(owner: Int64 = Int64(ProcessInfo.processInfo.processIdentifier), now: @escaping () -> Date = Date.init) {
        self.owner = owner & 0xFFFF_FFFF
        self.now = now
    }

    /// This owner's attempt tag (attempt numbers 2...0xFFFF).
    public func tag(attempt: Int64) -> Int64 {
        (Self.marker << 48) | (owner << 16) | (attempt & 0xFFFF)
    }

    /// Whether this is this owner's attempt tag.
    public func owns(_ userData: Int64) -> Bool {
        (userData >> 48) & 0xFFFF == Self.marker && (userData >> 16) & 0xFFFF_FFFF == owner && userData & 0xFFFF >= 2
    }

    /// Starts an attempt; evidence and damage from the previous one do not carry over.
    public func begin(_ attempt: Attempt) {
        lock.lock(); active = attempt; mainKeyDown = false; compromised = false; lock.unlock()
    }

    /// Ends an attempt. Its events are still swallowed but no longer count as evidence.
    public func retire(_ attempt: Attempt) {
        lock.lock(); if active == attempt { active = nil; mainKeyDown = false; compromised = false }; lock.unlock()
    }

    /// Called from the tap callback; true to swallow.
    public func intercept(type: CGEventType, userData: Int64, keyCode: Int64) -> Bool {
        guard owns(userData) else { return false }
        lock.lock(); defer { lock.unlock() }
        lastActivity = now()
        if let active, active.tag == userData, !compromised, type == .keyDown, keyCode == Int64(active.mainKey) { mainKeyDown = true }
        return true
    }

    /// The system disabled the tap (timeout or user input). An attempt in progress is damaged.
    public func noteTapDisabled() {
        lock.lock(); if active != nil { compromised = true }; lock.unlock()
    }

    /// The tier-0 attempt's events were posted.
    public func notePosted() {
        lock.lock(); lastActivity = now(); lock.unlock()
    }

    /// The main keyDown of the attempt in progress reached the tap (WindowServer did not consume it as a hotkey).
    public func mainKeyDownObserved(_ attempt: Attempt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == attempt && mainKeyDown
    }

    public func isCompromised(_ attempt: Attempt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == attempt && compromised
    }

    /// Last post or attempt-event arrival (for the wait before finishing).
    public var lastActivityAt: Date? { lock.lock(); defer { lock.unlock() }; return lastActivity }
}

public enum PassThroughTapState: Equatable { case idle, starting, ready, failed }

/// The pass-through tap. One per SpaceControl (`SpaceControl.passThroughTap`, works without `direct`), created on first use and kept for good.
public protocol PassThroughTap: AnyObject {
    var filter: PassThroughFilter { get }
    var state: PassThroughTapState { get }
    /// Starts creating it (only from `idle` or `failed`; safe to call repeatedly). `state` becomes `ready` when done.
    func start()
    /// Whether the tap is enabled (not disabled by WindowServer).
    var isEnabled: Bool { get }
}

/// An active annotated-session tap (`.defaultTap`). Creation, run loop registration, and enabling all happen on a dedicated thread
/// before `ready` is published (like InputMonitor, callbacks run on that thread's run loop). Never stopped afterward.
/// When the system disables it, it is re-enabled (to keep swallowing) and the attempt in progress is marked damaged.
public final class SystemPassThroughTap: PassThroughTap {
    public let filter = PassThroughFilter()
    private let lock = NSLock()
    private var current: PassThroughTapState = .idle
    private var port: CFMachPort?

    public init() {}

    public var state: PassThroughTapState { lock.lock(); defer { lock.unlock() }; return current }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == .ready, let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    private func set(_ state: PassThroughTapState, port newPort: CFMachPort? = nil) {
        lock.lock(); current = state; if let newPort { port = newPort }; lock.unlock()
    }

    private var currentPort: CFMachPort? { lock.lock(); defer { lock.unlock() }; return port }

    public func start() {
        lock.lock()
        guard current == .idle || current == .failed else { lock.unlock(); return }
        current = .starting
        lock.unlock()
        let thread = Thread { [self] in
            // The callback gets self. The tap is never stopped, so on success it is never released.
            let info = Unmanaged.passRetained(self).toOpaque()
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
            guard let created = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                                  eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<SystemPassThroughTap>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.filter.noteTapDisabled()
                    if let port = owner.currentPort { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let swallow = owner.filter.intercept(type: type, userData: event.getIntegerValueField(.eventSourceUserData),
                                                     keyCode: event.getIntegerValueField(.keyboardEventKeycode))
                return swallow ? nil : Unmanaged.passUnretained(event)
            }, userInfo: info) else {
                Unmanaged<SystemPassThroughTap>.fromOpaque(info).release()
                self.set(.failed)
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, created, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            self.set(.ready, port: created)
            CFRunLoopRun()
        }
        thread.name = "LazySpace.PassThroughTap"
        thread.start()
    }
}
