import XCTest
@testable import Copy

final class CopyTests: XCTestCase {
    override func tearDown() {
        Copy.language = .english
        super.tearDown()
    }

    func testEnglishIsTheDefaultForTests() {
        XCTAssertEqual(Copy.language, .english)
        XCTAssertEqual(MacItem.openAtLogin, "Open at Login")
    }

    func testJapaneseIsSelectedExplicitly() {
        Copy.language = .japanese
        XCTAssertEqual(MacItem.openAtLogin, "ログイン時に開く")
    }

    func testSeparatorsFollowTheLanguage() {
        XCTAssertEqual([Copy.listSeparator, Copy.clauseSeparator], [", ", "; "])
        Copy.language = .japanese
        XCTAssertEqual([Copy.listSeparator, Copy.clauseSeparator], ["、", "、"])
    }

    /// macOS's own matching: the first preferred language LazySpace ships, English when there is none.
    func testSystemLanguageIsTheFirstShippedPreferredLanguage() {
        XCTAssertEqual(Copy.systemLanguage(preferred: ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(Copy.systemLanguage(preferred: ["en-US", "ja-JP"]), .english)
        XCTAssertEqual(Copy.systemLanguage(preferred: ["fr-FR", "ja-JP"]), .japanese)
        XCTAssertEqual(Copy.systemLanguage(preferred: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(Copy.systemLanguage(preferred: []), .english)
    }

    func testEachLanguageIsNamedInItself() {
        XCTAssertEqual(Language.english.endonym, "English")
        XCTAssertEqual(Language.japanese.endonym, "日本語")
        XCTAssertEqual(Language.japanese.locale.identifier, "ja")
    }

    func testMacItemNamesMatchMacOSInBothLanguages() {
        XCTAssertEqual(MacItem.moveSpace(right: false), "Move left a Space")
        XCTAssertEqual(MacItem.moveSpace(right: true), "Move right a Space")
        XCTAssertEqual(MacItem.switchToDesktop(3), "Switch to Desktop 3")
        XCTAssertEqual(MacItem.switchToDesktop(10), "Switch to Desktop 10")
        XCTAssertEqual(MacItem.switchToDesktop(nil), "Switch to Desktop N")
        Copy.language = .japanese
        XCTAssertEqual(MacItem.moveSpace(right: false), "左の操作スペースに移動")
        XCTAssertEqual(MacItem.moveSpace(right: true), "右の操作スペースに移動")
        XCTAssertEqual(MacItem.switchToDesktop(3), "デスクトップ3へ切り替え")
        XCTAssertEqual(MacItem.switchToDesktop(10), "デスクトップ10へ切り替え")
        XCTAssertEqual(MacItem.switchToDesktop(nil), "デスクトップNへ切り替え")
    }

    /// macOS item names match macOS's own shortcut table in every shipped language. The table is macOS 27's, read without privileges.
    func testMacItemNamesMatchTheMacOSShortcutTable() throws {
        let url = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources/DefaultShortcutsTable.loctable")
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27, let data = try? Data(contentsOf: url),
              let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XCTSkip("needs macOS 27's DefaultShortcutsTable.loctable")
        }
        for language in Language.allCases {
            let names = try XCTUnwrap(table[language.rawValue] as? [String: Any], language.rawValue)
            Copy.language = language
            XCTAssertEqual(MacItem.moveSpace(right: true), names["Move to next space"] as? String, language.rawValue)
            XCTAssertEqual(MacItem.moveSpace(right: false), names["Move to previous space"] as? String, language.rawValue)
            XCTAssertEqual(MacItem.switchToDesktop(3), names["Switch to Space 3"] as? String, language.rawValue)
        }
    }

    func testNumberedDesktopLabelAndSentenceSeparatorFollowTheLanguage() {
        XCTAssertEqual(Copy.desktop(3), "Desktop 3")
        XCTAssertEqual(Copy.desktop(10), "Desktop 10")
        XCTAssertEqual(Copy.sentenceSeparator, " ")
        Copy.language = .japanese
        XCTAssertEqual(Copy.desktop(3), "デスクトップ3")
        XCTAssertEqual(Copy.desktop(10), "デスクトップ10")
        XCTAssertEqual(Copy.sentenceSeparator, "")
    }
}
