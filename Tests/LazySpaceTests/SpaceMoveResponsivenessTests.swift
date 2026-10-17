import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
@testable import Operations
@testable import LazySpaceApp

/// A window moved to another Space joins the layout without waiting for a click; response times on the arriving and departing sides.
final class SpaceMoveResponsivenessTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!

    private func make(layouts: [String: Layout]) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = layouts
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
    }

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func tick() {
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    private func placeMissing(on space: UInt64 = 7) -> Bool {
        let started = coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(space), spaceKey: String(space)) }
        drain()
        return started
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    private static let row = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)

    // MARK: - AX elements of the arrived Space

    /// Even on a Space with no operation, once arrived and settled it observes once and retains AX elements (direct-switch candidates), even while paused.
    func testSettledArrivalRetainsElementsOnceEvenWhilePaused() {
        make(layouts: [:])
        coordinator.pause()
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 800, height: 600)
        coordinator.noteSpaceArrival(at: Date())
        tick()
        XCTAssertEqual(system.snapshotCount, 0, "not before the arrival dwell")
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        tick()
        XCTAssertEqual(system.snapshotCount, 1)
        XCTAssertTrue(system.snapshotScopes.last??.contains(WindowID(1)) == true, "limited to the windows seen on this Space")
        tick()
        XCTAssertEqual(system.snapshotCount, 1, "once per arrival")
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        tick()
        XCTAssertEqual(system.snapshotCount, 2, "a new arrival retains again")
    }

    /// A tick that spent time retaining elements does not go on to automatic arrangement; the next tick does (no acting on stale observations).
    func testRetentionTickDoesNotActOnTheCensusTakenBeforeIt() {
        make(layouts: ["7": Self.row])
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 300, height: 300)
        system.frames[WindowID(2)] = CGRect(x: 400, y: 0, width: 300, height: 300)
        tick()  // the Space is first noticed (arrival)
        system.onSnapshot = { self.system.space = 8 } // the user changed Spaces during retention
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        let before = system.snapshotCount
        tick()
        XCTAssertEqual(system.snapshotCount, before + 1)
        XCTAssertEqual(system.writes, 0, "no arrangement from the census taken before the retention")
    }

    /// A Space change during the observation retaken after retention keeps that observation from reaching automatic arrangement.
    func testSpaceChangeDuringTheRefreshedCensusStopsTheTick() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = ["7": Self.row]
        store.save(state)
        system = CoordinatorSystem()
        var censusReads = 0
        var switchOnRead: Int?
        let sys = system!
        coordinator = Coordinator(system: sys, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: { space in
            censusReads += 1
            let c = sys.census(space)
            if censusReads == switchOnRead { sys.space = 8 }
            return c
        }, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 300, height: 300)
        system.frames[WindowID(2)] = CGRect(x: 400, y: 0, width: 300, height: 300)
        tick()  // arrival noticed
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        switchOnRead = censusReads + 2  // 1 = this tick's first census, 2 = the refreshed census after retention
        let before = system.snapshotCount
        tick()
        XCTAssertEqual(system.snapshotCount, before + 1, "retention ran")
        XCTAssertEqual(censusReads, switchOnRead, "the refreshed census was taken")
        XCTAssertEqual(system.writes, 0, "no arrangement after the Space changed during the refreshed census")
    }

    // MARK: - Windows missing from observation

    /// A window missing from the operation's observation is not a failure: it is retried after an interval and placed once observed (no click needed).
    func testWindowMissingFromTheOperationSnapshotIsRetriedInsteadOfGivenUp() {
        make(layouts: ["7": Self.row])
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.hiddenFromScopedSnapshots = [WindowID(3)]
        XCTAssertTrue(placeMissing())
        XCTAssertFalse(placeMissing(), "The next attempt waits for the backoff")
        Thread.sleep(forTimeInterval: ObservationBackoff.firstDelay + 0.05)
        XCTAssertTrue(placeMissing())
        Thread.sleep(forTimeInterval: ObservationBackoff.firstDelay * 2 + 0.05)
        XCTAssertTrue(placeMissing(), "Two unobserved attempts must not give up like two refusals do")
        system.hiddenFromScopedSnapshots = []
        Thread.sleep(forTimeInterval: ObservationBackoff.firstDelay * 4 + 0.05)
        XCTAssertTrue(placeMissing())
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
        XCTAssertFalse(coordinator.waiting.contains(WindowID(3)))
    }

    /// A window that never appears is not queried on every tick, only once its retry interval has passed.
    /// The backoff clock is fixed, so slow test waits never run out the 0.25 s interval.
    func testWindowThatNeverAppearsIsNotQueriedEveryTick() {
        make(layouts: ["7": Self.row])
        var clock = Date(timeIntervalSince1970: 1_000_000)
        coordinator.backoffClock = { clock }
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.hiddenFromScopedSnapshots = [WindowID(3)]
        XCTAssertTrue(placeMissing())
        let snapshots = system.snapshotCount
        let focusReads = system.focusReads
        for _ in 0..<10 { XCTAssertFalse(placeMissing()) }
        XCTAssertEqual(system.snapshotCount, snapshots)
        XCTAssertEqual(system.focusReads, focusReads, "Waiting for a retry does not read the focused window over AX each tick")
        clock += ObservationBackoff.firstDelay + 0.01
        _ = placeMissing()
        XCTAssertGreaterThan(system.snapshotCount, snapshots, "retried once the interval passed")
    }

    /// While the front window (CGWindowList) and AX focus disagree, focus is not reread until the front changes or a signal arrives.
    /// The backoff clock is fixed, so slow test waits never run out the retry interval.
    func testFocusDisagreementDoesNotReadFocusEveryTick() {
        for focused in [nil, WindowID(1)] as [WindowID?] {
            make(layouts: ["7": Self.row])
            coordinator.backoffClock = { Date(timeIntervalSince1970: 1_000_000) }
            system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
            system.hiddenFromScopedSnapshots = [WindowID(3)]
            system.frontWindow = WindowID(3)
            system.focused = focused
            XCTAssertTrue(placeMissing())
            let focusReads = system.focusReads
            for _ in 0..<10 { _ = placeMissing() }
            XCTAssertEqual(system.focusReads, focusReads, "focused=\(String(describing: focused))")
            drain()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// With the same front window, if AX focus moved after a focus signal, retry without waiting.
    func testFocusSignalRecoversAWindowWaitingForItsRetry() {
        make(layouts: ["7": Self.row])
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.hiddenFromScopedSnapshots = [WindowID(3)]
        system.frontWindow = WindowID(3)
        system.focused = nil
        XCTAssertTrue(placeMissing())
        system.hiddenFromScopedSnapshots = []
        system.focused = WindowID(3)
        XCTAssertFalse(placeMissing(), "Without a signal the retry still waits")
        coordinator.operationsQueue.sync { coordinator.requestFocusRead() }
        XCTAssertTrue(placeMissing(), "Focus on the window clears its retry wait")
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// A window seen on another Space joins once its membership becomes the current Space, even with an unchanged frame.
    func testStaleMembershipDoesNotFreezeTheWindowAtItsFrame() {
        make(layouts: ["7": Self.row])
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.membership = .other
        XCTAssertFalse(placeMissing())
        system.membership = .current
        Thread.sleep(forTimeInterval: ObservationBackoff.firstDelay + 0.05)
        XCTAssertTrue(placeMissing())
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// Windows refused by kind, like dialogs, still stop automatic retries after 2 tries.
    func testRefusalByKindStillGivesUp() {
        make(layouts: ["7": Self.row])
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        var snapshots = 0
        system.onSnapshot = {
            snapshots += 1
            self.system.kind = snapshots % 2 == 1 ? .standard : .dialog
        }
        var starts = 0
        for _ in 0..<6 where placeMissing() { starts += 1 }
        XCTAssertEqual(starts, 2)
        XCTAssertTrue(coordinator.waiting.contains(WindowID(3)))
    }

    func testIntegrateObservationSplitsByWhatTheOperationSaw() {
        func window(_ id: UInt32, membership: ObservedWindow.Membership = .current, kind: ObservedWindow.Kind = .standard) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: "test", frame: .zero, membership: membership, kind: kind, detail: "", title: "")
        }
        var result = OperationResult.note(kind: "auto-integrate", spaceID: 7, message: "", ok: false)
        result.excluded = [
            Exclusion(window: window(4, kind: .dialog), reason: "dialog"),
            Exclusion(window: window(5, membership: .other), reason: "other"),
            Exclusion(window: window(6, kind: .unknownRole), reason: "unknown role"),
            Exclusion(window: window(7, membership: .unknown), reason: "unknown")
        ]
        let split = Coordinator.integrateObservation(adding: [WindowID(3), WindowID(4), WindowID(5), WindowID(6), WindowID(7)], result: result)
        XCTAssertEqual(split.settled, [WindowID(4)])
        XCTAssertEqual(split.transient, [WindowID(3), WindowID(5), WindowID(6), WindowID(7)])
    }

    func testBackoffDoublesUpToTheCap() {
        var backoff = ObservationBackoff()
        let start = Date()
        backoff.note([WindowID(1)], now: start)
        XCTAssertTrue(backoff.isWaiting(WindowID(1), now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(backoff.isWaiting(WindowID(1), now: start.addingTimeInterval(0.3)))
        for _ in 0..<(ObservationBackoff.maxAttempts - 2) { backoff.note([WindowID(1)], now: start) }
        XCTAssertEqual(backoff.attempts(WindowID(1)), ObservationBackoff.maxAttempts - 1)
        XCTAssertEqual(backoff.nextAttempt(among: [WindowID(1)], now: start), start.addingTimeInterval(ObservationBackoff.maxDelay))
        backoff.note([WindowID(1)], now: start)
        XCTAssertTrue(backoff.isWaiting(WindowID(1), now: start.addingTimeInterval(60)), "Exhausted retries wait for an event")
        XCTAssertNil(backoff.nextAttempt(among: [WindowID(1)], now: start))
        backoff.keep(only: [WindowID(1): .zero], tolerance: 1)
        XCTAssertFalse(backoff.isEmpty, "Without a recorded frame, a visible window keeps its entry")
        backoff.keep(only: [:], tolerance: 1)
        XCTAssertTrue(backoff.isEmpty)
    }

    func testBackoffForgetsAWindowWhoseFrameChanged() {
        var backoff = ObservationBackoff()
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        for _ in 0..<ObservationBackoff.maxAttempts { backoff.note([WindowID(1)], frames: [WindowID(1): frame]) }
        backoff.keep(only: [WindowID(1): frame], tolerance: 1)
        XCTAssertTrue(backoff.isWaiting(WindowID(1)))
        backoff.keep(only: [WindowID(1): frame.offsetBy(dx: 40, dy: 0)], tolerance: 1)
        XCTAssertFalse(backoff.isWaiting(WindowID(1)))
    }

    /// Windows of unresponsive apps still count as failures (each wait stalls operations).
    /// An app that did not return its window list is no failure of the windows being added: one that was read waited for another app,
    /// and one whose own app did not answer is retried after an interval. An app that did not apply writes in time still counts.
    func testUnresponsiveAppIsNoFailureOfTheWindowsBeingAdded() {
        var result = OperationResult.note(kind: "auto-integrate", spaceID: 7, message: "", ok: false)
        result.stopReason = .appUnresponsive
        result.targets = [TargetReport(id: WindowID(4), app: "test", before: .zero, planned: nil, after: nil, status: .unapplied, issued: 0, note: nil)]
        result.unobservedApps = ["com.example.hung"]
        let split = Coordinator.integrateObservation(adding: [WindowID(3), WindowID(4)], result: result)
        XCTAssertTrue(split.settled.isEmpty)
        XCTAssertEqual(split.transient, [WindowID(3)])
        // Writes that timed out strike only the windows that were read and written.
        result.issued = 1
        let wrote = Coordinator.integrateObservation(adding: [WindowID(3), WindowID(4)], result: result)
        XCTAssertEqual(wrote.settled, [WindowID(4)])
        XCTAssertEqual(wrote.transient, [WindowID(3)])
        result.unobservedApps = []
        XCTAssertEqual(Coordinator.integrateObservation(adding: [WindowID(3), WindowID(4)], result: result).settled, [WindowID(3), WindowID(4)])
    }

    // MARK: - move-to-space

    /// A window carried by move-to-space is placed on the destination without the arrival dwell.
    func testWindowCarriedByMoveToSpaceIsPlacedWithoutTheArrivalDwell() {
        make(layouts: ["7": Self.row, "8": Self.row])
        tick(); tick(); tick()
        coordinator.operationsQueue.sync { coordinator.expectArrival(of: WindowID(3), on: 8) }
        system.space = 8
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick() // the new Space is first noticed
        tick() // stable observation: rebase
        XCTAssertTrue(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(3)) == true)
        XCTAssertFalse(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// An arrival without a carried window (passing through a Space, for example) still waits for the dwell.
    func testArrivalWithoutACarriedWindowStillWaitsForTheDwell() {
        make(layouts: ["7": Self.row, "8": Self.row])
        tick(); tick(); tick()
        system.space = 8
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick()
        tick()
        XCTAssertFalse(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(3)) == true)
        Thread.sleep(forTimeInterval: coordinator.arrivalDwell + 0.05)
        tick()
        XCTAssertTrue(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// The expected carried window is not used for arrivals on another Space.
    func testExpectedArrivalIsIgnoredOnAnotherSpace() {
        make(layouts: ["7": Self.row, "8": Self.row])
        tick(); tick(); tick()
        coordinator.operationsQueue.sync { coordinator.expectArrival(of: WindowID(3), on: 9) }
        system.space = 8
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick()
        tick()
        XCTAssertFalse(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(3)) == true)
    }

    // MARK: - Redistributing after a window leaves

    /// If the left button was down on arrival, redistributing after a managed window left waits for the release, then runs.
    func testDepartedRefitWaitsForTheButtonRelease() {
        make(layouts: ["7": Self.row, "8": Planner.rowLayout([WindowID(1), WindowID(2), WindowID(5)], rows: 1)])
        tick(); tick(); tick()
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        // The remaining windows on 8 sit where a redistribution would move them.
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 600, height: 1080)
        system.space = 8
        tick()
        tick()
        XCTAssertEqual(system.writes, 0, "No writes while the button is held")
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), true)
        mouse(.leftMouseUp)
        tick() // the release is noticed; this Space has no measured plan yet, so the quiet interval applies
        XCTAssertEqual(system.writes, 0)
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        drain()
        XCTAssertGreaterThan(system.writes, 0)
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), false)
    }

    /// A drag that swapped managed windows on arrival is adopted before the redistribution for the departed window.
    func testDepartedRefitDoesNotOverwriteADropMadeOnArrival() {
        make(layouts: ["7": Self.row, "8": Self.row])
        system.frames[WindowID(5)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.space = 8
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange 8") }
        drain()
        let three = coordinator.state.layouts["8"]!.windowIDs
        XCTAssertEqual(Set(three), [WindowID(1), WindowID(2), WindowID(5)])
        // 5 left 8. After settling on 7, return to 8 with the button held.
        system.frames[WindowID(5)] = nil
        system.space = 7
        tick(); tick(); tick()
        let first = three.first { $0 != WindowID(5) }!
        let second = three.last { $0 != WindowID(5) }!
        guard let firstFrame = system.frames[first], let secondFrame = system.frames[second] else { return XCTFail("frames") }
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.space = 8
        tick()
        tick()
        // Still held, drop first onto second.
        system.frames[first] = CGRect(origin: CGPoint(x: secondFrame.minX + 20, y: secondFrame.minY + 20), size: firstFrame.size)
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        drain()
        tick()
        drain()
        let ids = coordinator.state.layouts["8"]!.windowIDs
        XCTAssertFalse(ids.contains(WindowID(5)))
        XCTAssertEqual(ids, [second, first], "The drop onto the other window is kept as a swap")
        XCTAssertGreaterThan(system.frames[first]?.minX ?? 0, system.frames[second]?.minX ?? 0)
    }

    /// Arriving without the button held, the redistribution for a departed managed window runs at once.
    func testDepartedRefitRunsAtOnceWhenTheButtonIsUp() {
        make(layouts: ["7": Self.row, "8": Planner.rowLayout([WindowID(1), WindowID(2), WindowID(5)], rows: 1)])
        tick(); tick(); tick()
        system.space = 8
        tick()
        tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), false)
    }
}
