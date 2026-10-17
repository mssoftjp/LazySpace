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
            return L(.windowListExcludedOnAllSpaces)
        case .current where exclusion.window.kind == .dialog:
            return L(.windowListExcludedFixedSizeWindow)
        default:
            return L(.windowListExcluded(exclusion.reason))
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
            choices.append(DetailSheet.Choice(kind: .openGeneralSettings, title: L(.windowListOpenGeneralSettings)))
        } else if status.inputObservation == InputMonitor.Mode.unavailable.rawValue {
            choices.append(DetailSheet.Choice(kind: .openSettings, title: L(.windowListOpenAppSettings(AccessPane.name()))))
        } else if status.configError != nil {
            choices.append(DetailSheet.Choice(kind: .openGeneralSettings, title: L(.windowListOpenSettings)))
        }
        return choices
    }

    static func remediationDetail(_ status: AppStatus) -> String {
        if !status.trusted {
            return L(.windowListThePermissionIsRequiredTo(AccessPane.name()))
        }
        if !status.spaceObservation || !status.manualAvailable {
            return L(.windowListTheCurrentSpaceCantBe)
        }
        if status.inputObservation == InputMonitor.Mode.unavailable.rawValue {
            return L(.windowListInputObservationIsUnavailableSo(AccessPane.name()))
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
            L(.windowListFinished(time(result.finishedAt))),
            recordedSpaceLine(result.spaceID),
            outcomeTitle(result),
        ]
        let message = resultBody(result, name: name)
        if !message.isEmpty { lines.append(message) }
        if result.targets.isEmpty {
            lines.append(L(.windowListTargetsNotRecorded))
        } else {
            lines.append(L(.windowListRecordedTargets))
            for target in result.targets {
                lines.append("\(shownApp(target.app, name: name)) — \(statusText(target))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func recordedSpaceLine(_ spaceID: UInt64?) -> String {
        guard let spaceID else { return L(.windowListRecordedSpaceIDNotRecorded) }
        return L(.windowListRecordedSpaceID(String(spaceID)))
    }

    static func updatedLabel(checking: Bool, date: Date?) -> String {
        if checking { return L(.windowListChecking) }
        guard let date else { return "" }
        return L(.windowListUpdated(shortTime(date)))
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

    static var spaceHeadingText: String { L(.cliThisSpace) }
    static var refreshTitle: String { L(.windowListRefreshTitle) }
    static var previousTitle: String { L(.windowListPreviousTitle) }
    static var fixTitle: String { L(.windowListFixTitle) }
    static var remediationSheetTitle: String { L(.windowListRemediationSheetTitle) }
    static var eligibleVerdict: String { L(.windowListEligibleVerdict) }
    static var accessibilityShort: String { L(.windowListAccessibilityShort(AccessPane.name())) }
    static var spaceShort: String { L(.windowListSpaceShort) }
    static var inputShort: String { L(.windowListInputShort) }
    static var noWindowsText: String { L(.windowListNoWindowsText) }
    static var windowsUnavailableText: String {
        L(.windowListWindowsUnavailableText(AccessPane.name()))
    }
    static var unknownSpaceText: String {
        L(.windowListUnknownSpaceText)
    }
    static var mismatchText: String {
        L(.windowListMismatchText)
    }
    static var noResponseShort: String { L(.windowListNoResponseShort) }

    static func outcomeTitle(_ result: OperationResult) -> String {
        switch result.outcome {
        case .complete: return L(.windowListCompleted)
        case .partial: return L(.windowListPartiallyApplied)
        case .interrupted: return L(.windowListInterrupted)
        case .notPossible: return L(.windowListCouldNotComplete)
        case .nothingToDo: return L(.windowListNothingToDo)
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

    static var windowTitle: String { L(.windowListWindowTitle) }
    static var menuTitle: String { L(.windowListMenuTitle) }

    static var verdictColumnTitle: String { L(.windowListVerdictColumnTitle) }
    static var waitingVerdict: String { L(.windowListWaitingVerdict) }
    static var noResponseVerdict: String {
        L(.windowListNoResponseVerdict)
    }

    static func statusText(_ target: TargetReport) -> String {
        func withNote(_ title: String) -> String {
            guard let note = target.note, !note.isEmpty else { return title }
            return L(.windowListTitleAndNote(title, note))
        }
        switch target.status {
        case .verified: return L(.windowListApplied)
        case .unchanged: return L(.windowListAlreadyInPlace)
        case .mismatch: return withNote(L(.windowListDoesNotMatchTheLayout))
        case .unapplied: return withNote(L(.windowListNotApplied))
        case .gone: return L(.windowListWindowClosed)
        }
    }
}
