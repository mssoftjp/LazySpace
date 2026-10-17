import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// Automatic decisions measure input from when the decision started, and write nothing while a mouse button is held or after automatic arrangement is turned off for that Space.
final class AutomaticDecisionGateTests: XCTestCase {
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
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
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

    private func placeMissing() -> Bool {
        coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") }
    }

    private func assertNothingWritten(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        drain()
        XCTAssertEqual(system.writes, 0, message, file: file, line: line)
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)], message, file: file, line: line)
    }

    func testInputDuringTheDecisionReadStopsAutomaticIntegration() {
        var pressed = false
        system.onSnapshot = { if !pressed { pressed = true; self.system.inputActivityCount += 1 } }
        _ = placeMissing()
        assertNothingWritten("a click while the window list was being read must stop the integration it decided")
    }

    func testHeldMouseButtonStopsAutomaticIntegration() {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(.leftMouseDown, event: event)
        _ = placeMissing()
        assertNothingWritten("a held button means the user may be about to drag")
    }

    func testTurningOffThisSpaceDuringTheDecisionStopsAutomaticIntegration() {
        system.onSnapshot = { [unowned self] in
            system.onSnapshot = nil
            coordinator.setCurrentSpaceAutoPaused(true)
        }
        _ = placeMissing()
        assertNothingWritten("Automatically Arrange This Space was turned off before the decision was accepted")
    }

    /// If Stage Manager turns on after the decision, automatic arrangement writes nothing.
    func testStageManagerTurnedOnDuringTheDecisionStopsAutomaticIntegration() {
        system.onSnapshot = { [unowned self] in system.onSnapshot = nil; system.stageManagerOn = true }
        _ = placeMissing()
        assertNothingWritten("automatic arrangement became unavailable while it was deciding")
    }

    func testAutomaticArrangementIsRefusedInAPausedSpace() {
        coordinator.setCurrentSpaceAutoPaused(true)
        for kind in ["auto-integrate", "auto-refit", "auto-reconcile"] {
            XCTAssertEqual(coordinator.arrange(source: "auto", kind: kind, adding: [WindowID(3)]), .notApplicable, kind)
        }
        assertNothingWritten("automatic kinds are refused in a Space set to manual")
    }

    /// A window on another display's Space is not integrated as a new window of the current Space.
    func testWindowOnAnotherDisplaysSpaceIsNotTreatedAsNew() {
        system.hiddenSpaces = true
        system.reportedSpaces[WindowID(3)] = [836]
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        let snapshots = system.snapshotCount
        for _ in 0..<4 {
            coordinator.operationsQueue.sync { coordinator.tick() }
            drain()
        }
        XCTAssertEqual(system.snapshotCount, snapshots, "no Accessibility read for a window SkyLight places on another Space")
        XCTAssertEqual(coordinator.status().waiting, [])
        assertNothingWritten("a window on the other display stays out of this Space's layout")
    }
}

/// Only `autoGate` decides when automatic arrangement is unavailable, and status gives the reason.
final class AutomaticAvailabilityTests: XCTestCase {
    func testAutomaticArrangementIsOffForStageManagerSharedSpacesAndUnappliedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        try "[gaps\n".write(to: configURL, atomically: true, encoding: .utf8)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = coordinator.reloadConfig(source: "launch")
        XCTAssertNotNil(coordinator.configError)
        XCTAssertFalse(coordinator.autoGate().allowed, "the built-in settings never arrange automatically")
        XCTAssertFalse(coordinator.status().autoAvailable)
        XCTAssertTrue(coordinator.autoGate().reason.contains("configuration file"))

        try "".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertTrue(coordinator.autoGate().allowed)
        // A later reload failure keeps automatic arrangement running with the last valid configuration.
        try "[gaps\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertNotNil(coordinator.configError)
        XCTAssertTrue(coordinator.autoGate().allowed)

        system.stageManagerOn = true
        XCTAssertFalse(coordinator.autoGate().allowed)
        XCTAssertTrue(coordinator.autoGate().reason.contains("Stage Manager"))
        system.stageManagerOn = false
        system.displaysShareOneSpace = true
        XCTAssertFalse(coordinator.autoGate().allowed)
        XCTAssertTrue(coordinator.autoGate().reason.contains("Displays have separate Spaces"))
    }
}

