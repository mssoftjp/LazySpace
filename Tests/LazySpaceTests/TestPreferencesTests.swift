import XCTest

/// Test preferences stay in a temporary folder and leave nothing in ~/Library/Preferences.
final class TestPreferencesTests: XCTestCase {
    func testPreferencesStayOutOfTheUsersPreferencesFolder() throws {
        let preferences = TestPreferences("TestPreferencesTests")
        preferences.defaults.set("value", forKey: "key")
        XCTAssertEqual(preferences.defaults.string(forKey: "key"), "value")
        XCTAssertTrue(preferences.defaults.synchronize())
        preferences.remove()
        Thread.sleep(forTimeInterval: 0.5)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let unique = preferences.folder.lastPathComponent
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(unique) }
        XCTAssertEqual(left, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.folder.path))
    }
}
