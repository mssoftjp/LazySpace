import AppKit
import CoreGraphics
import Foundation

/// Observes user input. Counts only; never keeps key codes, characters, or coordinates.
/// Runs a listen-only CGEventTap on its own thread's run loop, independent of the UI thread and the CLI.
public final class InputMonitor {
    public enum Mode: String, Codable {
        case mouseAndKeyboard
        case mouseOnly
        case unavailable
    }

    private let lock = NSLock()
    private var _count: UInt64 = 0
    private var _mouseDown: UInt64 = 0
    /// The press count when the last drag ended, so a press after it can be told apart even if both happen between observations.
    private var _completedDragPresses: UInt64 = 0
    private var _drag: UInt64 = 0
    private var _key: UInt64 = 0
    private var _scroll: UInt64 = 0
    private var _leftMouseDown = false
    private var leftDragInProgress = false
    private var _completedMouseDrags: UInt64 = 0
    private var tap: CFMachPort?
    private var thread: Thread?
    /// Signaled when the tap thread leaves its run loop; stop waits for it.
    private var finished: DispatchSemaphore?
    private var runLoop: CFRunLoop?
    private var commandKeys: Set<CommandKey> = []
    private var _onFlags: ((CGEventFlags) -> Void)?
    private var _onLeftMouseUp: (() -> Void)?
    private var _mode: Mode = .unavailable
    public var mode: Mode { lock.lock(); defer { lock.unlock() }; return _mode }
    /// Serializes start and stop. Separate from `lock`, which the tap callback uses.
    private let lifecycle = NSLock()

    /// Passed to the tap callback. Holds the monitor weakly, so it never dangles if the monitor is freed first.
    private final class TapContext {
        weak var monitor: InputMonitor?
        init(_ monitor: InputMonitor) { self.monitor = monitor }
    }

