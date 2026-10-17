import CoreGraphics
import XCTest
@testable import Settings

final class ConfigDocumentTests: XCTestCase {
    private func patch(_ source: String, _ change: (inout Config) -> Void) throws -> String {
        var next = try Config.load(toml: source)
        let previous = next
        change(&next)
        return try ConfigDocument.applying(next, to: source, replacing: previous)
    }

    func testSingleChangedValuePreservesEveryOtherByte() throws {
        let source = "# 見出し\ngap = 0 # 隙間\naccordion-padding = 30 # keep\n"
        let patched = try patch(source) { $0.gap = 8 }
        XCTAssertEqual(patched, "# 見出し\ngap = 8 # 隙間\naccordion-padding = 30 # keep\n")
    }

    func testJapaneseTrailingCommentsQuotedKeysAndHashesStay() throws {
        let source = """
        "gap" = 1 # 日本語
        gaps.inner-horizontal = 4 # dotted
        show-shortcut-guide = true
        exec-on-space-change = ["/bin/sh", "-c", "echo # tag"] # 末尾
        """
        let patched = try patch(source) { $0.gap = 9 }
        XCTAssertTrue(patched.contains("\"gap\" = 1 # 日本語\n"), patched)
        XCTAssertTrue(patched.contains("gaps.inner-horizontal = 9 # dotted\n"), patched)
        XCTAssertTrue(patched.contains("echo # tag\"] # 末尾"), patched)
        XCTAssertEqual(try Config.load(toml: patched).gap, 9)
    }

    /// Turning the notification on inserts one line and keeps comments; turning it off edits that line.
    func testNotificationsInsertAndEdit() throws {
        let source = "# note\ngap = 0 # keep\n\n[keys]\nfocus-left = \"alt-h\"\n"
        let on = try patch(source) { $0.notifications.needsAttention = true }
        XCTAssertTrue(on.contains("# note\ngap = 0 # keep\n"), on)
        XCTAssertTrue(try Config.load(toml: on).notifications.needsAttention, on)
        let off = try patch(on) { $0.notifications.needsAttention = false }
        XCTAssertFalse(try Config.load(toml: off).notifications.needsAttention, off)
        XCTAssertEqual(off.components(separatedBy: "needs-attention").count, 2, off)
    }

    /// `[gaps] inner-horizontal` wins over `gap`; only the winning line is rewritten.
    func testInnerHorizontalWinsOverGap() throws {
        let shadowed = """
        gap = 1 # root
        [gaps]
        inner-horizontal = 6 # wins
        """
        let horizontal = try patch(shadowed) { $0.gap = 9 }
        XCTAssertTrue(horizontal.contains("gap = 1 # root\n"), horizontal)
        XCTAssertTrue(horizontal.contains("inner-horizontal = 9 # wins"), horizontal)

        let distinct = """
        [gaps]
        inner-horizontal = 8 # h
        inner-vertical = 3 # v
        """
        let widened = try patch(distinct) { $0.gap = 10 }
        XCTAssertTrue(widened.contains("inner-horizontal = 10 # h\n"), widened)
        XCTAssertTrue(widened.contains("inner-vertical = 3 # v"), widened)
        XCTAssertEqual(try Config.load(toml: widened).gapVertical, 3)

        let equal = """
        [gaps]
        inner-horizontal = 8 # h
        inner-vertical = 8 # v
        """
        let both = try patch(equal) { $0.gap = 10 }
        XCTAssertTrue(both.contains("inner-horizontal = 10 # h\n"), both)
        XCTAssertTrue(both.contains("inner-vertical = 10 # v"), both)
        XCTAssertNil(try Config.load(toml: both).gapVertical)
    }

    func testCRLFAndMissingFinalNewlineArePreserved() throws {
        let source = "gap = 1 # 日本語\r\naccordion-padding = 30"
        let patched = try patch(source) { $0.gap = 2 }
        XCTAssertEqual(patched, "gap = 2 # 日本語\r\naccordion-padding = 30")
        XCTAssertFalse(patched.hasSuffix("\n"))
    }

