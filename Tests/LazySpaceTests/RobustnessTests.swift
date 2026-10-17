import XCTest
import LayoutCore
@testable import LazySpaceApp

/// Automatic integration limits, undoing drops, per-Space offset correction, and observing unclassified windows.
final class RobustnessTests: XCTestCase {
    private func make(layouts: [String: Layout] = ["7": Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)]) -> (Coordinator, CoordinatorSystem, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = layouts
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        return (coordinator, system, root)
    }

    private func drain(_ coordinator: Coordinator) {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testLearnedMaximumBlocksSoloFill() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        s.frames = [WindowID(1): CGRect(x: 0, y: 0, width: 1000, height: 700)]
        c.knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            actual: CGRect(x: 0, y: 0, width: 1000, height: 700),
            spaceID: 7, workArea: s.area, tolerance: 1)
        for _ in 0..<6 {
            _ = c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7")
            drain(c)
        }
        XCTAssertEqual(s.frames[WindowID(1)]?.width, s.area.integralInset.width)
    }

    func testSoloProbeRelearnsGenuineMaximum() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 1000, height: 700)]
        s.fixed[id] = CGSize(width: 1000, height: 700)
        c.knowledge.recordPullback(
            id: id, requested: s.area, actual: s.frames[id]!, spaceID: 7, workArea: s.area, tolerance: 1)
        XCTAssertTrue(c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7"))
        drain(c)
        XCTAssertEqual(c.lastResult?.outcome, .complete)
        XCTAssertLessThanOrEqual(s.writes, 3)
        XCTAssertEqual(c.knowledge.maximums(for: [id], workArea: s.area)[id]?.width, 1000)
    }

    func testSoloProbeRunsOncePerLearnedMaximum() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        // Already where the plan puts a capped solo window: centered across, at the top.
        let area = s.area.integralInset
        s.frames = [id: CGRect(x: area.minX + floor((area.width - 1000) / 2), y: area.minY, width: 1000, height: 700)]
        s.fixed[id] = CGSize(width: 1000, height: 700)
        c.knowledge.recordPullback(
            id: id, requested: s.area, actual: s.frames[id]!, spaceID: 7, workArea: s.area, tolerance: 1)
        var starts = 0
        for _ in 0..<10 {
            if c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7") { starts += 1 }
            drain(c)
        }
        XCTAssertEqual(starts, 1)
    }

    /// A solo probe stopped before writing by a button pressed during its reads is not spent: after release it runs again and grows the window.
    func testSoloProbeStoppedByAButtonPressStaysAvailable() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        let area = s.area.integralInset
        s.frames = [id: CGRect(x: area.minX + floor((area.width - 1000) / 2), y: area.minY, width: 1000, height: 700)]
        c.knowledge.recordPullback(
            id: id, requested: s.area, actual: s.frames[id]!, spaceID: 7, workArea: s.area, tolerance: 1)
        s.onSnapshot = { [unowned s] in s.onSnapshot = nil; s.anyMouseButtonHeld = true }
        XCTAssertTrue(c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7"))
        drain(c)
        XCTAssertEqual(s.writes, 0)
        s.anyMouseButtonHeld = false
        XCTAssertTrue(c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7"), "the stopped probe is not spent")
        drain(c)
        XCTAssertGreaterThan(s.frames[id]?.width ?? 0, 1000)
    }

    /// A solo arrangement that learns the maximum already asked for the whole area, so the solo probe does not ask again.
    func testSoloArrangementThatLearnsTheMaximumNeedsNoProbe() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 1000, height: 700)]
        s.fixed[id] = CGSize(width: 1000, height: 700)
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange") }
        drain(c)
        XCTAssertEqual(c.lastResult?.outcome, .complete)
        XCTAssertEqual(c.knowledge.maximums(for: [id], workArea: s.area)[id]?.width, 1000)
        let area = s.area.integralInset
        XCTAssertEqual(s.frames[id], CGRect(x: area.minX + floor((area.width - 1000) / 2), y: area.minY, width: 1000, height: 700))
        let writes = s.writes
        for _ in 0..<5 {
            XCTAssertFalse(c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7"))
            drain(c)
        }
        XCTAssertEqual(s.writes, writes)
    }

    /// Learning only the height while an older width cap limits the request does not test that width cap, so the solo probe still widens the window.
    func testHeightLearnedUnderAnOlderWidthCapStillGetsTheSoloProbe() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        let area = s.area.integralInset
        c.knowledge.recordPullback(id: id, requested: CGRect(x: 0, y: 0, width: 960, height: area.height),
                                   actual: CGRect(x: 0, y: 0, width: 500, height: area.height), spaceID: 7, workArea: s.area, tolerance: 1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 500, height: 700)]
        s.maximumSizes[id] = CGSize(width: 0, height: 700)
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange") }
        drain(c)
        XCTAssertEqual(c.knowledge.maximums(for: [id], workArea: s.area)[id], CGSize(width: 500, height: 700))
        for _ in 0..<6 {
            _ = c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7")
            drain(c)
        }
        XCTAssertEqual(s.frames[id]?.width, area.width)
    }

    /// A maximum learned beside another window came from a narrower request, so the window still gets one solo probe once it is alone.
    func testMaximumLearnedBesideAnotherWindowStillGetsTheSoloProbe() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 500, height: 700), WindowID(2): CGRect(x: 960, y: 0, width: 960, height: 1080)]
        s.fixed[id] = CGSize(width: 500, height: 700)
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange") }
        drain(c)
        XCTAssertEqual(c.knowledge.maximums(for: [id], workArea: s.area)[id]?.width, 500)
        s.frames[WindowID(2)] = nil
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange alone") }
        drain(c)
        XCTAssertEqual(c.state.layouts["7"]?.windowIDs, [id])
        var starts = 0
        for _ in 0..<10 {
            if c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7") { starts += 1 }
            drain(c)
        }
        XCTAssertEqual(starts, 1)
    }

    /// A solo probe done on one display does not cover another: there the maximum was learned beside another window, so the window gets one probe once alone.
    func testSoloProbeOnOneDisplayDoesNotCoverAnother() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 500, height: 700)]
        s.fixed[id] = CGSize(width: 500, height: 700)
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange alone on the first display") }
        drain(c)
        XCTAssertFalse(c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7"), "learned alone from the whole area")

        // The Space now sits on a display below (another work area); the maximum is learned again beside another window.
        s.area = CGRect(x: 375, y: 1465, width: 1920, height: 1055)
        s.frames = [id: CGRect(x: 375, y: 1465, width: 500, height: 700), WindowID(2): CGRect(x: 1335, y: 1465, width: 960, height: 1055)]
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange beside another window") }
        drain(c)
        XCTAssertEqual(c.state.layouts["7"]?.windowIDs.count, 2)
        XCTAssertEqual(c.knowledge.maximums(for: [id], workArea: s.area)[id], CGSize(width: 500, height: 700))
        s.frames[WindowID(2)] = nil
        guard case .started = c.arrange(source: "test") else { return XCTFail("arrange alone on the second display") }
        drain(c)
        var starts = 0
        for _ in 0..<10 {
            if c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7") { starts += 1 }
            drain(c)
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(s.frames[id], CGRect(x: 375 + 710, y: 1465, width: 500, height: 700))
    }

    /// Each new tiling area on the same display gets its own solo probe; the retry limit belongs to one tiling area.
    func testEveryNewTilingAreaGetsItsOwnSoloProbe() throws {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 740, height: 1080)]
        s.maximumSizes[id] = CGSize(width: 740, height: 0)
        for outerRight in [0, 50, 100, 150, 200] {
            try "[gaps]\nouter-right = \(outerRight)\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            _ = c.reloadConfig(source: "test")
            drain(c)
            XCTAssertEqual(c.config.outerRight, Double(outerRight))
            let tilesWidth = s.area.width - CGFloat(outerRight)
            s.written.removeAll()
            for _ in 0..<8 {
                _ = c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7")
                drain(c)
            }
            XCTAssertTrue(s.written.contains { $0.1.width == tilesWidth }, "the whole tiling area was asked for with outer-right \(outerRight)")
            XCTAssertEqual(s.frames[id]?.minX, floor((tilesWidth - 740) / 2), "centered with outer-right \(outerRight)")
        }
    }

    /// A slow app applying a write after the deadline changes the frame, but that is not the user's doing, so the count is kept.
    func testLateWriteDoesNotResetTheRetryLimit() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        s.frames[WindowID(3)] = CGRect(x: 200, y: 600, width: 520, height: 408)
        s.focused = WindowID(3)
        s.lateWrites = true
        var starts = 0
        for _ in 0..<10 {
            if c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") } { starts += 1 }
            drain(c)
        }
        XCTAssertLessThanOrEqual(starts, 2)
        XCTAssertTrue(c.waiting.contains(WindowID(3)))
        // Once the user moves it, integration can be tried again.
        s.inputActivityCount += 1
        s.frames[WindowID(3)] = CGRect(x: 300, y: 300, width: 600, height: 400)
        s.lateWrites = false
        XCTAssertTrue(c.operationsQueue.sync { c.placeMissing(current: s.census(7), spaceKey: "7") })
        drain(c)
    }

    /// Once a focus move is confirmed, status reports that window right away.
    func testStatusReportsTheFocusedWindowRightAfterFocusMoves() {
        let (c, s, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        s.focused = WindowID(2)
        _ = c.status()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(c.status().focusedWindow, WindowID(2))
        guard case .started = c.runFocus(WindowID(1), source: "cli") else { return XCTFail("focus should start") }
        drain(c)
        XCTAssertEqual(c.status().focusedWindow, WindowID(1))
    }

    func testSoloFillDoesNotRetryForGenuineCap() {
        let (c, s, root) = make(layouts: ["7": Layout(root: .leaf(WindowID(1)))])
        defer { try? FileManager.default.removeItem(at: root) }
        let id = WindowID(1)
        s.frames = [id: CGRect(x: 0, y: 0, width: 1000, height: 700)]
        s.fixed[id] = CGSize(width: 1000, height: 700)
        c.knowledge.recordPullback(
            id: id, requested: s.area, actual: s.frames[id]!, spaceID: 7, workArea: s.area, tolerance: 1)
        var starts = 0
        for index in 0..<10 {
            if c.fillSoloIfNeeded(current: s.census(7), spaceKey: "7") { starts += 1 }
            drain(c)
            if index == 2 || index == 6 {
                _ = c.arrange(source: "test")
                drain(c)
            }
        }
        XCTAssertLessThanOrEqual(starts, 4)
    }

    func testSoloWindowFillsTheWorkArea() {
        let (coordinator, system, root) = make(layouts: [
            "7": Layout(root: .leaf(WindowID(1)), leftoverHeights: [WindowID(1): 440])
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        system.frames = [WindowID(1): CGRect(x: 80, y: 60, width: 640, height: 440)]
        system.focused = WindowID(1)
        XCTAssertTrue(coordinator.fillSoloIfNeeded(current: system.census(7), spaceKey: "7"))
        drain(coordinator)
        let tile = system.area.integralInset
        XCTAssertEqual(system.frames[WindowID(1)]?.width, tile.width)
        XCTAssertEqual(system.frames[WindowID(1)]?.height, tile.height)
        XCTAssertEqual(system.frames[WindowID(1)]?.minX, tile.minX)
        XCTAssertEqual(system.frames[WindowID(1)]?.minY, tile.minY)
    }

    func testUntrustedStatusIsInjectable() {
        let (coordinator, system, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        system.trusted = false
        XCTAssertFalse(coordinator.status().trusted)
        XCTAssertFalse(coordinator.status().autoAvailable)
        system.trusted = true
        XCTAssertTrue(coordinator.status().autoAvailable)
        XCTAssertTrue(coordinator.notStartedMessage.contains("Arrange Now"))
    }

    func testIntegrateGivesUpAfterTwoIdenticalFailuresThenRecovers() {
        let (coordinator, system, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.timeOutWrites = true
        for _ in 0..<10 {
            _ = coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") }
            drain(coordinator)
        }
        XCTAssertLessThanOrEqual(system.writes, 2, "two failures at the same frame stop automatic writes")
        XCTAssertTrue(coordinator.waiting.contains(WindowID(3)))
        system.timeOutWrites = false
        guard case .started = coordinator.integrateWaiting(source: "test") else { return XCTFail("integrate did not start") }
        drain(coordinator)
        XCTAssertFalse(coordinator.waiting.contains(WindowID(3)))
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    /// When the trigger window stops being an arrangement target twice at the same frame, automatic retries stop and it waits.
    func testIntegrateGivesUpAfterNotPossible() {
        let (coordinator, system, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        var snapshots = 0
        system.onSnapshot = {
            snapshots += 1
            system.kind = snapshots % 2 == 1 ? .standard : .dialog
        }
        var starts = 0
        for _ in 0..<10 {
            if coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") } { starts += 1 }
            drain(coordinator)
        }
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(system.writes, 0)
        XCTAssertTrue(coordinator.waiting.contains(WindowID(3)))
        XCTAssertFalse(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
    }

    func testWindowListIsCopiedOnlyForTrackedWindowsThatAreNotVisible() {
        XCTAssertTrue(Coordinator.windowsNeedingListCheck(tracked: [], visible: [WindowID(1)]).isEmpty)
        // A floating window visible on the current Space needs no full window list.
        XCTAssertTrue(Coordinator.windowsNeedingListCheck(tracked: [WindowID(1)], visible: [WindowID(1), WindowID(2)]).isEmpty)
        XCTAssertEqual(Coordinator.windowsNeedingListCheck(tracked: [WindowID(1), WindowID(3)], visible: [WindowID(1)]), [WindowID(3)])
    }

    func testIntegrateFailureIgnoresInterruptions() {
        XCTAssertTrue(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .nothingToDo, stopReason: nil))
        XCTAssertTrue(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .notPossible, stopReason: nil))
        XCTAssertTrue(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .partial, stopReason: nil))
        XCTAssertTrue(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .partial, stopReason: .appUnresponsive))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .interrupted, stopReason: .paused))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .partial, stopReason: .userInput))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .partial, stopReason: .spaceChanged))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .notPossible, stopReason: .permissionLost))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .nothingToDo, stopReason: .targetsChanged))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .notPossible, stopReason: .cancelled))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "auto-integrate", outcome: .complete, stopReason: nil))
        XCTAssertFalse(Coordinator.countsAsIntegrateFailure(kind: "arrange", outcome: .nothingToDo, stopReason: nil))
    }

    func testMouseReturnWritesNothingWhenPaused() {
        let (coordinator, system, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange") }
        drain(coordinator)
        guard let frame = system.frames[WindowID(1)] else { return XCTFail("missing frame") }
        system.frames[WindowID(1)] = frame.offsetBy(dx: 40, dy: 30)
        let before = system.writes
        coordinator.control.paused = true
        let layout = coordinator.state.layouts["7"]!
        XCTAssertTrue(coordinator.detectManualEdit(current: system.census(7), spaceKey: "7", layout: layout, managed: Set(layout.windowIDs)))
        drain(coordinator)
        XCTAssertEqual(system.writes, before, "Pause immediately after a drop must not write the original frame back")
    }

    func testReconcileLimitDoesNotStopAnotherSpace() {
        let row = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        let (coordinator, system, root) = make(layouts: ["7": row, "8": row])
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange 7") }
        drain(coordinator)
        system.space = 8
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange 8") }
        drain(coordinator)
        system.frames[WindowID(1)] = (system.frames[WindowID(1)] ?? .zero).offsetBy(dx: 80, dy: 0)
        system.timeOutWrites = true
        system.space = 7
        let layout = coordinator.state.layouts["7"]!
        let managed = Set(layout.windowIDs)
        for _ in 0..<3 {
            XCTAssertTrue(coordinator.reconcileDrift(current: system.census(7), spaceKey: "7", layout: layout, managed: managed))
            drain(coordinator)
        }
        let stalled = system.writes
        XCTAssertFalse(coordinator.reconcileDrift(current: system.census(7), spaceKey: "7", layout: layout, managed: managed))
        XCTAssertEqual(system.writes, stalled)
        system.space = 8
        let other = coordinator.state.layouts["8"]!
        XCTAssertTrue(coordinator.reconcileDrift(current: system.census(8), spaceKey: "8", layout: other, managed: Set(other.windowIDs)))
        drain(coordinator)
        XCTAssertGreaterThan(system.writes, stalled)
    }

    func testUnclassifiedWindowDoesNotRepeatTheSnapshot() throws {
        let (coordinator, system, root) = make()
        defer { try? FileManager.default.removeItem(at: root) }
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        try "[[rule]]\napp = \"test\"\naction = \"ignore\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.snapshotCount = 0
        for _ in 0..<10 {
            XCTAssertFalse(coordinator.operationsQueue.sync { coordinator.placeMissing(current: system.census(7), spaceKey: "7") })
        }
        XCTAssertEqual(system.snapshotCount, 1)
    }
}
