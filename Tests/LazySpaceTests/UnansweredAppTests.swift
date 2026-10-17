import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// A new window joins while another layout app does not answer, as in AeroSpace: after a short wait the windows that answered are committed,
/// the silent app's window is left where it is, and it returns to its place once its app answers.
final class UnansweredAppTests: XCTestCase {
    private var root: URL!
    private var store: StateStore!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        system.pids = [WindowID(1): 11, WindowID(2): 22]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.fitRetryClock = { [unowned self] in now }
        coordinator.backoffClock = { [unowned self] in now }
        coordinator.departureClock = { [unowned self] in now }
        tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
        // The launch fit finds the windows in place and commits the plan.
        tick(); tick(); tick()
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

    private func openWindowThree(pid: Int32) {
        system.frames[WindowID(3)] = CGRect(x: 300, y: 200, width: 500, height: 400)
        system.pids[WindowID(3)] = pid
    }

    private var layout: [WindowID]? { coordinator.state.layouts["7"]?.windowIDs }

    /// Opens window 3 while window 2's app does not answer and runs the wait out until the reclaim.
    private func reclaimWindowTwo() {
        system.unansweringPIDs = [22]
        let writes = system.writes
        openWindowThree(pid: 33)
        tick(); tick()
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        XCTAssertEqual(system.writes, writes, "nothing is written while waiting")
        XCTAssertFalse(layout?.contains(WindowID(3)) ?? false)
        tick()
    }

