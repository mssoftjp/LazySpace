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
        return L(.settingsRulesEnterANumberFromTo(String(lower), String(upper)))
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
            released.append(SettingsCopy.commandLabel(other, follow: config.followMovedWindow))
        }
        return released
    }

    static func isValidAppIdentifier(_ app: String) -> Bool { Config.Rule.isValidApp(app) }

    /// `config` with a rule that keeps `app`'s windows out of the arrangement, added last. nil when `app` is not a valid
    /// identifier or already has a rule, which is never replaced. Settings › Apps "+" and the window list's "Don't Arrange
    /// This App" both add it.
    static func addingIgnoreRule(_ app: String, to config: Config) -> Config? {
        guard isValidAppIdentifier(app), !config.rules.contains(where: { $0.app == app }) else { return nil }
        var next = config
        next.rules.append(Config.Rule(app: app, action: .ignore))
        return next
    }

    /// `rule` with the action chosen from the Apps row menu. `app` and `title` stay. `follow` stays only when a desktop rule
    /// moves to another desktop; any other change drops `space` and `follow`, which only a desktop rule may have. A desktop
    /// rule needs a number the parser accepts; without one, `rule` comes back unchanged.
    static func rule(_ rule: Config.Rule, choosing action: Config.Rule.Action, space: Int? = nil) -> Config.Rule {
        guard action == .space else { return Config.Rule(app: rule.app, action: action, title: rule.title) }
        guard let space, Config.Rule.spaceNumbers.contains(space) else { return rule }
        return Config.Rule(app: rule.app, action: .space, title: rule.title, space: space, follow: rule.action == .space && rule.follow)
    }

    static func appIdentifierMessage(_ app: String) -> String {
        if app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L(.settingsRulesEnterABundleIdentifier)
        }
        return L(.settingsRulesEnterABundleIdentifierA)
    }
}
