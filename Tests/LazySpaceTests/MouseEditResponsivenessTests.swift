import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// A drag's result is adopted once the windows are still after the release, instead of after the input quiet time,
/// and only when that is safe; everything else keeps the quiet path.
final class MouseEditResponsivenessTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var geometryQuiet: Bool? = true
    /// Runs when the coordinator asks for geometry evidence, i.e. during the observation that decides an early adoption.
    private var onGeometryCheck: (() -> Void)?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.geometryQuiet = { [unowned self] _, since in
            if since != .distantFuture { onGeometryCheck?() }
            return geometryQuiet
        }
        _ = coordinator.arrange(source: "test")
        drain()
        tick(); tick(); tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
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

    private func tickAndReadDelay() -> TimeInterval {
        let delay = coordinator.operationsQueue.sync { coordinator.tick(); return coordinator.testingNextTickDelay() }
        drain()
        return delay
    }

    private func mouse(_ type: CGEventType, at point: CGPoint = .zero) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    /// Drags the edge between the two windows: window 2 now starts at x 1200.
    private func dragEdge() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        mouse(.leftMouseUp)
    }

    private var adopted: Bool { system.frames[WindowID(1)]?.width == 1200 }

    func testEdgeDragIsAdoptedOnTheSecondStillReadAfterRelease() {
        let started = Date()
        dragEdge()
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "the first read after release is only a sample; look again after 50 ms")
        XCTAssertFalse(adopted)
        tick()
        XCTAssertTrue(adopted, "two equal reads after release")
        XCTAssertLessThan(Date().timeIntervalSince(started), coordinator.quietInterval, "no wait for the input quiet time")
        let writes = system.writes
        tick()
        XCTAssertEqual(system.writes, writes, "a drag is consumed once")
    }

    func testBoundsDeliveredLateAreSampledAgain() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        tick() // still the old bounds
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        tick()
        XCTAssertFalse(adopted, "the bounds changed since the sample")
        tick()
        XCTAssertTrue(adopted)
    }

    /// A click is never a mouse edit: what changes after it (a title-bar double-click zoom, an app resizing its own window) is drift, and is put back.
    func testClickWithoutDragIsNotAnEdit() {
        mouse(.leftMouseDown)
        tick()
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080) // e.g. a title-bar double-click zoom
        mouse(.leftMouseUp)
        tick(); tick(); tick()
        XCTAssertFalse(adopted, "a click is not a drag")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick(); tick()
        XCTAssertFalse(adopted, "not on the quiet path either")
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 960, y: 0, width: 960, height: 1080), "drift correction puts it back")
        XCTAssertEqual(coordinator.lastResult?.kind, "auto-reconcile")
    }

    func testPressAfterTheDragDiscardsTheEarlyPath() {
        dragEdge()
        tick()
        mouse(.leftMouseDown)
        mouse(.leftMouseUp)
        tick(); tick()
        XCTAssertFalse(adopted, "a click between reads makes the sample stale")
    }

    func testGeometryNotificationSinceTheSampleDelaysAdoption() {
        dragEdge()
        geometryQuiet = false
        tick(); tick()
        XCTAssertFalse(adopted)
        geometryQuiet = true
        tick()
        XCTAssertTrue(adopted)
    }

    func testAppWithoutAnObserverKeepsTheQuietPath() {
        geometryQuiet = nil
        dragEdge()
        tick(); tick(); tick()
        XCTAssertFalse(adopted, "without notifications two equal reads are not enough evidence")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertTrue(adopted, "the quiet path adopts it as before")
    }

    func testClickBeforeTheFirstReadKeepsTheQuietPath() {
        dragEdge()
        mouse(.leftMouseDown)
        mouse(.leftMouseUp)
        tick(); tick(); tick()
        XCTAssertFalse(adopted, "the click came after the drag ended, even though no read happened in between")
    }

    func testSpaceChangeDropsThePendingEdit() {
        dragEdge()
        system.space = 8
        tick()
        system.space = 7
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertFalse(adopted, "a drag never applies after leaving its Space")
    }

    func testPauseDropsThePendingEdit() {
        dragEdge()
        coordinator.pause()
        tick()
        XCTAssertTrue(coordinator.status().idle, "a paused drag does not stay pending")
    }

    func testInputDuringTheDecidingReadKeepsTheDragForTheQuietPath() {
        dragEdge()
        tick()
        onGeometryCheck = { [unowned self] in onGeometryCheck = nil; system.inputActivityCount += 1 }
        tick()
        XCTAssertFalse(adopted, "input after the observation started stops the early adoption")
        tick() // the input is seen; the quiet time starts again from it
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertTrue(adopted, "the drag is not lost")
    }

    func testInputDuringTheMouseArrangementKeepsTheDrag() {
        let before = coordinator.state.layouts["7"]
        dragEdge()
        tick()
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; system.inputActivityCount += 1 }
        tick()
        XCTAssertEqual(coordinator.state.layouts["7"], before, "the stopped arrangement committed nothing")
        tick() // the input is seen; the quiet time starts again from it
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertTrue(adopted, "the drag went back to the quiet path instead of being lost")
    }

    func testAButtonPressedDuringTheMouseArrangementKeepsTheDrag() {
        let before = coordinator.state.layouts["7"]
        dragEdge()
        tick()
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; system.anyMouseButtonHeld = true }
        tick()
        XCTAssertEqual(coordinator.state.layouts["7"], before, "the stopped arrangement committed nothing")
        system.anyMouseButtonHeld = false
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertTrue(adopted, "the drag went back to the quiet path instead of being undone")
    }

    func testBriefVisitToAnotherSpaceAfterTheFirstReadDropsTheDrag() {
        dragEdge()
        tick()
        system.space = 8
        tick()
        system.space = 7
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertFalse(adopted)
    }

    func testTurningOffThisSpaceDuringTheMouseArrangementCommitsNothing() {
        let before = coordinator.state.layouts["7"]
        dragEdge()
        tick()
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; coordinator.setCurrentSpaceAutoPaused(true) }
        tick()
        XCTAssertEqual(coordinator.state.layouts["7"], before)
        XCTAssertFalse(adopted)
    }

    func testTurningTheSpaceOffAndOnDuringTheMouseArrangementDoesNotReviveTheDrag() {
        dragEdge()
        tick()
        system.onSnapshot = { [unowned self] in
            system.onSnapshot = nil
            coordinator.setCurrentSpaceAutoPaused(true)
            coordinator.setCurrentSpaceAutoPaused(false)
        }
        tick()
        XCTAssertFalse(coordinator.testingMouseEditPending(), "the drag belonged to the time before the Space was turned off")
    }

    func testAnAppThatDoesNotAnswerIsNotRetriedOnEveryQuietTick() {
        system.timeOutWrites = true
        dragEdge()
        tick(); tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-resize")
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
            tick()
            XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-resize", "a failed mouse arrangement is not started again (drift correction has its own limit)")
        }
    }

    func testSpaceChangeDuringTheDecidingReadSavesNothing() {
        let before = coordinator.state.layouts["7"]
        dragEdge()
        tick()
        onGeometryCheck = { [unowned self] in onGeometryCheck = nil; system.space = 8 }
        tick()
        XCTAssertEqual(coordinator.state.layouts["7"], before, "the edit is committed only by a completed arrangement")
        XCTAssertFalse(adopted)
    }

    func testNewWindowDuringTheDragKeepsTheQuietPath() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 500, height: 400)
        dragEdge()
        tick(); tick(); tick()
        XCTAssertFalse(adopted, "no early adoption while an addition is deferred")
    }

    private let placed2 = CGRect(x: 960, y: 0, width: 960, height: 1080)

    /// Drags window 2 by its title bar and drops it where its center is over no other window.
    private func dropOnEmptySpace() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(2)] = CGRect(x: 1500, y: 700, width: 960, height: 1080)
        mouse(.leftMouseUp)
    }

    private var savedLayout: Layout? { coordinator.state.layouts["7"] }
    private var canUndo: Bool { coordinator.canApplyEdit(.undo, focused: nil) }

    func testDropOnEmptySpaceReturnsOnTheSecondStillRead() {
        let layout = savedLayout, undo = canUndo
        let started = Date()
        dropOnEmptySpace()
        let writes = system.writes
        tick()
        XCTAssertEqual(system.writes, writes, "the first read after release is only a sample")
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], placed2, "two equal reads after release return it")
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return")
        XCTAssertLessThan(Date().timeIntervalSince(started), coordinator.quietInterval, "no wait for the input quiet time")
        XCTAssertEqual(savedLayout, layout, "the layout, ratios included, is unchanged")
        XCTAssertEqual(canUndo, undo, "no undo step, as on the quiet path")
    }

    func testDropOnEmptySpaceStillMovingKeepsWaiting() {
        dropOnEmptySpace()
        tick()
        system.frames[WindowID(2)] = CGRect(x: 1600, y: 600, width: 960, height: 1080) // still moving, e.g. an OS snap
        let writes = system.writes
        tick()
        XCTAssertEqual(system.writes, writes, "the bounds changed since the sample")
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], placed2)
    }

    func testDropOnEmptySpaceWithAGeometryNotificationKeepsWaiting() {
        dropOnEmptySpace()
        geometryQuiet = false
        let writes = system.writes
        tick(); tick()
        XCTAssertEqual(system.writes, writes, "the app reported a move since the sample")
        geometryQuiet = true
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], placed2)
    }

    func testDropOnEmptySpaceWithoutAnObserverKeepsTheQuietPath() {
        let layout = savedLayout, undo = canUndo
        geometryQuiet = nil
        dropOnEmptySpace()
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "without notifications two equal reads are not enough evidence")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], placed2, "the quiet path returns it as before")
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return")
        XCTAssertEqual(savedLayout, layout)
        XCTAssertEqual(canUndo, undo)
    }

    func testPressAfterADropOnEmptySpaceKeepsTheQuietPath() {
        dropOnEmptySpace()
        tick()
        mouse(.leftMouseDown)
        mouse(.leftMouseUp)
        let writes = system.writes
        tick(); tick()
        XCTAssertEqual(system.writes, writes, "a click between reads makes the sample stale")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], placed2, "the quiet path still returns it")
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return")
    }

    /// Window 2, dragged by its title bar, is released with the pointer over window 1 while its center is over no tile: it swaps.
    func testADropSwapsWithTheTileUnderThePointer() {
        mouse(.leftMouseDown, at: CGPoint(x: 1160, y: 20))
        mouse(.leftMouseDragged, at: CGPoint(x: 900, y: 300))
        system.frames[WindowID(2)] = CGRect(x: 500, y: 600, width: 960, height: 1080)
        mouse(.leftMouseUp, at: CGPoint(x: 700, y: 620))
        tick(); tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-swap")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(2), WindowID(1)])
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 0, y: 0, width: 960, height: 1080))
    }

    /// The same drop released with the pointer off the window it dragged: judged at its center, which is over no tile, so it returns.
    func testAReleasePointOffTheDraggedWindowFallsBackToItsCenter() {
        mouse(.leftMouseDown, at: CGPoint(x: 1160, y: 20))
        mouse(.leftMouseDragged, at: CGPoint(x: 900, y: 300))
        system.frames[WindowID(2)] = CGRect(x: 500, y: 600, width: 960, height: 1080)
        mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100))
        tick(); tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return")
        XCTAssertEqual(system.frames[WindowID(2)], placed2)
    }

    /// Drags window 2 by its title bar and releases it with the pointer over window 1 while its center is over no tile.
    private func dropWithThePointerOverWindow1() {
        mouse(.leftMouseDown, at: CGPoint(x: 1160, y: 20))
        mouse(.leftMouseDragged, at: CGPoint(x: 900, y: 300))
        system.frames[WindowID(2)] = CGRect(x: 500, y: 600, width: 960, height: 1080)
        mouse(.leftMouseUp, at: CGPoint(x: 700, y: 620))
    }

    /// A press after a drag (here a click, or the press of a drag whose release the tap missed) makes its release point stale:
    /// a window moved since is judged at its center.
    func testAPressAfterTheDragDropsItsReleasePoint() {
        let layout = savedLayout
        mouse(.leftMouseDown, at: CGPoint(x: 1300, y: 300))
        mouse(.leftMouseDragged, at: CGPoint(x: 1100, y: 400))
        mouse(.leftMouseUp, at: CGPoint(x: 1000, y: 500)) // e.g. selecting text in window 2
        mouse(.leftMouseDown, at: CGPoint(x: 100, y: 20))
        mouse(.leftMouseUp, at: CGPoint(x: 100, y: 20))
        system.frames[WindowID(1)] = CGRect(x: 60, y: 0, width: 960, height: 1080) // holds (1000, 500); its center stays over its own tile
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-swap", "judged at its center, not at the earlier release")
        XCTAssertEqual(savedLayout, layout)
    }

    /// A release before arriving on this Space happened on another Space: the drop is judged at the window's center.
    func testAReleaseBeforeTheSpaceArrivalIsNotUsed() {
        let layout = savedLayout
        dropWithThePointerOverWindow1()
        coordinator.operationsQueue.sync { coordinator.noteSpaceArrival() }
        tick(); tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return")
        XCTAssertEqual(savedLayout, layout)
    }

    /// When two changed windows hold the release point, it does not tell which was dragged: both are judged at their centers.
    func testAReleasePointHeldByTwoChangedWindowsIsNotUsed() {
        let layout = savedLayout
        mouse(.leftMouseDown, at: CGPoint(x: 1160, y: 20))
        mouse(.leftMouseDragged, at: CGPoint(x: 900, y: 300))
        system.frames[WindowID(1)] = CGRect(x: 60, y: 0, width: 960, height: 1080) // moved by its app; holds the point, over window 2
        system.frames[WindowID(2)] = CGRect(x: 500, y: 600, width: 960, height: 1080)
        mouse(.leftMouseUp, at: CGPoint(x: 1000, y: 650))
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-return", "both centers are over their own tile or none")
        XCTAssertEqual(savedLayout, layout)
    }

    /// Another changed window that cannot be read might hold the release point too: the drop is judged at its center.
    func testAReleasePointBesideAnUnreadChangedWindowIsNotUsed() {
        system.unreadableFrames = [WindowID(1)]
        system.frames[WindowID(1)] = CGRect(x: 60, y: 0, width: 960, height: 1080)
        dropWithThePointerOverWindow1()
        tick(); tick()
        XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-swap")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
    }

    /// A pointer swap whose arrangement input stopped goes back to the quiet path and still swaps there.
    func testAnInterruptedPointerSwapStillSwapsOnTheQuietPath() {
        dropWithThePointerOverWindow1()
        tick()
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; system.inputActivityCount += 1 }
        tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)], "the stopped arrangement committed nothing")
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-swap")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(2), WindowID(1)])
    }

    /// Window 1 is resized while window 2 is dropped on empty space: the batch has a resize, so it keeps the quiet path.
    func testAReturnAmongOtherEditsKeepsTheQuietPath() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1100, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 1500, y: 700, width: 960, height: 1080)
        mouse(.leftMouseUp)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "a resize beside a return is decided as before")
    }

    /// Another changed window that cannot be read may hold the first edit: the return waits for the quiet path.
    func testAReturnBesideAnUnreadChangedWindowKeepsTheQuietPath() {
        system.unreadableFrames = [WindowID(1)]
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1100, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 1500, y: 700, width: 960, height: 1080)
        mouse(.leftMouseUp)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "window 1 was not read")
    }

    func testStillReadWithoutAnEditStopsShortTicks() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        tick()
        XCTAssertGreaterThan(tickAndReadDelay(), 0.1, "nothing to adopt: back to the quiet schedule")
    }

    func testHeldButtonBlocksTheMouseArrangementsWrites() {
        dragEdge()
        tick()
        system.onSnapshot = { [unowned self] in
            system.onSnapshot = nil
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            system.input.record(.leftMouseDown, event: event)
        }
        let writes = system.writes
        tick()
        XCTAssertEqual(system.writes, writes, "no write while a button is held")
    }

    /// After the drag's result is adopted, a new window no longer waits for the rest of the post-drag quiet time.
    func testAdditionAfterAnAdoptedDragDoesNotWaitForTheQuietTime() {
        dragEdge()
        tick(); tick()
        XCTAssertTrue(adopted)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 500, height: 400)
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)), true)
    }
}