    func testNewWindowJoinsAfterTheWaitWhileAnotherAppDoesNotAnswer() {
        reclaimWindowTwo()
        XCTAssertEqual(layout.map { Set($0) }, [WindowID(1), WindowID(3)])
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 960, y: 0, width: 960, height: 1080), "the silent app's window is left where it is")
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(system.frames[WindowID(3)]?.width, 960)
        XCTAssertFalse(coordinator.waiting.contains(WindowID(3)))
        XCTAssertNotNil(coordinator.testingPlan(spaceKey: "7"))
    }

    /// A reclaimed window is not polled: it is read again only after a change on the Space, and once its app answers it returns to its place.
    func testTheReclaimedWindowReturnsToItsPlaceOnTheNextChangeAfterItsAppAnswers() {
        reclaimWindowTwo()
        tick()
        func reads() -> Int { system.snapshotScopes.filter { $0?.contains(WindowID(2)) == true }.count }
        let before = reads()
        system.unansweringPIDs = []
        for _ in 0..<5 { now += 5; tick() }
        XCTAssertEqual(reads(), before, "not polled without a change")
        XCTAssertEqual(layout?.contains(WindowID(2)), false)
        system.frontWindow = WindowID(3)
        tick(); tick()
        let ids = layout ?? []
        XCTAssertEqual(Set(ids), [WindowID(1), WindowID(2), WindowID(3)])
        XCTAssertEqual(ids.firstIndex(of: WindowID(2)), ids.firstIndex(of: WindowID(1)).map { $0 + 1 }, "it returns beside its old neighbor")
    }

    /// A window whose own app does not answer cannot be waited into the layout; it is retried without counting failures and joins once its app answers.
    func testNewWindowWhoseOwnAppDoesNotAnswerJoinsOnceItAnswers() {
        system.unansweringPIDs = [33]
        openWindowThree(pid: 33)
        tick(); tick()
        for _ in 0..<3 { now += 1; tick() }
        system.unansweringPIDs = []
        now += 5
        tick(); tick()
        XCTAssertEqual(layout?.contains(WindowID(3)), true)
    }

    /// A reclaim whose writes do not apply in time counts as a failure of the window it adds, so the window gives up instead of waiting again forever.
    func testAReclaimThatCannotWriteGivesUp() {
        system.unansweringPIDs = [22]
        system.timeOutWrites = true
        openWindowThree(pid: 33)
        let scope: Set<WindowID> = [WindowID(1), WindowID(2), WindowID(3)]
        func tries() -> Int { system.snapshotScopes.filter { $0 == scope }.count }
        tick(); tick()
        for _ in 0..<20 { now += 5; tick() }
        let settled = tries()
        for _ in 0..<10 { now += 5; tick() }
        XCTAssertEqual(tries(), settled, "no more tries once it gave up")
        XCTAssertTrue(coordinator.waiting.contains(WindowID(3)))
    }

    /// A window that opens or closes during the delay waits for it too: no observation reads the silent app before the delay is over.
    func testWindowsOpeningOrClosingDuringTheDelayWaitForIt() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        let scoped = system.snapshotScopes.filter { $0 != nil }.count
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.pids[WindowID(4)] = 44
        tick(); tick()
        system.frames[WindowID(1)] = nil
        tick(); tick()
        XCTAssertEqual(system.snapshotScopes.filter { $0 != nil }.count, scoped, "nothing is tried before the delay is over")
        now += 1.1
        tick(); tick()
        XCTAssertGreaterThan(system.snapshotScopes.filter { $0 != nil }.count, scoped, "the delay over, the Space is tried again")
    }

    /// Each try reads the silent app once: looking at the new window asks only its own app, never every app on the Space.
    func testEachTryReadsTheSilentAppOnce() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        let before = system.snapshotScopes.count
        let observations = system.snapshotCount
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        let scopes = system.snapshotScopes.dropFirst(before)
        // Every scoped observation is built on an unscoped one in the fake; the rest asked every app.
        XCTAssertEqual(system.snapshotCount - observations, scopes.count, "no observation asks every app")
        XCTAssertFalse(scopes.contains { $0 == nil }, "no observation asks every app")
        XCTAssertEqual(scopes.filter { $0?.contains(WindowID(2)) == true }.count, 3, "one read of the silent app per try")
    }

    /// Any completed arrangement of the Space ends its wait: a later silence waits the full delay again instead of reclaiming at once.
    func testACompletedArrangementEndsTheWait() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        system.unansweringPIDs = []
        _ = coordinator.arrange(source: "test")
        drain()
        XCTAssertEqual(layout?.contains(WindowID(3)), true)
        system.unansweringPIDs = [22]
        let writes = system.writes
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.pids[WindowID(4)] = 44
        tick(); tick()
        XCTAssertEqual(system.writes, writes, "a new silence waits again")
    }

    /// Each try reads the focused window once (a frozen front app costs one read timeout per try, not two).
    func testEachTryReadsFocusOnce() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        let reads = system.focusReads
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        XCTAssertLessThanOrEqual(system.focusReads - reads, 3, "one focus read per try")
    }

    /// Input that stops a try before it writes keeps the count: the reclaim still comes after the same four tries.
    func testInputThatStopsATryKeepsTheWaitCount() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        now += 1.1; tick()
        var stop = true
        system.onSnapshot = { [unowned self] in
            if stop { stop = false; system.inputActivityCount += 1 }
        }
        now += 2.1; tick()
        system.onSnapshot = nil
        tick()
        now += 4.1; tick()
        tick()
        XCTAssertEqual(layout?.contains(WindowID(3)), true, "reclaimed after four tries despite the stopped one")
    }

    /// When the reclaim never comes (the window being added stopped answering too), the run of tries is over once no try came for 10 s:
    /// a later window waits the full delay again.
    func testARunOfTriesWithNoTryFor10SecondsIsOver() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        for wait in [1.0, 2.0, 4.0] { now += wait + 0.1; tick() }
        system.unansweringPIDs = [22, 33]
        tick()
        now += 11
        let writes = system.writes
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.pids[WindowID(4)] = 44
        tick(); tick()
        XCTAssertEqual(system.writes, writes, "a new window waits the full delay again")
    }

    /// A window that leaves during the delay is remembered at once, so it returns to its place even if another arrangement runs first.
    func testAWindowLeavingDuringTheDelayKeepsItsPlace() {
        system.unansweringPIDs = [22]
        openWindowThree(pid: 33)
        tick(); tick()
        system.hiddenFromCensus = [WindowID(1)]
        system.minimizedWindows = [WindowID(1)]
        tick(); tick()
        system.unansweringPIDs = []
        now += 1.1
        system.frames[WindowID(4)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.pids[WindowID(4)] = 44
        tick(); tick(); tick(); tick()
        XCTAssertEqual(layout?.contains(WindowID(1)), false)
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        now += 1
        tick(); tick(); tick()
        let ids = layout ?? []
        let next = ids.firstIndex(of: WindowID(1)).flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }
        XCTAssertEqual(next, WindowID(2), "it returns beside its old neighbor: \(ids)")
    }

    /// A reclaimed window whose app answers only after the 180 s departure memory is still read on the next change and joins (as a new window).
    func testAReclaimedWindowStillJoinsAfterItsPlaceIsForgotten() {
        reclaimWindowTwo()
        tick()
        system.unansweringPIDs = []
        now += 200
        tick(); tick()
        system.frontWindow = WindowID(3)
        tick(); tick()
        XCTAssertEqual(layout?.contains(WindowID(2)), true)
    }

    /// A reclaimed window minimized and shown again counts as a change: it is read again and joins once its app answers.
    func testAReclaimedWindowShownAgainIsReadAgain() {
        reclaimWindowTwo()
        tick()
        system.hiddenFromCensus = [WindowID(2)]
        system.minimizedWindows = [WindowID(2)]
        tick(); tick()
        system.unansweringPIDs = []
        system.hiddenFromCensus = []
        system.minimizedWindows = []
        tick(); tick()
        XCTAssertEqual(layout?.contains(WindowID(2)), true)
    }
}
