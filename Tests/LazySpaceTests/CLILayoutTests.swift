import CoreGraphics
import Copy
import Foundation
import LayoutCore
@testable import MacSupport
@testable import Operations
import XCTest
@testable import LazySpaceApp

/// The CLI's tables in every language: columns that cut their text (`CLI.padded`) are wide enough for every translation,
/// and English and Japanese read exactly as before.
final class CLILayoutTests: XCTestCase {
    override func tearDown() {
        Copy.language = .english
        super.tearDown()
    }

    static func overview() -> SpaceOverview {
        SpaceOverview(spaces: [
            .init(spaceID: 1, type: 0, isCurrent: true, windowIDs: [WindowID(1), WindowID(2)]),
            .init(spaceID: 117, type: 4, isCurrent: false, windowIDs: []),
            .init(spaceID: 9, type: 2, isCurrent: false, windowIDs: []),
        ], unknown: [])
    }

    static func inspection() -> Inspection {
        func window(_ id: UInt32, _ app: String, _ kind: ObservedWindow.Kind = .standard) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: app, frame: CGRect(x: 0, y: 25, width: 800, height: 600), membership: .current, kind: kind, detail: "")
        }
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: CGRect(x: 0, y: 25, width: 1440, height: 875), windows: [],
                            spaceObservationAvailable: true, unobservedApps: ["com.example.slow"])
        return Inspection(snapshot: snap, targets: [window(1, "com.apple.finder")],
                          excluded: [Exclusion(window: window(2, "com.apple.Safari", .nonNormalLayer), reason: TargetSelection.exclusionReason(window(2, "x", .nonNormalLayer)) ?? "")],
                          takenAt: Date(timeIntervalSince1970: 0))
    }

    static func status() -> AppStatus {
        AppStatus(availability: .manualOnly, availabilityReason: "Manual arrangement only", manualAvailable: true, manualReason: "Available", autoAvailable: false, autoReason: "Not checked",
                  currentSpaceManaged: false, trusted: true, spaceObservation: true, inputObservation: "none", paused: false, progress: .idle, progressText: "",
                  waiting: [], floating: [], zoomed: nil, lastRefusal: nil, configPath: "/tmp/config.toml", configError: "line 3: bad",
                  focusedWindow: nil, lastResult: nil, version: "0.2.0", mode: "main", modes: ["main", "service"], loginItem: "Off", loginItemEnabled: false)
    }

    static func outputs() -> [String: String] {
        let names = ["com.apple.finder": "Finder", "com.apple.Safari": "Safari", "com.example.slow": "Slow"]
        return [
            "spaces": CLI.spacesText(overview()),
            "windows": CLI.windowsText(inspection(), name: { names[$0] ?? $0 }),
            "status": CLI.statusText(status()),
        ]
    }

    /// Output before the nine-language change, for these fixtures.
    static let before: [String: [String: String]] = [
        "en": [
            "spaces": "     ID       Type           Windows\n* 1. 1        Standard       2\n   — 117      Full Screen    —\n   — 9        Other          —\n* = current Space. Only ordinary desktops are numbered, in macOS order on each display. Full-screen / Split View spaces are unnumbered.",
            "status": "LazySpace 0.2.0\nActivity:               Idle\nStatus:                 Manual Arrangement Only\nThis Space:             Manual Arrangement Only\nDevice Control and Data Access: Granted\nManual arrangement:     Available\nAutomatic arrangement:  Unavailable — Not checked\nMode:                   main (available modes: main, service)\nOpen at Login:          Off\nWaiting windows: 0\nConfiguration:          /tmp/config.toml\n  Error: line 3: bad\nFixed-size windows:     ",
            "windows": "ID      App                         Size and Position     Eligibility\nw1      Finder                      800×600 @0,25         Eligible\nw2      Safari                      800×600 @0,25         Excluded: Not a standard window\n-       Slow                        ?                     No Response: could not read this app's windows before the timeout\nEligible 1 / Excluded 1 / No response 1",
        ],
        "ja": [
            "spaces": "     ID       種類           ウインドウ数\n* 1. 1        通常           2\n   — 117      フルスクリーン —\n   — 9        その他         —\n* = 現在の操作スペース。通常のデスクトップだけをディスプレイごとにmacOSの並び順で数えます。フルスクリーン・Split Viewに番号は付きません。",
            "status": "LazySpace 0.2.0\n処理:                   待機中\n状態:                   手動整列のみ\nこの操作スペース:       手動整列のみ\nデバイスの制御とデータへのアクセス: 許可済み\n手動整列:               利用可能\n自動整列:               利用不可 — Not checked\nモード:                 main（使えるモード: main、service）\nログイン時に開く:       Off\n待機中のウインドウ: 0\n設定:                   /tmp/config.toml\n  誤り: line 3: bad\n大きさが固定のウインドウ: ",
            "windows": "ID      アプリ                      現在の位置・サイズ    整列対象\nw1      Finder                      800×600 @0,25         整列対象\nw2      Safari                      800×600 @0,25         対象外：通常のウインドウではない\n-       Slow                        ?                     応答なし: 期限内にウインドウの一覧を読めませんでした\n整列対象1 / 対象外1 / 応答なし1",
        ],
    ]

    func testEnglishAndJapaneseReadAsBefore() {
        for language in [Language.english, .japanese] {
            Copy.language = language
            let now = Self.outputs()
            for (name, text) in Self.before[language.rawValue] ?? [:] {
                XCTAssertEqual(now[name], text, "\(language.rawValue) \(name)")
            }
        }
    }

    /// Every row of list-spaces puts the window count in the same column, in every language.
    func testSpaceKindsFitTheirColumnInEveryLanguage() {
        for language in Language.allCases {
            Copy.language = language
            let rows = Array(CLI.spacesText(Self.overview()).components(separatedBy: "\n").prefix(4))
            let heading = L(.cliWindowCountHeading)
            let starts = rows.enumerated().map { index, row -> Int in
                let last = index == 0 ? row.range(of: heading) : row.range(of: #"(\d+|—)$"#, options: .regularExpression)
                return CLI.displayWidth(String(row[..<(last?.lowerBound ?? row.endIndex)]))
            }
            XCTAssertEqual(Set(starts).count, 1, "\(language.rawValue): \(Array(rows))")
            for kind in [CLI.spaceKindLabel(0), CLI.spaceKindLabel(4), CLI.spaceKindLabel(nil), L(.cliType)] {
                XCTAssertTrue(rows.contains { $0.contains(kind) }, "\(language.rawValue): \(kind) is cut")
            }
        }
    }

    /// list-windows cuts its App and Size columns at 28 and 22; their headings keep a space before the next column.
    func testWindowListHeadingsFitInEveryLanguage() {
        for language in Language.allCases {
            Copy.language = language
            XCTAssertLessThan(CLI.displayWidth(L(.cliApp)), 28, language.rawValue)
            XCTAssertLessThan(CLI.displayWidth(L(.cliSizeAndPosition)), 22, language.rawValue)
            let heading = CLI.windowsText(Self.inspection(), name: { $0 }).components(separatedBy: "\n")[0]
            XCTAssertTrue(heading.contains(L(.cliApp)) && heading.contains(L(.cliSizeAndPosition)), "\(language.rawValue): \(heading)")
        }
    }

    func testPrintOutputs() throws {
        guard ProcessInfo.processInfo.environment["LAZYSPACE_PRINT_CLI"] != nil else { throw XCTSkip("prints only on request") }
        var all: [String: [String: String]] = [:]
        for language in Language.allCases {
            Copy.language = language
            all[language.rawValue] = Self.outputs()
        }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        print("CLI-OUTPUTS-BEGIN\n" + String(decoding: data, as: UTF8.self) + "\nCLI-OUTPUTS-END")
    }
}
