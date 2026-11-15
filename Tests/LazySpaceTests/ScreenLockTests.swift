import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

/// While the screen is locked, Accessibility shows no windows: LazySpace observes and decides nothing, and never empties a layout.
final class ScreenLockTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!

    private func start(windows: [WindowID]) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout(windows, rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        system.frames = system.frames.filter { windows.contains($0.key) }
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        _ = coordinator.arrange(source: "test")
        drain()
        tick(); tick(); tick()
        system.writes = 0
        system.focusCalls = 0
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

    private var layout: [WindowID] { coordinator.state.layouts["7"]?.windowIDs ?? [] }

    /// One window on the Space, the lock hides it, and the layout must not be saved empty.
    func testALockedScreenKeepsAOneWindowLayout() {
        start(windows: [WindowID(1)])
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1)]
        system.censusBounds[WindowID(1)] = CGRect(x: 10, y: 10, width: 300, height: 300)
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.writes, 0)
        system.screenLocked = false
        system.hiddenFromCensus = []
        system.censusBounds = [:]
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.writes, 0, "after unlock the window is where it was")
    }

    func testTheStartOfALockStopsWorkInFlight() {
        start(windows: [WindowID(1), WindowID(2)])
        let before = coordinator.control.cancellationGeneration
        coordinator.noteScreenLocked()
        XCTAssertNotEqual(coordinator.control.cancellationGeneration, before, "the notification invalidates at once")
        let notified = coordinator.control.cancellationGeneration
        system.screenLocked = true
        tick()
        XCTAssertNotEqual(coordinator.control.cancellationGeneration, notified, "the first locked tick invalidates too")
        let locked = coordinator.control.cancellationGeneration
        tick(); tick()
        XCTAssertEqual(coordinator.control.cancellationGeneration, locked, "only the start of a lock invalidates")
    }

    func testNothingIsArrangedWhileTheScreenIsLocked() {
        start(windows: [WindowID(1), WindowID(2)])
        system.screenLocked = true
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        system.frontWindow = WindowID(3)
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0, "no integration while locked")
        guard case .started(let id) = coordinator.arrange(source: "test") else { return XCTFail("accepted, then stopped by the gate") }
        drain()
        XCTAssertEqual(coordinator.result(id: id)?.stopReason, .cancelled)
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
    }

    /// A command taken after the lock started (a new authorization) is stopped too: focus moves nothing.
    func testACommandAcceptedWhileLockedDoesNothing() {
        start(windows: [WindowID(1), WindowID(2)])
        system.screenLocked = true
        tick()
        system.focused = WindowID(1)
        _ = coordinator.edit(.focus(.right), source: "test")
        drain()
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertEqual(system.writes, 0)
    }

    /// The lock ends before the windows are back: the empty census is not taken as the baseline, so nothing is owed or removed.
    func testASlowRecoveryAfterUnlockKeepsTheLayout() {
        start(windows: [WindowID(1), WindowID(2)])
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        system.screenLocked = false
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
        system.hiddenFromCensus = []
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
    }

    func testWindowsClosedDuringTheLockLeaveTheLayoutAfterUnlock() {
        start(windows: [WindowID(1), WindowID(2)])
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        system.frames[WindowID(2)] = nil
        system.hiddenFromCensus = []
        system.screenLocked = false
        tick(); tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920)
    }

    /// Every window closed while the baseline had two: firm evidence lets the removal through the empty-census guard.
    func testAnEmptyCensusWithEveryWindowClosedEmptiesTheLayout() {
        start(windows: [WindowID(1), WindowID(2)])
        system.frames = [:]
        tick(); tick(); tick()
        drain()
        XCTAssertEqual(layout, [])
    }

    /// Every window gone from the census but still alive (no evidence): waited out, even past the removal hold.
    func testAnUnexplainedEmptyCensusIsWaitedOutPastTheHold() {
        start(windows: [WindowID(1), WindowID(2)])
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
    }

    /// Mouse edits read the shape the last frames were placed in, stored with them.
    func testTheShapeOfTheLastPlanIsKeptWithItsFrames() {
        start(windows: [WindowID(1), WindowID(2)])
        XCTAssertEqual(coordinator.testingShape(spaceKey: "7")?.root?.box?.accordion, false)
        system.minimums[WindowID(1)] = CGSize(width: 1200, height: 300)
        system.minimums[WindowID(2)] = CGSize(width: 1200, height: 300)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1200, height: 600)
        system.frames[WindowID(2)] = CGRect(x: 700, y: 100, width: 1200, height: 600)
        _ = coordinator.arrange(source: "test")
        drain()
        XCTAssertEqual(coordinator.testingShape(spaceKey: "7")?.root?.box?.accordion, true, "shown overlapping")
        XCTAssertEqual(coordinator.state.layouts["7"]?.root?.box?.accordion, false, "saved as tiles")
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    private func drag() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
    }

    /// A scoped observation that could not read the full window list (as when the lock starts between reads) proves nothing about the windows
    /// it missed, even when their records are readable and say they left: Resume keeps Pause and the layout.
    func testResumeRefusesFromAnIncompleteWindowListWhileRecordsAreReadable() {
        start(windows: [WindowID(1), WindowID(2)])
        coordinator.pause()
        let prior = coordinator.state.layouts["7"]
        // Window 1 is confirmed on another Space and window 2 has no record: with a complete list both would leave the layout.
        system.hiddenSpaces = true
        system.spaceOf = [WindowID(1): 8]
        system.frames[WindowID(2)] = nil
        system.scopedListUnreadable = true
        XCTAssertNotNil(coordinator.resume())
        drain()
        XCTAssertTrue(coordinator.control.paused)
        XCTAssertEqual(coordinator.state.layouts["7"], prior)
        XCTAssertEqual(system.writes, 0)
        // The same windows read from a complete list: Resume prunes them.
        system.scopedListUnreadable = false
        XCTAssertNil(coordinator.resume())
        drain()
        XCTAssertFalse(coordinator.control.paused)
        XCTAssertEqual(layout, [])
    }

    /// Every window closed during the lock: the empty census after unlock is firm evidence, so it becomes the baseline and the layout empties
    /// at once, without waiting out the removal hold.
    func testEveryWindowClosedDuringTheLockEmptiesTheLayoutAfterUnlock() {
        start(windows: [WindowID(1), WindowID(2)])
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        system.frames = [:]
        system.hiddenFromCensus = []
        system.screenLocked = false
        tick(); tick(); tick(); tick()
        drain()
        XCTAssertEqual(layout, [])
    }

    /// A window waited for before the lock starts a new wait after unlock: the time spent locked does not count toward its removal hold.
    func testARemovalHoldDoesNotSurviveTheLock() {
        start(windows: [WindowID(1), WindowID(2)])
        system.hiddenFromCensus = [WindowID(2)]
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)], "held: still a window, with no evidence it left")
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick()
        system.hiddenFromCensus = [WindowID(2)]
        system.screenLocked = false
        tick(); tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)], "the wait starts again after unlock")
        XCTAssertEqual(system.writes, 0)
    }

    /// A refit owed before the lock belongs to that time: after unlock the departures are owed again, so a window closed during the lock
    /// still leaves the layout.
    func testARefitOwedBeforeTheLockIsOwedAgainAfterUnlock() {
        start(windows: [WindowID(1), WindowID(2)])
        // The first lock ends with window 2 still missing: its departure is owed and waited for.
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        system.hiddenFromCensus = [WindowID(2)]
        system.screenLocked = false
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        // The second lock: window 2 really closes.
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick(); tick()
        system.frames[WindowID(2)] = nil
        system.hiddenFromCensus = []
        system.screenLocked = false
        tick(); tick(); tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920)
    }

    /// A drag made before the lock is not adopted after it: the pending mouse edit is dropped while locked.
    func testAPendingMouseEditDoesNotSurviveTheLock() {
        start(windows: [WindowID(1), WindowID(2)])
        drag()
        tick()
        XCTAssertTrue(coordinator.testingMouseEditPending(), "the drag waits for the quiet time")
        system.screenLocked = true
        tick()
        XCTAssertFalse(coordinator.testingMouseEditPending(), "dropped while locked")
        system.screenLocked = false
        tick(); tick()
        XCTAssertFalse(coordinator.testingMouseEditPending())
    }

    /// Presses and drags on the lock screen are not edits of these windows: frames that changed during the lock are not adopted as a swap.
    func testADragOnTheLockScreenIsNotAMouseEditAfterUnlock() {
        start(windows: [WindowID(1), WindowID(2)])
        var kinds: [String] = []
        coordinator.onTerminalResult = { kinds.append($0.kind) }
        system.screenLocked = true
        tick()
        drag()
        system.frames[WindowID(1)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        tick()
        system.screenLocked = false
        tick()
        XCTAssertFalse(coordinator.testingMouseEditPending(), "the lock screen's drag is not pending after unlock")
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick(); tick()
        drain()
        XCTAssertFalse(kinds.contains { $0.hasPrefix("mouse-") }, "\(kinds)")
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
    }

    /// The last work areas are kept through the lock: a work area that changed while locked is seen after unlock and the layout is fit to it.
    func testAWorkAreaChangedDuringTheLockIsFitAfterUnlock() {
        start(windows: [WindowID(1), WindowID(2)])
        coordinator.displaySettleInterval = 0.2
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        tick(); tick()
        drain()
        system.writes = 0
        system.screenLocked = true
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        tick()
        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        tick(); tick()
        XCTAssertEqual(system.writes, 0, "nothing is fit while locked")
        system.hiddenFromCensus = []
        system.screenLocked = false
        let fitted = CGRect(x: 800, y: 0, width: 800, height: 1000)
        let deadline = Date().addingTimeInterval(3)
        while system.frames[WindowID(2)] != fitted, Date() < deadline { tick(); Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(system.frames[WindowID(2)], fitted)
    }

    func testTheLockSignals() {
        XCTAssertFalse(ScreenLock.locked(session: [:], frontBundleID: nil), "an unreadable session dictionary is no evidence")
        XCTAssertFalse(ScreenLock.locked(session: [kCGSessionOnConsoleKey as String: true], frontBundleID: "com.apple.finder"))
        XCTAssertTrue(ScreenLock.locked(session: ["CGSSessionScreenIsLocked": true, kCGSessionOnConsoleKey as String: true], frontBundleID: nil))
        XCTAssertTrue(ScreenLock.locked(session: [kCGSessionOnConsoleKey as String: false], frontBundleID: nil), "another user's session is on the console")
        XCTAssertTrue(ScreenLock.locked(session: [kCGSessionOnConsoleKey as String: true], frontBundleID: "com.apple.loginwindow"))
        XCTAssertTrue(MacWindowSystem.answersWithApplication(role: "AXApplication"))
        XCTAssertFalse(MacWindowSystem.answersWithApplication(role: "AXWindow"))
        XCTAssertFalse(MacWindowSystem.answersWithApplication(role: nil))
    }
}
