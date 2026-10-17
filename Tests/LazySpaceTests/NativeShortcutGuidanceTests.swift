import Copy
import MacSupport
import Settings
import XCTest
@testable import LazySpaceApp

final class NativeShortcutGuidanceTests: XCTestCase {
    private let left = SystemSpaceShortcut.usable(keyCode: 123, modifiers: ["ctrl"])
    private let right = SystemSpaceShortcut.usable(keyCode: 124, modifiers: ["ctrl"])
    private let ctrlLeft = Config.Key(modifiers: ["ctrl"], key: "left")
    private let ctrlRight = Config.Key(modifiers: ["ctrl"], key: "right")

    override func tearDown() { Copy.language = .english }

    private func warning(left: SystemSpaceShortcut? = nil, right: SystemSpaceShortcut? = nil, saved: [Config.Key] = [], draft: [Config.Key]? = nil,
                         paused: (left: Bool, right: Bool) = (false, false)) -> NativeShortcutStatus.Warning? {
        NativeShortcutStatus.warning(left: left ?? self.left, right: right ?? self.right, saved: saved, draft: draft ?? saved, paused: paused)
    }

    private func bothLanguages(_ body: (Language) throws -> Void) rethrows {
        for language in Language.allCases {
            Copy.language = language
            try body(language)
        }
    }

    private func assertNoDockOrSendBoundary(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for banned in ["Dock", "Sending only a window", "ウインドウだけを送る", "ウィンドウだけを送る"] {
            XCTAssertFalse(text.contains(banned), text, file: file, line: line)
        }
    }

    private let conflictAction = ["Choose different keys in the list above, or change the matching macOS shortcut.",
                                  "上の一覧で重複しているキーを別のキーに変更するか、macOS側の割り当てを変更してください。"]
    private let settingAction = ["Open Keyboard Settings, choose Keyboard Shortcuts… › Mission Control, then turn on “Move left a Space” and “Move right a Space” and assign keys to them.",
                                 "「キーボード設定を開く…」を押し、「キーボードショートカット…」の「Mission Control」で、「左の操作スペースに移動」と「右の操作スペースに移動」をオンにしてキーを割り当ててください。"]
    private let logOut = ["Logging out of your Mac and back in may resolve this.",
                          "Macからログアウトしてログインし直すと、解決することがあります。"]

    private func pick(_ pair: [String], _ language: Language) -> String { language == .english ? pair[0] : pair[1] }

    func testNothingIsShownWhenBothShortcutsAreUsableWithoutAConflict() {
        bothLanguages { _ in
            XCTAssertNil(warning())
            XCTAssertNil(warning(saved: [Config.Key(modifiers: ["alt"], key: "left")]))
        }
    }

    func testUnreadShortcutsShowNothing() {
        bothLanguages { _ in
            XCTAssertNil(warning(left: .unread))
            XCTAssertNil(warning(left: .unread, right: .unread))
            XCTAssertNil(warning(left: .unread, saved: [ctrlLeft]), "an unread shortcut cannot be compared with LazySpace keys")
        }
    }

    func testSavedConflictNamesTheKeysAndTheMacOSItem() throws {
        try bothLanguages { language in
            let right = try XCTUnwrap(warning(saved: [ctrlRight]))
            XCTAssertEqual(right.text, [
                pick(["With these settings, ⌃→ is assigned in LazySpace and to “Move right a Space”, so stepwise switching to the right won't work.",
                      "この設定では、⌃→がLazySpaceと「右の操作スペースに移動」の両方に割り当てられているため、操作スペースを右へ順に切り替えられません。"], language),
                pick(conflictAction, language),
            ].joined(separator: "\n"))
            XCTAssertTrue(right.showsKeyboardSettings)
            assertNoDockOrSendBoundary(right.text)
            let left = try XCTUnwrap(warning(saved: [ctrlLeft]))
            XCTAssertEqual(left.text, [
                pick(["With these settings, ⌃← is assigned in LazySpace and to “Move left a Space”, so stepwise switching to the left won't work.",
                      "この設定では、⌃←がLazySpaceと「左の操作スペースに移動」の両方に割り当てられているため、操作スペースを左へ順に切り替えられません。"], language),
                pick(conflictAction, language),
            ].joined(separator: "\n"))
        }
    }

    func testConflictAfterSavingIsDistinguishedFromASavedConflict() throws {
        try bothLanguages { language in
            let pending = try XCTUnwrap(warning(saved: [], draft: [ctrlRight]))
            XCTAssertEqual(pending.text, [
                pick(["⌃→ is also the macOS shortcut “Move right a Space”. After you save, stepwise switching to the right won't work.",
                      "⌃→はmacOSの「右の操作スペースに移動」と同じキーです。保存すると、操作スペースを右へ順に切り替えられなくなります。"], language),
                pick(conflictAction, language),
            ].joined(separator: "\n"))
            XCTAssertTrue(pending.showsKeyboardSettings)
            let leftPending = try XCTUnwrap(warning(saved: [], draft: [ctrlLeft]))
            XCTAssertTrue(leftPending.text.hasPrefix(pick(["⌃← is also the macOS shortcut “Move left a Space”. After you save, stepwise switching to the left won't work.",
                                                           "⌃←はmacOSの「左の操作スペースに移動」と同じキーです。保存すると、操作スペースを左へ順に切り替えられなくなります。"], language)),
                          leftPending.text)
        }
    }