    func testRuleAddAndRemoveKeepsAdjacentComments() throws {
        let source = """
        # 電卓は残す
        [[rule]]
        app = "com.apple.calculator"
        action = "float"

        # このコメントは残す
        [[rule]]
        app = "com.apple.finder"
        title = "コピー"
        action = "ignore"
        # ルールの後

        """
        let removed = try patch(source) { config in
            config.rules.removeAll { $0.app == "com.apple.finder" }
        }
        XCTAssertTrue(removed.contains("# 電卓は残す\n"), removed)
        XCTAssertTrue(removed.contains("app = \"com.apple.calculator\"\n"), removed)
        XCTAssertFalse(removed.contains("com.apple.finder"), removed)
        XCTAssertFalse(removed.contains("コピー"), removed)
        XCTAssertTrue(removed.contains("# このコメントは残す\n"), removed)
        XCTAssertTrue(removed.contains("# ルールの後\n"), removed)
        XCTAssertEqual(try Config.load(toml: removed).rules.map(\.app), ["com.apple.calculator"])

        let added = try patch(removed) { config in
            config.rules.append(.init(app: "com.apple.finder", action: .ignore, title: "コピー"))
        }
        XCTAssertEqual(try Config.load(toml: added).rules.map(\.title), ["", "コピー"])
        XCTAssertTrue(added.contains("# このコメントは残す\n"), added)
        XCTAssertTrue(added.contains("app = \"com.apple.calculator\"\n"), added)
    }

    func testDisabledAndResetShortcutsUseExplicitNone() throws {
        let source = """
        [keys]
        zoom = "alt-z" # zoom
        focus-left = "alt-h" # left
        """
        let disabled = try patch(source) { $0.keys["zoom"] = nil }
        XCTAssertTrue(disabled.contains("zoom = \"none\" # zoom\n"), disabled)
        XCTAssertTrue(disabled.contains("focus-left = \"alt-h\" # left"), disabled)
        XCTAssertNil(try Config.load(toml: disabled).keys["zoom"])

        let restored = try patch(disabled) { $0.keys["zoom"] = Config.defaultKeys["zoom"] }
        XCTAssertTrue(restored.contains("zoom = \"alt-z\" # zoom\n"), restored)
        XCTAssertEqual(try Config.load(toml: restored).keys["zoom"], Config.Key(modifiers: ["alt"], key: "z"))
    }

    func testNoOpPreservesBytesAndHiddenValuesStayUntouched() throws {
        let source = "gap = 0   # x\r\npreferred-minimum = [500, 350] # 希望\r\n"
        let previous = try Config.load(toml: source)
        XCTAssertEqual(try ConfigDocument.applying(previous, to: source, replacing: previous), source)
        let patched = try patch(source) { $0.focusAfterClose = false }
        XCTAssertTrue(patched.contains("gap = 0   # x\r\n"), patched)
        XCTAssertTrue(patched.contains("preferred-minimum = [500, 350] # 希望\r\n"), patched)
        XCTAssertEqual(try Config.load(toml: patched).preferredMinimum, CGSize(width: 500, height: 350))
    }

    func testFollowMovedWindowChangesOnlyItsLine() throws {
        let source = "gap = 0 # x\nplace-dialogs-beside = false # beside\n[keys]\nzoom = \"alt-z\"\n"
        let added = try patch(source) { $0.followMovedWindow = true }
        XCTAssertEqual(added, "gap = 0 # x\nplace-dialogs-beside = false # beside\nfollow-moved-window = true\n[keys]\nzoom = \"alt-z\"\n")
        XCTAssertTrue(try Config.load(toml: added).followMovedWindow)
        let off = try patch(added) { $0.followMovedWindow = false }
        XCTAssertEqual(off, "gap = 0 # x\nplace-dialogs-beside = false # beside\nfollow-moved-window = false\n[keys]\nzoom = \"alt-z\"\n")
    }

