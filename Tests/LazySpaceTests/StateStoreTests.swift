import Foundation
import XCTest
import LayoutCore
@testable import LazySpace

final class StateStoreTests: XCTestCase {
    func testOldNamesDoNotDiscardOtherPersistedStateAndAreNotSavedAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var original = PersistedState()
        original.paused = true
        original.firstLaunchDone = true
        original.pausedSpaces = ["7"]
        original.floating = ["7": [WindowID(44)]]
        original.sessionKey = "same-session"
        store.save(original)
        let url = root.appendingPathComponent("state.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["spaceNames"] = ["old-uuid": ["name": "web", "setAt": "2026-10-02T00:00:00Z", "lastSeenAt": "2026-10-02T00:00:00Z"]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = store.load()
        XCTAssertTrue(loaded.paused)
        XCTAssertTrue(loaded.firstLaunchDone)
        XCTAssertEqual(loaded.pausedSpaces, ["7"])
        XCTAssertEqual(loaded.floating, original.floating)
        XCTAssertEqual(loaded.sessionKey, "same-session")
        store.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(saved["spaceNames"])
    }

    func testStateRoundTripsAndRequiresReleaseFields() throws {
        var previous = PersistedState()
        previous.paused = true
        previous.firstLaunchDone = true
        previous.sessionKey = "current-session"
        previous.layouts["7"] = Layout(root: .leaf(WindowID(1)))
        previous.floating["7"] = [WindowID(2)]
        previous.zoomed["7"] = WindowID(1)
        let encoded = try JSONEncoder().encode(previous)
        let state = try JSONDecoder().decode(PersistedState.self, from: encoded)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "sessionKey")
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: old)))
        XCTAssertTrue(state.paused)
        XCTAssertTrue(state.firstLaunchDone)
        XCTAssertEqual(state.sessionKey, "current-session")
        XCTAssertEqual(state.layouts["7"], previous.layouts["7"])
        XCTAssertEqual(state.floating["7"], [WindowID(2)])
        XCTAssertEqual(state.zoomed["7"], WindowID(1))
        XCTAssertEqual(state.sizeFacts, [])
    }

}
