import Copy
import Foundation
import Settings

/// Pure decisions for the Settings window. Holds no controller state.
enum SettingsRules {
    /// When the horizontal and vertical gaps are equal, drops the separate vertical value on save.
    static func normalized(_ config: Config) -> Config {
        var candidate = config
        if candidate.gapVertical == candidate.gap { candidate.gapVertical = nil }
        return candidate
    }

    static func languageID(_ setting: String) -> String {
        SettingsCopy.languageChoices.contains { $0.id == setting } ? setting : "system"
    }

    static func parsedNumber(_ text: String, in range: ClosedRange<Double>) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func numberError(range: ClosedRange<Double>) -> String {
        let lower = Int(range.lowerBound), upper = Int(range.upperBound)
        return L("Enter a number from \(lower) to \(upper).", "\(lower)〜\(upper)の数値を入力してください。")
    }

    static var modifierChoices: [(id: String, title: String, modifiers: Set<String>)] {
        [
            ("alt", "⌥", ["alt"]),
            ("alt-shift", "⌥⇧", ["alt", "shift"]),
            ("alt-ctrl", "⌥⌃", ["alt", "ctrl"]),
            ("alt-cmd", "⌥⌘", ["alt", "cmd"]),
            ("ctrl", "⌃", ["ctrl"]),
            ("cmd", "⌘", ["cmd"]),
            ("shift", "⇧", ["shift"]),
        ]
    }

    static func uniqueInOrder(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    /// Unassigns other actions using the same key in the same mode. except holds the actions being assigned.
    static func displace(_ key: Config.Key, in config: inout Config, except: Set<String>) -> [String] {
        var released: [String] = []
        for (other, existing) in config.keys where existing == key && !except.contains(other) {
            config.keys[other] = nil
            released.append(SettingsCopy.commandLabel(other))
        }
        return released
    }

    static func isValidAppIdentifier(_ app: String) -> Bool { Config.Rule.isValidApp(app) }

    static func appIdentifierMessage(_ app: String) -> String {
        if app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Enter a bundle identifier.", "バンドル識別子を入力してください。")
        }
        return L("Enter a bundle identifier. A trailing * matches a prefix.", "バンドル識別子を入力してください。末尾の * は前方一致です。")
    }
}
