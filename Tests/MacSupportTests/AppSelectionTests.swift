import XCTest
@testable import MacSupport
import LayoutCore

final class AppSelectionTests: XCTestCase {
    /// A regular app missing from the running-apps list is still asked if it owns a normal-layer window (for example, Xcode's Device Hub).
    /// Non-regular apps and LazySpace itself are never asked, even if listed or owning windows.
    func testWindowOwnersMissingFromTheRunningAppsListAreAsked() {
        var looked: [pid_t] = []
        let pids = MacWindowSystem.appsToAsk(
            listed: [(pid: 10, regular: true), (pid: 11, regular: false), (pid: 99, regular: true), (pid: 10, regular: true), (pid: -1, regular: true)],
            windowOwners: [10, 11, 20, 21, 99], me: 99,
            isRegular: { looked.append($0); return $0 == 20 })
        XCTAssertEqual(pids, [10, 20], "an entry reported with pid -1 is never asked")
        XCTAssertEqual(looked, [11, 20, 21], "listed apps are not looked up again; LazySpace itself is never asked")
    }

    /// With Space membership available, the running-apps list is not read: window owners are looked up by their own pid.
    /// Without it (no Space observation or no current Space), the snapshot starts from the running-apps list as before.
    func testWindowOwnersAloneAreAskedWhenMembershipCanNarrowThem() {
        var reads = 0
        let read = { () -> [Int] in reads += 1; return [1, 2] }
        XCTAssertEqual(MacWindowSystem.runningAppsToStartFrom(membershipAvailable: true, read: read), [])
        XCTAssertEqual(reads, 0, "reading every running app's properties is costly on every snapshot")
        XCTAssertEqual(MacWindowSystem.runningAppsToStartFrom(membershipAvailable: false, read: read), [1, 2])
        XCTAssertEqual(reads, 1)
        var looked: [pid_t] = []
        let pids = MacWindowSystem.appsToAsk(listed: [], windowOwners: [21, 10, 99, 20], me: 99,
                                             isRegular: { looked.append($0); return $0 != 21 })
        XCTAssertEqual(pids, [10, 20], "regular owners in pid order; LazySpace itself is never asked")
        XCTAssertEqual(looked, [10, 20, 21])
    }

    /// When the front app's pid is reported as -1, use the pid of the single on-screen window owner with the same bundle identifier.
    /// Accessibility is not asked. Otherwise unknown.
    func testFrontmostPIDFallsBackToTheSingleWindowOwnerWithTheSameBundle() {
        let bundles: [pid_t: String] = [300: "com.example.devices", 500: "com.example.helper", 600: "com.example.helper"]
        let bundleOf = { (pid: pid_t) in bundles[pid] }
        XCTAssertEqual(FrontmostApp.resolve(-1, bundleID: { "com.example.devices" }, owners: { [300, 500] }, bundleOf: bundleOf), 300)
        XCTAssertNil(FrontmostApp.resolve(-1, bundleID: { "com.example.helper" }, owners: { [500, 600] }, bundleOf: bundleOf), "two candidates")
        XCTAssertNil(FrontmostApp.resolve(-1, bundleID: { "com.example.devices" }, owners: { [500] }, bundleOf: bundleOf), "no window on screen")
        XCTAssertNil(FrontmostApp.resolve(-1, bundleID: { nil }, owners: { [300] }, bundleOf: bundleOf))
    }

    /// A positive reported pid reads neither the bundle identifier (a LaunchServices query) nor window owners. This runs on every observation.
    func testReportedPIDIsUsedWithoutAskingForTheBundleIdentifier() {
        XCTAssertEqual(FrontmostApp.resolve(42, bundleID: { XCTFail("bundle identifier not needed"); return "x" },
                                            owners: { XCTFail("owners not needed"); return [] },
                                            bundleOf: { _ in XCTFail("not needed"); return nil }), 42)
    }

    /// Regular apps get only `activate()`. An app reported with pid -1 also gets `AXFrontmost` set through its window owner's pid.
    func testActivationAlsoSetsFrontmostByPIDWhenTheRecordIsBroken() {
        var calls: [String] = []
        func run(reported: pid_t, allowed: @escaping () -> Bool = { true }, owner: Bool = true) {
            AppActivation.activate(reportedPID: reported, pid: 30636, allowed: allowed, stillOwner: { owner },
                                   activateApp: { calls.append("activate"); return true }, setFrontmost: { calls.append("frontmost \($0)") })
        }
        run(reported: 42)
        XCTAssertEqual(calls, ["activate"])
        calls = []
        run(reported: -1)
        XCTAssertEqual(calls, ["activate", "frontmost 30636"])
    }

    /// The gate is checked per request: if it closes during `activate()`, or the owner changed (pid reuse), `AXFrontmost` is not set.
    func testActivationRechecksTheGateAndOwnerBeforeTheFallback() {
        var calls: [String] = []
        var open = true
        AppActivation.activate(reportedPID: -1, pid: 30636, allowed: { open }, stillOwner: { true },
                               activateApp: { calls.append("activate"); open = false; return true }, setFrontmost: { calls.append("frontmost \($0)") })
        XCTAssertEqual(calls, ["activate"], "the gate closed during activate()")
        calls = []
        AppActivation.activate(reportedPID: -1, pid: 30636, allowed: { true }, stillOwner: { false },
                               activateApp: { calls.append("activate"); return true }, setFrontmost: { calls.append("frontmost \($0)") })
        XCTAssertEqual(calls, ["activate"], "the pid no longer owns the window")
        calls = []
        open = true
        AppActivation.activate(reportedPID: -1, pid: 30636, allowed: { open }, stillOwner: { open = false; return true },
                               activateApp: { calls.append("activate"); return true }, setFrontmost: { calls.append("frontmost \($0)") })
        XCTAssertEqual(calls, ["activate"], "the gate closed during the ownership check")
        calls = []
        AppActivation.activate(reportedPID: -1, pid: 30636, allowed: { false }, stillOwner: { true },
                               activateApp: { calls.append("activate"); return true }, setFrontmost: { calls.append("frontmost \($0)") })
        XCTAssertEqual(calls, [], "nothing is requested when the gate is closed")
    }

    /// AX elements of closed windows are not kept. Only windows missing from the all-windows list are dropped (windows on other Spaces are listed and stay).
    func testClosedWindowsAreEvictedFromTheCache() {
        let cached: Set<WindowID> = [WindowID(1), WindowID(2), WindowID(3)]
        XCTAssertEqual(MacWindowSystem.closedCacheEntries(cached, allWindows: [1, 3, 9]), [WindowID(2)])
        XCTAssertEqual(MacWindowSystem.closedCacheEntries(cached, allWindows: nil), [], "an unreadable list evicts nothing")
    }
}
