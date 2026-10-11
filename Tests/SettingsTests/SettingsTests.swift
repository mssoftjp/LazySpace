import CoreGraphics
import Copy
import XCTest
@testable import Settings

final class SettingsSaveRegressionTests: XCTestCase {
    func testRenderingPreservesFractionalGeometry() throws {
        let config = try Config.load(toml: "gap = 8.5\npreferred-minimum = [400.5, 300.25]\nunknown-floor = [120.75, 120.5]")
        XCTAssertEqual(try Config.load(toml: config.render()), config)
        XCTAssertTrue(config.render().contains("gap = 8.5\n"))
    }

    /// Integral values are written as `8`, like the template, not `8.0`.
    func testRenderingWritesIntegralValuesWithoutDecimals() throws {
        let rendered = try Config.load(toml: "gap = 8\npreferred-minimum = [400, 300]\nper-app-timeout = 2.0\n").render()
        XCTAssertTrue(rendered.contains("gap = 8\n"), rendered)
        XCTAssertTrue(rendered.contains("preferred-minimum = [400, 300]\n"), rendered)
        XCTAssertTrue(rendered.contains("per-app-timeout = 2\n"), rendered)
        XCTAssertTrue(rendered.contains("quiet-interval = 0.6\n"), rendered)
        XCTAssertEqual(Config.number(8), "8")
        XCTAssertEqual(Config.number(8.5), "8.5")
        XCTAssertEqual(Config.number(0.15), "0.15")
    }

    func testRenderingPreservesEscapedCommandArguments() throws {
        var config = Config()
        config.execOnSpaceChange = ["printf", "line1\nline2\t\\\"quoted\""]
        XCTAssertEqual(try Config.load(toml: config.render()), config)
    }
}

final class TOMLTests: XCTestCase {
    func testTablesArraysAndScalars() throws {
        let t = try TOML.parse("""
        # comment
        gap = 8
        ratio = 0.5
        on = true
        name = "a # not comment"
        pair = [400, 300]
        [keys]
        focus-left = 'alt-h'
        [[rule]]
        app = "com.apple.calculator"
        action = "float"
        [[rule]]
        app = "com.x.*"
        action = "ignore"
        [nested.deep]
        v = { a = 1, b = "x" }
        """)
        XCTAssertEqual(t["gap"] as? Int, 8)
        XCTAssertEqual(t["ratio"] as? Double, 0.5)
        XCTAssertEqual(t["on"] as? Bool, true)
        XCTAssertEqual(t["name"] as? String, "a # not comment")
        XCTAssertEqual((t["pair"] as? [Any])?.count, 2)
        XCTAssertEqual((t["keys"] as? [String: Any])?["focus-left"] as? String, "alt-h")
        XCTAssertEqual((t["rule"] as? [[String: Any]])?.count, 2)
        let deep = (t["nested"] as? [String: Any])?["deep"] as? [String: Any]
        XCTAssertEqual(((deep?["v"] as? [String: Any])?["b"]) as? String, "x")
    }

    func testErrorsCarryLineNumbers() {
        XCTAssertThrowsError(try TOML.parse("gap = 8\nbroken line\n")) { e in
            XCTAssertEqual((e as? TOML.ParseError)?.line, 2)
        }
        XCTAssertThrowsError(try TOML.parse("a = 1\na = 2")) { e in
            XCTAssertEqual((e as? TOML.ParseError)?.line, 2)
            XCTAssertEqual("\(e)", "Line 2: Duplicate key: a.")
        }
        XCTAssertThrowsError(try TOML.parse("s = \"open")) { e in
            XCTAssertEqual((e as? TOML.ParseError)?.line, 1)
            XCTAssertTrue("\(e)".contains("closing quote"), "\(e)")
        }
    }

    /// A plain table header naming an array of tables is an error, never a merge into its last element.
    func testATableHeaderCannotReopenAnArrayOfTables() {
        XCTAssertThrowsError(try TOML.parse("[[rule]]\napp = \"com.apple.finder\"\n[rule]\ntitle = \"Copy\"")) { error in
            XCTAssertEqual((error as? TOML.ParseError)?.line, 3)
        }
    }

