import Foundation
import LayoutCore
import MacSupport
import Operations
import Settings
@testable import LazySpace

final class CoordinatorSystem: CoordinatorWindowSystem {
    let input = InputMonitor() // never started
    var spaceObservationAvailable = true
    var inputActivityCount: UInt64 = 0
    var mouseButtonDown: Bool { input.leftMouseDown }
    var trusted = true
    var axTrusted: Bool { trusted }
    var inputAvailable = true
    var inputObservationAvailable: Bool { inputAvailable }
    var stageManagerOn = false
    var displaysShareOneSpace = false
    var anyMouseButtonHeld = false
    /// Displays as (frame, work area); nil means one display covering `area`.
    var displays: [(frame: CGRect, workArea: CGRect)]?
    func displayFrames() -> [(frame: CGRect, workArea: CGRect)] { displays ?? [(area, area)] }
    func windowTitle(_ id: WindowID) -> String? { titles[id] }
    var titles: [WindowID: String] = [:]
    /// Writes time out without applying; used for the automatic integration retry limit.
    var timeOutWrites = false
    /// Writes report a timeout but apply late (a slow app).
    var lateWrites = false
    var snapshotCount = 0
    var snapshotScopes: [Set<WindowID>?] = []
    var existingSpaces: Set<UInt64>? = [7, 8]
    var spaceListReads = 0
    func existingSpaceIDs() -> Set<UInt64>? { spaceListReads += 1; return existingSpaces }
    var exitedPIDs: Set<Int32> = []
    func processExited(_ pid: Int32) -> Bool { exitedPIDs.contains(pid) }
    var space: UInt64? = 7
    var focused: WindowID? = WindowID(1)
    var frames: [WindowID: CGRect] = [
        WindowID(1): CGRect(x: 0, y: 0, width: 960, height: 1080),
        WindowID(2): CGRect(x: 960, y: 0, width: 960, height: 1080)
    ]
    var area = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    /// Work area of the display that holds each Space (default `area`), for setups with more than one display.
    var areaOfSpace: [UInt64: CGRect] = [:]
    func workArea(of space: UInt64?) -> CGRect { space.flatMap { areaOfSpace[$0] } ?? area }
    var writes = 0
    var written: [(WindowID, CGRect)] = []
    var fixed: [WindowID: CGSize] = [:]
    /// Largest size the app allows per axis (0 = no limit on that axis).
    var maximumSizes: [WindowID: CGSize] = [:]
    func sizeTheAppAllows(_ id: WindowID, _ requested: CGSize) -> CGSize {
        if let size = fixed[id] { return size }
        var size = requested
        if let m = minimums[id] {
            size.width = max(size.width, m.width)
            size.height = max(size.height, m.height)
        }
        if let m = maximumSizes[id] {
            if m.width > 0 { size.width = min(size.width, m.width) }
            if m.height > 0 { size.height = min(size.height, m.height) }
        }
        return size
    }
    var minimums: [WindowID: CGSize] = [:]
    var refusedWrites: Set<WindowID> = []
    var focusCalls = 0
    var closeCalls = 0
    var stateCalls = 0
    var windowState: Bool? = false
    var changesState = true
    var kind: ObservedWindow.Kind = .standard
    var membership: ObservedWindow.Membership = .current
    /// Per-window membership (windows on a Space shown on another display, for example).
    var membershipOf: [WindowID: ObservedWindow.Membership] = [:]
    var onSnapshot: (() -> Void)?
    /// Windows missing only from operation observations (scoped to the layout and the windows being added, so they also hold other windows),
    /// standing in for windows briefly missing from an app's AX list. A look at only these windows still sees them.
    var hiddenFromScopedSnapshots: Set<WindowID> = []
    var onSpaceRead: (() -> Void)?
    func snapshot() -> Snapshot {
        onSnapshot?()
        snapshotCount += 1
        var snap = Snapshot(trusted: trusted, spaceID: space, workArea: workArea(of: space),
                 windows: frames.filter { onSpace($0.key, space) }.map { ObservedWindow(id: $0.key, pid: pids[$0.key] ?? 1, app: apps[$0.key] ?? "test", frame: $0.value, membership: membershipOf[$0.key] ?? membership, kind: kindOf[$0.key] ?? kind, detail: "", title: titles[$0.key] ?? "") },
                 spaceObservationAvailable: spaceObservationAvailable)
        // Like the real observation, an app that does not answer leaves out its windows and is reported unobserved.
        let unanswering = Set(snap.windows.map(\.pid)).intersection(unansweringPIDs)
        snap.windows.removeAll { unanswering.contains($0.pid) }
        snap.unobservedApps = unanswering.sorted().map { "pid\($0)" }
        return snap
    }
    /// Unresponsive apps (pid -> seconds one read blocks). Bounded observations wait only until the deadline and mark that app unobservable.
    var blockingPIDs: [Int32: TimeInterval] = [:]
    /// Remaining time (s) passed to bounded observations.
    var boundedReadBudgets: [TimeInterval] = []
    func snapshot(limitingTo ids: Set<WindowID>, deadline: Date) -> Snapshot {
        boundedReadBudgets.append(deadline.timeIntervalSinceNow)
        var snap = snapshot(limitingTo: ids)
        let blocked = Set(ids.compactMap { id in pids[id].flatMap { blockingPIDs[$0] != nil ? $0 : nil } })
        guard !blocked.isEmpty else { return snap }
        // For a blocking app, wait until the deadline (the remaining time) and give up.
        let wait = min(blocked.compactMap { blockingPIDs[$0] }.max() ?? 0, max(0, deadline.timeIntervalSinceNow))
        Thread.sleep(forTimeInterval: wait)
        snap.windows.removeAll { blocked.contains($0.pid) }
        snap.unobservedApps += blocked.map { pid in apps.first { pids[$0.key] == pid }?.value ?? "pid\(pid)" }
        return snap
    }
    /// Apps (pid) that do not return a window list: observations leave out their windows and report the app unobserved
    /// (a scoped observation only asks the owners of its windows).
    var unansweringPIDs: Set<Int32> = []
    /// Scoped observations could not read the full window list: no windows, and the list is reported unavailable.
    var scopedListUnreadable = false
    func snapshot(limitingTo ids: Set<WindowID>?) -> Snapshot {
        snapshotScopes.append(ids)
        var snap = snapshot()
        if let ids {
            let hidden = ids.subtracting(hiddenFromScopedSnapshots).isEmpty ? [] : hiddenFromScopedSnapshots
            snap.windows.removeAll { !ids.contains($0.id) || hidden.contains($0.id) }
            let asked = Set(ids.compactMap { id in frames[id].map { _ in pids[id] ?? 1 } })
            snap.unobservedApps = unansweringPIDs.intersection(asked).sorted().map { "pid\($0)" }
        }
        if scopedListUnreadable { snap.windows = []; snap.windowListAvailable = false }
        return snap
    }
    func currentSpaceID() -> UInt64? {
        let observed = space
        onSpaceRead?()
        return observed
    }
    func currentWorkArea() -> CGRect { workArea(of: space) }
    var focusReads = 0
    func focusedWindowID() -> WindowID? { focusReads += 1; return focused }
    private let frameLock = NSLock()
    /// Runs right after a frame read (to simulate something happening during the read).
    var onFrameRead: ((WindowID) -> Void)?
    func readFrame(_ id: WindowID) -> FrameRead {
        frameLock.lock()
        let read = frames[id].map(FrameRead.frame) ?? .gone
        frameLock.unlock()
        onFrameRead?(id)
        return read
    }
    /// Runs right after a write takes effect (to simulate something while waiting on the app, such as the user switching Spaces).
    var onWrite: ((WindowID, CGRect) -> Void)?
    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        frameLock.lock()
        writes += 1
        written.append((id, frame))
        if timeOutWrites { frameLock.unlock(); return .timedOut }
        if lateWrites { frames[id] = frame; frameLock.unlock(); return .timedOut }
        if refusedWrites.contains(id) { frameLock.unlock(); return .rejected("test window refused resize") }
        var applied = frame
        applied.size = sizeTheAppAllows(id, frame.size)
        frames[id] = applied
        frameLock.unlock()
        onWrite?(id, applied)
        return .issued
    }
    func focus(_ id: WindowID, timeout: TimeInterval) -> WriteResult { focused = id; focusCalls += 1; return .issued }
    /// Direct-path raises. The activation gates are recorded, not run (call them later to check the decision).
    var raiseGuards: [() -> Bool] = []
    /// Window owner pid (default 1).
    var pids: [WindowID: Int32] = [:]
    /// Window app (bundle identifier, default "test") and per-window kind (default `kind`).
    var apps: [WindowID: String] = [:]
    var kindOf: [WindowID: ObservedWindow.Kind] = [:]
    /// The front app (census frontmostPID).
    var frontPID: Int32? = 1
    /// raise queues activation like a real Mac: checks the gate on the main thread, and if it passes, reports the owner's activation as requested and brings that app forward.
    var raiseActivatesOwner = false
    /// Runs right after activation takes effect (the app moving its display to another Space, for example).
    var onRaiseActivated: ((WindowID) -> Void)?
    /// raise reports the owner's activation as requested, but the front does not change.
    var raiseReportsWithoutEffect = false
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult {
        guard activateIf() else { if let activated { DispatchQueue.main.async { activated(nil) } }; return .interrupted }
        if raiseReportsWithoutEffect {
            raiseGuards.append(activateIf)
            let owner = pids[id] ?? 1
            DispatchQueue.main.async { activated?(activateIf() ? owner : nil) }
            return .issued
        }
        if raiseActivatesOwner {
            raiseGuards.append(activateIf)
            DispatchQueue.main.async {
                guard activateIf() else { activated?(nil); return }
                let owner = self.pids[id] ?? 1
                activated?(owner)
                self.frontPID = owner
                self.onRaiseActivated?(id)
            }
            return focus(id, timeout: timeout)
        }
        raiseGuards.append(activateIf)
        // As on a real Mac, `activated` is always called once. This replacement does not bring the app forward.
        if let activated { DispatchQueue.main.async { activated(nil) } }
        return focus(id, timeout: timeout)
    }
    func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }; frames[id] = nil; closeCalls += 1; return .issued }
    func readWindowState(_ id: WindowID, _ attribute: WindowStateAttribute) -> Bool? {
        if attribute == .minimized, minimizedWindows.contains(id) { return true }
        return windowState
    }
    func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        stateCalls += 1
        if changesState, let before = windowState { windowState = !before }
        return .issued
    }
    func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        stateCalls += 1
        if changesState { windowState = value }
        return .issued
    }
    /// Front window by CGWindowList order; nil means the same as the AX focused window.
    var frontWindow: WindowID?
    /// Windows whose CGWindowList frame differs from their AX frame.
    var censusBounds: [WindowID: CGRect] = [:]
    /// The census also lists windows of `shownSpaces`, which are on screen on another display, as CGWindowList does.
    var censusListsShownSpaces = false
    func census(_ space: UInt64?) -> Census {
        let visible = frames.filter { onSpace($0.key, space) || (censusListsShownSpaces && !hiddenFromCensus.contains($0.key) && spaceOf[$0.key].map(shownSpaces.contains) == true) }
        return Census(windows: Dictionary(uniqueKeysWithValues: visible.keys.map { ($0, pids[$0] ?? Int32(1)) }), frontmostPID: frontPID,
                      spaceID: space, bounds: visible.merging(censusBounds.filter { visible[$0.key] != nil }) { _, seen in seen }, frontWindow: frontWindow ?? focused)
    }

    // MARK: Hidden Space

    /// Per-window Space. Empty: every window is visible on every Space, as before.
    var spaceOf: [WindowID: UInt64] = [:]
    /// Whether redistributing hidden Spaces is supported.
    var hiddenSpaces = false
    /// Spaces shown on another display.
    var shownSpaces: Set<UInt64> = []
    /// Windows with no element retained from when they were visible.
    var unretained: Set<WindowID> = []
    var kinds: [WindowID: ObservedWindow.Kind] = [:]
    var hiddenWrites: [WindowID] = []
    /// Runs right before writing a window on a hidden Space.
    var onHiddenWrite: ((WindowID) -> Void)?
    /// Runs after writing size, before writing position.
    var onHiddenWriteBetweenSetters: ((WindowID) -> Void)?
    /// Some display's shown Space is unknown.
    var hiddenVisibilityUnknown = false

    private func onSpace(_ id: WindowID, _ space: UInt64?) -> Bool {
        if hiddenFromCensus.contains(id) { return false }
        guard let home = spaceOf[id] else { return true }
        return home == space
    }

    // MARK: Transient removal

    /// Briefly missing from the on-screen lists (census and AX observation) but still a window.
    var hiddenFromCensus: Set<WindowID> = []
    /// Fading out while closing (low alpha in the full window list).
    var vanishing: Set<WindowID> = []
    var minimizedWindows: Set<WindowID> = []
    /// The full window list is unavailable.
    var windowListUnavailable = false

    var minimizedReads = 0
    /// Apps reported hidden.
    var hiddenPIDs: Set<Int32> = []
    func appHidden(pid: Int32) -> Bool? { hiddenPIDs.contains(pid) }
    func readMinimized(_ id: WindowID, deadline: Date) -> Bool? {
        minimizedReads += 1
        return minimizedWindows.contains(id)
    }

    /// Per-window layer and bounds of the single-window list read; without a key, the window's frame on layer 0.
    var recordLayers: [WindowID: Int] = [:]
    var recordBounds: [WindowID: CGRect] = [:]
    var recordAlphas: [WindowID: Double] = [:]
    func windowRecord(_ id: WindowID) -> CGWindowRecord? {
        guard let bounds = recordBounds[id] ?? frames[id] ?? (recordLayers[id] != nil ? .zero : nil) else { return nil }
        return CGWindowRecord(id: id.raw, pid: pids[id] ?? 1, layer: recordLayers[id] ?? 0, bounds: bounds, alpha: recordAlphas[id] ?? 1, onScreen: true)
    }

    func windowRecords(_ ids: Set<WindowID>) -> [WindowID: CGWindowRecord]? {
        guard !windowListUnavailable else { return nil }
        var out: [WindowID: CGWindowRecord] = [:]
        for id in ids {
            guard let frame = frames[id] else { continue }
            out[id] = CGWindowRecord(id: id.raw, pid: pids[id] ?? 1, layer: 0, bounds: frame, alpha: vanishing.contains(id) ? 0 : 1, onScreen: !hiddenFromCensus.contains(id))
        }
        return out
    }

    /// Windows for which SkyLight still returns stale membership.
    var reportedSpaces: [WindowID: [UInt64]] = [:]

    /// Per window, memberships returned by successive queries; when exhausted, the normal answer.
    var spacesSequence: [WindowID: [[UInt64]]] = [:]

    // MARK: Dialog region

    /// Per-window dialog-region evidence. Without a key it comes from `kindOf`; a nil value is unreadable.
    var dialogEvidences: [WindowID: DialogEvidence?] = [:]
    func dialogEvidence(pid: Int32, window id: WindowID, deadline: Date) -> DialogEvidence? {
        guard frames[id] != nil, (pids[id] ?? 1) == pid else { return nil }
        if let given = dialogEvidences[id] { return given }
        let dialog = (kindOf[id] ?? kind) == .dialog
        return DialogEvidence(role: "AXWindow", subrole: dialog ? "AXDialog" : "AXStandardWindow", minimized: false, fullscreen: false,
                              fullscreenButton: dialog ? .absent : .enabled, zoomButton: dialog ? .absent : .enabled, sizeSettable: !dialog, title: titles[id] ?? "")
    }
    /// Position-only writes. Windows in `ignoresPositionWrites` do not move when written (the app puts them back).
    var positionWrites: [(WindowID, CGPoint)] = []
    var ignoresPositionWrites: Set<WindowID> = []
    /// Windows that refuse position writes.
    var rejectsPositionWrites: Set<WindowID> = []
    func writePosition(_ id: WindowID, origin: CGPoint, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        guard let frame = frames[id] else { return .gone }
        positionWrites.append((id, origin))
        if rejectsPositionWrites.contains(id) { return .rejected("refused") }
        if !ignoresPositionWrites.contains(id) { frames[id] = CGRect(origin: origin, size: frame.size) }
        return .issued
    }

    /// Runs on each membership query (to simulate a change while it is read).
    var onSpacesOf: ((WindowID) -> Void)?
    func spacesOf(_ id: WindowID) -> [UInt64]? {
        onSpacesOf?(id)
        guard hiddenSpaces else { return nil }
        if var sequence = spacesSequence[id], !sequence.isEmpty {
            let next = sequence.removeFirst()
            spacesSequence[id] = sequence
            return next
        }
        if let reported = reportedSpaces[id] { return reported }
        return spaceOf[id].map { [$0] } ?? []
    }

    /// Display identifier per Space ("D1" when absent).
    var displayOf: [UInt64: String] = [:]
    func spaceDisplay(_ space: UInt64) -> SpaceDisplay? {
        // Both come from the same SkyLight display list, so an unreadable Space list leaves the displays unknown too.
        guard hiddenSpaces, !hiddenVisibilityUnknown, existingSpaces != nil else { return nil }
        return SpaceDisplay(display: displayOf[space] ?? "D1", workArea: workArea(of: space), shown: space == self.space || shownSpaces.contains(space))
    }

    func snapshot(ofHiddenSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        let windows = ids.filter { spaceOf[$0] == space && !unretained.contains($0) }.compactMap { id in
            frames[id].map { ObservedWindow(id: id, pid: 1, app: "test", frame: $0, membership: .current, kind: kinds[id] ?? .standard, detail: "", title: "") }
        }
        return Snapshot(trusted: trusted, spaceID: space, workArea: workArea(of: space), windows: windows, spaceObservationAvailable: hiddenSpaces)
    }

    var shownSnapshots: [UInt64] = []
    /// Runs during a shown-Space observation (to simulate input or a display change).
    var onShownSnapshot: (() -> Void)?
    /// Runs after a shown-Space observation succeeded.
    var afterShownSnapshot: (() -> Void)?
    func snapshot(ofShownSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        shownSnapshots.append(space)
        onShownSnapshot?()
        guard hiddenSpaces, shownSpaces.contains(space), space != self.space else {
            return Snapshot(trusted: trusted, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
        }
        let windows = ids.filter { spaceOf[$0] == space }.compactMap { id in
            frames[id].map { ObservedWindow(id: id, pid: pids[id] ?? 1, app: apps[id] ?? "test", frame: $0, membership: .current, kind: kinds[id] ?? .standard, detail: "", title: "") }
        }
        defer { afterShownSnapshot?() }
        return Snapshot(trusted: trusted, spaceID: space, workArea: workArea(of: space), windows: windows, spaceObservationAvailable: true)
    }

    func readFrame(inSpace id: WindowID, space: UInt64, deadline: Date) -> FrameRead { readFrame(id) }

    /// Like a real Mac, requests size and position separately and checks `shouldContinue` before each.
    func writeFrame(inSpace id: WindowID, space: UInt64, frame: CGRect, deadline: Date, shouldContinue: @escaping () -> Bool) -> WriteResult {
        onHiddenWrite?(id)
        guard shouldContinue(), var applied = frames[id] else { return .rejected("stopped") }
        hiddenWrites.append(id)
        writes += 1
        written.append((id, frame))
        applied.size = sizeTheAppAllows(id, frame.size)
        frames[id] = applied
        onHiddenWriteBetweenSetters?(id)
        guard shouldContinue() else { return .rejected("stopped") }
        applied.origin = frame.origin
        frames[id] = applied
        return .issued
    }
}