    /// Modifier changes. Not counted as input; used to show the key list.
    public var onFlagsChanged: ((CGEventFlags) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFlags }
        set { lock.lock(); _onFlags = newValue; lock.unlock() }
    }

    /// The user released the left button. Called on the tap thread; never for synthetic input.
    public var onLeftMouseUp: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLeftMouseUp }
        set { lock.lock(); _onLeftMouseUp = newValue; lock.unlock() }
    }

    /// A shortcut registered as a command to this app. Pressing it does not count as user input.
    public struct CommandKey: Hashable {
        public let keyCode: Int64
        public let flags: UInt64
        static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

        /// From Carbon modifiers (cmdKey / shiftKey / optionKey / controlKey).
        public init(keyCode: UInt32, carbonModifiers: UInt32) {
            var f: UInt64 = 0
            if carbonModifiers & 0x0100 != 0 { f |= CGEventFlags.maskCommand.rawValue }
            if carbonModifiers & 0x0200 != 0 { f |= CGEventFlags.maskShift.rawValue }
            if carbonModifiers & 0x0800 != 0 { f |= CGEventFlags.maskAlternate.rawValue }
            if carbonModifiers & 0x1000 != 0 { f |= CGEventFlags.maskControl.rawValue }
            self.keyCode = Int64(keyCode)
            flags = f
        }

        /// From a keyDown seen by the tap. Incidental flags such as Caps Lock, fn, and the keypad are ignored.
        public init(event: CGEvent) {
            keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            flags = event.flags.rawValue & CommandKey.modifierMask
        }

        /// For comparison; drops Fn / NumericPad and anything else outside `modifierMask`.
        fileprivate init(keyCode: Int64, modifierFlags: UInt64) {
            self.keyCode = keyCode
            flags = modifierFlags & CommandKey.modifierMask
        }
    }

    public init() {}

    public var count: UInt64 { lock.lock(); defer { lock.unlock() }; return _count }
    public var leftMouseDown: Bool { lock.lock(); defer { lock.unlock() }; return _leftMouseDown }
    /// Lets a drag that started and ended between observations be picked up once afterward.
    public var completedMouseDrags: UInt64 { lock.lock(); defer { lock.unlock() }; return _completedMouseDrags }
    /// Mouse-down count when the last drag ended; less than the current count once anything was pressed after it.
    public var completedDragPresses: UInt64 { lock.lock(); defer { lock.unlock() }; return _completedDragPresses }
    public var breakdown: (mouseDown: UInt64, drag: UInt64, key: UInt64, scroll: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (_mouseDown, _drag, _key, _scroll)
    }

    /// Replaces the registered shortcuts (on every settings change and mode switch).
    public func setCommandKeys(_ keys: Set<CommandKey>) {
        lock.lock(); commandKeys = keys; lock.unlock()
    }

    /// Whether this is a registered command key. The synthetic tag cannot stop Carbon hotkey reentry, so check this before posting.
    /// `CommandKey` ignores Fn and NumericPad.
    public func matchesCommand(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let key = CommandKey(keyCode: keyCode, modifierFlags: flags.rawValue)
        lock.lock(); defer { lock.unlock() }
        return commandKeys.contains(key)
    }

    func record(_ type: CGEventType, event: CGEvent) {
        // Input this app synthesized (Space switches and moves) is not user input.
        if SpaceControl.isSynthetic(event.getIntegerValueField(.eventSourceUserData)) { return }
        if type == .flagsChanged {
            lock.lock()
            let callback = _onFlags
            lock.unlock()
            if let callback { DispatchQueue.main.async { callback(event.flags) } }
            return
        }
        lock.lock()
        if type == .keyDown, commandKeys.contains(CommandKey(event: event)) { lock.unlock(); return }
        let released = type == .leftMouseUp ? _onLeftMouseUp : nil
        _count += 1
        switch type {
        case .leftMouseDown:
            _leftMouseDown = true
            leftDragInProgress = false
            _mouseDown += 1
        case .rightMouseDown, .otherMouseDown: _mouseDown += 1
        case .leftMouseUp:
            _leftMouseDown = false
            if leftDragInProgress { _completedMouseDrags &+= 1; _completedDragPresses = _mouseDown }
            leftDragInProgress = false
        case .leftMouseDragged:
            leftDragInProgress = true
            _drag += 1
        case .rightMouseDragged, .otherMouseDragged: _drag += 1
        case .keyDown: _key += 1
        case .scrollWheel: _scroll += 1
        default: break
        }
        lock.unlock()
        released?()
    }

    /// Starts. If a tap including key input cannot be created, retries with the mouse only.
    public func start() -> Mode {
        lifecycle.lock(); defer { lifecycle.unlock() }
        if currentTap() != nil { return mode }
        let full: CGEventMask = mask([.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown, .flagsChanged, .scrollWheel])
        let mouse: CGEventMask = mask([.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel])
        // The callback gets the context, retained until the tap thread leaves its run loop.
        let info = Unmanaged.passRetained(TapContext(self)).toOpaque()
        let created: CFMachPort
        let started: Mode
        if let t = createTap(full, info: info) { created = t; started = .mouseAndKeyboard }
        else if let t = createTap(mouse, info: info) { created = t; started = .mouseOnly }
        else {
            Unmanaged<TapContext>.fromOpaque(info).release()
            lock.lock(); _mode = .unavailable; lock.unlock()
            return .unavailable
        }
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(nil, created, 0)
            let rl = CFRunLoopGetCurrent()
            if let self { self.lock.lock(); self.runLoop = rl; self.lock.unlock() }
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
            // The run loop has exited, so no more callbacks for this tap.
            Unmanaged<TapContext>.fromOpaque(info).release()
            done.signal()
        }
        t.name = "LazySpace.InputMonitor"
        lock.lock(); tap = created; thread = t; finished = done; _mode = started; lock.unlock()
        t.start()
        _ = ready.wait(timeout: .now() + 2)
        return started
    }

    /// Re-enables the tap if it stayed disabled (the disable notice never reached the callback). If that fails, stops and reports unobservable.
    /// Returns whether input is observable. Does nothing if no tap was created.
    @discardableResult
    public func reviveIfDisabled() -> Bool {
        guard let tap = currentTap() else { return mode != .unavailable }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { stop(); return false }
        noteObservationGap(leftButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left))
        return true
    }

    /// Input during the unobserved gap is unknown: count it as input, match the left button to its current state, and drop any drag in progress.
    func noteObservationGap(leftButtonDown: Bool) {
        lock.lock()
        _count += 1
        _leftMouseDown = leftButtonDown
        leftDragInProgress = false
        lock.unlock()
    }

    /// Stops: disables the tap, stops the run loop, and waits for the thread to exit.
    /// The callback holds the monitor only weakly through the context, so even if the wait times out it never touches a freed monitor.
    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        lock.lock()
        let oldTap = tap
        let oldLoop = runLoop
        let oldDone = finished
        let oldThread = thread
        tap = nil
        runLoop = nil
        finished = nil
        thread = nil
        _mode = .unavailable
        // A release while stopped is invisible, so do not leave the button marked as down.
        _leftMouseDown = false
        leftDragInProgress = false
        lock.unlock()
        if let oldTap {
            CGEvent.tapEnable(tap: oldTap, enable: false)
            CFMachPortInvalidate(oldTap)
        }
        if let oldLoop { CFRunLoopStop(oldLoop) }
        if let oldDone, Thread.current !== oldThread { _ = oldDone.wait(timeout: .now() + 2) }
    }

    deinit { stop() }

    private func currentTap() -> CFMachPort? {
        lock.lock(); defer { lock.unlock() }
        return tap
    }

    private func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    private func createTap(_ eventMask: CGEventMask, info: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, info in
                guard let info,
                      let monitor = Unmanaged<TapContext>.fromOpaque(info).takeUnretainedValue().monitor
                else { return Unmanaged.passUnretained(event) }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.currentTap() { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    monitor.record(type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: info)
    }
}
