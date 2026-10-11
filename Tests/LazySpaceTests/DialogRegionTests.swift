import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

/// Region calculation and the planner's reservation (the pure parts).
final class DialogRegionPlannerTests: XCTestCase {
    private let area = CGRect(x: 0, y: 25, width: 2000, height: 1000)
    private let start = Date(timeIntervalSince1970: 100)

    private func arrival(_ id: UInt32, _ w: CGFloat, _ h: CGFloat) -> DialogRegionPlanner.Arrival {
        DialogRegionPlanner.Arrival(id: WindowID(id), pid: Int32(id) + 100, processStart: start, size: CGSize(width: w, height: h))
    }

    private func plan(_ previous: DialogRegion?, _ arrivals: [DialogRegionPlanner.Arrival], departed: Set<WindowID> = [], sizes: [WindowID: CGSize] = [:],
                      pinned: Set<WindowID> = [], area: CGRect? = nil, gap: Double = 10, gapVertical: Double = 10,
                      tileMinimum: CGSize = .zero, allowBottom: Bool = false, rememberedEdge: DialogRegion.Edge? = nil,
                      allowSwitch: Bool = true) -> DialogRegionPlanner.Result {
        DialogRegionPlanner.plan(DialogRegionPlanner.Input(previous: previous, arrivals: arrivals, departed: departed, sizes: sizes, pinned: pinned,
                                                           area: area ?? self.area, gap: gap, gapVertical: gapVertical, tileMinimum: tileMinimum,
                                                           allowBottom: allowBottom, rememberedEdge: rememberedEdge, allowSwitch: allowSwitch))
    }

    /// An empty region (edge only), used to check bottom packing.
    private func empty(_ edge: DialogRegion.Edge, area: CGRect, tileMinimum: CGSize = .zero) -> DialogRegion {
        DialogRegion(edge: edge, area: DialogRegionPlanner.wholeArea(area), tileMinimum: tileMinimum, thickness: 0, members: [])
    }

    /// Stacked from the top in arrival order, aligned to the right edge. Arrivals alone never move earlier positions.
    func testArrivalsStackAndKeepEarlierPositions() {
        let region = try! XCTUnwrap(plan(nil, [arrival(5, 300, 400)]).region)
        XCTAssertEqual(region.thickness, 300)
        XCTAssertEqual(region.edge, .right)
        XCTAssertEqual(region.members.map(\.origin), [CGPoint(x: 1700, y: 25)])
        let next = try! XCTUnwrap(plan(region, [arrival(6, 500, 200)]).region)
        XCTAssertEqual(next.thickness, 500, "the widest dialog decides the width")
        XCTAssertEqual(next.members.first?.origin, CGPoint(x: 1700, y: 25), "an earlier dialog does not move")
        XCTAssertEqual(next.members.last?.origin, CGPoint(x: 1500, y: 435))
        XCTAssertEqual(next.reservation(gap: 10, gapVertical: 10).right, 510)
        XCTAssertEqual(next.reservation(gap: 10, gapVertical: 10).bottom, 0)
    }

    /// Departures close up, unless that would move the front member (then deferred, arrivals included).
    func testDepartureClosesUpUnlessAPinnedMemberWouldMove() {
        let region = plan(nil, [arrival(5, 300, 400), arrival(6, 300, 300)]).region!
        let closed = plan(region, [], departed: [WindowID(5)])
        XCTAssertEqual(closed.region?.members.map(\.origin), [CGPoint(x: 1700, y: 25)])
        let deferred = plan(region, [arrival(7, 100, 100)], departed: [WindowID(5)], pinned: [WindowID(6)])
        XCTAssertTrue(deferred.deferred)
        XCTAssertEqual(deferred.region?.members.map(\.origin), [CGPoint(x: 1700, y: 435)], "the front dialog stays where it is")
        XCTAssertEqual(deferred.pending, [WindowID(7)], "arrivals wait while the repack is deferred")
        XCTAssertEqual(deferred.region?.thickness, 300)
        let last = plan(closed.region, [], departed: [WindowID(6)])
        XCTAssertNil(last.region, "the strip disappears with its last dialog")
    }

    /// If the area changes while a member is pinned, the region is dropped.
    func testAnAreaChangeWhileAMemberIsPinnedDropsTheRegion() {
        let region = plan(nil, [arrival(5, 300, 400)]).region!
        let smaller = CGRect(x: 0, y: 25, width: 1800, height: 1000)
        let pinned = plan(region, [], pinned: [WindowID(5)], area: smaller)
        XCTAssertNil(pinned.region)
        XCTAssertTrue(pinned.deferred)
        let free = plan(region, [], area: smaller)
        XCTAssertEqual(free.region?.members.map(\.origin), [CGPoint(x: 1500, y: 25)], "without pins the region follows the new area")
    }

    /// A window that cannot fit alone is skipped and smaller later ones still enter; what does not fit in total is pending.
    func testInadmissibleAndPending() {
        let result = plan(nil, [arrival(5, 1200, 300), arrival(6, 200, 1200), arrival(7, 1000, 600), arrival(8, 1000, 600)])
        XCTAssertEqual(result.inadmissible, [WindowID(5), WindowID(6)], "too wide, too tall")
        XCTAssertEqual(result.region?.members.map(\.id), [WindowID(7)])
        XCTAssertEqual(result.pending, [WindowID(8)])
        XCTAssertEqual(DialogRegionPlanner.limit(edge: .right, area: area, tileMinimum: CGSize(width: 400, height: 0), gap: 10, gapVertical: 10), 1000)
        XCTAssertEqual(DialogRegionPlanner.limit(edge: .right, area: area, tileMinimum: CGSize(width: 1500, height: 0), gap: 10, gapVertical: 10), 490)
        XCTAssertEqual(DialogRegionPlanner.limit(edge: .bottom, area: area, tileMinimum: CGSize(width: 0, height: 600), gap: 10, gapVertical: 10), 390)
        let capped = plan(nil, (1...9).map { arrival(UInt32(10 + $0), 50, 50) })
        XCTAssertEqual(capped.region?.members.count, DialogRegionPlanner.maxMembers)
        XCTAssertEqual(capped.pending, [WindowID(19)])
    }