    /// Basic-string escapes follow TOML; anything else is an error with its line, never kept as text.
    func testStringEscapes() throws {
        let t = try TOML.parse(#"a = "コピー""# + "\n" + #"b = "\U0001F600\b\f""#)
        XCTAssertEqual(t["a"] as? String, "コピー")
        XCTAssertEqual(t["b"] as? String, "😀\u{08}\u{0C}")
        XCTAssertThrowsError(try TOML.parse(#"a = "\q""#)) { XCTAssertEqual(($0 as? TOML.ParseError)?.line, 1) }
        XCTAssertThrowsError(try TOML.parse(#"a = "\u12""#))
        XCTAssertThrowsError(try TOML.parse(#"a = "\uD800""#), "a surrogate is not a character")
    }

    /// A rule's app is a bundle identifier, or a prefix ending in `*`; a bare `*` (every app) is refused, as in Settings.
    func testARuleForEveryAppIsRefused() {
        XCTAssertThrowsError(try Config.load(toml: "[[rule]]\napp = \"*\"\naction = \"space\"\nspace = 2"))
        XCTAssertThrowsError(try Config.load(toml: "[[rule]]\napp = \"com.apple finder\"\naction = \"ignore\""))
        XCTAssertNoThrow(try Config.load(toml: "[[rule]]\napp = \"com.example.*\"\naction = \"ignore\""))
    }

    func testMalformedTablesAreRejectedBeforeApplyingSettings() {
        XCTAssertThrowsError(try TOML.parse("[\"keys]\nfocus-left = 'alt-h'")) { error in
            XCTAssertEqual((error as? TOML.ParseError)?.line, 1)
        }
        XCTAssertThrowsError(try TOML.parse("v = { a = 1 b = 2 }")) { error in
            XCTAssertEqual((error as? TOML.ParseError)?.line, 1)
        }
    }

    func testErrorMessagesFollowJapanese() {
        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        XCTAssertThrowsError(try TOML.parse("a = 1\na = 2")) { e in
            XCTAssertEqual("\(e)", "2行目: aが重複しています。")
        }
        XCTAssertThrowsError(try Config.load(toml: "gap = 8\nbroken line\n")) { e in
            XCTAssertEqual((e as? Config.LoadError)?.problems, ["2行目: key = valueの形ではありません。"])
        }
    }
}

final class ConfigTests: XCTestCase {
    func testTemplateLoadsToDefaults() throws {
        let c = try Config.load(toml: Config.template)
        XCTAssertEqual(c, Config())
    }

    func testTemplateIsEnglishAndLoadsToDefaults() throws {
        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        let text = Config.template
        XCTAssertFalse(text.contains("初期"))
        XCTAssertFalse(text.contains("[mode."))
        XCTAssertTrue(text.contains("initial row count"))
        XCTAssertTrue(text.contains("unused space below a short window"))
        XCTAssertEqual(try Config.load(toml: text), Config())
        XCTAssertTrue(Config.defaultHeader.hasPrefix("# LazySpace configuration."))
        XCTAssertFalse(Config().render().contains("設定"))
        XCTAssertFalse(text.contains("# space-next = \"alt-tab\""))
        XCTAssertTrue(text.contains("otherwise one Space at a time"))
    }

    func testLanguageParsingAndRendering() throws {
        XCTAssertEqual(Config().language, "system")
        for value in Config.languageValues {
            let c = try Config.load(toml: "language = \"\(value)\"")
            XCTAssertEqual(c.language, value)
            XCTAssertTrue(c.render().contains("language = \"\(value)\"\n"))
            XCTAssertEqual(try Config.load(toml: c.render()), c)
        }
        for bad in ["\"fr\"", "\"EN\"", "1"] {
            XCTAssertThrowsError(try Config.load(toml: "language = \(bad)"), bad) { e in
                let problems = (e as? Config.LoadError)?.problems ?? []
                XCTAssertTrue(problems.contains { $0.hasPrefix("language ") }, "\(problems)")
            }
        }
    }

    func testValuesRulesAndKeys() throws {
        let c = try Config.load(toml: """
        gap = 10
        preferred-minimum = [500, 350]
        [[rule]]
        app = "com.apple.calculator"
        action = "float"
        [[rule]]
        app = "com.example.*"
        action = "ignore"
        [keys]
        focus-left = "alt-shift-left"
        zoom = "none"
        """)
        XCTAssertEqual(c.gap, 10)
        XCTAssertEqual(c.preferredMinimum, CGSize(width: 500, height: 350))
        XCTAssertEqual(c.rule(for: "com.apple.calculator")?.action, .float)
        XCTAssertEqual(c.rule(for: "com.example.foo")?.action, .ignore)
        XCTAssertNil(c.rule(for: "com.apple.finder"))
        XCTAssertEqual(c.keys["focus-left"], Config.Key(modifiers: ["alt", "shift"], key: "left"))
        XCTAssertNil(c.keys["zoom"])
        XCTAssertEqual(c.keys["focus-right"], Config.defaultKeys["focus-right"], "unwritten keys keep their defaults")
    }

    func testNonFiniteAndHugeSizesAreRejected() {
        for value in ["inf", "1e300"] {
            XCTAssertThrowsError(try Config.load(toml: "preferred-minimum = [\(value), 300]"))
        }
    }

    func testAllProblemsAreReportedAndNothingIsApplied() {
        XCTAssertThrowsError(try Config.load(toml: """
        gap = -1
        typo = 3
        [[rule]]
        app = "x"
        action = "hide"
        [keys]
        focus-left = "alt-h"
        focus-right = "alt-h"
        nope = "alt-a"
        """)) { e in
            let problems = (e as? Config.LoadError)?.problems ?? []
            XCTAssertTrue(problems.contains { $0.contains("gap") })
            XCTAssertTrue(problems.contains { $0.contains("typo") })
            XCTAssertTrue(problems.contains { $0.contains("hide") || $0.contains("action") })
            XCTAssertTrue(problems.contains { $0.contains("focus-left") && $0.contains("focus-right") && $0.contains("same shortcut") }, "\(problems)")
            XCTAssertTrue(problems.contains { $0.contains("nope") })
        }
    }

    func testGapsAndTitleRulesRoundTrip() throws {
        let c = try Config.load(toml: """
        gap = 8
        [gaps]
        inner-vertical = 4
        outer-left = 2
        outer-bottom = 3
        [[rule]]
        app = "com.apple.finder"
        title = "コピー|Copy"
        action = "float"
        [[rule]]
        app = "com.apple.Safari"
        action = "ignore"
        """)
        XCTAssertEqual(c.gap, 8)
        XCTAssertEqual(c.gapVertical, 4)
        XCTAssertEqual(c.outerLeft, 2)
        XCTAssertEqual(c.outerBottom, 3)
        XCTAssertEqual(c.outerTop, 0)
        XCTAssertEqual(c.rule(for: "com.apple.finder", title: "ファイルをコピー中")?.action, .float)
        XCTAssertNil(c.rule(for: "com.apple.finder", title: "書類"))
        XCTAssertEqual(c.rule(for: "com.apple.Safari")?.action, .ignore)
        XCTAssertEqual(try Config.load(toml: c.render()), c)
        XCTAssertThrowsError(try Config.load(toml: "[[rule]]\napp = \"a\"\ntitle = \"(\"\naction = \"float\"\n[keys]\nfocus-left = \"alt-h\"\n"))
    }

    func testClearingADefaultOrNumberedShortcutWritesNoneWithoutRewritingTheFile() throws {
        let source = """
        gap = 8 # keep
        [focus-border]
        width = 5
        [mode.resize]
        return-to-main = true
        [mode.resize.keys]
        focus-left = "h"
        [keys]
        focus-left = "alt-h"
        focus-back = "alt-b"
        space-3 = "f3"
        space-next = "alt-tab"

        """
        let loaded = try Config.load(toml: source)
        XCTAssertTrue(Config.commandNames.contains("space-1"))
        XCTAssertTrue(Config.commandNames.contains("space-9"))
        XCTAssertTrue(Config.commandNames.contains("space-next"))
        XCTAssertTrue(Config.commandNames.contains("space-prev"))
        let none = try Config.load(toml: "[keys]\nspace-4 = \"none\"\n")
        XCTAssertNil(none.keys["space-4"])

        var cleared = loaded
        cleared.keys["focus-back"] = nil
        let withoutDefault = try ConfigDocument.applying(cleared, to: source, replacing: loaded)
        XCTAssertTrue(withoutDefault.contains("focus-back = \"none\""), withoutDefault)
        XCTAssertTrue(withoutDefault.contains("gap = 8 # keep"), withoutDefault)
        XCTAssertTrue(withoutDefault.contains("width = 5"), withoutDefault)
        XCTAssertTrue(withoutDefault.contains("[mode.resize]"), withoutDefault)
        XCTAssertTrue(withoutDefault.contains("focus-left = \"h\""), withoutDefault)

        var numbered = loaded
        numbered.keys["space-3"] = nil
        let withoutNumber = try ConfigDocument.applying(numbered, to: source, replacing: loaded)
        XCTAssertEqual(withoutNumber.replacingOccurrences(of: "space-3 = \"none\"", with: "space-3 = \"f3\""), source)
        XCTAssertTrue(withoutNumber.contains("space-next = \"alt-tab\""))
    }

    func testKeyParsingAndDisplay() {
        XCTAssertEqual(Config.Key.parse("alt-shift-h")?.display, "⌥⇧H")
        XCTAssertEqual(Config.Key.parse("ctrl-slash")?.display, "⌃/")
        XCTAssertNil(Config.Key.parse("hyper-h"))
        XCTAssertNil(Config.Key.parse("alt-"))
        XCTAssertEqual(Config.Key.parse("alt-h")?.keyCode, 4)
        XCTAssertEqual(Config.Key.parse("alt-cmd-l")?.carbonModifiers, 0x0800 | 0x0100)
        XCTAssertEqual(Config.Key.parse("alt-yen")?.display, "⌥¥")
        XCTAssertEqual(Config.Key.parse("alt-¥")?.keyCode, 93)
        XCTAssertEqual(Config.Key.parse("underscore")?.keyCode, 94)
        XCTAssertEqual(Config.Key.parse("eisu")?.display, "英数")
        XCTAssertEqual(Config.Key.parse("かな")?.keyCode, 104)
        XCTAssertEqual(Config.Key.parse("sectionsign")?.display, "§")
        XCTAssertEqual(Config.Key.parse("section")?.keyCode, 10)
        XCTAssertEqual(Config.defaultKeys["space-1"], Config.Key(modifiers: ["alt"], key: "1"))
        XCTAssertEqual(Config.defaultKeys["move-to-space-1"], Config.Key(modifiers: ["alt", "shift"], key: "1"))
        XCTAssertEqual(Config.defaultKeys["move-left"], Config.Key(modifiers: ["alt", "shift"], key: "h"))
        XCTAssertEqual(Config.defaultKeys["swap-left"], Config.Key(modifiers: ["alt", "ctrl"], key: "h"))
        XCTAssertNil(Config.defaultKeys["space-next"])
    }
}

final class KeyLayoutTests: XCTestCase {
    func testStandardDirectionsStayOnHjklAndSpaceKeysStayUnset() {
        XCTAssertEqual(DirectionGroup.focus.matched(in: Config.defaultKeys)?.pattern, .hjkl)
        XCTAssertEqual(DirectionGroup.focus.summary(in: Config.defaultKeys), "⌥HJKL")
        XCTAssertEqual(DirectionGroup.move.matched(in: Config.defaultKeys)?.modifiers, ["alt", "shift"])
        XCTAssertEqual(DirectionGroup.swap.matched(in: Config.defaultKeys)?.modifiers, ["alt", "ctrl"])
        XCTAssertEqual(DirectionGroup.resize.matched(in: Config.defaultKeys)?.modifiers, ["alt", "cmd"])
        XCTAssertTrue(DirectionGroup.join.standardKeys.isEmpty)
        XCTAssertEqual(Config.defaultKeys["float"], Config.Key(modifiers: ["alt"], key: "f"))
        XCTAssertEqual(Config.defaultKeys["space-1"], Config.Key(modifiers: ["alt"], key: "1"))
        XCTAssertEqual(Config.defaultKeys["accordion"], Config.Key(modifiers: ["alt"], key: "comma"))
        XCTAssertEqual(Config.defaultKeys["resize-smart-shrink"], Config.Key(modifiers: ["alt"], key: "minus"))
        XCTAssertEqual(Config.defaultKeys["space-back"], Config.Key(modifiers: ["alt"], key: "tab"))
        XCTAssertNil(Config.defaultKeys["mode-service"])
    }

    func testShortcutRowsGroupDirectionsAndFilterTheRest() {
        let commands = [("close", "Close Window"), ("arrange", "Arrange and Start Tiling"), ("space-1", "Space 1"), ("mode-service", "Service"), ("mode-main", "Main")]
        XCTAssertEqual(ShortcutList.sectionID(for: "close"), .window)
        XCTAssertEqual(ShortcutList.sectionID(for: "arrange"), .actions)
        XCTAssertEqual(ShortcutList.sectionID(for: "space-1"), .stepwise)
        let rows = ShortcutList.rows(commands: commands, saved: Config.defaultKeys, draft: Config.defaultKeys, search: "")
        XCTAssertEqual(rows.prefix(5).compactMap { if case .direction(let g) = $0 { return g } else { return nil } }, DirectionGroup.allCases)
        XCTAssertEqual(Array(rows.dropFirst(5)), [
            .heading(ShortcutHeading(section: .window, title: ShortcutSection.window.title, detail: "")),
            .command(name: "close", label: "Close Window"),
            .heading(ShortcutHeading(section: .actions, title: ShortcutSection.actions.title, detail: "")),
            .command(name: "arrange", label: "Arrange and Start Tiling"),
            .heading(ShortcutHeading(section: .stepwise, title: ShortcutSection.stepwise.title, detail: ShortcutSection.stepwise.detail)),
            .command(name: "space-1", label: "Space 1"),
        ])
        XCTAssertFalse(rows.contains { if case .command(let name, _) = $0 { return name == "mode-service" } else { return false } })
        XCTAssertFalse(rows.contains { if case .command(let name, _) = $0 { return name == "mode-main" } else { return false } })
        let found = ShortcutList.rows(commands: commands, saved: Config.defaultKeys, draft: Config.defaultKeys, search: "Start Tiling")
        XCTAssertEqual(found, [
            .heading(ShortcutHeading(section: .actions, title: ShortcutSection.actions.title, detail: "")),
            .command(name: "arrange", label: "Arrange and Start Tiling"),
        ])
    }

    func testShortcutWarningsDoNotBlockKnownCollisions() {
        let altB = Config.Key(modifiers: ["alt"], key: "b")
        XCTAssertEqual(
            ShortcutConflicts.messages(for: altB, systemHotkeys: [], optionGlyph: "∫"),
            ["If Terminal uses Option as the Meta key, this conflicts with moving by word.", "With this keyboard layout, ⌥B types “∫”."]
        )
        let altH = Config.Key(modifiers: ["alt"], key: "h")
        XCTAssertEqual(ShortcutConflicts.messages(for: altH, systemHotkeys: [], optionGlyph: "h"), [])
        let hotkey = ShortcutConflicts.SystemHotkey(keyCode: altH.keyCode, modifiers: ["alt"], name: "Move left a space")
        XCTAssertEqual(
            ShortcutConflicts.messages(for: altH, systemHotkeys: [hotkey], optionGlyph: nil),
            ["Conflicts with the macOS shortcut “Move left a space”."]
        )
        let alt1 = Config.Key(modifiers: ["alt"], key: "1")
        XCTAssertEqual(
            ShortcutConflicts.messages(for: alt1, systemHotkeys: [], optionGlyph: "¡"),
            ["With this keyboard layout, ⌥1 types “¡”."]
        )
        XCTAssertEqual(ShortcutConflicts.messages(for: alt1, systemHotkeys: [], optionGlyph: "1"), [])
        let altMinus = Config.Key(modifiers: ["alt"], key: "minus")
        XCTAssertEqual(
            ShortcutConflicts.messages(for: altMinus, systemHotkeys: [], optionGlyph: "–"),
            ["With this keyboard layout, ⌥- types “–”."]
        )
        XCTAssertEqual(ShortcutConflicts.messages(for: altMinus, systemHotkeys: [], optionGlyph: "-"), [])
        let altComma = Config.Key(modifiers: ["alt"], key: "comma")
        XCTAssertEqual(
            ShortcutConflicts.messages(for: altComma, systemHotkeys: [], optionGlyph: "≤"),
            ["With this keyboard layout, ⌥, types “≤”."]
        )
        XCTAssertEqual(ShortcutConflicts.messages(for: Config.Key(modifiers: ["alt", "shift"], key: "1"), systemHotkeys: [], optionGlyph: "¡"), [])
        let unnamed = ShortcutConflicts.SystemHotkey(keyCode: altH.keyCode, modifiers: ["alt"])
        XCTAssertEqual(ShortcutConflicts.messages(for: altH, systemHotkeys: [unnamed], optionGlyph: nil), ["Conflicts with a macOS shortcut."])
        XCTAssertEqual(ShortcutConflicts.messages(for: Config.Key(modifiers: ["ctrl"], key: "left"), systemHotkeys: [hotkey], optionGlyph: nil), [])
    }

    func testAdjacentSwitchesStayHiddenUntilAssignedAndSectionsKeepTheirOrder() {
        let altTab = Config.Key(modifiers: ["alt"], key: "tab")
        let f3 = Config.Key(modifiers: [], key: "f3")
        XCTAssertFalse(ShortcutList.shows("space-next", saved: [:], draft: [:]))
        XCTAssertTrue(ShortcutList.shows("space-next", saved: ["space-next": altTab], draft: [:]))
        XCTAssertTrue(ShortcutList.shows("space-prev", saved: [:], draft: ["space-prev": altTab]))
        XCTAssertTrue(ShortcutList.shows("space-3", saved: [:], draft: [:]))
        XCTAssertTrue(ShortcutList.shows("move-to-space-3", saved: [:], draft: [:]))
        XCTAssertTrue(ShortcutList.shows("space-back", saved: [:], draft: [:]))

        let names = Config.commandNames.filter { !$0.hasPrefix("mode-") }
        let commands = names.map { ($0, $0) }
        let fresh = ShortcutList.rows(commands: commands, saved: [:], draft: [:], search: "")
        let spaces = commandNames(in: fresh, section: .spaces)
        XCTAssertEqual(spaces.count, 12)
        XCTAssertEqual(spaces.first, "space-back")
        XCTAssertEqual(commandNames(in: fresh, section: .stepwise), (1...9).map { "space-\($0)" })
        XCTAssertFalse(fresh.contains { if case .heading(let heading) = $0 { return heading.section == .adjacentAssigned } else { return false } })

        var saved = Config.defaultKeys
        saved["space-next"] = altTab
        saved["space-3"] = f3
        let assigned = ShortcutList.rows(commands: commands, saved: saved, draft: saved, search: "")
        let headings = assigned.compactMap { if case .heading(let heading) = $0 { return heading.section } else { return nil } }
        XCTAssertEqual(headings.last, .adjacentAssigned)
        XCTAssertEqual(commandNames(in: assigned, section: .adjacentAssigned), ["space-next"])
        XCTAssertEqual(commandNames(in: assigned, section: .stepwise).contains("space-3"), true)
        let searched = ShortcutList.rows(commands: commands, saved: saved, draft: saved, search: "f3")
        XCTAssertEqual(searched, [
            .heading(ShortcutHeading(section: .stepwise, title: ShortcutSection.stepwise.title, detail: ShortcutSection.stepwise.detail)),
            .command(name: "space-3", label: "space-3"),
        ])

        let byFile = ShortcutList.rows(commands: commands, saved: Config.defaultKeys, draft: Config.defaultKeys, search: "alt-shift")
        XCTAssertTrue(byFile.contains { if case .direction(.move) = $0 { return true } else { return false } })
        let byControl = ShortcutList.rows(commands: commands, saved: Config.defaultKeys, draft: Config.defaultKeys, search: "ctrl")
        XCTAssertTrue(byControl.contains { if case .direction(.swap) = $0 { return true } else { return false } })
    }

    func testNativeChordComparisonDoesNotUseDisplayText() {
        let left = Config.Key(modifiers: ["ctrl"], key: "left")
        XCTAssertTrue(ShortcutConflicts.matches(left, keyCode: 123, modifiers: ["ctrl"]))
        XCTAssertFalse(ShortcutConflicts.matches(Config.Key(modifiers: ["ctrl", "shift"], key: "left"), keyCode: 123, modifiers: ["ctrl"]))
        XCTAssertFalse(ShortcutConflicts.matches(left, keyCode: 124, modifiers: ["ctrl"]))
        XCTAssertEqual(left.display.contains("ctrl"), false)
    }

    private func commandNames(in rows: [ShortcutRow], section: ShortcutSection) -> [String] {
        var active = false
        var names: [String] = []
        for row in rows {
            switch row {
            case .heading(let heading):
                if active { return names }
                active = heading.section == section
            case .command(let name, _):
                if active { names.append(name) }
            case .direction:
                if active { return names }
            }
        }
        return names
    }
}

final class ModesAndHooksTests: XCTestCase {
    func testNewKeyNamesAndAliases() {
        XCTAssertEqual(Config.Key.parse("f1")?.keyCode, 122)
        XCTAssertEqual(Config.Key.parse("F12")?.keyCode, 111)
        XCTAssertEqual(Config.Key.parse("esc")?.keyCode, 53)
        XCTAssertEqual(Config.Key.parse("escape")?.key, "esc")
        XCTAssertEqual(Config.Key.parse("backspace")?.keyCode, 51)
        XCTAssertEqual(Config.Key.parse("leftSquareBracket")?.keyCode, 33)
        XCTAssertEqual(Config.Key.parse("alt-keypad1")?.keyCode, 83)
        XCTAssertEqual(Config.Key.parse("esc")?.display, "⎋")
        XCTAssertEqual(Config.Key.parse("alt-shift-f5")?.display, "⌥⇧F5")
        XCTAssertEqual(Config.Key.parse("alt-shift-h")?.configText, "alt-shift-h")
        XCTAssertNil(Config.Key.parse("f21"))
    }

    func testModesLoadAndValidate() throws {
        let c = try Config.load(toml: """
        start-at-login = true
        exec-on-space-change = ["/bin/sh", "-c", "echo $LAZYSPACE_SPACE_ID"]
        [keys]
        mode-service = "alt-shift-semicolon"
        [mode.service]
        return-to-main = false
        [mode.service.keys]
        mode-main = "esc"
        arrange = "r"
        reload = "alt-r"
        integrate = "i"
        """)
        XCTAssertEqual(c.startAtLogin, true)
        XCTAssertEqual(c.execOnSpaceChange, ["/bin/sh", "-c", "echo $LAZYSPACE_SPACE_ID"])
        XCTAssertEqual(c.keys["mode-service"], Config.Key(modifiers: ["alt", "shift"], key: "semicolon"))
        XCTAssertEqual(c.modes["service"]?.returnToMain, false)
        XCTAssertEqual(c.modes["service"]?.keys["arrange"], Config.Key(modifiers: [], key: "r"))
        XCTAssertEqual(c.keys(forMode: "service")?["mode-main"]?.key, "esc")
        XCTAssertNil(c.keys(forMode: "nope"))
        XCTAssertEqual(c.allCommandNames.last, "mode-service")
        XCTAssertEqual(Config.modeName(fromCommand: "mode-service"), "service")
        XCTAssertNil(Config.modeName(fromCommand: "focus-left"))
        // Round-trips unchanged.
        XCTAssertEqual(try Config.load(toml: c.render()), c)
    }

    func testModeProblemsAreAllReported() {
        XCTAssertThrowsError(try Config.load(toml: """
        start-at-login = "yes"
        exec-on-mode-change = "sketchybar"
        [keys]
        mode-ghost = "alt-g"
        arrange = "r"
        [mode.main.keys]
        arrange = "a"
        [mode.svc]
        [mode.svc.keys]
        float = "f"
        zoom = "f"
        [mode.empty]
        return-to-main = true
        """)) { e in
            let problems = (e as? Config.LoadError)?.problems ?? []
            XCTAssertTrue(problems.contains { $0.contains("start-at-login") })
            XCTAssertTrue(problems.contains { $0.contains("exec-on-mode-change") })
            XCTAssertTrue(problems.contains { $0.contains("ghost") && $0.contains("not declared") }, "\(problems)")
            XCTAssertTrue(problems.contains { $0.contains("keys.arrange") && $0.contains("needs a modifier key") }, "keys without modifiers are refused in main")
            XCTAssertTrue(problems.contains { $0.contains("mode.main") })
            XCTAssertTrue(problems.contains { $0.contains("mode.svc.keys") && $0.contains("same shortcut") })
            XCTAssertTrue(problems.contains { $0.contains("mode.empty") && $0.contains("has no shortcuts") })
        }
    }

    func testTemplateStillLoadsToDefaults() throws {
        XCTAssertEqual(try Config.load(toml: Config.template), Config())
    }

    func testDefaultShortcutsAreUniquePerMode() throws {
        func check(_ table: [String: Config.Key], _ mode: String) {
            var seen: [Config.Key: String] = [:]
            for (name, key) in table {
                if let other = seen[key] { XCTFail("\(mode): \(name) and \(other) both use \(key.configText)") }
                seen[key] = name
            }
        }
        check(Config.defaultKeys, "main")
        XCTAssertTrue(Config().modes.isEmpty)
        XCTAssertFalse(Config().render().contains("[mode.service]"))
        XCTAssertEqual(try Config.load(toml: Config().render()), Config())
    }

    func testOldDefaultTableLoadsAndPartialTablesStayExplicit() throws {
        let old = """
        [keys]
        focus-left = "alt-h"
        focus-down = "alt-j"
        focus-up = "alt-k"
        focus-right = "alt-l"
        swap-left = "alt-shift-h"
        swap-down = "alt-shift-j"
        swap-up = "alt-shift-k"
        swap-right = "alt-shift-l"
        move-left = "alt-ctrl-h"
        move-down = "alt-ctrl-j"
        move-up = "alt-ctrl-k"
        move-right = "alt-ctrl-l"
        resize-width-shrink = "alt-cmd-h"
        resize-width-grow = "alt-cmd-l"
        resize-height-grow = "alt-cmd-j"
        resize-height-shrink = "alt-cmd-k"
        toggle-split = "alt-slash"
        float = "alt-f"
        zoom = "alt-z"
        resize-smart-shrink = "alt-shift-minus"
        resize-smart-grow = "alt-shift-equal"
        balance = "alt-shift-b"
        undo = "alt-shift-z"
        focus-back = "alt-b"
        arrange = "alt-shift-a"
        integrate = "alt-shift-i"
        """
        let kept = try Config.load(toml: old)
        XCTAssertEqual(kept.keys["swap-left"], Config.Key(modifiers: ["alt", "shift"], key: "h"))
        XCTAssertEqual(kept.keys["move-left"], Config.Key(modifiers: ["alt", "ctrl"], key: "h"))
        XCTAssertEqual(kept.keys["resize-smart-shrink"], Config.Key(modifiers: ["alt", "shift"], key: "minus"))
        XCTAssertEqual(kept.keys["accordion"], Config.Key(modifiers: ["alt"], key: "comma"))
        XCTAssertEqual(kept.keys["space-9"], Config.Key(modifiers: ["alt"], key: "9"))
        XCTAssertEqual(kept.keys["move-to-space-9"], Config.Key(modifiers: ["alt", "shift"], key: "9"))
        XCTAssertEqual(kept.keys["space-back"], Config.Key(modifiers: ["alt"], key: "tab"))
        XCTAssertNil(kept.keys["mode-service"])
        XCTAssertNil(kept.modes["service"])

        let partial = try Config.load(toml: """
        [keys]
        zoom = "none"
        swap-left = "alt-shift-h"
        """)
        XCTAssertNil(partial.keys["zoom"])
        XCTAssertEqual(partial.keys["swap-left"]?.configText, "alt-shift-h")
        XCTAssertNil(partial.keys["move-left"])
        XCTAssertEqual(partial.keys["move-down"]?.configText, "alt-shift-j")
        XCTAssertEqual(partial.keys["space-1"]?.configText, "alt-1")
        XCTAssertEqual(partial.keys["space-2"]?.configText, "alt-2")
    }

    func testDeclaredServiceModeRoundTripsWithoutDefaults() throws {
        let replaced = try Config.load(toml: """
        [mode.service]
        return-to-main = false
        [mode.service.keys]
        mode-main = "esc"
        arrange = "r"
        """)
        XCTAssertEqual(replaced.modes["service"]?.keys.count, 2)
        XCTAssertNil(replaced.modes["service"]?.keys["join-left"])
        XCTAssertEqual(replaced.modes["service"]?.returnToMain, false)
        let replacedText = replaced.render()
        XCTAssertTrue(replacedText.contains("[mode.service]"))
        XCTAssertTrue(replacedText.contains("return-to-main = false"))
        XCTAssertTrue(replacedText.contains("arrange = \"r\""))
        XCTAssertFalse(replacedText.contains("join-left"))
        XCTAssertEqual(try Config.load(toml: replacedText), replaced)

        var both = Config()
        both.modes["resize"] = Config.Mode(keys: ["focus-left": Config.Key(modifiers: [], key: "h")], returnToMain: true)
        let text = both.render()
        XCTAssertTrue(text.contains("[mode.resize]"))
        XCTAssertFalse(text.contains("[mode.service]"))
        XCTAssertEqual(try Config.load(toml: text), both)
    }
}

final class PlacementTests: XCTestCase {
    /// External commands ([[exec]]) are not a setting; when present they are rejected as unknown.
    func testExternalCommandsAreNotASetting() {
        XCTAssertThrowsError(try Config.load(toml: "[[exec]]\nkey = \"b\"\ncommand = [\"/usr/bin/true\"]\n"))
        XCTAssertFalse(Config.template.contains("[[exec]]"))
    }

    func testPlacementAndFocusAfterCloseLoadAndRender() throws {
        let c = try Config.load(toml: """
        new-window-placement = "end"
        focus-after-close = false
        """)
        XCTAssertEqual(c.newWindowPlacement, .end)
        XCTAssertEqual(c.focusAfterClose, false)
        XCTAssertEqual(try Config.load(toml: c.render()), c)
        XCTAssertEqual(Config().newWindowPlacement, .besideFocused)
        XCTAssertEqual(Config().focusAfterClose, true)
        XCTAssertEqual(Config().accordionPadding, 30)
        XCTAssertFalse(Config.template.contains("auto-start-spaces"), "removed setting")
        XCTAssertThrowsError(try Config.load(toml: "auto-start-spaces = true\n"), "a removed setting is an unknown setting")
        XCTAssertTrue(Config.template.contains("accordion-padding = 30"))
    }

    func testPlacementProblems() {
        XCTAssertThrowsError(try Config.load(toml: """
        new-window-placement = "random"
        focus-after-close = "yes"
        """)) { error in
            let problems = (error as! Config.LoadError).problems
            XCTAssertTrue(problems.contains { $0.contains("new-window-placement") })
            XCTAssertTrue(problems.contains { $0.contains("focus-after-close") })
        }
    }

    /// There are no brief on-screen notices; `[hud]` is an error like any unknown setting.
    func testHudIsNotASetting() {
        XCTAssertFalse(Config.template.contains("hud"))
        XCTAssertFalse(Config().render().contains("hud"))
        for toml in ["[hud]\nenabled = false\n", "hud.enabled = false\n"] {
            XCTAssertThrowsError(try Config.load(toml: toml)) { error in
                XCTAssertEqual((error as! Config.LoadError).problems, ["Unknown setting: hud."])
            }
        }
    }

    func testShortcutGuideDefaultsFalseRoundTripAndRejectsNonBool() throws {
        XCTAssertTrue(Config().showShortcutGuide)
        let omitted = try Config.load(toml: "gap = 4\n")
        XCTAssertTrue(omitted.showShortcutGuide)
        XCTAssertEqual(omitted.gap, 4)
        let off = try Config.load(toml: """
        show-shortcut-guide = false
        gap = 8.5
        focus-after-close = false
        [mode.service]
        return-to-main = false
        [mode.service.keys]
        mode-main = "esc"
        arrange = "r"
        """)
        XCTAssertFalse(off.showShortcutGuide)
        XCTAssertEqual(off.gap, 8.5)
        XCTAssertFalse(off.focusAfterClose)
        XCTAssertEqual(off.modes["service"]?.returnToMain, false)
        XCTAssertEqual(off.modes["service"]?.keys["mode-main"], Config.Key.parse("esc"))
        XCTAssertEqual(off.modes["service"]?.keys["arrange"], Config.Key.parse("r"))
        XCTAssertEqual(try Config.load(toml: off.render()), off)
        for bad in ["\"yes\"", "1"] {
            XCTAssertThrowsError(try Config.load(toml: "show-shortcut-guide = \(bad)"), bad) { error in
                let problems = (error as? Config.LoadError)?.problems ?? []
                XCTAssertTrue(problems.contains { $0.contains("show-shortcut-guide") }, "\(problems)")
            }
        }
        XCTAssertEqual(try Config.load(toml: Config.template).showShortcutGuide, true)
    }

    func testFocusBorderLoadRenderAndProblems() throws {
        XCTAssertEqual(Config().focusBorder, Config.FocusBorder(enabled: false, width: 3, color: "#4C8DFF"))
        let c = try Config.load(toml: """
        [focus-border]
        enabled = true
        width = 5
        color = "#FF000080"
        """)
        XCTAssertEqual(c.focusBorder, Config.FocusBorder(enabled: true, width: 5, color: "#FF000080"))
        let rgba = c.focusBorder.rgba!
        XCTAssertEqual(rgba.0, 1, accuracy: 0.001); XCTAssertEqual(rgba.1, 0, accuracy: 0.001)
        XCTAssertEqual(rgba.3, 128.0 / 255, accuracy: 0.001)
        let again = try Config.load(toml: c.render())
        XCTAssertEqual(again.focusBorder, c.focusBorder)
        XCTAssertFalse(Config().render().contains("[focus-border]"))

        XCTAssertThrowsError(try Config.load(toml: """
        [focus-border]
        enabled = "yes"
        width = 40
        color = "red"
        extra = 1
        """)) { error in
            let problems = (error as! Config.LoadError).problems
            XCTAssertTrue(problems.contains { $0.contains("focus-border.enabled") }, "\(problems)")
            XCTAssertTrue(problems.contains { $0.contains("focus-border.width") })
            XCTAssertTrue(problems.contains { $0.contains("focus-border.color") })
            XCTAssertTrue(problems.contains { $0 == "Unknown setting in focus-border: extra." }, "\(problems)")
        }
        XCTAssertNil(Config.parseColor("4C8DFF"))
        XCTAssertNil(Config.parseColor("#GGGGGG"))
    }

    /// A user key that collides with a default key (added in an update) still loads; the default is unassigned.
    func testUserKeyOverridesDefaultOnlyKey() throws {
        let c = try Config.load(toml: """
        [keys]
        arrange = "alt-shift-b"     # balance's key by default
        """)
        XCTAssertEqual(c.keys["arrange"], Config.Key(modifiers: ["alt", "shift"], key: "b"))
        XCTAssertNil(c.keys["balance"])
        // Rendering writes the unassigned default as an explicit "none".
        let rendered = c.render()
        XCTAssertTrue(rendered.contains("balance = \"none\""), rendered)
        // Conflicts between the user's own keys are still errors.
        XCTAssertThrowsError(try Config.load(toml: """
        [keys]
        arrange = "alt-shift-b"
        balance = "alt-shift-b"
        """))
    }

    /// Gaps are written only with `gap` and the hyphenated keys in `[gaps]`.
    func testOnlyDocumentedGapKeysAreAccepted() {
        for text in ["[gaps]\ninner = 2\n", "[gaps]\nouter = 2\n", "[gaps.inner]\nhorizontal = 2\n", "[gaps.outer]\nleft = 2\n"] {
            XCTAssertThrowsError(try Config.load(toml: text), text)
        }
        XCTAssertEqual(try Config.load(toml: "[gaps]\ninner-horizontal = 2\nouter-left = 3\n").outerLeft, 3)
    }
}
