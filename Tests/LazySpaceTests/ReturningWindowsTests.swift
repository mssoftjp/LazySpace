import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// Windows that were removed because their app was hidden (or they were minimized) return to their place when they come back,
/// whether or not the window in front at that moment belongs to the layout.
final class ReturningWindowsTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private let t = Layout(root: .split(.horizontal, children: [
        .leaf(WindowID(1)),
        .split(.vertical, children: [.leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [0.5, 0.5]),
    ], ratios: [0.5, 0.5]))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = t
        store.save(state)
        system = CoordinatorSystem()
        system.frames[WindowID(3)] = CGRect(x: 960, y: 540, width: 960, height: 540)
        system.pids = [WindowID(1): 1, WindowID(2): 22, WindowID(3): 22]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        _ = coordinator.arrange(source: "test")
        drain()
        tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick()
    }

    override func tearDownWithError() throws {
        drain()
        try FileManager.default.removeItem(at: root)
    }

    private func drain() {
        let done = expectation(description: "Operations drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func tick() {
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    func testHiddenStackReturnsToItsPlaceWhenTheFrontWindowIsNotManaged() {
        XCTAssertEqual(coordinator.state.layouts["7"], t)
        // The app restores its windows a little off the old place when shown again (as TextEdit does after a hide).
        system.frames[WindowID(2)] = CGRect(x: 760, y: 0, width: 1160, height: 700)
        system.frames[WindowID(3)] = CGRect(x: 760, y: 700, width: 1160, height: 380)
        system.hiddenPIDs = [22]
        system.hiddenFromCensus = [WindowID(2), WindowID(3)]
        // Another app's window is in front while TextEdit is hidden and when it comes back.
        system.frontWindow = WindowID(99)
        system.focused = WindowID(99)
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        system.hiddenPIDs = []
        system.hiddenFromCensus = []
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"], t, "the stack comes back as it was")
    }

    private var stacked: Bool {
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return false }
        return children.contains(.split(.vertical, children: [.leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [0.5, 0.5]))
    }

    private func hideStack() {
        system.hiddenPIDs = [22]
        system.hiddenFromCensus = [WindowID(2), WindowID(3)]
        system.frontWindow = WindowID(99)
        system.focused = WindowID(99)
        tick(); tick()
    }

    func testReturningAndNewWindowsTogetherRestoreTheStackFirst() {
        hideStack()
        system.hiddenPIDs = []
        system.hiddenFromCensus = []
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 500, height: 400)
        tick(); tick()
        XCTAssertTrue(stacked, "the stack comes back whole although a new window arrived in the same observation")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(4)), true)
    }

    func testAnExpiredRecordNoLongerRestoresThePlace() {
        var now = Date()
        coordinator.departureClock = { now }
        hideStack()
        now = now.addingTimeInterval(Coordinator.departureMemory + 1)
        system.hiddenPIDs = []
        system.hiddenFromCensus = []
        tick(); tick()
        XCTAssertFalse(stacked, "after 180 s the windows join as new ones")
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3)])
    }

    func testNewWindowWithoutARecordOrAnAnchorStillJoins() {
        system.frontWindow = WindowID(99)
        system.focused = WindowID(99)
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 500, height: 400)
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(4)), true, "it joins as before")
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3), WindowID(4)])
    }

    /// A window minimized while the user was on another Space leaves the layout on return and, shown again, returns to its place.
    func testWindowMinimizedWhileAwayReturnsToItsPlace() {
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 7, WindowID(5): 8]
        system.frames[WindowID(5)] = CGRect(x: 200, y: 200, width: 600, height: 500)
        system.focused = WindowID(3)
        system.space = 8
        tick(); tick()
        system.hiddenFromCensus = [WindowID(1)]
        system.minimizedWindows = [WindowID(1)]
        system.space = 7
        tick(); tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(2), WindowID(3)])
        // It comes back somewhere else on screen, so only the remembered place puts it back on the left.
        system.frames[WindowID(1)] = CGRect(x: 1400, y: 300, width: 400, height: 400)
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, t.windowIDs)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.first, WindowID(1), "it returns to its place")
    }
}
