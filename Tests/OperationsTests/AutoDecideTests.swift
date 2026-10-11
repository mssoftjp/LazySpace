import XCTest
import LayoutCore
@testable import Operations

final class AutoDecideTests: XCTestCase {
    let a = WindowID(1), b = WindowID(2), c = WindowID(3)

    func census(_ pairs: [(WindowID, Int32)], front: Int32?, space: UInt64? = 7, frontWindow: WindowID? = nil) -> Census {
        Census(windows: Dictionary(uniqueKeysWithValues: pairs), frontmostPID: front, spaceID: space, frontWindow: frontWindow)
    }

    func input(_ prev: Census, _ cur: Census, quiet: Bool = true, paused: Bool = false, hasLayout: Bool = true, managed: Set<WindowID> = []) -> AutoDecide.Input {
        .init(previous: prev, current: cur, inputQuiet: quiet, paused: paused, hasLayout: hasLayout, managed: managed)
    }

    func testNewForegroundAppJoinsAfterInputSettles() {
        let prev = census([(a, 10)], front: 10, frontWindow: a)
        let cur = census([(a, 10), (b, 20)], front: 20, frontWindow: b)
        let deferred = AutoDecide.decide(input(prev, cur, quiet: false, managed: [a]))
        XCTAssertTrue(deferred.actions.isEmpty)
        XCTAssertEqual(deferred.deferredAdded, [b])
        XCTAssertEqual(AutoDecide.decide(input(prev, cur, managed: [a])).actions, [.integrate([b], beside: a)])
    }

