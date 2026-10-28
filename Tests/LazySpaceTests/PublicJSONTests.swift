import CoreGraphics
import Foundation
import LayoutCore
@testable import MacSupport
@testable import Operations
import XCTest
@testable import LazySpaceApp

/// The `--json` output (`docs/scripting.md`): window IDs as numbers, rectangles as named fields, outcomes as strings,
/// while the wire to the app and the state file keep Swift's own encodings.
final class PublicJSONTests: XCTestCase {
    private let token = "01234567-89AB-CDEF-0123-456789ABCDEF:3"

    private func window(_ id: UInt32, frame: CGRect, membership: ObservedWindow.Membership = .current) -> ObservedWindow {
        ObservedWindow(id: WindowID(id), pid: 42, app: "com.example.app", frame: frame, membership: membership, kind: .standard,
                       detail: "AXWindow/AXStandardWindow layer=0", subrole: "AXStandardWindow", stackOrder: 0)
    }

    private func result(_ outcome: Outcome = .partial) -> OperationResult {
        var result = OperationResult(
            id: "op-1", kind: "arrange", startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1), outcome: outcome,
            stopReason: .appUnresponsive, spaceID: 884, workArea: CGRect(x: -1440, y: 25, width: 1440, height: 875.5),
            targets: [TargetReport(id: WindowID(5), app: "com.example.app", before: CGRect(x: 0, y: 25, width: 720, height: 875),
                                   planned: CGRect(x: 0, y: 25, width: 719.5, height: 875), after: nil, status: .unapplied, issued: 0)],
            excluded: [Exclusion(window: window(6, frame: CGRect(x: 10, y: 30.5, width: 400, height: 300)), reason: "Too large", code: .overflowFloat)],
            issued: 1, retries: 0, verified: false, maxWriteMs: 0.1, wallMs: 12.3, message: "Partly arranged.", tolerance: 1, rows: 1,
            unobservedApps: ["com.example.slow"], timing: OperationTiming(observeMs: 1.5, planMs: 0, writeMs: 2, settleMs: 0.25))
        result.timeline = [TimelineEvent(at: 0, event: "accepted"), TimelineEvent(at: 12.3, event: "published")]
        return result
    }

    private func status() -> AppStatus {
        var status = AppStatus(
            availability: .manualOnly, availabilityReason: "Manual arrangement only", manualAvailable: true, manualReason: "Available",
            autoAvailable: false, autoReason: "Stage Manager is on.", currentSpaceManaged: true, trusted: true, spaceObservation: true,
            inputObservation: "mouseAndKeyboard", paused: false, progress: .idle, progressText: "", waiting: [WindowID(9)],
            floating: [WindowID(7), WindowID(8)], zoomed: WindowID(5), lastRefusal: nil, configPath: "/tmp/config.toml", configError: nil,
            focusedWindow: WindowID(5), lastResult: result(), version: "0.6.1", mode: "main", modes: ["main"], loginItem: "Off", loginItemEnabled: false)
        status.autoUnavailableCause = AutoUnavailableCause.stageManager.rawValue
        status.currentSpaceID = 884
        return status
    }

    private func inspection() -> Inspection {
        let windows = [window(110138, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)),
                       window(7, frame: CGRect(x: 0, y: 30, width: 2560, height: 1410), membership: .other)]
        let snapshot = Snapshot(trusted: true, spaceID: 884, workArea: CGRect(x: 0, y: 30, width: 2560, height: 1410), windows: windows,
                                spaceObservationAvailable: true)
        return Inspection(snapshot: snapshot, targets: [windows[0]], excluded: [Exclusion(window: windows[1], reason: "On another Space")],
                          takenAt: Date(timeIntervalSince1970: 0))
    }

    private func overview() -> SpaceOverview {
        SpaceOverview(spaces: [.init(spaceID: UInt64.max, type: 0, isCurrent: true, windowIDs: [WindowID(110138)]),
                               .init(spaceID: 4, type: 0, isCurrent: false, windowIDs: [])],
                      unknown: [WindowID(3)])
    }

    private func finished(_ result: OperationResult) -> ControlPort.Response {
        ControlPort.Response(ok: result.outcome == .complete, message: "", operationID: result.id, code: .finished, requestID: token, result: result)
    }

    private func json(_ response: ControlPort.Response, cmd: String = "status", view: String? = nil) -> String {
        CLI.render(response, invocation: CLI.Invocation(cmd: cmd, json: true, view: view))
    }

    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text, file: file, line: line)
    }

    func testStatusNamesWindowsByNumberAndRectanglesByField() throws {
        let object = try parse(json(ControlPort.Response(ok: true, message: "", status: status())))
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        let status = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(status["focusedWindow"] as? Int, 5)
        XCTAssertEqual(status["zoomed"] as? Int, 5)
        XCTAssertEqual(status["floating"] as? [Int], [7, 8])
        XCTAssertEqual(status["waiting"] as? [Int], [9])
        XCTAssertEqual(status["currentSpaceID"] as? Int, 884)
        XCTAssertEqual(status["autoUnavailableCause"] as? String, "stageManager")
        XCTAssertEqual(status["configNotes"] as? [String], [], "an empty list stays a list")
        let result = try XCTUnwrap(status["lastResult"] as? [String: Any])
        XCTAssertEqual(result["outcome"] as? String, "partial")
        XCTAssertEqual(result["stopReason"] as? String, "appUnresponsive")
        XCTAssertEqual(result["workArea"] as? [String: Double], ["x": -1440, "y": 25, "width": 1440, "height": 875.5])
        let target = try XCTUnwrap((result["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["id"] as? Int, 5)
        XCTAssertEqual(target["before"] as? [String: Double], ["x": 0, "y": 25, "width": 720, "height": 875])
        XCTAssertEqual(target["planned"] as? [String: Double], ["x": 0, "y": 25, "width": 719.5, "height": 875])
        XCTAssertNil(target["after"], "an absent rectangle stays absent")
        XCTAssertEqual(target["status"] as? String, "unapplied")
        let excluded = try XCTUnwrap((result["excluded"] as? [[String: Any]])?.first)
        XCTAssertEqual(excluded["code"] as? String, "overflowFloat")
        let window = try XCTUnwrap(excluded["window"] as? [String: Any])
        XCTAssertEqual(window["id"] as? Int, 6)
        XCTAssertEqual(window["frame"] as? [String: Double], ["x": 10, "y": 30.5, "width": 400, "height": 300])
        XCTAssertEqual(result["unobservedApps"] as? [String], ["com.example.slow"])
        XCTAssertEqual((result["timeline"] as? [[String: Any]])?.map { $0["event"] as? String }, ["accepted", "published"])
    }

    func testWindowAndSpaceListsUseTheNumbersWindowIDTakes() throws {
        let response = ControlPort.Response(ok: true, message: "", status: status(), inspection: inspection(), spaces: overview(), operationID: "i-1")
        let windows = try parse(json(response, cmd: "inspect", view: "windows"))
        XCTAssertNil(windows["status"])
        XCTAssertNil(windows["spaces"])
        let inspection = try XCTUnwrap(windows["inspection"] as? [String: Any])
        let target = try XCTUnwrap((inspection["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["id"] as? Int, 110138)
        XCTAssertEqual(target["pid"] as? Int, 42)
        XCTAssertEqual(target["frame"] as? [String: Double], ["x": -1920, "y": 0, "width": 1920, "height": 1055])
        let excluded = try XCTUnwrap((inspection["excluded"] as? [[String: Any]])?.first?["window"] as? [String: Any])
        XCTAssertEqual(excluded["id"] as? Int, 7)
        XCTAssertEqual(excluded["membership"] as? String, "other")
        let snapshot = try XCTUnwrap(inspection["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["workArea"] as? [String: Double], ["x": 0, "y": 30, "width": 2560, "height": 1410])
        XCTAssertEqual((snapshot["windows"] as? [[String: Any]])?.map { $0["id"] as? Int }, [110138, 7])

        let spacesText = json(response, cmd: "inspect", view: "spaces")
        let spaces = try parse(spacesText)
        XCTAssertNil(spaces["inspection"])
        let overview = try XCTUnwrap(spaces["spaces"] as? [String: Any])
        let entries = try XCTUnwrap(overview["spaces"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["windowIDs"] as? [Int] }, [[110138], []], "an empty list stays a list")
        XCTAssertEqual(overview["unknown"] as? [Int], [3])
        XCTAssertTrue(spacesText.contains("\"spaceID\" : 18446744073709551615"), "a 64-bit Space ID keeps every digit: \(spacesText)")
    }

    func testEveryOutcomeIsItsName() throws {
        let names: [(Outcome, String)] = [(.complete, "complete"), (.partial, "partial"), (.interrupted, "interrupted"),
                                          (.notPossible, "notPossible"), (.nothingToDo, "nothingToDo")]
        XCTAssertEqual(names.count, Outcome.allCases.count)
        for (outcome, name) in names {
            let object = try parse(json(finished(result(outcome)), cmd: "edit.v3"))
            XCTAssertEqual((object["result"] as? [String: Any])?["outcome"] as? String, name)
            XCTAssertEqual(object["code"] as? String, "finished")
            XCTAssertEqual(object["requestID"] as? String, token)
            XCTAssertEqual(object["operationID"] as? String, "op-1")
        }
    }

    /// Doubles are written as `JSONEncoder` writes them (`0.1`), not as `JSONSerialization` would (`0.10000000000000001`).
    func testNumbersKeepTheirSpelling() {
        var response = finished(result())
        response.receivedAt = 0.1
        let text = json(response, cmd: "edit.v3")
        for expected in ["\"receivedAt\" : 0.1", "\"at\" : 12.3", "\"wallMs\" : 12.3", "\"maxWriteMs\" : 0.1", "\"observeMs\" : 1.5",
                         "\"settleMs\" : 0.25", "\"height\" : 875.5", "\"x\" : -1440", "\"spaceID\" : 884",
                         "\"issued\" : 1", "\"retries\" : 0", "\"verified\" : false", "\"ok\" : false"] {
            XCTAssertTrue(text.contains(expected), "\(expected) in \(text)")
        }
        XCTAssertFalse(text.contains("00000000"), text)
        XCTAssertFalse(text.contains("99999999"), text)
    }

    func testNoSwiftEncodingReachesTheOutput() throws {
        let everything = ControlPort.Response(ok: true, message: "", status: status(), inspection: inspection(), spaces: overview(), operationID: "op-1",
                                              settlement: ControlPort.Settlement(settled: false, spaceID: 884, observedAt: Date(timeIntervalSince1970: 0), stableFor: 0.5,
                                                                                requiredStableFor: 1, blockers: [SettlementBlocker.observing.rawValue]),
                                              code: .finished, requestID: token, result: result())
        for (cmd, view) in [("status", nil), ("edit.v3", nil), ("inspect", "windows"), ("inspect", "spaces"), ("wait-settled", nil)] as [(String, String?)] {
            assertPublic(try JSONSerialization.jsonObject(with: Data(json(everything, cmd: cmd, view: view).utf8)), path: cmd)
        }
    }

    private func assertPublic(_ value: Any, path: String) {
        if let object = value as? [String: Any] {
            XCTAssertFalse(object.count == 1 && object["raw"] != nil, "\(path) is a Swift window ID")
            if let outcome = object["outcome"] { XCTAssertTrue(outcome is String, "\(path).outcome is \(outcome)") }
            for (key, child) in object { assertPublic(child, path: path + "." + key) }
        } else if let array = value as? [Any] {
            let pairs = array.compactMap { $0 as? [NSNumber] }
            XCTAssertFalse(array.count == 2 && pairs.count == 2 && pairs.allSatisfy { $0.count == 2 }, "\(path) is a Swift rectangle")
            for (index, child) in array.enumerated() { assertPublic(child, path: "\(path)[\(index)]") }
        }
    }

    /// The state file's layouts store window IDs as `{"raw": N}` (`StateStore.load` starts empty when they do not decode), and a CLI
    /// newer than the running app reads its replies, so only the CLI's output changes.
    func testTheWireAndTheStateFileKeepSwiftEncodings() throws {
        XCTAssertEqual(String(data: try JSONEncoder().encode(WindowID(5)), encoding: .utf8), #"{"raw":5}"#)
        let response = ControlPort.Response(ok: true, message: "", status: status())
        let wire = try XCTUnwrap(String(data: ControlPort.encoder.encode(response), encoding: .utf8))
        XCTAssertTrue(wire.contains("\"raw\" : 5"), wire)
        XCTAssertTrue(wire.contains("\"partial\" : {"), wire)
        XCTAssertTrue(wire.contains("\"schemaVersion\" : 2"), wire)
        XCTAssertEqual(ControlPort.wireSchemaVersion, 2)
        XCTAssertEqual(PublicJSON.schemaVersion, 3)
        XCTAssertEqual(try ControlPort.decoder.decode(ControlPort.Response.self, from: Data(wire.utf8)).status, response.status)
    }

    /// Only the documented places are rewritten, and a value there in another shape stops the output.
    func testOnlyDocumentedPlacesAreRewrittenAndOtherShapesThere() throws {
        func rewrite(_ json: String) throws -> PublicJSON.Value {
            try PublicJSON.rewrite(ControlPort.decoder.decode(PublicJSON.Value.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try rewrite(#"{"other": {"raw": 1}, "status": {"mode": "main"}}"#),
                       .object(["other": .object(["raw": .int(1)]), "status": .object(["mode": .string("main")]), "schemaVersion": .int(3)]))
        let wrong = [
            (#"{"status": {"focusedWindow": {"raw": "1"}}}"#, ".status.focusedWindow"),
            (#"{"status": {"floating": [{"raw": 1, "extra": 2}]}}"#, ".status.floating[0]"),
            (#"{"result": {"workArea": [[0, 0], [1]]}}"#, ".result.workArea"),
            (#"{"result": {"outcome": {"finishedEarly": {}}}}"#, ".result.outcome"),
            (#"{"result": {"outcome": {"complete": {"why": 1}}}}"#, ".result.outcome"),
            (#"{"inspection": {"targets": [{"frame": {"x": 0}}]}}"#, ".inspection.targets[0].frame"),
            (#"{"spaces": {"unknown": {"raw": 1}}}"#, ".spaces.unknown"),
        ]
        for (json, path) in wrong {
            XCTAssertThrowsError(try rewrite(json), json) { XCTAssertEqual($0 as? PublicJSON.ShapeError, PublicJSON.ShapeError(path: path), json) }
        }
    }

    func testAReplyThatCannotBeWrittenIsAnErrorWithItsIDs() throws {
        var broken = result(.complete)
        broken.wallMs = .nan
        guard case .invocation(let call)? = CLI.parse(["space", "2", "--request-id", token, "--json"]) else { return XCTFail("parse") }
        let output = CLI.execute(call, send: { _, _ in self.finished(broken) }, sleep: { _ in }, uptime: { 0 }, unavailable: "down")
        XCTAssertEqual(output.exitCode, 1, "a complete operation whose reply cannot be written does not exit 0")
        let object = try parse(output.stdout)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["code"] as? String, "internal-error")
        XCTAssertEqual(object["requestID"] as? String, token)
        XCTAssertEqual(object["operationID"] as? String, "op-1")
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
    }

    /// Every reply is checked for the wire schema before it is printed, not only receipts and results.
    func testRepliesInAnotherWireSchemaAreProtocolErrors() throws {
        func older(_ response: ControlPort.Response) -> ControlPort.Response {
            var older = response
            older.schemaVersion = ControlPort.wireSchemaVersion - 1
            return older
        }
        func assertProtocolError(_ output: CLI.Output, _ label: String) throws {
            XCTAssertEqual(output.exitCode, 1, label)
            XCTAssertEqual(try parse(output.stdout)["code"] as? String, "protocol-error", label)
        }
        try assertProtocolError(CLI.execute(CLI.Invocation(cmd: "status", json: true), send: { _, _ in older(ControlPort.Response(ok: true, message: "", status: self.status())) },
                                            unavailable: "down"), "status")

        guard case .invocation(let list)? = CLI.parse(["list-windows", "--json"]) else { return XCTFail("parse") }
        let reading = ControlPort.Response(ok: true, message: "Reading windows…", operationID: "i-1")
        try assertProtocolError(CLI.execute(list, send: { _, _ in older(reading) }, sleep: { _ in }, unavailable: "down"), "list-windows start")
        let listed = ControlPort.Response(ok: true, message: "", status: status(), inspection: inspection(), spaces: overview())
        try assertProtocolError(CLI.execute(list, send: { request, _ in request.cmd == "inspect" ? reading : older(listed) }, sleep: { _ in }, unavailable: "down"),
                                "list-windows result")

        guard case .invocation(let wait)? = CLI.parse(["wait-settled", "1", "--json"]) else { return XCTFail("parse") }
        let observing = ControlPort.Response(ok: true, message: "Observing.", operationID: "s-1", code: .pending)
        let settled = ControlPort.Response(ok: true, message: "", operationID: "s-1",
                                           settlement: ControlPort.Settlement(settled: true, spaceID: 884, observedAt: Date(), stableFor: 2, requiredStableFor: 1, blockers: []))
        for (label, reply) in [("start", { (request: ControlPort.Request) in older(observing) }),
                               ("observation", { (request: ControlPort.Request) in request.cmd == "settle.v2" ? observing : older(settled) })] {
            var clock = Date(timeIntervalSince1970: 0)
            try assertProtocolError(CLI.execute(wait, send: { request, _ in reply(request) }, sleep: { clock.addTimeInterval($0) }, now: { clock },
                                                uptime: { clock.timeIntervalSince1970 }, unavailable: "down"), "wait-settled \(label)")
        }
    }
}
