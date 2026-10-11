import XCTest
import Foundation
import CoreFoundation
import LayoutCore
import MacSupport
import Operations
import Settings
@testable import LazySpace

/// Retry limits, title rules, input availability, rendered commands, and light focus across Space changes.
final class CoordinatorRegressionTests: XCTestCase {
    private func make() -> (Coordinator, CoordinatorSystem, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = ["7": Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)]
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store,
            configURL: root.appendingPathComponent("config.toml"),
            takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        return (coordinator, system, root)
    }

    private func drain(_ c: Coordinator) {
        let done = expectation(description: "operations drained")
        c.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// No history of operations is written: the last result stays in memory for `status`, and only the layouts are saved.
    func testOperationsKeepNoHistoryOnDisk() throws {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        s.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        XCTAssertTrue(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        drain(c)
        XCTAssertNotNil(c.status().lastResult)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["state.json"])
        let saved = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("lastResult"), saved)
    }

    func testFocusedFailingWindowStillHasRetryLimit() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        s.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        s.focused = WindowID(3)
        s.timeOutWrites = true
        var starts = 0
        for _ in 0..<10 {
            if c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") } { starts += 1 }
            drain(c)
        }
        XCTAssertLessThanOrEqual(starts, 2)
    }

    func testTitleRuleReevaluatesAfterTitleChanges() throws {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(3)
        s.frames[id] = CGRect(x: 300, y: 200, width: 500, height: 400)
        s.titles[id] = "Loading"
        try "[[rule]]\napp = \"test\"\ntitle = \"^Loading$\"\naction = \"ignore\"\n".write(to: c.configURL, atomically: true, encoding: .utf8)
        _ = c.reloadConfig(source: "test")
        XCTAssertFalse(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        s.titles[id] = "Document"
        let before = s.snapshotCount
        var starts = 0
        for _ in 0..<10 {
            if c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") } { starts += 1 }
            drain(c)
        }
        XCTAssertTrue(c.state.layouts["7"]?.windowIDs.contains(id) == true)
    }

    func testInputUnavailableDisablesAutomaticArrangement() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        s.inputAvailable = false
        XCTAssertFalse(c.status().autoAvailable)
        s.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        let started = c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") }
        drain(c)
        XCTAssertEqual(s.writes, 0)
    }

    func testRenderedCommandWithQuotedHashRoundTrips() throws {
        var config = Config()
        config.execOnSpaceChange = ["/bin/sh", "-c", "printf \"#tag\""]
        let text = config.render()
        XCTAssertEqual(try Config.load(toml: text).execOnSpaceChange, config.execOnSpaceChange)
    }

    func testLightFocusCancelsAfterSpaceChange() {
        let s = RegressionFocusSystem()
        let op = FocusOperation(system: s, control: OperationControl(), target: WindowID(1))
        s.space = 8
        // An all-Spaces window remains eligible on the destination Space too.
        s.member = .allSpaces
        let result = op.run()
        XCTAssertEqual(s.focusCalls, 0)
        XCTAssertEqual(result.stopReason, .spaceChanged)
    }

    func testLightFocusDoesNotReportSuccessBeforeFocusActuallyChanges() {
        let s = RegressionFocusSystem()
        let op = FocusOperation(system: s, control: OperationControl(), target: WindowID(1))
        let result = op.run()
        XCTAssertNotEqual(result.outcome, .complete)
    }

}

private final class RegressionFocusSystem: WindowSystem {
    var space: UInt64? = 7
    var member: ObservedWindow.Membership = .current
    var inputActivityCount: UInt64 = 0
    var focusCalls = 0
    func currentSpaceID() -> UInt64? { space }
    func membershipOf(_ id: WindowID) -> ObservedWindow.Membership? { member }
    func focusedWindowID() -> WindowID? { WindowID(2) }
    func snapshot() -> Snapshot {
        Snapshot(trusted: true, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: true)
    }
    func readFrame(_ id: WindowID) -> FrameRead { .gone }
    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected("unused") }
    func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected("unused") }
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult {
        if let activated { DispatchQueue.main.async { activated(nil) } }
        guard activateIf() else { return .interrupted }
        focusCalls += 1
        return .issued
    }
}