    /// Narrow windows line up under a wide one and spill into the next column when they do not fit.
    func testNarrowDialogsFillTheSpaceUnderAWideOne() {
        let area = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let packed = plan(nil, [arrival(1, 700, 300), arrival(2, 230, 408), arrival(3, 230, 408), arrival(4, 230, 200)], area: area, gap: 8, gapVertical: 8)
        XCTAssertEqual(packed.region?.members.map(\.origin), [CGPoint(x: 1300, y: 0), CGPoint(x: 1770, y: 308), CGPoint(x: 1532, y: 308), CGPoint(x: 1770, y: 724)])
        XCTAssertEqual(packed.region?.thickness, 700)
        let calculators = plan(nil, [arrival(1, 230, 408), arrival(2, 230, 408), arrival(3, 230, 408)], area: area, gap: 8, gapVertical: 8)
        XCTAssertEqual(calculators.region?.members.map(\.origin), [CGPoint(x: 1770, y: 0), CGPoint(x: 1770, y: 416), CGPoint(x: 1532, y: 0)])
        XCTAssertEqual(calculators.region?.thickness, 468, "a third one opens a second column instead of waiting")
        // Bottom: lined up from the left along the bottom.
        let bottom = plan(empty(.bottom, area: area), [arrival(1, 300, 200), arrival(2, 300, 100)], area: area, gap: 8, gapVertical: 8)
        XCTAssertEqual(bottom.region?.edge, .bottom)
        XCTAssertEqual(bottom.region?.members.map(\.origin), [CGPoint(x: 0, y: 800), CGPoint(x: 308, y: 900)])
        XCTAssertEqual(bottom.region?.reservation(gap: 8, gapVertical: 8).bottom, 208)
    }

    /// On the same edge: appending never moves earlier positions; removing or resizing the k-th never moves those before it.
    func testPrefixStabilityOnBothEdges() {
        let area = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let sizes: [(CGFloat, CGFloat)] = [(420, 300), (230, 408), (180, 200), (500, 120), (230, 408), (90, 90), (300, 250), (150, 400)]
        let all = sizes.enumerated().map { arrival(UInt32($0.offset + 1), $0.element.0, $0.element.1) }
        for edge in [DialogRegion.Edge.right, .bottom] {
            let full = plan(empty(edge, area: area), all, area: area).region!.members
            for k in 1..<all.count {
                let prefix = plan(empty(edge, area: area), Array(all.prefix(k)), area: area).region!.members
                XCTAssertEqual(prefix, Array(full.prefix(prefix.count)), "\(edge) append k=\(k)")
                var without = all; without.remove(at: k)
                let removed = plan(empty(edge, area: area), without, area: area).region!.members
                XCTAssertEqual(Array(removed.prefix(k)), Array(full.prefix(k)), "\(edge) remove k=\(k)")
                var resized = all; resized[k].size = CGSize(width: 60, height: 60)
                let changed = plan(empty(edge, area: area), resized, area: area).region!.members
                XCTAssertEqual(Array(changed.prefix(k)), Array(full.prefix(k)), "\(edge) resize k=\(k)")
            }
        }
    }

    /// Even with fractional sizes, gaps, and areas, written positions are integers and gaps are kept.
    func testFractionalInputsGiveWholePointFrames() {
        let area = CGRect(x: 0.5, y: 24.6, width: 1999.2, height: 1000.7)
        let members = plan(nil, [arrival(1, 300.2, 100.4), arrival(2, 299.6, 100.4), arrival(3, 120.3, 880)], area: area, gap: 7.5, gapVertical: 7.5).region!.members
        for m in members {
            XCTAssertEqual(m.origin.x, m.origin.x.rounded())
            XCTAssertEqual(m.origin.y, m.origin.y.rounded())
            XCTAssertLessThanOrEqual(m.frame.maxX, area.maxX)
            XCTAssertGreaterThanOrEqual(m.origin.y, area.minY)
        }
        XCTAssertGreaterThanOrEqual(members[1].origin.y - members[0].frame.maxY, 7.5)
    }

    /// Edge: right edge from empty; no switch for a difference under 0.10; bottom for a portrait area.
    func testEdgeChoiceByShare() {
        XCTAssertEqual(plan(nil, [arrival(1, 230, 408)], allowBottom: true).region?.edge, .right)
        let tall = CGRect(x: 0, y: 0, width: 1000, height: 2000)
        XCTAssertEqual(plan(nil, [arrival(1, 300, 200)], area: tall, allowBottom: true).region?.edge, .bottom)
        XCTAssertEqual(plan(nil, [arrival(1, 300, 280)], area: CGRect(x: 0, y: 0, width: 1000, height: 1250), allowBottom: true).region?.edge, .right,
                       "a difference under 0.10 keeps the right edge")
    }

