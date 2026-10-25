import CoreGraphics
import Foundation
import LayoutCore
import Operations

/// Stands in for the OS. Reproduces constraints, delays, and interruptions.
final class FakeSystem: WindowSystem {
    var snap: Snapshot
    var frames: [WindowID: CGRect] = [:]
    var minimums: [WindowID: CGSize] = [:]
    var maximums: [WindowID: CGSize] = [:]
    /// Height the window's content needs at a width (Finder's Get Info window grows taller when narrower).
    var contentHeights: [WindowID: (CGFloat) -> CGFloat] = [:]
    var fixed: [WindowID: CGSize] = [:]
    var gone: Set<WindowID> = []
    var unresponsiveApps: Set<String> = []
    var writes: [(WindowID, CGRect)] = []
    var onWrite: ((FakeSystem, Int) -> Void)?
    private let frameLock = NSLock()
    var onRead: ((FakeSystem, WindowID) -> Void)?
    var reads: [WindowID: Int] = [:]
    var suppliedFrames: [(WindowID, CGRect)] = []
    var inputActivityCount: UInt64 = 0
    var space: UInt64? = 7
    var focused: WindowID?
    var focusCalls: [WindowID] = []
    var delayedFocus = false
    var pendingActivations: [() -> Void] = []
    var beforeRaise: (() -> Void)?
    func focusedWindowID() -> WindowID? { onFocusRead?(self); return focused }
    func focus(_ id: WindowID, timeout: TimeInterval) -> WriteResult {
        raise(id, timeout: timeout, activateIf: { true }, activated: nil)
    }
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult {
        beforeRaise?()
        guard activateIf() else { return .rejected("interrupted") }
        if gone.contains(id) { return .gone }
        let activate = { [self] in
            guard activateIf() else { activated?(nil); return }
            focusCalls.append(id); focused = id; activated?(Int32(id.raw))
        }
        if delayedFocus { pendingActivations.append(activate) } else { activate() }
        return .issued
    }
    var closeCalls: [WindowID] = []
    var confirmsClose = true
    var onSnapshot: ((FakeSystem) -> Void)?
    var onFocusRead: ((FakeSystem) -> Void)?
    /// Only windows with a known membership take the light focus path; nil falls back to a full observation.
    var membershipOverride: [WindowID: ObservedWindow.Membership] = [:]
    /// Per window, memberships returned by successive queries. When exhausted, membershipOverride applies.
    var membershipQueue: [WindowID: [ObservedWindow.Membership?]] = [:]
    func membershipOf(_ id: WindowID) -> ObservedWindow.Membership? {
        if var queue = membershipQueue[id], !queue.isEmpty {
            let next = queue.removeFirst()
            membershipQueue[id] = queue
            return next
        }
        return membershipOverride[id]
    }
    func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        if gone.contains(id) { return .gone }
        closeCalls.append(id)
        if confirmsClose { gone.insert(id) }
        return .issued
    }

    init(windows: [ObservedWindow], trusted: Bool = true, area: CGRect = CGRect(x: 0, y: 30, width: 1920, height: 1050)) {
        snap = Snapshot(trusted: trusted, spaceID: 7, workArea: area, windows: windows, spaceObservationAvailable: true)
        for w in windows { frames[w.id] = w.frame }
    }

    /// Like a real Mac, the snapshot returns the current actual frames.
    func snapshot() -> Snapshot {
        onSnapshot?(self)
        var s = snap
        s.windows = s.windows.filter { !gone.contains($0.id) }.map { w in var w = w; w.frame = frames[w.id] ?? w.frame; return w }
        return s
    }
    func currentSpaceID() -> UInt64? { space }

    func readFrame(_ id: WindowID) -> FrameRead {
        frameLock.lock()
        reads[id, default: 0] += 1
        onRead?(self, id)
        if gone.contains(id) { frameLock.unlock(); return .gone }
        let frame = frames[id]
        frameLock.unlock()
        return frame.map { .frame($0) } ?? .gone
    }

    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        frameLock.lock()
        if gone.contains(id) { frameLock.unlock(); return .gone }
        let app = snap.windows.first { $0.id == id }!.app
        if unresponsiveApps.contains(app) { frameLock.unlock(); return .timedOut }
        var f = frame
        if let m = minimums[id] { f.size.width = max(f.width, m.width); f.size.height = max(f.height, m.height) }
        if let m = maximums[id] { f.size.width = min(f.width, m.width); f.size.height = min(f.height, m.height) }
        if let content = contentHeights[id] { f.size.height = content(f.width) }
        if let fx = fixed[id] { f.size = fx }
        frames[id] = f
        writes.append((id, frame))
        let count = writes.count
        frameLock.unlock()
        onWrite?(self, count)
        return .issued
    }

    /// Runs in the middle of a write (after reading auxiliary attributes, before setting size and position).
    var betweenSetters: ((FakeSystem, WindowID) -> Void)?
    func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        betweenSetters?(self, id)
        suppliedFrames.append((id, currentFrame))
        return writeFrame(id, frame: frame, timeout: timeout, shouldContinue: shouldContinue)
    }
}

func window(_ id: UInt32, app: String = "app.\(UUID().uuidString.prefix(4))", x: CGFloat = 0, membership: ObservedWindow.Membership = .current, kind: ObservedWindow.Kind = .standard) -> ObservedWindow {
    ObservedWindow(id: WindowID(id), pid: Int32(id), app: app, frame: CGRect(x: x, y: 100, width: 500, height: 400), membership: membership, kind: kind, detail: "")
}
