import XCTest
import Operations
@testable import LazySpace

/// CLI result polling: the interval (short at first, longer for long operations) and `--json` `receivedAt` (the CLI's clock, from the acceptance reply).
final class CLIResultPollingTests: XCTestCase {
    private let token = "01234567-89AB-CDEF-0123-456789ABCDEF:3"

    private func invocation(json: Bool) throws -> CLI.Invocation {
        let args = ["space", "2", "--request-id", token] + (json ? ["--json"] : [])
        guard case .invocation(let call) = CLI.parse(args) else { XCTFail("space did not parse"); throw CancellationError() }
        return call
    }

    private func finished(_ timeline: [TimelineEvent] = []) -> ControlPort.Response {
        var result = OperationResult.note(id: "op-a", kind: "space", spaceID: 8, message: "Switched to Space 2.", ok: true)
        result.timeline = timeline
        return ControlPort.Response(ok: true, message: "Switched to Space 2.", operationID: "op-a", code: "finished", requestID: token, result: result)
    }

    func testPollIntervalStartsShortAndWidensForLongOperations() {
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 0), 0.02)
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 1.99), 0.02)
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 2), 0.1)
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 9.9), 0.1)
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 10), 0.25)
        XCTAssertEqual(CLI.resultPollInterval(elapsed: 119), 0.25)
    }

    /// An operation finishing in 0.5 s is not rounded up to a 250 ms step by the polling interval (delay within 20 ms).
    func testAFastOperationIsSeenWithinOneShortInterval() throws {
        var clock = Date(timeIntervalSince1970: 0)
        var uptime: TimeInterval = 100
        var slept: [TimeInterval] = []
        let output = CLI.execute(try invocation(json: true), send: { request, _ in
            if request.cmd == "edit.v3" { return ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: self.token) }
            // Finishes 0.5 s after acceptance.
            return clock.timeIntervalSince1970 >= 0.5 ? self.finished([TimelineEvent(at: 0, event: "accepted"), TimelineEvent(at: 480, event: "published")])
                : ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: self.token)
        }, sleep: { slept.append($0); clock.addTimeInterval($0); uptime += $0 }, now: { clock }, uptime: { uptime }, unavailable: "down")
        XCTAssertEqual(output.exitCode, 0, output.stdout)
        XCTAssertLessThanOrEqual(clock.timeIntervalSince1970, 0.52 + 1e-9)
        XCTAssertTrue(slept.allSatisfy { $0 == 0.02 })
        let decoded = try XCTUnwrap(ControlPort.decoder.decode(ControlPort.Response.self, from: Data(output.stdout.utf8)))
        XCTAssertEqual(try XCTUnwrap(decoded.receivedAt), 520, accuracy: 0.11, "the CLI's own clock, from the acceptance reply")
        XCTAssertEqual(decoded.result?.timeline.map(\.event), ["accepted", "published"], "the server timeline is kept separately")
    }

    /// Losing the app while a window inspection is pending is "not reachable" (exit 2), not a timeout.
    func testLosingTheAppDuringAnInspectionIsNotATimeout() throws {
        guard case .invocation(let inspect)? = CLI.parse(["list-windows"]) else { return XCTFail("parse") }
        var clock = Date(timeIntervalSince1970: 0)
        let output = CLI.execute(inspect, send: { request, _ in
            request.cmd == "inspect" ? ControlPort.Response(ok: true, message: "Reading windows…", operationID: "i-1") : nil
        }, sleep: { clock.addTimeInterval($0) }, now: { clock }, uptime: { clock.timeIntervalSince1970 }, unavailable: "down")
        XCTAssertEqual(output.exitCode, 2)
        XCTAssertTrue((output.stderr ?? output.stdout).contains("down"), output.stderr ?? output.stdout)
    }

    /// `receivedAt` is added only to completed results, never to human-readable text.
    func testReceivedAtOnlyOnCompletedJSONResults() throws {
        var clock = Date(timeIntervalSince1970: 0)
        let pendingForever = CLI.execute(try invocation(json: true), send: { request, _ in
            ControlPort.Response(ok: true, message: "Accepted.", operationID: "op-a", code: "pending", requestID: self.token)
        }, sleep: { clock.addTimeInterval($0) }, now: { clock }, uptime: { clock.timeIntervalSince1970 }, unavailable: "down")
        XCTAssertFalse(pendingForever.stdout.contains("receivedAt"), "a timeout carries no receive time")
        let immediate = CLI.execute(try invocation(json: true), send: { _, _ in self.finished() }, sleep: { _ in }, uptime: { 5 }, unavailable: "down")
        XCTAssertTrue(immediate.stdout.contains("\"receivedAt\" : 0"), immediate.stdout)
        let text = CLI.execute(try invocation(json: false), send: { _, _ in self.finished() }, sleep: { _ in }, uptime: { 5 }, unavailable: "down")
        XCTAssertFalse(text.stdout.contains("receivedAt"))
        XCTAssertTrue(text.stdout.contains("Switched to Space 2."), text.stdout)
    }
}
