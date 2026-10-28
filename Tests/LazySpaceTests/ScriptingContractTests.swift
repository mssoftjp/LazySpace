import Foundation
import Operations
import XCTest
@testable import LazySpaceApp

/// `docs/scripting.md` lists exactly the codes, blockers, outcomes, stop reasons, and causes the CLI can print.
final class ScriptingContractTests: XCTestCase {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The first column of every table in the guide whose header starts with `heading`, in order.
    private func documented(_ heading: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let text = try String(contentsOf: Self.root.appendingPathComponent("docs/scripting.md"), encoding: .utf8)
        var values: [String] = []
        var inTable = false
        for row in text.components(separatedBy: "\n") {
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard row.hasPrefix("|"), cells.count > 2 else { inTable = false; continue }
            if cells[1] == heading { inTable = true; continue }
            guard inTable, !cells[1].hasPrefix("---") else { continue }
            let cell = cells[1]
            guard cell.count > 2, cell.hasPrefix("`"), cell.hasSuffix("`") else {
                XCTFail("\(heading) table row without a single code: \(row)", file: file, line: line)
                continue
            }
            values.append(String(cell.dropFirst().dropLast()))
        }
        XCTAssertFalse(values.isEmpty, "no \(heading) table", file: file, line: line)
        XCTAssertEqual(values.count, Set(values).count, "a \(heading) value is listed twice", file: file, line: line)
        return values
    }

    func testEveryCodeIsDocumented() throws {
        XCTAssertEqual(Set(try documented("Code")), Set(ResultCode.allCases.map(\.rawValue)))
    }

    func testEveryWaitSettledBlockerIsDocumented() throws {
        XCTAssertEqual(Set(try documented("Blocker")), Set(SettlementBlocker.allCases.map(\.rawValue)))
    }

    /// Outcome names are read from Swift's own encoding, which `PublicJSON` turns into the string.
    func testEveryOutcomeAndStopReasonIsDocumented() throws {
        let outcomes = try Outcome.allCases.map { outcome -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome)) as? [String: Any])
            return try XCTUnwrap(object.keys.first)
        }
        XCTAssertEqual(Set(try documented("Outcome")), Set(outcomes))
        XCTAssertEqual(Set(try documented("Stop reason")), Set(StopReason.allCases.map(\.rawValue)))
    }

    /// The guide says the causes are checked in the order listed.
    func testCausesAreDocumentedInTheOrderTheyAreChecked() throws {
        XCTAssertEqual(try documented("Cause"), AutoUnavailableCause.allCases.map(\.rawValue))
    }
}
