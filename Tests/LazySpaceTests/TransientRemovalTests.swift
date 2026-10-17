import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

/// A managed window briefly missing from the on-screen list (right after a drag, for example) is not treated as closed.
final class TransientRemovalTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        _ = coordinator.arrange(source: "test")
        drain()
        tick(); tick(); tick()
        system.writes = 0
        system.focusCalls = 0
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

    private var layout: [WindowID] { coordinator.state.layouts["7"]?.windowIDs ?? [] }

    /// Briefly missing then back: placement and focus unchanged, nothing written.
    func testWindowBrieflyMissingKeepsItsPlaceAndFocus() {
        system.frontWindow = WindowID(1)
        system.focused = WindowID(1)
        system.hiddenFromCensus = [WindowID(1)]
        tick(); tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.focusCalls, 0)
        system.hiddenFromCensus = []
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertEqual(system.focused, WindowID(1))
    }

    /// Not back after the hold: redistribute, but without moving focus since closing was not confirmed.
    func testWindowStillPresentIsRefitAfterTheHoldWithoutMovingFocus() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        system.hiddenFromCensus = [WindowID(1)]
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1920)
        XCTAssertEqual(system.focusCalls, 0)
    }

    /// A front window that really closed is redistributed at once and focus moves to its neighbor.
    func testClosedFrontWindowIsRefitAtOnceAndFocusMoves() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        system.frames[WindowID(1)] = nil
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
        XCTAssertEqual(system.focusCalls, 1)
        XCTAssertEqual(system.focused, WindowID(2))
    }

    /// A window fading out while closing counts as closed and is redistributed without the hold.
    func testFadingWindowIsRefitWithoutTheHold() {
        system.hiddenFromCensus = [WindowID(2)]
        system.vanishing = [WindowID(2)]
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
    }

    /// A minimized window is redistributed without the hold; focus does not move.
    func testMinimizedWindowIsRefitWithoutTheHoldOrFocus() {
        system.frontWindow = WindowID(2)
        system.focused = nil
        tick(); tick()
        system.hiddenFromCensus = [WindowID(2)]
        system.minimizedWindows = [WindowID(2)]
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.focusCalls, 0)
    }

    /// A window of an app the user hid is redistributed without the hold and without reading AX; focus does not move.
    func testHiddenAppWindowIsRefitWithoutTheHoldOrFocus() {
        system.frontWindow = WindowID(2)
        system.focused = nil
        system.pids[WindowID(2)] = 22
        tick(); tick()
        system.hiddenFromCensus = [WindowID(2)]
        system.hiddenPIDs = [22]
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertEqual(system.minimizedReads, 0, "the hidden app is evidence enough; the AX budget is not spent")
    }

    /// A window the user moved to another Space (Mission Control) is redistributed without the hold; focus does not move.
    func testWindowThatLeftForAnotherSpaceIsRefitWithoutTheHoldOrFocus() {
        system.hiddenSpaces = true
        system.frontWindow = WindowID(2)
        system.focused = nil
        tick(); tick()
        system.spaceOf = [WindowID(1): 7, WindowID(2): 8]
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertTrue(system.hiddenWrites.isEmpty)
    }

    /// The user's real mouse never reaches the fixture: only the fake system's held button defers the refit, and releasing it lets the refit run.
    func testHeldMouseButtonDefersRefitUntilReleased() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        system.anyMouseButtonHeld = true
        system.frames[WindowID(1)] = nil
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        system.anyMouseButtonHeld = false
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
    }

    /// A refit stopped before writing by a button pressed during its reads is owed again: after release the gap is filled, without moving focus.
    func testRefitStoppedByAButtonPressedDuringItsReadsIsRetriedAfterRelease() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        system.frames[WindowID(1)] = nil
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; system.anyMouseButtonHeld = true }
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.writes, 0)
        system.anyMouseButtonHeld = false
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1920)
        XCTAssertEqual(system.focusCalls, 0, "the user's press decided focus; it is not moved later")
    }

    /// An unavailable window list is no evidence of closing: wait, then redistribute without moving focus.
    func testUnavailableWindowListIsNotEvidenceOfClosing() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        system.windowListUnavailable = true
        system.hiddenFromCensus = [WindowID(1)]
        tick(); tick()
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        Thread.sleep(forTimeInterval: coordinator.removalHold + 0.05)
        tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
        XCTAssertEqual(system.focusCalls, 0)
    }

    /// During the hold, integrating new windows from the same observation is deferred too (so the missing window is not dropped).
    func testHoldAlsoDefersOtherDecisionsInTheSameObservation() {
        system.hiddenFromCensus = [WindowID(1)]
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(layout, [WindowID(1), WindowID(2)])
        system.hiddenFromCensus = []
        tick(); tick()
        drain()
        XCTAssertEqual(Set(layout), [WindowID(1), WindowID(2), WindowID(3)])
    }

    /// A fading front window leaves the layout, but focus moves only once it is gone from the full window list.
    func testFadingFrontWindowMovesFocusOnlyAfterItIsGone() {
        system.frontWindow = WindowID(1)
        system.focused = nil
        tick(); tick()
        system.hiddenFromCensus = [WindowID(1)]
        system.vanishing = [WindowID(1)]
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(2)])
        XCTAssertEqual(system.focusCalls, 0, "The record is still listed, so it is not confirmed closed")
    }

    /// Even if it looks faint, evidence that it moved to another Space makes it a departure; focus does not move.
    func testLowAlphaWindowThatLeftIsADepartureNotAClose() {
        system.hiddenSpaces = true
        system.frontWindow = WindowID(2)
        system.focused = nil
        tick(); tick()
        system.spaceOf = [WindowID(1): 7, WindowID(2): 8]
        system.vanishing = [WindowID(2)]
        system.frames[WindowID(2)] = system.frames[WindowID(2)] // still listed
        tick(); tick()
        drain()
        XCTAssertEqual(layout, [WindowID(1)])
        XCTAssertEqual(system.focusCalls, 0)
    }

    /// Two windows going missing at different times do not extend each other's hold.
    func testStaggeredHoldsDoNotRestartEachOther() {
        system.frames[WindowID(4)] = CGRect(x: 1400, y: 0, width: 520, height: 1080)
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(4)], rows: 1)
        store.save(state)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        tick(); tick(); tick()
        let start = Date()
        system.hiddenFromCensus = [WindowID(1)]
        tick(); tick()
        Thread.sleep(forTimeInterval: 0.5)
        system.hiddenFromCensus = [WindowID(1), WindowID(2)]
        while Date().timeIntervalSince(start) < 2.3 {
            tick()
            Thread.sleep(forTimeInterval: 0.15)
        }
        drain()
        XCTAssertEqual(layout, [WindowID(4)], "Both holds expire about a second after each window went missing")
    }

    /// On the arrived Space, while a placed window cannot be confirmed, no other arrangement (such as integrating new windows) runs.
    func testArrivalHoldGatesOtherArrangements() {
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["8"] = Planner.rowLayout([WindowID(5)], rows: 1)
        store.save(state)
        system.frames[WindowID(5)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        tick(); tick(); tick()
        system.writes = 0
        system.hiddenFromCensus = [WindowID(5)]
        system.space = 8
        tick(); tick() // arrival: window 5 can't be confirmed, so its refit is held
        // A new window opens, but it is not integrated until 5 is confirmed (integrating would drop 5 from the layout).
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), true)
        XCTAssertEqual(system.writes, 0)
        system.hiddenFromCensus = []
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        for _ in 0..<4 { tick() }
        drain()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), true, "The window that came back keeps its place")
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    /// If a redistribution deferred because of a held button becomes uncertain, integration in the same observation stops too.
    func testPendingRefitThatBecomesUncertainGatesTheSameObservation() {
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["8"] = Planner.rowLayout([WindowID(5), WindowID(6)], rows: 1)
        store.save(state)
        system.hiddenSpaces = true
        system.frames[WindowID(5)] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        system.frames[WindowID(6)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(5): 9, WindowID(6): 8]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        tick(); tick(); tick()
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.space = 8
        tick(); tick() // arrival while held: window 5 is confirmed on Space 9, so the refit is only deferred
        system.writes = 0
        // 5 is actually on 8 and only briefly missing from the list. A new window opens at the same time.
        system.spaceOf[WindowID(5)] = 8
        system.hiddenFromCensus = [WindowID(5)]
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        mouse(.leftMouseUp)
        tick(); tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick(); tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), true)
        XCTAssertEqual(system.writes, 0)
    }

    /// If, within one observation, the first check says departed and a later one says unconfirmed, that observation writes nothing.
    func testHoldFoundBySecondAssessmentStopsLaterWrites() {
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["8"] = Planner.rowLayout([WindowID(5), WindowID(6)], rows: 1)
        store.save(state)
        system.hiddenSpaces = true
        system.frames[WindowID(5)] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        system.frames[WindowID(6)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 8, WindowID(5): 9, WindowID(6): 8]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        tick(); tick(); tick()
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.space = 8
        tick(); tick()
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.arrivalDwell + 0.05)
        system.writes = 0
        system.spaceOf[WindowID(5)] = 8
        system.hiddenFromCensus = [WindowID(5)]
        system.spacesSequence[WindowID(5)] = [[9]] // the first check still sees Space 9
        tick()
        drain()
        XCTAssertEqual(coordinator.state.layouts["8"]?.windowIDs.contains(WindowID(5)), true)
        XCTAssertEqual(system.writes, 0)
    }

    /// The minimized state is not read for windows already decided by the list and membership.
    func testMinimizedStateIsReadOnlyForUndecidedWindows() {
        system.frames[WindowID(2)] = nil
        tick(); tick()
        drain()
        XCTAssertEqual(system.minimizedReads, 0, "A window gone from the list needs no AX read")
    }

    func testRemovalVerdict() {
        let now = Date()
        func verdict(list: Bool = true, record: CGWindowRecord?, pid: Int32? = 1, spaces: [UInt64]? = [7], minimized: Bool? = false, hidden: Bool? = nil,
                     since: Date? = nil) -> Coordinator.RemovalVerdict {
            Coordinator.removalVerdict(listAvailable: list, record: record, expectedPID: pid, spaces: spaces, currentSpace: 7,
                                       minimized: minimized, appHidden: hidden, heldSince: since, now: now, hold: 1)
        }
        let listed = CGWindowRecord(id: 1, pid: 1, layer: 0, bounds: .zero, alpha: 1, onScreen: false)
        var fading = listed; fading.alpha = 0.01
        XCTAssertEqual(verdict(record: nil), .closed)
        XCTAssertEqual(verdict(record: listed, pid: 2), .closed, "A reused window ID from another process is not the same window")
        XCTAssertEqual(verdict(record: fading), .fading)
        XCTAssertEqual(verdict(record: fading, spaces: [8]), .departed, "Departure evidence wins over low alpha")
        XCTAssertEqual(verdict(record: fading, minimized: true), .lost)
        XCTAssertEqual(verdict(record: listed, spaces: [8]), .departed)
        XCTAssertEqual(verdict(record: listed, minimized: true), .lost)
        XCTAssertEqual(verdict(record: listed, hidden: true), .lost)
        XCTAssertEqual(verdict(record: listed, hidden: false), .held, "false is no evidence")
        XCTAssertEqual(verdict(record: listed, spaces: [8], hidden: true), .departed, "departure evidence comes first")
        XCTAssertEqual(verdict(record: nil, hidden: true), .closed)
        XCTAssertEqual(verdict(record: listed), .held)
        XCTAssertEqual(verdict(record: listed, spaces: []), .held)
        XCTAssertEqual(verdict(record: listed, spaces: [7, 8]), .held)
        XCTAssertEqual(verdict(record: listed, since: now.addingTimeInterval(-1.1)), .lost)
        XCTAssertEqual(verdict(list: false, record: nil), .held)
        XCTAssertEqual(verdict(list: false, record: nil, since: now.addingTimeInterval(-1.1)), .lost)
    }
}
