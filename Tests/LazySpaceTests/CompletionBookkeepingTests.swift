import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpace

private struct ThreeSpaces: SpaceListing {
    var order: [UInt64]
    var active: () -> UInt64?
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
}

/// A tap that only holds a ready state (counts prestarts).
private final class CountingTap: PassThroughTap {
    let filter = PassThroughFilter()
    var state: PassThroughTapState = .idle
    var failOnStart = false
    var starts = 0
    var creations = 0
    var isEnabled: Bool { state == .ready }
    func start() {
        starts += 1
        guard state == .idle || state == .failed else { return }
        creations += 1
        state = failOnStart ? .failed : .ready
    }
}

/// Bookkeeping for Space switch and move-to-space arrival (hooks, `space back` target, arrival handling) finishes before the result is published.
/// No test runs a tick between operations. The timeline is carried on the result and the receipt lookup.
final class CompletionBookkeepingTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private let hookLock = NSLock()
    private var hookCalls: [(from: UInt64?, to: UInt64)] = []
    private var hooks: [String] { hookLock.lock(); defer { hookLock.unlock() }; return hookCalls.map { "\($0.from.map(String.init) ?? "-")→\($0.to)" } }

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 8, 9]
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { SpaceOverview(spaces: [], unknown: [], reordersByRecentUse: false) }, takeInventory: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.spaceListingOverride = ThreeSpaces(order: [7, 8, 9], active: { self.system.space })
        coordinator.spaceChangeHookObserver = { [weak self] from, to in
            guard let self else { return }
            hookLock.lock(); hookCalls.append((from, to)); hookLock.unlock()
        }
        // State observed once after launch (Space 7). No ticks run between later operations.
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Replaces the switch and pretends to arrive on the target (`via` is a Space passed through; no tick runs during the operation, so it is not recorded).
    private func switches(via: UInt64? = nil, during: ((SpaceControl.SwitchPlan) -> Void)? = nil) -> () -> [UInt64] {
        var dests: [UInt64] = []
        coordinator.spaceSwitcherOverride = { dest, plan, _ in
            dests.append(dest)
            during?(plan)
            let from = self.system.space ?? 0
            if let via { self.system.space = via }
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: from, toSpace: dest, steps: via == nil ? 0 : 1, wallMs: 1))
        }
        return { dests }
    }

    private func run(_ command: EditCommand, file: StaticString = #filePath, line: UInt = #line) {
        guard case .started = coordinator.edit(command, source: "test") else { return XCTFail("\(command) was not started", file: file, line: line) }
        drain()
    }

    func testSpaceAToBToBackRecordsEachArrivalBeforeTheNextCommand() {
        make()
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().hookSpace, 7)
        let dests = switches()
        let before = Date()
        run(.space(.index(2)))
        var book = coordinator.testingSpaceBookkeeping()
        XCTAssertEqual(book.previous, 7)
        XCTAssertEqual(book.hookSpace, 8)
        XCTAssertGreaterThanOrEqual(book.arrivedAt, before, "the arrival time is noted when the switch completes")
        XCTAssertEqual(hooks, ["7→8"])
        run(.space(.index(3)))
        book = coordinator.testingSpaceBookkeeping()
        XCTAssertEqual(book.previous, 8)
        XCTAssertEqual(hooks, ["7→8", "8→9"])
        run(.space(.back))
        XCTAssertEqual(dests(), [8, 9, 8])
        XCTAssertEqual(system.space, 8)
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 9)
        XCTAssertEqual(hooks, ["7→8", "8→9", "9→8"])
        // The next tick does not record the same Space again (the hook runs once).
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        XCTAssertEqual(hooks, ["7→8", "8→9", "9→8"])
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
    }

    /// By the time the result is published (`onTerminalResult`), the hook has already run.
    func testTheHookRunsBeforeTheResultIsPublished() {
        make()
        _ = switches()
        var hooksAtPublish: [String]?
        coordinator.onTerminalResult = { [weak self] _ in hooksAtPublish = self?.hooks }
        run(.space(.index(2)))
        XCTAssertEqual(hooksAtPublish, ["7→8"])
    }

    /// One jump plus stepping (7 -> 8 -> 9 in one operation): 8 is not recorded, `space back` returns to 7, and the hook runs once for 7->9.
    func testHopRouteBacksToTheOriginalSource() {
        make()
        let dests = switches(via: 8)
        run(.space(.index(3)))
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
        XCTAssertEqual(hooks, ["7→9"])
        run(.space(.back))
        XCTAssertEqual(dests(), [9, 7])
        XCTAssertEqual(hooks, ["7→9", "9→7"])
    }

    /// Even a failure that stopped on an intermediate Space records the visible Space before publishing (so the next `space back` does not use a stale record).
    func testAStoppedSwitchRecordsTheVisibleSpaceBeforePublishing() {
        make()
        coordinator.spaceSwitcherOverride = { _, _, _ in
            self.system.space = 8
            return .failure(.interrupted)
        }
        run(.space(.index(3)))
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(hooks, ["7→8"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
    }

    /// move-to-space B -> space back: position correction and arrival handling (`expectedArrival`) finish before publishing, and the back target is the source Space.
    /// Going back leaves the carried window's Space, so the arrival handling is dropped.
    func testMoveToSpaceThenBackWithoutATick() {
        make()
        system.focused = WindowID(2)
        let original = system.frames[WindowID(2)]!
        coordinator.spaceMoverOverride = { wid, _, dest, _ in
            // Arrived a few points off because of drag recognition.
            self.system.frames[WindowID(wid)] = original.offsetBy(dx: 6, dy: 4)
            self.system.spaceOf[WindowID(wid)] = dest
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        var expectedAtPublish: UInt64?
        coordinator.onTerminalResult = { _ in expectedAtPublish = self.system.frames[WindowID(2)] == original ? 8 : nil }
        run(.moveToSpace(.index(2)))
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete, coordinator.lastResult?.message ?? "")
        XCTAssertEqual(expectedAtPublish, 8, "the position was corrected before the result was published")
        var book = coordinator.testingSpaceBookkeeping()
        XCTAssertEqual(book.previous, 7)
        XCTAssertEqual(book.expected?.window, WindowID(2))
        XCTAssertEqual(book.expected?.spaceID, 8)
        XCTAssertEqual(hooks, ["7→8"])
        let dests = switches()
        run(.space(.back))
        XCTAssertEqual(dests(), [7])
        book = coordinator.testingSpaceBookkeeping()
        XCTAssertNil(book.expected, "leaving the destination drops the arrival expectation")
        XCTAssertEqual(book.previous, 8)
        XCTAssertEqual(hooks, ["7→8", "8→7"])
    }

    /// The window moved but the display stayed on the source Space: partial, with no arrival or back target.
    func testMovedWindowWithoutFollowIsReportedAsPartial() {
        make()
        system.hiddenSpaces = true
        system.focused = WindowID(2)
        coordinator.spaceMoverOverride = { wid, _, dest, _ in
            self.system.spaceOf[WindowID(wid)] = dest
            return .failure(.notSwitched)
        }
        run(.moveToSpace(.index(2)))
        XCTAssertEqual(coordinator.lastResult?.outcome, .partial)
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.spaceOf[WindowID(2)], 8)
        XCTAssertTrue(hooks.isEmpty)
        XCTAssertNil(coordinator.testingSpaceBookkeeping().expected)
    }

    func testMoveThatNeverLeftSourceIsNotReportedAsPartial() {
        make()
        system.hiddenSpaces = true
        system.focused = WindowID(2)
        system.spaceOf[WindowID(2)] = 7
        coordinator.spaceMoverOverride = { _, _, _, _ in .failure(.moveUnconfirmed) }
        run(.moveToSpace(.index(2)))
        XCTAssertEqual(coordinator.lastResult?.outcome, .notPossible)
        XCTAssertEqual(system.space, 7)
        XCTAssertTrue(hooks.isEmpty)
    }

    /// A switch accepted but stopped before its body (the user moved to another Space) still records the visible Space before publishing.
    func testAnAcceptedSwitchRefusedBeforeItsBodyRecordsTheVisibleSpace() {
        make()
        let dests = switches()
        let gate = DispatchSemaphore(value: 0)
        coordinator.operationsQueue.async { gate.wait() }
        guard case .started = coordinator.edit(.space(.index(3)), source: "test") else { gate.signal(); return XCTFail("not accepted") }
        system.space = 8 // after acceptance, before the body, the user goes to Space 8
        gate.signal()
        drain()
        XCTAssertTrue(dests().isEmpty, "the switch body never ran")
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(coordinator.lastResult?.timeline.map(\.event), ["accepted", "queued", "published"])
        XCTAssertEqual(hooks, ["7→8"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
        run(.space(.back))
        XCTAssertEqual(dests(), [7])
    }

    /// The same for move-to-space (refused before the body).
    func testAnAcceptedMoveRefusedBeforeItsBodyRecordsTheVisibleSpace() {
        make()
        system.focused = WindowID(2)
        var moves = 0
        coordinator.spaceMoverOverride = { _, _, _, _ in moves += 1; return .failure(.interrupted) }
        let gate = DispatchSemaphore(value: 0)
        coordinator.operationsQueue.async { gate.wait() }
        guard case .started = coordinator.edit(.moveToSpace(.index(3)), source: "test") else { gate.signal(); return XCTFail("not accepted") }
        system.space = 8
        gate.signal()
        drain()
        XCTAssertEqual(moves, 0)
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(hooks, ["7→8"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
    }

    /// The user moved to another Space during the post-move position correction (AX writes): the Space visible after correction is recorded before publishing.
    /// The arrived Space (8) is recorded as passed through and the back target is 8 (overwriting with the source 7 only when staying on the target). The pending arrival is dropped.
    func testASpaceChangeDuringPositionCorrectionIsRecordedBeforePublishing() {
        make()
        system.focused = WindowID(2)
        let original = system.frames[WindowID(2)]!
        coordinator.spaceMoverOverride = { wid, _, dest, _ in
            self.system.frames[WindowID(wid)] = original.offsetBy(dx: 6, dy: 4)
            self.system.spaceOf[WindowID(wid)] = dest
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        system.onWrite = { id, _ in if id == WindowID(2) { self.system.space = 9 } }
        var hooksAtPublish: [String]?
        coordinator.onTerminalResult = { [weak self] _ in hooksAtPublish = self?.hooks }
        run(.moveToSpace(.index(2)))
        XCTAssertEqual(system.frames[WindowID(2)], original, "the correction was written")
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete, "leaving the destination during the correction is not success")
        XCTAssertEqual(hooksAtPublish, ["7→8", "8→9"], "recorded after the correction, before publishing")
        let book = coordinator.testingSpaceBookkeeping()
        XCTAssertEqual(book.hookSpace, 9)
        XCTAssertEqual(book.previous, 8, "no override to the origin after leaving the destination")
        XCTAssertNil(book.expected, "the arrival expectation for Space 8 is dropped")
        let dests = switches()
        run(.space(.back))
        XCTAssertEqual(dests(), [8])
    }

    /// Input or cancellation during the post-move AX work (position correction writes and readback, or the frame read when no correction is needed) is not success
    /// even when staying on the destination, and creates no arrival handling (for the new cancellation generation). The back target is the source (previous) Space.
    func testInterruptionDuringPostMoveWorkWhileStayingOnTheDestination() throws {
        for (correction, interruption) in [(true, "input"), (true, "cancel"), (false, "input"), (false, "cancel")] {
            let label = "\(correction ? "correction write" : "frame read"), \(interruption)"
            make()
            system.focused = WindowID(2)
            let original = system.frames[WindowID(2)]!
            coordinator.spaceMoverOverride = { wid, _, dest, _ in
                if correction { self.system.frames[WindowID(wid)] = original.offsetBy(dx: 6, dy: 4) }
                self.system.spaceOf[WindowID(wid)] = dest
                self.system.space = dest
                return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
            }
            let interrupt = { [self] in
                if interruption == "input" { system.inputActivityCount += 1 } else { coordinator.control.invalidate() }
            }
            var fired = false
            if correction {
                system.onWrite = { id, _ in if id == WindowID(2), !fired { fired = true; interrupt() } }
            } else {
                // The frame read after arriving (the last AX read, deciding whether correction is needed).
                system.onFrameRead = { id in if id == WindowID(2), self.system.space == 8, !fired { fired = true; interrupt() } }
            }
            run(.moveToSpace(.index(2)))
            XCTAssertTrue(fired, label)
            let result = try XCTUnwrap(coordinator.lastResult)
            XCTAssertNotEqual(result.outcome, .complete, "\(label): \(result.message)")
            XCTAssertEqual(system.space, 8, "\(label): still on the destination")
            let book = coordinator.testingSpaceBookkeeping()
            XCTAssertNil(book.expected, "\(label): no arrival expectation")
            XCTAssertEqual(hooks, ["7→8"], label)
            XCTAssertEqual(book.previous, 7, label)
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
            hookLock.lock(); hookCalls = []; hookLock.unlock()
        }
    }

    /// A `space N` queued behind a non-Space operation (arranging) is refused when dequeued because the user moved to another Space:
    /// the visible Space is recorded before publishing the refusal (so a tickless `space back` returns to the previous Space).
    func testAQueuedSwitchRefusedBehindANonSpaceOperationRecordsTheVisibleSpace() throws {
        make()
        let gate = DispatchSemaphore(value: 0)
        var blocked = false
        // Stop at the first observation of the arrangement body (operations queue).
        system.onSnapshot = {
            guard !blocked, !Thread.isMainThread else { return }
            blocked = true
            _ = gate.wait(timeout: .now() + 5)
        }
        guard case .started = coordinator.arrange(source: "test") else { gate.signal(); return XCTFail("arrange not started") }
        guard case .started(let ticket) = coordinator.edit(.space(.index(3)), source: "hotkey") else { gate.signal(); return XCTFail("space not queued") }
        system.space = 8 // the user goes to Space 8 during arranging
        gate.signal()
        drain(); drain()
        system.onSnapshot = nil
        let refusal = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(refusal.id, ticket, refusal.message)
        XCTAssertEqual(refusal.kind, "queued")
        XCTAssertEqual(hooks, ["7→8"], "recorded before the refusal was published")
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
        let dests = switches()
        run(.space(.back))
        XCTAssertEqual(dests(), [7])
    }

    // MARK: - Timeline

    /// Acceptance -> start on the queue -> plan -> (SpaceControl records) -> publish, with monotonic times.
    func testTimelineIsOrderedAndCarriedOnTheResult() throws {
        make()
        var planTimeline: OperationTimeline?
        _ = switches { plan in
            planTimeline = plan.timeline
            plan.timeline?.mark("mainKeyPosted", attempt: 1)
            plan.timeline?.mark("arrivalObserved", attempt: 1)
        }
        let timeline = OperationTimeline()
        guard case .started = coordinator.edit(.space(.index(2)), source: "test", timeline: timeline) else { return XCTFail("not started") }
        drain()
        XCTAssertTrue(planTimeline === timeline, "SpaceControl records into the operation's timeline")
        let events = try XCTUnwrap(coordinator.lastResult?.timeline)
        XCTAssertEqual(events.map(\.event), ["accepted", "queued", "prepared", "mainKeyPosted", "arrivalObserved", "published"])
        XCTAssertEqual(events.first?.at, 0)
        XCTAssertEqual(events.map(\.at), events.map(\.at).sorted())
        XCTAssertEqual(events[3].attempt, 1)
        XCTAssertNil(events[3].step)
    }

    /// Keyboard and menu actions (no timeline passed) also record one, from the `edit` call.
    func testKeyboardEditsGetATimelineToo() {
        make()
        _ = switches()
        run(.space(.index(2)))
        XCTAssertEqual(coordinator.lastResult?.timeline.map(\.event), ["accepted", "queued", "prepared", "published"])
    }

    /// Failures keep the timeline so far; operations stopped before their body still have acceptance, start, and publish.
    func testFailuresKeepThePartialTimeline() {
        make()
        coordinator.spaceSwitcherOverride = { _, plan, _ in
            plan.timeline?.mark("mainKeyPosted", step: 1, attempt: 1)
            return .failure(.drifted(to: 9))
        }
        run(.space(.index(2)))
        XCTAssertEqual(coordinator.lastResult?.timeline.map(\.event), ["accepted", "queued", "prepared", "mainKeyPosted", "published"])
        XCTAssertEqual(coordinator.lastResult?.timeline[3].step, 1)
        system.trusted = false
        _ = coordinator.edit(.space(.index(3)), source: "test")
        drain()
        XCTAssertEqual(coordinator.lastResult?.timeline.map(\.event), ["accepted", "queued", "published"])
    }

    /// From ControlPort acceptance to the receipt-ID lookup, the timeline is on the result (`result` reply).
    func testTheReceiptLookupReturnsTheTimeline() throws {
        make()
        _ = switches()
        let receipts = MutationReceiptRegistry(now: { 10_000 })
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator, receipts: receipts)
        let token = try XCTUnwrap(delegate.handle(.init(cmd: "request-token.v3")).requestID)
        let accepted = delegate.handle(.init(cmd: "edit.v3", arg: "space-2", requestID: token))
        XCTAssertEqual(accepted.code, "pending", accepted.message)
        drain()
        let polled = delegate.handle(.init(cmd: "result", arg: token))
        let result = try XCTUnwrap(polled.result)
        XCTAssertEqual(result.timeline.first?.event, "accepted")
        XCTAssertEqual(result.timeline.last?.event, "published")
        XCTAssertNil(polled.receivedAt, "the server never stamps the client's receive time")
    }

    // MARK: - Queue (keyboard and menu)

    /// A keyboard `space N` received while busy waits with a timeline whose origin is the first `edit` acceptance, and the wait shows up in the time to `queued`.
    func testQueuedKeyboardCommandsKeepTheirAcceptanceOrigin() throws {
        make()
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        coordinator.spaceSwitcherOverride = { dest, _, _ in
            calls += 1
            if calls == 1 {
                // The first one stops and fails without changing Space (the waiting second starts from the same Space).
                release.wait()
                return .failure(.interrupted)
            }
            let from = self.system.space ?? 0
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: from, toSpace: dest, steps: 0, wallMs: 1))
        }
        guard case .started = coordinator.edit(.space(.index(2)), source: "hotkey") else { return XCTFail("first not started") }
        guard case .started(let ticket) = coordinator.edit(.space(.index(3)), source: "hotkey") else { release.signal(); return XCTFail("second not queued") }
        Thread.sleep(forTimeInterval: 0.15) // time the second spends in the queue
        release.signal()
        drain(); drain()
        XCTAssertEqual(calls, 2)
        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertNotEqual(result.id, ticket, "the queued ticket is bound to the operation it started")
        let events = result.timeline
        XCTAssertEqual(events.map(\.event), ["accepted", "queued", "prepared", "published"])
        XCTAssertEqual(events[0].at, 0)
        XCTAssertGreaterThanOrEqual(events[1].at, 150, "the time spent in the queue is part of the elapsed time")
    }

    /// A waiting `space N` refused when dequeued (the Space changed) is still published with its timeline since acceptance.
    func testAQueuedCommandRefusedWhenDequeuedKeepsItsTimeline() throws {
        make()
        let release = DispatchSemaphore(value: 0)
        coordinator.spaceSwitcherOverride = { dest, _, _ in
            release.wait()
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        guard case .started = coordinator.edit(.space(.index(2)), source: "hotkey") else { return XCTFail("first not started") }
        guard case .started(let ticket) = coordinator.edit(.space(.index(3)), source: "hotkey") else { release.signal(); return XCTFail("second not queued") }
        Thread.sleep(forTimeInterval: 0.05)
        release.signal()
        drain(); drain()
        let refusal = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(refusal.id, ticket)
        XCTAssertEqual(refusal.kind, "queued")
        XCTAssertEqual(refusal.timeline.map(\.event), ["accepted", "published"])
        XCTAssertGreaterThanOrEqual(refusal.timeline.last?.at ?? 0, 50)
    }

    // MARK: - Prestarting the tap

    /// Creation starts when a Space operation is accepted (before its body), only once however often called, and again on the next operation after a failure.
    func testThePassThroughTapIsPrestartedOnAcceptanceAndRetriedAfterFailure() {
        make()
        let tap = CountingTap()
        tap.failOnStart = true
        coordinator.passThroughTapOverride = tap
        var startsSeenByTheSwitch: [Int] = []
        _ = switches { _ in startsSeenByTheSwitch.append(tap.starts) }
        run(.space(.index(2)))
        XCTAssertEqual(startsSeenByTheSwitch, [1], "started before the operation body")
        XCTAssertEqual(tap.state, .failed)
        tap.failOnStart = false
        run(.space(.index(3)))
        XCTAssertEqual(tap.creations, 2, "a failed start is retried")
        XCTAssertEqual(tap.state, .ready)
        run(.space(.index(1)))
        XCTAssertEqual(tap.starts, 3)
        XCTAssertEqual(tap.creations, 2, "a ready tap is not created again")
    }
}
