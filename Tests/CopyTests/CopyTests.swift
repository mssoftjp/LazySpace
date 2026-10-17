import XCTest
@testable import Copy

final class CopyTests: XCTestCase {
    override func tearDown() {
        Copy.language = .english
        super.tearDown()
    }

    func testEnglishIsTheDefaultForTests() {
        XCTAssertEqual(Copy.language, .english)
        XCTAssertEqual(L("Arrange", "整列"), "Arrange")
    }

    func testJapaneseIsSelectedExplicitly() {
        Copy.language = .japanese
        XCTAssertEqual(L("Arrange", "整列"), "整列")
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
