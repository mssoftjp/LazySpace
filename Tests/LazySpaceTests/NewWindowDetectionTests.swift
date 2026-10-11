import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

/// A kAXWindowCreated announcement shortens the wait for the window to appear, without making the announcement a decision.
final class NewWindowDetectionTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var now = Date()
    private let newWindow = WindowID(3)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.announcementClock = { [unowned self] in now }
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        // Baseline and the stable window set before the announcement.
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

    /// Delay until the next scheduled tick, read right after a tick (before anything else reschedules).
    private func tickAndReadDelay() -> TimeInterval {
        coordinator.operationsQueue.sync { coordinator.tick(); return coordinator.testingNextTickDelay() }
    }

    private func appear() { system.frames[newWindow] = CGRect(x: 100, y: 100, width: 600, height: 400) }
    private var integrated: Bool { coordinator.state.layouts["7"]?.windowIDs.contains(newWindow) ?? false }

    func testAnnouncedWindowIsPolledAt50msAndIntegratedOnTheTickThatSeesIt() {
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "the window is not listed yet: look again after the 50 ms floor, not the 150 ms fast tick")
        drain()
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "still pending")
        drain()
        appear()
        tick()
        XCTAssertTrue(integrated, "an announced addition skips the second census")
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [], "the decision consumes the announcement")
    }

    func testExpiredAnnouncementNeitherShortensTicksNorSkipsTheSecondCensus() {
        coordinator.noteAnnouncedWindow(newWindow)
        now = now.addingTimeInterval(1.1)
        XCTAssertGreaterThan(tickAndReadDelay(), 0.1, "after 1 s the announcement no longer drives short ticks")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [])
        appear()
        tick()
        XCTAssertFalse(integrated, "without a live announcement a new window still waits for a second census")
        tick()
        XCTAssertTrue(integrated)
    }

    func testReannouncementKeepsTheNewerEntry() {
        coordinator.noteAnnouncedWindow(newWindow)
        now = now.addingTimeInterval(0.9)
        coordinator.noteAnnouncedWindow(newWindow)
        now = now.addingTimeInterval(0.2)
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "the second announcement is 0.2 s old, not expired")
        drain()
        appear()
        tick()
        XCTAssertTrue(integrated)
    }

    func testAnnouncedWindowOnlyOnAnotherSpaceStopsShortTicks() {
        system.hiddenSpaces = true
        system.reportedSpaces[newWindow] = [836]
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertGreaterThan(tickAndReadDelay(), 0.1, "SkyLight puts it on another Space only")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [])
    }

    func testUnknownMembershipKeepsTheAnnouncement() {
        system.hiddenSpaces = true
        system.reportedSpaces[newWindow] = []
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "empty membership is no evidence")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow])
    }

    func testAnnouncementListedOnAnotherLayerStopsShortTicks() {
        system.recordLayers[newWindow] = 3
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertGreaterThan(tickAndReadDelay(), 0.1, "a layer other than 0 is never a census candidate (tooltips, popovers)")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [])
    }

    func testTinyOrFadingInWindowKeepsTheAnnouncement() {
        system.recordLayers[newWindow] = 0
        system.recordBounds[newWindow] = CGRect(x: 0, y: 0, width: 10, height: 10)
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "apps often create a window small and resize it right away")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow])
        system.recordBounds[newWindow] = CGRect(x: 0, y: 0, width: 600, height: 400)
        system.recordAlphas[newWindow] = 0
        XCTAssertLessThanOrEqual(tickAndReadDelay(), 0.051, "a window fading in is listed before the census counts it")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow])
    }

    /// A re-announcement that arrives while the tick reads the window's Space is newer than the copy being pruned and stays.
    func testReannouncementDuringPruningIsKept() {
        system.hiddenSpaces = true
        system.reportedSpaces[newWindow] = [836]
        coordinator.noteAnnouncedWindow(newWindow)
        system.onSpacesOf = { [unowned self] id in
            guard id == newWindow else { return }
            system.onSpacesOf = nil
            now = now.addingTimeInterval(0.01)
            coordinator.noteAnnouncedWindow(newWindow)
        }
        tick()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow], "only the entry that was read is dropped")
    }

    func testClosedGateKeepsTheAnnouncementWithoutShortTicks() {
        system.stageManagerOn = true
        coordinator.noteAnnouncedWindow(newWindow)
        XCTAssertGreaterThan(tickAndReadDelay(), 0.1, "nothing could consume it while automatic arrangement is unavailable")
        drain()
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow])
    }

    func testTickDuringAnOperationKeepsTheAnnouncementWithoutShortTicks() {
        coordinator.noteAnnouncedWindow(newWindow)
        var delayDuringOperation: TimeInterval?
        system.onSnapshot = { [unowned self] in
            system.onSnapshot = nil
            // A tick that runs while an operation holds `running` (the operations queue is this thread).
            coordinator.tick()
            delayDuringOperation = coordinator.testingNextTickDelay()
        }
        _ = coordinator.arrange(source: "test")
        drain()
        XCTAssertNotNil(delayDuringOperation)
        XCTAssertGreaterThan(delayDuringOperation ?? 0, 0.1, "the operation's own completion schedules the next 50 ms tick")
        XCTAssertEqual(coordinator.testingAnnouncedWindows(), [newWindow], "a busy tick does not lose the announcement")
        appear()
        tick()
        XCTAssertTrue(integrated, "the tick after the operation still takes the announced fast path")
    }

    func testMixedAnnouncedAndUnannouncedAdditionsStillNeedTheSecondCensus() {
        coordinator.noteAnnouncedWindow(newWindow)
        appear()
        system.frames[WindowID(4)] = CGRect(x: 700, y: 100, width: 600, height: 400)
        tick()
        XCTAssertFalse(integrated, "one unannounced addition keeps the stability check")
        tick()
        XCTAssertTrue(integrated)
    }
}
