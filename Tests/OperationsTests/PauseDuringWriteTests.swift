import XCTest
import LayoutCore
import Operations

final class PauseDuringWriteTests: XCTestCase {
    func testAccordionDoesNotRaiseAfterPauseDuringLastWrite() {
        let s = FakeSystem(windows: [window(1), window(2, x: 600)])
        s.focused = WindowID(1)
        let control = OperationControl()
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        s.onWrite = { _, count in if count == 2 { control.paused = true } }
        let result = ArrangeOperation(system: s, control: control, knowledge: ConstraintKnowledge(), limits: OperationLimits(settleDelay: 0), priorLayout: layout, sleep: { _ in }).run()
        XCTAssertEqual(result.stopReason, .paused)
        XCTAssertEqual(s.writes.count, 2)
        XCTAssertTrue(s.focusCalls.isEmpty, "Pause after the final geometry write must prevent the subsequent raise")
    }

    func testRollbackStopsAfterPauseDuringFirstRestore() {
        let area = CGRect(x: 0, y: 33, width: 800, height: 400)
        let s = FakeSystem(windows: [window(1, x: 0), window(2, x: 300)], area: area)
        s.minimums[WindowID(1)] = CGSize(width: 500, height: 300)
        s.minimums[WindowID(2)] = CGSize(width: 500, height: 300)
        let control = OperationControl()
        var writesAtPause: Int?
        s.onWrite = { _, count in
            if count == 3 { writesAtPause = count; control.paused = true }
        }
        let result = ArrangeOperation(system: s, control: control, knowledge: ConstraintKnowledge(), limits: OperationLimits(settleDelay: 0), priorLayout: Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1), kind: "edit:resize", transform: { layout, _ in layout }, sleep: { _ in }).run()
        XCTAssertEqual(writesAtPause, 3, "Fixture must reach rollback")
        XCTAssertEqual(s.writes.count, writesAtPause, "Rollback must not issue the next write after Pause")
        XCTAssertEqual(result.stopReason, .paused)
        XCTAssertTrue(result.targets.contains { $0.noteKind == .notRestoredAfterStop })
    }
}