    func testSavedConflictThatTheDraftRemovesSaysSavingResolvesIt() throws {
        try bothLanguages { language in
            let resolved = try XCTUnwrap(warning(saved: [ctrlLeft], draft: []))
            XCTAssertEqual(resolved.text, [
                pick(["With these settings, ⌃← is assigned in LazySpace and to “Move left a Space”, so stepwise switching to the left won't work.",
                      "この設定では、⌃←がLazySpaceと「左の操作スペースに移動」の両方に割り当てられているため、操作スペースを左へ順に切り替えられません。"], language),
                pick(["Saving removes ⌃←, so this conflict goes away.", "保存すると⌃←は外れるので、この重複は解消します。"], language),
                pick(conflictAction, language),
            ].joined(separator: "\n"))
            XCTAssertTrue(resolved.showsKeyboardSettings)
        }
    }

    func testShortcutThatIsOffNamesTheSettingAndOffersKeyboardSettings() throws {
        try bothLanguages { language in
            let off = try XCTUnwrap(warning(right: .disabled))
            XCTAssertEqual(off.text, [
                pick(["“Move right a Space” is off in macOS. Stepwise Space switching to the right won't work.",
                      "macOSの「右の操作スペースに移動」がオフです。操作スペースを右へ順に切り替えられません。"], language),
                pick(settingAction, language),
            ].joined(separator: "\n"))
            XCTAssertTrue(off.showsKeyboardSettings)
            assertNoDockOrSendBoundary(off.text)
        }
    }

    func testShortcutWithoutAUsableKeyKeepsTheReasonAndAddsTheConsequence() throws {
        try bothLanguages { language in
            let unusable = try XCTUnwrap(warning(left: .unusable(.unassigned)))
            let lead = SpaceControl.refusalLead(.unassigned, right: false)
            XCTAssertEqual(unusable.text, [
                lead + Copy.sentenceSeparator + pick(["Stepwise Space switching to the left won't work.", "操作スペースを左へ順に切り替えられません。"], language),
                pick(settingAction, language),
            ].joined(separator: "\n"))
            XCTAssertTrue(unusable.showsKeyboardSettings)
            assertNoDockOrSendBoundary(unusable.text)
        }
    }

    func testDifferentProblemsOnEachSideGetOneLineEachAndOneActionPerKindOfFix() throws {
        Copy.language = .english
        let mixed = try XCTUnwrap(warning(right: .disabled, saved: [ctrlLeft]))
        XCTAssertEqual(mixed.text.components(separatedBy: "\n"), [
            "With these settings, ⌃← is assigned in LazySpace and to “Move left a Space”, so stepwise switching to the left won't work.",
            "“Move right a Space” is off in macOS. Stepwise Space switching to the right won't work.",
            conflictAction[0],
            settingAction[0],
        ])
        XCTAssertTrue(mixed.showsKeyboardSettings)
    }

    func testNoResponseSuggestsLoggingOutWithoutKeyboardSettings() throws {
        try bothLanguages { language in
            let leftLine = pick(["macOS is not responding to “Move left a Space”, so stepwise Space switching to the left won't work.",
                                 "macOSが「左の操作スペースに移動」に応答しないため、操作スペースを左へ順に切り替えられません。"], language)
            let rightLine = pick(["macOS is not responding to “Move right a Space”, so stepwise Space switching to the right won't work.",
                                  "macOSが「右の操作スペースに移動」に応答しないため、操作スペースを右へ順に切り替えられません。"], language)
            let onlyLeft = try XCTUnwrap(warning(paused: (true, false)))
            XCTAssertEqual(onlyLeft.text, [leftLine, pick(logOut, language)].joined(separator: "\n"))
            XCTAssertFalse(onlyLeft.showsKeyboardSettings)
            let onlyRight = try XCTUnwrap(warning(paused: (false, true)))
            XCTAssertEqual(onlyRight.text, [rightLine, pick(logOut, language)].joined(separator: "\n"))
            XCTAssertFalse(onlyRight.showsKeyboardSettings)
            let both = try XCTUnwrap(warning(paused: (true, true)))
            XCTAssertEqual(both.text, [leftLine, rightLine, pick(logOut, language)].joined(separator: "\n"))
            XCTAssertFalse(both.showsKeyboardSettings)
            for text in [onlyLeft.text, onlyRight.text, both.text] { assertNoDockOrSendBoundary(text) }
        }
    }

    func testConfigurationProblemsHideTheNoResponseWarning() throws {
        Copy.language = .english
        let conflict = try XCTUnwrap(warning(saved: [ctrlRight], paused: (false, true)))
        XCTAssertFalse(conflict.text.contains("not responding"), conflict.text)
        XCTAssertFalse(conflict.text.contains("Logging out"), conflict.text)
        XCTAssertTrue(conflict.showsKeyboardSettings)
        let off = try XCTUnwrap(warning(left: .disabled, paused: (false, true)))
        XCTAssertFalse(off.text.contains("not responding"), off.text)
        XCTAssertTrue(off.showsKeyboardSettings)
    }
}
