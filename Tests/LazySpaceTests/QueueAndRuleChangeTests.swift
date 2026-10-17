import XCTest
import LayoutCore
import Operations
@testable import LazySpaceApp

final class QueueAndRuleChangeTests: XCTestCase {
    func testRemovingIgnoreRuleReconsidersUnplacedWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        let s = CoordinatorSystem()
        s.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        let configURL = root.appendingPathComponent("config.toml")
        let c = Coordinator(system: s, store: store, configURL: configURL, takeCensus: s.census, takeOverview: { nil })
        c.limits.settleDelay = 0
        try "[[rule]]\napp = \"test\"\naction = \"ignore\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = c.reloadConfig(source: "test")
        XCTAssertFalse(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        _ = c.reloadConfig(source: "test")
        XCTAssertNil(c.config.tilingExclusionReason(bundleID: "test", title: ""))
        XCTAssertTrue(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") }, "Removing ignore must allow the next observation to enroll the unchanged window")
        let done = expectation(description: "queue drained")
        c.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testRemovingTitleIgnoreRuleReconsidersUnplacedWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        let s = CoordinatorSystem()
        s.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        s.titles[WindowID(3)] = "Draft"
        let configURL = root.appendingPathComponent("config.toml")
        let c = Coordinator(system: s, store: store, configURL: configURL, takeCensus: s.census, takeOverview: { nil })
        c.limits.settleDelay = 0
        try "[[rule]]\napp = \"test\"\ntitle = \"Draft\"\naction = \"ignore\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = c.reloadConfig(source: "test")
        XCTAssertFalse(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        _ = c.reloadConfig(source: "test")
        XCTAssertNil(c.config.tilingExclusionReason(bundleID: "test", title: "Draft"))
        XCTAssertTrue(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        let done = expectation(description: "queue drained")
        c.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testQueuedCloseDoesNotRetargetToAnotherSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        state.layouts["8"] = Planner.rowLayout([WindowID(3), WindowID(4)], rows: 1)
        store.save(state)
        let s = CoordinatorSystem()
        let c = Coordinator(system: s, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: s.census, takeOverview: { nil })
        c.limits.settleDelay = 0
        c.operationsQueue.suspend()
        _ = c.runFocus(WindowID(2), source: "test")
        let accepted = c.edit(.close, source: "hotkey close")
        guard case .started(let ticket) = accepted else {
            c.operationsQueue.resume()
            return XCTFail("Close was not queued")
        }
        s.space = 8
        s.focused = WindowID(3)
        s.frames = [WindowID(3): CGRect(x: 0, y: 0, width: 960, height: 1080), WindowID(4): CGRect(x: 960, y: 0, width: 960, height: 1080)]
        c.operationsQueue.resume()
        for _ in 0..<4 {
            let done = expectation(description: "queue drained")
            c.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(s.closeCalls, 0, "A close requested on Space 7 must not close Space 8's focused window")
        XCTAssertNotNil(s.frames[WindowID(3)])
        XCTAssertNotEqual(c.result(id: ticket)?.outcome, .complete)
        XCTAssertEqual(c.result(id: ticket)?.message, "Not run because the current Space changed.")
    }

    func testSameSpaceQueuedFocusContinuesAndResizeAccumulates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        let s = CoordinatorSystem()
        s.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080),
            WindowID(3): CGRect(x: 1280, y: 0, width: 640, height: 1080),
        ]
        s.focused = WindowID(1)
        let c = Coordinator(system: s, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: s.census, takeOverview: { nil })
        c.limits.settleDelay = 0
        c.operationsQueue.suspend()
        _ = c.runFocus(WindowID(2), source: "test")
        guard case .started = c.edit(.focus(.right), source: "hotkey focus") else {
            c.operationsQueue.resume()
            return XCTFail("focus was not queued")
        }
        guard case .started(let resize) = c.edit(.resize(.horizontal, 0.1), source: "hotkey resize") else {
            c.operationsQueue.resume()
            return XCTFail("resize was not queued")
        }
        guard case .started(let again) = c.edit(.resize(.horizontal, 0.1), source: "hotkey resize") else {
            c.operationsQueue.resume()
            return XCTFail("second resize was not queued")
        }
        XCTAssertEqual(resize, again, "resizes on the same Space add up")
        c.operationsQueue.resume()
        for _ in 0..<6 {
            let done = expectation(description: "queue drained")
            c.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(s.focused, WindowID(3), "a repeated focus moves on from the previous focus result")
        XCTAssertNotNil(c.state.layouts["7"])
    }
}
