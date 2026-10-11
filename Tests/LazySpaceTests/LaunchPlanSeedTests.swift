import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

/// After a restart, a Space whose windows sit where its saved layout puts them gets that as the reference for mouse edits and drift,
/// without writing anything; a Space whose windows were moved while LazySpace was not running is left alone.
final class LaunchPlanSeedTests: XCTestCase {
    private var root: URL!
    private var store: StateStore!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        // The previous run arranged the Space.
        let previous = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        previous.limits.settleDelay = 0
        _ = previous.arrange(source: "test")
        previous.operationsQueue.sync {}
        let done = expectation(description: "previous drained")
        previous.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        try FileManager.default.removeItem(at: root)
    }

    private func launch() {
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        // The first observation records the arrival; pretend it was long ago.
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
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

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    func testPlanIsSeededWithoutWritingWhenWindowsSitWhereTheLayoutPutsThem() {
        let arranged = system.frames
        launch()
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.testingPlan(spaceKey: "7"), arranged.filter { [WindowID(1), WindowID(2)].contains($0.key) })
        XCTAssertEqual(system.writes, writes, "seeding writes nothing")
    }

    func testDragRightAfterARestartIsAdopted() {
        launch()
        tick(); tick(); tick()
        let left = system.frames[WindowID(1)]!
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: left.minX, y: left.minY, width: left.width + 200, height: left.height)
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.frames[WindowID(2)]!.minX, left.maxX + 200, accuracy: 30, "the neighbor follows the resized edge")
    }

    func testWindowMovedWhileNotRunningIsLeftAloneAndNotSeeded() {
        system.frames[WindowID(2)] = CGRect(x: 1100, y: 100, width: 700, height: 800)
        launch()
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertNil(coordinator.testingPlan(spaceKey: "7"))
        XCTAssertEqual(system.writes, writes)
    }

    func testNoSeedWhileAManagedWindowIsMissing() {
        system.hiddenFromCensus = [WindowID(2)]
        launch()
        tick(); tick(); tick()
        XCTAssertNil(coordinator.testingPlan(spaceKey: "7"))
    }
}
