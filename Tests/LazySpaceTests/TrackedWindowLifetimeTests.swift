import XCTest
import LayoutCore
@testable import LazySpaceApp

final class TrackedWindowLifetimeTests: XCTestCase {
    private func checkSweep(listUnavailable: Bool, alive: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        let id = WindowID(99)
        // Waiting windows are separate from floating and placed windows (floating windows never wait).
        let waitingID = WindowID(98)
        var state = PersistedState()
        // This Space is deliberately left for manual use; lifetime checks still apply.
        state.pausedSpaces = ["7"]
        state.floating["7"] = [id]
        state.floatHomes["7"] = [FloatHome(id: id, layout: Layout(root: .leaf(id)))]
        state.zoomed["7"] = id
        store.save(state)
        let system = CoordinatorSystem()
        system.windowListUnavailable = listUnavailable
        if alive {
            for window in [id, waitingID] {
                system.frames[window] = system.area
                system.hiddenFromCensus.insert(window)
            }
        }
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.parkWaiting([waitingID])
        coordinator.operationsQueue.sync {
            coordinator.tick(); coordinator.tick(); coordinator.tick()
        }
        let retained = alive || listUnavailable
        XCTAssertEqual(coordinator.state.floating["7"]?.contains(id) == true, retained)
        XCTAssertEqual(coordinator.state.floatHomes["7"]?.contains { $0.id == id } == true, retained)
        XCTAssertEqual(coordinator.state.zoomed["7"] == id, retained)
        XCTAssertEqual(coordinator.status().waiting.contains(waitingID), retained)
        XCTAssertEqual(store.load().floating["7"]?.contains(id) == true, retained)
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.focusCalls, 0)
    }

    func testAnUnavailableWindowListKeepsUserChoices() throws {
        try checkSweep(listUnavailable: true, alive: true)
    }

    func testAWindowAbsentFromTheVisibleCensusButStillAliveKeepsUserChoices() throws {
        try checkSweep(listUnavailable: false, alive: true)
    }

    func testAConfirmedClosedWindowIsForgotten() throws {
        try checkSweep(listUnavailable: false, alive: false)
    }
}
