import AppKit
import Copy
import XCTest
import Settings
@testable import LazySpaceApp

/// How the shortcut list groups the current mode's shortcuts, without the panel.
final class CheatsheetLayoutTests: XCTestCase {
    private let main = Config.mainModeName

    override func setUp() {
        super.setUp()
        Copy.language = .japanese
    }

    override func tearDown() {
        Copy.language = .english
        super.tearDown()
    }

    private func headings(_ sections: [CheatsheetLayout.Section]) -> [String] { sections.map(\.heading) }

    func testTheDefaultsGroupByModifierSet() {
        let sections = CheatsheetLayout.sections(Config(), mode: main)
        XCTAssertEqual(headings(sections), ["⌥", "⌥⇧", "⌃⌥", "⌥⌘"])
        XCTAssertEqual(sections.map(\.rows.count), [10, 6, 1, 4])
        XCTAssertEqual(sections[0].rows.first, CheatsheetLayout.Row(keys: "H\u{2002}J\u{2002}K\u{2002}L", label: L(.keyCheatsheetFocusEachDirection), commands: 4))
        XCTAssertTrue(sections[0].rows.contains(CheatsheetLayout.Row(keys: Copy.numberRange("1", "9"),
                                                                     label: L(.editCommandsSwitchTo(Copy.desktops(1, 9))), commands: 9)),
                      "desktops after the window operations, in command order")
        XCTAssertEqual(sections[2].rows, [CheatsheetLayout.Row(keys: "H\u{2002}J\u{2002}K\u{2002}L", label: L(.keyCheatsheetSwapEachDirection), commands: 4)])
    }

    func testEveryShortcutAppearsExactlyOnce() throws {
        let config = try Config.load(toml: """
        [keys]
        balance = "alt-shift-q"
        join-left = "ctrl-alt-shift-h"
        """)
        let sections = CheatsheetLayout.sections(config, mode: main)
        XCTAssertEqual(sections.flatMap(\.rows).map(\.commands).reduce(0, +), config.keys.count)
        XCTAssertTrue(sections.contains { $0.heading == "⌃⌥⇧" && $0.rows.count == 1 }, "a set of its own")
    }

    /// A run is one row only when all of it is bound in one set; otherwise each key has its own row.
    func testARunCollapsesOnlyWhenWhollyBoundInOneSet() throws {
        let config = try Config.load(toml: """
        [keys]
        focus-right = "ctrl-l"
        """)
        let alt = try XCTUnwrap(CheatsheetLayout.sections(config, mode: main).first { $0.heading == "⌥" })
        XCTAssertFalse(alt.rows.contains { $0.commands == 4 && $0.label == L(.keyCheatsheetFocusEachDirection) })
        XCTAssertEqual(Array(alt.rows.prefix(3)).map(\.keys), ["H", "J", "K"], "left, down, up in command order")
    }

    func testDesktopsCollapseOnlyWhereDesktopNIsOnKeyN() throws {
        let config = try Config.load(toml: """
        [keys]
        space-5 = "alt-0"
        """)
        let alt = try XCTUnwrap(CheatsheetLayout.sections(config, mode: main).first { $0.heading == "⌥" })
        XCTAssertTrue(alt.rows.contains { $0.keys == Copy.numberRange("1", "4") && $0.commands == 4 })
        XCTAssertTrue(alt.rows.contains { $0.keys == Copy.numberRange("6", "9") && $0.commands == 4 })
        XCTAssertTrue(alt.rows.contains { $0.keys == "0" && $0.label == L(.editCommandsSwitchTo(Copy.desktop(5))) })
    }

    func testSendingRowsFollowTheMoveSetting() throws {
        let send = try XCTUnwrap(CheatsheetLayout.sections(Config(), mode: main).first { $0.heading == "⌥⇧" })
        XCTAssertTrue(send.rows.contains { $0.label == L(.editCommandsSendWindowTo(Copy.desktops(1, 9))) })
        var follow = Config()
        follow.followMovedWindow = true
        let moved = try XCTUnwrap(CheatsheetLayout.sections(follow, mode: main).first { $0.heading == "⌥⇧" })
        XCTAssertTrue(moved.rows.contains { $0.label == L(.editCommandsMoveWindowToAndFollow(Copy.desktops(1, 9))) })
    }

