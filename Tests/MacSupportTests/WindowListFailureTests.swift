import AppKit
import ApplicationServices
import LayoutCore
import Operations
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

/// An app's window list can leave out a window it shows: Finder, after running for days, answered its list empty while the window was among its children.
/// Only such windows send LazySpace to the children, and only they are taken from there.
final class UnlistedWindowTests: XCTestCase {
    let finder: pid_t = 100
    let other: pid_t = 200

    func record(_ id: CGWindowID, pid: pid_t = 100, layer: Int = 0, onScreen: Bool = true) -> CGWindowRecord {
        CGWindowRecord(id: id, pid: pid, layer: layer, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 1, onScreen: onScreen)
    }

    func unlisted(_ listed: Set<CGWindowID>, _ records: [CGWindowRecord], membership: [CGWindowID: ObservedWindow.Membership] = [:], ids: Set<WindowID>? = nil) -> Set<CGWindowID> {
        MacWindowSystem.unlistedWindows(listed: listed, pid: finder, windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), membership: membership, ids: ids)
    }

    func testAWindowShownOnTheCurrentSpaceButLeftOutOfTheListIsLookedFor() {
        XCTAssertEqual(unlisted([], [record(1)], membership: [1: .current]), [1], "an empty list")
        XCTAssertEqual(unlisted([1], [record(1), record(2)], membership: [1: .current, 2: .current]), [2], "a list missing one window")
        XCTAssertEqual(unlisted([], [record(1)], membership: [1: .allSpaces]), [1], "on all Spaces")
        XCTAssertEqual(unlisted([], [record(1)]), [1], "membership not read, on screen")
        XCTAssertEqual(unlisted([], [record(1)], membership: [1: .unknown]), [1], "SkyLight gave no Space, on screen")
    }

    func testNothingIsLookedForWhenTheListHasEveryShownWindow() {
        XCTAssertEqual(unlisted([1, 2], [record(1), record(2)], membership: [1: .current, 2: .current]), [])
        XCTAssertEqual(unlisted([], []), [], "no windows at all")
    }

    func testWindowsTheListRightlyLeavesOutAreNotLookedFor() {
        // Off screen: an app keeping a closed window ordered out on its Space.
        XCTAssertEqual(unlisted([], [record(1, onScreen: false)], membership: [1: .current]), [])
        XCTAssertEqual(unlisted([], [record(1)], membership: [1: .other]), [], "on another Space")
        XCTAssertEqual(unlisted([], [record(1)], membership: [1: .otherDisplay]), [], "on a display without the menu bar while displays share one Space")
        XCTAssertEqual(unlisted([], [record(1, layer: 3)], membership: [1: .current]), [], "a floating layer")
        XCTAssertEqual(unlisted([], [record(1, pid: other)], membership: [1: .current]), [], "another app's window")
    }

    func testOnlyRequestedWindowsAreLookedFor() {
        XCTAssertEqual(unlisted([], [record(1), record(2)], membership: [1: .current, 2: .current], ids: [WindowID(2)]), [2])
    }

    func testOnlyChildrenWithAMissingWindowIDAreObservedOnceEach() {
        // Finder's children: the window, its menu bar, and the desktop's scroll area, which have no window ID (-25201).
        let noWindow = Result<CGWindowID, AXFailure>.failure(.other(-25201))
        var remaining: Set<CGWindowID> = [7]
        XCTAssertEqual(MacWindowSystem.childStep(noWindow, remaining: &remaining), .skip)
        XCTAssertEqual(MacWindowSystem.childStep(.success(5), remaining: &remaining), .skip, "a window the list already has")
        XCTAssertEqual(MacWindowSystem.childStep(.success(7), remaining: &remaining), .observe(7))
        XCTAssertEqual(remaining, [], "found, so the scan can stop")
        XCTAssertEqual(MacWindowSystem.childStep(.success(7), remaining: &remaining), .skip, "the same window twice is observed once")
    }

    func testAWindowIDLookupThatRunsOutOfTimeLeavesTheAppUnobserved() {
        // Taken as "not a window", the missing window would drop out of a complete observation and could leave the saved layout.
        var remaining: Set<CGWindowID> = [7]
        XCTAssertEqual(MacWindowSystem.childStep(.failure(.cannotComplete), remaining: &remaining), .unobserved)
        XCTAssertEqual(remaining, [7])
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
