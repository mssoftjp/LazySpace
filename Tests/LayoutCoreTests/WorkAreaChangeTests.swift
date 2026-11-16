import CoreGraphics
import XCTest
@testable import LayoutCore

/// Ratios are written back from the tiles after every arrangement, and the tiles are whole points. When the work area changes size
/// (another display, a Dock or text-size setting, a dialog strip reserved and released) and changes back, the same tiles come back,
/// however many times it happens, and a window held at its minimum on the smaller area gets its share back on the larger one.
final class WorkAreaChangeTests: XCTestCase {
    func ids(_ count: Int) -> [WindowID] { (0..<count).map { WindowID(UInt32($0 + 1)) } }

    /// Planned and written back as an arrangement does.
    func arranged(_ layout: Layout, in area: CGRect, _ constraints: [WindowID: SizeKnowledge], _ options: PlannerOptions) -> (layout: Layout, rects: [WindowID: CGRect])? {
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: constraints, options: options) else { return nil }
        return (layout.packing(rects: plan.rects, shape: plan.shape, limits: (constraints, options)).normalized(), plan.rects)
    }

    func minimums(_ widths: [Double]) -> [WindowID: SizeKnowledge] {
        Dictionary(uniqueKeysWithValues: widths.enumerated().map { (WindowID(UInt32($0.offset + 1)), SizeKnowledge.known(CGSize(width: $0.element, height: 120))) })
    }

    /// Ten round trips between two work areas; the first difference from the tiles before the first trip, if any.
    func roundTrips(_ windowIDs: [WindowID], rows: Int, _ constraints: [WindowID: SizeKnowledge], _ options: PlannerOptions,
                    between a: CGRect, and b: CGRect, bOptions: PlannerOptions? = nil) -> String? {
        guard var (layout, original) = arranged(Planner.rowLayout(windowIDs, rows: rows), in: a, constraints, options) else { return nil }
        for trip in 1...10 {
            guard let (onB, _) = arranged(layout, in: b, constraints, bOptions ?? options),
                  let (back, rects) = arranged(onB, in: a, constraints, options) else { return nil }
            layout = back
            if let moved = windowIDs.first(where: { !rects[$0]!.matches(original[$0]!, tolerance: 0) }) {
                return "trip \(trip): window \(moved.raw) \(original[moved]!) is now \(rects[moved]!)"
            }
        }
        return nil
    }

    func testTilesComeBackAfterTheWorkAreaChangesBackAndForth() {
        let screens = ScreenSizeMatrixTests.screens
        var failures: [String] = []
        for options in [PlannerOptions(), PlannerOptions(gap: 8)] {
            for a in screens {
                for b in screens where b.name != a.name {
                    for count in 2...5 {
                        for rows in [1, 2] where rows <= count {
                            if let failure = roundTrips(ids(count), rows: rows, minimums(Array(repeating: 150, count: count)), options, between: a.area, and: b.area) {
                                failures.append("\(count) windows in \(rows) rows, gap \(Int(options.gap)), \(a.name) and \(b.name), \(failure)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// Windows held at their minimum on the smaller work area get their shares back on the larger one.
    func testAWindowHeldAtItsMinimumGetsItsShareBack() {
        let screens = ScreenSizeMatrixTests.screens
        let sets: [(String, [Double])] = [("400 + 1280", [400, 1280]), ("840 + 800", [840, 800]), ("5 × 300", Array(repeating: 300, count: 5)), ("4 × 600", Array(repeating: 600, count: 4)), ("840 + 300 + 300", [840, 300, 300])]
        var failures: [String] = []
        var held = 0
        for (name, widths) in sets {
            let constraints = minimums(widths)
            for a in screens {
                for b in screens where b.name != a.name {
                    for rows in [1, 2] where rows <= widths.count {
                        if case .fits(let onB) = Planner.fit(Planner.rowLayout(ids(widths.count), rows: rows), in: b.area, constraints: constraints),
                           !onB.folded, ids(widths.count).contains(where: { onB.rects[$0]!.width <= constraints[$0]!.size!.width }) {
                            held += 1
                        }
                        if let failure = roundTrips(ids(widths.count), rows: rows, constraints, PlannerOptions(), between: a.area, and: b.area) {
                            failures.append("\(name) in \(rows) rows, \(a.name) and \(b.name), \(failure)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(held, 100, "the smaller work areas hold windows at their minimum")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// A dialog strip reserved beside the tiles and released again, with windows small enough to stay beside it and windows held at their minimum there.
    func testTilesComeBackAfterADialogStripComesAndGoes() {
        var strip = PlannerOptions()
        strip.reservedRight = 317
        var failures: [String] = []
        for screen in ScreenSizeMatrixTests.screens {
            for widths in [[150.0, 150], [150, 150, 150], [150, 150, 150, 150, 150], [400, 840, 1000], [840, 800], [600, 600, 600]] {
                let windowIDs = ids(widths.count)
                guard case .fits(let beside) = Planner.fit(Planner.rowLayout(windowIDs, rows: 1), in: screen.area, constraints: minimums(widths), options: strip), !beside.folded else { continue }
                if let failure = roundTrips(windowIDs, rows: 1, minimums(widths), PlannerOptions(), between: screen.area, and: screen.area, bOptions: strip) {
                    failures.append("\(widths.map { Int($0) }) on \(screen.name), \(failure)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// When a window held at its minimum closes, the others take their intended shares, not the shares left over beside it.
    func testWhenAWindowHeldAtItsMinimumClosesTheOthersTakeTheirShares() {
        let area = CGRect(x: 0, y: 33, width: 2056, height: 1296)
        let constraints = minimums([840, 800, 300])
        guard let (layout, rects) = arranged(Planner.rowLayout(ids(3), rows: 1), in: area, constraints, PlannerOptions()) else { return XCTFail("does not fit") }
        XCTAssertEqual(ids(3).map { rects[$0]!.width }, [840, 800, 416])
        guard let (_, after) = arranged(layout.removing([WindowID(1)]), in: area, constraints, PlannerOptions()) else { return XCTFail("does not fit") }
        XCTAssertEqual([WindowID(2), WindowID(3)].map { after[$0]!.width }, [1028, 1028])
    }

    /// Without the plan's limits (frames observed on screen), ratios stay only where they give the frames with no minimum.
    func testFramesReadBackWithoutLimitsKeepOnlyRatiosThatGiveThem() {
        let even = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        // Thirds of 1471 points in whole points: the last tile takes the remaining point.
        let tiles: [WindowID: CGRect] = [WindowID(1): CGRect(x: 0, y: 0, width: 490, height: 900), WindowID(2): CGRect(x: 490, y: 0, width: 490, height: 900), WindowID(3): CGRect(x: 980, y: 0, width: 491, height: 900)]
        guard case .split(_, _, let kept)? = even.packing(rects: tiles, shape: even).root else { return XCTFail() }
        XCTAssertEqual(kept, [1.0 / 3, 1.0 / 3, 1.0 / 3], "whole-point tiles the ratios give")
        var resized = tiles
        resized[WindowID(1)] = CGRect(x: 0, y: 0, width: 840, height: 900)
        resized[WindowID(2)] = CGRect(x: 840, y: 0, width: 315, height: 900)
        resized[WindowID(3)] = CGRect(x: 1155, y: 0, width: 316, height: 900)
        guard case .split(_, _, let read)? = even.packing(rects: resized, shape: even).root else { return XCTFail() }
        XCTAssertEqual(read[0], 840.0 / 1471, accuracy: 1e-9, "a frame the ratios do not give is read back")
    }

    /// A share edit starts from the tiles only in the split it moves, and only where a window is held at its minimum there.
    func testAShareEditStartsFromTheTilesOfTheSplitItMovesOnly() {
        let area = CGRect(x: 0, y: 0, width: 1710, height: 1000)
        let constraints = minimums([1280, 300, 300, 300])
        let rows = Layout(root: .split(.vertical, children: [
            .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
            .split(.horizontal, children: [.leaf(WindowID(3)), .leaf(WindowID(4))], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(rows, in: area, constraints: constraints) else { return XCTFail("does not fit") }
        let lower = rows.shareEditStart(editing: WindowID(3), along: [.horizontal], rects: plan.rects, shape: plan.shape, limits: (constraints, PlannerOptions()))
        XCTAssertEqual(lower.layout, rows, "nothing is held in the lower row")
        XCTAssertTrue(lower.tiled)
        let upper = rows.shareEditStart(editing: WindowID(2), along: [.horizontal], rects: plan.rects, shape: plan.shape, limits: (constraints, PlannerOptions()))
        XCTAssertTrue(upper.tiled)
        guard case .split(_, let row, let outer)? = upper.layout.root, case .split(_, _, let top) = row[0], case .split(_, _, let bottom) = row[1] else { return XCTFail("no rows") }
        XCTAssertEqual(top, [1280.0 / 1710, 430.0 / 1710])
        XCTAssertEqual(bottom, [0.5, 0.5])
        XCTAssertEqual(outer, [0.5, 0.5])
    }

    /// Inside a real accordion, the split a share edit moves still starts from its tiles where a window is held at its minimum.
    func testAShareEditInsideAnAccordionStartsFromTheTiles() {
        let area = CGRect(x: 0, y: 0, width: 1710, height: 1000)
        let constraints: [WindowID: SizeKnowledge] = [WindowID(1): .known(CGSize(width: 300, height: 120)), WindowID(2): .known(CGSize(width: 300, height: 120)),
                                                      WindowID(3): .known(CGSize(width: 300, height: 700))]
        let layout = Layout(root: .accordion(.horizontal, children: [
            .leaf(WindowID(1)),
            .split(.vertical, children: [.leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [0.5, 0.5]),
        ], ratios: [0.5, 0.5]))
        guard case .fits(let plan) = Planner.fit(layout, in: area, constraints: constraints) else { return XCTFail("does not fit") }
        let start = layout.shareEditStart(editing: WindowID(2), along: [.vertical], rects: plan.rects, shape: plan.shape, limits: (constraints, PlannerOptions()))
        XCTAssertTrue(start.tiled)
        guard case .accordion(_, let children, let outer)? = start.layout.root, case .split(_, _, let column) = children[1] else { return XCTFail("no column") }
        XCTAssertEqual(column, [0.3, 0.7])
        XCTAssertEqual(outer, [0.5, 0.5])
        // The accordion itself does not tile by its ratios.
        XCTAssertFalse(layout.shareEditStart(editing: WindowID(1), along: [.horizontal], rects: plan.rects, shape: plan.shape, limits: (constraints, PlannerOptions())).tiled)
    }
}