    /// Edge: switch if more windows fit; not if a current window would drop out; not while an unmovable window is present.
    func testEdgeChoiceByCount() {
        let area = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let minimum = CGSize(width: 1500, height: 0)
        let right = plan(nil, [arrival(1, 400, 400)], area: area, tileMinimum: minimum, allowBottom: true).region!
        XCTAssertEqual(right.edge, .right)
        let switched = plan(right, [arrival(2, 600, 200)], area: area, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(switched.region?.edge, .bottom)
        XCTAssertTrue(switched.switched)
        XCTAssertEqual(switched.region?.members.map(\.id), [WindowID(1), WindowID(2)])
        let held = plan(right, [arrival(2, 600, 200)], pinned: [WindowID(1)], area: area, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(held.region?.edge, .right)
        XCTAssertTrue(held.deferred)
        let tallFirst = plan(nil, [arrival(1, 300, 600)], area: area, tileMinimum: minimum, allowBottom: true).region!
        XCTAssertEqual(plan(tallFirst, [arrival(2, 600, 200)], area: area, tileMinimum: minimum, allowBottom: true).region?.edge, .right,
                       "a member that would not fit at the bottom keeps the right edge")
        // Right after a switch, the same input does not switch back.
        let again = plan(switched.region, [], area: area, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(again.region?.edge, .bottom)
        XCTAssertFalse(again.switched)
    }

    /// Size changes alone never switch the edge; a 1 pt change at the fitting threshold switches at most once.
    func testSizeChangesAloneNeverSwitch() {
        let area = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let minimum = CGSize(width: 1500, height: 100)
        let start = plan(nil, [arrival(1, 200, 400), arrival(2, 500, 200)], area: area, gap: 0, gapVertical: 0, tileMinimum: minimum, allowBottom: true).region!
        XCTAssertEqual(start.edge, .right)
        let grown = plan(start, [], sizes: [WindowID(2): CGSize(width: 501, height: 200)], area: area, gap: 0, gapVertical: 0, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(grown.region?.edge, .right, "a size change alone does not switch")
        XCTAssertEqual(grown.inadmissible, [WindowID(2)])
        let back = plan(grown.region, [arrival(2, 501, 200)], area: area, gap: 0, gapVertical: 0, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(back.region?.edge, .bottom, "it re-enters as an arrival, which may switch")
        let shrunk = plan(back.region, [], sizes: [WindowID(2): CGSize(width: 500, height: 200)], area: area, gap: 0, gapVertical: 0, tileMinimum: minimum, allowBottom: true)
        XCTAssertEqual(shrunk.region?.edge, .bottom, "and does not switch back on a size change")
    }

    /// A blocked switch to the better edge is carried over and made once allowed; not right after a switch.
    func testABlockedSwitchIsOwedUntilAllowed() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let a = plan(nil, [arrival(1, 100, 300)], area: area, gap: 0, gapVertical: 0, allowBottom: true).region!
        XCTAssertEqual(a.edge, .right)
        let blocked = plan(a, [arrival(2, 500, 100)], pinned: [WindowID(1)], area: area, gap: 0, gapVertical: 0, allowBottom: true)
        XCTAssertEqual(blocked.region?.edge, .right)
        XCTAssertEqual(blocked.region?.members.map(\.id), [WindowID(1), WindowID(2)], "the arrival still enters on the current edge")
        XCTAssertEqual(blocked.region?.edgeReview, true)
        let freed = plan(blocked.region, [], area: area, gap: 0, gapVertical: 0, allowBottom: true)
        XCTAssertEqual(freed.region?.edge, .bottom)
        XCTAssertEqual(freed.region?.edgeReview, false)
        let limited = plan(blocked.region, [], area: area, gap: 0, gapVertical: 0, allowBottom: true, allowSwitch: false)
        XCTAssertEqual(limited.region?.edge, .right)
        XCTAssertEqual(limited.region?.edgeReview, true)
        // After the region empties, it starts from the remembered edge.
        XCTAssertEqual(plan(nil, [arrival(3, 100, 100)], area: area, allowBottom: true, rememberedEdge: .bottom, allowSwitch: false).region?.edge, .bottom)
    }

    /// An owed review survives a temporary size change while switching is blocked.
    func testAnOwedReviewSurvivesATemporarySizeChange() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let a = plan(nil, [arrival(1, 100, 300)], area: area, gap: 0, gapVertical: 0, allowBottom: true).region!
        let owed = plan(a, [arrival(2, 500, 100)], pinned: [WindowID(1)], area: area, gap: 0, gapVertical: 0, allowBottom: true).region!
        XCTAssertTrue(owed.edgeReview)
        let shrunk = plan(owed, [], sizes: [WindowID(2): CGSize(width: 100, height: 100)], pinned: [WindowID(1)], area: area, gap: 0, gapVertical: 0, allowBottom: true).region!
        XCTAssertTrue(shrunk.edgeReview, "still owed while the switch is blocked")
        let restored = plan(shrunk, [], sizes: [WindowID(2): CGSize(width: 500, height: 100)], area: area, gap: 0, gapVertical: 0, allowBottom: true)
        XCTAssertEqual(restored.region?.edge, .bottom, "evaluated once unblocked")
    }

    /// Even with fractional areas and gaps, exactly the rounded-up gap separates tiles from the strip (both edges).
    func testTheTileToStripGapSurvivesRounding() {
        let work = CGRect(x: 0, y: 0, width: 1000.9, height: 800.7)
        for edge in [DialogRegion.Edge.right, .bottom] {
            let region = plan(empty(edge, area: work), [arrival(1, 100, 100)], area: work, gap: 7.5, gapVertical: 7.5).region!
            var options = PlannerOptions()
            let reservation = region.reservation(gap: 7.5, gapVertical: 7.5)
            options.reservedRight = reservation.right
            options.reservedBottom = reservation.bottom
            let tiles = options.tilingArea(work)
            let dialog = region.members[0].frame
            if edge == .right { XCTAssertEqual(dialog.minX - tiles.maxX, 8, accuracy: 0.001) }
            else { XCTAssertEqual(dialog.minY - tiles.maxY, 8, accuracy: 0.001) }
        }
    }

    /// If the limit shrinks while a member is pinned and the current strip no longer fits, the region is dropped.
    func testAFrozenStripThatNoLongerFitsIsDropped() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let region = plan(nil, [arrival(1, 400, 100), arrival(2, 200, 100)], area: area, gap: 0, gapVertical: 0).region!
        let shrunk = plan(region, [], pinned: [WindowID(2)], area: area, gap: 0, gapVertical: 0, tileMinimum: CGSize(width: 700, height: 0))
        XCTAssertNil(shrunk.region)
    }

    func testDeterministic() {
        let a = plan(nil, [arrival(5, 300, 400), arrival(6, 200, 100)], allowBottom: true)
        let b = plan(nil, [arrival(5, 300, 400), arrival(6, 200, 100)], allowBottom: true)
        XCTAssertEqual(a, b)
    }

    /// No backward compatibility: old saved data without an edge is not read.
    func testDecodingWithoutEdgeFails() {
        let json = #"{"thickness":300,"members":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DialogRegion.self, from: json))
    }

    /// The reservation comes from the right edge after outer gaps; when too large, only the gaps remain.
    func testTilingAreaReservesTheRightEdge() {
        var options = PlannerOptions(outerLeft: 10, outerRight: 20)
        XCTAssertEqual(options.tilingArea(area), CGRect(x: 10, y: 25, width: 1970, height: 1000))
        options.reservedRight = 510
        XCTAssertEqual(options.tilingArea(area), CGRect(x: 10, y: 25, width: 1460, height: 1000))
        options.reservedRight = 5000
        XCTAssertEqual(options.tilingArea(area), CGRect(x: 10, y: 25, width: 1970, height: 1000))
    }

    /// Resizable: even without a full-screen button, a window with a writable size and an enabled zoom button is standard.
    func testDialogEvidence() {
        func ev(_ subrole: String?, fs: DialogEvidence.Button, zoom: DialogEvidence.Button, settable: Bool) -> DialogEvidence {
            DialogEvidence(role: "AXWindow", subrole: subrole, minimized: false, fullscreen: false, fullscreenButton: fs, zoomButton: zoom, sizeSettable: settable, title: "")
        }
        XCTAssertTrue(ev("AXStandardWindow", fs: .absent, zoom: .disabled, settable: false).isDialog, "Calculator")
        XCTAssertTrue(ev("AXStandardWindow", fs: .absent, zoom: .enabled, settable: true).isStandard, "Activity Monitor")
        XCTAssertTrue(ev("AXStandardWindow", fs: .absent, zoom: .absent, settable: true).isDialog, "an open panel")
        XCTAssertTrue(ev("AXDialog", fs: .absent, zoom: .absent, settable: true).isDialog, "an alert")
        XCTAssertFalse(ev("AXSystemDialog", fs: .absent, zoom: .absent, settable: false).isDialog, "a panel that follows its app's window")
        XCTAssertTrue(ev("AXStandardWindow", fs: .enabled, zoom: .enabled, settable: true).isStandard)
        XCTAssertFalse(ev("AXFloatingWindow", fs: .absent, zoom: .absent, settable: false).isDialog, "palettes are not dialogs")
    }

    func testConfigKey() throws {
        XCTAssertFalse(Config().placeDialogsBeside)
        XCTAssertTrue(try Config.load(toml: "place-dialogs-beside = true\n").placeDialogsBeside)
        XCTAssertThrowsError(try Config.load(toml: "place-dialogs-beside = 1\n"))
        XCTAssertFalse(try Config.load(toml: Config.template).placeDialogsBeside)
    }
}

/// The region through Coordinator. Space 7 is arranged with windows 1 (pid 101, front) and 2 (pid 102). Window 5 (pid 105) is a dialog.
final class DialogRegionCoordinatorTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var clock = Date(timeIntervalSince1970: 90_000)

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make(_ config: String = "place-dialogs-beside = true\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        system.existingSpaces = [7]
        system.hiddenSpaces = true
        system.frames = [WindowID(1): CGRect(x: 0, y: 0, width: 960, height: 1080),
                         WindowID(2): CGRect(x: 960, y: 0, width: 960, height: 1080),
                         WindowID(5): CGRect(x: 600, y: 300, width: 300, height: 400)]
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(5): 7]
        system.pids = [WindowID(1): 101, WindowID(2): 102, WindowID(5): 105]
        system.apps = [WindowID(1): "com.example.a", WindowID(2): "com.example.b", WindowID(5): "com.example.c"]
        system.kindOf = [WindowID(5): .dialog]
        system.focused = WindowID(1)
        system.frontPID = 101
        let configURL = root.appendingPathComponent("config.toml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        coordinator = Coordinator(system: system, store: store, configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.routingClock = { [unowned self] in clock }
        coordinator.processStartTime = { _ in Date(timeIntervalSince1970: 1_000) }
        coordinator.appBundleID = { [unowned self] pid in system.pids.first { $0.value == pid }.flatMap { system.apps[$0.key] } }
        coordinator.isRegularApp = { _ in true }
        // Most tests use a dialog the user saw and left (enters after 1 s); the 5 s for never-front windows is checked separately.
        coordinator.regionUnseenDelay = Coordinator.regionAwayDelay
        _ = coordinator.reloadConfig(source: "test")
        drain()
        tick()
        coordinator.operationsQueue.sync { coordinator.noteSpaceArrival(at: .distantPast) }
    }

    private func drain() {
        for _ in 0..<2 {
            let done = expectation(description: "drained")
            coordinator.operationsQueue.async { done.fulfill() }
            wait(for: [done], timeout: 5)
        }
    }

    private func tick(after seconds: TimeInterval = 0.4) {
        clock.addTimeInterval(seconds)
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    private func ticks(_ n: Int = 8) { for _ in 0..<n { tick() } }

    private let mainFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let mainWork = CGRect(x: 0, y: 25, width: 2560, height: 1415)
    private let belowFrame = CGRect(x: 375, y: 1440, width: 1920, height: 1080)
    private let belowWork = CGRect(x: 375, y: 1465, width: 1920, height: 1055)

    /// The current Space moves to a display below the main one (the owner's setup), with the dialog at `dialog`.
    private func onTheDisplayBelow(dialog: CGRect) {
        coordinator.displaySettleInterval = 0
        system.area = belowWork
        system.frames[WindowID(1)] = CGRect(x: 375, y: 1465, width: 960, height: 1055)
        system.frames[WindowID(2)] = CGRect(x: 1335, y: 1465, width: 960, height: 1055)
        system.frames[WindowID(5)] = dialog
        system.displays = [(mainFrame, mainWork), (belowFrame, belowWork)]
    }

    /// On the display below, the strip takes that display's right edge and tiles stay on that display.
    func testTheStripOnTheDisplayBelow() throws {
        try make()
        onTheDisplayBelow(dialog: CGRect(x: 600, y: 1600, width: 300, height: 400))
        ticks(12)
        let dialog = try XCTUnwrap(system.frames[WindowID(5)])
        XCTAssertEqual(dialog, CGRect(x: 1995, y: 1465, width: 300, height: 400))
        for id in [WindowID(1), WindowID(2)] {
            let tile = try XCTUnwrap(system.frames[id])
            XCTAssertGreaterThanOrEqual(tile.minX, belowWork.minX)
            XCTAssertLessThanOrEqual(tile.maxX, dialog.minX)
            XCTAssertEqual(tile.minY, belowWork.minY)
        }
    }

    /// With two displays, a dialog joins the strip only when more than half of it is on the current Space's display.
    func testADialogMostlyOnAnotherDisplayStaysPut() throws {
        for (top, joins) in [(1200.0, false), (1240.0, false), (1280.0, true)] {
            try make()
            onTheDisplayBelow(dialog: CGRect(x: 600, y: top, width: 300, height: 400))
            ticks(12)
            XCTAssertEqual(!system.positionWrites.isEmpty, joins, "dialog top \(top)")
            XCTAssertEqual(coordinator.state.dialogRegions?["7"] != nil, joins, "dialog top \(top)")
            try tearDownWithError()
        }
    }

    /// A system dialog on the display below is left alone too, and the tiles there keep the whole width.
    func testSystemDialogOnTheDisplayBelowStaysOut() throws {
        try make()
        onTheDisplayBelow(dialog: CGRect(x: 600, y: 1600, width: 300, height: 400))
        system.dialogEvidences[WindowID(5)] = .some(DialogEvidence(role: "AXWindow", subrole: "AXSystemDialog", minimized: false, fullscreen: false,
                                                                    fullscreenButton: .absent, zoomButton: .absent, sizeSettable: false, title: ""))
        ticks(12)
        XCTAssertTrue(system.positionWrites.isEmpty)
        XCTAssertEqual(max(system.frames[WindowID(1)]!.maxX, system.frames[WindowID(2)]!.maxX), belowWork.maxX)
    }

    /// After a display setup change, the strip waits until the displays settle, then moves to the new edge.
    func testTheStripWaitsForTheDisplaysToSettle() throws {
        try make()
        ticks()
        XCTAssertNotNil(coordinator.state.dialogRegions?["7"])
        coordinator.displaySettleInterval = 0.3
        // The display clock stands still until the wait is over, so slow ticks on a busy machine cannot end it early.
        let held = Date()
        coordinator.operationsQueue.sync { coordinator.displayClock = { held } }
        let positions = system.positionWrites.count, writes = system.writes
        system.area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        ticks(4)
        XCTAssertEqual(system.positionWrites.count, positions, "no strip write before the displays settle")
        XCTAssertEqual(system.writes, writes, "no tile write before the displays settle")
        Thread.sleep(forTimeInterval: 0.35)
        coordinator.operationsQueue.sync { coordinator.displayClock = Date.init }
        ticks(12)
        XCTAssertEqual(system.frames[WindowID(5)]?.maxX ?? 0, 1600, accuracy: 1)
    }

    /// 1 s after moving to another window, the dialog moves to the right edge and tiles use the rest. Its size does not change.
    func testADialogMovesToTheRightEdgeAndTilesUseTheRest() throws {
        try make()
        ticks()
        let dialog = try XCTUnwrap(system.frames[WindowID(5)])
        XCTAssertEqual(dialog.size, CGSize(width: 300, height: 400), "the dialog keeps its size")
        XCTAssertEqual(dialog.maxX, system.area.maxX, accuracy: 1)
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
        let tileRight = max(system.frames[WindowID(1)]!.maxX, system.frames[WindowID(2)]!.maxX)
        XCTAssertLessThanOrEqual(tileRight, dialog.minX + 1, "tiles stay left of the strip")
        XCTAssertTrue(coordinator.status().dialogRegion.contains("300"))
    }

    /// The front dialog is not moved.
    func testTheFrontDialogIsNotMoved() throws {
        try make()
        system.frontPID = 105
        system.focused = WindowID(5)
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
    }

    /// Off: nothing happens. Turning it off removes the strip and tiles expand (the dialog stays where it is).
    func testTurningTheSettingOffExpandsTiles() throws {
        try make()
        ticks()
        XCTAssertNotNil(coordinator.state.dialogRegions?["7"])
        try "place-dialogs-beside = false\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        drain()
        let dialogBefore = system.frames[WindowID(5)]
        ticks()
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
        XCTAssertEqual(max(system.frames[WindowID(1)]!.maxX, system.frames[WindowID(2)]!.maxX), system.area.maxX, accuracy: 1)
        XCTAssertEqual(system.frames[WindowID(5)], dialogBefore, "the dialog stays where it is")
    }

    func testOffByDefault() throws {
        try make("")
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
    }

    /// Not used while Stage Manager is on.
    func testStageManagerTurnsItOff() throws {
        try make()
        system.stageManagerOn = true
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
    }

    /// Closing removes the strip and tiles expand.
    func testClosingTheDialogRemovesTheStrip() throws {
        try make()
        ticks()
        XCTAssertNotNil(coordinator.state.dialogRegions?["7"])
        system.frames[WindowID(5)] = nil
        system.spaceOf[WindowID(5)] = nil
        ticks()
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
        XCTAssertEqual(max(system.frames[WindowID(1)]!.maxX, system.frames[WindowID(2)]!.maxX), system.area.maxX, accuracy: 1)
    }

    /// Windows with unreadable evidence stay out, and so do resizable (standard) windows.
    func testUnreadableOrResizableWindowsStayOut() throws {
        try make()
        system.dialogEvidences[WindowID(5)] = .some(nil)
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
        system.dialogEvidences[WindowID(5)] = .some(DialogEvidence(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, fullscreen: false,
                                                                    fullscreenButton: .absent, zoomButton: .enabled, sizeSettable: true, title: ""))
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
    }

    /// A system dialog, like a panel an app keeps beside its own window, is never moved and never narrows the tiles.
    func testSystemDialogsStayOut() throws {
        try make()
        let tiles = [system.frames[WindowID(1)], system.frames[WindowID(2)]]
        system.dialogEvidences[WindowID(5)] = .some(DialogEvidence(role: "AXWindow", subrole: "AXSystemDialog", minimized: false, fullscreen: false,
                                                                    fullscreenButton: .absent, zoomButton: .absent, sizeSettable: false, title: ""))
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
        XCTAssertEqual([system.frames[WindowID(1)], system.frames[WindowID(2)]], tiles)
    }

    /// An app that keeps moving it back after writes is left alone after 3 times (tiles expand).
    func testAnAppThatKeepsMovingItBackIsLeftAlone() throws {
        try make()
        system.ignoresPositionWrites = [WindowID(5)]
        ticks(14)
        XCTAssertEqual(system.positionWrites.count, 3)
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
    }

    /// An app that moves it back later (after the readback) is counted only after two consecutive observations, and left alone after 3. No rewrite while checking.
    func testAnAppThatMovesItBackLaterIsLeftAlone() throws {
        try make()
        let original = try XCTUnwrap(system.frames[WindowID(5)])
        var seen = 0
        for _ in 0..<30 {
            tick()
            if system.positionWrites.count > seen {
                seen = system.positionWrites.count
                system.frames[WindowID(5)] = original
            }
        }
        XCTAssertEqual(system.positionWrites.count, 3)
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
    }

    /// Input in another app after writing does not forgive an app that moved it back (only bringing it forward does).
    func testInputInAnotherAppDoesNotForgiveAnAppThatMovesItBack() throws {
        try make()
        let original = try XCTUnwrap(system.frames[WindowID(5)])
        var seen = 0
        for _ in 0..<30 {
            tick()
            system.inputActivityCount += 1 // the user is typing in another window
            if system.positionWrites.count > seen {
                seen = system.positionWrites.count
                system.frames[WindowID(5)] = original
            }
        }
        XCTAssertLessThanOrEqual(system.positionWrites.count, 3)
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
    }

    /// A window whose size or position keeps changing enters only after being still for 1 s.
    func testACandidateEntersOnlyAfterItsFrameIsStill() throws {
        try make()
        for step in 0..<5 {
            system.frames[WindowID(5)]?.size = CGSize(width: 300 + CGFloat(step) * 40, height: 400)
            tick()
        }
        XCTAssertTrue(system.positionWrites.isEmpty, "a dialog that is still changing is left alone")
        ticks(4)
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
    }

    /// If placement fails (the app does not accept the written position), no tile moves and it is not retried for 5 s.
    func testAFailedPlacementMovesNoTileAndBacksOff() throws {
        try make()
        system.rejectsPositionWrites = [WindowID(5)]
        let tiles = [WindowID(1): system.frames[WindowID(1)], WindowID(2): system.frames[WindowID(2)]]
        for _ in 0..<10 where system.positionWrites.isEmpty { tick() }
        XCTAssertEqual(system.positionWrites.count, 1)
        XCTAssertEqual(system.frames[WindowID(1)], tiles[WindowID(1)]!)
        XCTAssertEqual(system.frames[WindowID(2)], tiles[WindowID(2)]!)
        XCTAssertTrue(system.written.filter { $0.0 == WindowID(1) || $0.0 == WindowID(2) }.isEmpty, "tiles are written only after the dialogs are in place")
        ticks(8) // 3.2 s
        XCTAssertEqual(system.positionWrites.count, 1, "no new attempt before the back-off ends")
    }

    /// If its app resizes a strip dialog, tiles wait until it settles, and unless the user brought it forward it leaves the strip.
    func testAMemberResizedByItsAppLeavesTheStripOnce() throws {
        try make()
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
        let tiles = system.written.count
        system.frames[WindowID(5)]?.size = CGSize(width: 600, height: 500)
        tick()
        XCTAssertEqual(system.written.count, tiles, "no tile write while the size is changing")
        ticks()
        XCTAssertNil(coordinator.state.dialogRegions?["7"], "the app re-lays out its own window, so it leaves the strip")
        XCTAssertEqual(max(system.frames[WindowID(1)]!.maxX, system.frames[WindowID(2)]!.maxX), system.area.maxX, accuracy: 1)
        let writes = system.positionWrites.count
        ticks()
        XCTAssertEqual(system.positionWrites.count, writes, "not tried again while the window exists")
    }

    /// A dialog resized after the user brought it forward (such as switching Calculator's view) stays in the strip at its new size.
    func testAMemberResizedAfterBeingFrontStaysWithTheNewSize() throws {
        try make()
        ticks()
        system.frontPID = 105; system.focused = WindowID(5)
        tick()
        system.frames[WindowID(5)]?.size = CGSize(width: 400, height: 500)
        tick()
        system.frontPID = 101; system.focused = WindowID(1)
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.first?.size, CGSize(width: 400, height: 500))
    }

    /// Even after a restart (for a member not yet written in this launch), a size changed after the user brought it forward is accepted.
    func testAMemberRestoredAfterRestartKeepsAUserResize() throws {
        try make()
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
        drain()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.routingClock = { [unowned self] in clock }
        coordinator.processStartTime = { _ in Date(timeIntervalSince1970: 1_000) }
        coordinator.appBundleID = { [unowned self] pid in system.pids.first { $0.value == pid }.flatMap { system.apps[$0.key] } }
        coordinator.isRegularApp = { _ in true }
        // Most tests use a dialog the user saw and left (enters after 1 s); the 5 s for never-front windows is checked separately.
        coordinator.regionUnseenDelay = Coordinator.regionAwayDelay
        _ = coordinator.reloadConfig(source: "test")
        drain()
        tick()
        coordinator.operationsQueue.sync { coordinator.noteSpaceArrival(at: .distantPast) }
        ticks(3)
        let writes = system.positionWrites.count
        system.frontPID = 105; system.focused = WindowID(5)
        tick()
        system.frames[WindowID(5)]?.size = CGSize(width: 400, height: 500)
        tick()
        system.frontPID = 101; system.focused = WindowID(1)
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.first?.size, CGSize(width: 400, height: 500))
        XCTAssertGreaterThanOrEqual(system.positionWrites.count, writes)
    }