    func testForegroundCreationIntegratesWhenQuiet() {
        let prev = census([(a, 10)], front: 10)
        let cur = census([(a, 10), (b, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, managed: [a]))
        XCTAssertEqual(out.actions, [.integrate([b], beside: nil)])
    }

    func testForegroundCreationRemembersWindowThatWasInFront() {
        // Inserted beside a, the managed window that was in front before it appeared.
        let prev = census([(a, 10)], front: 10, frontWindow: a)
        let cur = census([(a, 10), (b, 10)], front: 10, frontWindow: b)
        XCTAssertEqual(AutoDecide.decide(input(prev, cur, managed: [a])).actions, [.integrate([b], beside: a)])
        // A front window that is not managed (waiting, for example) is no position hint.
        XCTAssertEqual(AutoDecide.decide(input(prev, cur, managed: [c])).actions, [.integrate([b], beside: nil)])
    }

    func testWindowAlreadyInLayoutIsNotIntegratedAgain() {
        let a = WindowID(1), b = WindowID(2)
        let prev = Census(windows: [a: 10], frontmostPID: 10, spaceID: 7, frontWindow: a)
        let cur = Census(windows: [a: 10, b: 20], frontmostPID: 20, spaceID: 7, frontWindow: b)
        let out = AutoDecide.decide(input(prev, cur, managed: [a, b]))
        XCTAssertEqual(out.actions, [])
        XCTAssertTrue(out.deferredAdded.isEmpty)
    }

    func testForegroundCreationDuringInputIsDeferredNotDropped() {
        let prev = census([(a, 10)], front: 10)
        let cur = census([(a, 10), (b, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, quiet: false, managed: [a]))
        XCTAssertEqual(out.actions, [])
        XCTAssertEqual(out.deferredAdded, [b])
    }

    func testBackgroundCreationTilesBesideTheRecentWindow() {
        // 20 is not the front app. Once still, the window goes beside the previous managed window.
        let prev = census([(a, 10)], front: 10, frontWindow: a)
        let cur = census([(a, 10), (b, 20)], front: 10, frontWindow: a)
        let out = AutoDecide.decide(input(prev, cur, managed: [a]))
        XCTAssertEqual(out.actions, [.integrate([b], beside: a)])
        let busy = AutoDecide.decide(input(prev, cur, quiet: false, managed: [a]))
        XCTAssertEqual(busy.actions, [])
        XCTAssertEqual(busy.deferredAdded, [b])
    }

    func testNewAppWithoutAKnownFrontWindowStillTiles() {
        // Without a known front window, a new window is inserted by the tail rule.
        let prev = census([(a, 10)], front: 10)
        let cur = census([(a, 10), (b, 20)], front: 20)
        let out = AutoDecide.decide(input(prev, cur, managed: [a]))
        XCTAssertEqual(out.actions, [.integrate([b], beside: nil)])
    }

    func testRemovalOfManagedWindowRefits() {
        let prev = census([(a, 10), (b, 10)], front: 10)
        let cur = census([(a, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, managed: [a, b]))
        XCTAssertEqual(out.actions, [.refitAfterRemoval([b], wasFront: false)])
    }

    func testRemovalOfFrontWindowIsMarked() {
        let prev = census([(a, 10), (b, 10)], front: 10, frontWindow: b)
        let cur = census([(a, 10)], front: 10, frontWindow: a)
        XCTAssertEqual(AutoDecide.decide(input(prev, cur, managed: [a, b])).actions, [.refitAfterRemoval([b], wasFront: true)])
    }

    func testRemovalOfUnmanagedWindowDoesNothing() {
        let prev = census([(a, 10), (b, 10)], front: 10)
        let cur = census([(a, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, managed: [a]))
        XCTAssertEqual(out.actions, [])
    }

    func testRemovalDuringInputIsDeferred() {
        let prev = census([(a, 10), (b, 10)], front: 10)
        let cur = census([(a, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, quiet: false, managed: [a, b]))
        XCTAssertEqual(out.actions, [])
        XCTAssertEqual(out.deferredRemoved, [b])
    }

    func testPausedTracksButNeverActs() {
        let prev = census([(a, 10)], front: 10)
        let cur = census([(a, 10), (b, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, paused: true, managed: [a]))
        XCTAssertEqual(out.actions, [])
        XCTAssertEqual(out.deferredAdded, [])
    }

    func testUnmanagedSpaceDoesNothing() {
        let prev = census([(a, 10)], front: 10)
        let cur = census([(a, 10), (b, 10)], front: 10)
        let out = AutoDecide.decide(input(prev, cur, hasLayout: false))
        XCTAssertEqual(out.actions, [])
    }

    func testSpaceChangeOnlyRebases() {
        let prev = census([(a, 10)], front: 10, space: 7)
        let cur = census([(b, 20), (c, 20)], front: 20, space: 4)
        let out = AutoDecide.decide(input(prev, cur, managed: [a]))
        XCTAssertEqual(out.actions, [.rebase])
    }
}

final class LayoutInsertTests: XCTestCase {
    let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)

    func testInsertIntoEmptyAndLeaf() {
        XCTAssertEqual(Layout(root: nil).inserting(a).root, .leaf(a))
        XCTAssertEqual(Layout(root: .leaf(a)).inserting(b).root, .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
    }

    func testInsertIntoHorizontalUsesTheSiblingAverage() {
        let l = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.75, 0.25])).inserting(c)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(ratios[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 0.25 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testInsertAtEndScalesEverySibling() {
        let packed = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [230.0 / 1512.0, 1282.0 / 1512.0]))
        let l = packed.inserting(c)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(ratios[0], (230.0 / 1512.0) * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], (1282.0 / 1512.0) * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 1.0 / 3.0, accuracy: 1e-9)
    }

    func testInsertIntoRowsGoesToShortestRow() {
        let rows = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .leaf(c),
        ], ratios: [0.5, 0.5]))
        let l = rows.inserting(d)
        XCTAssertEqual(l.root, .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .split(.horizontal, children: [.leaf(c), .leaf(d)], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
    }

    func testInsertExistingIsNoop() {
        let l = Layout(root: .leaf(a))
        XCTAssertEqual(l.inserting(a), l)
    }

    func testInsertBesideTargetBecomesNextSiblingInParentAxis() {
        // Row [a, b, c], d beside b: [a, b, d, c]. The new weight is the siblings' average.
        let row = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.5, 0.25, 0.25]))
        let l = row.inserting(d, beside: b)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(d), .leaf(c)])
        XCTAssertEqual(ratios[0], 0.375, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 0.1875, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 0.25, accuracy: 1e-9)
        XCTAssertEqual(ratios[3], 0.1875, accuracy: 1e-9)
        XCTAssertEqual(ratios.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testInsertBesideScalesEverySibling() {
        let packed = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [230.0 / 1512.0, 1282.0 / 1512.0]))
        let l = packed.inserting(c, beside: b)
        guard case .split(.horizontal, let children, let ratios)? = l.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(b), .leaf(c)])
        XCTAssertEqual(ratios[0], (230.0 / 1512.0) * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], (1282.0 / 1512.0) * 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 1.0 / 3.0, accuracy: 1e-9)
    }

    func testInsertBesideInNestedRowStaysInThatRow() {
        let rows = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .leaf(c),
        ], ratios: [0.5, 0.5]))
        // Beside a (same row); the tail rule would put it in c's row.
        let l = rows.inserting(d, beside: a)
        guard case .split(.vertical, let children, _)? = l.root, case .split(.horizontal, let top, let ratios) = children[0] else { return XCTFail() }
        XCTAssertEqual(top, [.leaf(a), .leaf(d), .leaf(b)])
        XCTAssertEqual(ratios[0], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(children[1], .leaf(c))
        // A single leaf splits horizontally. Without the neighbor, the tail rule applies.
        XCTAssertEqual(Layout(root: .leaf(a)).inserting(b, beside: a).root, .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        XCTAssertEqual(rows.inserting(d, beside: WindowID(99)), rows.inserting(d))
    }

    func testBalancedResetsRatiosKeepingStructure() {
        let l = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [0.6, 0.2, 0.2]),
            .leaf(d),
        ], ratios: [0.7, 0.3])).balanced()
        XCTAssertEqual(l.root, .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]),
            .leaf(d),
        ], ratios: [0.5, 0.5]))
    }

    func testParentAxis() {
        let l = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            .leaf(c),
        ], ratios: [0.5, 0.5]))
        XCTAssertEqual(l.parentAxis(of: a), .horizontal)
        XCTAssertEqual(l.parentAxis(of: c), .vertical)
        XCTAssertNil(l.parentAxis(of: d))
        XCTAssertNil(Layout(root: .leaf(a)).parentAxis(of: a))
    }

    func testInsertInPlaceOfAFloatedMiddleWindowFillsThatGap() {
        let home = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let current = home.removing([b])
        let next = current.inserting(d, inPlaceOf: b, home: home)
        guard case .split(.horizontal, let children, _)? = next.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(d), .leaf(c)])
    }

    func testInsertInPlaceOfAFloatedLeftWindowStaysOnTheLeft() {
        let home = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        let current = home.removing([a])
        let next = current.inserting(d, inPlaceOf: a, home: home)
        guard case .split(.horizontal, let children, _)? = next.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(d), .leaf(b), .leaf(c)])
    }

    func testReturningBesideAReorderedColumnStaysOutside() {
        let home = Layout(root: .split(.horizontal, children: [
            .leaf(a),
            .split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5]),
        ], ratios: [0.4, 0.6]))
        let current = Layout(root: .split(.vertical, children: [.leaf(c), .leaf(b)], ratios: [0.5, 0.5]))
        let back = current.returning(a, home: home)
        guard case .split(.horizontal, let children, _)? = back.root else { return XCTFail() }
        XCTAssertEqual(children, [
            .leaf(a),
            .split(.vertical, children: [.leaf(c), .leaf(b)], ratios: [0.5, 0.5]),
        ])
    }

    func testReturningBesideAColumnThatStillHasANeighborStaysOutside() {
        let column = LayoutNode.split(.vertical, children: [.leaf(c), .leaf(b)], ratios: [0.5, 0.5])
        let home = Layout(root: .split(.horizontal, children: [
            .leaf(a),
            .split(.vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5]),
            .leaf(d),
        ], ratios: [0.25, 0.5, 0.25]))
        let current = Layout(root: .split(.horizontal, children: [column, .leaf(d)], ratios: [0.67, 0.33]))
        let back = current.returning(a, home: home)
        guard case .split(.horizontal, let children, let ratios)? = back.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), column, .leaf(d)])
        XCTAssertEqual(ratios[2], 0.22, accuracy: 1e-9)
        XCTAssertEqual(ratios[0] + ratios[1], 0.78, accuracy: 1e-9)
    }

    func testReturningAboveAReorderedRowStaysAboveTheRow() {
        let home = Layout(root: .split(.vertical, children: [
            .leaf(a),
            .split(.horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5]),
        ], ratios: [0.4, 0.6]))
        let current = Layout(root: .split(.horizontal, children: [.leaf(c), .leaf(b)], ratios: [0.5, 0.5]))
        let back = current.returning(a, home: home)
        guard case .split(.vertical, let children, _)? = back.root else { return XCTFail() }
        XCTAssertEqual(children, [
            .leaf(a),
            .split(.horizontal, children: [.leaf(c), .leaf(b)], ratios: [0.5, 0.5]),
        ])
    }
}
