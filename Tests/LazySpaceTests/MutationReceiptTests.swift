import XCTest
import LayoutCore
import Operations
@testable import LazySpaceApp

private final class ManualClock {
    var time: TimeInterval = 10_000
    func now() -> TimeInterval { time }
}

private struct FixtureSpaces: SpaceListing {
    var order: [(id: UInt64, type: Int32?)]
    var active: UInt64
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order }
    func neighbor(offset: Int) -> UInt64? {
        guard let index = order.firstIndex(where: { $0.id == active }) else { return nil }
        let next = index + offset
        guard order.indices.contains(next) else { return nil }
        return order[next].id
    }
}

final class MutationReceiptTests: XCTestCase {
    private struct Harness {
        var root: URL
        var system: CoordinatorSystem
        var coordinator: Coordinator
        var clock: ManualClock
        var receipts: MutationReceiptRegistry
        var delegate: AppDelegate
    }

    private func makeHarness(ids: [WindowID] = [WindowID(1), WindowID(2)], layout: Bool = true, limits: (active: Int, terminal: Int) = (64, 32)) -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        if layout {
            var state = PersistedState()
            state.layouts["7"] = Planner.rowLayout(ids, rows: 1)
            store.save(state)
        }
        let system = CoordinatorSystem()
        system.frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: CGFloat(index) * 960, y: 0, width: 960, height: 1080))
        })
        system.focused = ids.first
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        let clock = ManualClock()
        let receipts = MutationReceiptRegistry(now: clock.now, activeLimit: limits.active, terminalLimit: limits.terminal)
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator, receipts: receipts)
        return Harness(root: root, system: system, coordinator: coordinator, clock: clock, receipts: receipts, delegate: delegate)
    }

    private func cleanup(_ harness: Harness) {
        drain(harness.coordinator)
        try? FileManager.default.removeItem(at: harness.root)
    }

    private func drain(_ coordinator: Coordinator) {
        let done = expectation(description: "Operations drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func token(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) -> String {
        let response = harness.delegate.handle(.init(cmd: "request-token.v3"))
        XCTAssertEqual(response.code, "reserved", file: file, line: line)
        return response.requestID ?? ""
    }

    private func resize(_ token: String, amount: String = "-0.1", window: UInt32 = 1, space: UInt64 = 7, pid: Int32? = nil, desired: Bool? = nil) -> ControlPort.Request {
        .init(cmd: "edit.v3", arg: "resize-width \(amount)", windowID: WindowID(window), expectedSpaceID: space, expectedPID: pid, desiredState: desired, requestID: token)
    }

    private func payload(cmd: String = "edit.v3", edit: EditCommand? = .resize(.horizontal, -0.1), window: WindowID? = WindowID(1), space: UInt64? = 7, pid: Int32? = nil, desired: Bool? = nil) -> MutationReceiptRegistry.Payload {
        .init(cmd: cmd, edit: edit, windowID: window, expectedSpaceID: space, expectedPID: pid, desiredState: desired)
    }

    func testRegistryAllocationExpiryCapacityAndEviction() {
        let clock = ManualClock()
        let registry = MutationReceiptRegistry(now: clock.now)
        guard case .reserved(let first) = registry.reserve(), case .reserved(let second) = registry.reserve() else { return XCTFail("Not reserved") }
        XCTAssertEqual(first.split(separator: ":").last, "1")
        XCTAssertEqual(second.split(separator: ":").last, "2")
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}:[1-9][0-9]*$"#
        XCTAssertNotNil(first.range(of: pattern, options: .regularExpression))
        XCTAssertTrue(MutationReceiptRegistry.isCanonicalToken("01234567-89AB-CDEF-0123-456789ABCDEF:17"))
        for bad in ["01234567-89ab-cdef-0123-456789abcdef:17", "01234567-89AB-CDEF-0123-456789ABCDEF:01", "01234567-89AB-CDEF-0123-456789ABCDEF:0", "01234567-89AB-CDEF-0123-456789ABCDEF", "nope", first + ":2"] {
            XCTAssertFalse(MutationReceiptRegistry.isCanonicalToken(bad), bad)
            if case .dispatch = registry.begin(bad, payload: payload()) { XCTFail("Malformed token dispatched") }
            XCTAssertEqual(registry.query(bad).code, "usage", bad)
        }
        let issued = first.split(separator: ":").first.map(String.init) ?? ""
        XCTAssertEqual(registry.query(issued + ":9").code, "unknown-request")
        XCTAssertEqual(registry.begin(issued + ":9", payload: payload()).code, "unknown-request")
        let other = MutationReceiptRegistry(now: clock.now)
        XCTAssertEqual(other.begin(first, payload: payload()).code, "session-mismatch")
        XCTAssertEqual(other.query(first).code, "session-mismatch")
        XCTAssertTrue(other.query(first).message.contains("unavailable"))
        XCTAssertEqual(other.dispatchCount, 0)

        clock.time += 59
        XCTAssertEqual(registry.query(first).code, "request-not-submitted")
        XCTAssertNil(registry.query(first).operationID)
        clock.time += 1
        XCTAssertEqual(registry.query(first).code, "request-expired")
        XCTAssertEqual(registry.begin(first, payload: payload()).code, "request-expired")
        guard case .reserved(let third) = registry.reserve() else { return XCTFail("Sequence was reused or refused") }
        XCTAssertEqual(third.split(separator: ":").last, "3")
        XCTAssertEqual(registry.dispatchCount, 0)
        clock.time += 61

        var held: [String] = []
        for _ in 0..<64 {
            guard case .reserved(let id) = registry.reserve() else { return XCTFail("Capacity was reached early") }
            held.append(id)
        }
        guard case .refused(let full) = registry.reserve() else { return XCTFail("65th reservation was accepted") }
        XCTAssertEqual(full.code, "request-capacity")
        XCTAssertEqual(registry.counts.active, 64)
        if case .dispatch = registry.begin(held[0], payload: payload()) {} else { return XCTFail("Live reservation did not dispatch") }
        XCTAssertEqual(registry.reserve().code, "request-capacity")
        clock.time += 120
        XCTAssertEqual(registry.query(held[0]).code, "pending")
        XCTAssertEqual(registry.query(held[1]).code, "request-expired")
        guard case .reserved = registry.reserve() else { return XCTFail("Expired reservations did not free a slot") }
        let refusal = MutationReceiptRegistry.Outcome(ok: false, code: "busy", message: "Another operation is in progress.", operationID: nil, result: nil)
        XCTAssertEqual(registry.finish(held[0], .refused(refusal)).code, "busy")

        clock.time += 120
        var terminal: [String] = []
        let bound = payload()
        for _ in 0..<32 {
            guard case .reserved(let id) = registry.reserve() else { return XCTFail("Terminal setup failed") }
            XCTAssertEqual(registry.begin(id, payload: bound), .dispatch)
            _ = registry.finish(id, .refused(refusal))
            terminal.append(id)
        }
        XCTAssertEqual(registry.counts.terminal, 32)
        for _ in 0..<5 { XCTAssertEqual(registry.query(terminal[0]).code, "busy") }
        guard case .reserved(let newest) = registry.reserve() else { return XCTFail("No slot after terminals") }
        XCTAssertEqual(registry.begin(newest, payload: bound), .dispatch)
        _ = registry.finish(newest, .refused(refusal))
        XCTAssertEqual(registry.query(terminal[0]).code, "request-expired")
        XCTAssertEqual(registry.begin(terminal[0], payload: bound).code, "request-expired")
        XCTAssertEqual(registry.begin(terminal[0], payload: payload(edit: .undo, window: nil)).code, "request-expired")
        XCTAssertEqual(registry.query(terminal[1]).code, "busy")
        XCTAssertEqual(registry.begin(terminal[1], payload: payload(edit: .undo, window: nil)).code, "request-conflict")
        XCTAssertEqual(registry.dispatchCount, 1 + 33)

        let exhausted = MutationReceiptRegistry(now: clock.now, nextSequence: .max)
        guard case .reserved(let last) = exhausted.reserve() else { return XCTFail("Max sequence was refused") }
        XCTAssertTrue(last.hasSuffix(":\(UInt64.max)"))
        XCTAssertEqual(exhausted.reserve().code, "request-sequence-exhausted")
        XCTAssertEqual(exhausted.begin(last.replacingOccurrences(of: ":\(UInt64.max)", with: ":1"), payload: bound).code, "request-expired")
        XCTAssertEqual(exhausted.dispatchCount, 0)
    }

    func testCompletionBeforeBindingAndOrdinaryCacheDoNotDropTheReceipt() throws {
        let clock = ManualClock()
        let registry = MutationReceiptRegistry(now: clock.now)
        guard case .reserved(let early) = registry.reserve() else { return XCTFail("No token") }
        let bound = payload()
        registry.arm(early)
        XCTAssertEqual(registry.begin(early, payload: bound), .dispatch)
        registry.claim("op-early")
        let raced = OperationResult.note(id: "op-early", kind: "edit:resize", spaceID: 7, message: "resized", ok: true)
        registry.absorb(raced)
        for index in 0..<300 {
            registry.absorb(OperationResult.note(id: "noise-\(index)", kind: "auto-reconcile", spaceID: 7, message: "noise", ok: true))
        }
        XCTAssertEqual(registry.counts.active, 0)
        let finished = registry.finish(early, .started(operationID: "op-early", message: "Accepted."))
        registry.disarm()
        XCTAssertEqual(finished.code, "finished")
        XCTAssertEqual(finished.result?.id, "op-early")
        XCTAssertEqual(finished.operationID, "op-early")
        XCTAssertNotEqual(registry.begin(early, payload: bound), .dispatch)
        XCTAssertEqual(registry.query(early).result?.message, "resized")

        guard case .reserved(let late) = registry.reserve() else { return XCTFail("No second token") }
        XCTAssertEqual(registry.begin(late, payload: bound), .dispatch)
        let pending = registry.finish(late, .started(operationID: "op-late", message: "Accepted."))
        XCTAssertEqual(pending.code, "pending")
        XCTAssertEqual(pending.operationID, "op-late")
        registry.absorb(OperationResult.note(id: "op-late", kind: "edit:resize", spaceID: 7, message: "later", ok: false))
        XCTAssertEqual(registry.query(late).code, "finished")
        XCTAssertEqual(registry.query(late).result?.message, "later")
        XCTAssertFalse(registry.query(late).ok)
        XCTAssertEqual(registry.dispatchCount, 2)

        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.coordinator.completeSynchronouslyForTesting = true
        let id = token(harness)
        let first = harness.delegate.handle(resize(id))
        XCTAssertEqual(first.code, "finished")
        XCTAssertEqual(first.result?.id, first.operationID)
        XCTAssertNotEqual(first.requestID, first.operationID)
        XCTAssertGreaterThan(harness.system.writes, 0)
        let writes = harness.system.writes
        let replay = harness.delegate.handle(resize(id))
        XCTAssertEqual(replay.result?.id, first.result?.id)
        XCTAssertEqual(harness.system.writes, writes)
        XCTAssertEqual(harness.receipts.dispatchCount, 1)
        let operationID = try XCTUnwrap(first.operationID)
        for index in 0..<33 {
            harness.coordinator.testingRecord(OperationResult.note(id: "churn-\(index)", kind: "auto-reconcile", spaceID: 7, message: "churn", ok: true))
        }
        XCTAssertNil(harness.coordinator.result(id: operationID))
        let recovered = harness.delegate.handle(.init(cmd: "result", arg: id))
        XCTAssertEqual(recovered.code, "finished")
        XCTAssertEqual(recovered.result?.id, operationID)
        XCTAssertEqual(recovered.operationID, operationID)
        XCTAssertNotEqual(recovered.result?.message, "churn")
        XCTAssertEqual(harness.system.writes, writes)
    }

    func testSuspendedDuplicateResizeDispatchesOnceAndUndoReplayDoesNotInvertAgain() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.coordinator.operationsQueue.suspend()
        let id = token(harness)
        let first = harness.delegate.handle(resize(id))
        let second = harness.delegate.handle(resize(id))
        XCTAssertEqual(first.code, "pending")
        XCTAssertEqual(second.code, "pending")
        XCTAssertEqual(second.operationID, first.operationID)
        XCTAssertEqual(harness.receipts.dispatchCount, 1)
        XCTAssertEqual(harness.system.writes, 0)
        XCTAssertEqual(harness.delegate.handle(resize(id, amount: "-0.10")).operationID, first.operationID)
        XCTAssertEqual(harness.receipts.dispatchCount, 1)
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)
        XCTAssertEqual(harness.system.frames[WindowID(1)]?.width, 768)
        let writes = harness.system.writes
        let done = harness.delegate.handle(resize(id))
        XCTAssertEqual(done.code, "finished")
        XCTAssertEqual(done.result?.id, first.operationID)
        XCTAssertEqual(harness.system.writes, writes)

        harness.coordinator.completeSynchronouslyForTesting = true
        let undoID = token(harness)
        let undone = harness.delegate.handle(.init(cmd: "edit.v3", arg: "undo", expectedSpaceID: 7, requestID: undoID))
        XCTAssertEqual(undone.result?.outcome, .complete)
        XCTAssertEqual(harness.system.frames[WindowID(1)]?.width, 960)
        let afterUndo = harness.system.writes
        _ = harness.delegate.handle(.init(cmd: "edit.v3", arg: "undo", expectedSpaceID: 7, requestID: undoID))
        XCTAssertEqual(harness.system.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(harness.system.writes, afterUndo)
        XCTAssertEqual(harness.receipts.dispatchCount, 2)
    }

    func testConflictChecksEveryBoundFieldAndMalformedRequestsDoNotConsume() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.coordinator.operationsQueue.suspend()
        defer { harness.coordinator.operationsQueue.resume() }
        let id = token(harness)
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "edit.v3", arg: "nope", requestID: id)).code, "usage")
        XCTAssertEqual(harness.receipts.dispatchCount, 0)
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "result", arg: id)).code, "request-not-submitted")
        let accepted = harness.delegate.handle(resize(id))
        XCTAssertEqual(accepted.code, "pending")
        let conflicts: [ControlPort.Request] = [
            resize(id, amount: "+0.1"),
            resize(id, window: 2),
            resize(id, space: 8),
            resize(id, pid: 1),
            .init(cmd: "focus-window.v3", windowID: WindowID(1), expectedSpaceID: 7, requestID: id),
            .init(cmd: "edit.v3", arg: "resize-width -0.1", expectedSpaceID: 7, requestID: id)
        ]
        for request in conflicts {
            let response = harness.delegate.handle(request)
            XCTAssertEqual(response.code, "request-conflict", request.cmd + " " + (request.arg ?? ""))
            XCTAssertEqual(response.operationID, nil)
        }
        XCTAssertEqual(harness.system.writes, 0)
        XCTAssertEqual(harness.receipts.dispatchCount, 1)
        XCTAssertEqual(harness.delegate.handle(resize(id)).operationID, accepted.operationID)

        let stateHarness = makeHarness()
        defer { cleanup(stateHarness) }
        stateHarness.coordinator.operationsQueue.suspend()
        defer { stateHarness.coordinator.operationsQueue.resume() }
        let state = token(stateHarness)
        let on = stateHarness.delegate.handle(.init(cmd: "edit.v3", arg: "float", windowID: WindowID(1), expectedSpaceID: 7, desiredState: true, requestID: state))
        XCTAssertEqual(on.code, "pending")
        XCTAssertEqual(stateHarness.delegate.handle(.init(cmd: "edit.v3", arg: "float", windowID: WindowID(1), expectedSpaceID: 7, desiredState: false, requestID: state)).code, "request-conflict")
        XCTAssertEqual(stateHarness.delegate.handle(.init(cmd: "edit.v3", arg: "float", windowID: WindowID(1), expectedSpaceID: 7, requestID: state)).code, "usage")
        XCTAssertEqual(stateHarness.delegate.handle(.init(cmd: "edit.v3", arg: "float", windowID: WindowID(1), expectedSpaceID: 7, desiredState: true, requestID: state)).operationID, on.operationID)
        XCTAssertEqual(stateHarness.system.writes, 0)
    }

    func testBusyPreconditionAndInterruptedResultsStayTerminal() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.coordinator.operationsQueue.suspend()
        let holder = token(harness)
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "focus-window.v3", windowID: WindowID(2), expectedSpaceID: 7, requestID: holder)).code, "pending")
        let busyID = token(harness)
        XCTAssertEqual(harness.delegate.handle(resize(busyID)).code, "busy")
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)
        harness.system.focused = WindowID(1)
        let writes = harness.system.writes
        XCTAssertEqual(harness.delegate.handle(resize(busyID)).code, "busy")
        XCTAssertEqual(harness.system.writes, writes)
        let fresh = token(harness)
        harness.coordinator.completeSynchronouslyForTesting = true
        XCTAssertEqual(harness.delegate.handle(resize(fresh)).code, "finished")
        XCTAssertGreaterThan(harness.system.writes, writes)
        XCTAssertEqual(harness.receipts.dispatchCount, 3)

        let missing = makeHarness()
        defer { cleanup(missing) }
        let missingID = token(missing)
        XCTAssertEqual(missing.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(99), expectedSpaceID: 7, expectedPID: 1, requestID: missingID)).code, "target-not-found")
        missing.system.frames[WindowID(99)] = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(missing.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(99), expectedSpaceID: 7, expectedPID: 1, requestID: missingID)).code, "target-not-found")
        XCTAssertEqual(missing.system.closeCalls, 0)
        let retry = token(missing)
        let beforeRetry = missing.receipts.dispatchCount
        missing.coordinator.completeSynchronouslyForTesting = true
        let retried = missing.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(1), expectedSpaceID: 7, expectedPID: 1, requestID: retry))
        XCTAssertEqual(missing.receipts.dispatchCount, beforeRetry + 1)
        XCTAssertEqual(retried.code, "finished", retried.message)
        XCTAssertEqual(missing.system.closeCalls, 1)

        let interrupted = makeHarness()
        defer { cleanup(interrupted) }
        interrupted.coordinator.operationsQueue.suspend()
        let change = token(interrupted)
        XCTAssertEqual(interrupted.delegate.handle(resize(change)).code, "pending")
        interrupted.system.inputActivityCount += 1
        interrupted.coordinator.operationsQueue.resume()
        drain(interrupted.coordinator)
        let settled = interrupted.delegate.handle(.init(cmd: "result", arg: change))
        XCTAssertEqual(settled.code, "finished")
        XCTAssertEqual(settled.result?.stopReason, .userInput)
        XCTAssertNotEqual(settled.result?.id, change)
        let stableWrites = interrupted.system.writes
        _ = interrupted.delegate.handle(resize(change))
        XCTAssertEqual(interrupted.system.writes, stableWrites)
        XCTAssertEqual(interrupted.receipts.dispatchCount, 1)
    }

    func testRestartRejectsTheOldTokenOnQueryAndMutation() {
        let clock = ManualClock()
        let old = MutationReceiptRegistry(session: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, now: clock.now)
        guard case .reserved(let saved) = old.reserve() else { return XCTFail("No token") }
        let restarted = makeHarness()
        defer { cleanup(restarted) }
        let response = restarted.delegate.handle(resize(saved))
        XCTAssertEqual(response.code, "session-mismatch")
        XCTAssertTrue(response.message.contains("unavailable"))
        XCTAssertEqual(restarted.delegate.handle(.init(cmd: "result", arg: saved)).code, "session-mismatch")
        XCTAssertEqual(restarted.system.writes, 0)
        XCTAssertEqual(restarted.receipts.dispatchCount, 0)
        XCTAssertEqual(old.dispatchCount, 0)
    }

    func testTransportFaultsRetainTheRequestAndDoNotSendTwice() throws {
        let harness = makeHarness()
        defer { cleanup(harness) }
        guard case .invocation(let resizeCall) = CLI.parse(["resize", "width", "-0.1", "--window-id", "1", "--expect-space-id", "7", "--json"]) else {
            return XCTFail("Resize did not parse")
        }
        var droppedToken: [String] = []
        let droppedAllocation = CLI.execute(resizeCall, send: { request, _ in
            droppedToken.append(request.cmd)
            if request.cmd == "request-token.v3" {
                _ = harness.delegate.handle(request)
                return nil
            }
            XCTFail("Mutation was sent after a lost token reply")
            return nil
        }, sleep: { _ in }, unavailable: "down")
        XCTAssertEqual(droppedToken, ["request-token.v3"])
        XCTAssertEqual(droppedAllocation.exitCode, 2)
        XCTAssertEqual(harness.receipts.dispatchCount, 0)

        var lostReply: [String] = []
        let lost = CLI.execute(resizeCall, send: { request, _ in
            lostReply.append(request.cmd)
            let response = harness.delegate.handle(request)
            if request.cmd == "edit.v3" { return nil }
            return response
        }, sleep: { _ in }, unavailable: "down")
        XCTAssertEqual(lostReply, ["request-token.v3", "edit.v3"])
        XCTAssertEqual(lost.exitCode, 2)
        let lostJSON = try XCTUnwrap(decode(lost.stdout))
        let requestID = try XCTUnwrap(lostJSON.requestID)
        XCTAssertEqual(lostJSON.code, "connection-unavailable")
        drain(harness.coordinator)
        let writes = harness.system.writes
        guard case .invocation(let lookup) = CLI.parse(["result", requestID, "--json"]) else { return XCTFail("Result did not parse") }
        let found = CLI.execute(lookup, send: { request, _ in harness.delegate.handle(request) }, unavailable: "down")
        let foundJSON = try XCTUnwrap(decode(found.stdout))
        XCTAssertEqual(found.exitCode, 0)
        XCTAssertEqual(foundJSON.result?.id, foundJSON.operationID)
        XCTAssertNotEqual(foundJSON.operationID, requestID)

        guard case .invocation(let replayCall) = CLI.parse(["resize", "width", "-0.1", "--window-id", "1", "--expect-space-id", "7", "--request-id", requestID, "--json"]) else {
            return XCTFail("Supplied token did not parse")
        }
        var replayed: [String] = []
        let replay = CLI.execute(replayCall, send: { request, _ in
            replayed.append(request.cmd)
            return harness.delegate.handle(request)
        }, unavailable: "down")
        XCTAssertEqual(replayed, ["edit.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(replay.stdout)).result?.id, foundJSON.result?.id)
        XCTAssertEqual(harness.system.writes, writes)
        XCTAssertEqual(harness.receipts.dispatchCount, 1)

        let supplied = token(harness)
        guard case .invocation(let suppliedCall) = CLI.parse(["resize", "width", "0.05", "--window-id", "2", "--expect-space-id", "7", "--request-id", supplied]) else {
            return XCTFail("Text resize did not parse")
        }
        let textLoss = CLI.execute(suppliedCall, send: { request, _ in
            XCTAssertEqual(request.cmd, "edit.v3")
            _ = harness.delegate.handle(request)
            return nil
        }, unavailable: "down")
        XCTAssertEqual(textLoss.exitCode, 2)
        XCTAssertEqual(textLoss.stdout, "")
        XCTAssertTrue(textLoss.stderr?.contains("Request: \(supplied)") == true)

        drain(harness.coordinator)
        harness.coordinator.operationsQueue.suspend()
        guard case .invocation(let pendingCall) = CLI.parse(["resize", "width", "-0.05", "--window-id", "1", "--expect-space-id", "7", "--json"]) else { return }
        let polled = CLI.execute(pendingCall, send: { request, _ in
            if request.cmd == "result" { return nil }
            return harness.delegate.handle(request)
        }, sleep: { _ in }, unavailable: "down")
        let polledJSON = try XCTUnwrap(decode(polled.stdout))
        XCTAssertEqual(polled.exitCode, 2)
        XCTAssertNotNil(polledJSON.requestID)
        XCTAssertNotNil(polledJSON.operationID)
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)

        harness.coordinator.operationsQueue.suspend()
        _ = harness.delegate.handle(.init(cmd: "focus-window.v3", windowID: WindowID(2), expectedSpaceID: 7, requestID: token(harness)))
        guard case .invocation(let busyCall) = CLI.parse(["undo", "--expect-space-id", "7", "--json"]) else { return }
        var busySends: [String] = []
        let busy = CLI.execute(busyCall, send: { request, _ in
            busySends.append(request.cmd)
            return harness.delegate.handle(request)
        }, unavailable: "down")
        XCTAssertEqual(busySends, ["request-token.v3", "edit.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(busy.stdout)).code, "busy")
        XCTAssertEqual(busy.exitCode, 1)
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)

        let expired = token(harness)
        harness.clock.time += 60
        guard case .invocation(let expiredCall) = CLI.parse(["undo", "--expect-space-id", "7", "--request-id", expired, "--json"]) else { return }
        var expiredSends: [String] = []
        let refused = CLI.execute(expiredCall, send: { request, _ in
            expiredSends.append(request.cmd)
            return harness.delegate.handle(request)
        }, unavailable: "down")
        XCTAssertEqual(expiredSends, ["edit.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(refused.stdout)).code, "request-expired")
        let beforeCapacity = harness.receipts.dispatchCount
        for _ in 0..<64 { _ = token(harness) }
        var capacitySends: [String] = []
        _ = CLI.execute(resizeCall, send: { request, _ in
            capacitySends.append(request.cmd)
            return harness.delegate.handle(request)
        }, unavailable: "down")
        XCTAssertEqual(capacitySends, ["request-token.v3"])
        XCTAssertEqual(harness.receipts.dispatchCount, beforeCapacity)
        harness.clock.time += 60

        let reservedOnly = token(harness)
        guard case .invocation(let reservedLookup) = CLI.parse(["result", reservedOnly]) else { return }
        let reserved = CLI.execute(reservedLookup, send: { request, _ in harness.delegate.handle(request) }, unavailable: "down")
        XCTAssertEqual(reserved.exitCode, 1)
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "result", arg: reservedOnly)).code, "request-not-submitted")
        harness.coordinator.operationsQueue.suspend()
        let pendingID = token(harness)
        _ = harness.delegate.handle(.init(cmd: "edit.v3", arg: "balance", expectedSpaceID: 7, requestID: pendingID))
        guard case .invocation(let pendingLookup) = CLI.parse(["result", pendingID, "--json"]) else { return }
        let pending = CLI.execute(pendingLookup, send: { request, _ in harness.delegate.handle(request) }, unavailable: "down")
        XCTAssertEqual(pending.exitCode, 1)
        XCTAssertEqual(try XCTUnwrap(decode(pending.stdout)).code, "pending")
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)
    }

    func testRetiredNameRequestsCannotMutateState() throws {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let stateURL = harness.root.appendingPathComponent("state.json")
        let original = try Data(contentsOf: stateURL)
        let malformed = Data(#"{"cmd":"space-name.set","arg":"2","spaceName":"web"}"#.utf8)
        let response = ControlPort.response(for: malformed) { _ in
            XCTFail("Retired payload was dispatched")
            return .init(ok: true, message: "unexpected")
        }
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, "invalid-request")
        for name in ["space-name.set", "space-name.clear", "space-name.list"] {
            let data = try ControlPort.encoder.encode(ControlPort.Request(cmd: name, arg: nil))
            let result = ControlPort.response(for: data, handler: harness.delegate.handle)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.code, "unknown-command")
        }
        XCTAssertEqual(harness.system.writes, 0)
        XCTAssertEqual(harness.system.focusCalls, 0)
        XCTAssertEqual(try Data(contentsOf: stateURL), original)
    }

    func testStrictIPCAndSemanticRefusalCodes() throws {
        let harness = makeHarness()
        defer { cleanup(harness) }
        let snapshots = harness.system.snapshotCount
        _ = token(harness)
        XCTAssertEqual(harness.system.snapshotCount, snapshots)
        XCTAssertTrue(CLI.parse(["status", "--request-id", "01234567-89AB-CDEF-0123-456789ABCDEF:1"])?.isError == true)
        XCTAssertTrue(CLI.parse(["resize", "width", "--request-id", UUID().uuidString])?.isError == true)
        XCTAssertEqual(CLI.parse(["request-token", "--json"])?.invocation?.cmd, "request-token.v3")
        let wire = Data(#"{"cmd":"edit.v3","arg":"resize-width -0.1","windowID":{"raw":123},"expectedSpaceID":884,"expectedPID":456,"requestID":"01234567-89AB-CDEF-0123-456789ABCDEF:17"}"#.utf8)
        let decoded = try XCTUnwrap(ControlPort.decodeRequest(wire))
        XCTAssertNil(decoded.validationError)
        XCTAssertEqual(decoded.windowID, WindowID(123))
        XCTAssertEqual(harness.delegate.handle(decoded).code, "session-mismatch")
        XCTAssertEqual(harness.receipts.dispatchCount, 0)
        let invalid = ControlPort.response(for: Data("not json".utf8)) { _ in
            XCTFail("Invalid bytes were dispatched")
            return .init(ok: true, message: "")
        }
        XCTAssertEqual(invalid.code, "invalid-request")
        XCTAssertEqual(invalid.schemaVersion, 2)
        XCTAssertNil(ControlPort.decodeRequest(Data(#"{"cmd":"status","extra":true}"#.utf8)))
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "edit.v2", arg: "undo")).code, "unknown-command")
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "edit.v3", arg: "undo")).code, "usage")
        XCTAssertEqual(harness.delegate.handle(.init(cmd: "status", requestID: token(harness))).code, "usage")

        XCTAssertEqual(Coordinator.preconditionCode(.permissionLost), "permission-lost")
        XCTAssertEqual(Coordinator.preconditionCode(.targetsChanged), "targets-changed")
        XCTAssertEqual(Coordinator.preconditionCode(.appUnresponsive), "app-unresponsive")
        var codes: [String: String] = [:]
        func remember(_ name: String, _ response: ControlPort.Response) {
            XCTAssertFalse(response.ok, name)
            XCTAssertNotNil(response.code, name)
            XCTAssertNotEqual(response.code, "precondition-failed", name)
            codes[name] = response.code
        }
        remember("usage", harness.delegate.handle(.init(cmd: "edit.v3", arg: "float", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(harness))))
        remember("space-mismatch", harness.delegate.handle(resize(token(harness), space: 8)))
        remember("target-not-found", harness.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(99), expectedSpaceID: 7, requestID: token(harness))))
        harness.system.trusted = false
        remember("untrusted-target", harness.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(harness))))
        harness.system.trusted = true
        harness.system.onSnapshot = { harness.system.inputActivityCount += 1 }
        remember("input-changed", harness.delegate.handle(resize(token(harness))))
        harness.system.inputActivityCount = 0
        harness.system.onSnapshot = { harness.system.space = 8 }
        remember("space-changed", harness.delegate.handle(resize(token(harness))))
        harness.system.space = 7
        harness.system.onSnapshot = { harness.coordinator.control.invalidate() }
        remember("cancelled", harness.delegate.handle(resize(token(harness))))
        harness.system.onSnapshot = nil
        harness.coordinator.pause()
        remember("paused", harness.delegate.handle(.init(cmd: "edit.v3", arg: "balance", expectedSpaceID: 7, requestID: token(harness))))
        harness.coordinator.resume()
        remember("nothing-to-undo", harness.delegate.handle(.init(cmd: "edit.v3", arg: "undo", expectedSpaceID: 7, requestID: token(harness))))
        remember("no-focus-history", harness.delegate.handle(.init(cmd: "edit.v3", arg: "focus-back", expectedSpaceID: 7, requestID: token(harness))))
        harness.system.focused = nil
        remember("no-focused-window", harness.delegate.handle(.init(cmd: "edit.v3", arg: "resize-width -0.1", expectedSpaceID: 7, requestID: token(harness))))
        harness.system.focused = WindowID(1)
        remember("no-neighbor", harness.delegate.handle(.init(cmd: "edit.v3", arg: "focus-up", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(harness))))
        harness.system.frames[WindowID(3)] = CGRect(x: 0, y: 0, width: 40, height: 40)
        remember("not-tiled", harness.delegate.handle(.init(cmd: "edit.v3", arg: "close", windowID: WindowID(3), expectedSpaceID: 7, requestID: token(harness))))
        remember("space-unavailable", harness.delegate.handle(.init(cmd: "edit.v3", arg: "space-next", expectedSpaceID: 7, requestID: token(harness))))
        harness.coordinator.spaceListingOverride = FixtureSpaces(order: [(id: 7, type: 0), (id: 8, type: 0)], active: 7)
        remember("same-space", harness.delegate.handle(.init(cmd: "edit.v3", arg: "space-1", expectedSpaceID: 7, requestID: token(harness))))
        remember("space-not-found", harness.delegate.handle(.init(cmd: "edit.v3", arg: "space-prev", expectedSpaceID: 7, requestID: token(harness))))
        remember("move-same-space", harness.delegate.handle(.init(cmd: "edit.v3", arg: "move-to-space-1", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(harness))))
        harness.coordinator.operationsQueue.suspend()
        _ = harness.delegate.handle(.init(cmd: "focus-window.v3", windowID: WindowID(2), expectedSpaceID: 7, requestID: token(harness)))
        remember("busy", harness.delegate.handle(resize(token(harness))))
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)
        remember("inspect", harness.delegate.handle(.init(cmd: "inspect-result")))
        remember("mode", harness.delegate.handle(.init(cmd: "mode", arg: "missing-mode")))
        remember("login", harness.delegate.handle(.init(cmd: "login-item", arg: "maybe")))
        try "[\n".write(to: harness.coordinator.configURL, atomically: true, encoding: .utf8)
        remember("reload", harness.delegate.handle(.init(cmd: "reload")))
        remember("unknown", harness.delegate.handle(.init(cmd: "dance")))

        let single = makeHarness(ids: [WindowID(1)])
        defer { cleanup(single) }
        remember("single-window", single.delegate.handle(.init(cmd: "edit.v3", arg: "resize-smart -0.1", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(single))))
        single.coordinator.knowledge.recordPushback(id: WindowID(1), requested: CGRect(x: 0, y: 0, width: 10, height: 10), actual: CGRect(x: 0, y: 0, width: 5000, height: 5000), spaceID: 7, workArea: single.system.area, tolerance: 1)
        remember("layout-unavailable", single.delegate.handle(.init(cmd: "edit.v3", arg: "focus-left", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(single))))
        let bare = makeHarness(layout: false)
        defer { cleanup(bare) }
        remember("not-started", bare.delegate.handle(.init(cmd: "edit.v3", arg: "resize-width -0.1", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(bare))))

        XCTAssertEqual(codes["usage"], "usage")
        XCTAssertEqual(codes["space-mismatch"], "space-mismatch")
        XCTAssertEqual(codes["target-not-found"], "target-not-found")
        XCTAssertEqual(codes["untrusted-target"], "target-not-found")
        XCTAssertEqual(codes["input-changed"], "input-changed")
        XCTAssertEqual(codes["space-changed"], "space-changed")
        XCTAssertEqual(codes["cancelled"], "cancelled")
        XCTAssertEqual(codes["paused"], "paused")
        XCTAssertEqual(codes["nothing-to-undo"], "nothing-to-undo")
        XCTAssertEqual(codes["no-focus-history"], "no-focus-history")
        XCTAssertEqual(codes["no-focused-window"], "no-focused-window")
        XCTAssertEqual(codes["no-neighbor"], "no-neighbor")
        XCTAssertEqual(codes["not-tiled"], "not-tiled")
        XCTAssertEqual(codes["space-unavailable"], "space-unavailable")
        XCTAssertEqual(codes["same-space"], "same-space")
        XCTAssertEqual(codes["space-not-found"], "space-not-found")
        XCTAssertEqual(codes["move-same-space"], "same-space")
        XCTAssertEqual(codes["busy"], "busy")
        XCTAssertEqual(codes["inspect"], "usage")
        XCTAssertEqual(codes["mode"], "unknown-mode")
        XCTAssertEqual(codes["login"], "usage")
        XCTAssertEqual(codes["reload"], "config-error")
        XCTAssertEqual(codes["unknown"], "unknown-command")
        XCTAssertEqual(codes["single-window"], "single-window")
        XCTAssertEqual(codes["layout-unavailable"], "layout-unavailable")
        XCTAssertEqual(codes["not-started"], "not-started")
        XCTAssertFalse(single.delegate.handle(.init(cmd: "edit.v3", arg: "focus-left", windowID: WindowID(1), expectedSpaceID: 7, requestID: token(single))).message.contains("no window to the left"))
    }

    func testHandlerCompletionBeforeFinishSurvivesHundredsOfOtherResults() {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.coordinator.operationsQueue.suspend()
        let claim = harness.coordinator.onOperationID
        harness.coordinator.onOperationID = { id in
            claim?(id)
            harness.receipts.absorb(OperationResult.note(id: id, kind: "edit:resize", spaceID: 7, message: "early", ok: true))
            for index in 0..<300 {
                harness.receipts.absorb(OperationResult.note(id: "noise-\(index)", kind: "auto-reconcile", spaceID: 7, message: "noise", ok: true))
            }
        }
        let id = token(harness)
        let response = harness.delegate.handle(resize(id))
        XCTAssertEqual(response.code, "finished")
        XCTAssertEqual(response.result?.message, "early")
        XCTAssertEqual(response.result?.id, response.operationID)
        XCTAssertNotEqual(response.operationID, id)
        XCTAssertEqual(harness.receipts.counts.active, 0)
        harness.coordinator.operationsQueue.resume()
        drain(harness.coordinator)
        XCTAssertEqual(harness.delegate.handle(resize(id)).result?.message, "early")
        XCTAssertEqual(harness.receipts.dispatchCount, 1)
        guard case .reserved = harness.receipts.reserve() else { return XCTFail("Completed receipt did not free capacity") }
    }

    func testMutationResponsesMustMatchTheRetainedRequest() throws {
        let harness = makeHarness()
        defer { cleanup(harness) }
        guard case .invocation(let automatic) = CLI.parse(["resize", "width", "-0.1", "--window-id", "1", "--expect-space-id", "7", "--json"]) else {
            return XCTFail("Resize did not parse")
        }
        var sends: [String] = []
        let missingToken = CLI.execute(automatic, send: { request, _ in
            sends.append(request.cmd)
            return ControlPort.Response(ok: true, message: "Reserved.", code: "reserved")
        }, sleep: { _ in }, unavailable: "down")
        XCTAssertEqual(sends, ["request-token.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(missingToken.stdout)).code, "protocol-error")
        XCTAssertNotEqual(missingToken.exitCode, 0)

        sends.removeAll()
        let malformedToken = CLI.execute(automatic, send: { request, _ in
            sends.append(request.cmd)
            return ControlPort.Response(ok: true, message: "Reserved.", code: "reserved", requestID: "not-a-token")
        }, sleep: { _ in }, unavailable: "down")
        XCTAssertEqual(sends, ["request-token.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(malformedToken.stdout)).code, "protocol-error")
        XCTAssertNotEqual(malformedToken.exitCode, 0)

        let retained = token(harness)
        guard case .invocation(let supplied) = CLI.parse(["resize", "width", "-0.1", "--window-id", "1", "--expect-space-id", "7", "--request-id", retained, "--json"]) else {
            return XCTFail("Supplied resize did not parse")
        }
        func once(_ response: ControlPort.Response, file: StaticString = #filePath, line: UInt = #line) throws -> ControlPort.Response {
            var count = 0
            let output = CLI.execute(supplied, send: { _, _ in
                count += 1
                return response
            }, sleep: { _ in }, unavailable: "down")
            XCTAssertEqual(count, 1, file: file, line: line)
            XCTAssertEqual(output.exitCode, 1, file: file, line: line)
            let decoded = try XCTUnwrap(decode(output.stdout), file: file, line: line)
            XCTAssertEqual(decoded.code, "protocol-error", file: file, line: line)
            XCTAssertEqual(decoded.requestID, retained, file: file, line: line)
            return decoded
        }
        XCTAssertNil(try once(.init(ok: true, message: "Accepted.", operationID: "op-a", code: "pending")).operationID)
        XCTAssertNil(try once(.init(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: "01234567-89AB-CDEF-0123-456789ABCDEF:99")).operationID)
        var wrongSchema = ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: retained)
        wrongSchema.schemaVersion = 1
        XCTAssertEqual(try once(wrongSchema).requestID, retained)
        XCTAssertNil(try once(.init(ok: true, message: "Done", operationID: "op-a", code: "finished", requestID: retained)).result)
        let partial = OperationResult.note(id: "op-a", kind: "edit:resize", spaceID: 7, message: "partial", ok: false)
        XCTAssertNil(try once(.init(ok: true, message: "Done", operationID: "op-a", code: "finished", requestID: retained, result: partial)).result)
        XCTAssertNil(try once(.init(ok: true, message: "Busy", operationID: "op-a", code: "busy", requestID: retained)).operationID)
        var clock = Date()
        func afterAcceptance(_ later: @escaping (ControlPort.Request) -> ControlPort.Response, file: StaticString = #filePath, line: UInt = #line) throws -> ControlPort.Response {
            var count = 0
            clock = Date()
            let output = CLI.execute(supplied, send: { request, _ in
                count += 1
                if request.cmd == "edit.v3" {
                    return ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: retained)
                }
                return later(request)
            }, sleep: { clock.addTimeInterval($0) }, now: { clock }, unavailable: "down")
            XCTAssertEqual(count, 2, "reply was retried", file: file, line: line)
            XCTAssertEqual(output.exitCode, 1, file: file, line: line)
            let decoded = try XCTUnwrap(decode(output.stdout), file: file, line: line)
            XCTAssertEqual(decoded.code, "protocol-error", file: file, line: line)
            XCTAssertEqual(decoded.requestID, retained, file: file, line: line)
            XCTAssertEqual(decoded.operationID, "op-a", file: file, line: line)
            XCTAssertNil(decoded.result, file: file, line: line)
            return decoded
        }
        _ = try afterAcceptance { _ in ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending") }
        _ = try afterAcceptance { _ in ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: "01234567-89AB-CDEF-0123-456789ABCDEF:99") }
        let foreignResult = OperationResult.note(id: "op-b", kind: "edit:resize", spaceID: 7, message: "other", ok: true)
        var steps = 0
        let changed = CLI.execute(supplied, send: { request, _ in
            steps += 1
            if request.cmd == "edit.v3" {
                return ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: retained)
            }
            return ControlPort.Response(ok: true, message: "Done", operationID: "op-b", code: "finished", requestID: retained, result: foreignResult)
        }, sleep: { clock.addTimeInterval($0) }, now: { clock }, unavailable: "down")
        XCTAssertEqual(steps, 2)
        let changedJSON = try XCTUnwrap(decode(changed.stdout))
        XCTAssertEqual(changed.exitCode, 1)
        XCTAssertEqual(changedJSON.code, "protocol-error")
        XCTAssertEqual(changedJSON.requestID, retained)
        XCTAssertEqual(changedJSON.operationID, "op-a")
        XCTAssertNil(changedJSON.result)
    }

    func testPublicTokenAndResultUseTheSharedValidator() throws {
        let token = "01234567-89AB-CDEF-0123-456789ABCDEF:17"
        let other = "01234567-89AB-CDEF-0123-456789ABCDEF:18"
        let operation = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let otherOperation = "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        guard case .invocation(let tokenCall) = CLI.parse(["request-token", "--json"]) else { return XCTFail("request-token did not parse") }
        var sends: [String] = []
        let missingAllocation = CLI.execute(tokenCall, send: { request, _ in
            sends.append(request.cmd)
            return ControlPort.Response(ok: true, message: "Reserved.", code: "reserved")
        }, unavailable: "down")
        XCTAssertEqual(sends, ["request-token.v3"])
        XCTAssertEqual(try XCTUnwrap(decode(missingAllocation.stdout)).code, "protocol-error")
        XCTAssertNotEqual(missingAllocation.exitCode, 0)
        let capacity = CLI.execute(tokenCall, send: { _, _ in
            ControlPort.Response(ok: false, message: "Too many reserved or in-flight requests.", code: "request-capacity")
        }, unavailable: "down")
        XCTAssertEqual(capacity.exitCode, 1)
        XCTAssertEqual(try XCTUnwrap(decode(capacity.stdout)).code, "request-capacity")

        guard case .invocation(let lookup) = CLI.parse(["result", token, "--json"]) else { return XCTFail("Receipt lookup did not parse") }
        let kept = OperationResult.note(id: operation, kind: "edit:resize", spaceID: 7, message: "kept", ok: true)
        let otherResult = OperationResult.note(id: otherOperation, kind: "edit:resize", spaceID: 7, message: "other", ok: true)
        func rejected(_ response: ControlPort.Response, file: StaticString = #filePath, line: UInt = #line) throws {
            let output = CLI.execute(lookup, send: { _, _ in response }, unavailable: "down")
            XCTAssertEqual(output.exitCode, 1, file: file, line: line)
            let decoded = try XCTUnwrap(decode(output.stdout), file: file, line: line)
            XCTAssertEqual(decoded.code, "protocol-error", file: file, line: line)
            XCTAssertEqual(decoded.requestID, token, file: file, line: line)
            XCTAssertNil(decoded.operationID, file: file, line: line)
            XCTAssertNil(decoded.result, file: file, line: line)
        }
        try rejected(.init(ok: true, message: "Done", operationID: otherOperation, code: "finished", requestID: other, result: otherResult))
        try rejected(.init(ok: true, message: "Done", operationID: operation, code: "finished", result: kept))
        try rejected(.init(ok: true, message: "Done", operationID: operation, code: "finished", requestID: token, result: otherResult))
        try rejected(.init(ok: true, message: "Done", operationID: operation, code: "finished", requestID: token, result: OperationResult.note(id: operation, kind: "edit:resize", spaceID: 7, message: "partial", ok: false)))
        var wrongSchema = ControlPort.Response(ok: true, message: "Done", operationID: operation, code: "finished", requestID: token, result: kept)
        wrongSchema.schemaVersion = 1
        try rejected(wrongSchema)

        let lostReceipt = CLI.execute(lookup, send: { _, _ in nil }, unavailable: "down")
        XCTAssertEqual(lostReceipt.exitCode, 2)
        let lostReceiptJSON = try XCTUnwrap(decode(lostReceipt.stdout))
        XCTAssertEqual(lostReceiptJSON.code, "connection-unavailable")
        XCTAssertEqual(lostReceiptJSON.requestID, token)
        XCTAssertNil(lostReceiptJSON.operationID)

        guard case .invocation(let operationLookup) = CLI.parse(["result", operation, "--json"]) else { return XCTFail("Operation lookup did not parse") }
        let lostOperation = CLI.execute(operationLookup, send: { _, _ in nil }, unavailable: "down")
        XCTAssertEqual(lostOperation.exitCode, 2)
        let lostOperationJSON = try XCTUnwrap(decode(lostOperation.stdout))
        XCTAssertEqual(lostOperationJSON.code, "connection-unavailable")
        XCTAssertEqual(lostOperationJSON.operationID, operation)
        XCTAssertNil(lostOperationJSON.requestID)
        let foreignOperation = CLI.execute(operationLookup, send: { _, _ in
            ControlPort.Response(ok: true, message: "Done", operationID: otherOperation, code: "finished", result: otherResult)
        }, unavailable: "down")
        let foreignOperationJSON = try XCTUnwrap(decode(foreignOperation.stdout))
        XCTAssertEqual(foreignOperation.exitCode, 1)
        XCTAssertEqual(foreignOperationJSON.code, "protocol-error")
        XCTAssertEqual(foreignOperationJSON.operationID, operation)
        XCTAssertNil(foreignOperationJSON.result)
    }

    func testPollPreservesRestartAndEvictionErrors() throws {
        let retained = "01234567-89AB-CDEF-0123-456789ABCDEF:17"
        guard case .invocation(let supplied) = CLI.parse(["resize", "width", "-0.1", "--window-id", "1", "--expect-space-id", "7", "--request-id", retained, "--json"]) else {
            return XCTFail("Supplied resize did not parse")
        }
        let terminal = [
            ("session-mismatch", "The request ID belongs to a different LazySpace session. An earlier effect may have occurred, and its outcome is unavailable."),
            ("request-expired", "The request ID is expired or no longer retained. It will not dispatch again.")
        ]
        for (code, message) in terminal {
            var commands: [String] = []
            var clock = Date()
            let output = CLI.execute(supplied, send: { request, _ in
                commands.append(request.cmd)
                if request.cmd == "edit.v3" {
                    return ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: retained)
                }
                return ControlPort.Response(ok: false, message: message, code: code, requestID: retained)
            }, sleep: { clock.addTimeInterval($0) }, now: { clock }, unavailable: "down")
            XCTAssertEqual(commands, ["edit.v3", "result"], code)
            XCTAssertEqual(output.exitCode, 1, code)
            let decoded = try XCTUnwrap(decode(output.stdout))
            XCTAssertEqual(decoded.code, code)
            XCTAssertEqual(decoded.message, message)
            XCTAssertEqual(decoded.requestID, retained)
            XCTAssertEqual(decoded.operationID, "op-a")
            XCTAssertNil(decoded.result)
        }
        var commands: [String] = []
        var clock = Date()
        let omitted = CLI.execute(supplied, send: { request, _ in
            commands.append(request.cmd)
            if request.cmd == "edit.v3" {
                return ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: retained)
            }
            return ControlPort.Response(ok: true, message: "Accepted.", code: "pending", requestID: retained)
        }, sleep: { clock.addTimeInterval($0) }, now: { clock }, unavailable: "down")
        XCTAssertEqual(commands, ["edit.v3", "result"])
        let omittedJSON = try XCTUnwrap(decode(omitted.stdout))
        XCTAssertEqual(omitted.exitCode, 1)
        XCTAssertEqual(omittedJSON.code, "protocol-error")
        XCTAssertEqual(omittedJSON.requestID, retained)
        XCTAssertEqual(omittedJSON.operationID, "op-a")
    }

    private func decode(_ text: String) -> ControlPort.Response? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? ControlPort.decoder.decode(ControlPort.Response.self, from: data)
    }
}

private extension MutationReceiptRegistry.Decision {
    var code: String? {
        if case .outcome(let outcome) = self { return outcome.code }
        return nil
    }
}

private extension MutationReceiptRegistry.Reservation {
    var code: String? {
        if case .refused(let outcome) = self { return outcome.code }
        return nil
    }
}

private extension CLI.Parsed {
    var isError: Bool { if case .error = self { return true }; return false }
    var invocation: CLI.Invocation? { if case .invocation(let value) = self { return value }; return nil }
}