    /// If the size changed after the decision (this operation's observation differs from the plan), neither dialogs nor tiles are written, and it is recorded as nothing to do.
    func testAStalePlanWritesNothingAndIsNotReportedAsAFailure() throws {
        try make()
        system.censusBounds[WindowID(5)] = CGRect(x: 600, y: 300, width: 280, height: 400) // the decision's observation (CGWindowList)
        let tiles = system.written.count
        ticks()
        XCTAssertTrue(system.positionWrites.isEmpty)
        XCTAssertEqual(system.written.count, tiles)
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .partial)
    }

    /// The record keeps the placed dialog's planned and observed sizes, the outcome, and whether the front was the same app (numbers and names only).
    func testRegionTimelineRecordsPlacementSizesAndOutcome() throws {
        try make()
        ticks()
        let events = coordinator.lastResult?.timeline.map(\.event) ?? []
        XCTAssertTrue(events.contains("region:place=5:planned=300x400:observed=300x400:verified"), "\(events)")
        XCTAssertTrue(events.contains("region:frontSameApp=false"), "\(events)")
    }

    /// A dialog never in front (one the app opened on its own) waits 5 s; once it has been in front, it enters 1 s after the user leaves it.
    func testANeverFrontDialogWaitsFiveSeconds() throws {
        try make()
        coordinator.regionUnseenDelay = 5
        for _ in 0..<10 { tick() } // 4 s
        XCTAssertTrue(system.positionWrites.isEmpty, "not after 4 seconds")
        for _ in 0..<6 where system.positionWrites.isEmpty { tick() }
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
    }

    func testADialogThatWasFrontOnceEntersAfterOneSecond() throws {
        try make()
        coordinator.regionUnseenDelay = 5
        system.frontPID = 105; system.focused = WindowID(5)
        tick()
        system.frontPID = 101; system.focused = WindowID(1)
        for _ in 0..<5 where system.positionWrites.isEmpty { tick() } // up to 2 s
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
    }

    /// While a member that refused a write waits for its retry, other members do not pack into its place.
    func testAMemberWaitingToRetryIsNotOverlapped() throws {
        try make()
        for id in [WindowID(6), WindowID(8)] {
            system.frames[id] = CGRect(x: 500, y: 200 + CGFloat(id.raw) * 10, width: 300, height: 300)
            system.spaceOf[id] = 7
            system.pids[id] = 100 + Int32(id.raw)
            system.apps[id] = "com.example.d\(id.raw)"
            system.kindOf[id] = .dialog
        }
        system.frames[WindowID(5)]?.size = CGSize(width: 300, height: 300)
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5), WindowID(6), WindowID(8)])
        let last = try XCTUnwrap(system.frames[WindowID(8)])
        system.frames[WindowID(5)] = nil
        system.spaceOf[WindowID(5)] = nil
        system.rejectsPositionWrites = [WindowID(6)]
        ticks(8)
        XCTAssertEqual(system.frames[WindowID(8)], last, "the last dialog does not move into the place the refusing dialog still occupies")
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(6), WindowID(8)])
    }

    /// When the same ID becomes another app's window, the previous window's wait does not carry over.
    func testARetryHoldDoesNotFollowAReusedWindowID() throws {
        try make()
        system.rejectsPositionWrites = [WindowID(5)]
        ticks(8)
        XCTAssertEqual(system.positionWrites.count, 1, "the first owner was tried once and is waiting")
        XCTAssertFalse(system.positionWrites.isEmpty, "the first owner was tried")
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
        system.rejectsPositionWrites = []
        system.pids[WindowID(5)] = 106
        system.apps[WindowID(5)] = "com.example.e"
        ticks(5)
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.pid), [106])
    }

    /// An edit interrupted by a settings change commits neither layout nor floating state and does not report success.
    func testAnEditInterruptedByASettingsChangeSavesNothing() throws {
        try make("")
        var reloaded = false
        system.onWrite = { [unowned self] _, _ in
            guard !reloaded else { return }
            reloaded = true
            try? "gap = 20\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            _ = coordinator.reloadConfig(source: "test")
        }
        guard case .started(let id) = coordinator.agentEdit(.toggleFloat, windowID: WindowID(1), expectedSpaceID: 7, desiredState: true) else { return XCTFail("Not accepted") }
        drain()
        XCTAssertTrue(reloaded)
        XCTAssertNotEqual(coordinator.result(id: id)?.outcome, .complete)
        XCTAssertTrue(coordinator.status().floating.isEmpty)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.sorted { $0.raw < $1.raw }, [WindowID(1), WindowID(2)])
    }

    /// Even after the last tile closes, the dialog enters the strip and the closed tile leaves the layout.
    func testTheStripWorksAfterTheLastTileCloses() throws {
        try make()
        for id in [WindowID(1), WindowID(2)] { system.frames[id] = nil; system.spaceOf[id] = nil }
        system.focused = nil
        system.frontPID = 101
        system.frames[WindowID(9)] = CGRect(x: 0, y: 0, width: 200, height: 200)
        system.spaceOf[WindowID(9)] = 7
        system.pids[WindowID(9)] = 101
        system.apps[WindowID(9)] = "com.example.a"
        system.kindOf[WindowID(9)] = .dialog
        system.focused = WindowID(9)
        ticks(10)
        XCTAssertTrue(coordinator.state.dialogRegions?["7"]?.members.map(\.id).contains(WindowID(5)) == true)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [])
    }

    /// After the last tile is minimized, its minimum width no longer limits the strip.
    func testMinimizedTilesDoNotLimitTheStrip() throws {
        try make()
        for id in [WindowID(1), WindowID(2)] {
            system.hiddenFromCensus.insert(id)
            system.minimizedWindows.insert(id)
            coordinator.knowledge.recordPushback(id: id, requested: CGRect(x: 0, y: 0, width: 100, height: 1080), actual: CGRect(x: 0, y: 0, width: 1300, height: 1080),
                                                 spaceID: 7, workArea: system.area, tolerance: 2)
        }
        system.frames[WindowID(5)]?.size = CGSize(width: 800, height: 400)
        system.frames[WindowID(9)] = CGRect(x: 0, y: 0, width: 200, height: 200)
        system.spaceOf[WindowID(9)] = 7
        system.pids[WindowID(9)] = 101
        system.apps[WindowID(9)] = "com.example.a"
        system.kindOf[WindowID(9)] = .dialog
        system.focused = WindowID(9)
        ticks(10)
        XCTAssertTrue(coordinator.state.dialogRegions?["7"]?.members.map(\.id).contains(WindowID(5)) == true)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [])
    }

    /// After the last tile moves to another Space, its minimum width no longer limits the strip.
    func testTilesMovedToAnotherSpaceDoNotLimitTheStrip() throws {
        try make()
        system.existingSpaces = [7, 8]
        for id in [WindowID(1), WindowID(2)] {
            system.spaceOf[id] = 8
            coordinator.knowledge.recordPushback(id: id, requested: CGRect(x: 0, y: 0, width: 100, height: 1080), actual: CGRect(x: 0, y: 0, width: 1300, height: 1080),
                                                 spaceID: 7, workArea: system.area, tolerance: 2)
        }
        system.frames[WindowID(5)]?.size = CGSize(width: 800, height: 400)
        system.frames[WindowID(9)] = CGRect(x: 0, y: 0, width: 200, height: 200)
        system.spaceOf[WindowID(9)] = 7
        system.pids[WindowID(9)] = 101
        system.apps[WindowID(9)] = "com.example.a"
        system.kindOf[WindowID(9)] = .dialog
        system.focused = WindowID(9)
        ticks(10)
        XCTAssertTrue(coordinator.state.dialogRegions?["7"]?.members.map(\.id).contains(WindowID(5)) == true)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [])
    }

    /// A tile moved to a Space shown on another display (still in the on-screen list) does not limit the strip either.
    func testTilesMovedToAnotherDisplaysSpaceDoNotLimitTheStrip() throws {
        try make()
        system.existingSpaces = [7, 8]
        system.shownSpaces = [8]
        for id in [WindowID(1), WindowID(2)] {
            system.reportedSpaces[id] = [8]
            system.membershipOf[id] = .other
            coordinator.knowledge.recordPushback(id: id, requested: CGRect(x: 0, y: 0, width: 100, height: 1080), actual: CGRect(x: 0, y: 0, width: 1300, height: 1080),
                                                 spaceID: 7, workArea: system.area, tolerance: 2)
        }
        system.frames[WindowID(5)]?.size = CGSize(width: 800, height: 400)
        system.frames[WindowID(9)] = CGRect(x: 0, y: 0, width: 200, height: 200)
        system.spaceOf[WindowID(9)] = 7
        system.pids[WindowID(9)] = 101
        system.apps[WindowID(9)] = "com.example.a"
        system.kindOf[WindowID(9)] = .dialog
        system.focused = WindowID(9)
        ticks(10)
        XCTAssertTrue(coordinator.state.dialogRegions?["7"]?.members.map(\.id).contains(WindowID(5)) == true)
    }

    /// Directional focus moves between tiles and strip dialogs. Swapping from a strip dialog is not possible.
    func testFocusMovesBetweenTilesAndTheStrip() throws {
        try make()
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
        system.focused = WindowID(2)
        system.frontPID = 102
        XCTAssertTrue(coordinator.canApplyEdit(.focus(.right), focused: WindowID(2)))
        guard case .started = coordinator.edit(.focus(.right), source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(system.focused, WindowID(5))
        system.frontPID = 105
        XCTAssertTrue(coordinator.canApplyEdit(.focus(.left), focused: WindowID(5)))
        XCTAssertFalse(coordinator.canApplyEdit(.swap(.left), focused: WindowID(5)))
        if case .started = coordinator.edit(.swap(.left), source: "test") { XCTFail("swap from a dialog is not possible") }
        guard case .started = coordinator.edit(.focus(.left), source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(system.focused, WindowID(2))
    }

    /// Directional focus from a given window (the observe-and-choose path) also reaches strip dialogs.
    func testTargetedFocusReachesAStripDialog() throws {
        try make()
        ticks()
        system.focused = WindowID(2)
        system.frontPID = 102
        guard case .started = coordinator.agentEdit(.focus(.right), windowID: WindowID(2), expectedSpaceID: 7) else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(system.focused, WindowID(5))
    }

    /// A replaced process with the same ID and pid is not a focus target.
    func testAReusedProcessIsNotAFocusTarget() throws {
        try make()
        ticks()
        system.focused = WindowID(2)
        system.frontPID = 102
        coordinator.processStartTime = { pid in Date(timeIntervalSince1970: pid == 105 ? 5_000 : 1_000) }
        XCTAssertFalse(coordinator.canApplyEdit(.focus(.right), focused: WindowID(2)))
        guard case .refused(_, let code) = coordinator.edit(.focus(.right), source: "test") else { return XCTFail("should be refused") }
        XCTAssertEqual(code, "no-neighbor")
    }

    /// The border also shows on strip dialogs, but not on dialogs outside the strip.
    func testTheFocusBorderShowsOnStripDialogs() throws {
        try make("place-dialogs-beside = true\n[focus-border]\nenabled = true\n")
        var frame: CGRect??
        coordinator.onFocusFrame = { frame = .some($0) }
        ticks()
        system.focused = WindowID(5)
        system.frontPID = 105
        tick()
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // the border is reported on the main queue
        XCTAssertEqual(frame, .some(system.frames[WindowID(5)]))
        system.frames[WindowID(9)] = CGRect(x: 100, y: 100, width: 200, height: 200)
        system.spaceOf[WindowID(9)] = 7
        system.pids[WindowID(9)] = 109
        system.apps[WindowID(9)] = "com.example.f"
        system.kindOf[WindowID(9)] = .dialog
        system.focused = WindowID(9)
        system.frontPID = 109
        tick()
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(frame, .some(nil))
    }

    /// Pretends a tile minimum width was learned (so no wide strip fits on the right).
    private func learnWideTiles(_ width: CGFloat = 780) {
        for id in [WindowID(1), WindowID(2)] {
            coordinator.knowledge.recordPushback(id: id, requested: CGRect(x: 0, y: 0, width: 100, height: 1080), actual: CGRect(x: 0, y: 0, width: width, height: 1080),
                                                 spaceID: 7, workArea: system.area, tolerance: 2)
        }
    }

    private func addDialog(_ id: UInt32, _ frame: CGRect) {
        let window = WindowID(id)
        system.frames[window] = frame
        system.spaceOf[window] = 7
        system.pids[window] = 100 + Int32(id)
        system.apps[window] = "com.example.d\(id)"
        system.kindOf[window] = .dialog
    }

    /// A dialog that does not fit on the right goes into a bottom strip, and tiles use the remaining height.
    func testADialogThatOnlyFitsAtTheBottomUsesABottomStrip() throws {
        try make()
        learnWideTiles()
        system.frames[WindowID(5)]?.size = CGSize(width: 400, height: 200)
        ticks()
        let region = try XCTUnwrap(coordinator.state.dialogRegions?["7"])
        XCTAssertEqual(region.edge, .bottom)
        let dialog = try XCTUnwrap(system.frames[WindowID(5)])
        XCTAssertEqual(dialog.maxY, system.area.maxY, accuracy: 1)
        XCTAssertEqual(dialog.size, CGSize(width: 400, height: 200))
        let tileBottom = max(system.frames[WindowID(1)]!.maxY, system.frames[WindowID(2)]!.maxY)
        XCTAssertLessThanOrEqual(tileBottom, dialog.minY + 1, "tiles stay above the strip")
        XCTAssertTrue(coordinator.status().dialogRegion.contains("200"))
    }

    /// A switch that stops midway commits nothing and the next decision restores it. Dialogs that moved are not counted.
    func testAPartialSwitchCommitsNothingAndConverges() throws {
        try make()
        learnWideTiles()
        ticks()
        let start = try XCTUnwrap(coordinator.state.dialogRegions?["7"])
        XCTAssertEqual(start.edge, .right)
        let placed = try XCTUnwrap(system.frames[WindowID(5)])
        addDialog(6, CGRect(x: 100, y: 100, width: 400, height: 200))
        system.rejectsPositionWrites = [WindowID(6)]
        ticks(10)
        XCTAssertTrue(system.positionWrites.contains { $0.0 == WindowID(6) }, "the switch was attempted")
        XCTAssertTrue(system.positionWrites.contains { $0.0 == WindowID(5) && $0.1.y > 600 }, "the first dialog was moved to the bottom during the attempt")
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .right, "the failed switch was not saved")
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)])
        XCTAssertEqual(system.frames[WindowID(5)], placed, "the dialog that had moved is back in the strip")
        ticks(10)
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.members.map(\.id), [WindowID(5)], "it is not counted as an app moving it back")
    }

    /// No edge switch for 30 s after a switch (after the strip empties, it starts from the remembered edge).
    func testTheEdgeChangesAtMostOnceEvery30Seconds() throws {
        try make()
        learnWideTiles()
        system.frames[WindowID(5)]?.size = CGSize(width: 300, height: 300)
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .right)
        system.frames[WindowID(5)] = nil
        system.spaceOf[WindowID(5)] = nil
        ticks()
        XCTAssertNil(coordinator.state.dialogRegions?["7"])
        addDialog(6, CGRect(x: 100, y: 100, width: 400, height: 200))
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .bottom, "the first change after a while is allowed")
        system.frames[WindowID(6)] = nil
        system.spaceOf[WindowID(6)] = nil
        ticks()
        addDialog(8, CGRect(x: 100, y: 100, width: 300, height: 300))
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .bottom, "within 30 seconds it starts on the remembered edge")
    }

    /// If the strip dialog's process is replaced after focus is accepted, focus does not move.
    func testAFocusDestinationIsCheckedAgainBeforeRaising() throws {
        try make()
        ticks()
        system.focused = WindowID(2)
        system.frontPID = 102
        coordinator.operationsQueue.suspend()
        guard case .started = coordinator.edit(.focus(.right), source: "test") else { coordinator.operationsQueue.resume(); return XCTFail("not accepted") }
        coordinator.processStartTime = { pid in Date(timeIntervalSince1970: pid == 105 ? 5_000 : 1_000) }
        system.kindOf[WindowID(5)] = .standard
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(system.focused, WindowID(2))
    }

    /// A region loaded after a restart remembers its edge, and does not switch back for 30 s after the first switch.
    func testARestoredRegionStartsTheSwitchCooldown() throws {
        try make()
        learnWideTiles()
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .right)
        // Restart: rebuild from the same storage location.
        drain()
        let store = StateStore(root: root)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.routingClock = { [unowned self] in clock }
        coordinator.processStartTime = { _ in Date(timeIntervalSince1970: 1_000) }
        coordinator.appBundleID = { [unowned self] pid in system.pids.first { $0.value == pid }.flatMap { system.apps[$0.key] } }
        coordinator.isRegularApp = { _ in true }
        // Most tests use a dialog the user saw and left (enters after 1 s); the 5 s for never-front windows is checked separately.
        coordinator.regionUnseenDelay = Coordinator.regionAwayDelay
        _ = coordinator.reloadConfig(source: "test")
        drain()
        tick()
        coordinator.operationsQueue.sync { coordinator.noteSpaceArrival(at: .distantPast) }
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .right, "the saved strip was restored")
        let restored = coordinator.state.dialogRegions?["7"]
        learnWideTiles()
        tick()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"], restored, "the restored strip is not committed again before the switch")
        addDialog(6, CGRect(x: 100, y: 100, width: 400, height: 200))
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .bottom)
        system.frames[WindowID(6)] = nil
        system.spaceOf[WindowID(6)] = nil
        ticks()
        XCTAssertEqual(coordinator.state.dialogRegions?["7"]?.edge, .bottom, "no switch back within 30 seconds of the first switch")
    }

    /// User input during the destination recheck stops the raise (authorization is checked after the recheck too).
    func testInputDuringTheDestinationCheckStopsTheRaise() throws {
        try make()
        ticks()
        system.focused = WindowID(2)
        system.frontPID = 102
        let control = OperationControl()
        var checks = 0
        let destination = FocusOperation.RegionDestination(pid: 105) { [unowned self] in
            checks += 1
            if checks >= 2 { system.inputActivityCount += 1 } // input during the read of the recheck right before raising
            return true
        }
        let result = FocusOperation(system: system, control: control, target: WindowID(5), regionDestination: destination).run()
        XCTAssertNotEqual(result.outcome, .complete)
        XCTAssertEqual(system.focused, WindowID(2), "nothing was raised")
        XCTAssertGreaterThanOrEqual(checks, 2, "the final gate ran the destination check")
    }
}