    func testSeveralRuleEditsKeepUnchangedBlocksAndOrder() throws {
        let rules = """
        [[rule]]
        app = 'one' # one
        action = 'ignore'
        [[rule]]
        app = 'two' # two
        action = 'float'
        [mode.service]
        return-to-main = true
        [mode.service.keys]
        mode-main = 'esc'
        """
        let both = try patch(rules) { config in
            config.rules[0].app = "new-one"
            config.rules[1].app = "new-two"
        }
        XCTAssertTrue(both.contains("app = \"new-one\" # one\n"), both)
        XCTAssertTrue(both.contains("app = \"new-two\" # two\n"), both)
        XCTAssertTrue(both.contains("action = 'ignore'\n"), both)
        XCTAssertTrue(both.contains("action = 'float'\n"), both)
        XCTAssertTrue(both.contains("mode-main = 'esc'"), both)
        XCTAssertEqual(try Config.load(toml: both).rules.map(\.app), ["new-one", "new-two"])

        let editedAndAdded = try patch(both) { config in
            config.rules[0].action = .float
            config.rules.append(.init(app: "three", action: .ignore))
            config.rules.append(.init(app: "four", action: .float))
        }
        XCTAssertEqual(try Config.load(toml: editedAndAdded).rules.map(\.app), ["new-one", "new-two", "three", "four"])
        XCTAssertTrue(editedAndAdded.contains("app = \"new-two\" # two\n"), editedAndAdded)

        let editedAndRemoved = try patch(editedAndAdded) { config in
            config.rules[1].app = "two-b"
            config.rules.remove(at: 0)
        }
        XCTAssertEqual(try Config.load(toml: editedAndRemoved).rules.map(\.app), ["two-b", "three", "four"])
        XCTAssertTrue(editedAndRemoved.contains("# one\n"), editedAndRemoved)
    }

    func testDeletedEntriesKeepTrailingComments() throws {
        let source = """
        [[rule]] # table note
        app = 'one' # 日本語メモ
        title = 'Copy' # title note
        action = 'ignore' # English note

        """
        let untitled = try patch(source) { $0.rules[0].title = "" }
        XCTAssertTrue(untitled.contains("[[rule]] # table note\n"), untitled)
        XCTAssertTrue(untitled.contains("app = 'one' # 日本語メモ\n"), untitled)
        XCTAssertTrue(untitled.contains("# title note\n"), untitled)
        XCTAssertFalse(untitled.contains("title ="), untitled)
        XCTAssertTrue(untitled.contains("action = 'ignore' # English note\n"), untitled)

        let cleared = try patch(source) { $0.rules = [] }
        XCTAssertTrue(cleared.contains("# table note"), cleared)
        XCTAssertTrue(cleared.contains("# 日本語メモ"), cleared)
        XCTAssertTrue(cleared.contains("# title note"), cleared)
        XCTAssertTrue(cleared.contains("# English note"), cleared)
        XCTAssertFalse(cleared.contains("[[rule]]"), cleared)
        XCTAssertTrue(try Config.load(toml: cleared).rules.isEmpty)
    }

    func testStructuralEditsPreserveFinalNewlineStyle() throws {
        let rule = "[[rule]]\napp = 'one'\naction = 'ignore'"
        XCTAssertEqual(try patch("gap = 0\n" + rule) { $0.rules = [] }, "gap = 0")
        XCTAssertEqual(try patch("gap = 0\n" + rule + "\n") { $0.rules = [] }, "gap = 0\n")
        XCTAssertEqual(try patch("gap = 0\r\n" + rule.replacingOccurrences(of: "\n", with: "\r\n")) { $0.rules = [] }, "gap = 0")
        XCTAssertEqual(try patch("gap = 0\r\n" + rule.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") { $0.rules = [] }, "gap = 0\r\n")

        let commented = "gap = 0 # keep\n[[rule]] # table note\napp = 'one' # 日本語メモ\naction = 'ignore' # English note"
        XCTAssertEqual(try patch(commented) { $0.rules = [] }, "gap = 0 # keep\n# table note\n# 日本語メモ\n# English note")
        let commentedTail = "gap = 0 # keep\n[[rule]] # table note\napp = 'one' # 日本語メモ\naction = 'ignore'"
        XCTAssertEqual(try patch(commentedTail) { $0.rules = [] }, "gap = 0 # keep\n# table note\n# 日本語メモ")
        let untouched = "gap = 0\n" + rule
        let loaded = try Config.load(toml: untouched)
        XCTAssertEqual(try ConfigDocument.applying(loaded, to: untouched, replacing: loaded), untouched)
    }

    func testUnsupportedPatchLeavesTheSourceUntouched() throws {
        let source = "gaps = { inner-horizontal = 4 }\n"
        let previous = try Config.load(toml: source)
        var next = previous
        next.gap = 1
        XCTAssertThrowsError(try ConfigDocument.applying(next, to: source, replacing: previous))
        XCTAssertEqual(source, "gaps = { inner-horizontal = 4 }\n")
    }
}
