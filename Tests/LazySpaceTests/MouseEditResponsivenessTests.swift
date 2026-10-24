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

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
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

    func testDropOnEmptySpaceKeepsTheQuietPath() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(2)] = CGRect(x: 1500, y: 700, width: 960, height: 1080) // its center is over no other window
        mouse(.leftMouseUp)
        let writes = system.writes
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "returning a window to its place keeps the old timing")
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
