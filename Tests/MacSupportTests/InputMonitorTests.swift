import XCTest
@testable import MacSupport

final class InputMonitorTests: XCTestCase {
    func testCompletedDragSurvivesUntilTheNextObservation() {
        let monitor = InputMonitor()
        func record(_ type: CGEventType, synthetic: Bool = false) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
            if synthetic { event.setIntegerValueField(.eventSourceUserData, value: SpaceControl.syntheticTag) }
            monitor.record(type, event: event)
        }
        for _ in 0..<2 {
            record(.leftMouseDown)
            record(.leftMouseDragged)
            record(.leftMouseDragged)
            record(.leftMouseUp)
        }
        XCTAssertFalse(monitor.leftMouseDown)
        XCTAssertEqual(monitor.completedMouseDrags, 2)
        record(.leftMouseUp) // A duplicate release is not another drag.
        record(.leftMouseDown)
        record(.leftMouseUp) // A click is not a drag.
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            record(type, synthetic: true) // LazySpace' own Space movement is not a manual edit.
        }
        XCTAssertEqual(monitor.completedMouseDrags, 2)
    }

    /// Releasing a running monitor without stopping it, or starting and stopping it repeatedly, never lets the tap thread touch a freed monitor.
    func testReleasingOrRestartingARunningMonitorIsSafe() throws {
        for _ in 0..<20 {
            var monitor: InputMonitor? = InputMonitor()
            guard monitor?.start() != .unavailable else {
                throw XCTSkip("input observation cannot start in this test process")
            }
            monitor?.stop()
            _ = monitor?.start()
            monitor = nil
        }
    }
}

/// A button released while the tap was stopped is not assumed held. The unobserved gap counts as input.
final class InputGapTests: XCTestCase {
    func testObservationGapReconcilesTheLeftButtonAndCountsAsInput() {
        let monitor = InputMonitor()
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        monitor.record(.leftMouseDown, event: event)
        XCTAssertTrue(monitor.leftMouseDown)
        let count = monitor.count
        monitor.noteObservationGap(leftButtonDown: false)
        XCTAssertFalse(monitor.leftMouseDown)
        XCTAssertGreaterThan(monitor.count, count)
    }
}
