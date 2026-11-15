import CoreGraphics
import XCTest
@testable import LayoutCore

final class PlannerTests: XCTestCase {
    let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    func ids(_ n: Int) -> [WindowID] { (1...n).map { WindowID(UInt32($0)) } }

    func testSingleWindowFillsArea() {
        guard case .fits(let plan) = Planner.initial(for: ids(1), in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(1)], area)
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.assumedUnknown, [WindowID(1)])
    }

    func testSoloWindowFillsEvenWhenAShortHeightWasRemembered() {
        let id = WindowID(1)
        let layout = Layout(root: .leaf(id), leftoverHeights: [id: 440])
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[id], area.integralInset)
        let pruned = Layout(
            root: .split(.horizontal, children: [.leaf(id), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
            leftoverHeights: [id: 440]
        ).removing([WindowID(2)])
        XCTAssertEqual(pruned.root, .leaf(id))
        XCTAssertTrue(pruned.leftoverHeights.isEmpty)
    }

    func testTwoWindowsSplitHorizontallyFirst() {
        guard case .fits(let plan) = Planner.initial(for: ids(2), in: area, constraints: [:]) else { return XCTFail() }
        let a = plan.rects[WindowID(1)]!, b = plan.rects[WindowID(2)]!
        XCTAssertEqual(a.minX, 0); XCTAssertEqual(a.width, 960); XCTAssertEqual(a.height, 1055)
        XCTAssertEqual(b.minX, 960); XCTAssertEqual(b.width, 960)
        XCTAssertEqual(plan.rows, 1)
    }

    func testFiveWindowsRespectKnownMinimumsInOneRowWhenNoPreference() {
        var c: [WindowID: SizeKnowledge] = [:]
        c[WindowID(3)] = .known(CGSize(width: 600, height: 400))
        let opts = PlannerOptions(preferredMinimum: .zero)
        guard case .fits(let plan) = Planner.initial(for: ids(5), in: area, constraints: c, options: opts) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 1)
        XCTAssertGreaterThanOrEqual(plan.rects[WindowID(3)]!.width, 600)
        let total = plan.rects.values.map(\.width).reduce(0, +)
        XCTAssertEqual(total, 1920)
        for r in plan.rects.values { XCTAssertGreaterThanOrEqual(r.width, 120) }
    }

    func testPreferredMinimumChoosesMoreRowsBeforeSqueezing() {
        // 5 in one row are 384 wide < the preferred 400. Two rows (3+2) give 640 wide, 525 high.
        guard case .fits(let plan) = Planner.initial(for: ids(5), in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 2)
        for r in plan.rects.values {
            XCTAssertGreaterThanOrEqual(r.width, 400)
            XCTAssertGreaterThanOrEqual(r.height, 300)
        }
    }

    func testEightWindowsOnLaptopWorkAreaFitAsThreeRows() {
        let laptop = CGRect(x: 0, y: 33, width: 1512, height: 949)
        guard case .fits(let plan) = Planner.initial(for: ids(8), in: laptop, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 3)
        XCTAssertEqual(plan.rects.values.filter { Int($0.width) == 504 }.count, 6)
        XCTAssertEqual(plan.rects.values.filter { Int($0.width) == 756 }.count, 2)
    }

    func testPreferredMinimumFallsBackToOneOverlappingRow() {
        // When no row count meets the preference, one overlapping row comes before rows that only fit above the provisional
        // minimum 120 (40 windows would be 3 rows of 14, 137 wide each).
        guard case .fits(let plan) = Planner.initial(for: ids(40), in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 1)
        XCTAssertTrue(plan.folded)
        XCTAssertEqual(plan.rects.count, 40)
        for r in plan.rects.values {
            XCTAssertEqual(r.width, 400, "the preferred width")
            XCTAssertTrue(area.contains(r), "\(r) is outside the area")
        }
        var unfolded = PlannerOptions()
        unfolded.folds = false
        guard case .fits(let rows) = Planner.initial(for: ids(40), in: area, constraints: [:], options: unfolded) else { return XCTFail() }
        XCTAssertEqual(rows.rows, 3)
        for r in rows.rects.values { XCTAssertGreaterThanOrEqual(r.width, 120) }
        // 12 windows in 3 rows (4 per row = 480x350) meet the preference.
        guard case .fits(let plan12) = Planner.initial(for: ids(12), in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan12.rows, 3)
    }

    func testOverflowFallsBackToTwoRowsAndKeepsRowHeightConstraint() {
        // 5 windows each needing 500 wide: one row is 2500 > 1920, so two rows of 3+2.
        var c: [WindowID: SizeKnowledge] = [:]
        for id in ids(5) { c[id] = .known(CGSize(width: 500, height: 300)) }
        guard case .fits(let plan) = Planner.initial(for: ids(5), in: area, constraints: c) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 2)
        let firstRow = plan.rects.values.filter { $0.minY == area.minY }
        XCTAssertEqual(firstRow.count, 3)
        for r in plan.rects.values {
            XCTAssertGreaterThanOrEqual(r.width, 500)
            XCTAssertGreaterThanOrEqual(r.height, 300)
            XCTAssertTrue(area.contains(r), "\(r) is outside the area")
        }
    }

    func testUnfitReportsMembersAndDoesNotPlan() {
        var c: [WindowID: SizeKnowledge] = [:]
        c[WindowID(1)] = .known(CGSize(width: 1900, height: 1040))
        c[WindowID(2)] = .known(CGSize(width: 1900, height: 1040))
        // Side by side needs 3800 > 1920 wide, stacked 2080 > 1055 high; overlapping leaves 1890 < 1900 wide or 1025 < 1040 high.
        guard case .unfit(let u) = Planner.initial(for: ids(2), in: area, constraints: c) else { return XCTFail("must not fit") }
        XCTAssertEqual(Set(u.offending), Set(ids(2)))
    }

    func testUnknownIsNotTreatedAsNoMinimum() {
        // A known window needing 1850 leaves 70 for the unknown one, below the provisional minimum 120 -> no single row -> two rows.
        var c: [WindowID: SizeKnowledge] = [:]
        c[WindowID(1)] = .known(CGSize(width: 1850, height: 300))
        guard case .fits(let plan) = Planner.initial(for: ids(2), in: area, constraints: c) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 2)
        XCTAssertGreaterThanOrEqual(plan.rects[WindowID(2)]!.width, 120)
    }

    func testFitKeepsUserStructureAndRatios() {
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.7, 0.3]))
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(1)]!.width, 1344)
        XCTAssertEqual(plan.rects[WindowID(2)]!.width, 576)
        XCTAssertEqual(plan.layout, layout)
    }

    func testPackedRatiosSurviveALaterFitWithoutMaximums() {
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let windows = [WindowID(1), WindowID(2)]
        let maximums = [WindowID(1): CGSize(width: 230, height: 408)]
        guard case .fits(let planned) = Planner.initial(for: windows, in: screen, constraints: [:], maximums: maximums) else {
            return XCTFail("expected an initial layout with caps")
        }
        XCTAssertEqual(planned.rects[WindowID(1)]?.width, 230)
        XCTAssertEqual(planned.rects[WindowID(2)]?.width, 1282)
        let packed = planned.layout.packing(rects: planned.rects, shape: planned.shape)
        guard case .split(.horizontal, _, let ratios)? = packed.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 230.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 1282.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(planned.layout, Planner.rowLayout(windows, rows: 1))
        guard case .fits(let again) = Planner.fit(packed, in: screen, constraints: [:]) else {
            return XCTFail("expected a recalculation with the saved ratios")
        }
        XCTAssertEqual(again.rects[WindowID(1)]?.width, 230)
        XCTAssertEqual(again.rects[WindowID(2)]?.width, 1282)
    }

    func testFitClampsOnlyViolatorAndRedistributesRest() {
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let c: [WindowID: SizeKnowledge] = [WindowID(2): .estimated(CGSize(width: 900, height: 0))]
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: c) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(2)]!.width, 900)
        XCTAssertEqual(plan.rects[WindowID(1)]!.width, 510)
        XCTAssertEqual(plan.rects[WindowID(3)]!.width, 510)
        XCTAssertTrue(plan.assumedUnknown.contains(WindowID(2)), "with only one axis known, the other is assumed")
    }

    func testFixedWindowGivesUnusedWidthToFlexibleNeighbors() {
        // A laptop's work area. A fixed 230x408 window in an equal share would leave space its neighbor cannot use.
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let windows = [WindowID(1), WindowID(2), WindowID(3)]
        let maximums = [WindowID(1): CGSize(width: 230, height: 408)]
        guard case .fits(let plan) = Planner.initial(for: windows, in: screen, constraints: [:], maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.rects[WindowID(1)], CGRect(x: 0, y: 33, width: 230, height: 408))
        XCTAssertEqual(plan.rects[WindowID(2)], CGRect(x: 230, y: 33, width: 641, height: 949))
        XCTAssertEqual(plan.rects[WindowID(3)], CGRect(x: 871, y: 33, width: 641, height: 949))
    }

    func testFixedWindowsLeaveAGapInsteadOfStretchingCenteredAsAGroup() {
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let maximums = [
            WindowID(1): CGSize(width: 230, height: 408),
            WindowID(2): CGSize(width: 400, height: 300),
        ]
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: [:], maximums: maximums) else { return XCTFail() }
        // 1512 - 230 - 400 = 882 unused, split evenly on both sides of the pair.
        XCTAssertEqual(plan.rects[WindowID(1)], CGRect(x: 441, y: 33, width: 230, height: 408))
        XCTAssertEqual(plan.rects[WindowID(2)], CGRect(x: 671, y: 33, width: 400, height: 300))
    }

    /// Ratios written back from a centered row reproduce the same row, so the next arrangement writes nothing.
    func testCenteredRowIsStableAfterPacking() {
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let maximums = [WindowID(1): CGSize(width: 230, height: 408), WindowID(2): CGSize(width: 400, height: 300)]
        guard case .fits(let first) = Planner.fit(layout, in: screen, constraints: [:], maximums: maximums) else { return XCTFail() }
        guard case .fits(let second) = Planner.fit(first.layout.normalized().packing(rects: first.rects, shape: first.shape), in: screen, constraints: [:], maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(second.rects, first.rects)
    }

    func testFixedWidthSoloWindowIsCenteredAndKeepsFullHeight() {
        // System Settings: a fixed width, resizable vertically.
        let id = WindowID(1)
        guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: area, constraints: [:], maximums: [id: CGSize(width: 740, height: 0)]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[id], CGRect(x: 590, y: 25, width: 740, height: 1055))
    }

    func testHeightCapLeavesTheSpaceBelowTheWindow() {
        let id = WindowID(1)
        guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: area, constraints: [:], maximums: [id: CGSize(width: 0, height: 400)]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[id], CGRect(x: 0, y: 25, width: 1920, height: 400))
    }

    func testCapWiderThanTheAreaFillsTheArea() {
        let id = WindowID(1)
        guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: area, constraints: [:], maximums: [id: CGSize(width: 3000, height: 0)]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[id], area.integralInset)
    }

    func testOddUnusedWidthRoundsToWholePoints() {
        let id = WindowID(1)
        guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: area, constraints: [:], maximums: [id: CGSize(width: 741, height: 0)]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[id], CGRect(x: 589, y: 25, width: 741, height: 1055))
    }

    func testHeightCappedStackStaysAtTheTop() {
        let layout = Layout(root: .split(.vertical, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let maximums = [WindowID(1): CGSize(width: 0, height: 200), WindowID(2): CGSize(width: 0, height: 300)]
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: [:], maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(1)], CGRect(x: 0, y: 25, width: 1920, height: 200))
        XCTAssertEqual(plan.rects[WindowID(2)], CGRect(x: 0, y: 225, width: 1920, height: 300))
    }

    /// Centering is measured from the work area's own origin, on any display: below the main one, to its left, or beside a strip.
    func testCenteringOnDisplaysAwayFromTheOrigin() {
        let id = WindowID(1)
        let cap = [id: CGSize(width: 740, height: 0)]
        var strip = PlannerOptions()
        strip.reservedRight = 310
        let cases: [(CGRect, PlannerOptions, CGRect)] = [
            (CGRect(x: 375, y: 1465, width: 1920, height: 1055), PlannerOptions(), CGRect(x: 965, y: 1465, width: 740, height: 1055)),
            (CGRect(x: -1920, y: 25, width: 1920, height: 1055), PlannerOptions(), CGRect(x: -1330, y: 25, width: 740, height: 1055)),
            (CGRect(x: 375, y: 1465, width: 1919, height: 1055), PlannerOptions(), CGRect(x: 964, y: 1465, width: 740, height: 1055)),
            (CGRect(x: 375, y: 1465, width: 1920, height: 1055), strip, CGRect(x: 810, y: 1465, width: 740, height: 1055)),
        ]
        for (workArea, options, expected) in cases {
            guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: workArea, constraints: [:], options: options, maximums: cap) else { return XCTFail("\(workArea)") }
            XCTAssertEqual(plan.rects[id], expected, "\(workArea)")
        }
        let row = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let caps = [WindowID(1): CGSize(width: 230, height: 408), WindowID(2): CGSize(width: 400, height: 300)]
        guard case .fits(let plan) = Planner.fit(row, in: CGRect(x: 375, y: 1465, width: 1920, height: 1055), constraints: [:], maximums: caps) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(1)]?.minX, 1020)
        XCTAssertEqual(plan.rects[WindowID(2)]?.minX, 1250)
    }

    /// A work area with fractional edges is rounded inward, so no window extends past it, even left of the main display.
    func testFractionalWorkAreasRoundInward() {
        let id = WindowID(1)
        for workArea in [CGRect(x: 375.5, y: 1465.5, width: 1919, height: 1054), CGRect(x: -1920.5, y: 25.5, width: 1920, height: 1055)] {
            for cap in [CGSize.zero, CGSize(width: 740, height: 0)] {
                let maximums = cap == .zero ? [:] : [id: cap]
                guard case .fits(let plan) = Planner.fit(Layout(root: .leaf(id)), in: workArea, constraints: [:], maximums: maximums), let rect = plan.rects[id] else { return XCTFail("\(workArea)") }
                XCTAssertGreaterThanOrEqual(rect.minX, workArea.minX, "\(workArea)")
                XCTAssertGreaterThanOrEqual(rect.minY, workArea.minY, "\(workArea)")
                XCTAssertLessThanOrEqual(rect.maxX, workArea.maxX, "\(workArea)")
                XCTAssertLessThanOrEqual(rect.maxY, workArea.maxY, "\(workArea)")
                XCTAssertEqual(rect, rect.integral, "\(workArea)")
            }
        }
    }

    /// A fractional work area is rounded once for the whole layout, so tiles share their edges and ratios written back from them reproduce the same tiles.
    func testFractionalWorkAreaKeepsSplitRatiosStable() {
        let workArea = CGRect(x: 0.5, y: 0.5, width: 1000, height: 500)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.25, 0.75]))
        let options = PlannerOptions(unknownFloor: .zero)
        guard case .fits(let first) = Planner.fit(layout, in: workArea, constraints: [:], options: options) else { return XCTFail() }
        XCTAssertEqual(first.rects[WindowID(1)]?.maxX, first.rects[WindowID(2)]?.minX, "no gap between the tiles")
        var plan = first
        for _ in 0..<3 {
            guard case .fits(let next) = Planner.fit(plan.layout.normalized().packing(rects: plan.rects, shape: plan.shape), in: workArea, constraints: [:], options: options) else { return XCTFail() }
            XCTAssertEqual(next.rects, first.rects)
            plan = next
        }
    }

    /// Fractional gaps are rounded to whole points, so tiles stay on whole points and written-back ratios reproduce the same tiles on both axes.
    func testFractionalGapsKeepSplitRatiosStable() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let options = PlannerOptions(gap: 0.5, unknownFloor: .zero, gapVertical: 0.5)
        for axis in [Axis.horizontal, .vertical] {
            let layout = Layout(root: .split(axis, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.75, 0.25]))
            guard case .fits(let first) = Planner.fit(layout, in: workArea, constraints: [:], options: options) else { return XCTFail() }
            for rect in first.rects.values { XCTAssertEqual(rect, rect.integral, "\(axis)") }
            var plan = first
            for _ in 0..<3 {
                guard case .fits(let next) = Planner.fit(plan.layout.normalized().packing(rects: plan.rects, shape: plan.shape), in: workArea, constraints: [:], options: options) else { return XCTFail() }
                XCTAssertEqual(next.rects, first.rects, "\(axis)")
                plan = next
            }
        }
    }

    /// A fractional accordion padding is rounded too, so splits inside an accordion keep their written-back ratios.
    func testFractionalAccordionPaddingKeepsInnerSplitRatiosStable() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let options = PlannerOptions(unknownFloor: .zero, accordionPadding: 30.5)
        let inner = LayoutNode.split(.vertical, children: [
            .split(.horizontal, children: [.leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [0.25, 0.75]),
            .leaf(WindowID(4)),
        ], ratios: [0.5, 0.5])
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(WindowID(1)), inner], ratios: [0.5, 0.5]))
        guard case .fits(let first) = Planner.fit(layout, in: workArea, constraints: [:], options: options, focused: WindowID(2)) else { return XCTFail() }
        for rect in first.rects.values { XCTAssertEqual(rect, rect.integral) }
        XCTAssertEqual(first.rects[WindowID(2)]?.maxX, first.rects[WindowID(3)]?.minX, "no gap between the tiles")
        var plan = first
        for _ in 0..<3 {
            guard case .fits(let next) = Planner.fit(plan.layout.normalized().packing(rects: plan.rects, shape: plan.shape), in: workArea, constraints: [:], options: options, focused: WindowID(2)) else { return XCTFail() }
            XCTAssertEqual(next.rects, first.rects)
            plan = next
        }
    }

    func testFixedWidthWindowInAColumnIsCenteredInThatColumn() {
        let layout = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)),
            .split(.vertical, children: [.leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
        let maximums = [WindowID(2): CGSize(width: 600, height: 0)]
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: [:], maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(plan.rects[WindowID(2)]?.minX, 1140)
        XCTAssertEqual(plan.rects[WindowID(2)]?.width, 600)
        XCTAssertEqual(plan.rects[WindowID(3)]?.minX, 960)
        XCTAssertEqual(plan.rects[WindowID(3)]?.width, 960)
    }

    func testKnownMinimumAndMaximumShareOneRow() {
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let windows = [WindowID(1), WindowID(2), WindowID(3)]
        let constraints = [WindowID(2): SizeKnowledge.known(CGSize(width: 800, height: 400))]
        let maximums = [WindowID(1): CGSize(width: 230, height: 408)]
        guard case .fits(let plan) = Planner.initial(for: windows, in: screen, constraints: constraints, maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.rects[WindowID(1)]?.width, 230)
        XCTAssertEqual(plan.rects[WindowID(2)]?.width, 800)
        XCTAssertEqual(plan.rects[WindowID(3)]?.width, 482)
        XCTAssertEqual(plan.rects[WindowID(1)]!.maxX, plan.rects[WindowID(2)]!.minX)
        XCTAssertEqual(plan.rects[WindowID(2)]!.maxX, plan.rects[WindowID(3)]!.minX)
    }

    func testCappedSlotStaysWhenANeighborRisesToItsMinimum() {
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3)),
        ], ratios: [230.0 / 1512.0, 641.0 / 1512.0, 641.0 / 1512.0]))
        let constraints: [WindowID: SizeKnowledge] = [
            WindowID(2): .estimated(CGSize(width: 700, height: 0)),
        ]
        let maximums = [WindowID(1): CGSize(width: 230, height: 440)]
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints, maximums: maximums) else {
            return XCTFail("a capped fixed width must not be cut by the neighbor's minimum")
        }
        XCTAssertEqual(plan.rects[WindowID(1)], CGRect(x: 0, y: 33, width: 230, height: 440))
        XCTAssertEqual(plan.rects[WindowID(2)], CGRect(x: 230, y: 33, width: 700, height: 949))
        XCTAssertEqual(plan.rects[WindowID(3)], CGRect(x: 930, y: 33, width: 582, height: 949))
        let lengths = Planner.distribute(
            available: 1512,
            ratios: [230.0 / 1512.0, 641.0 / 1512.0, 641.0 / 1512.0],
            minimums: [120, 700, 120],
            maximums: [230, .infinity, .infinity]
        )
        XCTAssertEqual(lengths, [230, 700, 582])
    }

    /// A window whose height follows its width (Finder's Get Info) can need more than a remembered short height or a maximum learned at
    /// another width: the cap gives way to the known minimum instead of asking for less than the window can be.
    func testACapBelowAKnownMinimumGivesWayToTheMinimum() {
        let screen = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        let (a, b, c) = (WindowID(1), WindowID(2), WindowID(3))
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.6, 0.2, 0.2]), leftoverHeights: [b: 1280])
        let constraints: [WindowID: SizeKnowledge] = [
            b: .estimated(CGSize(width: 0, height: 1308)),
            c: .estimated(CGSize(width: 600, height: 0)),
        ]
        let maximums = [b: CGSize(width: 400, height: 1280), c: CGSize(width: 500, height: 0)]
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints, maximums: maximums) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 30, width: 1560, height: 1410))
        XCTAssertEqual(plan.rects[b], CGRect(x: 1560, y: 30, width: 400, height: 1308), "the remembered height and the learned maximum give way")
        XCTAssertEqual(plan.rects[c], CGRect(x: 1960, y: 30, width: 600, height: 1410), "a maximum width below the minimum gives way, and the height stays uncapped")
    }

    /// Pinning caps and minimums at once with the same shares would reject a feasible split (500 and 500).
    func testDistributeFindsFeasibleLengthsWhenMinimumAndMaximumBothBind() {
        let lengths = Planner.distribute(available: 1000, ratios: [0.9, 0.1], minimums: [120, 500], maximums: [600, .infinity])
        XCTAssertEqual(lengths, [500, 500])
        let three = Planner.distribute(available: 1200, ratios: [0.8, 0.1, 0.1], minimums: [100, 400, 300], maximums: [700, .infinity, 350])
        XCTAssertEqual(three?.reduce(0, +), 1200)
        if let three {
            for (i, length) in three.enumerated() { XCTAssertTrue(length >= [100, 400, 300][i] && length <= [700, .infinity, 350][i], "\(three)") }
        }
    }

    func testDistributeIsIntegerAndSumsToAvailable() {
        let lengths = Planner.distribute(available: 1001, ratios: [1, 1, 1], minimums: [0, 0, 0])!
        XCTAssertEqual(lengths.reduce(0, +), 1001)
        XCTAssertTrue(lengths.allSatisfy { $0 == floor($0) })
    }

    func testRemovingWindowCollapsesSingleChild() {
        let layout = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
            .leaf(WindowID(3)),
        ], ratios: [0.5, 0.5]))
        let pruned = layout.removing([WindowID(2)])
        XCTAssertEqual(pruned.root, .split(.vertical, children: [.leaf(WindowID(1)), .leaf(WindowID(3))], ratios: [0.5, 0.5]))
        XCTAssertNil(layout.removing([WindowID(1), WindowID(2), WindowID(3)]).root)
    }

    func testLayoutRoundTripsThroughJSON() throws {
        let layout = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data), layout)
    }

    func testSizeKnowledgeMergePrefersKnown() {
        XCTAssertEqual(SizeKnowledge.unknown.merged(with: .estimated(CGSize(width: 1, height: 2))), .estimated(CGSize(width: 1, height: 2)))
        XCTAssertEqual(SizeKnowledge.estimated(CGSize(width: 9, height: 9)).merged(with: .known(CGSize(width: 1, height: 2))), .known(CGSize(width: 1, height: 2)))
    }

    func testPackingKeepsLeftoverOnlyWhenTheColumnHasAGapBelow() {
        let a = WindowID(1), b = WindowID(2)
        let sideBySide = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]))
        let gapped = sideBySide.packing(rects: [
            a: CGRect(x: 0, y: 33, width: 700, height: 432),
            b: CGRect(x: 700, y: 33, width: 812, height: 949),
        ], shape: sideBySide)
        XCTAssertEqual(gapped.leftoverHeights[a], 432)
        XCTAssertNil(gapped.leftoverHeights[b])
        let stacked = Layout(
            root: .split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [b: 475]
        )
        let filled = stacked.packing(rects: [
            a: CGRect(x: 0, y: 33, width: 1512, height: 474),
            b: CGRect(x: 0, y: 507, width: 1512, height: 475),
        ], shape: stacked)
        XCTAssertNil(filled.leftoverHeights[a])
        XCTAssertNil(filled.leftoverHeights[b])
    }

    func testUnusedStackHostSkipsANarrowLeftover() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let a = WindowID(1), b = WindowID(2)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [230 / 1512, 1282 / 1512]))
        let rects: [WindowID: CGRect] = [
            a: CGRect(x: 0, y: 33, width: 230, height: 440),
            b: CGRect(x: 230, y: 33, width: 1282, height: 949),
        ]
        XCTAssertNil(layout.unusedStackHost(rects: rects, area: work, need: CGSize(width: 400, height: 300)))
    }

    func testUnusedStackHostPicksTheWideShortLeaf() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let a = WindowID(1), b = WindowID(2), extra = WindowID(3)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]))
        let rects: [WindowID: CGRect] = [
            a: CGRect(x: 0, y: 33, width: 700, height: 440),
            b: CGRect(x: 700, y: 33, width: 812, height: 949),
        ]
        let host = layout.unusedStackHost(rects: rects, area: work, need: CGSize(width: 400, height: 300))
        XCTAssertEqual(host?.id, a)
        XCTAssertEqual(host?.usedHeight, 440)
        XCTAssertEqual(host?.unusedHeight, 509)
        let stacked = layout.inserting(extra, stackingBelow: host!.id, hostHeight: host!.usedHeight, unusedHeight: host!.unusedHeight)
        guard case .split(.horizontal, let children, let ratios)? = stacked.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 700 / 1512, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 812 / 1512, accuracy: 1e-9)
        guard case .split(.vertical, let stackedChildren, let stackedRatios) = children[0] else { return XCTFail() }
        XCTAssertEqual(stackedChildren, [.leaf(a), .leaf(extra)])
        XCTAssertEqual(stackedRatios[0], 440 / 949, accuracy: 1e-9)
        XCTAssertEqual(stackedRatios[1], 509 / 949, accuracy: 1e-9)
        guard case .leaf(let right) = children[1] else { return XCTFail() }
        XCTAssertEqual(right, b)
        XCTAssertEqual(stacked.leftoverHeights[a], 440)
        let packed = stacked.packing(rects: [
            a: CGRect(x: 0, y: 33, width: 700, height: 440),
            extra: CGRect(x: 0, y: 473, width: 700, height: 509),
            b: CGRect(x: 700, y: 33, width: 812, height: 949),
        ], shape: stacked)
        XCTAssertEqual(packed.leftoverHeights[a], 440)
        let collapsed = packed.removing([extra])
        XCTAssertEqual(collapsed.leftoverHeights[a], 440)
        XCTAssertNil(collapsed.leftoverHeights[extra])
        guard case .fits(let plan) = Planner.fit(collapsed, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]?.height, 440)
        XCTAssertEqual(plan.rects[b]?.height, 949)
        let floated = packed.removing([a], keepHeights: [a])
        XCTAssertEqual(floated.leftoverHeights[a], 440)
        XCTAssertFalse(floated.windowIDs.contains(a))
        let hostGone = packed.removing([a])
        XCTAssertNil(hostGone.leftoverHeights[extra])
        XCTAssertNil(hostGone.leftoverHeights[a])
        guard case .fits(let grown) = Planner.fit(hostGone, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(grown.rects[extra]?.height, 949)
    }

    func testHorizontalAccordionPadsAroundTheFocusedWindow() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let options = PlannerOptions(unknownFloor: .zero, accordionPadding: 30)
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: [:], options: options, focused: b) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 970, height: 500))
        XCTAssertEqual(plan.rects[b], CGRect(x: 30, y: 0, width: 940, height: 500))
        XCTAssertEqual(plan.rects[c], CGRect(x: 30, y: 0, width: 970, height: 500))
        guard case .fits(let end) = Planner.fit(layout, in: screen, constraints: [:], options: options, focused: a) else { return XCTFail() }
        XCTAssertEqual(end.rects[a], CGRect(x: 0, y: 0, width: 970, height: 500))
        XCTAssertEqual(end.rects[b], CGRect(x: 60, y: 0, width: 940, height: 500))
        guard case .fits(let column) = Planner.fit(
            Layout(root: .accordion(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5])),
            in: screen, constraints: [:], options: options, focused: b
        ) else { return XCTFail() }
        XCTAssertEqual(column.rects[a], CGRect(x: 0, y: 0, width: 1000, height: 470))
        XCTAssertEqual(column.rects[b], CGRect(x: 0, y: 30, width: 1000, height: 470))
    }

    /// Centering a capped window behind the front one would hide its strip, so a window whose strip is on the leading side keeps its leading edge.
    func testCappedWindowInAnAccordionKeepsItsStrip() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .split(.vertical, children: [.leaf(b)], ratios: [1]), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let maximums = [a: CGSize(width: 600, height: 0), b: CGSize(width: 600, height: 0)]
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: [:], options: PlannerOptions(accordionPadding: 30), maximums: maximums, focused: c) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 600, height: 1080))
        XCTAssertEqual(plan.rects[b]?.minX, 0, "a capped window in a split inside the accordion keeps its leading edge too")
    }

    /// A row that does not fit overlaps by what it lacks and no more, whoever has focus and whatever its ratios. The last window keeps the trailing edge.
    func testARowThatDoesNotFitOverlapsOnlyByWhatItLacks() {
        let wide = WindowID(1), other = WindowID(2)
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let options = PlannerOptions(accordionPadding: 30)
        for (width, start) in [(800.0, 712.0), (1000.0, 512.0)] {
            let constraints = [wide: SizeKnowledge.known(CGSize(width: 840, height: 400)), other: .known(CGSize(width: width, height: 400))]
            for ratios in [[0.5, 0.5], [0.9, 0.1]] {
                let layout = Layout(root: .split(.horizontal, children: [.leaf(wide), .leaf(other)], ratios: ratios))
                for focused in [wide, other] {
                    guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints, options: options, focused: focused) else { return XCTFail() }
                    XCTAssertTrue(plan.folded)
                    XCTAssertEqual(plan.layout, layout, "the intent stays a row")
                    XCTAssertEqual(plan.shape.root?.box?.accordion, true, "its windows overlap")
                    XCTAssertEqual(plan.rects[wide], CGRect(x: 0, y: 33, width: 840, height: 949))
                    XCTAssertEqual(plan.rects[other], CGRect(x: start, y: 33, width: width, height: 949))
                }
            }
        }
    }

    /// A capped window sits beside the other one in either order, and a capped height stays at the top.
    func testACappedWindowInARowThatDoesNotFitSitsBesideTheOther() {
        let wide = WindowID(1), capped = WindowID(2)
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let constraints = [wide: SizeKnowledge.known(CGSize(width: 840, height: 400)), capped: SizeKnowledge.known(CGSize(width: 740, height: 400))]
        let options = PlannerOptions(accordionPadding: 30)
        let row = Layout(root: .split(.horizontal, children: [.leaf(wide), .leaf(capped)], ratios: [0.5, 0.5]))
        let swapped = Layout(root: .split(.horizontal, children: [.leaf(capped), .leaf(wide)], ratios: [0.5, 0.5]))
        for focused in [wide, capped] {
            guard case .fits(let plan) = Planner.fit(row, in: screen, constraints: constraints, options: options, maximums: [capped: CGSize(width: 740, height: 0)], focused: focused) else { return XCTFail() }
            XCTAssertEqual(plan.rects[wide], CGRect(x: 0, y: 33, width: 840, height: 949))
            XCTAssertEqual(plan.rects[capped], CGRect(x: 772, y: 33, width: 740, height: 949))
            guard case .fits(let other) = Planner.fit(swapped, in: screen, constraints: constraints, options: options, maximums: [capped: CGSize(width: 740, height: 0)], focused: focused) else { return XCTFail() }
            XCTAssertEqual(other.rects[capped], CGRect(x: 0, y: 33, width: 740, height: 949))
            XCTAssertEqual(other.rects[wide], CGRect(x: 672, y: 33, width: 840, height: 949))
        }
        guard case .fits(let short) = Planner.fit(row, in: screen, constraints: constraints, options: options, maximums: [capped: CGSize(width: 740, height: 500)]) else { return XCTFail() }
        XCTAssertEqual(short.rects[capped], CGRect(x: 772, y: 33, width: 740, height: 500))
    }

    /// Nothing jumps at the edge of fitting: one point short looks like the tiles.
    func testARowOnePointShortOfFittingLooksLikeItsTiles() {
        let a = WindowID(1), b = WindowID(2)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        func known(_ width: Double) -> [WindowID: SizeKnowledge] {
            [a: .known(CGSize(width: 840, height: 400)), b: .known(CGSize(width: width, height: 400))]
        }
        guard case .fits(let tiles) = Planner.fit(layout, in: screen, constraints: known(672)) else { return XCTFail() }
        XCTAssertFalse(tiles.folded)
        XCTAssertEqual(tiles.rects[a], CGRect(x: 0, y: 0, width: 840, height: 949))
        XCTAssertEqual(tiles.rects[b], CGRect(x: 840, y: 0, width: 672, height: 949))
        guard case .fits(let short) = Planner.fit(layout, in: screen, constraints: known(673)) else { return XCTFail() }
        XCTAssertTrue(short.folded)
        XCTAssertEqual(short.rects[a], CGRect(x: 0, y: 0, width: 840, height: 949))
        XCTAssertEqual(short.rects[b], CGRect(x: 839, y: 0, width: 673, height: 949))
    }

    /// The shortage is split evenly over the joints, in whole points, and no frame depends on focus.
    func testTheShortageIsSplitEvenlyOverTheJoints() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let three = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let constraints = [a: SizeKnowledge.known(CGSize(width: 840, height: 400)), b: .known(CGSize(width: 800, height: 400)), c: .known(CGSize(width: 740, height: 400))]
        for focused in [a, b, c, nil] {
            guard case .fits(let plan) = Planner.fit(three, in: screen, constraints: constraints, maximums: [c: CGSize(width: 740, height: 0)], focused: focused) else { return XCTFail() }
            XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 840, height: 949))
            XCTAssertEqual(plan.rects[b], CGRect(x: 406, y: 0, width: 800, height: 949))
            XCTAssertEqual(plan.rects[c], CGRect(x: 772, y: 0, width: 740, height: 949))
        }
        // 889 points do not divide by three joints.
        let four = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c), .leaf(d)], ratios: [0.25, 0.25, 0.25, 0.25]))
        let uneven = [a: SizeKnowledge.known(CGSize(width: 600, height: 400)), b: .known(CGSize(width: 600, height: 400)), c: .known(CGSize(width: 600, height: 400)), d: .known(CGSize(width: 601, height: 400))]
        guard case .fits(let plan) = Planner.fit(four, in: screen, constraints: uneven) else { return XCTFail() }
        XCTAssertEqual([a, b, c, d].map { plan.rects[$0]?.minX }, [0, 304, 607, 911])
        XCTAssertEqual(plan.rects[d]?.maxX, 1512)
    }

    /// A short window beside long ones cannot share the shortage evenly, so a window between the ends stays inside their strips.
    func testAWindowBetweenTheEndsStaysInsideTheirStrips() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        func starts(_ widths: [Double]) -> [CGFloat?] {
            let constraints = Dictionary(uniqueKeysWithValues: zip([a, b, c], widths).map { ($0, SizeKnowledge.known(CGSize(width: $1, height: 400))) })
            guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints) else { return [] }
            return [a, b, c].map { plan.rects[$0]?.minX }
        }
        XCTAssertEqual(starts([400, 1000, 1000]), [0, 30, 512], "evenly it would start at -44, past the left edge")
        XCTAssertEqual(starts([1000, 1000, 400]), [0, 482, 1112], "evenly it would end at 1556, past the right edge")
    }

    /// Whatever the lengths, every frame stays in the area, and the first and last windows always show a strip.
    func testEveryFrameOfARowThatDoesNotFitStaysInTheArea() {
        let screen = CGRect(x: 100, y: 50, width: 1512, height: 949)
        let widths: [Double] = [230, 400, 740, 1000, 1400]
        var rows: [[Double]] = []
        for x in widths {
            for y in widths {
                for z in widths {
                    rows.append([x, y, z])
                    for w in widths { rows.append([x, y, z, w]) }
                }
            }
        }
        for row in rows {
            let ids = row.indices.map { WindowID(UInt32($0 + 1)) }
            let constraints = Dictionary(uniqueKeysWithValues: zip(ids, row).map { ($0, SizeKnowledge.known(CGSize(width: $1, height: 400))) })
            guard case .fits(let plan) = Planner.fit(Planner.rowLayout(ids, rows: 1), in: screen, constraints: constraints) else { return XCTFail("\(row)") }
            for id in ids {
                let frame = plan.rects[id]!
                XCTAssertTrue(screen.contains(frame), "\(row): \(frame)")
                XCTAssertEqual(frame, frame.integral, "\(row)")
            }
            guard plan.folded else { continue }
            let first = plan.rects[ids[0]]!, last = plan.rects[ids[ids.count - 1]]!
            XCTAssertEqual(first.minX, screen.minX, "\(row)")
            XCTAssertEqual(last.maxX, screen.maxX, "\(row)")
            for id in ids.dropFirst() { XCTAssertGreaterThanOrEqual(plan.rects[id]!.minX, screen.minX + 30, "\(row)") }
            for id in ids.dropLast() { XCTAssertLessThanOrEqual(plan.rects[id]!.maxX, screen.maxX - 30, "\(row)") }
        }
    }

    /// A child fits if it fits in its room, as in a real accordion: two windows in an accordion need less than the two strips its minimum counts.
    func testARealAccordionInARowThatDoesNotFitFitsInItsRoom() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 930, height: 400)), b: .known(CGSize(width: 930, height: 400)), c: .known(CGSize(width: 400, height: 400))]
        let stack = LayoutNode.accordion(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5])
        let row = Layout(root: .split(.horizontal, children: [stack, .leaf(c)], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(row, in: screen, constraints: constraints, focused: a) else { return XCTFail("970 holds an accordion of two 930s with their strips") }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 940, height: 600))
        XCTAssertEqual(plan.rects[b], CGRect(x: 30, y: 0, width: 940, height: 600))
        XCTAssertEqual(plan.rects[c], CGRect(x: 600, y: 0, width: 400, height: 600))
    }

    /// Lengths are rounded down, so a minimum counts in whole points: 100.8 is not left with 100, which fitting would refuse.
    func testAFractionalMinimumFitsWhereItsWholePointsDo() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)
        let area = CGRect(x: 0, y: 0, width: 400, height: 600)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 100.8, height: 200)), b: .known(CGSize(width: 100.8, height: 200))]
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.2, 0.8]))
        guard case .fits(let plan) = Planner.fit(row, in: area, constraints: constraints) else { return XCTFail("a tile pinned to its minimum fits") }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 101, height: 600))
        XCTAssertEqual(plan.rects[b], CGRect(x: 101, y: 0, width: 299, height: 600))
        // Half a point below a whole point still counts as that point: fitting allows it.
        guard case .fits(let half) = Planner.fit(Layout(root: .leaf(a)), in: CGRect(x: 0, y: 0, width: 1055, height: 600), constraints: [a: .known(CGSize(width: 1055.5, height: 200))]) else { return XCTFail() }
        XCTAssertEqual(half.rects[a]?.width, 1055)
        // A fixed window with a fractional width keeps its whole points, whatever its share.
        guard case .fits(let fixed) = Planner.fit(row, in: area, constraints: constraints, maximums: [a: CGSize(width: 100.8, height: 0)]) else { return XCTFail() }
        XCTAssertEqual(fixed.rects[a]?.width, 101)

        // In a row that does not fit, the children of a child get whole points too.
        let inner = LayoutNode.split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.2, 0.8])
        let column = LayoutNode.split(.vertical, children: [inner, .leaf(d)], ratios: [0.5, 0.5])
        let nested = Layout(root: .split(.horizontal, children: [column, .leaf(c)], ratios: [0.5, 0.5]))
        let tight = [a: SizeKnowledge.known(CGSize(width: 100.8, height: 200)), b: .known(CGSize(width: 100.8, height: 200)),
                     d: .known(CGSize(width: 120, height: 200)), c: .known(CGSize(width: 900, height: 200))]
        guard case .fits(let folded) = Planner.fit(nested, in: CGRect(x: 0, y: 0, width: 1000, height: 600), constraints: tight) else { return XCTFail("expected the nested layout to fit folded") }
        XCTAssertEqual(folded.rects[a]?.width, 101)
        XCTAssertEqual(folded.rects[c], CGRect(x: 100, y: 0, width: 900, height: 600))
    }

    /// A small or unknown minimum does not make a window that narrow: it gets the preferred length, up to its cap and the room it has.
    func testASmallWindowInARowThatDoesNotFitGetsThePreferredLength() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let wide = [a: SizeKnowledge.known(CGSize(width: 1000, height: 400)), c: .known(CGSize(width: 800, height: 400))]
        var small = wide
        small[b] = .known(CGSize(width: 300, height: 400))
        for constraints in [small, wide] {
            guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints) else { return XCTFail() }
            XCTAssertEqual(plan.rects[b], CGRect(x: 656, y: 0, width: 400, height: 949))
            XCTAssertEqual(plan.rects[c], CGRect(x: 712, y: 0, width: 800, height: 949))
        }
        guard case .fits(let capped) = Planner.fit(layout, in: screen, constraints: wide, maximums: [b: CGSize(width: 230, height: 0)]) else { return XCTFail() }
        XCTAssertEqual(capped.rects[b]?.width, 230)

        let pair = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(c)], ratios: [0.5, 0.5]))
        let huge = PlannerOptions(preferredMinimum: CGSize(width: 100000, height: 100000))
        guard case .fits(let plan) = Planner.fit(pair, in: screen, constraints: wide, options: huge) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 1482, height: 949))
        XCTAssertEqual(plan.rects[c], CGRect(x: 30, y: 0, width: 1482, height: 949))
    }

    /// The same acceptance as a real accordion: the first and last windows leave one strip, any other two.
    func testARowFitsWhileEveryWindowLeavesItsStrips() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        func known(_ widths: [WindowID: Double]) -> [WindowID: SizeKnowledge] { widths.mapValues { .known(CGSize(width: $0, height: 400)) } }
        let pair = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(pair, in: screen, constraints: known([a: 1482, b: 1482])) else { return XCTFail() }
        XCTAssertEqual(plan.rects[b], CGRect(x: 30, y: 0, width: 1482, height: 949))
        guard case .unfit(let unfit) = Planner.fit(pair, in: screen, constraints: known([a: 1483, b: 400])) else { return XCTFail() }
        XCTAssertEqual(Set(unfit.offending), [a, b])

        let three = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        guard case .fits(let middle) = Planner.fit(three, in: screen, constraints: known([a: 400, b: 1452, c: 400])) else { return XCTFail() }
        XCTAssertEqual(middle.rects[b], CGRect(x: 30, y: 0, width: 1452, height: 949))
        guard case .unfit(let wide) = Planner.fit(three, in: screen, constraints: known([a: 400, b: 1453, c: 400])) else { return XCTFail() }
        XCTAssertEqual(Set(wide.offending), [a, b, c])

        let plain = PlannerOptions(accordionPadding: 0)
        guard case .fits(let full) = Planner.fit(pair, in: screen, constraints: known([a: 1512, b: 1512]), options: plain) else { return XCTFail() }
        XCTAssertEqual(full.rects[b], CGRect(x: 0, y: 0, width: 1512, height: 949))
    }

    /// A column overlaps the same way, and a capped width is centered as between tiles.
    func testAColumnThatDoesNotFitOverlapsOnlyByWhatItLacks() {
        let a = WindowID(1), b = WindowID(2)
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 500, height: 600)), b: .known(CGSize(width: 500, height: 600))]
        let column = Layout(root: .split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(column, in: screen, constraints: constraints, maximums: [b: CGSize(width: 700, height: 0)]) else { return XCTFail() }
        XCTAssertTrue(plan.folded)
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 33, width: 1512, height: 600))
        XCTAssertEqual(plan.rects[b], CGRect(x: 406, y: 382, width: 700, height: 600))
    }

    /// Gaps give way before windows overlap.
    func testGapsGiveWayInARowThatDoesNotFit() {
        let a = WindowID(1), b = WindowID(2)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 756, height: 400)), b: .known(CGSize(width: 756, height: 400))]
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(row, in: screen, constraints: constraints, options: PlannerOptions(gap: 8)) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 756, height: 949))
        XCTAssertEqual(plan.rects[b], CGRect(x: 756, y: 0, width: 756, height: 949))
    }

    /// Each split decides for itself: a row beside a column, both short.
    func testNestedSplitsThatDoNotFitEachOverlapByWhatTheyLack() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 840, height: 400)),
                           b: SizeKnowledge.known(CGSize(width: 740, height: 500)),
                           c: SizeKnowledge.known(CGSize(width: 740, height: 500))]
        let column = LayoutNode.split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])
        let layout = Layout(root: .split(.horizontal, children: [.leaf(a), column], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 840, height: 900))
        XCTAssertEqual(plan.rects[b], CGRect(x: 760, y: 0, width: 740, height: 500))
        XCTAssertEqual(plan.rects[c], CGRect(x: 760, y: 400, width: 740, height: 500))
    }

    /// A capped window in a real accordion keeps its strip's edge: the right edge when it is behind, whoever has focus, in a pair.
    func testCappedLastWindowOfAnAccordionKeepsItsTrailingEdge() {
        let wide = WindowID(1), capped = WindowID(2)
        let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let maximums = [capped: CGSize(width: 740, height: 0)]
        let options = PlannerOptions(accordionPadding: 30)
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(wide), .leaf(capped)], ratios: [0.5, 0.5]))
        for focused in [wide, capped] {
            guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: [:], options: options, maximums: maximums, focused: focused) else { return XCTFail() }
            XCTAssertEqual(plan.rects[wide], CGRect(x: 0, y: 33, width: 1482, height: 949))
            XCTAssertEqual(plan.rects[capped], CGRect(x: 772, y: 33, width: 740, height: 949), "30 points show to the right of the wide window")
        }
        let swapped = Layout(root: .accordion(.horizontal, children: [.leaf(capped), .leaf(wide)], ratios: [0.5, 0.5]))
        for focused in [wide, capped] {
            guard case .fits(let plan) = Planner.fit(swapped, in: screen, constraints: [:], options: options, maximums: maximums, focused: focused) else { return XCTFail() }
            XCTAssertEqual(plan.rects[capped], CGRect(x: 0, y: 33, width: 740, height: 949))
            XCTAssertEqual(plan.rects[wide], CGRect(x: 30, y: 33, width: 1482, height: 949))
        }
    }

    /// A capped middle window follows its strip as focus moves past it.
    func testCappedMiddleWindowOfAnAccordionFollowsItsStrip() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let maximums = [b: CGSize(width: 700, height: 0)]
        let options = PlannerOptions(accordionPadding: 30)
        func frame(focused: WindowID) -> CGRect? {
            guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: [:], options: options, maximums: maximums, focused: focused) else { return nil }
            return plan.rects[b]
        }
        XCTAssertEqual(frame(focused: a), CGRect(x: 800, y: 0, width: 700, height: 900), "its strip is on the right")
        XCTAssertEqual(frame(focused: c), CGRect(x: 0, y: 0, width: 700, height: 900), "its strip is on the left")
        XCTAssertEqual(frame(focused: b), CGRect(x: 30, y: 0, width: 700, height: 900), "in front, it has no strip to keep")
    }

    /// Everything inside a child on the trailing side keeps the trailing edge, and a vertical accordion does the same with height.
    func testCappedWindowsKeepTheTrailingEdgeInsideChildrenAndAlongTheHeight() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let options = PlannerOptions(accordionPadding: 30)

        let stacked = Layout(root: .accordion(.horizontal, children: [.leaf(a), .split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])], ratios: [0.5, 0.5]))
        let narrow = [b: CGSize(width: 600, height: 0), c: CGSize(width: 500, height: 0)]
        guard case .fits(let column) = Planner.fit(stacked, in: screen, constraints: [:], options: options, maximums: narrow, focused: a) else { return XCTFail() }
        XCTAssertEqual(column.rects[b]?.maxX, 1500)
        XCTAssertEqual(column.rects[c]?.maxX, 1500)

        let row = Layout(root: .accordion(.horizontal, children: [.leaf(a), .split(.horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])], ratios: [0.5, 0.5]))
        let narrowRow = [b: CGSize(width: 300, height: 0), c: CGSize(width: 200, height: 0)]
        guard case .fits(let packed) = Planner.fit(row, in: screen, constraints: [:], options: options, maximums: narrowRow, focused: a) else { return XCTFail() }
        XCTAssertEqual(packed.rects[c]?.maxX, 1500, "the row's unused width is on the leading side")
        XCTAssertEqual(packed.rects[b]?.maxX, packed.rects[c]?.minX)

        let vertical = Layout(root: .accordion(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        let short = [a: CGSize(width: 0, height: 400), b: CGSize(width: 800, height: 400)]
        guard case .fits(let plan) = Planner.fit(vertical, in: screen, constraints: [:], options: options, maximums: short, focused: a) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 1500, height: 400), "its strip is at the top")
        XCTAssertEqual(plan.rects[b], CGRect(x: 0, y: 500, width: 800, height: 400), "its strip is at the bottom; its width stays at the leading edge")
    }

    /// A column that does not fit inside an accordion decides its own axis and keeps the accordion's edge across it, or the wide window would cover both.
    func testCappedWindowsInAColumnInsideAnAccordionKeepTheStripEdge() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let options = PlannerOptions(accordionPadding: 30)
        let constraints = [a: SizeKnowledge.known(CGSize(width: 840, height: 400)),
                           b: SizeKnowledge.known(CGSize(width: 740, height: 500)),
                           c: SizeKnowledge.known(CGSize(width: 740, height: 500))]
        let maximums = [b: CGSize(width: 740, height: 0), c: CGSize(width: 740, height: 0)]
        let column = LayoutNode.split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])

        let trailing = Layout(root: .accordion(.horizontal, children: [.leaf(a), column], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(trailing, in: screen, constraints: constraints, options: options, maximums: maximums, focused: a) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 0, width: 1470, height: 900))
        XCTAssertEqual(plan.rects[b], CGRect(x: 760, y: 0, width: 740, height: 500))
        XCTAssertEqual(plan.rects[c], CGRect(x: 760, y: 400, width: 740, height: 500))

        let leading = Layout(root: .accordion(.horizontal, children: [column, .leaf(a)], ratios: [0.5, 0.5]))
        guard case .fits(let other) = Planner.fit(leading, in: screen, constraints: constraints, options: options, maximums: maximums, focused: a) else { return XCTFail() }
        XCTAssertEqual(other.rects[b]?.minX, 0)
        XCTAssertEqual(other.rects[c]?.minX, 0)

        // Alone, the column is a tile: capped widths are centered.
        guard case .fits(let alone) = Planner.fit(Layout(root: column), in: screen, constraints: constraints, options: options, maximums: maximums, focused: b) else { return XCTFail() }
        XCTAssertEqual(alone.rects[b]?.minX, 380)
        XCTAssertEqual(alone.rects[c]?.minX, 380)
    }

    /// Without strips there is no edge to keep.
    func testCappedWindowsInAnAccordionWithoutStripsKeepTheLeadingEdge() {
        let a = WindowID(1), b = WindowID(2)
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        let maximums = [b: CGSize(width: 700, height: 0)]
        guard case .fits(let plan) = Planner.fit(layout, in: CGRect(x: 0, y: 0, width: 1500, height: 900), constraints: [:], options: PlannerOptions(accordionPadding: 0), maximums: maximums, focused: a) else { return XCTFail() }
        XCTAssertEqual(plan.rects[b]?.minX, 0)
    }

    func testAccordionFitsWhenTiledMinimumsWouldNot() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        var constraints: [WindowID: SizeKnowledge] = [:]
        for id in [a, b, c] { constraints[id] = .known(CGSize(width: 400, height: 300)) }
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let screen = CGRect(x: 0, y: 0, width: 500, height: 400)
        guard case .fits(let plan) = Planner.fit(layout, in: screen, constraints: constraints, options: PlannerOptions(accordionPadding: 30), focused: b) else {
            return XCTFail("requires only the largest minimum width plus the strip")
        }
        XCTAssertEqual(plan.rects[b]?.width, 440)
        let packed = layout.packing(rects: plan.rects, shape: plan.shape)
        XCTAssertTrue(packed.leftoverHeights.isEmpty)
        guard case .accordion = packed.root else { return XCTFail() }
    }

    func testInnerGapsFollowTheSplitAxisAndOuterInsetsTheArea() {
        let a = WindowID(1), b = WindowID(2)
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let gapped = PlannerOptions(gap: 20, unknownFloor: CGSize(width: 50, height: 50))
        guard case .fits(let side) = Planner.fit(row, in: screen, constraints: [:], options: gapped) else { return XCTFail() }
        XCTAssertEqual(side.rects[a], CGRect(x: 0, y: 0, width: 490, height: 400))
        XCTAssertEqual(side.rects[b], CGRect(x: 510, y: 0, width: 490, height: 400))

        let column = Layout(root: .split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        let vertical = PlannerOptions(gap: 0, unknownFloor: CGSize(width: 50, height: 50), gapVertical: 30)
        guard case .fits(let stacked) = Planner.fit(column, in: screen, constraints: [:], options: vertical) else { return XCTFail() }
        XCTAssertEqual(stacked.rects[a], CGRect(x: 0, y: 0, width: 1000, height: 185))
        XCTAssertEqual(stacked.rects[b], CGRect(x: 0, y: 215, width: 1000, height: 185))

        let inset = PlannerOptions(gap: 0, unknownFloor: CGSize(width: 50, height: 50), outerLeft: 10, outerTop: 10, outerRight: 10, outerBottom: 10)
        guard case .fits(let padded) = Planner.fit(row, in: screen, constraints: [:], options: inset) else { return XCTFail() }
        XCTAssertEqual(padded.rects[a], CGRect(x: 10, y: 10, width: 490, height: 380))
        XCTAssertEqual(padded.rects[b], CGRect(x: 500, y: 10, width: 490, height: 380))
    }

    func testDamagedSavedLayoutDecodesWithoutTrapping() throws {
        let saved = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
                           leftoverHeights: [WindowID(1): 200])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var root = try XCTUnwrap(json["root"] as? [String: Any])
        let entry = try XCTUnwrap((json["leftoverHeights"] as? [[String: Any]])?.first)
        root["ratios"] = [1]
        json["root"] = root
        json["leftoverHeights"] = [entry, entry.merging(["height": 300]) { $1 }]
        let layout = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(layout.root?.box?.ratios, [0.5, 0.5])
        XCTAssertEqual(layout.leftoverHeights, [WindowID(1): 200])
        root["children"] = []
        root["ratios"] = []
        json["root"] = root
        XCTAssertThrowsError(try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
