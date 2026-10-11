import XCTest
@testable import MacSupport

final class ObserverRunLoopTests: XCTestCase {
    func testObserverRunLoopStaysAliveBeforeSourcesAttach() throws {
        let observer = WakeObserver { _ in }
        observer.start()
        defer { observer.stop() }
        let thread = try XCTUnwrap(Mirror(reflecting: observer).children.first { $0.label == "loopThread" }?.value as? Thread)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(thread.isFinished, "The AX run-loop thread must survive until asynchronous observer attachment")
        observer.stop()
        observer.start()
        let restarted = try XCTUnwrap(Mirror(reflecting: observer).children.first { $0.label == "loopThread" }?.value as? Thread)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(restarted.isFinished, "start after stop must be able to accept sources again")
    }

    func testObserverLoopWaitsWhileNoSourceIsAttached() {
        let observer = WakeObserver { _ in }
        observer.start()
        defer { observer.stop() }
        let before = observer.loopPasses
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertLessThanOrEqual(observer.loopPasses - before, 2, "an empty run loop must wait instead of spinning")
    }
}

/// A per-observation watch request skips main only when no work is waiting on main and the requested set equals the attached observers.
final class WatchGateTests: XCTestCase {
    private let a: Set<pid_t> = [10, 20]

    func testASteadyAttachedSetDoesNotWakeMain() {
        var gate = WatchGate()
        XCTAssertTrue(gate.needsMain(a))
        gate.attached = a
        XCTAssertEqual((0..<10).filter { _ in gate.needsMain(a) }.count, 0)
    }

    /// Requests empty, A, A sent while main is blocked all arrive: if the empty one later detaches observers and
    /// reattaching for the first A fails, the last A tries again.
    func testRequestsReachMainWhileEarlierRequestsAreQueued() {
        var gate = WatchGate()
        gate.attached = a
        for wanted in [Set<pid_t>(), a, a] {
            XCTAssertTrue(gate.needsMain(wanted))
            gate.pending += 1 // request watch sent to main
        }
    }

    /// While an observer is being attached, a request for the same set still reaches main, even if the completion is queued first (to detach after it).
    func testRequestsReachMainWhileAnAttachmentIsInFlight() {
        var gate = WatchGate()
        gate.attached = a
        gate.pending = 1
        XCTAssertTrue(gate.needsMain(a))
        gate.pending = 0
        XCTAssertFalse(gate.needsMain(a))
    }

    /// An app whose observer could not be attached is retried on every observation until an attachment fails.
    func testAnAppWithoutAnObserverIsRetriedEveryTime() {
        var gate = WatchGate()
        gate.attached = a
        XCTAssertEqual((0..<10).filter { _ in gate.needsMain(a.union([30])) }.count, 10)
        XCTAssertTrue(gate.needsMain([10]), "a smaller set must reach main to detach the rest")
    }

    /// After a failed attachment the app is retried no sooner than 1 s, then 2, 4, and 8 s; observations in between do not wake main for it.
    func testAFailedAttachmentBacksOffBeforeRetrying() {
        var gate = WatchGate()
        gate.attached = a
        let t0 = Date()
        var expected: [TimeInterval] = []
        var now = t0
        for _ in 0..<5 {
            gate.noteAttachFailure(30, now: now)
            let wait = gate.retryNotBefore[30]!.timeIntervalSince(now)
            expected.append(wait)
            XCTAssertFalse(gate.needsMain(a.union([30]), now: now.addingTimeInterval(wait - 0.01)), "still backing off")
            XCTAssertTrue(gate.needsMain(a.union([30]), now: now.addingTimeInterval(wait)), "retry is due")
            now = now.addingTimeInterval(wait)
        }
        XCTAssertEqual(expected, [1, 2, 4, 8, 8])
        XCTAssertTrue(gate.needsMain([10], now: t0), "a smaller set still reaches main to detach the rest")
        gate.noteAttached(30)
        XCTAssertNil(gate.retryNotBefore[30])
        gate.noteAttachFailure(30, now: now)
        XCTAssertEqual(gate.retryNotBefore[30]!.timeIntervalSince(now), 1, "a success starts the backoff over")
        gate.forget(30)
        XCTAssertNil(gate.retryNotBefore[30], "a quit app is forgotten")
    }
}

