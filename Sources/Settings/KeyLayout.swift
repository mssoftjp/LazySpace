import Copy
import Foundation

/// Directional actions as a modifier set with HJKL or the arrows.
public enum DirectionPattern: String, Equatable {
    case hjkl
    case arrows

    public var title: String { self == .hjkl ? "HJKL" : L(.keyLayoutArrows) }

    var letters: [String] {
        self == .hjkl ? ["h", "j", "k", "l"] : ["left", "down", "up", "right"]
    }
}

/// focus / swap / move / join / resize, in left, down, up, right order.
public enum DirectionGroup: String, CaseIterable, Equatable {
    case focus, swap, move, join, resize

    public var title: String {
        switch self {
        case .focus: return L(.keyLayoutFocus)
        case .swap: return L(.keyLayoutSwap)
        case .move: return L(.keyLayoutMove)
        case .join: return L(.keyLayoutJoin)
        case .resize: return L(.keyLayoutResize)
        }
    }

    /// Left, down, up, right. For resize: narrower, taller, shorter, wider (H J K L order).
    public var commands: [String] {
        switch self {
        case .focus: return ["focus-left", "focus-down", "focus-up", "focus-right"]
        case .swap: return ["swap-left", "swap-down", "swap-up", "swap-right"]
        case .move: return ["move-left", "move-down", "move-up", "move-right"]
        case .join: return ["join-left", "join-down", "join-up", "join-right"]
        case .resize: return ["resize-width-shrink", "resize-height-grow", "resize-height-shrink", "resize-width-grow"]
        }
    }

    public static var allCommands: Set<String> { Set(allCases.flatMap(\.commands)) }

    public func keys(modifiers: Set<String>, pattern: DirectionPattern) -> [String: Config.Key] {
        Dictionary(uniqueKeysWithValues: zip(commands, pattern.letters).map { ($0.0, Config.Key(modifiers: modifiers, key: $0.1)) })
    }

    /// Only when all four keys share modifiers and follow HJKL or arrow order.
    public func matched(in table: [String: Config.Key]) -> (modifiers: Set<String>, pattern: DirectionPattern)? {
        let bound = commands.compactMap { table[$0] }
        guard bound.count == commands.count else { return nil }
        let mods = bound[0].modifiers
        guard bound.allSatisfy({ $0.modifiers == mods }) else { return nil }
        let letters = bound.map(\.key)
        if letters == DirectionPattern.hjkl.letters { return (mods, .hjkl) }
        if letters == DirectionPattern.arrows.letters { return (mods, .arrows) }
        return nil
    }

    public func summary(in table: [String: Config.Key]) -> String {
        if let matched = matched(in: table) {
            let mods = Config.Key.modifierText(matched.modifiers)
            return mods.isEmpty ? matched.pattern.title : mods + matched.pattern.title
        }
        let shown = commands.compactMap { table[$0]?.display }
        return shown.isEmpty ? "—" : L(.keyLayoutCustom)
    }

    /// Keys the standard template gives this group; empty if none.
    public var standardKeys: [String: Config.Key] {
        commands.reduce(into: [String: Config.Key]()) { result, name in
            if let key = Config.defaultKeys[name] { result[name] = key }
        }
    }
}

extension Config.Key {
    /// Modifiers only (such as ⌥⇧), without the key itself.
    public static func modifierText(_ modifiers: Set<String>) -> String {
        let sample = Config.Key(modifiers: modifiers, key: "space").display
        return sample.replacingOccurrences(of: "␣", with: "")
    }
}

/// Shortcut list heading; two lines only for sections with an explanation.
public struct ShortcutHeading: Equatable {
    public var section: ShortcutSection
    public var title: String
    public var detail: String
    public init(section: ShortcutSection, title: String, detail: String) {
        self.section = section
        self.title = title
        self.detail = detail
    }
}

/// Shortcut list row: one row per direction group, the rest by section.
public enum ShortcutRow: Equatable {
    case direction(DirectionGroup)
    case heading(ShortcutHeading)
    case command(name: String, label: String)

    public var commandName: String? {
        if case .command(let name, _) = self { return name }
        return nil
    }
}

/// Shortcut list sections. Decisions use the identifier; heading text is built only for display.
public enum ShortcutSection: String, CaseIterable, Equatable {
    case window
    case actions
    case spaces
    case stepwise
    case adjacentAssigned

