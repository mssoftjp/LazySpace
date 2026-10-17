import AppKit
import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations

extension ReadyWindowController {
    // MARK: - Presentation

    /// App rows only; explanations never go into table cells.
    static func listRows(_ inspection: Inspection, waiting: Set<WindowID>, waitingApplies: Bool, name: (String) -> String) -> [InspectorRow] {
        let snapshot = inspection.snapshot
        guard snapshot.trusted, snapshot.spaceObservationAvailable, snapshot.spaceID != nil else { return [] }
        let waiting = waitingApplies ? waiting : []
        var rows: [InspectorRow] = []
        for window in inspection.targets {
            let eligibility = waiting.contains(window.id) ? waitingVerdict : eligibleVerdict
            rows.append(InspectorRow(app: shownApp(window.app, name: name), eligibility: eligibility))
        }
        for exclusion in inspection.excluded {
            rows.append(InspectorRow(app: shownApp(exclusion.window.app, name: name), eligibility: exclusionText(exclusion)))
        }
        for app in snapshot.unobservedApps {
            rows.append(InspectorRow(app: shownApp(app, name: name), eligibility: noResponseShort, toolTip: noResponseVerdict))
        }
        return rows
    }

    static func presentation(_ inspection: Inspection, waiting: Set<WindowID>, waitingApplies: Bool, name: (String) -> String) -> ListBody {
        let snapshot = inspection.snapshot
        if !snapshot.trusted { return .message(windowsUnavailableText) }
        if !snapshot.spaceObservationAvailable || snapshot.spaceID == nil { return .message(unknownSpaceText) }
        let rows = listRows(inspection, waiting: waiting, waitingApplies: waitingApplies, name: name)
        if rows.isEmpty { return .message(noWindowsText) }
        return .rows(rows)
    }

    static func exclusionText(_ exclusion: Exclusion) -> String {
        switch exclusion.window.membership {
        case .allSpaces:
            return L("Excluded: on all Spaces", "対象外：すべての操作スペースに表示")
        case .current where exclusion.window.kind == .dialog:
            return L("Excluded: fixed-size window", "対象外：大きさが固定のウインドウ")
        default:
            return L("Excluded: \(exclusion.reason)", "対象外：\(exclusion.reason)")
        }
    }

    static func showsRemediation(_ status: AppStatus) -> Bool {
        !status.trusted || !status.manualAvailable || !status.autoAvailable
    }

    /// A short reason shown right above the list. The long explanation is in the remediation sheet.
    static func remediationReason(_ status: AppStatus) -> String? {
        guard showsRemediation(status) else { return nil }
        if !status.trusted { return accessibilityShort }
        if !status.spaceObservation || !status.manualAvailable { return spaceShort }
        if status.inputObservation == InputMonitor.Mode.unavailable.rawValue { return inputShort }
        // The configuration file, Stage Manager, and display setup reuse the sentence that explains why automatic arrangement stopped.
        return status.autoReason
    }

    static func remediationChoices(_ status: AppStatus) -> [DetailSheet.Choice] {
        var choices = [DetailSheet.closeChoice]
        if !status.trusted {
            choices.append(DetailSheet.Choice(kind: .openGeneralSettings, title: L("Open General Settings", "設定の「一般」を開く")))
        } else if status.inputObservation == InputMonitor.Mode.unavailable.rawValue {
            choices.append(DetailSheet.Choice(kind: .openSettings, title: L("Open \(AccessPane.name()) Settings", "「\(AccessPane.name())」の設定を開く")))
        } else if status.configError != nil {
            choices.append(DetailSheet.Choice(kind: .openGeneralSettings, title: L("Open Settings", "設定を開く")))
        }
        return choices
    }

    static func remediationDetail(_ status: AppStatus) -> String {
        if !status.trusted {
            return L(
                "The \(AccessPane.name()) permission is required to read windows. Open General Settings and click Open System Settings….",
                "ウインドウを読むには「\(AccessPane.name())」の許可が必要です。設定の「一般」で「システム設定を開く…」をクリックしてください。")
        }
        if !status.spaceObservation || !status.manualAvailable {
            return L(
                "The current Space can't be detected. This version of macOS does not tell LazySpace which Space is active, so windows in this Space can't be listed.",
                "現在の操作スペースを確認できません。このmacOSでは現在の操作スペースが分からないため、この操作スペースのウインドウを一覧できません。")
        }
        if status.inputObservation == InputMonitor.Mode.unavailable.rawValue {
            return L(
                "Input observation is unavailable, so automatic arrangement stays off. Open \(AccessPane.name()) settings and allow LazySpace.",
                "入力を観測できないため、自動整列はオフのままです。「\(AccessPane.name())」でLazySpaceを許可してください。")
        }
        return status.autoReason
    }

    /// Only an unfinished recent operation, never a Space move, and not after 30 minutes even while managed.
    static func showsPreviousOperation(_ result: OperationResult?, now: Date = Date()) -> Bool {
        guard let result else { return false }
        switch result.outcome {
        case .partial, .interrupted, .notPossible:
            break
        case .complete, .nothingToDo:
            return false
        }
        if isSpaceOperation(result.kind) { return false }
        let age = now.timeIntervalSince(result.finishedAt)
        return age >= 0 && age <= 30 * 60
    }

    static func isSpaceOperation(_ kind: String) -> Bool {
        kind == "space" || kind == "move-to-space"
    }

