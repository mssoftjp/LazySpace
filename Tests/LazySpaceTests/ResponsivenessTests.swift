import XCTest
import LayoutCore
import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

final class ResponsivenessTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var store: StateStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        state.layouts["99"] = Planner.rowLayout([WindowID(99)], rows: 1)
        state.pausedSpaces = ["99"]
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { XCTFail("Window overview is unnecessary here"); return nil })
        coordinator.limits.settleDelay = 0
    }

    override func tearDownWithError() throws {
        drain()
        try FileManager.default.removeItem(at: root)
    }

    private func drain() {
        let done = expectation(description: "operations drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testSpacePreflightDoesNotReadWindowsButStillRejectsInvalidAuthorization() {
        for invalidation in ["none", "input", "space", "pause", "trust", "observation"] {
            system.trusted = true; system.spaceObservationAvailable = true; system.space = 7
            coordinator.control.paused = false
            coordinator.operationsQueue.suspend()
            var ran = false
            let accepted = coordinator.runSimple(kind: "space", progress: "", source: "test") { _ in
                ran = true
                return .note(kind: "space", spaceID: 7, message: "test", ok: true)
            }
            switch invalidation {
            case "input": system.inputActivityCount += 1
            case "space": system.space = 8
            case "pause": coordinator.control.paused = true
            case "trust": system.trusted = false
            case "observation": system.spaceObservationAvailable = false
            default: break
            }
            coordinator.operationsQueue.resume()
            drain()
            guard case .started = accepted else { return XCTFail("not accepted") }
            XCTAssertEqual(ran, invalidation == "none", invalidation)
            XCTAssertEqual(system.snapshotCount, 0)
        }
    }

    func testWindowOperationStillChecksTargetAndFocus() {
        var ran = false
        system.kind = .dialog
        _ = coordinator.runSimple(kind: "minimize", progress: "", source: "test", target: WindowID(1)) { _ in
            ran = true
            return .note(kind: "minimize", spaceID: 7, message: "test", ok: true)
        }
        drain()
        XCTAssertFalse(ran)
        XCTAssertEqual(system.snapshotCount, 1)
        XCTAssertEqual(system.snapshotScopes.last!, [WindowID(1)])
    }

    func testArrivalOnlyReadsSpaceIDsAndPreservesStateWhenUnavailable() {
        system.existingSpaces = nil
        coordinator.arrivedOnRebase(current: system.census(7), spaceKey: "7")
        XCTAssertNotNil(coordinator.state.layouts["99"])
        system.existingSpaces = [7, 8]
        coordinator.arrivedOnRebase(current: system.census(7), spaceKey: "7")
        XCTAssertNil(coordinator.state.layouts["99"])
        XCTAssertTrue(coordinator.state.pausedSpaces.contains("99"), "a Space can come back with its display")
        XCTAssertNotNil(coordinator.state.layouts["7"])
        XCTAssertEqual(system.spaceListReads, 2)
        XCTAssertEqual(system.writes, 0)
    }

    func testStableManagedSpaceDoesNotRepeatedlyQueryAXFocus() {
        for _ in 0..<120 { XCTAssertFalse(coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") }) }
        XCTAssertEqual(system.focusReads, 1)
        system.focused = WindowID(2)
        XCTAssertFalse(coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") })
        XCTAssertEqual(system.focusReads, 2)
        XCTAssertEqual(system.snapshotCount, 0)
        XCTAssertEqual(system.writes, 0)
    }

    /// Repeated identical observations of an unstarted Space take only one snapshot to prepare the automatic start.
    func testUnstartedSpaceDoesNotSnapshotOnEveryTick() throws {
        for _ in 0..<120 {
            let census = system.census(7)
            coordinator.armAutomaticStart(previous: census, current: census, spaceKey: "7")
        }
        XCTAssertLessThanOrEqual(system.snapshotCount, 1)
    }

    func testAutomaticArrangeLimitsObservationAndManualArrangeStillDiscoversWindows() {
        let extra = WindowID(3)
        system.frames[extra] = CGRect(x: 200, y: 200, width: 500, height: 400)
        _ = coordinator.arrange(source: "auto", kind: "auto-reconcile")
        drain()
        XCTAssertEqual(system.snapshotScopes.last!, [WindowID(1), WindowID(2)])
        XCTAssertFalse(system.written.contains { $0.0 == extra })
        _ = coordinator.integrateForeground([extra], beside: WindowID(1))
        drain()
        XCTAssertEqual(system.snapshotScopes.last!, [WindowID(1), WindowID(2), extra])
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(extra) == true)
        system.frames[WindowID(4)] = CGRect(x: 300, y: 300, width: 500, height: 400)
        _ = coordinator.arrange(source: "menu")
        drain()
        XCTAssertNil(system.snapshotScopes.last!)
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(4)) == true)
    }
}
