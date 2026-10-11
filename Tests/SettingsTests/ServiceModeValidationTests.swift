import XCTest
@testable import Settings

final class ServiceModeValidationTests: XCTestCase {
    func testUndeclaredServiceIsAnErrorLikeAnyOtherMode() {
        for mode in ["service", "review"] {
            for key in ["none", "alt-shift-semicolon"] {
                XCTAssertThrowsError(try Config.load(toml: "[keys]\nmode-\(mode) = \"\(key)\"\n"))
            }
        }
    }

    func testDeclaredServiceUsesNormalModeValidation() throws {
        for entry in ["none", "alt-shift-semicolon"] {
            var notes: [String] = []
            let config = try Config.load(toml: """
            exec-on-mode-change = ["echo", "changed"]
            [keys]
            mode-service = "\(entry)"
            [mode.service]
            return-to-main = true
            [mode.service.keys]
            mode-main = "esc"
            join-left = "alt-shift-h"
            """, onNote: { notes.append($0) })
            XCTAssertTrue(notes.isEmpty, "\(notes)")
            XCTAssertEqual(config.keys["mode-service"], entry == "none" ? nil : Config.Key.parse(entry))
            XCTAssertEqual(config.modes["service"]?.returnToMain, true)
            XCTAssertEqual(config.keys(forMode: "service")?["mode-main"]?.configText, "esc")
            XCTAssertEqual(config.keys(forMode: "service")?["join-left"]?.configText, "alt-shift-h")
            XCTAssertEqual(config.execOnModeChange, ["echo", "changed"])
            XCTAssertEqual(try Config.load(toml: config.render()), config)
        }
        XCTAssertThrowsError(try Config.load(toml: "[mode.service]\n"))
        XCTAssertThrowsError(try Config.load(toml: "[keys]\nmode-review = \"none\"\n"))
        XCTAssertThrowsError(try Config.load(toml: """
        [mode.review.keys]
        mode-service = "s"
        """))
    }
}
