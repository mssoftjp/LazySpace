import Copy
import Foundation
import MacSupport
import Settings

/// The Settings warning about the macOS move-left/right Space shortcuts. Compares key codes and modifier sets.
/// Returned only when something prevents switching to the adjacent Space (a conflict, an off or unsendable assignment, no response).
enum NativeShortcutStatus {
    struct Warning: Equatable {
        var text: String
        var showsKeyboardSettings: Bool
    }

    /// Settings problems (conflict, off, unsendable assignment) come first. Without them, guidance for a direction stopped for not responding.
    /// Shows nothing when unreadable (the action reports the reason when run).
    static func warning(left: SystemSpaceShortcut, right: SystemSpaceShortcut, saved: [Config.Key], draft: [Config.Key],
                        paused: (left: Bool, right: Bool) = (false, false)) -> Warning? {
        var problems: [String] = []
        var conflict = false
        var needsSetting = false
        for (side, isRight) in [(left, false), (right, true)] {
            switch side {
            case .usable:
                let found = conflictLines(side, right: isRight, saved: saved, draft: draft)
                problems += found
                conflict = conflict || !found.isEmpty
            case .disabled, .unusable:
                problems.append(unavailableText(side, right: isRight))
                needsSetting = true
            case .unread:
                break
            }
        }
        if conflict || needsSetting {
            if conflict {
                problems.append(L("Choose different keys in the list above, or change the matching macOS shortcut.",
                                  "上の一覧で重複しているキーを別のキーに変更するか、macOS側の割り当てを変更してください。"))
            }
            if needsSetting {
                let leftName = MacItem.moveSpace(right: false), rightName = MacItem.moveSpace(right: true)
                problems.append(L("Open Keyboard Settings, choose Keyboard Shortcuts… › Mission Control, then turn on “\(leftName)” and “\(rightName)” and assign keys to them.",
                                  "「キーボード設定を開く…」を押し、「キーボードショートカット…」の「Mission Control」で、「\(leftName)」と「\(rightName)」をオンにしてキーを割り当ててください。"))
            }
            return Warning(text: problems.joined(separator: "\n"), showsKeyboardSettings: true)
        }
        let unresponsive = [(paused.left, false), (paused.right, true)].filter(\.0).map { noResponseText(right: $0.1) }
        guard !unresponsive.isEmpty else { return nil }
        return Warning(text: (unresponsive + [DesktopShortcuts.logOutAdvice]).joined(separator: "\n"), showsKeyboardSettings: false)
    }

    /// Lines for saved conflicts, conflicts resolved on save, and conflicts a save would create.
    private static func conflictLines(_ side: SystemSpaceShortcut, right: Bool, saved: [Config.Key], draft: [Config.Key]) -> [String] {
        let savedMatches = matching(saved, side)
        let draftMatches = matching(draft, side)
        var lines: [String] = []
        if let configured = configuredText(savedMatches, right: right) { lines.append(configured) }
        if let resolved = resolvedOnSaveText(savedMatches.filter { !draftMatches.contains($0) }) { lines.append(resolved) }
        if let pending = pendingText(draftMatches.filter { !savedMatches.contains($0) }, right: right) { lines.append(pending) }
        return lines
    }

    private static func matching(_ keys: [Config.Key], _ shortcut: SystemSpaceShortcut) -> [Config.Key] {
        guard case .usable(let keyCode, let modifiers) = shortcut else { return [] }
        return keys.filter { ShortcutConflicts.matches($0, keyCode: UInt32(keyCode), modifiers: modifiers) }
            .sorted { $0.configText < $1.configText }
    }

    private static func configuredText(_ keys: [Config.Key], right: Bool) -> String? {
        let shown = displayList(keys)
        guard !shown.isEmpty else { return nil }
        let name = MacItem.moveSpace(right: right)
        if right {
            return L("With these settings, \(shown) is assigned in LazySpace and to “\(name)”, so stepwise switching to the right won't work.",
                     "この設定では、\(shown)がLazySpaceと「\(name)」の両方に割り当てられているため、操作スペースを右へ順に切り替えられません。")
        }
        return L("With these settings, \(shown) is assigned in LazySpace and to “\(name)”, so stepwise switching to the left won't work.",
                 "この設定では、\(shown)がLazySpaceと「\(name)」の両方に割り当てられているため、操作スペースを左へ順に切り替えられません。")
    }

    /// A saved conflicting key removed from the draft: current behavior still follows the saved settings until saved.
    private static func resolvedOnSaveText(_ keys: [Config.Key]) -> String? {
        let shown = displayList(keys)
        guard !shown.isEmpty else { return nil }
        return L("Saving removes \(shown), so this conflict goes away.",
                 "保存すると\(shown)は外れるので、この重複は解消します。")
    }

    private static func pendingText(_ keys: [Config.Key], right: Bool) -> String? {
        let shown = displayList(keys)
        guard !shown.isEmpty else { return nil }
        let name = MacItem.moveSpace(right: right)
        if right {
            return L("\(shown) is also the macOS shortcut “\(name)”. After you save, stepwise switching to the right won't work.",
                     "\(shown)はmacOSの「\(name)」と同じキーです。保存すると、操作スペースを右へ順に切り替えられなくなります。")
        }
        return L("\(shown) is also the macOS shortcut “\(name)”. After you save, stepwise switching to the left won't work.",
                 "\(shown)はmacOSの「\(name)」と同じキーです。保存すると、操作スペースを左へ順に切り替えられなくなります。")
    }

    private static func unavailableText(_ shortcut: SystemSpaceShortcut, right: Bool) -> String {
        let name = MacItem.moveSpace(right: right)
        let consequence = right
            ? L("Stepwise Space switching to the right won't work.", "操作スペースを右へ順に切り替えられません。")
            : L("Stepwise Space switching to the left won't work.", "操作スペースを左へ順に切り替えられません。")
        let lead: String
        switch shortcut {
        case .disabled:
            lead = L("“\(name)” is off in macOS.", "macOSの「\(name)」がオフです。")
        case .unusable(let issue):
            lead = SpaceControl.refusalLead(issue, right: right)
        case .usable, .unread:
            return ""
        }
        return lead + Copy.sentenceSeparator + consequence
    }

    private static func noResponseText(right: Bool) -> String {
        let name = MacItem.moveSpace(right: right)
        if right {
            return L("macOS is not responding to “\(name)”, so stepwise Space switching to the right won't work.",
                     "macOSが「\(name)」に応答しないため、操作スペースを右へ順に切り替えられません。")
        }
        return L("macOS is not responding to “\(name)”, so stepwise Space switching to the left won't work.",
                 "macOSが「\(name)」に応答しないため、操作スペースを左へ順に切り替えられません。")
    }

    private static func displayList(_ keys: [Config.Key]) -> String {
        var seen: [String] = []
        for key in keys where !seen.contains(key.display) { seen.append(key.display) }
        return seen.joined(separator: ", ")
    }
}
