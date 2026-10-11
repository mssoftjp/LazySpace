import XCTest
import Operations
@testable import lzprobe

/// lzprobe `--json`: diagnostics go to stderr; stdout holds exactly one JSON document (including the final tap drain result).
final class ProbeOutputTests: XCTestCase {
    private var out: [String] = []
    private var err: [String] = []
    private var saved: (Bool, (String) -> Void, (String) -> Void)!

    override func setUp() {
        saved = (ProbeOutput.json, ProbeOutput.writeOut, ProbeOutput.writeErr)
        out = []; err = []
        ProbeOutput.writeOut = { [unowned self] in out.append($0) }
        ProbeOutput.writeErr = { [unowned self] in err.append($0) }
    }

    override func tearDown() {
        (ProbeOutput.json, ProbeOutput.writeOut, ProbeOutput.writeErr) = saved
    }

    private func records() -> [SwitchSequence.Record] {
        let move = SwitchSequence.Record(label: "move:9", ok: true, detail: "moved 10: 3 -> 9 steps=0", startMs: 0, callMs: 432.1, fromSpace: 3, toSpace: 9,
                                         steps: 0, wallMs: 430, activeAfter: 9, membershipAfter: [9],
                                         timeline: [TimelineEvent(at: 0, event: "accepted"), TimelineEvent(at: 10.2, event: "mainKeyPosted", attempt: 1)])
        let then = SwitchSequence.Record(label: "hotkey:4", ok: true, detail: "hotkey:4: tier 0: switched", startMs: 432.5, callMs: 295, fromSpace: 9, toSpace: 4,
                                         steps: 0, wallMs: 294, activeAfter: 4, membershipAfter: nil, timeline: [TimelineEvent(at: 0, event: "accepted")])
        return [move, then]
    }

    /// Writes in the real order (diagnostics, one line per record, drain, document), and all of stdout parses as one document.
    func testJSONModeWritesDiagnosticsToStderrAndOneDocumentToStdout() throws {
        ProbeOutput.json = true
        diag("direct move: available")
        let records = records()
        for record in records { diag(SwitchSequence.describe(record)) }
        diag("pass-through tap drained (best effort, 1 s quiet): true")
        let ok = SwitchSequence.emit(SwitchSequence.Document(command: "direct-move", settle: "observed", operations: records, sequenceMs: 727.6, ok: true), drained: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(err.count, 4, "every diagnostic line goes to stderr")
        let stdout = out.joined(separator: "\n")
        let document = try JSONDecoder().decode(SwitchSequence.Document.self, from: Data(stdout.utf8))
        XCTAssertEqual(document.operations, records)
        XCTAssertEqual(document.drained, true)
        XCTAssertEqual(document.sequenceMs, 727.6, "the sequence total is separate from each operation's call time")
        XCTAssertEqual(document.operations[0].activeAfter, 9, "the move's own observations, not the second operation's")
        XCTAssertEqual(document.operations[0].membershipAfter, [9])
        XCTAssertNil(document.error)
    }

    /// If the drain times out, the document and the exit code both fail.
    func testAnUndrainedTapFailsTheDocument() throws {
        ProbeOutput.json = true
        XCTAssertFalse(SwitchSequence.emit(SwitchSequence.Document(command: "direct-switch-app", settle: "observed", operations: records(), sequenceMs: 1, ok: true), drained: false))
        let document = try JSONDecoder().decode(SwitchSequence.Document.self, from: Data(out.joined(separator: "\n").utf8))
        XCTAssertEqual(document.drained, false)
        XCTAssertFalse(document.ok)
    }

    /// Without `--json`, diagnostics go to stdout and no document is written.
    func testTextModeWritesNoDocument() {
        ProbeOutput.json = false
        diag("home 3 dest 9")
        XCTAssertTrue(SwitchSequence.emit(SwitchSequence.Document(command: "direct-switch-app", settle: "observed", operations: [], sequenceMs: 0, ok: true), drained: true))
        XCTAssertEqual(out, ["home 3 dest 9"])
        XCTAssertTrue(err.isEmpty)
    }

    func testThenSpecParsing() {
        XCTAssertEqual(SwitchSequence.parse("4", default: .hotkey).map { "\($0.mode):\($0.index)" }, "hotkey:4")
        XCTAssertEqual(SwitchSequence.parse("stepping:6", default: .hotkey).map { "\($0.mode):\($0.index)" }, "stepping:6")
        XCTAssertNil(SwitchSequence.parse("drag:2", default: .app))
    }
}