    /// Exactly the mode's shortcuts, each once, in command order, with their own labels: no row stands in for another.
    func testEveryRowIsItsOwnShortcutInCommandOrder() throws {
        let config = try Config.load(toml: """
        [mode.demo.keys]
        mode-main = "esc"
        space-3 = "3"
        join-left = "alt-h"
        move-to-space-1 = "alt-1"
        move-to-space-follow-2 = "alt-2"
        """)
        func label(_ command: String) -> String {
            guard case .edit(let edit)? = HotkeyBinding.action(forCommand: command) else {
                return HotkeyBinding(keyCode: 0, modifiers: 0, action: HotkeyBinding.action(forCommand: command)!, display: "").label
            }
            return HotkeyBinding(keyCode: 0, modifiers: 0, action: .edit(edit.following(config.followMovedWindow)), display: "").label
        }
        let sections = CheatsheetLayout.sections(config, mode: "demo")
        XCTAssertEqual(sections.map(\.heading), ["", "⌥"])
        XCTAssertEqual(sections[0].rows.map { [$0.keys, $0.label] }, [["⎋", label("mode-main")], ["3", label("space-3")]])
        XCTAssertEqual(sections[1].rows.map { [$0.keys, $0.label] },
                       [["H", label("join-left")], ["1", label("move-to-space-1")], ["2", label("move-to-space-follow-2")]])
        XCTAssertNotEqual(label("move-to-space-1"), label("move-to-space-follow-2"), "send and move-and-follow stay apart")
    }

    /// Fewer than three desktops in a row stay separate rows.
    func testTwoDesktopsInARowStaySeparate() throws {
        let config = try Config.load(toml: """
        [keys]
        space-3 = "alt-0"
        """)
        let alt = try XCTUnwrap(CheatsheetLayout.sections(config, mode: main).first { $0.heading == "⌥" })
        XCTAssertTrue(alt.rows.contains { $0.keys == "1" && $0.commands == 1 })
        XCTAssertTrue(alt.rows.contains { $0.keys == "2" && $0.commands == 1 })
        XCTAssertTrue(alt.rows.contains { $0.keys == Copy.numberRange("4", "9") && $0.commands == 6 })
    }

    /// With ⌥ held, ⌥'s rows are drawn in the label color and the other sets' in the secondary color; with no set held, all in the label color.
    @MainActor
    func testTheHeldSetIsDrawnDarker() throws {
        func color(of text: String, held: UInt32) throws -> NSColor? {
            let (root, _) = try XCTUnwrap(KeyCheatsheet.content(config: Config(), mode: main, held: held, visible: NSRect(x: 0, y: 0, width: 1470, height: 918)))
            return TextFitTests.descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }?.textColor
        }
        XCTAssertEqual(try color(of: L(.keyCheatsheetFocusEachDirection), held: 0x0800), .labelColor)
        XCTAssertEqual(try color(of: L(.keyCheatsheetSwapEachDirection), held: 0x0800), .secondaryLabelColor)
        XCTAssertEqual(try color(of: L(.keyCheatsheetSwapEachDirection), held: 0x1800), .labelColor, "⌃⌥ held")
        XCTAssertEqual(try color(of: L(.keyCheatsheetFocusEachDirection), held: 0x0100), .labelColor, "no set matches: nothing is dimmed")
    }

    /// A mode may bind keys without modifiers; they come first, without a heading.
    func testAModesBareKeysComeFirstWithoutAHeading() throws {
        let config = try Config.load(toml: """
        [mode.resize.keys]
        focus-left = "h"
        balance = "alt-b"
        """)
        let sections = CheatsheetLayout.sections(config, mode: "resize")
        XCTAssertEqual(headings(sections), ["", "⌥"])
        XCTAssertEqual(sections[0].rows.map(\.keys), ["H"])
    }
}
