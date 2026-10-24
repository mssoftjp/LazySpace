import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// A mouse edit is a frame change the user made: CGWindowList also lists frames macOS only shows (a Space switch slide,
/// Mission Control), and those are never edits. Measured on a real Mac: while the leaving Space slides away, its windows are
/// listed shifted at their own size and SkyLight still reports that Space as current.
final class MouseEditEvidenceTests: XCTestCase {
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
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.geometryQuiet = { _, _ in true }
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

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    /// A drag that moved no window, such as selecting text, seen by the next observation: it leaves a mouse edit pending until input is quiet.
    /// The first quiet observation then decides it; here that observation comes while macOS shows other frames.
    private func dragInsideAWindowThenWaitForQuiet() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
    }

    /// CGWindowList's frames when the windows are shown `dx` points to the right; Accessibility still reports them in place.
    private func shown(shiftedBy dx: CGFloat) {
        system.censusBounds = [
            WindowID(1): CGRect(x: dx, y: 0, width: 960, height: 1080),
            WindowID(2): CGRect(x: 960 + dx, y: 0, width: 960, height: 1080)
        ]
    }

    func testLeavingSlideAfterADragWritesNothing() {
        dragInsideAWindowThenWaitForQuiet()
        let writes = system.writes
        // Leaving for a Space on the left: window 1's center is already over window 2's tile at the first look.
        for dx: CGFloat in [700, 1100, 1500, 1900] {
            shown(shiftedBy: dx)
            tick()
        }
        XCTAssertEqual(system.writes, writes, "nothing is written while the Space slides away")
        XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-swap")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
    }

    /// The last frame of a slide can stay put for a tick; Accessibility still has the windows in place, so there is no edit.
    func testStillFramesThatAccessibilityDoesNotReportAreNoEdit() {
        dragInsideAWindowThenWaitForQuiet()
        let writes = system.writes
        shown(shiftedBy: 700)
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes)
        XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-swap")
        XCTAssertFalse(coordinator.testingMouseEditPending(), "the drag is settled: it made no edit")
    }

    /// Mission Control lists the thumbnails' scaled frames; a drag there starts no mouse arrangement.
    func testMissionControlFramesAfterADragStartNoMouseArrangement() {
        var kinds: [String] = []
        coordinator.onTerminalResult = { kinds.append($0.kind) }
        dragInsideAWindowThenWaitForQuiet()
        let writes = system.writes
        system.censusBounds = [
            WindowID(1): CGRect(x: 180, y: 200, width: 768, height: 864),
            WindowID(2): CGRect(x: 1150, y: 200, width: 768, height: 864)
        ]
        tick(); tick(); tick()
        XCTAssertEqual(system.writes, writes)
        XCTAssertFalse(kinds.contains { $0.hasPrefix("mouse-") }, "\(kinds)")
    }

    /// The reads that confirm an edit run on the queue commands wait on: they stop at a total budget and as soon as new input arrives.
    func testEvidenceReadsStopAtTheBudgetAndOnInput() {
        var clock = Date(timeIntervalSince1970: 0)
        let ids = [WindowID(1), WindowID(2), WindowID(3)]
        let slow = Coordinator.readEvidence(ids, deadline: clock.addingTimeInterval(0.5), now: { clock }, interrupted: { false }) { id, _ in
            clock.addTimeInterval(0.4)
            return .frame(CGRect(x: Double(id.raw), y: 0, width: 10, height: 10))
        }
        XCTAssertEqual(slow, .frames([WindowID(1): CGRect(x: 1, y: 0, width: 10, height: 10), WindowID(2): CGRect(x: 2, y: 0, width: 10, height: 10)], complete: false),
                       "the third read would start after the budget")
        var input = false
        let stopped = Coordinator.readEvidence(ids, deadline: .distantFuture, now: Date.init, interrupted: { input }) { _, _ in
            input = true
            return .frame(.zero)
        }
        XCTAssertEqual(stopped, .interrupted)
        var duringLast = false
        let last = Coordinator.readEvidence([WindowID(1)], deadline: .distantFuture, now: Date.init, interrupted: { duringLast }) { _, _ in
            duringLast = true
            return .failed("no answer")
        }
        XCTAssertEqual(last, .interrupted, "input during the last read, even one that failed")
    }

    /// The only edited window does not answer, and a key is pressed meanwhile: the drag waits for the quiet time instead of being dropped.
    func testInputDuringAFailedLastReadKeepsTheDrag() {
        coordinator.geometryQuiet = { _, _ in nil } // no move or resize observer: the quiet path decides
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 960, height: 980) // only window 1 changed
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        system.unreadableFrames = [WindowID(1)]
        system.onFrameRead = { [unowned self] _ in system.inputActivityCount += 1 }
        tick()
        system.onFrameRead = nil
        system.unreadableFrames = []
        XCTAssertTrue(coordinator.testingMouseEditPending(), "the drag waits for the quiet time again")
    }

    /// Input while the edited windows are read leaves the drag for the quiet path instead of losing it.
    func testInputDuringTheEvidenceReadsKeepsTheDrag() {
        coordinator.geometryQuiet = { _, _ in nil } // no move or resize observer: the quiet path decides
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1200, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        var reads = 0
        system.onFrameRead = { [unowned self] _ in
            reads += 1
            if reads == 1 { system.inputActivityCount += 1 } // a key press while the first window is read
        }
        let writes = system.writes
        tick()
        system.onFrameRead = nil
        XCTAssertEqual(reads, 1, "the second window is not read on a stale observation")
        XCTAssertEqual(system.writes, writes)
        XCTAssertTrue(coordinator.testingMouseEditPending(), "the drag waits for the quiet time again")
        tick() // sees the key press, which starts the quiet time again
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick(); tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "mouse-resize", "adopted once input is quiet")
    }

    /// A real drop, which Accessibility reports too, still swaps the two windows.
    func testADropOntoTheOtherWindowStillSwaps() {
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 700, y: 0, width: 960, height: 1080)
        mouse(.leftMouseUp)
        for _ in 0..<4 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)]?.minX, 960)
        XCTAssertEqual(system.frames[WindowID(2)]?.minX, 0)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(2), WindowID(1)])
    }
}
