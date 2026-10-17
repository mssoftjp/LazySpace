import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

/// After a restart, every Space with a saved layout is fit again (what changed while LazySpace was not running is unknown), writing only windows
/// not already in place; the fit becomes the reference for mouse edits and drift. A layout window that left meanwhile is refit right after launch.
final class LaunchRefitTests: XCTestCase {
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

    /// With `settled` false, the arrival recorded by the first observation stays recent (the arrival dwell has not passed).
    private func launch(settled: Bool = true) {
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        // The first observation records the arrival; pretend it was long ago.
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        if settled { coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2)) }
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

    func testLaunchFitWritesNothingWhenWindowsSitWhereTheLayoutPutsThem() {
        let arranged = system.frames
        launch()
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.testingPlan(spaceKey: "7"), arranged.filter { [WindowID(1), WindowID(2)].contains($0.key) })
        XCTAssertEqual(system.writes, writes, "windows already in place are not written")
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

    func testWindowMovedWhileNotRunningIsFitAgainAtLaunch() {
        let arranged = system.frames[WindowID(2)]
        system.frames[WindowID(2)] = CGRect(x: 1100, y: 100, width: 700, height: 800)
        launch(settled: false)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "the fit waits for the arrival dwell")
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick(); tick()
        XCTAssertEqual(system.frames[WindowID(2)], arranged)
        XCTAssertNotNil(coordinator.testingPlan(spaceKey: "7"))
    }

    /// Another Space's saved layout is fit once that Space is shown and settled, not before.
    func testAnotherSpaceIsFitAgainOnceShown() {
        var state = store.load()
        state.layouts["8"] = Planner.rowLayout([WindowID(3), WindowID(4)], rows: 1)
        store.save(state)
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 8, WindowID(4): 8]
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 700, height: 800)
        system.frames[WindowID(4)] = CGRect(x: 900, y: 100, width: 700, height: 800)
        launch()
        tick(); tick(); tick()
        XCTAssertEqual(system.frames[WindowID(3)], CGRect(x: 100, y: 100, width: 700, height: 800), "a Space not shown is not written")
        system.space = 8
        tick(); tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick(); tick()
        XCTAssertEqual(system.frames[WindowID(3)], CGRect(x: 0, y: 0, width: 960, height: 1080))
        XCTAssertEqual(system.frames[WindowID(4)], CGRect(x: 960, y: 0, width: 960, height: 1080))
    }

    func testWindowClosedWhileNotRunningIsRefitRightAfterLaunch() {
        system.frames[WindowID(2)] = nil
        launch(settled: false)
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertEqual(system.frames[WindowID(1)], system.area, "the gap is filled without waiting for the arrival dwell")
    }

    func testNothingIsOwedAtLaunchWhilePausedOrTheSpaceIsOff() {
        for off in ["pause", "space"] {
            var state = store.load()
            if off == "pause" { state.paused = true; state.pausedSpaces = [] } else { state.paused = false; state.pausedSpaces = ["7"] }
            store.save(state)
            system.frames[WindowID(2)] = nil
            if coordinator != nil { drain() }
            launch()
            let writes = system.writes
            tick(); tick(); tick()
            XCTAssertEqual(system.writes, writes, off)
            XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)], off)
        }
    }

    /// Every saved window closed while LazySpace was not running: the refit writes nothing, and the windows shown now join after the arrival dwell.
    func testAllSavedWindowsGoneAtLaunchWritesNothingUntilNewWindowsJoin() {
        system.frames = [WindowID(3): CGRect(x: 100, y: 100, width: 700, height: 800)]
        system.focused = WindowID(3)
        launch(settled: false)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "nothing is written before the arrival dwell")
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(3)])
        XCTAssertEqual(system.frames[WindowID(3)], system.area)
    }

    /// A refit still owed on the Space left while automatic arrangement was unavailable does not keep the Space reached meanwhile from owing its own.
    func testARefitStillOwedOnTheSpaceLeftBehindDoesNotHideTheNextOne() {
        var state = store.load()
        state.layouts["8"] = Planner.rowLayout([WindowID(3), WindowID(4)], rows: 1)
        store.save(state)
        system.spaceOf = [WindowID(1): 7, WindowID(3): 8, WindowID(4): 8]
        system.frames[WindowID(2)] = nil
        system.frames[WindowID(3)] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        system.frames[WindowID(4)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        // A held button keeps Space 7's refit owed.
        system.anyMouseButtonHeld = true
        launch()
        tick(); tick()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960, "nothing is written while a button is held")
        system.stageManagerOn = true
        tick()
        system.space = 8
        system.frames[WindowID(4)] = nil
        system.anyMouseButtonHeld = false
        system.stageManagerOn = false
        tick(); tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs, [WindowID(3)])
        XCTAssertEqual(system.frames[WindowID(3)], system.area)
    }

    /// A window minimized while LazySpace was not running leaves the layout at launch and, shown again soon, returns to its place instead of joining as new.
    func testWindowMinimizedWhileNotRunningReturnsToItsPlace() {
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        system.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080),
            WindowID(3): CGRect(x: 1280, y: 0, width: 640, height: 1080)
        ]
        system.hiddenFromCensus = [WindowID(1)]
        system.minimizedWindows = [WindowID(1)]
        system.focused = WindowID(3)
        launch()
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(2), WindowID(3)])
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2), WindowID(3)])
    }

    /// An app that does not answer keeps the refit from arranging around its window: nothing is written, and it is tried again once the app answers.
    func testRefitWaitsForAnAppThatDoesNotAnswer() {
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        system.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080)
        ]
        system.pids = [WindowID(1): 11, WindowID(2): 22]
        system.unansweringPIDs = [22]
        launch(settled: false)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "nothing is arranged around the app that did not answer")
        system.unansweringPIDs = []
        Thread.sleep(forTimeInterval: 1.05)
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    func testLaunchFitWaitsForAnAppThatDoesNotAnswer() {
        system.frames[WindowID(1)] = CGRect(x: 100, y: 100, width: 700, height: 800)
        system.pids = [WindowID(1): 11, WindowID(2): 22]
        system.unansweringPIDs = [22]
        launch()
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "nothing is arranged around the app that did not answer")
        system.unansweringPIDs = []
        Thread.sleep(forTimeInterval: 1.05)
        tick(); tick()
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    /// Resume adopts the windows where they are, which counts as that Space's launch fit: nothing moves after Resume.
    func testResumeAfterAPausedLaunchLeavesWhatItAdopted() {
        var state = store.load()
        state.paused = true
        store.save(state)
        system.frames[WindowID(1)] = CGRect(x: 100, y: 100, width: 700, height: 800)
        system.frames[WindowID(2)] = CGRect(x: 900, y: 100, width: 700, height: 800)
        launch()
        tick(); tick()
        XCTAssertNil(coordinator.resume())
        let writes = system.writes
        tick(); tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "windows Resume adopted stay where they are")
    }

    /// A window list that could not be read is no proof that nothing is left to fit: the launch fit is tried again after the same delays
    /// as for an app that does not answer.
    func testLaunchFitSurvivesAnUnreadableWindowList() {
        system.frames[WindowID(1)] = CGRect(x: 100, y: 100, width: 700, height: 800)
        system.scopedListUnreadable = true
        launch()
        var now = Date()
        coordinator.fitRetryClock = { now }
        tick(); tick()
        for wait in [1.0, 2.0] { now += wait + 0.1; tick() }
        system.scopedListUnreadable = false
        now += 4.1
        tick(); tick()
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    /// When an app still does not answer after the tries, the refit reclaims: it commits the windows that answered, the launch fit does not start
    /// another round, and the app's window returns to its place once the app answers.
    func testAfterItsTriesTheRefitReclaimsTheSpaceOfAnAppThatStillDoesNotAnswer() {
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        system.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080)
        ]
        system.pids = [WindowID(1): 11, WindowID(2): 22]
        system.unansweringPIDs = [22]
        launch(settled: false)
        var now = Date()
        coordinator.fitRetryClock = { now }
        coordinator.backoffClock = { now }
        let scope: Set<WindowID> = [WindowID(1), WindowID(2), WindowID(3)]
        func tries() -> Int { system.snapshotScopes.filter { $0 == scope }.count }
        let writes = system.writes
        tick(); tick()
        XCTAssertEqual(tries(), 1)
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        XCTAssertEqual(tries(), 4)
        XCTAssertEqual(system.writes, writes, "nothing is written while waiting")
        tick()
        XCTAssertEqual(tries(), 5)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)], "the windows that answered are committed")
        XCTAssertEqual(system.frames[WindowID(1)], system.area)
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 640, y: 0, width: 640, height: 1080), "the app's window is left where it is")
        XCTAssertNotNil(coordinator.testingPlan(spaceKey: "7"))
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        now += 10
        tick(); tick(); tick()
        XCTAssertEqual(tries(), 5, "the launch fit does not start another round")
        system.unansweringPIDs = []
        now += 5
        system.frontWindow = WindowID(2)
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)], "the app's window returns to its place on the next change")
    }

    /// When no saved window answers, the reclaim commits an empty layout and remembers them, so they return once their apps answer.
    func testWhenNoSavedWindowAnswersTheReclaimStillLetsThemReturn() {
        system.frames[WindowID(1)] = CGRect(x: 100, y: 100, width: 700, height: 800)
        system.pids = [WindowID(1): 11, WindowID(2): 22]
        system.unansweringPIDs = [11, 22]
        launch()
        var now = Date()
        coordinator.fitRetryClock = { now }
        coordinator.backoffClock = { now }
        tick(); tick()
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        tick()
        system.unansweringPIDs = []
        now += 1
        system.frontWindow = WindowID(2)
        tick(); tick(); tick()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    /// When the first observation after launch is already settled, a window minimized while LazySpace was not running is refit before any insertion,
    /// so it keeps its place to return to.
    func testWindowMinimizedWhileNotRunningKeepsItsPlaceWhenTheFirstObservationIsSettled() {
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        system.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080),
            WindowID(3): CGRect(x: 1280, y: 0, width: 640, height: 1080),
            WindowID(4): CGRect(x: 300, y: 200, width: 500, height: 400)
        ]
        system.hiddenFromCensus = [WindowID(1)]
        system.minimizedWindows = [WindowID(1)]
        system.focused = WindowID(3)
        launch()
        tick(); tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(1)), false)
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.first, WindowID(1), "it returns to its place")
    }

    /// A window minimized while LazySpace was not running keeps its place even when a new window opens before the owed refit runs.
    func testWindowMinimizedWhileNotRunningKeepsItsPlaceWhenANewWindowComesFirst() {
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(3)], rows: 1)
        store.save(state)
        system.frames = [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 640, height: 1080),
            WindowID(3): CGRect(x: 1280, y: 0, width: 640, height: 1080)
        ]
        system.hiddenFromCensus = [WindowID(1)]
        system.minimizedWindows = [WindowID(1)]
        system.focused = WindowID(3)
        launch(settled: false)
        tick()
        system.frames[WindowID(4)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(1)), false)
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.first, WindowID(1), "it returns to its place")
    }
}
