import Copy
import Foundation
import LayoutCore

/// An explicit close. Checks authorization on acceptance, and membership, kind, and focus right before sending.
public final class CloseOperation {
    public let id = UUID().uuidString
    private let system: WindowSystem
    private let control: OperationControl
    private let authorization: OperationAuthorization
    private let target: WindowID
    private let limits: OperationLimits
    private let requireFocus: Bool
    private let sleep: (TimeInterval) -> Void

    public init(system: WindowSystem, control: OperationControl, target: WindowID, limits: OperationLimits = OperationLimits(),
                authorization: OperationAuthorization? = nil, requireFocus: Bool = true,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.system = system
        self.control = control
        self.target = target
        self.limits = limits
        self.sleep = sleep
        self.authorization = authorization ?? OperationAuthorization(system: system, control: control)
        self.requireFocus = requireFocus
    }

    public func run() -> OperationResult {
        let startedAt = Date()
        let snapshot = system.snapshot()
        var inspection = TargetSelection.inspect(snapshot, now: startedAt)
        inspection.targets.removeAll { $0.id != target }
        var builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: "edit:close")
        func finish(_ outcome: Outcome, _ reason: StopReason?, _ message: String) -> OperationResult {
            builder.finish(outcome: outcome, stopReason: reason, message: message,
                           finishedAt: Date(), wallMs: Date().timeIntervalSince(startedAt) * 1000)
        }
        guard snapshot.trusted else {
            return finish(.notPossible, .permissionLost, L(.closeOperationTheWindowWasNotClosed(AccessPane.name())))
        }
        guard !inspection.targets.isEmpty else {
            return finish(.notPossible, .targetsChanged, L(.closeOperationTheWindowWasNotClosedBecause))
        }
        let focused = system.focusedWindowID()
        if let reason = authorization.stopReason(system: system, control: control, snapshot: snapshot) {
            return finish(.notPossible, reason, L(.closeOperationTheWindowWasNotClosedBecausePause))
        }
        guard !requireFocus || focused == target else {
            return finish(.notPossible, .targetsChanged, L(.closeOperationTheWindowWasNotClosedBecauseFocus))
        }

        let write = system.close(target, timeout: limits.perAppTimeout) { [self] in
            let focused = !requireFocus || system.focusedWindowID() == target
            return focused && system.axTrusted && authorization.stopReason(system: system, control: control, snapshot: snapshot) == nil
        }
        builder.issued = 1
        var report = builder.report(for: target)
        report.issued = 1
        var outcome: Outcome = .partial
        var reason: StopReason?
        let message: String
        switch write {
        case .issued:
            sleep(limits.settleDelay)
            if case .gone = system.readFrame(target) {
                report.status = .gone
                builder.verified = true
                outcome = .complete
                message = L(.closeOperationWindowClosed(String(describing: target)))
            } else {
                report.status = .mismatch
                message = L(.closeOperationCloseWasRequestedButThe)
            }
        case .gone:
            report.status = .gone
            builder.verified = true
            outcome = .nothingToDo
            message = L(.closeOperationWindowIsAlreadyClosed(String(describing: target)))
        case .rejected(let why):
            report.status = .mismatch
            message = L(.closeOperationCouldntCloseWindow(String(describing: target), why))
        case .timedOut:
            report.status = .mismatch
            reason = .appUnresponsive
            message = L(.closeOperationTheAppForWindowDidnt(String(describing: target)))
        }
        report.note = message
        builder.set(report)
        return finish(outcome, reason, message)
    }
}
