import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// Settings. The GUI, the file, and the CLI all converge on this type.
public struct Config: Equatable, Codable {
    public struct Rule: Equatable, Codable {
        /// `space` sends newly opened windows to another Space (separate from tiling exclusion; not counted by `tilingExclusionReason`).
        public enum Action: String, Codable { case ignore, float, space }
        /// Exact bundle identifier, or a prefix match with a trailing `*`.
        public var app: String
        public var action: Action
        /// Regular expression for the window title; empty matches by app only. Titles are never written to saved logs.
        public var title: String
        /// Destination of a `space` rule: a standard desktop number.
        public var space: Int?
        /// Whether a `space` rule switches to that Space after sending (default false).
        public var follow: Bool
        public init(app: String, action: Action, title: String = "", space: Int? = nil, follow: Bool = false) {
            self.app = app
            self.action = action
            self.title = title
            self.space = space
            self.follow = follow
        }
        /// A bundle identifier, or a prefix ending in `*` (never `*` alone, which would match every app).
        public static func isValidApp(_ app: String) -> Bool {
            guard (1...200).contains(app.count) else { return false }
            let body = app.hasSuffix("*") ? String(app.dropLast()) : app
            guard !body.isEmpty else { return false }
            return body.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
            }
        }
        /// Whether the app alone matches (ignoring the title condition).
        public func matchesApp(_ bundleID: String) -> Bool {
            app.hasSuffix("*") ? bundleID.hasPrefix(String(app.dropLast())) : app == bundleID
        }
        public func matches(bundleID: String, title windowTitle: String = "") -> Bool {
            let appMatches = app.hasSuffix("*") ? bundleID.hasPrefix(String(app.dropLast())) : app == bundleID
            guard appMatches else { return false }
            guard !title.isEmpty else { return true }
            return windowTitle.range(of: title, options: .regularExpression) != nil
        }
    }

    /// A shortcut written like `alt-shift-h`. Keys without modifiers (`r`, `esc`) are allowed too (for use in modes).
    public struct Key: Equatable, Codable, Hashable {
        public var modifiers: Set<String>   // alt, shift, ctrl, cmd
        /// Normalized key name (lowercase); the list is `keyCodes`.
        public var key: String
        public init(modifiers: Set<String>, key: String) { self.modifiers = modifiers; self.key = key }

        public static func parse(_ text: String) -> Key? {
            let parts = text.lowercased().split(separator: "-").map(String.init)
            guard let last = parts.last, !last.isEmpty else { return nil }
            var mods = Set<String>()
            for m in parts.dropLast() {
                switch m {
                case "alt", "option", "opt": mods.insert("alt")
                case "shift": mods.insert("shift")
                case "ctrl", "control": mods.insert("ctrl")
                case "cmd", "command": mods.insert("cmd")
                default: return nil
                }
            }
            let name = aliases[last] ?? last
            guard keyCodes[name] != nil else { return nil }
            return Key(modifiers: mods, key: name)
        }

        public var display: String {
            let order = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
            let mods = ["ctrl", "alt", "shift", "cmd"].filter { modifiers.contains($0) }.map { order[$0]! }.joined()
            let names = [
                "slash": "/", "minus": "-", "equal": "=", "comma": ",", "period": ".", "semicolon": ";", "quote": "'", "backslash": "\\", "backtick": "`",
                "leftsquarebracket": "[", "rightsquarebracket": "]", "space": "␣", "enter": "↩", "tab": "⇥", "esc": "⎋", "backspace": "⌫", "forwarddelete": "⌦",
                "left": "←", "right": "→", "up": "↑", "down": "↓", "pageup": "⇞", "pagedown": "⇟", "home": "↖", "end": "↘",
                "yen": "¥", "underscore": "_", "eisu": "英数", "kana": "かな", "sectionsign": "§",
            ]
            if let n = names[key] { return mods + n }
            if key.hasPrefix("keypad") { return mods + "⌨" + String(key.dropFirst(6)) }
            return mods + key.uppercased()
        }

        /// Alias (compared lowercase) -> canonical name. AeroSpace spellings are accepted here too.
        public static let aliases: [String: String] = [
            "escape": "esc", "delete": "backspace", "return": "enter", "grave": "backtick", "lbracket": "leftsquarebracket", "rbracket": "rightsquarebracket",
            "pgup": "pageup", "pgdn": "pagedown", "keypaddecimalmark": "keypaddecimal", "keypadequal": "keypadequals",
            "¥": "yen", "jisyen": "yen", "_": "underscore", "jisunderscore": "underscore",
            "英数": "eisu", "eisuu": "eisu", "jiseisu": "eisu",
            "かな": "kana", "jiskana": "kana",
            "section": "sectionsign",
        ]

        /// Virtual key codes (Carbon kVK_*) of keys in the same position on US and JIS layouts.
        public static let keyCodes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
            "rightsquarebracket": 30, "o": 31, "u": 32, "leftsquarebracket": 33, "i": 34, "p": 35, "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41,
            "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49, "backtick": 50, "backspace": 51, "enter": 36, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
            "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86, "keypad5": 87, "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92,
            "keypaddecimal": 65, "keypadmultiply": 67, "keypadplus": 69, "keypadclear": 71, "keypaddivide": 75, "keypadenter": 76, "keypadminus": 78, "keypadequals": 81,
            // JIS / ISO: Carbon kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_Eisu, kVK_JIS_Kana, kVK_ISO_Section.
            "yen": 93, "underscore": 94, "eisu": 102, "kana": 104, "sectionsign": 10,
        ]
        public var keyCode: UInt32 { Key.keyCodes[key] ?? 0 }
        /// f1-f20. Even without modifiers they do not take over normal typing.
        public var isFunctionKey: Bool { key.hasPrefix("f") && Int(key.dropFirst()) != nil }
        /// Spelling written to the configuration file (`alt-shift-h`).
        public var configText: String { (["alt", "shift", "ctrl", "cmd"].filter { modifiers.contains($0) } + [key]).joined(separator: "-") }
        /// Carbon modifiers.
        public var carbonModifiers: UInt32 {
            var m: UInt32 = 0
            if modifiers.contains("alt") { m |= 0x0800 }
            if modifiers.contains("shift") { m |= 0x0200 }
            if modifiers.contains("ctrl") { m |= 0x1000 }
            if modifiers.contains("cmd") { m |= 0x0100 }
            return m
        }
    }

    /// A binding mode (other than main). While in a mode, only its keys work.
    public struct Mode: Equatable, Codable {
        /// Command name -> key.
        public var keys: [String: Key]
        /// Returns to main after one command in the mode (like i3 / AeroSpace `['cmd', 'mode main']`).
        public var returnToMain: Bool
        public init(keys: [String: Key] = [:], returnToMain: Bool = true) { self.keys = keys; self.returnToMain = returnToMain }
    }

    /// Where a new window opened in front goes.
    public enum NewWindowPlacement: String, Codable {
        /// Beside the window focused just before (as in i3 / AeroSpace).
        case besideFocused = "beside-focused"
        /// At the end (end of a horizontal row, or the row with the fewest leaves).
        case end
    }

    public var gap: Double = 0
    /// Vertical gap between windows; nil means the same as `gap`.
    public var gapVertical: Double? = nil
    public var outerLeft: Double = 0
    public var outerTop: Double = 0
    public var outerRight: Double = 0
    public var outerBottom: Double = 0
    public var newWindowPlacement: NewWindowPlacement = .besideFocused
    /// After the front window closes, if focus is not on a window of this Space, move it to the neighbor.
    public var focusAfterClose: Bool = true
    /// Puts dialogs in a strip at the right edge and tiles the rest (sizes unchanged). Off by default.
    public var placeDialogsBeside: Bool = false
    /// Width (pt) of the visible strip of unfocused accordion windows.
    public var accordionPadding: Double = 30
    /// Border around the focused window (optional, off by default). Drawn only on Spaces that have started arranging.
    public struct FocusBorder: Equatable, Codable {
        public var enabled: Bool = false
        /// Width (pt, 1-12).
        public var width: Double = 3
        /// Color ("#RRGGBB" or "#RRGGBBAA").
        public var color: String = "#4C8DFF"
        public init(enabled: Bool = false, width: Double = 3, color: String = "#4C8DFF") { self.enabled = enabled; self.width = width; self.color = color }

        /// Color as RGBA (0-1); nil when unparseable.
        public var rgba: (Double, Double, Double, Double)? { Config.parseColor(color) }
    }
    public var focusBorder = FocusBorder()
    /// macOS notifications LazySpace may send. Off by default; how they appear is set in System Settings › Notifications.
    public struct Notifications: Equatable, Codable {
        /// When LazySpace stops arranging windows (or cannot apply the file) until the user acts.
        public var needsAttention: Bool = false
        public init(needsAttention: Bool = false) { self.needsAttention = needsAttention }
    }
    public var notifications = Notifications()
    /// Shows the shortcut list after a modifier is held for about 0.8 s. Shortcuts work even when off.
    public var showShortcutGuide = true
    public var preferredMinimum: CGSize = CGSize(width: 400, height: 300)
    public var unknownFloor: CGSize = CGSize(width: 120, height: 120)
    public var quietInterval: Double = 0.6
    public var perAppTimeout: Double = 2.0
    public var rules: [Rule] = []
    /// main mode command name (focus-left and so on) -> key.
    public var keys: [String: Key] = Config.defaultKeys
    /// Modes other than main declared in the file.
    public var modes: [String: Mode] = [:]
    /// Open at Login. nil leaves it alone from the file (the menu toggle decides).
    public var startAtLogin: Bool? = nil
    /// Command (argv array) run after the Space changes, with LAZYSPACE_SPACE_ID / LAZYSPACE_PREV_SPACE_ID in the environment.
    public var execOnSpaceChange: [String] = []
    /// Command (argv array) run after a rule's send to another Space is confirmed. The environment carries the window, app, and both Spaces (never the title).
    public var execOnWindowSent: [String] = []
    /// Command (argv array) run after the binding mode changes, with LAZYSPACE_MODE in the environment.
    public var execOnModeChange: [String] = []
    /// Display language: "system" (follow macOS) / "en" / "ja".
    public var language: String = "system"
    public static let languageValues = ["system", "en", "ja"]

    public init() {}

    public static let mainModeName = "main"

    /// Command names usable in every mode. `mode-<name>` is additionally allowed for each declared mode.
    public static let commandNames: [String] = [
        "focus-left", "focus-down", "focus-up", "focus-right",
        "swap-left", "swap-down", "swap-up", "swap-right",
        "move-left", "move-down", "move-up", "move-right",
        "join-left", "join-down", "join-up", "join-right",
        "resize-width-shrink", "resize-width-grow", "resize-height-grow", "resize-height-shrink",
        "resize-smart-shrink", "resize-smart-grow", "balance", "undo", "close", "focus-back",
        "toggle-split", "accordion", "float", "zoom", "arrange", "integrate", "pause-resume", "reload", "mode-main",
        "fullscreen", "minimize",
    ] + (1...9).map { "space-\($0)" } + ["space-next", "space-prev", "space-back"]
      + (1...9).map { "move-to-space-\($0)" } + ["move-to-space-next", "move-to-space-prev"]
      // Follow only when explicit; no additional default keys.
      + (1...9).map { "move-to-space-follow-\($0)" } + ["move-to-space-follow-next", "move-to-space-follow-prev"]

    /// Command names valid for this configuration, including declared modes.
    public var allCommandNames: [String] { Config.commandNames + modes.keys.sorted().map { "mode-\($0)" } }

    /// A mode's key table (`keys` for main).
    public func keys(forMode name: String) -> [String: Key]? {
        name == Config.mainModeName ? keys : modes[name]?.keys
    }

    /// Extracts the mode name from `mode-<name>`.
    public static func modeName(fromCommand command: String) -> String? {
        command.hasPrefix("mode-") ? String(command.dropFirst(5)) : nil
    }

    /// main follows AeroSpace's default keys. move swaps places with a neighbor in the same split (each keeps its share) and otherwise joins the neighbor's split; smart resize is 0.05.
    /// Space numbers follow standard desktop order and never create Spaces. move-to-space sends only the window; the display stays.
    /// `alt-shift-tab` and letter workspaces are not assigned.
    public static let defaultKeys: [String: Key] = {
        var keys: [String: Key] = [
            "focus-left": Key(modifiers: ["alt"], key: "h"), "focus-down": Key(modifiers: ["alt"], key: "j"),
            "focus-up": Key(modifiers: ["alt"], key: "k"), "focus-right": Key(modifiers: ["alt"], key: "l"),
            "move-left": Key(modifiers: ["alt", "shift"], key: "h"), "move-down": Key(modifiers: ["alt", "shift"], key: "j"),
            "move-up": Key(modifiers: ["alt", "shift"], key: "k"), "move-right": Key(modifiers: ["alt", "shift"], key: "l"),
            "swap-left": Key(modifiers: ["alt", "ctrl"], key: "h"), "swap-down": Key(modifiers: ["alt", "ctrl"], key: "j"),
            "swap-up": Key(modifiers: ["alt", "ctrl"], key: "k"), "swap-right": Key(modifiers: ["alt", "ctrl"], key: "l"),
            "resize-width-shrink": Key(modifiers: ["alt", "cmd"], key: "h"), "resize-width-grow": Key(modifiers: ["alt", "cmd"], key: "l"),
            "resize-height-grow": Key(modifiers: ["alt", "cmd"], key: "j"), "resize-height-shrink": Key(modifiers: ["alt", "cmd"], key: "k"),
            "resize-smart-shrink": Key(modifiers: ["alt"], key: "minus"), "resize-smart-grow": Key(modifiers: ["alt"], key: "equal"),
            "toggle-split": Key(modifiers: ["alt"], key: "slash"), "accordion": Key(modifiers: ["alt"], key: "comma"),
            "float": Key(modifiers: ["alt"], key: "f"), "zoom": Key(modifiers: ["alt"], key: "z"),
            "balance": Key(modifiers: ["alt", "shift"], key: "b"), "undo": Key(modifiers: ["alt", "shift"], key: "z"), "focus-back": Key(modifiers: ["alt"], key: "b"),
            "arrange": Key(modifiers: ["alt", "shift"], key: "a"), "integrate": Key(modifiers: ["alt", "shift"], key: "i"),
            "space-back": Key(modifiers: ["alt"], key: "tab"),
        ]
        for n in 1...9 {
            keys["space-\(n)"] = Key(modifiers: ["alt"], key: String(n))
            keys["move-to-space-\(n)"] = Key(modifiers: ["alt", "shift"], key: String(n))
        }
        return keys
    }()

    // MARK: - Loading and validation

    public struct LoadError: Error, Equatable, CustomStringConvertible {
        public var problems: [String]
        public var description: String { problems.joined(separator: "\n") }
    }

    /// Builds from a TOML string. Collects every error and throws them together (never applies partially).
    /// Valid values that deserve attention are reported through onNote.
    public static func load(toml text: String, onNote: (String) -> Void = { _ in }) throws -> Config {
        let table: [String: Any]
        do { table = try TOML.parse(text) } catch let e as TOML.ParseError { throw LoadError(problems: [e.description]) }
        var c = Config()
        var problems: [String] = []
        func boolProblem(_ key: String) -> String { L("\(key) must be true or false.", "\(key)はtrueかfalseで指定してください。") }
        let known: Set<String> = ["gap", "gaps", "preferred-minimum", "unknown-floor", "quiet-interval", "per-app-timeout", "rule", "keys", "mode", "start-at-login", "exec-on-space-change", "exec-on-mode-change", "exec-on-window-sent", "new-window-placement", "focus-after-close", "accordion-padding", "focus-border", "notifications", "language", "show-shortcut-guide", "place-dialogs-beside"]
        for k in table.keys where !known.contains(k) { problems.append(L("Unknown setting: \(k).", "不明な設定: \(k)。")) }

        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = table[key] else { return nil }
            guard let d = (v as? Double) ?? (v as? Int).map(Double.init) else { problems.append(L("\(key) must be a number.", "\(key)は数値で指定してください。")); return nil }
            guard d.isFinite, range.contains(d) else { let lo = Config.number(range.lowerBound), hi = Config.number(range.upperBound); problems.append(L("\(key) must be between \(lo) and \(hi).", "\(key)は\(lo)〜\(hi)の範囲で指定してください。")); return nil }
            return d
        }
        func size(_ key: String) -> CGSize? {
            guard let v = table[key] else { return nil }
            guard let arr = v as? [Any], arr.count == 2, let w = (arr[0] as? Double) ?? (arr[0] as? Int).map(Double.init), let h = (arr[1] as? Double) ?? (arr[1] as? Int).map(Double.init), w.isFinite, h.isFinite, (0...100_000).contains(w), (0...100_000).contains(h) else {
                problems.append(L("\(key) must be [width, height], each from 0 to 100000 points.", "\(key)は[幅, 高さ]（それぞれ0〜100000 pt）で指定してください。")); return nil
            }
            return CGSize(width: w, height: h)
        }
        if let v = number("gap", 0...200) { c.gap = v }
        if let v = number("accordion-padding", 0...200) { c.accordionPadding = v }
        if let gaps = table["gaps"] {
            guard let t = gaps as? [String: Any] else { problems.append(L("gaps must be written as a [gaps] table.", "gapsは[gaps]テーブルで書いてください。")); throw LoadError(problems: problems) }
            let gapKeys = ["inner-horizontal", "inner-vertical", "outer-left", "outer-top", "outer-right", "outer-bottom"]
            for k in t.keys where !gapKeys.contains(k) { problems.append(L("Unknown setting in gaps: \(k).", "gapsの不明な項目: \(k)。")) }
            func edge(_ value: Any?) -> Double? {
                guard let value else { return nil }
                guard let d = (value as? Double) ?? (value as? Int).map(Double.init), d.isFinite, (0...200).contains(d) else {
                    problems.append(L("Values in gaps must be numbers from 0 to 200.", "gapsの余白は0〜200の数値で指定してください。"))
                    return nil
                }
                return d
            }
            if let h = edge(t["inner-horizontal"]) { c.gap = h }
            if let v = edge(t["inner-vertical"]) { c.gapVertical = v }
            if let v = edge(t["outer-left"]) { c.outerLeft = v }
            if let v = edge(t["outer-top"]) { c.outerTop = v }
            if let v = edge(t["outer-right"]) { c.outerRight = v }
            if let v = edge(t["outer-bottom"]) { c.outerBottom = v }
            if c.gapVertical == c.gap { c.gapVertical = nil }
        }
        if let v = size("preferred-minimum") { c.preferredMinimum = v }
        if let v = size("unknown-floor") { c.unknownFloor = v }
        if let v = number("quiet-interval", 0.1...10) { c.quietInterval = v }
        if let v = number("per-app-timeout", 0.2...30) { c.perAppTimeout = v }
        if let v = table["new-window-placement"] {
            if let s = v as? String, let p = NewWindowPlacement(rawValue: s) { c.newWindowPlacement = p }
            else { problems.append(L("new-window-placement must be \"beside-focused\" or \"end\".", "new-window-placementは \"beside-focused\" か \"end\" で指定してください。")) }
        }
        if let v = table["focus-after-close"] {
            if let b = v as? Bool { c.focusAfterClose = b } else { problems.append(boolProblem("focus-after-close")) }
        }
        if let v = table["language"] {
            if let s = v as? String, languageValues.contains(s) { c.language = s }
            else { problems.append(L("language must be \"system\", \"en\", or \"ja\".", "languageは \"system\"、\"en\"、\"ja\" のいずれかで指定してください。")) }
        }
        if let v = table["place-dialogs-beside"] {
            if let b = v as? Bool { c.placeDialogsBeside = b } else { problems.append(boolProblem("place-dialogs-beside")) }
        }
        if let v = table["show-shortcut-guide"] {
            if let b = v as? Bool { c.showShortcutGuide = b } else { problems.append(boolProblem("show-shortcut-guide")) }
        }
        if let v = table["focus-border"] {
            guard let t = v as? [String: Any] else { problems.append(L("focus-border must be written as a [focus-border] table.", "focus-borderは[focus-border]テーブルで書いてください。")); throw LoadError(problems: problems) }
            for k in t.keys where !["enabled", "width", "color"].contains(k) { problems.append(L("Unknown setting in focus-border: \(k).", "focus-borderの不明な項目: \(k)。")) }
            if let e = t["enabled"] {
                if let b = e as? Bool { c.focusBorder.enabled = b } else { problems.append(boolProblem("focus-border.enabled")) }
            }
            if let w = t["width"] {
                if let d = (w as? Double) ?? (w as? Int).map(Double.init), (1...12).contains(d) { c.focusBorder.width = d }
                else { problems.append(L("focus-border.width must be a number from 1 to 12.", "focus-border.widthは1〜12の数値で指定してください。")) }
            }
            if let col = t["color"] {
                if let s = col as? String, parseColor(s) != nil { c.focusBorder.color = s }
                else { problems.append(L("focus-border.color must be \"#RRGGBB\" or \"#RRGGBBAA\".", "focus-border.colorは \"#RRGGBB\" か \"#RRGGBBAA\" で指定してください。")) }
            }
        }
        if let v = table["notifications"] {
            guard let t = v as? [String: Any] else { problems.append(L("notifications must be written as a [notifications] table.", "notificationsは[notifications]テーブルで書いてください。")); throw LoadError(problems: problems) }
            for k in t.keys where k != "needs-attention" { problems.append(L("Unknown setting in notifications: \(k).", "notificationsの不明な項目: \(k)。")) }
            if let n = t["needs-attention"] {
                if let b = n as? Bool { c.notifications.needsAttention = b } else { problems.append(boolProblem("notifications.needs-attention")) }
            }
        }

        if let rules = table["rule"] {
            guard let list = rules as? [[String: Any]] else { problems.append(L("rule must be written as [[rule]] array tables.", "ruleは[[rule]]の配列テーブルで書いてください。")); throw LoadError(problems: problems) }
            for (i, r) in list.enumerated() {
                guard let app = r["app"] as? String, !app.isEmpty else { problems.append(L("rule[\(i)]: app is required.", "rule[\(i)]: appが必要です。")); continue }
                guard Rule.isValidApp(app) else { problems.append(L("rule[\(i)]: app must be a bundle identifier, or a prefix ending in *.", "rule[\(i)]: appはバンドルIDか、*で終わる前方一致で指定してください。")); continue }
                guard let actionText = r["action"] as? String, let action = Rule.Action(rawValue: actionText) else { problems.append(L("rule[\(i)]: action must be ignore, float, or space.", "rule[\(i)]: actionはignore・float・spaceのどれかで指定してください。")); continue }
                // Standard desktop number and follow.
                var space: Int?
                var follow = false
                if action == .space {
                    switch r["space"] {
                    case let n as Int:
                        guard (1...99).contains(n) else { problems.append(L("rule[\(i)]: space must be a desktop number from 1 to 99.", "rule[\(i)]: spaceは1〜99のデスクトップ番号で指定してください。")); continue }
                        space = n
                    default:
                        problems.append(L("rule[\(i)]: action = \"space\" needs space = <number> (1 to 99).", "rule[\(i)]: action = \"space\" にはspace = <番号>（1〜99）が必要です。")); continue
                    }
                    if let f = r["follow"] {
                        guard let b = f as? Bool else { problems.append(L("rule[\(i)]: follow must be true or false.", "rule[\(i)]: followはtrueかfalseで指定してください。")); continue }
                        follow = b
                    }
                } else if r["space"] != nil || r["follow"] != nil {
                    problems.append(L("rule[\(i)]: space and follow are only for action = \"space\".", "rule[\(i)]: spaceとfollowはaction = \"space\" のときだけ使えます。")); continue
                }
                var title = ""
                if let pattern = r["title"] {
                    guard let text = pattern as? String, !text.isEmpty else { problems.append(L("rule[\(i)]: title must be a non-empty regular expression.", "rule[\(i)]: titleは空でない正規表現で指定してください。")); continue }
                    if (try? NSRegularExpression(pattern: text)) == nil { problems.append(L("rule[\(i)]: title is not a valid regular expression.", "rule[\(i)]: titleの正規表現を解釈できません。")); continue }
                    title = text
                }
                for k in r.keys where !["app", "action", "title", "space", "follow"].contains(k) { problems.append(L("rule[\(i)]: unknown setting \(k).", "rule[\(i)]: 不明な項目\(k)。")) }
                c.rules.append(Rule(app: app, action: action, title: title, space: space, follow: follow))
            }
        }
        if let v = table["start-at-login"] {
            if let b = v as? Bool { c.startAtLogin = b } else { problems.append(boolProblem("start-at-login")) }
        }
        func argv(_ key: String) -> [String]? {
            guard let v = table[key] else { return nil }
            let arr = (v as? [Any]) ?? []
            let strings = arr.compactMap { $0 as? String }
            guard !arr.isEmpty, strings.count == arr.count, !strings[0].isEmpty else {
                let example = "[\"/bin/sh\", \"-c\", \"sketchybar --trigger space_change\"]"
                problems.append(L("\(key) must be an array of strings, for example \(example).", "\(key)は文字列の配列で指定してください（例: \(example)）。")); return nil
            }
            return strings
        }
        if let v = argv("exec-on-space-change") { c.execOnSpaceChange = v }
        if let v = argv("exec-on-window-sent") { c.execOnWindowSent = v }
        if let v = argv("exec-on-mode-change") { c.execOnModeChange = v }

        // Collect mode declarations first (to check mode-<name> references).
        var modeTables: [(String, [String: Any])] = []
        if let modes = table["mode"] {
            guard let dict = modes as? [String: Any] else { problems.append(L("mode must be written as [mode.<name>] tables.", "modeは[mode.<名前>]のテーブルで書いてください。")); throw LoadError(problems: problems) }
            for (name, v) in dict.sorted(by: { $0.key < $1.key }) {
                guard let md = v as? [String: Any] else { problems.append(L("mode.\(name) must be a table.", "mode.\(name)はテーブルで書いてください。")); continue }
                if name == mainModeName { problems.append(L("Do not declare mode.main. Put main-mode shortcuts in [keys].", "mode.mainは宣言しないでください。mainモードのショートカットは[keys]に書きます。")); continue }
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { problems.append(L("mode.\(name): use letters, numbers, hyphens, or underscores in mode names.", "mode.\(name): モード名には文字・数字・ハイフン・アンダースコアを使えます。")); continue }
                modeTables.append((name, md))
                c.modes[name] = Mode()
            }
        }
        let validCommands = Set(c.allCommandNames)

        func loadKeys(_ value: Any, label: String, into keys: inout [String: Key]) {
            guard let dict = value as? [String: Any] else { problems.append(L("\(label) must be a table.", "\(label)はテーブルで書いてください。")); return }
            var written: Set<String> = []
            for (name, v) in dict {
                written.insert(name)
                guard validCommands.contains(name) else {
                    if let m = modeName(fromCommand: name) { problems.append(L("\(label): mode \(m) is not declared. Add [mode.\(m)].", "\(label): モード\(m)が宣言されていません。[mode.\(m)]を書いてください。")) }
                    else { problems.append(L("\(label): unknown command \(name).", "\(label): 不明なコマンド\(name)。")) }
                    continue
                }
                guard let text = v as? String else { problems.append(L("\(label).\(name) must be a string.", "\(label).\(name)は文字列で指定してください。")); continue }
                if text.isEmpty || text == "none" { keys[name] = nil; continue }
                guard let key = Key.parse(text) else { problems.append(L("\(label).\(name): could not read \(text). Example: alt-shift-h.", "\(label).\(name): \(text)を解釈できません（例: alt-shift-h）。")); continue }
                keys[name] = key
            }
            // Explicit assignments win over defaults; only conflicts between explicit ones are problems.
            let userKeys = Set(written.compactMap { keys[$0] })
            for (name, key) in keys where !written.contains(name) && userKeys.contains(key) { keys[name] = nil }
            var seen: [Key: String] = [:]
            for (name, key) in keys.sorted(by: { $0.key < $1.key }) {
                if let other = seen[key] { problems.append(L("\(label): \(name) and \(other) use the same shortcut \(key.display).", "\(label): \(name)と\(other)が同じショートカット\(key.display)を使っています。")) }
                seen[key] = name
            }
        }
        if let keys = table["keys"] { loadKeys(keys, label: "keys", into: &c.keys) }
        for (name, md) in modeTables {
            var mode = Mode()
            for k in md.keys where k != "keys" && k != "return-to-main" { problems.append(L("mode.\(name): unknown setting \(k).", "mode.\(name): 不明な項目\(k)。")) }
            if let r = md["return-to-main"] {
                if let b = r as? Bool { mode.returnToMain = b } else { problems.append(boolProblem("mode.\(name).return-to-main")) }
            }
            if let keys = md["keys"] { loadKeys(keys, label: "mode.\(name).keys", into: &mode.keys) }
            if mode.keys.isEmpty { problems.append(L("mode.\(name) has no shortcuts. Add [mode.\(name).keys].", "mode.\(name)にショートカットがありません。[mode.\(name).keys]を書いてください。")) }
            c.modes[name] = mode
        }
        // Keys without modifiers take over normal typing: main allows only F keys, the rest only in modes.
        for (name, key) in c.keys.sorted(by: { $0.key < $1.key }) where key.modifiers.isEmpty && !key.isFunctionKey {
            problems.append(L("keys.\(name): \(key.display) needs a modifier key in the main mode because a single key would capture normal typing. Single keys are allowed for function keys or inside a mode.", "keys.\(name): mainモードでは修飾キーなしの\(key.display)は通常の入力を横取りするため使えません。Fキーかモード内なら使えます。"))
        }
        if !problems.isEmpty { throw LoadError(problems: problems) }
        return c
    }

    /// "#RRGGBB" / "#RRGGBBAA" -> RGBA (0-1).
    public static func parseColor(_ text: String) -> (Double, Double, Double, Double)? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? Double(v & 0xFF) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        return (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255, a)
    }

    public var plannerOptions: PlannerOptions {
        PlannerOptions(gap: gap, unknownFloor: unknownFloor, maxRows: 4, preferredMinimum: preferredMinimum, accordionPadding: accordionPadding, gapVertical: gapVertical, outerLeft: outerLeft, outerTop: outerTop, outerRight: outerRight, outerBottom: outerBottom)
    }

    /// Tiling exclusion rules (ignore, float). `space` rules do not count (windows not sent are arranged as usual).
    public func rule(for bundleID: String, title: String = "") -> Rule? {
        rules.first { $0.action != .space && $0.matches(bundleID: bundleID, title: title) }
    }

    /// The `space` rule that sends new windows (first match) and its index (key for per-rule pauses).
    public func spaceRule(for bundleID: String, title: String = "") -> (index: Int, rule: Rule)? {
        rules.enumerated().first { $0.element.action == .space && $0.element.matches(bundleID: bundleID, title: title) }.map { ($0.offset, $0.element) }
    }

    /// Whether the app has a `space` rule (ignoring title conditions); decides whether to classify its windows.
    public func hasSpaceRule(forApp bundleID: String) -> Bool {
        rules.contains { $0.action == .space && $0.matchesApp(bundleID) }
    }

    public func tilingExclusionReason(bundleID: String, title: String = "") -> String? {
        guard let rule = rule(for: bundleID, title: title) else { return nil }
        if rule.action == .ignore {
            return rule.title.isEmpty
                ? L("Excluded by rule (\(rule.app))", "ルールで除外（\(rule.app)）")
                : L("Excluded by rule (\(rule.app), title /\(rule.title)/)", "ルールで除外（\(rule.app)、タイトル /\(rule.title)/）")
        }
        return rule.title.isEmpty
            ? L("Floating by rule (\(rule.app)). Its position is kept.", "ルールでフローティング（\(rule.app)）。位置を保ちます。")
            : L("Floating by rule (\(rule.app), title /\(rule.title)/). Its position is kept.", "ルールでフローティング（\(rule.app)、タイトル /\(rule.title)/）。位置を保ちます。")
    }


    /// Heading of the saved configuration file. Generated headings are English regardless of the display language.
    public static let defaultHeader = "# LazySpace configuration. Changes are reloaded automatically; run `lazyspace reload` to request a refresh."

    /// The initial configuration written on first launch. Comments and values are English and do not follow the display language.
    public static let template = """
        # LazySpace configuration. Changes to this file are reloaded automatically; run `lazyspace reload` to request a refresh.
        # Reloading replaces the settings only; it does not move windows.
        # Uncommented values are the defaults. Commented lines are optional examples.

        language = "system"            # Display language: "system" (follow macOS), "en", or "ja"
        gap = 0                        # Space between windows (pt). Use [gaps] for separate horizontal and vertical gaps and outer margins
        # [gaps]                       # Example
        # inner-horizontal = 8
        # inner-vertical = 4
        # outer-left = 0             # Inset inside the work area, excluding the menu bar and Dock (pt)
        # outer-top = 0
        # outer-right = 0
        # outer-bottom = 0
        accordion-padding = 30         # Width of the visible strip of unfocused windows in accordion layout (pt)
        preferred-minimum = [400, 300] # Hint for the initial row count, and for fitting a new window into unused space below a short window. Not an enforced size or minimum; saving does not rearrange windows
        unknown-floor = [120, 120]     # Minimum size assumed for windows whose minimum size is unknown (pt)
        quiet-interval = 0.6           # Input quiet time used by automatic arrangement (seconds, 0.1–10)
        per-app-timeout = 2.0          # Maximum wait for an app request (seconds, 0.2–30)
        new-window-placement = "beside-focused"  # New window placement: beside-focused (next to the previously focused window) or end
        focus-after-close = true       # After closing the focused window, focus a nearby window if no window in this Space has focus
        show-shortcut-guide = true     # Show shortcuts after a modifier key is held for about 0.8 seconds. false hides only that display; shortcuts still work.
        place-dialogs-beside = false   # After you switch away from a fixed-size window (such as Calculator or an alert), move it to a strip at the right or bottom edge; arranged windows use the rest. Its size does not change

        # Open at Login (true / false). If omitted, the macOS login-item setting is left unchanged.
        # You can also run `lazyspace login-item on` or `lazyspace login-item off`.
        # start-at-login = true

        # Commands to run after a Space change, or after a binding mode defined in this file changes (argv array).
        # Environment variables: LAZYSPACE_SPACE_ID, LAZYSPACE_PREV_SPACE_ID / LAZYSPACE_MODE
        # exec-on-space-change = ["/bin/sh", "-c", "sketchybar --trigger space_change"]
        # exec-on-mode-change = ["/bin/sh", "-c", "sketchybar --trigger mode_change"]
        # After a rule sends a window to another Space (confirmed sends only). Environment variables: LAZYSPACE_WINDOW_ID, LAZYSPACE_APP,
        # LAZYSPACE_FROM_SPACE, LAZYSPACE_TO_SPACE (desktop numbers on their own display; empty for a Space that has no number),
        # LAZYSPACE_FROM_DISPLAY, LAZYSPACE_TO_DISPLAY (display positions as in list-spaces; empty when unknown),
        # LAZYSPACE_FROM_SPACE_ID, LAZYSPACE_TO_SPACE_ID (macOS Space IDs, like LAZYSPACE_SPACE_ID). Window titles are never passed.
        # exec-on-window-sent = ["/bin/sh", "-c", "sketchybar --trigger window_sent"]

        # Focused-window border (default: off). Drawn only in Spaces with a managed layout; nothing is written to windows.
        # Example (turns it on):
        # [focus-border]
        # enabled = true
        # width = 3                    # pt (1–12)
        # color = "#4C8DFF"            # "#RRGGBB" or "#RRGGBBAA"

        # macOS notifications (default: off). When one is turned on, macOS asks once whether LazySpace may send notifications.
        # Choose how they appear in System Settings › Notifications.
        # [notifications]
        # needs-attention = true       # When arranging stops until you act, or a change to this file cannot be applied

        # Window rules. app is a bundle identifier (a trailing * matches a prefix). title is a regular expression for the window title (omit it to match the whole app).
        # action is ignore (exclude from tiling), float (keep its position), or space (send new windows to another Space).
        # For action = "space": space = 3 is an ordinary desktop number; follow = true also switches there.
        # A space rule only routes windows when they open (within about 1.5 s); it does not exclude them from tiling. Titles are used only for matching and are not saved.
        # Examples:
        # [[rule]]
        # app = "com.apple.calculator"
        # action = "float"
        # [[rule]]
        # app = "com.apple.finder"
        # title = "Copy"
        # action = "float"
        # [[rule]]
        # app = "com.google.Chrome"
        # title = "Meet"
        # action = "space"
        # space = 3

        # Keyboard shortcuts (main mode). Modifiers: alt, shift, ctrl, cmd. Keys: letters, digits, f1–f20, slash, minus, esc, and more. "none" disables a shortcut.
        # Key names are virtual keys. "equal" is the key beside minus, not the character printed on a JIS keyboard.
        # Commands: focus-, swap-, move-, join- + left, down, up, right; focus-back;
        #   resize-width-, resize-height-, resize-smart- + grow, shrink; balance;
        #   toggle-split, accordion, float, zoom, undo, close, fullscreen, minimize, arrange, integrate, pause-resume, reload;
        #   space-1 … space-9, space-next, space-prev, space-back (switch Spaces);
        #   move-to-space-1 … move-to-space-9, move-to-space-next, move-to-space-prev (send the focused window without switching);
        #   move-to-space-follow-1 … move-to-space-follow-9, move-to-space-follow-next, move-to-space-follow-prev (move and follow; no default keys)
        # move swaps places with the neighbor when both are in the same split, and each keeps its share of the split, as in AeroSpace.
        # Otherwise it joins the neighbor's split (into the stacked side of a T, for example), sharing the neighbor's place.
        # resize-smart changes that window's share of the parent split by 0.05, not by a fixed number of points.
        # toggle-split changes orientation and keeps accordion. accordion toggles tiles and accordion and keeps orientation.
        # space-N counts ordinary desktops in Mission Control order, excluding full-screen / Split View. A missing Space is refused, not created.
        # alt-shift-tab is not assigned. AeroSpace uses it to move a workspace to another display.
        # Letter workspaces are not assigned. Option-letter shortcuts below are LazySpace actions.
        [keys]
        focus-left = "alt-h"
        focus-down = "alt-j"
        focus-up = "alt-k"
        focus-right = "alt-l"
        move-left = "alt-shift-h"                 # Swap places within the split, or join the neighbor's split
        move-down = "alt-shift-j"
        move-up = "alt-shift-k"
        move-right = "alt-shift-l"
        swap-left = "alt-ctrl-h"
        swap-down = "alt-ctrl-j"
        swap-up = "alt-ctrl-k"
        swap-right = "alt-ctrl-l"
        resize-width-shrink = "alt-cmd-h"
        resize-width-grow = "alt-cmd-l"
        resize-height-grow = "alt-cmd-j"
        resize-height-shrink = "alt-cmd-k"
        resize-smart-shrink = "alt-minus"         # Shrink the share of the parent split by 0.05
        resize-smart-grow = "alt-equal"
        balance = "alt-shift-b"                   # Balance layout ratios
        focus-back = "alt-b"                      # Switch to the previously focused window
        undo = "alt-shift-z"                      # Undo the last layout change
        toggle-split = "alt-slash"                # Switch orientation. Accordion stays accordion
        accordion = "alt-comma"                   # Toggle tiles and accordion. Orientation stays the same
        float = "alt-f"
        zoom = "alt-z"
        arrange = "alt-shift-a"                   # Arrange this Space and start tiling (same as the menu)
        integrate = "alt-shift-i"                 # Add one waiting window to the layout
        space-1 = "alt-1"                         # Mission Control position 1 (direct through a window or app there when possible, otherwise one Space at a time for the rest). A missing Space is refused
        space-2 = "alt-2"
        space-3 = "alt-3"
        space-4 = "alt-4"
        space-5 = "alt-5"
        space-6 = "alt-6"
        space-7 = "alt-7"
        space-8 = "alt-8"
        space-9 = "alt-9"
        space-back = "alt-tab"                    # Switch to the previous Space
        move-to-space-1 = "alt-shift-1"           # Send the focused window to Desktop 1 and stay here
        move-to-space-2 = "alt-shift-2"
        move-to-space-3 = "alt-shift-3"
        move-to-space-4 = "alt-shift-4"
        move-to-space-5 = "alt-shift-5"
        move-to-space-6 = "alt-shift-6"
        move-to-space-7 = "alt-shift-7"
        move-to-space-8 = "alt-shift-8"
        move-to-space-9 = "alt-shift-9"
        # close = "alt-shift-q"                   # Close the focused window (not assigned by default; same as ⌘W)
        # fullscreen = "alt-shift-f"              # Toggle macOS full screen
        """

    /// Number spelling: `8` for integral values, otherwise full precision like `8.5` (`load` reads both).
    public static func number(_ v: Double) -> String {
        v.isFinite && v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
    }

    /// Writes the configuration as TOML that `load` reads back.
    public func render(header: String = Config.defaultHeader) -> String {
        let n = Config.number
        var out = header + "\n"
        out += "gap = \(n(gap))\n"
        out += "accordion-padding = \(n(accordionPadding))\n"
        out += "preferred-minimum = [\(n(preferredMinimum.width)), \(n(preferredMinimum.height))]\n"
        out += "unknown-floor = [\(n(unknownFloor.width)), \(n(unknownFloor.height))]\n"
        out += "quiet-interval = \(n(quietInterval))\n"
        out += "per-app-timeout = \(n(perAppTimeout))\n"
        out += "new-window-placement = \"\(newWindowPlacement.rawValue)\"\n"
        out += "focus-after-close = \(focusAfterClose)\n"
        out += "show-shortcut-guide = \(showShortcutGuide)\n"
        out += "place-dialogs-beside = \(placeDialogsBeside)\n"
        out += "language = \"\(language)\"\n"
        if let s = startAtLogin { out += "start-at-login = \(s)\n" }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
        if !execOnSpaceChange.isEmpty { out += "exec-on-space-change = [\(execOnSpaceChange.map(quoted).joined(separator: ", "))]\n" }
        if !execOnWindowSent.isEmpty { out += "exec-on-window-sent = [\(execOnWindowSent.map(quoted).joined(separator: ", "))]\n" }
        if !execOnModeChange.isEmpty { out += "exec-on-mode-change = [\(execOnModeChange.map(quoted).joined(separator: ", "))]\n" }
        let outer = outerLeft != 0 || outerTop != 0 || outerRight != 0 || outerBottom != 0
        if gapVertical != nil && gapVertical != gap || outer {
            out += "[gaps]\n"
            if let vertical = gapVertical, vertical != gap {
                out += "inner-horizontal = \(n(gap))\ninner-vertical = \(n(vertical))\n"
            }
            if outer {
                out += "outer-left = \(n(outerLeft))\nouter-top = \(n(outerTop))\nouter-right = \(n(outerRight))\nouter-bottom = \(n(outerBottom))\n"
            }
        }
        out += "\n"
        if focusBorder != FocusBorder() {
            out += "[focus-border]\nenabled = \(focusBorder.enabled)\nwidth = \(n(focusBorder.width))\ncolor = \(quoted(focusBorder.color))\n\n"
        }
        if notifications != Notifications() {
            out += "[notifications]\nneeds-attention = \(notifications.needsAttention)\n\n"
        }
        for r in rules {
            out += "[[rule]]\napp = \(quoted(r.app))\n"
            if !r.title.isEmpty { out += "title = \(quoted(r.title))\n" }
            out += "action = \"\(r.action.rawValue)\"\n"
            if let n = r.space { out += "space = \(n)\n" }
            if r.follow { out += "follow = true\n" }
            out += "\n"
        }
        func renderKeys(_ table: [String: Key], defaults: [String: Key]) {
            for name in allCommandNames {
                if let k = table[name] { out += "\(name) = \"\(k.configText)\"\n" }
                else if defaults[name] != nil { out += "\(name) = \"none\"\n" } // make the removed default explicit
            }
        }
        out += "[keys]\n"
        renderKeys(keys, defaults: Config.defaultKeys)
        for name in modes.keys.sorted() {
            guard let m = modes[name] else { continue }
            out += "\n[mode.\(name)]\nreturn-to-main = \(m.returnToMain)\n[mode.\(name).keys]\n"
            renderKeys(m.keys, defaults: [:])
        }
        return out
    }
}
