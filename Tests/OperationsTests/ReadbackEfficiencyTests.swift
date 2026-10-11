import XCTest
import LayoutCore
@testable import Operations

final class ReadbackEfficiencyTests: XCTestCase {
    func testUnchangedSiblingInTheSameAppStillSettles() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var a = window(1, app: "shared"); a.frame = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let b = window(2, app: "shared")
        let s = FakeSystem(windows: [a, b], area: area)
        var sleeps = 0
        let result = ArrangeOperation(system: s, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                      limits: OperationLimits(maxRetries: 0),
                                      priorLayout: Planner.rowLayout([a.id, b.id], rows: 1), sleep: { _ in
            sleeps += 1
            // The app moves the unwritten sibling before the first reading, so that reading does not match its request.
            if sleeps == 1 { s.frames[a.id] = CGRect(x: 0, y: 0, width: 550, height: 1000) }
        }).run()
        XCTAssertGreaterThanOrEqual(sleeps, 2, "A sibling that does not match its request keeps the wait going")
        XCTAssertNotEqual(result.outcome, .complete)
        XCTAssertEqual(result.targets.first { $0.id == a.id }?.after?.width, 550)
    }

    func testOnlyChangedWindowsSettleAndFinalStableReadingIsReused() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        var a = window(1); a.frame = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let b = window(2)
        let s = FakeSystem(windows: [a, b], area: area)
        var sleeps = 0
        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                  priorLayout: Planner.rowLayout([a.id, b.id], rows: 1), sleep: { _ in sleeps += 1 })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.issued, 1)
        XCTAssertEqual(sleeps, 1, "A reading that matches every request ends the wait")
        XCTAssertEqual(s.reads[a.id], 2, "An unchanged window still gets final verification")
        XCTAssertEqual(s.reads[b.id], 2, "Pre-write plus one matching read, without a duplicate final read")
        XCTAssertEqual(s.suppliedFrames.first?.1, b.frame)
        XCTAssertEqual(result.targets.first { $0.id == b.id }?.after, CGRect(x: 500, y: 0, width: 500, height: 1000))
    }

    func testUnsettledOrInterruptedReadbackDoesNotReuseOldGeometry() {
        for event in ["input", "space", "pause", "hurry", "aged"] {
            let s = FakeSystem(windows: [window(1)])
            let control = OperationControl()
            var changed = false
            var readsAtCheck = 0
            let expected = CGRect(x: 200, y: 300, width: 600, height: 450)
            let op = ArrangeOperation(system: s, control: control, knowledge: ConstraintKnowledge(),
                                      limits: OperationLimits(maxRetries: 0), sleep: { _ in })
            let result = op.run { progress in
                guard progress == "Checking actual sizes", !changed else { return }
                changed = true
                readsAtCheck = s.reads[WindowID(1)] ?? 0
                switch event {
                case "input": s.inputActivityCount += 1
                case "space": s.space = 8
                case "pause": control.paused = true
                case "hurry": control.hurrySettle = true; s.inputActivityCount += 1
                case "aged": Thread.sleep(forTimeInterval: 0.06)
                default: break
                }
                s.frames[WindowID(1)] = expected
            }
            XCTAssertEqual(result.targets.first?.after, expected, event)
            XCTAssertGreaterThan(s.reads[WindowID(1)] ?? 0, readsAtCheck, "\(event): the final check reads again")
        }
    }

    func testHurryBeforeSettleStillReadsFinalGeometry() {
        let s = FakeSystem(windows: [window(1)])
        let control = OperationControl(); control.hurrySettle = true
        var sleeps = 0
        let result = ArrangeOperation(system: s, control: control, knowledge: ConstraintKnowledge(),
                                      sleep: { _ in sleeps += 1 }).run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(sleeps, 0)
        XCTAssertEqual(s.reads[WindowID(1)], 2)
    }

    func testReadingThatDiffersFromTheRequestNeedsTwoAgreeingReadings() {
        let s = FakeSystem(windows: [window(1)])
        s.minimums[WindowID(1)] = CGSize(width: 1500, height: 1200)
        var sleeps = 0
        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                  limits: OperationLimits(maxRetries: 0), sleep: { _ in sleeps += 1 })
        _ = op.run()
        XCTAssertEqual(sleeps, 2, "A size the app enforced is accepted only after it holds for two readings")
    }

    func testFrameStillChangingAfterFirstReadingKeepsWaiting() {
        let s = FakeSystem(windows: [window(1)])
        var sleeps = 0
        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                  limits: OperationLimits(maxRetries: 0), sleep: { _ in
            sleeps += 1
            if sleeps == 1 { s.frames[WindowID(1)] = CGRect(x: 40, y: 40, width: 650, height: 500) }
            if sleeps == 2 { s.frames[WindowID(1)] = CGRect(x: 40, y: 40, width: 700, height: 500) }
        })
        let result = op.run()
        XCTAssertGreaterThanOrEqual(sleeps, 3)
        XCTAssertNotEqual(result.outcome, .complete)
        XCTAssertEqual(result.targets.first?.after, CGRect(x: 40, y: 40, width: 700, height: 500))
    }
}
