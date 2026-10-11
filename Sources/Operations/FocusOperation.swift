import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// Focus move. Writes no geometry; sends focus / raise once and confirms.
public final class FocusOperation {
    public let id = UUID().uuidString
    private let system: WindowSystem
    private let control: OperationControl
    private let authorization: OperationAuthorization
    private let limits: OperationLimits
    private let target: WindowID
    /// When the key was pressed. Without it, the time from the operation start to the raise is recorded.
    private let pressedAt: Date?
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    /// When the destination is a dialog-region member: its owner's pid and a recheck run right before focusing (identity, membership, process).
    /// Accepted as the destination even by observations that select only standard windows.
    public struct RegionDestination {
        public var pid: Int32
        public var check: () -> Bool
        public init(pid: Int32, check: @escaping () -> Bool) { self.pid = pid; self.check = check }
    }
    private let regionDestination: RegionDestination?

    public init(system: WindowSystem, control: OperationControl, limits: OperationLimits = OperationLimits(), target: WindowID,
                pressedAt: Date? = nil, authorization: OperationAuthorization? = nil, regionDestination: RegionDestination? = nil,
                now: @escaping () -> Date = Date.init, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.system = system
        self.control = control
        self.authorization = authorization ?? OperationAuthorization(system: system, control: control)
        self.limits = limits
        self.target = target
        self.pressedAt = pressedAt
        self.regionDestination = regionDestination
        self.now = now
        self.sleep = sleep
    }

