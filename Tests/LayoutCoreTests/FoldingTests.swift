import CoreGraphics
import XCTest
@testable import LayoutCore

/// A tiled split whose windows do not fit side by side overlaps by what it lacks, without changing the layout intent.
final class FoldingTests: XCTestCase {
    /// A laptop-sized work area.
    let laptop = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4), e = WindowID(5)
    let options = PlannerOptions(unknownFloor: CGSize(width: 120, height: 120), accordionPadding: 30)

    func widths(_ pairs: [(WindowID, Double)], height: Double = 200) -> [WindowID: SizeKnowledge] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, SizeKnowledge.known(CGSize(width: $0.1, height: height))) })
    }

    func testARowThatDoesNotFitOverlapsAndKeepsItsIntent() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.6, 0.4]))
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 1000)]), options: options, focused: b) else {
            return XCTFail("840 + 1000 does not fit 1512 side by side, but fits folded")
        }
        XCTAssertEqual(plan.rects[a], CGRect(x: 0, y: 33, width: 840, height: 949))
        XCTAssertEqual(plan.rects[b], CGRect(x: 512, y: 33, width: 1000, height: 949))
        XCTAssertEqual(plan.layout, row, "the intent keeps the split and its ratios")
        XCTAssertEqual(plan.shape.root, .accordion(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.6, 0.4]))
    }

    func testTheSameRowIsTiledAgainWithItsRatiosOnceItFits() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.6, 0.4]))
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 600)]), options: options, focused: b) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]?.width, 907)
        XCTAssertEqual(plan.rects[b]?.minX, 907)
        XCTAssertEqual(plan.shape, row)
        guard case .fits(let wide) = Planner.fit(row, in: CGRect(x: 0, y: 25, width: 2560, height: 1415), constraints: widths([(a, 840), (b, 1000)]), options: options) else { return XCTFail() }
        XCTAssertEqual(wide.shape, row, "a wider display tiles the same windows")
    }

    func testOnlyTheRowThatDoesNotFitFolds() {
        let layout = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .split(.horizontal, children: [.leaf(c), .leaf(d)], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: laptop, constraints: widths([(a, 900), (b, 900), (c, 500), (d, 500)]), options: options, focused: a) else { return XCTFail() }
        XCTAssertEqual(plan.shape.root, .split(.vertical, children: [
            .accordion(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .split(.horizontal, children: [.leaf(c), .leaf(d)], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
        XCTAssertEqual(plan.rects[c], CGRect(x: 0, y: 507, width: 756, height: 475))
        XCTAssertEqual(plan.layout, layout)
    }

    /// The parent plans with the folded need, so a row that folds does not make its parent fold too.
    func testTheFoldedNeedFeedsTheParent() {
        let layout = Layout(root: .split(.horizontal, children: [
            .split(.vertical, children: [.split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]), .leaf(e)], ratios: [0.5, 0.5]),
            .leaf(d),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: laptop, constraints: widths([(a, 700), (b, 700), (e, 120), (d, 400)]), options: options, focused: a) else {
            return XCTFail("the folded row needs 760, which fits beside 400")
        }
        guard case .split(.horizontal, let children, _)? = plan.shape.root else { return XCTFail("the root stays tiled") }
        guard case .split(.vertical, let column, _) = children[0], case .accordion = column[0] else { return XCTFail("the inner row folds") }
        XCTAssertEqual(plan.rects[d]?.minX, 760)
        XCTAssertEqual(plan.rects[a]?.width, 700)
        XCTAssertEqual(plan.rects[b]?.minX, 60)
    }

    func testAWindowWiderThanItsStripAreaStillDoesNotFit() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        guard case .unfit(let unfit) = Planner.fit(row, in: laptop, constraints: widths([(a, 1500), (b, 400)]), options: options, focused: b) else {
            return XCTFail("1500 is wider than the 1482 a folded window gets")
        }
        XCTAssertEqual(Set(unfit.offending), [a, b], "the row's members overflow, as without folding, so relief picks among them")
    }

    func testFoldingIsOffWhenTheOptionsSaySo() {
        var unfolded = options
        unfolded.folds = false
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        guard case .unfit(let unfit) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 1000)]), options: unfolded) else { return XCTFail() }
        XCTAssertEqual(Set(unfit.offending), [a, b])
        XCTAssertEqual(Planner.minimumSize(of: row, constraints: widths([(a, 840), (b, 1000)]), options: unfolded).width, 1840)
        XCTAssertEqual(Planner.minimumSize(of: row, constraints: widths([(a, 840), (b, 1000)]), options: options).width, 1060)
    }

    // MARK: Initial layout

    func testInitialPrefersComfortableRowsOverFolding() {
        guard case .fits(let plan) = Planner.initial(for: [a, b], in: laptop, constraints: widths([(a, 900), (b, 900)]), options: options) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 2)
        XCTAssertFalse(plan.shape.root?.containsAccordion() ?? true)
    }

    func testInitialPrefersOneFoldedRowOverUncomfortableRows() {
        var tall = options
        tall.preferredMinimum = CGSize(width: 400, height: 400)
        guard case .fits(let plan) = Planner.initial(for: [a, b, c], in: laptop, constraints: widths([(a, 840), (b, 800), (c, 1000)]), options: tall) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.shape.root, .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
    }

    func testInitialFallsBackToUncomfortableRowsWhenOneFoldedRowDoesNotFit() {
        var tall = options
        tall.preferredMinimum = CGSize(width: 400, height: 500)
        guard case .fits(let plan) = Planner.initial(for: [a, b], in: laptop, constraints: widths([(a, 1500), (b, 1500)]), options: tall) else { return XCTFail() }
        XCTAssertEqual(plan.rows, 2)
    }

    // MARK: Consumers of the shape

    func testPackingKeepsTheRatiosOfAFoldedSplit() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.6, 0.4]))
        let constraints = widths([(a, 840), (b, 1000)])
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: constraints, options: options, maximums: [a: CGSize(width: 0, height: 500)], focused: b) else { return XCTFail() }
        let packed = row.packing(rects: plan.rects, shape: plan.shape)
        XCTAssertEqual(packed.root, row.root)
        XCTAssertTrue(packed.leftoverHeights.isEmpty, "overlapping strips are not free height")
    }

    func testNeighborsInsideAFoldComeFromTheTree() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 800), (c, 1000)]), options: options, focused: b) else { return XCTFail() }
        XCTAssertEqual(LayoutEdit.neighbor(of: b, direction: .right, rects: plan.rects, layout: plan.shape), c)
        XCTAssertEqual(LayoutEdit.neighbor(of: b, direction: .left, rects: plan.rects, layout: plan.shape), a)
    }

    func testNoAccordionMemberHostsAStack() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        let caps = [a: CGSize(width: 0, height: 400)]
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 1000)]), options: options, maximums: caps, focused: a) else { return XCTFail() }
        XCTAssertNil(plan.shape.unusedStackHost(rects: plan.rects, area: laptop, need: CGSize(width: 400, height: 300)),
                     "the space below a short window in a fold can be covered by its sibling")
    }

    func testMouseEditsInsideAFold() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 800), (c, 1000)]), options: options, focused: b) else { return XCTFail() }
        let planned = plan.rects[b]!
        // Dragged a little: its center is still over its own frame, though its neighbors overlap it, so it goes back.
        let nudged = planned.offsetBy(dx: 80, dy: 40)
        XCTAssertEqual(ManualEdit.detect(id: b, planned: planned, actual: nudged, layout: row, shape: plan.shape, plannedRects: plan.rects), .float(b))
        // Made narrower from its right edge, along the accordion's axis: no ratio changes.
        var narrower = planned
        narrower.size.width -= 200
        XCTAssertNil(ManualEdit.detect(id: b, planned: planned, actual: narrower, layout: row, shape: plan.shape, plannedRects: plan.rects))
        // Dragged off the layout's area entirely: float, as for tiles.
        XCTAssertEqual(ManualEdit.detect(id: b, planned: planned, actual: planned.offsetBy(dx: 0, dy: 2000), layout: row, shape: plan.shape, plannedRects: plan.rects), .float(b))
    }

    /// Across the fold's axis the row is an ordinary child of its column, so a height change edits the column as between tiles.
    func testAResizeAcrossAFoldEditsItsColumn() {
        let column = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]),
            .leaf(d),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(column, in: laptop, constraints: widths([(a, 840), (b, 800), (c, 1000), (d, 400)]), options: options, focused: b) else { return XCTFail() }
        guard case .split(.vertical, let children, _)? = plan.shape.root, case .accordion? = children.first else { return XCTFail("the top row folds") }
        let planned = plan.rects[b]!
        var taller = planned
        taller.size.height += 100
        guard case .resize(let id, let changes)? = ManualEdit.detect(id: b, planned: planned, actual: taller, layout: column, shape: plan.shape, plannedRects: plan.rects) else {
            return XCTFail("a height change across the fold is a resize")
        }
        XCTAssertEqual(id, b)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, .vertical)
        XCTAssertEqual(changes.first?.2, .down)
        XCTAssertEqual(changes.first?.1 ?? 0, 100 / laptop.height, accuracy: 0.01)
    }

    /// Of the windows under a dropped window's center, the nearest is the target, once that center has left the window's own frame.
    func testADropInAFoldTakesTheNearestWindow() {
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        guard case .fits(let plan) = Planner.fit(row, in: laptop, constraints: widths([(a, 840), (b, 800), (c, 740)]), options: options, focused: c) else { return XCTFail() }
        let planned = plan.rects[c]!
        XCTAssertEqual(planned, CGRect(x: 772, y: 33, width: 740, height: 949))
        func dropped(centerX: Double) -> ManualEdit? {
            ManualEdit.detect(id: c, planned: planned, actual: planned.offsetBy(dx: centerX - planned.midX, dy: 0), layout: row, shape: plan.shape, plannedRects: plan.rects)
        }
        XCTAssertEqual(dropped(centerX: 800), .float(c), "still over its own frame")
        XCTAssertEqual(dropped(centerX: 700), .dropOnto(c, b), "over both; the middle window's center is nearer")
        XCTAssertEqual(dropped(centerX: 500), .dropOnto(c, a), "over both; the first window's center is nearer")
        XCTAssertEqual(dropped(centerX: 100), .dropOnto(c, a))
    }

    /// A real accordion under a dropped window counts once, by its first window in the tree.
    func testADropOntoARealAccordionTakesItsFirstWindow() {
        let layout = Layout(root: .split(.vertical, children: [
            .accordion(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .leaf(c),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: laptop, constraints: [:], options: options, focused: c) else { return XCTFail() }
        let planned = plan.rects[c]!
        let center = CGPoint(x: 1300, y: plan.rects[a]!.midY)
        let moved = planned.offsetBy(dx: center.x - planned.midX, dy: center.y - planned.midY)
        XCTAssertEqual(ManualEdit.detect(id: c, planned: planned, actual: moved, layout: layout, shape: plan.shape, plannedRects: plan.rects), .dropOnto(c, a))
    }

    func testADropOnTheMiddleOfAnotherFoldPicksOneTargetEveryTime() {
        let layout = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .leaf(c),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: laptop, constraints: widths([(a, 900), (b, 900), (c, 200)]), options: options, focused: c) else { return XCTFail() }
        let planned = plan.rects[c]!
        // Dropped with its center exactly between the centers of a and b: the first of them in the tree is the target.
        let center = CGPoint(x: 756, y: 33 + 237)
        let moved = CGRect(x: center.x - planned.width / 2, y: center.y - planned.height / 2, width: planned.width, height: planned.height)
        for _ in 0..<20 {
            XCTAssertEqual(ManualEdit.detect(id: c, planned: planned, actual: moved, layout: layout, shape: plan.shape, plannedRects: plan.rects), .dropOnto(c, a))
        }
    }
}