/// Every regular app is observed, so a window opened by an app with no window on the current Space is announced.
final class WatchSetTests: XCTestCase {
    func testEveryRegularAppAndEveryCensusAppIsObservedExceptLazySpace() {
        XCTAssertEqual(WakeObserver.desired(census: [10, 99, -1], regular: [10, 20, 0], me: 99), [10, 20],
                       "census apps include apps missing from LaunchServices; never LazySpace itself or a non-positive pid")
    }

    func testTheFrontAppAttachesFirstThenCensusAppsThenTheRest() {
        XCTAssertEqual(WakeObserver.attachOrder([5, 7, 20, 30], front: 30, census: [20, 7]), [30, 7, 20, 5])
        XCTAssertEqual(WakeObserver.attachOrder([5, 7], front: nil, census: []), [5, 7])
    }

    /// Only window creation wakes for an app without a window in the census, so moves of windows elsewhere add no observations.
    func testOnlyWindowCreationWakesForAppsOutsideTheCensus() {
        XCTAssertTrue(WakeObserver.wakes(created: true, pid: 40, census: [10]))
        XCTAssertTrue(WakeObserver.wakes(created: true, pid: nil, census: [10]))
        XCTAssertFalse(WakeObserver.wakes(created: false, pid: 40, census: [10]))
        XCTAssertTrue(WakeObserver.wakes(created: false, pid: 10, census: [10]))
        XCTAssertFalse(WakeObserver.wakes(created: false, pid: nil, census: [10]), "an unreadable owner is not in the census")
    }

    /// An app outside the census that keeps failing gives up at the 8 s step until it enters the census or is activated (`forget`).
    func testAnAppOutsideTheCensusGivesUpAfterTheLongestBackoff() {
        var gate = WatchGate()
        var now = Date()
        for _ in 0..<4 { gate.noteAttachFailure(40, now: now, inCensus: false); now = gate.retryNotBefore[40]! }
        XCTAssertTrue(gate.mayAttach(40, now: now), "1, 2, 4, 8 s: the 8 s retry is due")
        gate.noteAttachFailure(40, now: now, inCensus: false)
        XCTAssertFalse(gate.mayAttach(40, now: now.addingTimeInterval(3600)), "given up")
        XCTAssertFalse(gate.needsMain([40], now: now.addingTimeInterval(3600)), "a given-up app never wakes main")
        gate.prune(keeping: [40], census: [40])
        XCTAssertTrue(gate.mayAttach(40, now: now), "entering the census starts it over")
        for _ in 0..<5 { gate.noteAttachFailure(41, now: now, inCensus: true) }
        XCTAssertLessThan(gate.retryNotBefore[41]!, now.addingTimeInterval(9), "a census app keeps retrying every 8 s")
    }

    /// Stillness needs an observer that registered both window moves and resizes for every app; otherwise there is no evidence.
    func testGeometryEvidenceNeedsBothRegistrationsForEveryApp() {
        let t0 = Date()
        XCTAssertNil(WakeObserver.geometryQuiet(pids: [10, 20], covered: [10], notices: [:], since: t0), "app 20 is not covered")
        XCTAssertEqual(WakeObserver.geometryQuiet(pids: [10, 20], covered: [10, 20], notices: [:], since: t0), true)
        XCTAssertEqual(WakeObserver.geometryQuiet(pids: [10, 20], covered: [10, 20], notices: [20: t0.addingTimeInterval(0.01)], since: t0), false)
        XCTAssertEqual(WakeObserver.geometryQuiet(pids: [10], covered: [10], notices: [10: t0.addingTimeInterval(-0.01)], since: t0), true, "a notice before the sample")
    }

    /// Retry state of an app no longer wanted (quit, or no longer regular) is dropped even when nothing else would wake main.
    func testRetryStateOfAppsNoLongerWantedIsDropped() {
        var gate = WatchGate()
        gate.noteAttachFailure(40, now: Date())
        gate.prune(keeping: [10], census: [10])
        XCTAssertNil(gate.retryNotBefore[40])
    }
}
