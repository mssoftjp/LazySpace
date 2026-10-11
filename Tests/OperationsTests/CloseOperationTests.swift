import XCTest
import LayoutCore
@testable import Operations

final class CloseOperationTests: XCTestCase {
    func testExcludedTargetsCannotBeClosed() {
        for w in [window(1, membership: .other), window(1, membership: .unknown),
                  window(1, membership: .allSpaces), window(1, kind: .dialog), window(1, kind: .fullscreen)] {
            let system = FakeSystem(windows: [w])
            system.focused = w.id
            let result = CloseOperation(system: system, control: OperationControl(), target: w.id).run()
            XCTAssertEqual(result.outcome, .notPossible)
            XCTAssertTrue(system.closeCalls.isEmpty)
        }
    }

    func testQueuedCloseIsInvalidatedByPauseResumeSpaceAndInput() {
        for change in 0..<3 {
            let system = FakeSystem(windows: [window(1)])
            system.focused = WindowID(1)
            let control = OperationControl()
            let op = CloseOperation(system: system, control: control, target: WindowID(1))
            switch change {
            case 0: control.paused = true; control.paused = false
            case 1: system.space = 8; system.snap.spaceID = 8
            default: system.inputActivityCount += 1
            }
            let result = op.run()
            XCTAssertEqual(result.outcome, .notPossible)
            XCTAssertEqual(result.stopReason, [.paused, .spaceChanged, .userInput][change])
            XCTAssertTrue(system.closeCalls.isEmpty)
        }
    }

    func testSpaceChangeDuringFocusReadPreventsClose() {
        let system = FakeSystem(windows: [window(1)])
        system.focused = WindowID(1)
        system.onFocusRead = { $0.space = 8 }
        let result = CloseOperation(system: system, control: OperationControl(), target: WindowID(1)).run()
        XCTAssertEqual(result.stopReason, .spaceChanged)
        XCTAssertTrue(system.closeCalls.isEmpty)
    }

    func testFocusChangePreventsClosingOldWindow() {
        let system = FakeSystem(windows: [window(1), window(2)])
        system.focused = WindowID(2)
        let result = CloseOperation(system: system, control: OperationControl(), target: WindowID(1)).run()
        XCTAssertEqual(result.stopReason, .targetsChanged)
        XCTAssertTrue(system.closeCalls.isEmpty)
    }

    func testCloseRequiresPermission() {
        let system = FakeSystem(windows: [window(1)], trusted: false)
        let result = CloseOperation(system: system, control: OperationControl(), target: WindowID(1)).run()
        XCTAssertEqual(result.stopReason, .permissionLost)
        XCTAssertTrue(system.closeCalls.isEmpty)
    }

    func testCloseConfirmsDisappearanceWithoutChangingGeometry() {
        let system = FakeSystem(windows: [window(1)])
        system.focused = WindowID(1)
        let result = CloseOperation(system: system, control: OperationControl(), target: WindowID(1)).run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.targets.first?.status, .gone)
        XCTAssertEqual(result.issued, 1)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(system.writes.isEmpty)
    }

    func testSaveConfirmationIsNotReportedAsClosed() {
        let system = FakeSystem(windows: [window(1)])
        system.focused = WindowID(1)
        system.confirmsClose = false
        let result = CloseOperation(system: system, control: OperationControl(), target: WindowID(1)).run()
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.issued, 1)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.targets.first?.status, .mismatch)
        XCTAssertTrue(result.message.contains("still open"), result.message)
    }
}