    public var title: String {
        switch self {
        case .window: return L(.keyLayoutWindows)
        case .actions: return L(.keyLayoutActions)
        case .spaces: return L(.keyLayoutSpaces)
        case .stepwise: return L(.keyLayoutNumberedDesktopSwitching)
        case .adjacentAssigned: return L(.keyLayoutNextPreviousSpaceInLazySpace)
        }
    }

    public var detail: String { detail(follow: false) }

    /// `follow`: `follow-moved-window`, which decides what the `move-to-space-*` rows do.
    public func detail(follow: Bool) -> String {
        switch self {
        case .spaces:
            return follow
                ? L(.keyLayoutMovesTheWindowAndSwitches)
                : L(.keyLayoutSendsTheWindowAndStays)
        case .adjacentAssigned: return L(.keyLayoutStillActiveMacOSHasThe)
        case .window, .actions, .stepwise: return ""
        }
    }
}

public enum ShortcutList {
    /// Switching to the left/right Space. It overlaps the macOS shortcuts, so shown only when assigned.
    public static func isAdjacentSwitch(_ name: String) -> Bool {
        name == "space-next" || name == "space-prev"
    }

    /// Explicit follow. No default key, so shown only when assigned.
    public static func isOptionalTransfer(_ name: String) -> Bool {
        name.hasPrefix("move-to-space-follow-")
    }

    /// Keeps the row while either the saved or the draft configuration has a key, even right after unassigning.
    public static func shows(_ name: String, saved: [String: Config.Key], draft: [String: Config.Key]) -> Bool {
        !(isAdjacentSwitch(name) || isOptionalTransfer(name)) || saved[name] != nil || draft[name] != nil
    }

    public static func sectionID(for name: String) -> ShortcutSection {
        if isAdjacentSwitch(name) { return .adjacentAssigned }
        if name.hasPrefix("space-"), let index = Int(name.dropFirst("space-".count)), (1...9).contains(index) { return .stepwise }
        if name == "space-back" || name.hasPrefix("move-to-space") { return .spaces }
        if ["close", "fullscreen", "minimize", "float", "zoom", "focus-back"].contains(name) { return .window }
        return .actions
    }

    /// The five direction rows, then commands matching the search under section headings. The order is decided here, not by `Config.commandNames`.
    public static func rows(commands: [(name: String, label: String)], saved: [String: Config.Key], draft: [String: Config.Key], search: String, follow: Bool = false) -> [ShortcutRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func hits(_ text: String) -> Bool { query.isEmpty || text.lowercased().contains(query) }
        func keyHits(_ name: String) -> Bool {
            for table in [draft, saved] {
                if let key = table[name], hits(key.display) || hits(key.configText) { return true }
            }
            return false
        }
        var rows: [ShortcutRow] = []
        for group in DirectionGroup.allCases {
            let body = group.summary(in: draft)
            let matchesGroup = hits(group.title) || hits(body) || group.commands.contains { name in
                hits(name) || keyHits(name)
            }
            if matchesGroup { rows.append(.direction(group)) }
        }
        let listed = commands.filter { command in
            if DirectionGroup.allCommands.contains(command.name) { return false }
            if command.name.hasPrefix("mode-") { return false }
            return true
        }
        for section in [ShortcutSection.window, .actions, .spaces, .stepwise, .adjacentAssigned] {
            let members = ordered(listed, in: section).filter { shows($0.name, saved: saved, draft: draft) && (hits($0.label) || hits($0.name) || keyHits($0.name)) }
            guard !members.isEmpty else { continue }
            rows.append(.heading(ShortcutHeading(section: section, title: section.title, detail: section.detail(follow: follow))))
            rows.append(contentsOf: members.map { .command(name: $0.name, label: $0.label) })
        }
        return rows
    }

    private static func ordered(_ commands: [(name: String, label: String)], in section: ShortcutSection) -> [(name: String, label: String)] {
        let byName = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let preferred: [String]
        switch section {
        case .spaces:
            preferred = ["space-back"] + (1...9).map { "move-to-space-\($0)" } + ["move-to-space-next", "move-to-space-prev"]
                + (1...9).map { "move-to-space-follow-\($0)" } + ["move-to-space-follow-next", "move-to-space-follow-prev"]
        case .stepwise:
            preferred = (1...9).map { "space-\($0)" }
        case .adjacentAssigned:
            preferred = ["space-next", "space-prev"]
        case .window, .actions:
            return commands.filter { sectionID(for: $0.name) == section }
        }
        return preferred.compactMap { byName[$0] }
    }
}

