import CoreGraphics
import XCTest
@testable import LayoutCore

final class LayoutEditTests: XCTestCase {
    let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)
    let area = CGRect(x: 0, y: 30, width: 1920, height: 1050)

    var row: Layout { Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3])) }
    var grid: Layout {
        Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .split(.horizontal, children: [.leaf(c), .leaf(d)], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
    }

    func rects(_ l: Layout) -> [WindowID: CGRect] {
        guard case .fits(let p) = Planner.fit(l, in: area, constraints: [:], options: PlannerOptions(unknownFloor: .zero)) else { XCTFail(); return [:] }
        return p.rects
    }

    func testNeighborByGeometry() {
        let r = rects(grid)
        XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .right, rects: r), b)
        XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .down, rects: r), c)
        XCTAssertEqual(LayoutEdit.neighbor(of: d, direction: .up, rects: r), b)
        XCTAssertEqual(LayoutEdit.neighbor(of: d, direction: .left, rects: r), c)
        XCTAssertNil(LayoutEdit.neighbor(of: a, direction: .left, rects: r))
        XCTAssertNil(LayoutEdit.neighbor(of: a, direction: .up, rects: r))
    }

    func testNeighborPrefersLargestOverlapAmongAdjacent() {
        // One window on the left, two stacked on the right. Right of the top-left window is the upper one.
        let l = Layout(root: .split(.horizontal, children: [.leaf(a), .split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.7, 0.3])], ratios: [0.5, 0.5]))
        let r = rects(l)
        XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .right, rects: r), b)
        XCTAssertEqual(LayoutEdit.neighbor(of: c, direction: .left, rects: r), a)
    }

    func testNeighborTiesUseVisualOrderAndStableID() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = CGRect(x: 100, y: 0, width: 100, height: 50)
        let bottom = CGRect(x: 100, y: 50, width: 100, height: 50)
        // Even with the right side split evenly, dictionary order never changes the focus / swap target.
        for _ in 0..<100 {
            let r = Dictionary(uniqueKeysWithValues: [(a, origin), (c, top), (b, bottom)].shuffled())
            XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .right, rects: r), c)
            let overlapping = Dictionary(uniqueKeysWithValues: [(a, origin), (b, top), (c, top)].shuffled())
            XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .right, rects: overlapping), b)
        }
    }

    func testNeighborToleranceIsMeasuredFromNearestEdge() {
        for _ in 0..<100 {
            let r = Dictionary(uniqueKeysWithValues: [
                (a, CGRect(x: 0, y: 0, width: 100, height: 100)),
                (b, CGRect(x: 100, y: 0, width: 100, height: 20)),
                (c, CGRect(x: 101.5, y: 20, width: 100, height: 30)),
                (d, CGRect(x: 103, y: 50, width: 100, height: 50)),
            ].shuffled())
            XCTAssertEqual(LayoutEdit.neighbor(of: a, direction: .right, rects: r), c)
        }
    }

    func testSwapExchangesLeavesOnly() {
        let l = LayoutEdit.swap(a, c, in: row)
        XCTAssertEqual(l.root, .split(.horizontal, children: [.leaf(c), .leaf(b), .leaf(a)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        XCTAssertEqual(LayoutEdit.swap(a, WindowID(99), in: row), row)
    }

    func testSwapKeepsLeftoverHeightOnTheSameWindow() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]),
            leftoverHeights: [a: 440]
        )
        let swapped = LayoutEdit.swap(a, b, in: prior)
        XCTAssertEqual(swapped.leftoverHeights[a], 440)
        XCTAssertNil(swapped.leftoverHeights[b])
        guard case .fits(let plan) = Planner.fit(swapped, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]?.height, 440)
        XCTAssertEqual(plan.rects[b]?.height, 949)
        XCTAssertEqual(plan.rects[a]!.minX, 700, accuracy: 1)
        XCTAssertEqual(plan.rects[b]!.minX, 0, accuracy: 1)
    }

    func testMoveBesideNeighborInSameAxisSplitsItsShare() {
        // a moves right of c; c's 1/3 share is halved between them.
        let l = LayoutEdit.move(a, toward: c, direction: .right, in: row)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(b), .leaf(c), .leaf(a)])
        XCTAssertEqual(ratios[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 0.25, accuracy: 1e-9)
    }

    /// Moving a window to its adjacent sibling in the same split only changes the order: every window keeps its own share (AeroSpace move).
    func testMoveToAdjacentSiblingKeepsEveryShare() {
        let uneven = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.5, 0.3, 0.2]))
        let l = LayoutEdit.move(b, toward: c, direction: .right, in: uneven)
        XCTAssertEqual(l.root, .split(.horizontal, children: [.leaf(a), .leaf(c), .leaf(b)], ratios: [0.5, 0.2, 0.3]))
        XCTAssertEqual(LayoutEdit.move(b, toward: a, direction: .left, in: uneven).root,
                       .split(.horizontal, children: [.leaf(b), .leaf(a), .leaf(c)], ratios: [0.3, 0.5, 0.2]))
    }

    /// Moving up and down in a column and then switching the column to side by side keeps every window usable.
    /// Reinsertion used to halve a share on every move; the column's height caps hid the result until the orientation changed.
    func testMovesInAColumnDoNotShrinkWindowsThatDidNotMove() {
        var l = Layout(root: .split(.vertical, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.5, 0.3, 0.2]))
        for _ in 0..<3 {
            l = LayoutEdit.move(a, toward: l.windowIDs[l.windowIDs.firstIndex(of: a)! + 1], direction: .down, in: l)
            l = LayoutEdit.move(a, toward: l.windowIDs[l.windowIDs.firstIndex(of: a)! + 1], direction: .down, in: l)
            l = LayoutEdit.move(a, toward: l.windowIDs[l.windowIDs.firstIndex(of: a)! - 1], direction: .up, in: l)
            l = LayoutEdit.move(a, toward: l.windowIDs[l.windowIDs.firstIndex(of: a)! - 1], direction: .up, in: l)
        }
        let side = LayoutEdit.toggleOrientation(of: a, in: l)!
        guard case .split(.horizontal, let children, let ratios)? = side.root else { return XCTFail("\(String(describing: side.root))") }
        func share(_ id: WindowID) -> Double { zip(children, ratios).first { $0.0 == .leaf(id) }?.1 ?? 0 }
        XCTAssertEqual(share(a), 0.5, accuracy: 1e-9, "\(ratios)")
        XCTAssertEqual(share(b), 0.3, accuracy: 1e-9, "\(ratios)")
        XCTAssertEqual(share(c), 0.2, accuracy: 1e-9, "\(ratios)")
    }

    /// In a vertical move to an adjacent sibling, both windows drop their short height caps, as any vertical move does.
    func testVerticalMoveToAdjacentSiblingDropsBothHeightCaps() {
        let column = Layout(root: .split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]), leftoverHeights: [a: 200, b: 300])
        let l = LayoutEdit.move(a, toward: b, direction: .down, in: column)
        XCTAssertEqual(l.root, .split(.vertical, children: [.leaf(b), .leaf(a)], ratios: [0.5, 0.5]))
        XCTAssertNil(l.leftoverHeights[a])
        XCTAssertNil(l.leftoverHeights[b])
    }

    /// An accordion keeps being an accordion; only its order changes.
    func testMoveWithinAnAccordionKeepsTheAccordion() {
        let strip = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.4, 0.3, 0.3]))
        XCTAssertEqual(LayoutEdit.move(a, toward: b, direction: .right, in: strip).root,
                       .accordion(.horizontal, children: [.leaf(b), .leaf(a), .leaf(c)], ratios: [0.3, 0.4, 0.3]))
    }

    /// A neighbor inside a nested split (the stacked side of a T) is not a sibling: the window joins that split as before.
    func testMoveIntoTheStackOfATStillReinserts() {
        let t = Layout(root: .split(.horizontal, children: [.leaf(a), .split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])], ratios: [0.5, 0.5]))
        let l = LayoutEdit.move(a, toward: b, direction: .right, in: t)
        XCTAssertEqual(Set(l.windowIDs), [a, b, c])
        XCTAssertEqual(l.root, .split(.vertical, children: [.split(.horizontal, children: [.leaf(b), .leaf(a)], ratios: [0.5, 0.5]), .leaf(c)], ratios: [0.5, 0.5]),
                       "a joins b's place in the stack, as before")
    }

    /// A stack of three that left together (an app hidden, say) comes back as it was when all three return at once.
    func testWindowsThatLeftTogetherReturnTogether() {
        let home = Layout(root: .split(.horizontal, children: [
            .leaf(a), .split(.vertical, children: [.leaf(b), .leaf(c), .leaf(d)], ratios: [0.5, 0.3, 0.2]),
        ], ratios: [0.4, 0.6]))
        let alone = Layout(root: .leaf(a))
        XCTAssertEqual(alone.returning([b, c, d], home: home), home.normalized())
        XCTAssertNotEqual([b, c, d].reduce(alone) { $0.returning($1, home: home) }, home.normalized(), "one at a time cannot rebuild a stack of three")
        XCTAssertEqual(alone.returning([b, c], home: home).windowIDs.sorted(), [a, b, c], "a partial return still places every window")
    }

    func testMoveAcrossAxisCreatesNestedSplit() {
        // In the grid, a moves below c: the top row has only b, the bottom row has [c's place -> (c above / a below)] and d.
        let l = LayoutEdit.move(a, toward: c, direction: .down, in: grid)
        XCTAssertEqual(l.root, .split(.vertical, children: [
            .leaf(b),
            .split(.horizontal, children: [.split(.vertical, children: [.leaf(c), .leaf(a)], ratios: [0.5, 0.5]), .leaf(d)], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
    }

    func testMoveDownDropsLeftoverHeightSoTheWindowsShareTheColumn() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]),
            leftoverHeights: [a: 440]
        )
        let moved = LayoutEdit.move(a, toward: b, direction: .down, in: prior)
        XCTAssertNil(moved.leftoverHeights[a])
        XCTAssertNil(moved.leftoverHeights[b])
        guard case .fits(let plan) = Planner.fit(moved, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]!.height, 949 / 2, accuracy: 1)
        XCTAssertEqual(plan.rects[b]!.height, 949 / 2, accuracy: 1)
    }

    func testMoveRightKeepsLeftoverHeightOnTheSameWindow() {
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]),
            leftoverHeights: [a: 440]
        )
        let moved = LayoutEdit.move(a, toward: c, direction: .right, in: prior)
        XCTAssertEqual(moved.leftoverHeights[a], 440)
        XCTAssertNil(moved.leftoverHeights[b])
        XCTAssertNil(moved.leftoverHeights[c])
    }

    func testJoinNestsPerpendicular() {
        let l = LayoutEdit.join(b, with: a, direction: .left, in: row)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]), .leaf(c)])
        XCTAssertEqual(ratios[0], 0.5, accuracy: 1e-9)
    }

    func testJoinLeftDropsLeftoverHeightSoTheWindowsShareTheColumn() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]),
            leftoverHeights: [a: 440]
        )
        let joined = LayoutEdit.join(b, with: a, direction: .left, in: prior)
        XCTAssertNil(joined.leftoverHeights[a])
        XCTAssertNil(joined.leftoverHeights[b])
        guard case .split(.vertical, let children, let ratios)? = joined.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b)])
        XCTAssertEqual(ratios, [0.5, 0.5])
        guard case .fits(let plan) = Planner.fit(joined, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]!.height, 949 / 2, accuracy: 1)
        XCTAssertEqual(plan.rects[b]!.height, 949 / 2, accuracy: 1)
    }

    func testJoinDownKeepsLeftoverHeightBecauseTheSplitIsHorizontal() {
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [a: 440]
        )
        let joined = LayoutEdit.join(b, with: a, direction: .down, in: prior)
        XCTAssertEqual(joined.leftoverHeights[a], 440)
        XCTAssertNil(joined.leftoverHeights[b])
    }

    func testVerticalResizeDropsLeftoverHeightSoTheWindowCanGrow() {
        let work = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let prior = Layout(
            root: .split(.vertical, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [b: 400]
        )
        guard case .fits(let before) = Planner.fit(prior, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(before.rects[b]!.height, 400, accuracy: 1)
        let grown = LayoutEdit.resize(b, axis: .vertical, by: 0.1, in: prior)!
        XCTAssertNil(grown.leftoverHeights[a])
        XCTAssertNil(grown.leftoverHeights[b])
        guard case .fits(let after) = Planner.fit(grown, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(after.rects[b]!.height, 648, accuracy: 1)
    }

    func testHorizontalResizeKeepsLeftoverHeight() {
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [a: 440]
        )
        let grown = LayoutEdit.resize(a, axis: .horizontal, by: 0.1, in: prior)!
        XCTAssertEqual(grown.leftoverHeights[a], 440)
    }

    func testResizeTakesFromNextSiblingOrPrevious() {
        let grown = LayoutEdit.resize(a, axis: .horizontal, by: 0.1, in: row)!
        guard case .split(_, _, let r1)? = grown.root else { return XCTFail() }
        XCTAssertEqual(r1[0], 1.0 / 3 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(r1[1], 1.0 / 3 - 0.1, accuracy: 1e-9)
        let last = LayoutEdit.resize(c, axis: .horizontal, by: 0.1, in: row)!
        guard case .split(_, _, let r2)? = last.root else { return XCTFail() }
        XCTAssertEqual(r2[2], 1.0 / 3 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(r2[1], 1.0 / 3 - 0.1, accuracy: 1e-9)
    }

    func testLeftEdgeResizeChangesPreviousSibling() {
        let planned = rects(row)[b]!
        var actual = planned
        actual.origin.x -= 192
        actual.size.width += 192
        guard case .resize(_, let changes)? = ManualEdit.detect(id: b, planned: planned, actual: actual, layout: row, plannedRects: rects(row)) else { return XCTFail() }
        XCTAssertEqual(changes[0].2, .left)
        guard let edited = LayoutEdit.resize(b, axis: changes[0].0, by: changes[0].1, in: row, edge: changes[0].2) else { return XCTFail() }
        let after = rects(edited)
        XCTAssertEqual(after[b]!.minX, planned.minX - 192, accuracy: 1)
        XCTAssertEqual(after[c]!.minX, rects(row)[c]!.minX, accuracy: 1)
    }

    func testTopEdgeResizeChangesPreviousSibling() {
        let stack = Layout(root: .split(.vertical, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let before = rects(stack)
        var actual = before[b]!
        actual.origin.y -= 105
        actual.size.height += 105
        guard case .resize(_, let changes)? = ManualEdit.detect(id: b, planned: before[b]!, actual: actual,
                                                                layout: stack, plannedRects: before) else { return XCTFail() }
        XCTAssertEqual(changes[0].2, .up)
        guard let edited = LayoutEdit.resize(b, axis: changes[0].0, by: changes[0].1,
                                              in: stack, edge: changes[0].2) else { return XCTFail() }
        let after = rects(edited)
        XCTAssertEqual(after[b]!.minY, before[b]!.minY - 105, accuracy: 1)
        XCTAssertEqual(after[c]!.minY, before[c]!.minY, accuracy: 1)
    }

    func testResizeClampsAndFindsAncestorOfMatchingAxis() {
        // Resizing a in the grid vertically changes the row ratios.
        let l = LayoutEdit.resize(a, axis: .vertical, by: 0.2, in: grid)!
        guard case .split(.vertical, _, let r)? = l.root else { return XCTFail() }
        XCTAssertEqual(r, [0.7, 0.3])
        // A sibling never goes below 0.05.
        let clamped = LayoutEdit.resize(a, axis: .horizontal, by: 0.9, in: row)!
        guard case .split(_, _, let rc)? = clamped.root else { return XCTFail() }
        XCTAssertEqual(rc[1], 0.05, accuracy: 1e-9)
        // No ancestor on that axis.
        XCTAssertNil(LayoutEdit.resize(a, axis: .vertical, by: 0.1, in: row))
    }

    func testToggleOrientationFlipsParent() {
        let l = LayoutEdit.toggleOrientation(of: a, in: grid)!
        // Making the top row vertical matches the root's direction, so its two windows merge into the root. Frames are the same as when nested.
        guard case .split(.vertical, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [
            .leaf(a), .leaf(b),
            .split(.horizontal, children: [.leaf(c), .leaf(d)], ratios: [0.5, 0.5]),
        ])
        XCTAssertEqual(ratios[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 0.5, accuracy: 1e-9)
        XCTAssertNil(LayoutEdit.toggleOrientation(of: a, in: Layout(root: .leaf(a))))
    }

    func testNormalizeFlattensSameAxisAndCollapsesSingleChild() {
        let nested = Layout(root: .split(.horizontal, children: [
            .leaf(a),
            .split(.horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.4, 0.6]),
        ], ratios: [0.5, 0.5]))
        let flat = nested.normalized()
        guard case .split(.horizontal, let children, let ratios)? = flat.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(ratios[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 0.3, accuracy: 1e-9)
        let single = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a)], ratios: [1]),
        ], ratios: [1])).normalized()
        XCTAssertEqual(single.root, .leaf(a))
        let opposite = grid.normalized()
        XCTAssertEqual(opposite, grid)
    }

    func testAccordionStaysNestedInsideSameAxisTilesAndAbsorbsTiles() {
        let kept = Layout(root: .split(.horizontal, children: [
            .leaf(a),
            .accordion(.horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.4, 0.6]),
        ], ratios: [0.5, 0.5])).normalized()
        guard case .split(.horizontal, let children, _)? = kept.root else { return XCTFail() }
        XCTAssertEqual(children.count, 2)
        guard case .accordion(.horizontal, let band, let ratios) = children[1] else { return XCTFail() }
        XCTAssertEqual(band, [.leaf(b), .leaf(c)])
        XCTAssertEqual(ratios[0], 0.4, accuracy: 1e-9)

        let absorbed = Layout(root: .accordion(.horizontal, children: [
            .leaf(a),
            .split(.horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.4, 0.6]),
        ], ratios: [0.5, 0.5])).normalized()
        guard case .accordion(.horizontal, let flat, let flatRatios)? = absorbed.root else { return XCTFail() }
        XCTAssertEqual(flat, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(flatRatios[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(flatRatios[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(flatRatios[2], 0.3, accuracy: 1e-9)
    }

    func testToggleAccordionKeepsAxisAndInsertsBesideTheFocusedWindow() {
        let tiles = row
        let accordion = LayoutEdit.toggleAccordion(of: b, in: tiles)!
        guard case .accordion(.horizontal, let children, let ratios)? = accordion.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(ratios, [1.0 / 3, 1.0 / 3, 1.0 / 3])
        let back = LayoutEdit.toggleAccordion(of: b, in: accordion)!
        XCTAssertEqual(back.root, tiles.root)
        let inserted = accordion.inserting(WindowID(9), beside: b)
        guard case .accordion(.horizontal, let next, _)? = inserted.root else { return XCTFail() }
        XCTAssertEqual(next, [.leaf(a), .leaf(b), .leaf(WindowID(9)), .leaf(c)])
        XCTAssertNil(LayoutEdit.toggleAccordion(of: a, in: Layout(root: .leaf(a))))
    }

    func testAccordionFocusUsesTreeOrder() {
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let area = CGRect(x: 0, y: 0, width: 900, height: 400)
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: [:], options: PlannerOptions(unknownFloor: .zero, accordionPadding: 30), focused: b) else { return XCTFail() }
        XCTAssertEqual(LayoutEdit.neighbor(of: b, direction: .left, rects: plan.rects, layout: layout), a)
        XCTAssertEqual(LayoutEdit.neighbor(of: b, direction: .right, rects: plan.rects, layout: layout), c)
        XCTAssertNil(LayoutEdit.neighbor(of: b, direction: .up, rects: plan.rects, layout: layout))
        XCTAssertNil(LayoutEdit.neighbor(of: a, direction: .left, rects: plan.rects, layout: layout))
    }

    func testBalanceDropsLeftoverHeightOnAVerticalSplit() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let column = LayoutNode.split(.vertical, children: [.leaf(a), .leaf(c)], ratios: [440 / 949, 509 / 949])
        let root = LayoutNode.split(.horizontal, children: [column, .leaf(b)], ratios: [700 / 1512, 812 / 1512])
        let prior = Layout(root: root, leftoverHeights: [a: 440])
        let balanced = prior.balanced()
        XCTAssertNil(balanced.leftoverHeights[a])
        guard case .fits(let plan) = Planner.fit(balanced, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]!.height, 949 / 2, accuracy: 1)
        XCTAssertEqual(plan.rects[c]!.height, 949 / 2, accuracy: 1)
    }

    func testBalanceKeepsLeftoverHeightOnAHorizontalPair() {
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.7, 0.3]),
            leftoverHeights: [a: 440]
        )
        let balanced = prior.balanced()
        XCTAssertEqual(balanced.leftoverHeights[a], 440)
        guard case .split(.horizontal, _, let ratios)? = balanced.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 0.5, accuracy: 1e-9)
    }

    func testToggleToVerticalDropsLeftoverHeightSoTheWindowsShareTheColumn() {
        let work = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [700 / 1512, 812 / 1512]),
            leftoverHeights: [a: 440]
        )
        let flipped = LayoutEdit.toggleOrientation(of: a, in: prior)!
        XCTAssertNil(flipped.leftoverHeights[a])
        XCTAssertNil(flipped.leftoverHeights[b])
        guard case .split(.vertical, let children, let ratios)? = flipped.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b)])
        XCTAssertEqual(ratios[0], 700 / 1512, accuracy: 1e-9)
        guard case .fits(let plan) = Planner.fit(flipped, in: work, constraints: [:]) else { return XCTFail() }
        XCTAssertEqual(plan.rects[a]!.height, 949 * 700 / 1512, accuracy: 1)
        XCTAssertEqual(plan.rects[b]!.height, 949 * 812 / 1512, accuracy: 1)
    }
}

