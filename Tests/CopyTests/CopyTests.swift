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

    /// The setting and LAZYSPACE_LANGUAGE match a code without regard to case, so mixed-case codes such as zh-Hans are not lost.
    func testLanguageCodesMatchWithoutRegardToCase() {
        XCTAssertEqual(Language.matching("JA"), .japanese)
        XCTAssertEqual(Language.matching("En"), .english)
        XCTAssertNil(Language.matching("fr-CA"))
        XCTAssertNil(Language.matching("system"))
        for language in Language.allCases {
            XCTAssertEqual(Language.matching(language.rawValue.lowercased()), language)
            XCTAssertEqual(Language.matching(language.rawValue.uppercased()), language)
        }
        Copy.apply(setting: "JA")
        XCTAssertEqual(Copy.language, .japanese)
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

    static let glossary: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("script/catalog/glossary.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    /// A value from one of macOS's own tables: a .loctable keyed by language, or the Dock's per-language .strings (`<lproj>`).
    static func macOSValue(_ path: String, _ key: String, _ language: Language) -> String? {
        let codes = glossary["tableCodes"] as? [String: String] ?? [:]
        let code = codes[language.rawValue] ?? language.rawValue
        guard let data = FileManager.default.contents(atPath: path.replacingOccurrences(of: "<lproj>", with: code)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return path.contains("<lproj>") ? plist[key] as? String : (plist[code] as? [String: Any])?[key] as? String
    }

    /// Every macOS name LazySpace writes reads as macOS 27 shows it, in every shipped language, compared with macOS's own
    /// tables (not with a copy). The glossary's copy must match too, because translators and the wording tests use it.
    func testMacOSNamesMatchMacOSInEveryLanguage() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { throw XCTSkip("the names are macOS 27's") }
        let sources = try XCTUnwrap(Self.glossary["macosSources"] as? [String: [String]])
        let names = try XCTUnwrap(Self.glossary["macosNames"] as? [String: [String: String]])
        for language in Language.allCases {
            Copy.language = language
            func table(_ name: String) -> String? { sources[name].flatMap { Self.macOSValue($0[0], $0[1], language) } }
            for name in sources.keys.sorted() {
                XCTAssertNotNil(table(name), "\(language.rawValue): no macOS table for \(name)")
                XCTAssertEqual(names[name]?[language.rawValue], table(name), "\(language.rawValue): glossary \(name)")
            }
            let lang = language.rawValue
            XCTAssertEqual(MacItem.moveSpace(right: true), table("moveRightASpace"), lang)
            XCTAssertEqual(MacItem.moveSpace(right: false), table("moveLeftASpace"), lang)
            XCTAssertEqual(MacItem.stageManager, table("stageManager"), lang)
            XCTAssertEqual(MacItem.openAtLogin, table("openAtLogin"), lang)
            XCTAssertEqual(MacItem.loginItems(osMajor: 15), table("loginItemsExtensions"), lang)
            XCTAssertEqual(MacItem.separateSpaces, table("separateSpaces"), lang)
            XCTAssertEqual(AccessPane.name(osMajor: 27), table("deviceControlAndDataAccess"), lang)
            XCTAssertEqual(AccessPane.name(osMajor: 26), table("accessibility"), lang)
            for number in [1, 3, 10] {
                XCTAssertEqual(Copy.desktop(number), table("desktop")?.replacingOccurrences(of: "%@", with: String(number)), lang)
            }
            // Korean writes (으)로 after any number, Apple's form after an unknown value; macOS's table varies it by the number.
            let shortcuts = try XCTUnwrap(sources["switchToDesktop3"]?.first)
            for number in 1...16 {
                var expected = Self.macOSValue(shortcuts, "Switch to Space \(number)", language)
                if language.rawValue == "ko" { expected = expected?.replacingOccurrences(of: #"(\d+)(으로|로)"#, with: "$1(으)로", options: .regularExpression) }
                XCTAssertEqual(MacItem.switchToDesktop(number), expected, "\(lang) \(number)")
            }
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