    public func run() -> OperationResult {
        let lifetime = OperationLifetime()
        defer { lifetime.finish() }
        let mayFocus = { [self] in
            lifetime.isActive && system.axTrusted
                && authorization.interruptionReason(system: system, control: control) == nil
                && system.currentSpaceID() == authorization.spaceID
                && (system.membershipOf(target).map { $0 == .current || $0 == .allSpaces } ?? true)
        }
        let startedAt = now()
        let clock = ContinuousClock()
        let t0 = clock.now
        func elapsedMs() -> Double { (clock.now - t0).milliseconds }
        if authorization.expectedWindow == nil, let member = system.membershipOf(target) {
            return runLight(member: member, startedAt: startedAt, elapsedMs: elapsedMs, mayFocus: mayFocus)
        }
        let observeStart = clock.now
        let snapshot = system.snapshot(limitingTo: authorization.expectedWindow.map { [$0.id, target] })
        var inspection = TargetSelection.inspect(snapshot, now: startedAt)
        // A dialog in the region is the destination regardless of how observation classified it, but only with the same owner, on the current Space, and passing the recheck.
        let window: ObservedWindow?
        if let destination = regionDestination {
            window = snapshot.windows.first { $0.id == target && $0.pid == destination.pid && $0.membership == .current }.flatMap { destination.check() ? $0 : nil }
        } else {
            window = inspection.targets.first { $0.id == target }
        }
        inspection.targets = window.map { [$0] } ?? []
        var builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: "focus")
        builder.timing.observeMs = (clock.now - observeStart).milliseconds
        guard snapshot.trusted else {
            return builder.finish(outcome: .notPossible, stopReason: .permissionLost, message: Self.noAccessMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        if let reason = authorization.stopReason(system: system, control: control, snapshot: snapshot) {
            return builder.finish(outcome: .notPossible, stopReason: reason, message: Self.changedAfterRequestMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        guard let window else {
            return builder.finish(outcome: .notPossible, stopReason: .targetsChanged, message: Self.notStandardWindowMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        var report = builder.report(for: window.id)
        report.planned = window.frame
        noteKeyToRaise(&builder, elapsedMs: elapsedMs)
        let writeStart = clock.now
        let result = system.raise(window.id, timeout: limits.perAppTimeout, activateIf: mayRaise(mayFocus))
        builder.timing.writeMs = (clock.now - writeStart).milliseconds
        builder.issued = 1
        report.issued = 1
        switch result {
        case .issued:
            let settleStart = clock.now
            let moved = waitForFocus(on: window.id, mayFocus: mayFocus)
            builder.timing.settleMs = (clock.now - settleStart).milliseconds
            report.after = window.frame
            report.status = moved ? .verified : .mismatch
            if !moved { report.note = Self.focusNotReceivedNote }
        case .gone: report.status = .gone; report.note = L("The window was closed", "閉じられた")
        case .rejected(let why): report.status = .mismatch; report.note = L("macOS rejected the request: \(why)", "OSが拒否: \(why)")
        case .timedOut: report.status = .mismatch; report.note = L("The app didn't respond in time", "アプリが期限内に応答しなかった")
        }
        builder.set(report)
        builder.verified = true
        let ok = report.status == .verified
        let failure = result == .issued
            ? Self.focusNotReceivedNote
            : L("Couldn't move focus: \(report.note ?? "")", "フォーカスを移せませんでした: \(report.note ?? "")")
        return builder.finish(outcome: ok ? .complete : .partial, stopReason: ok ? nil : (result == .timedOut ? .appUnresponsive : nil),
                              message: ok ? L("Focused \(window.app).", "\(window.app)にフォーカスを移しました。") : failure,
                              finishedAt: now(), wallMs: elapsedMs())
    }

    /// Checks membership only, raises, and confirms the focus moved within a short deadline.
    private func runLight(member: ObservedWindow.Membership, startedAt: Date, elapsedMs: () -> Double, mayFocus: @escaping () -> Bool) -> OperationResult {
        let space = system.currentSpaceID()
        let snapshot = Snapshot(trusted: system.axTrusted, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: space != nil)
        var builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: Inspection(snapshot: snapshot, targets: [], excluded: [], takenAt: startedAt), limits: limits, kind: "focus")
        guard system.axTrusted else {
            return builder.finish(outcome: .notPossible, stopReason: .permissionLost, message: Self.noAccessMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        if let reason = authorization.stopReason(system: system, control: control, snapshot: snapshot) {
            return builder.finish(outcome: .notPossible, stopReason: reason, message: Self.changedAfterRequestMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        guard member == .current || member == .allSpaces else {
            return builder.finish(outcome: .notPossible, stopReason: .targetsChanged, message: Self.notStandardWindowMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        // A dialog in the region must be on the current Space only and pass the recheck.
        if let regionDestination, member != .current || !regionDestination.check() {
            return builder.finish(outcome: .notPossible, stopReason: .targetsChanged, message: Self.notStandardWindowMessage, finishedAt: now(), wallMs: elapsedMs())
        }
        builder.timing.observeMs = elapsedMs()
        noteKeyToRaise(&builder, elapsedMs: elapsedMs)
        let writeStart = now()
        let result = system.raise(target, timeout: limits.perAppTimeout, activateIf: mayRaise(mayFocus))
        builder.issued = result == .issued ? 1 : 0
        builder.timing.writeMs = now().timeIntervalSince(writeStart) * 1000
        guard result == .issued else {
            return builder.finish(outcome: .partial, stopReason: result == .timedOut ? .appUnresponsive : nil,
                                  message: L("Couldn't move focus.", "フォーカスを移せませんでした。"), finishedAt: now(), wallMs: elapsedMs())
        }
        // App switching is asynchronous, so an accepted request alone is not completion.
        let settleStart = now()
        let moved = waitForFocus(on: target, mayFocus: mayFocus)
        builder.timing.settleMs = now().timeIntervalSince(settleStart) * 1000
        builder.verified = true
        return builder.finish(outcome: moved ? .complete : .partial, stopReason: nil,
                              message: moved ? L("Focus moved.", "フォーカスを移しました。") : Self.focusNotReceivedNote,
                              finishedAt: now(), wallMs: elapsedMs())
    }

    /// Check right before raising. For a dialog in the region, identity, membership, and process are rechecked here too (before resolving the element or switching apps).
    /// Input, pause, or the Space can change during that read, so the light check runs again after it.
    private func mayRaise(_ mayFocus: @escaping () -> Bool) -> () -> Bool {
        guard let regionDestination else { return mayFocus }
        return { mayFocus() && regionDestination.check() && mayFocus() }
    }

    private static var noAccessMessage: String {
        L("Can't move focus without the \(AccessPane.name()) permission.", "「\(AccessPane.name())」の許可がないためフォーカスを移せません。")
    }
    private static var changedAfterRequestMessage: String {
        L("Focus was not moved because pause, input, or the Space changed after the request.",
          "受付後に一時停止・入力・操作スペースの状態が変わったためフォーカスを移しません。")
    }
    private static var notStandardWindowMessage: String {
        L("The window isn't a standard window in the current Space.", "対象は現在の操作スペースの通常のウインドウではありません。")
    }
    private static var focusNotReceivedNote: String {
        L("The window did not receive focus.", "ウインドウへフォーカスを移せませんでした。")
    }

    /// Returns as soon as focus moves. With a zero wait (tests), reads once.
    private func waitForFocus(on target: WindowID, mayFocus: () -> Bool) -> Bool {
        guard mayFocus() else { return false }
        if system.focusedWindowID() == target { return true }
        guard limits.settleDelay > 0 else { return false }
        let deadline = now().addingTimeInterval(0.5)
        while now() < deadline {
            sleep(0.02)
            guard mayFocus() else { return false }
            if system.focusedWindowID() == target { return true }
        }
        return false
    }

    private func noteKeyToRaise(_ builder: inout ResultBuilder, elapsedMs: () -> Double) {
        if let pressedAt {
            builder.timing.keyToFirstWriteMs = max(0, now().timeIntervalSince(pressedAt) * 1000)
        } else {
            builder.timing.keyToFirstWriteMs = elapsedMs()
        }
    }

}
