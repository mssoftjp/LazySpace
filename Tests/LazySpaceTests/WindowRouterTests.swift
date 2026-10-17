import XCTest
import CoreGraphics
import LayoutCore
@testable import LazySpaceApp

/// State of `WindowRouter` (tracking new windows for `action = "space"` rules) only.
final class WindowRouterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)
    private let start = Date(timeIntervalSince1970: 1_000)
    private func w(_ id: UInt32, pid: Int32 = 100, start: Date? = nil) -> WindowIdentity {
        WindowIdentity(window: WindowID(id), pid: pid, processStart: start ?? self.start)
    }

    /// The full window list at launch only marks windows known (Spaces are not marked observed). A Space shown for the first time marks all its windows known.
    func testSeedingAtLaunchAndOnFirstDisplay() {
        var router = WindowRouter()
        router.seedAtLaunch([(w(1), [7]), (w(2), [8])])
        XCTAssertTrue(router.seededSpaces.isEmpty, "launch does not mark Spaces as visited")
        XCTAssertEqual(router.observe([w(1)], space: 7, now: t0) { _ in true }, [], "the first display of Space 7 seeds")
        XCTAssertEqual(router.observe([w(3)], space: 9, now: t0) { _ in true }, [], "the first display of Space 9 seeds its windows, even ones opened after launch")
        XCTAssertEqual(router.phase(of: WindowID(3)), .seen)
        XCTAssertEqual(router.observe([w(3), w(4), w(2)], space: 9, now: t0) { _ in true }, [WindowID(4)],
                       "a window that appears later is new; a window known at launch that moves here is not")
        XCTAssertEqual(router.observe([w(5)], space: 7, now: t0) { _ in false }, [], "no rule for its app: seen")
        XCTAssertEqual(router.phase(of: WindowID(5)), .seen)
    }

    /// Window ID reuse within a process: an ID reappearing after its disappearance was confirmed is a new window (the lifetime number advances). An ID that keeps appearing without a confirmed disappearance stays known (not sent).
    /// The same ID in another process (different pid, or same pid with a different launch time) is a new window. A window whose identity changes during classification is ambiguous and not sent.
    func testWindowIdentityAndReuse() {
        func visited(_ windows: [WindowIdentity]) -> WindowRouter {
            var router = WindowRouter()
            _ = router.observe(windows, space: 7, now: t0) { _ in true }
            return router
        }
        var router = visited([w(1)])
        XCTAssertEqual(router.observe([w(1)], space: 7, now: t0) { _ in true }, [], "the same window, even if its size or title changed")
        router.noteDestroyed([WindowID(1)])
        XCTAssertEqual(router.lifetime(of: WindowID(1)), 1)
        var reborn = w(1); reborn.lifetime = 1
        XCTAssertEqual(router.observe([reborn], space: 7, now: t0) { _ in true }, [WindowID(1)], "reappearing after confirmed destruction: new")
        var other = visited([w(2)])
        XCTAssertEqual(other.observe([w(2, pid: 200)], space: 7, now: t0) { _ in true }, [WindowID(2)], "another process")
        var reused = visited([w(3)])
        XCTAssertEqual(reused.observe([w(3, start: Date(timeIntervalSince1970: 2_000))], space: 7, now: t0) { _ in true }, [WindowID(3)], "pid reused by a new process")
        reused.forgetProcess(100)
        XCTAssertNil(reused.phase(of: WindowID(3)), "a quit app's windows are forgotten")
        var ambiguous = visited([])
        _ = ambiguous.observe([w(4)], space: 7, now: t0) { _ in true }
        XCTAssertEqual(ambiguous.phase(of: WindowID(4)), .classifying(since: t0, space: 7))
        XCTAssertEqual(ambiguous.observe([w(4, start: Date(timeIntervalSince1970: 3_000))], space: 7, now: t0) { _ in true }, [], "identity changed while classifying")
        XCTAssertEqual(ambiguous.phase(of: WindowID(4)), .seen, "retired, never sent")
    }

    /// Classification up to 1.5 s, preparation up to 3 s; after that, seen (normal placement). Excluded from the layout only while classifying, preparing, or sending. consumed is not excluded and never resent.
    func testPhasesAndExclusions() {
        var router = WindowRouter()
        _ = router.observe([], space: 7, now: t0) { _ in true }
        _ = router.observe([w(1), w(2)], space: 7, now: t0) { _ in true }
        XCTAssertEqual(Set(router.exclusions().keys), [WindowID(1), WindowID(2)])
        router.markReady(WindowID(1), rule: 0, now: t0.addingTimeInterval(0.5))
        router.markReady(WindowID(2), rule: 0, now: t0.addingTimeInterval(1.6))
        XCTAssertEqual(router.phase(of: WindowID(2)), .classifying(since: t0, space: 7), "a match after the period does not make it ready")
        XCTAssertEqual(router.ready(on: 7).map(\.window), [WindowID(1)])
        XCTAssertEqual(router.expire(now: t0.addingTimeInterval(1.6)), [WindowID(2)], "classification ends after 1.5 s")
        XCTAssertEqual(router.phase(of: WindowID(2)), .seen)
        XCTAssertEqual(router.expire(now: t0.addingTimeInterval(3.6)), [WindowID(1)], "a ready window waits for the operation slot up to 3 s")
        _ = router.observe([w(3)], space: 7, now: t0) { _ in true }
        router.markReady(WindowID(3), rule: 0, now: t0)
        router.markSending(WindowID(3))
        XCTAssertEqual(router.exclusions()[WindowID(3)], .sending(space: 7, rule: 0, readySince: t0))
        router.retry(WindowID(3))
        XCTAssertEqual(router.phase(of: WindowID(3)), .ready(since: t0, space: 7, rule: 0), "a retry keeps the original ready deadline")
        router.markSending(WindowID(3))
        router.consume(WindowID(3))
        XCTAssertNil(router.exclusions()[WindowID(3)])
        XCTAssertEqual(router.observe([w(3)], space: 8, now: t0.addingTimeInterval(5)) { _ in true }, [], "a consumed window is never routed again")
        XCTAssertEqual(router.missing(on: 7, present: [WindowID(1)]), [WindowID(2)])
    }

    /// Recreate loop: 3 sends within 10 s for the same app, Space, and rule pause that rule on that Space for 1 minute.
    func testRecreateLoopLimiter() {
        var router = WindowRouter()
        XCTAssertFalse(router.noteSend(app: "a", space: 7, rule: 0, now: t0))
        XCTAssertFalse(router.noteSend(app: "a", space: 7, rule: 0, now: t0.addingTimeInterval(11)), "the first send is older than 10 s")
        XCTAssertFalse(router.noteSend(app: "a", space: 7, rule: 0, now: t0.addingTimeInterval(12)))
        XCTAssertTrue(router.noteSend(app: "a", space: 7, rule: 0, now: t0.addingTimeInterval(13)))
        XCTAssertTrue(router.isPaused(space: 7, rule: 0, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(router.isPaused(space: 8, rule: 0, now: t0.addingTimeInterval(60)), "only on that Space")
        XCTAssertFalse(router.isPaused(space: 7, rule: 1, now: t0.addingTimeInterval(60)), "only that rule")
        XCTAssertFalse(router.isPaused(space: 7, rule: 0, now: t0.addingTimeInterval(74)), "for one minute")
    }

    /// Send reconciliation: only the destination -> arrived; only departure for 3 s with a still frame -> stayed; unreadable or flapping -> stays excluded; gone -> forgotten.
    func testSendHoldReconciliation() {
        let identity = w(1)
        var hold = SendHold(identity: identity, source: 7, target: 9, targetUUID: "U9", startedAt: t0)
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        XCTAssertEqual(hold.evaluate(membership: nil, frame: frame, exists: nil, now: t0.addingTimeInterval(10), tolerance: 2), .keep, "unreadable: keep")
        XCTAssertEqual(hold.evaluate(membership: [7], frame: frame, exists: true, now: t0.addingTimeInterval(11), tolerance: 2), .keep)
        XCTAssertEqual(hold.evaluate(membership: [7, 9], frame: frame, exists: true, now: t0.addingTimeInterval(13), tolerance: 2), .keep, "in transit restarts")
        XCTAssertEqual(hold.evaluate(membership: [7], frame: frame, exists: true, now: t0.addingTimeInterval(14), tolerance: 2), .keep)
        XCTAssertEqual(hold.evaluate(membership: [7], frame: frame, exists: true, now: t0.addingTimeInterval(16.9), tolerance: 2), .keep)
        XCTAssertEqual(hold.evaluate(membership: [7], frame: frame, exists: true, now: t0.addingTimeInterval(17), tolerance: 2), .stayed)
        var late = SendHold(identity: identity, source: 7, target: 9, targetUUID: "U9", startedAt: t0)
        XCTAssertEqual(late.evaluate(membership: [9], frame: frame, exists: true, now: t0, tolerance: 2), .arrived)
        var gone = SendHold(identity: identity, source: 7, target: 9, targetUUID: nil, startedAt: t0)
        XCTAssertEqual(gone.evaluate(membership: [], frame: nil, exists: false, now: t0, tolerance: 2), .gone)
    }
}
