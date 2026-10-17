import CoreGraphics
import XCTest
import LayoutCore
@testable import LazySpaceApp

final class IntegrationRetryLedgerTests: XCTestCase {
    private let window = WindowID(7)
    private let frame = CGRect(x: 10, y: 20, width: 300, height: 200)

    func testTwoIdenticalFailuresGiveUpAndAnAppOnlyMoveDoesNotReset() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 4, tolerance: 1)
        XCTAssertFalse(ledger.gaveUp(window))
        var writtenByApp = frame
        writtenByApp.origin.x += 30
        ledger.record([window], bounds: [window: writtenByApp], inputCount: 4, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
        XCTAssertFalse(ledger.forgiveMoved(id: window, frame: writtenByApp.offsetBy(dx: 12, dy: 0), inputCount: 4, tolerance: 1))
        XCTAssertTrue(ledger.gaveUp(window))
        XCTAssertFalse(ledger.isEmpty)
    }

    func testAUserMoveResetsTheCount() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 4, tolerance: 1)
        ledger.record([window], bounds: [window: frame], inputCount: 4, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
        let moved = frame.offsetBy(dx: 40, dy: 0)
        XCTAssertTrue(ledger.forgiveMoved(id: window, frame: moved, inputCount: 5, tolerance: 1))
        XCTAssertFalse(ledger.gaveUp(window))
        XCTAssertTrue(ledger.isEmpty)
        ledger.record([window], bounds: [window: moved], inputCount: 5, tolerance: 1)
        XCTAssertFalse(ledger.gaveUp(window))
    }

    func testRecordingAfterAUserMoveStartsAgain() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 1, tolerance: 1)
        let moved = frame.offsetBy(dx: 0, dy: 25)
        ledger.record([window], bounds: [window: moved], inputCount: 2, tolerance: 1)
        XCTAssertFalse(ledger.gaveUp(window))
        ledger.record([window], bounds: [window: moved], inputCount: 2, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
    }

    func testInputChangeWithinToleranceDoesNotForgive() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 1, tolerance: 1)
        ledger.record([window], bounds: [window: frame], inputCount: 1, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
        XCTAssertFalse(ledger.forgiveMoved(id: window, frame: frame, inputCount: 2, tolerance: 1))
        let nudged = frame.offsetBy(dx: 0.4, dy: 0)
        XCTAssertFalse(ledger.forgiveMoved(id: window, frame: nudged, inputCount: 3, tolerance: 1))
        XCTAssertTrue(ledger.gaveUp(window))
        XCTAssertFalse(ledger.isEmpty)
    }

    func testMissingBoundsReusesTheRecordedFrame() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 4, tolerance: 1)
        ledger.record([window], bounds: [:], inputCount: 5, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
        let moved = frame.offsetBy(dx: 40, dy: 0)
        XCTAssertTrue(ledger.forgiveMoved(id: window, frame: moved, inputCount: 6, tolerance: 1))
    }

    func testClearForgetsAGiveUp() {
        var ledger = IntegrationRetryLedger()
        ledger.record([window], bounds: [window: frame], inputCount: 1, tolerance: 1)
        ledger.record([window], bounds: [window: frame], inputCount: 1, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
        ledger.clear(window)
        XCTAssertFalse(ledger.gaveUp(window))
        XCTAssertTrue(ledger.isEmpty)
        ledger.record([window], bounds: [window: frame], inputCount: 3, tolerance: 1)
        ledger.record([window], bounds: [window: frame], inputCount: 3, tolerance: 1)
        XCTAssertTrue(ledger.gaveUp(window))
    }
}
