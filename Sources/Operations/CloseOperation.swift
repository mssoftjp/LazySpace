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
            return finish(.notPossible, .permissionLost, L("The window was not closed because the \(AccessPane.name()) permission is missing.", "「\(AccessPane.name())」の許可がないため閉じません。"))
        }
        guard !inspection.targets.isEmpty else {
            return finish(.notPossible, .targetsChanged, L("The window was not closed because it isn't a standard window in the current Space.", "対象は現在の操作スペースの通常のウインドウではないため閉じません。"))
        }
        let focused = system.focusedWindowID()
        if let reason = authorization.stopReason(system: system, control: control, snapshot: snapshot) {
            return finish(.notPossible, reason, L("The window was not closed because pause, input, or the Space changed after the request.",
                                                  "受付後に一時停止・入力・操作スペースの状態が変わったため閉じません。"))
        }
        guard !requireFocus || focused == target else {
            return finish(.notPossible, .targetsChanged, L("The window was not closed because focus changed.", "フォーカスが変わったため閉じません。"))
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
                message = L("Window \(target) closed.", "ウインドウ\(target)が閉じたことを確認しました。")
            } else {
                report.status = .mismatch
                message = L("Close was requested, but the window is still open. Check the app for a save prompt or similar dialog.",
                            "閉じる操作を発行しましたが、ウインドウはまだあります。保存の確認などをアプリで確認してください。")
            }
        case .gone:
            report.status = .gone
            builder.verified = true
            outcome = .nothingToDo
            message = L("Window \(target) is already closed.", "ウインドウ\(target)は既に閉じられています。")
        case .rejected(let why):
            report.status = .mismatch
            message = L("Couldn't close window \(target): \(why)", "ウインドウ\(target)を閉じられません: \(why)")
        case .timedOut:
            report.status = .mismatch
            reason = .appUnresponsive
            message = L("The app for window \(target) didn't respond in time.", "ウインドウ\(target)のアプリが期限内に応答しませんでした。")
        }
        report.note = message
        builder.set(report)
        return finish(outcome, reason, message)
    }
}
