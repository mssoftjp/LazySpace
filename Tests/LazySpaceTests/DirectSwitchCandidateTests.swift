import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

private struct Listing: SpaceListing {
    var order: [UInt64]
    var active: () -> UInt64?
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
}

/// Direct-switch candidates (app eligibility, order, candidate table) and `space back` after one jump plus stepping.
final class DirectSwitchCandidateTests: XCTestCase {
    // MARK: - App eligibility (raw window list)

    private typealias Inventory = AppWindowInventory

    private static let me: pid_t = 99

    private func inventory(_ windows: [(CGWindowID, pid_t, [UInt64])], apps: [Inventory.App], visible: Set<UInt64> = [1, 21],
                           offScreen: Set<CGWindowID> = [], orderedOut: Set<CGWindowID> = []) -> Inventory {
        Inventory(selfPID: Self.me, visibleSpaces: visible, apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) }),
                  windows: windows.map { Inventory.Window(id: $0.0, pid: $0.1, onScreen: !offScreen.contains($0.0), spaces: $0.2,
                                                          orderedIn: !orderedOut.contains($0.0)) })
    }

    private func app(_ pid: pid_t, _ bundleID: String? = nil, regular: Bool = true, hidden: Bool = false) -> Inventory.App {
        Inventory.App(pid: pid, bundleID: bundleID ?? "com.example.\(pid)", regular: regular, hidden: hidden)
    }

    /// Current Space 1, target 3. The other display's Spaces are 21 and 22 (21 shown).
    func testOnlyAppsWithEveryWindowExactlyOnTheTargetAreEligible() {
        let inv = inventory([
            (10, 10, [3]), (11, 10, [3]), // target only (2 windows)
            (20, 20, [3]), (21, 20, [1]), // also on the current Space
            (30, 30, [3]), (31, 30, [1, 2, 3]), // has a window on all Spaces
            (40, 40, [3]), (41, 40, [2]), // spread over several Spaces
            (50, 50, []), // only unknown membership (off screen, so ignored; no target window)
            (60, 60, [3]), (61, 60, []), // plus an on-screen window with unknown membership
            (70, 70, [3]),                    // hidden
            (80, 80, [3]), (81, 81, [3]), (82, 82, [3]), // Finder, Dock, ourselves
            (90, 90, [3]), // not regular
            (100, 100, [3]), (101, 100, [22]), // also on the other display's Space
            (110, 110, [2]), // another Space only
        ], apps: [app(10), app(20), app(30), app(40), app(50), app(60), app(70, hidden: true),
                  app(80, "com.apple.finder"), app(81, "com.apple.dock"), app(Self.me, "jp.lazyspace.app"),
                  app(90, regular: false), app(100), app(110)], offScreen: [10, 11, 20, 30, 31, 40, 41, 50, 70, 80, 81, 82, 90, 100, 101, 110])
        XCTAssertEqual(inv.eligibleApps(on: 3).map(\.pid), [10])
        XCTAssertEqual(inv.eligibleApps(on: 3).first?.bundleID, "com.example.10")
        XCTAssertEqual(inv.eligibleApps(on: 2).map(\.pid), [110])
        XCTAssertEqual(inv.eligibleApps(on: 22), [], "the app also has a window on Space 3")
    }

    /// Windows an app keeps ordered out (a closed settings window still listed on a Space, or a minimized window) never qualify an app:
    /// activating that app switches nothing. A closed settings window listed on an empty desktop once made its app the candidate,
    /// and the switch never happened. Elsewhere they still conflict, as any window on another Space does.
    func testOrderedOutWindowsAreIgnored() {
        let inv = inventory([(10, 10, [3]), (20, 20, [3]), (21, 20, [3]), (30, 30, [3]), (31, 30, [7])],
                            apps: [app(10), app(20), app(30)], offScreen: [10, 20, 21, 30, 31], orderedOut: [10, 21, 31])
        XCTAssertEqual(inv.exclusion(of: 10, on: 3), .noWindowOnTarget, "only an ordered-out window there")
        XCTAssertNil(inv.exclusion(of: 20, on: 3), "a real window there; the ordered-out one does not matter")
        XCTAssertEqual(inv.exclusion(of: 30, on: 3), .windowElsewhere(31, spaces: [7]), "a minimized window elsewhere reads ordered out too, and still conflicts")
        XCTAssertEqual(inv.eligibleApps(on: 3).map(\.pid), [20])
        let unknown = Inventory(selfPID: Self.me, visibleSpaces: [1], apps: [40: app(40)],
                                windows: [Inventory.Window(id: 40, pid: 40, onScreen: false, spaces: [3], orderedIn: nil)])
        XCTAssertEqual(unknown.eligibleApps(on: 3).map(\.pid), [40], "an unreadable order keeps the earlier judgment")
    }

    /// Off-screen windows with unknown membership are ignored as auxiliary; on-screen ones conflict (visible on the current Space).
    func testOffScreenUnknownWindowsAreIgnoredButVisibleOnesConflict() {
        let inv = inventory([(10, 10, [3]), (11, 10, []), (20, 20, [3]), (21, 20, [])], apps: [app(10), app(20)], offScreen: [10, 11, 20])
        XCTAssertEqual(inv.eligibleApps(on: 3).map(\.pid), [10])
        XCTAssertNil(inv.exclusion(of: 10, on: 3))
        XCTAssertEqual(inv.exclusion(of: 20, on: 3), .visibleUnknownWindow(21))
        let unknownOnly = inventory([(10, 10, [])], apps: [app(10)], offScreen: [10])
        XCTAssertEqual(unknownOnly.exclusion(of: 10, on: 3), .noWindowOnTarget)
    }

    /// The shape of a raw window list from a real session.
    /// Every app has off-screen strips, small windows, and 1x1 windows of unknown membership; real windows are on one Space. Current Space is 7 (the terminal).
    func testRealInventoryShapesQualifyForTheirSpace() {
        let browser: pid_t = 101, viewer: pid_t = 102, browser2: pid_t = 103, terminal: pid_t = 104, chat: pid_t = 105
        let rows: [(CGWindowID, pid_t, [UInt64])] = [
            (1001, browser, []), (1002, browser, []), (1003, browser, []), (1004, browser, []), (1005, browser, [6]), (1006, browser, [6]),
            (1007, browser, [6]), (1008, browser, []), (1009, browser, []),
            (1010, viewer, []), (1011, viewer, []), (1012, viewer, [50]), (1013, viewer, []), (1014, viewer, []), (1015, viewer, []),
            (1016, viewer, [50]), (1017, viewer, [50]), (1018, viewer, [50]), (1019, viewer, [50]), (1020, viewer, [50]), (1021, viewer, [50]),
            (1022, browser2, []), (1023, browser2, []), (1024, browser2, []), (1025, browser2, []), (1026, browser2, []), (1027, browser2, []),
            (1028, browser2, []), (1029, browser2, [8]), (1030, browser2, [8]),
            (1031, terminal, []), (1032, terminal, []), (1033, terminal, []), (1034, terminal, [7]), (1035, terminal, []),
            (1036, chat, []), (1037, chat, []), (1038, chat, []), (1039, chat, [36]), (1040, chat, []), (1041, chat, []),
        ]
        // All on=0 (off screen) in the list; only the terminal's window on the current Space is actually on screen.
        let inv = inventory(rows, apps: [app(browser, "com.example.browser"), app(viewer, "com.example.viewer"), app(browser2, "com.example.browser2"),
                                         app(terminal, "com.example.terminal"), app(chat, "com.example.chat")],
                            visible: [7], offScreen: Set(rows.map(\.0)).subtracting([1034]))
        XCTAssertEqual(inv.eligibleApps(on: 6).map(\.pid), [browser])
        XCTAssertEqual(inv.eligibleApps(on: 50).map(\.pid), [viewer])
        XCTAssertEqual(inv.eligibleApps(on: 8).map(\.pid), [browser2])
        XCTAssertEqual(inv.eligibleApps(on: 36).map(\.pid), [chat])
        XCTAssertEqual(inv.exclusion(of: terminal, on: 6), .windowElsewhere(1034, spaces: [7]))
        XCTAssertEqual(inv.exclusion(of: browser, on: 50), .windowElsewhere(1005, spaces: [6]))
    }

    func testAppsWithoutABundleIdentifierOrWindowsAreNotEligible() {
        let inv = inventory([(10, 10, [3])], apps: [Inventory.App(pid: 10, bundleID: nil, regular: true, hidden: false), app(20)])
        XCTAssertEqual(inv.eligibleApps(on: 3), [])
    }

    /// A window on a shown Space that is not on screen is known minimized; apps with only such windows are excluded.
    /// Windows on Spaces not shown cannot be told apart, so the post-send check decides.
    func testKnownMinimizedOnlyAppsAreNotEligible() {
        let shown = inventory([(10, 10, [21]), (20, 20, [21]), (21, 20, [21])], apps: [app(10), app(20)], offScreen: [10, 20])
        XCTAssertEqual(shown.eligibleApps(on: 21).map(\.pid), [20])
        let hiddenSpace = inventory([(10, 10, [3])], apps: [app(10)], offScreen: [10])
        XCTAssertEqual(hiddenSpace.eligibleApps(on: 3).map(\.pid), [10])
    }

    /// Recheck right before activation: if the pid's app has a different bundle ID (pid reuse), it is not eligible.
    func testRevalidationChecksTheBundleIdentifierAndTheCurrentWindows() {
        let inv = inventory([(10, 10, [3])], apps: [app(10)])
        XCTAssertTrue(inv.isEligible(pid: 10, bundleID: "com.example.10", on: 3))
        XCTAssertFalse(inv.isEligible(pid: 10, bundleID: "com.example.other", on: 3))
        XCTAssertFalse(inv.isEligible(pid: 11, bundleID: "com.example.11", on: 3))
        let moved = inventory([(10, 10, [3]), (12, 10, [1])], apps: [app(10)])
        XCTAssertFalse(moved.isEligible(pid: 10, bundleID: "com.example.10", on: 3), "a window opened on the current Space since the table was built")
    }

    // MARK: - Order

    func testWindowsComeFirstAndAppsFollowHistoryThenLayoutThenPID() {
        let apps = [Inventory.Candidate(pid: 30, bundleID: "c"), Inventory.Candidate(pid: 10, bundleID: "a"),
                    Inventory.Candidate(pid: 20, bundleID: "b"), Inventory.Candidate(pid: 40, bundleID: "d"),
                    Inventory.Candidate(pid: 30, bundleID: "c")]
        let owners: [CGWindowID: pid_t] = [1: 40, 2: 30, 3: 20, 7: 10]
        let recent = [WindowID(1), WindowID(2)], arranged = [WindowID(3), WindowID(1)]
        XCTAssertEqual(Coordinator.windowCandidates(recent: recent, arranged: arranged, seen: [WindowID(7), WindowID(5)]),
                       [.window(1), .window(2), .window(3), .window(5), .window(7)])
        XCTAssertEqual(Coordinator.appCandidates(recent: recent, arranged: arranged, apps: apps, owners: owners),
                       [.app(40, bundleID: "d"), .app(30, bundleID: "c"), .app(20, bundleID: "b"), .app(10, bundleID: "a")])
    }

    // MARK: - Coordinator

    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var overview: SpaceOverview?
    private var inventoryFixture: AppWindowInventory?
    private var inventoryReads = 0

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { self.overview }, takeInventory: { self.inventoryReads += 1; return self.inventoryFixture })
        coordinator.spaceListingOverride = Listing(order: [7, 8, 9, 10], active: { self.system.space })
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private struct Call { var dest: UInt64; var plan: SpaceControl.SwitchPlan }

    /// Replaces the switch, records the calls, and pretends to arrive on the target Space.
    private func recordSwitches() -> () -> [Call] {
        var calls: [Call] = []
        coordinator.spaceSwitcherOverride = { dest, plan, _ in
            calls.append(Call(dest: dest, plan: plan))
            let from = self.system.space ?? 0
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: from, toSpace: dest, steps: 1, wallMs: 1))
        }
        return { calls }
    }

    func testCandidateTableCoversTheTargetAndTheSpacesInBetween() {
        make()
        overview = SpaceOverview(spaces: [.init(spaceID: 10, type: 0, isCurrent: false, windowIDs: [WindowID(101)])], unknown: [], reordersByRecentUse: false)
        inventoryFixture = AppWindowInventory(selfPID: 1, visibleSpaces: [7], apps: [50: .init(pid: 50, bundleID: "com.example.50", regular: true, hidden: false)],
                                              windows: [.init(id: 90, pid: 50, onScreen: false, spaces: [9])])
        let calls = recordSwitches()
        guard case .started = coordinator.edit(.space(.index(4)), source: "test") else { return XCTFail("switch refused") }
        drain()
        guard let call = calls().first else { return XCTFail("switcher not called") }
        XCTAssertEqual(call.dest, 10)
        XCTAssertEqual(call.plan.source, 7, "the authorized source")
        XCTAssertEqual(Set(call.plan.windows.keys), [8, 9, 10])
        XCTAssertEqual(call.plan.windows[10], [.window(101)])
        XCTAssertEqual(call.plan.windows[9], [])
        XCTAssertTrue(call.plan.hopAllowed)
        XCTAssertEqual(inventoryReads, 0, "the app inventory is read only when SpaceControl asks for it")
        let apps = call.plan.apps()
        XCTAssertEqual(inventoryReads, 1)
        XCTAssertEqual(Set(apps.keys), [8, 9, 10])
        XCTAssertEqual(apps[9], [.app(50, bundleID: "com.example.50")])
        XCTAssertEqual(apps[8], [])
    }

    /// With rearranging on, or an unreadable overview, one jump plus stepping is not allowed.
    func testHopIsNotAllowedWhenSpacesReorderOrTheOverviewIsMissing() {
        make()
        let calls = recordSwitches()
        overview = SpaceOverview(spaces: [], unknown: [], reordersByRecentUse: true)
        _ = coordinator.edit(.space(.index(3)), source: "test")
        drain()
        overview = nil
        _ = coordinator.edit(.space(.index(1)), source: "test")
        drain()
        XCTAssertEqual(calls().map(\.plan.hopAllowed), [false, false])
    }

    /// After arriving by one jump plus stepping, `space back` returns to the original Space, not the one passed through.
    func testSpaceBackReturnsToTheOriginalSourceAfterAHop() {
        make()
        overview = SpaceOverview(spaces: [], unknown: [], reordersByRecentUse: false)
        coordinator.spaceSwitcherOverride = { dest, _, _ in
            // Result of 7 -> 9 (passing) -> 10 in one operation.
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 1, wallMs: 1))
        }
        _ = coordinator.edit(.space(.index(4)), source: "test")
        drain()
        XCTAssertEqual(system.space, 10)
        coordinator.operationsQueue.sync { coordinator.tick() }
        let calls = recordSwitches()
        guard case .started = coordinator.edit(.space(.back), source: "test") else { return XCTFail("space back refused") }
        drain()
        XCTAssertEqual(calls().map(\.dest), [7])
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
    }

    /// If two switches 7 -> 8 -> 9 finish between a tick that saw 7 and the next, `space back` returns to 8 (not overwritten by the stale Space).
    func testTwoSwitchesBetweenTicksKeepTheLatestBackTarget() {
        make()
        coordinator.operationsQueue.sync { coordinator.tick() }
        let calls = recordSwitches()
        _ = coordinator.edit(.space(.index(2)), source: "test")
        drain()
        _ = coordinator.edit(.space(.index(3)), source: "test")
        drain()
        XCTAssertEqual(system.space, 9)
        coordinator.operationsQueue.sync { coordinator.tick() }
        guard case .started = coordinator.edit(.space(.back), source: "test") else { return XCTFail("space back refused") }
        drain()
        XCTAssertEqual(calls().map(\.dest), [8, 9, 8])
    }

    func testFailedSwitchDoesNotChangeTheBackTarget() {
        make()
        coordinator.spaceSwitcherOverride = { _, _, _ in
            self.system.space = 9
            return .failure(.routeChanged)
        }
        _ = coordinator.edit(.space(.index(4)), source: "test")
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .notPossible)
        XCTAssertTrue(coordinator.lastResult?.message.contains("order of Spaces") == true || coordinator.lastResult?.message.contains("並び") == true)
        let calls = recordSwitches()
        guard case .refused = coordinator.edit(.space(.back), source: "test") else { return XCTFail("no previous Space is recorded by a failed switch") }
        XCTAssertTrue(calls().isEmpty)
    }
}
