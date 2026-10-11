import AppKit
import ApplicationServices
import XCTest
@testable import MacSupport

/// When an app returns no window list, tells "it has no windows" apart from "it could not be read",
/// so windows of an unreadable app are not dropped from the layout as closed.
final class WindowListFailureTests: XCTestCase {
    func testOnlyAnswersThatMeanNoWindowsCountAsObserved() {
        for listed in [true, false] {
            XCTAssertTrue(MacWindowSystem.windowListUnobserved(.cannotComplete, listedBefore: listed, failuresWithoutList: 3))
            XCTAssertTrue(MacWindowSystem.windowListUnobserved(.apiDisabled, listedBefore: listed, failuresWithoutList: 3))
            XCTAssertFalse(MacWindowSystem.windowListUnobserved(.invalidElement, listedBefore: listed, failuresWithoutList: 3), "the app has quit")
            XCTAssertFalse(MacWindowSystem.windowListUnobserved(.attributeUnsupported, listedBefore: listed, failuresWithoutList: 3))
            XCTAssertFalse(MacWindowSystem.windowListUnobserved(.notImplemented, listedBefore: listed, failuresWithoutList: 3))
            XCTAssertFalse(MacWindowSystem.windowListUnobserved(.other(AXError.noValue.rawValue), listedBefore: listed, failuresWithoutList: 3))
        }
        // A failure from an app that has returned a list before, or that has failed only a few times, is unknown (not dropped right after a restart).
        // An app that keeps failing without ever returning a list has no list (it does not stop arranging other windows).
        let failure = AXFailure.other(AXError.failure.rawValue)
        XCTAssertTrue(MacWindowSystem.windowListUnobserved(failure, listedBefore: true, failuresWithoutList: 0))
        XCTAssertTrue(MacWindowSystem.windowListUnobserved(failure, listedBefore: false, failuresWithoutList: 1))
        XCTAssertTrue(MacWindowSystem.windowListUnobserved(failure, listedBefore: false, failuresWithoutList: 2))
        XCTAssertFalse(MacWindowSystem.windowListUnobserved(failure, listedBefore: false, failuresWithoutList: 3))
    }
}

/// The single-window read returns the same record as the full list for a listed window, and nothing for an unlisted ID.
final class SingleWindowRecordTests: XCTestCase {
    func testSingleWindowReadMatchesTheFullList() throws {
        // A window of this test (invisible and click-through), so the record cannot vanish between the reads.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        guard let all = WindowList.allIfAvailable() else { throw XCTSkip("the window list is unavailable in this session") }
        let listed = try XCTUnwrap(all[CGWindowID(window.windowNumber)], "the test's own window is listed")
        XCTAssertEqual(WindowList.record(listed.id)?.id, listed.id)
        XCTAssertEqual(WindowList.record(listed.id)?.layer, listed.layer)
        XCTAssertNil(WindowList.record(CGWindowID.max - 1))
    }
}

/// The operation record (environment) can be captured while the main thread is busy with other work.
final class EnvironmentCaptureTests: XCTestCase {
    func testCaptureOffTheMainThreadDoesNotWaitForTheMainThread() {
        let record = DispatchQueue.global().sync { EnvironmentRecord.capture() }
        XCTAssertFalse(record.cpu.isEmpty)
    }
}