/// A sentence for a recorded key that overlaps a macOS shortcut, a known key, or a special character typed with ⌥. Never blocks the assignment.
public enum ShortcutConflicts {
    public struct SystemHotkey: Equatable {
        public var keyCode: UInt32
        public var modifiers: Set<String>
        public var name: String?
        /// The `com.apple.symbolichotkeys` number. 79 and 81 are shown separately in the UI from the CGS read.
        public var symbolicID: Int?
        public init(keyCode: UInt32, modifiers: Set<String>, name: String? = nil, symbolicID: Int? = nil) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.name = name
            self.symbolicID = symbolicID
        }
    }

    /// Compares key code and modifier set; display strings are never parsed.
    public static func matches(_ key: Config.Key, keyCode: UInt32, modifiers: Set<String>) -> Bool {
        key.keyCode == keyCode && key.modifiers == modifiers
    }

    /// Keys whose character changes with ⌥ alone: letters, digits, symbols, but not arrows or F keys. Shown as the symbol (`-`), not the key name (`minus`).
    private static func optionTypingSymbol(_ key: Config.Key) -> String? {
        if key.key.count == 1, let scalar = key.key.first, scalar.isLetter { return key.key.uppercased() }
        if key.key.count == 1, let scalar = key.key.first, scalar.isNumber { return key.key }
        let punctuation: Set<String> = [
            "minus", "equal", "comma", "period", "slash", "semicolon", "quote", "backslash", "backtick",
            "leftsquarebracket", "rightsquarebracket", "space", "tab", "yen", "underscore", "sectionsign",
        ]
        guard punctuation.contains(key.key) else { return nil }
        return Config.Key(modifiers: [], key: key.key).display
    }

    public static func messages(for key: Config.Key, systemHotkeys: [SystemHotkey], optionGlyph: String?) -> [String] {
        var lines: [String] = []
        if key.modifiers == ["alt"], ["left", "right", "b", "f"].contains(key.key) {
            lines.append(L(.keyLayoutIfTerminalUsesOptionAs))
        }
        if key.modifiers == ["alt"], let optionGlyph, !optionGlyph.isEmpty, let shown = Self.optionTypingSymbol(key) {
            let glyph = optionGlyph.lowercased()
            let plain = Config.Key(modifiers: [], key: key.key).display.lowercased()
            if glyph != plain && glyph != key.key.lowercased() {
                lines.append(L(.keyLayoutWithThisKeyboardLayoutTypes(shown, optionGlyph)))
            }
        }
        if let hit = systemHotkeys.first(where: { $0.keyCode == key.keyCode && $0.modifiers == key.modifiers }) {
            if let name = hit.name, !name.isEmpty {
                lines.append(L(.keyLayoutConflictsWithTheMacOSShortcut(name)))
            } else {
                lines.append(L(.keyLayoutConflictsWithAMacOSShortcut))
            }
        }
        return lines
    }

    /// Enabled `com.apple.symbolichotkeys`, or empty when unreadable. Only entries whose meaning we verified get names.
    public static func enabledSystemHotkeys() -> [SystemHotkey] {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let table = domain["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        var out: [SystemHotkey] = []
        for (id, raw) in table {
            guard let entry = raw as? [String: Any], isEnabled(entry["enabled"]),
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let rawKeyCode = intValue(params[1]), let keyCode = UInt32(exactly: rawKeyCode),
                  let mods = intValue(params[2]) else { continue }
            var modifiers = Set<String>()
            if mods & (1 << 17) != 0 { modifiers.insert("shift") }
            if mods & (1 << 18) != 0 { modifiers.insert("ctrl") }
            if mods & (1 << 19) != 0 { modifiers.insert("alt") }
            if mods & (1 << 20) != 0 { modifiers.insert("cmd") }
            let name: String? = switch Int(id) {
            case 79: MacItem.moveSpace(right: false)
            case 81: MacItem.moveSpace(right: true)
            default: nil
            }
            out.append(SystemHotkey(keyCode: keyCode, modifiers: modifiers, name: name, symbolicID: Int(id)))
        }
        return out
    }

    private static func isEnabled(_ raw: Any?) -> Bool {
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.intValue != 0 }
        return false
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let number = raw as? Int { return number }
        return nil
    }
}
