import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpace

private struct TwoSpaces: SpaceListing {
    var order: [UInt64]
    var active: () -> UInt64?
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
}

/// Redistributes a Space a window left, without showing that Space.
final class HiddenSpaceRefitTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = ["7": Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1), "8": Planner.rowLayout([WindowID(3)], rows: 1)]
        store.save(state)
        system = CoordinatorSystem()
        system.frames[WindowID(3)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 8]
        system.hiddenSpaces = true
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
    }

    override func tearDownWithError() throws {
        drain()
        try? FileManager.default.removeItem(at: root)
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

    /// After settling on 7, only window 2 moves to 8, and the user is on 8 too.
    private func carryWindowTwoToEight() {
        tick(); tick(); tick()
        system.spaceOf[WindowID(2)] = 8
        system.space = 8
        tick() // the new Space is first noticed
        tick() // stable observation: the departure is confirmed and the Space rebased
    }

    private var sevenFillsTheScreen: Bool { system.frames[WindowID(1)]?.width == 1920 }

    func testDepartureRefitsTheSourceSpaceWhileItIsHidden() {
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertTrue(sevenFillsTheScreen)
        XCTAssertEqual(system.hiddenWrites, [WindowID(1)], "Only the window that stayed is written, through the hidden-Space path")
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertEqual(system.space, 8)
    }

    /// After a display setup change, the hidden refit waits like every other automatic correction, then fits the new work area.
    func testHiddenRefitWaitsForTheDisplaysToSettle() {
        coordinator.displaySettleInterval = 0.3
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        tick(); tick(); tick()
        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        system.spaceOf[WindowID(2)] = 8
        system.space = 8
        tick(); tick(); tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty, "no hidden write before the displays settle")
        Thread.sleep(forTimeInterval: 0.35)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        let deadline = Date().addingTimeInterval(2)
        while system.hiddenWrites.isEmpty, Date() < deadline { tick() }
        XCTAssertEqual(system.hiddenWrites.first, WindowID(1))
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    /// A Space on the display below is refit in that display's work area; a capped window that stays alone is centered there,
    /// and the Space settles without further writes when shown.
    func testHiddenRefitOnTheOtherDisplayCentersACappedWindow() {
        let below = CGRect(x: 375, y: 1465, width: 1920, height: 1055)
        system.areaOfSpace = [7: below, 8: CGRect(x: 0, y: 25, width: 2560, height: 1415)]
        system.frames[WindowID(3)] = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        system.maximumSizes[WindowID(1)] = CGSize(width: 740, height: 0)
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertEqual(system.hiddenWrites.first, WindowID(1))
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 965, y: 1465, width: 740, height: 1055))
        XCTAssertEqual(coordinator.knowledge.maximums(for: [WindowID(1)], workArea: below)[WindowID(1)]?.width, 740)

        system.space = 7
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        for _ in 0..<12 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 965, y: 1465, width: 740, height: 1055))
        let writes = system.writes
        for _ in 0..<5 { tick() }
        XCTAssertEqual(system.writes, writes, "settled: no more writes")
    }

    func testReturningAfterTheHiddenRefitWritesNothing() {
        carryWindowTwoToEight()
        tick()
        drain()
        let writes = system.writes
        system.space = 7
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes)
    }

    /// Even if membership in the source Space lingers right after arriving, it counts as a departure once settled.
    func testLateMembershipUpdateStillCountsAsADeparture() {
        tick(); tick(); tick()
        system.spaceOf[WindowID(2)] = 8
        system.reportedSpaces[WindowID(2)] = [7] // on screen on 8, but SkyLight still reports Space 7
        system.space = 8
        tick(); tick(); tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        system.reportedSpaces = [:]
        // The observation with settled membership puts the window in the current Space's list, and the next one with a settled window set counts the departure.
        tick(); tick(); tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    /// If a window has no element retained from when it was visible, write nothing and leave it to the redistribution on return.
    func testWindowWithoutARetainedElementFallsBackToTheReturnRefit() {
        system.unretained = [WindowID(1)]
        carryWindowTwoToEight()
        for _ in 0..<3 { tick() }
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(2)), true)
        system.space = 7
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertTrue(sevenFillsTheScreen)
    }

    /// A Space shown on another display is not written as a hidden Space.
    func testSpaceShownOnAnotherDisplayIsNotWritten() {
        system.shownSpaces = [7]
        carryWindowTwoToEight()
        tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
    }

    /// If a remaining window is no longer a standard window (minimized, for example), write nothing.
    func testIneligibleStayerStopsTheHiddenRefit() {
        system.kinds[WindowID(1)] = .minimized
        carryWindowTwoToEight()
        tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(2)), true)
    }

    /// Returning to 7 midway cancels and leaves it to the redistribution on return.
    func testReturningDuringTheHiddenRefitHandsOverToTheArrival() {
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 600, height: 1080)
        system.onHiddenWrite = { _ in self.system.space = 7 }
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        system.onHiddenWrite = nil
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertTrue(sevenFillsTheScreen)
    }

    /// Stopped by input, it retries once after a pause.
    func testInputStopsTheHiddenRefitAndItRetriesOnce() {
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 600, height: 1080)
        var bumped = false
        system.onHiddenWrite = { _ in if !bumped { bumped = true; self.system.inputActivityCount += 1 } }
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(2)), true)
        Thread.sleep(forTimeInterval: 1.05)
        tick() // the destination's own work (window 2 joins Space 8) comes first
        tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertTrue(sevenFillsTheScreen)
    }

    /// Without support (membership unreadable), nothing happens; redistribution waits for the return as before.
    func testWithoutHiddenSpaceSupportNothingIsWrittenWhileAway() {
        system.hiddenSpaces = false
        carryWindowTwoToEight()
        for _ in 0..<3 { tick() }
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(2)), true)
    }

    /// A Space with a zoomed window is not redistributed while hidden.
    func testZoomedSourceIsLeftForTheReturn() {
        let store = StateStore(root: root)
        var state = store.load()
        state.zoomed["7"] = WindowID(1)
        store.save(state)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        carryWindowTwoToEight()
        tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
    }

    /// move-to-space: confirms the departure from the window's actual membership, places it on the destination, then redistributes the hidden source.
    func testMoveToSpaceRefitsTheSourceAfterTheWindowArrives() {
        tick(); tick(); tick()
        system.focused = WindowID(2)
        coordinator.spaceListingOverride = TwoSpaces(order: [7, 8], active: { self.system.space })
        coordinator.spaceMoverOverride = { wid, _, dest, _ in
            self.system.spaceOf[WindowID(wid)] = dest
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 1, wallMs: 1))
        }
        guard case .started = coordinator.edit(.moveToSpace(.index(2)), source: "test") else { return XCTFail("move refused") }
        drain()
        for _ in 0..<4 { tick() }
        drain()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(2)), true, "The carried window joins the destination")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertTrue(sevenFillsTheScreen)
        XCTAssertEqual(system.space, 8)
    }

    /// A move reported as failed is not a departure while the window is still on the source Space.
    func testFailedMoveThatLeavesTheWindowDoesNotRefit() {
        tick(); tick(); tick()
        system.focused = WindowID(2)
        coordinator.spaceListingOverride = TwoSpaces(order: [7, 8], active: { self.system.space })
        coordinator.spaceMoverOverride = { _, _, _, _ in .failure(.interrupted) }
        _ = coordinator.edit(.moveToSpace(.index(2)), source: "test")
        drain()
        for _ in 0..<3 { tick() }
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
    }

    private func remake(seven ids: [UInt32]) {
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout(ids.map(WindowID.init), rows: 1)
        store.save(state)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
    }

    /// Input in the middle of a write (between size and position) stops the remaining requests.
    /// A partly written Space is redistributed on return, even if the window that left has come back.
    func testInputBetweenSettersStopsAndTheReturnRepairsThePartialWrite() {
        system.frames[WindowID(4)] = CGRect(x: 1400, y: 0, width: 520, height: 1080)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 700, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 700, y: 0, width: 700, height: 1080)
        system.spaceOf[WindowID(4)] = 7
        remake(seven: [1, 2, 4])
        var bumped = false
        system.onHiddenWriteBetweenSetters = { _ in if !bumped { bumped = true; self.system.inputActivityCount += 1 } }
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertEqual(system.hiddenWrites.count, 1, "The first window got its size; nothing else was written")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(2)), true)
        // Window 2 and the user return to 7. No window left, but the partial write is repaired.
        system.spaceOf[WindowID(2)] = 7
        system.space = 7
        tick(); tick(); tick()
        drain()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(4)]?.width, 640)
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    /// A partly written frame is not adopted as the user's resize when the button is released after returning.
    func testPartialHiddenWriteIsNotAdoptedAsAMouseResizeOnReturn() {
        system.frames[WindowID(4)] = CGRect(x: 1400, y: 0, width: 520, height: 1080)
        system.spaceOf[WindowID(4)] = 7
        remake(seven: [1, 2, 4])
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange 7") }
        drain()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 640)
        var bumped = false
        system.onHiddenWriteBetweenSetters = { _ in if !bumped { bumped = true; self.system.inputActivityCount += 1 } }
        carryWindowTwoToEight()
        tick()
        drain()
        XCTAssertNotEqual(system.frames[WindowID(1)]?.width, 640, "A partial write was left behind")
        // Carry window 2 back to 7 and release.
        system.spaceOf[WindowID(2)] = 7
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.space = 7
        tick(); tick()
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        drain()
        tick()
        drain()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(4)]?.width, 640)
        guard case .refused = coordinator.edit(.undo, source: "test") else { return XCTFail("No layout change should have been recorded for undo") }
    }

    /// If the repair on return is itself stopped by input, it is retried once quiet, without a Space change.
    func testInterruptedReturnRepairIsRetried() {
        system.frames[WindowID(4)] = CGRect(x: 1400, y: 0, width: 520, height: 1080)
        system.spaceOf[WindowID(4)] = 7
        remake(seven: [1, 2, 4])
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange 7") }
        drain()
        var bumped = false
        system.onHiddenWriteBetweenSetters = { _ in if !bumped { bumped = true; self.system.inputActivityCount += 1 } }
        carryWindowTwoToEight()
        tick()
        drain()
        system.spaceOf[WindowID(2)] = 7
        system.space = 7
        // The first repair on return is stopped by input during observation.
        var interrupted = false
        system.onSnapshot = { if !interrupted { interrupted = true; self.system.inputActivityCount += 1 } }
        tick(); tick()
        drain()
        XCTAssertTrue(interrupted)
        XCTAssertNotEqual(system.frames[WindowID(1)]?.width, 640)
        system.onSnapshot = nil
        tick()
        drain()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 640)
        XCTAssertEqual(system.frames[WindowID(4)]?.width, 640)
    }

    /// If the Spaces shown on displays are unknown, being hidden cannot be confirmed, so nothing is written.
    func testUnknownDisplayVisibilityWritesNothing() {
        system.hiddenVisibilityUnknown = true
        carryWindowTwoToEight()
        tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
    }

    /// If the window returns to its (hidden) source Space while waiting to retry, the departure is dropped.
    func testDepartureThatReversesWhileWaitingIsDropped() {
        var first = true
        system.onHiddenWrite = { _ in if first { first = false; self.system.inputActivityCount += 1 } }
        carryWindowTwoToEight()
        tick()
        drain()
        let writes = system.hiddenWrites.count
        system.spaceOf[WindowID(2)] = 7
        Thread.sleep(forTimeInterval: 1.05)
        for _ in 0..<3 { tick() }
        XCTAssertEqual(system.hiddenWrites.count, writes)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
    }

    /// A window reported on several Spaces still counts as a departure once it settles on one.
    func testMultiSpaceMembershipThatSettlesStillCounts() {
        tick(); tick(); tick()
        system.spaceOf[WindowID(2)] = 8
        system.reportedSpaces[WindowID(2)] = [7, 8]
        system.space = 8
        tick(); tick(); tick()
        XCTAssertTrue(system.hiddenWrites.isEmpty)
        system.reportedSpaces = [:]
        tick(); tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    func testDisplayHoldingASpaceMustBeUniqueAndOrdinary() {
        let a = SpaceObserver.ManagedDisplay(display: "A", currentSpace: 1, spaces: [1, 7], spaceTypes: [0, 0])
        let b = SpaceObserver.ManagedDisplay(display: "B", currentSpace: 2, spaces: [2, 9], spaceTypes: [0, 4])
        XCTAssertEqual(SpaceDisplay.holding(7, in: [a, b])?.display, "A")
        XCTAssertNil(SpaceDisplay.holding(9, in: [a, b]), "A full-screen Space is not written")
        XCTAssertNil(SpaceDisplay.holding(5, in: [a, b]))
        let both = SpaceObserver.ManagedDisplay(display: "C", currentSpace: 3, spaces: [3, 7], spaceTypes: [0, 0])
        XCTAssertNil(SpaceDisplay.holding(7, in: [a, both]), "Ambiguous ownership is refused")
        let unknownType = SpaceObserver.ManagedDisplay(display: "D", currentSpace: 1, spaces: [1, 7], spaceTypes: [0])
        XCTAssertNil(SpaceDisplay.holding(7, in: [unknownType]))
    }
}