/// After a display change, once the setup settles and input is quiet, the current Space's layout is fit to the new work area.
final class DisplayChangeRefitTests: XCTestCase {
    func testLayoutIsFittedToTheNewWorkAreaAfterTheDisplaysSettle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.displaySettleInterval = 0.2
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        func tick() {
            coordinator.operationsQueue.sync { coordinator.tick() }
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        for _ in 0..<3 { tick() }
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 960, y: 0, width: 960, height: 1080))

        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        tick()
        tick()
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 960, y: 0, width: 960, height: 1080), "wait until the displays have stayed the same")
        Thread.sleep(forTimeInterval: 0.25)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        tick()
        tick()
        let deadline = Date().addingTimeInterval(2)
        while system.frames[WindowID(2)] != CGRect(x: 800, y: 0, width: 800, height: 1000), Date() < deadline { tick() }
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    /// A centered window that can't grow wide is centered again in the new work area once the displays settle, and then stays put.
    func testCappedWindowIsCenteredAgainAfterTheDisplaysChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1)], rows: 1)
        store.save(state)
        let system = CoordinatorSystem()
        system.frames = [WindowID(1): CGRect(x: 0, y: 0, width: 740, height: 1080)]
        system.maximumSizes[WindowID(1)] = CGSize(width: 740, height: 0)
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.displaySettleInterval = 0.2
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        func tick() {
            coordinator.operationsQueue.sync { coordinator.tick() }
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        let centered = CGRect(x: 590, y: 0, width: 740, height: 1080)
        let start = Date().addingTimeInterval(3)
        while system.frames[WindowID(1)] != centered, Date() < start { tick() }
        for _ in 0..<4 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)], centered)

        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        tick(); tick()
        XCTAssertEqual(system.frames[WindowID(1)], centered, "wait until the displays have stayed the same")
        Thread.sleep(forTimeInterval: 0.25)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        let target = CGRect(x: 430, y: 0, width: 740, height: 1000)
        let deadline = Date().addingTimeInterval(3)
        while system.frames[WindowID(1)] != target, Date() < deadline { tick() }
        for _ in 0..<6 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)], target)
        let writes = system.writes
        for _ in 0..<6 { tick() }
        XCTAssertEqual(system.writes, writes, "settled in the new work area")
    }

    /// A single-window Space is not refilled until the setup settles either. Redistributions stopped by input do not count against the limit and are retried once quiet.
    func testSoloFillWaitsAndInputCancellationsDoNotExhaustTheRefit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1)], rows: 1)
        store.save(state)
        let system = CoordinatorSystem()
        system.frames = [WindowID(1): CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.displaySettleInterval = 0.2
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        func tick() {
            coordinator.operationsQueue.sync { coordinator.tick() }
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        for _ in 0..<3 { tick() }
        let writes = system.writes
        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        tick(); tick()
        XCTAssertEqual(system.writes, writes, "the one-window fill also waits for the displays to settle")
        Thread.sleep(forTimeInterval: 0.25)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        // Input arrives on every decision observation: even after 3 or more stops, it fits once quiet.
        var interruptions = 4
        system.onSnapshot = { [unowned system] in if interruptions > 0 { interruptions -= 1; system.inputActivityCount += 1 } }
        let deadline = Date().addingTimeInterval(3)
        while system.frames[WindowID(1)] != CGRect(x: 0, y: 0, width: 1600, height: 1000), Date() < deadline {
            tick()
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(interruptions, 0)
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 1600, height: 1000))
    }

    /// Until the displays settle after a change, new windows are not integrated into an intermediate work area.
    func testNewWindowWaitsForTheDisplaysToSettle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.displaySettleInterval = 0.3
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        func tick() {
            coordinator.operationsQueue.sync { coordinator.tick() }
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        for _ in 0..<3 { tick() }
        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        tick()
        let writes = system.writes
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes, "no arrangement against a work area that may still change")
        Thread.sleep(forTimeInterval: 0.35)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        let deadline = Date().addingTimeInterval(3)
        while coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) != true, Date() < deadline { tick(); Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// An unreadable Space list, or one without the current Space, does not drop per-Space state.
    func testIncompleteSpaceListDoesNotDropPerSpaceState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        state.layouts["8"] = Planner.rowLayout([WindowID(5)], rows: 1)
        state.pausedSpaces = ["8"]
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        for list in [Set<UInt64>(), [9]] {
            system.existingSpaces = list
            coordinator.operationsQueue.sync { coordinator.arrivedOnRebase(current: system.census(7), spaceKey: "7") }
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertNotNil(coordinator.state.layouts["8"], "\(list)")
            XCTAssertEqual(coordinator.state.pausedSpaces, ["8"], "\(list)")
        }
    }
}