    static func previousOperationText(_ result: OperationResult, name: (String) -> String = { $0 }, time: (Date) -> String = shortDateTime) -> String {
        var lines = [
            L("Finished: \(time(result.finishedAt))", "完了: \(time(result.finishedAt))"),
            recordedSpaceLine(result.spaceID),
            outcomeTitle(result),
        ]
        let message = resultBody(result, name: name)
        if !message.isEmpty { lines.append(message) }
        if result.targets.isEmpty {
            lines.append(L("Targets: not recorded", "対象: 記録なし"))
        } else {
            lines.append(L("Recorded targets", "記録された対象"))
            for target in result.targets {
                lines.append("\(shownApp(target.app, name: name)) — \(statusText(target))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func recordedSpaceLine(_ spaceID: UInt64?) -> String {
        guard let spaceID else { return L("Recorded Space ID: not recorded", "記録された操作スペースID: 記録なし") }
        return L("Recorded Space ID: \(spaceID)", "記録された操作スペースID: \(spaceID)")
    }

    static func updatedLabel(checking: Bool, date: Date?) -> String {
        if checking { return L("Checking…", "確認中…") }
        guard let date else { return "" }
        return L("Updated \(shortTime(date))", "\(shortTime(date))更新")
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static var spaceHeadingText: String { L("This Space", "この操作スペース") }
    static var refreshTitle: String { L("Refresh", "更新") }
    static var previousTitle: String { L("Previous Operation…", "前回の操作…") }
    static var fixTitle: String { L("Show Fix…", "対処を確認…") }
    static var remediationSheetTitle: String { L("Resolve Arrangement Issue", "整列の問題を解決") }
    static var eligibleVerdict: String { L("Eligible", "整列対象") }
    static var accessibilityShort: String { L("The \(AccessPane.name()) permission is required.", "「\(AccessPane.name())」の許可が必要です。") }
    static var spaceShort: String { L("The current Space can't be detected.", "現在の操作スペースを確認できません。") }
    static var inputShort: String { L("Input observation is unavailable.", "入力の観測が利用できません。") }
    static var noWindowsText: String { L("No windows in this Space.", "この操作スペースにウインドウはありません。") }
    static var windowsUnavailableText: String {
        L("The \(AccessPane.name()) permission is required to read windows.", "ウインドウを読むには「\(AccessPane.name())」の許可が必要です。")
    }
    static var unknownSpaceText: String {
        L("The current Space can't be determined, so its windows can't be listed.", "現在の操作スペースを確認できないため、ウインドウを一覧できません。")
    }
    static var mismatchText: String {
        L("The window list did not match this Space.", "ウインドウ一覧がこの操作スペースと一致しませんでした。")
    }
    static var noResponseShort: String { L("No Response", "応答なし") }

    static func outcomeTitle(_ result: OperationResult) -> String {
        switch result.outcome {
        case .complete: return L("Completed", "完了")
        case .partial: return L("Partially Applied", "一部のみ適用")
        case .interrupted: return L("Interrupted", "中断")
        case .notPossible: return L("Could Not Complete", "完了できませんでした")
        case .nothingToDo: return L("Nothing to Do", "することはありません")
        }
    }

    /// App name shown in the window list. An empty lookup keeps the bundle ID.
    static func shownApp(_ bundleID: String, name: (String) -> String) -> String {
        let shown = name(bundleID)
        return shown.isEmpty ? bundleID : shown
    }

    /// Replaces bundle IDs left in a saved result message with app names, only for IDs among the targets.
    /// Longer IDs first, and replaced text is never searched again.
    static func readableMessage(_ message: String, apps: [String], name: (String) -> String) -> String {
        var out = message
        var slots: [(token: String, shown: String)] = []
        for (index, app) in Set(apps).sorted(by: { $0.count > $1.count }).enumerated() {
            let shown = shownApp(app, name: name)
            guard shown != app, out.contains(app) else { continue }
            let token = "\u{0}\(index)\u{0}"
            out = out.replacingOccurrences(of: app, with: token)
            slots.append((token, shown))
        }
        for slot in slots { out = out.replacingOccurrences(of: slot.token, with: slot.shown) }
        return out
    }

    static func resultBody(_ result: OperationResult, name: (String) -> String = { $0 }) -> String {
        readableMessage(result.message, apps: result.targets.map(\.app) + result.unobservedApps, name: name)
    }

    static var windowTitle: String { L("LazySpace — Windows", "LazySpace — ウインドウの確認") }
    static var menuTitle: String { L("Check Windows…", "ウインドウを確認…") }

    static var verdictColumnTitle: String { L("Eligibility", "整列対象") }
    static var waitingVerdict: String { L("Waiting to Join", "待機中") }
    static var noResponseVerdict: String {
        L("No Response: Could not read this app's windows before the timeout.", "応答なし: 期限内にこのアプリのウインドウを読み取れませんでした。")
    }

    static func statusText(_ target: TargetReport) -> String {
        func withNote(_ title: String) -> String {
            guard let note = target.note, !note.isEmpty else { return title }
            return L("\(title): \(note)", "\(title): \(note)")
        }
        switch target.status {
        case .verified: return L("Applied", "適用済み")
        case .unchanged: return L("Already in Place", "変更不要")
        case .mismatch: return withNote(L("Does Not Match the Layout", "レイアウトと不一致"))
        case .unapplied: return withNote(L("Not Applied", "未適用"))
        case .gone: return L("Window Closed", "閉じられました")
        }
    }
}
