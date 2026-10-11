import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations

/// A WindowSystem for arranging a Space other than the current one, passing through only geometry writes.
/// Hidden: the remaining windows of a Space no display shows, observed only through AX elements captured while that Space was visible (`auto-refit-hidden`).
/// Shown: a Space another display is showing, observed fresh (`auto-arrive-shown`).
/// Refuses focus, close, full screen, and minimize. There is no front window.
final class OtherSpaceWindowSystem: WindowSystem {
    enum Mode: Equatable {
        case hidden
        /// Shown on the display with this identifier.
        case shown(display: String)
    }

    /// AX time budget for one arrangement. Past it, neither observation nor writes happen.
    static let budget: TimeInterval = 2.0
    /// Limit per write, so a sleeping app does not hold the operation queue for long.
    static let writeTimeout: TimeInterval = 1.0

    let base: CoordinatorWindowSystem
    let control: OperationControl
    let space: UInt64
    let mode: Mode
    /// The windows to arrange. Nothing else is written.
    let windows: Set<WindowID>
    let deadline: Date
    private let generation: UInt64
    private let inputCount: UInt64
    /// The display's work area at acceptance. A change (resolution, arrangement, Dock) stops observation and writes.
    private let workArea: CGRect?

    init(base: CoordinatorWindowSystem, control: OperationControl, space: UInt64, mode: Mode, windows: Set<WindowID>, now: Date = Date()) {
        self.base = base
        self.control = control
        self.space = space
        self.mode = mode
        self.windows = windows
        deadline = now.addingTimeInterval(Self.budget)
        generation = control.cancellationGeneration
        inputCount = base.inputActivityCount
        workArea = base.spaceDisplay(space)?.workArea
    }

    /// The Space is not the current Space, is still hidden (or still shown on the same display), its display's work area is unchanged, and the budget remains.
    func stillValid() -> Bool {
        guard Date() < deadline, let active = base.currentSpaceID(), active != space, let display = base.spaceDisplay(space),
              display.workArea == workArea else { return false }
        switch mode {
        case .hidden: return !display.shown
        case .shown(let id): return display.shown && display.display == id
        }
    }

    private func onSpace(_ id: WindowID) -> Bool { base.spacesOf(id) == [space] }

    /// Check before each write: still valid, window membership, and pause, cancellation, and input unchanged since acceptance.
    /// A shown Space also needs no mouse button held (the user may be dragging there).
    /// The Space is checked again after the membership read, which can be slow.
    func mayWrite(_ id: WindowID) -> Bool {
        stillValid() && onSpace(id) && stillValid() && !control.paused && control.cancellationGeneration == generation
            && base.inputActivityCount == inputCount && base.inputObservationAvailable
            && (mode == .hidden || !base.mouseButtonDown)
    }

    func snapshot() -> Snapshot { snapshot(limitingTo: nil) }

    /// Returns an observation only when every window reads as a standard window of that Space.
    /// A single missing window makes it unobservable, so missing windows are never silently dropped from the layout.
    func snapshot(limitingTo ids: Set<WindowID>?) -> Snapshot {
        let wanted = ids.map { $0.intersection(windows) } ?? windows
        let unavailable = Snapshot(trusted: base.axTrusted, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
        guard stillValid() else { return unavailable }
        let snap = mode == .hidden
            ? base.snapshot(ofHiddenSpace: space, windows: wanted, deadline: deadline)
            : base.snapshot(ofShownSpace: space, windows: wanted, deadline: deadline)
        let complete = wanted.allSatisfy { id in
            snap.windows.contains { $0.id == id && $0.membership == .current && $0.kind == .standard }
        }
        guard snap.spaceObservationAvailable, snap.spaceID == space, snap.workArea == workArea, snap.unobservedApps.isEmpty, complete, stillValid() else { return unavailable }
        return snap
    }

    func membershipOf(_ id: WindowID) -> ObservedWindow.Membership? {
        guard let list = base.spacesOf(id) else { return nil }
        if list.isEmpty { return .unknown }
        if list.count > 1, list.contains(space) { return .allSpaces }
        return list.contains(space) ? .current : .other
    }

    var axTrusted: Bool { base.axTrusted }
    /// Reports that Space as current only while it stays valid; operation gates see Space changes through this.
    func currentSpaceID() -> UInt64? { stillValid() ? space : nil }
    var inputActivityCount: UInt64 { base.inputActivityCount }
    var mouseButtonDown: Bool { base.mouseButtonDown }

    func readFrame(_ id: WindowID) -> FrameRead {
        guard windows.contains(id) else { return .failed(Self.refusal) }
        return base.readFrame(inSpace: id, space: space, deadline: deadline)
    }

    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard windows.contains(id) else { return .rejected(Self.refusal) }
        let limit = min(deadline, Date().addingTimeInterval(min(timeout, Self.writeTimeout)))
        return base.writeFrame(inSpace: id, space: space, frame: frame, deadline: limit) { [self] in shouldContinue() && mayWrite(id) && shouldContinue() }
    }

    func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        writeFrame(id, frame: frame, timeout: timeout, shouldContinue: shouldContinue)
    }

    func focusedWindowID() -> WindowID? { nil }
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult {
        if let activated { DispatchQueue.main.async { activated(nil) } }
        return .rejected(Self.refusal)
    }
    func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected(Self.refusal) }
    func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected(Self.refusal) }
    func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected(Self.refusal) }
    func readWindowState(_ id: WindowID, _ attribute: WindowStateAttribute) -> Bool? { nil }

    static let refusal = L("Not done on a Space other than the current one.", "今の操作スペース以外では行いません。")
}