final class ManualEditTests: XCTestCase {
    let a = WindowID(1), b = WindowID(2), c = WindowID(3)
    let area = CGRect(x: 0, y: 30, width: 1920, height: 1050)
    var row: Layout { Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3])) }
    func rects(_ l: Layout) -> [WindowID: CGRect] {
        guard case .fits(let p) = Planner.fit(l, in: area, constraints: [:], options: PlannerOptions(unknownFloor: .zero)) else { XCTFail(); return [:] }
        return p.rects
    }

    func testNoDifferenceIsNil() {
        let r = rects(row)
        XCTAssertNil(ManualEdit.detect(id: a, planned: r[a]!, actual: r[a]!.offsetBy(dx: 0.5, dy: 0), layout: row, plannedRects: r))
    }

    func testEdgeDragIsResizeAsRatioOfContainer() {
        let r = rects(row)
        var actual = r[a]!; actual.size.width += 192 // right edge 192 pt to the right (10% of 1920)
        guard case .resize(let id, let deltas)? = ManualEdit.detect(id: a, planned: r[a]!, actual: actual, layout: row, plannedRects: r) else { return XCTFail() }
        XCTAssertEqual(id, a)
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].0, .horizontal)
        XCTAssertEqual(deltas[0].1, 0.1, accuracy: 1e-9)
    }

    func testDropOntoAnotherWindowIsSwapIntent() {
        let r = rects(row)
        let moved = CGRect(x: r[c]!.midX - r[a]!.width / 2, y: 200, width: r[a]!.width, height: r[a]!.height)
        XCTAssertEqual(ManualEdit.detect(id: a, planned: r[a]!, actual: moved, layout: row, plannedRects: r), .dropOnto(a, c))
    }

    func testMoveToNowhereOrSnapBecomesFloat() {
        let r = rects(row)
        let nowhere = CGRect(x: 0, y: 3000, width: r[a]!.width, height: r[a]!.height)
        XCTAssertEqual(ManualEdit.detect(id: a, planned: r[a]!, actual: nowhere, layout: row, plannedRects: r), .float(a))
        let snapped = CGRect(x: 960, y: 30, width: 960, height: 1050) // both position and size changed (OS tiling)
        XCTAssertEqual(ManualEdit.detect(id: a, planned: r[a]!, actual: snapped, layout: row, plannedRects: r), .float(a))
    }
}
