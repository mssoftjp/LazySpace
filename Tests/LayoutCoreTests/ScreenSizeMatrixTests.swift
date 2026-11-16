import CoreGraphics
import XCTest
@testable import LayoutCore

/// The folding rules on the common Mac work areas, so every rule about sizes is checked on every screen.
/// Rows, columns, and initial layouts are planned for windows with the minimum widths of real apps, a fixed width, and an unknown minimum.
/// `ScreenSizeArrangeTests` (OperationsTests) keeps the same list of work areas.
final class ScreenSizeMatrixTests: XCTestCase {
    struct Screen {
        let name: String
        let area: CGRect
    }

    /// Work areas in points: the screen below the menu bar (33 points with a camera housing, 24 or 25 without), and without the Dock unless named.
    static let screens: [Screen] = [
        Screen(name: "13-inch laptop", area: CGRect(x: 0, y: 33, width: 1470, height: 923)),
        Screen(name: "13-inch laptop, larger text", area: CGRect(x: 0, y: 33, width: 1280, height: 799)),
        Screen(name: "13-inch laptop at more space, 15-inch laptop", area: CGRect(x: 0, y: 33, width: 1710, height: 1079)),
        Screen(name: "14-inch laptop", area: CGRect(x: 0, y: 33, width: 1512, height: 949)),
        Screen(name: "14-inch laptop, larger text", area: CGRect(x: 0, y: 33, width: 1352, height: 845)),
        Screen(name: "14-inch laptop, more space", area: CGRect(x: 0, y: 33, width: 1800, height: 1136)),
        Screen(name: "14-inch laptop, Dock at the left", area: CGRect(x: 70, y: 33, width: 1442, height: 949)),
        Screen(name: "14-inch laptop, Dock below", area: CGRect(x: 0, y: 33, width: 1512, height: 879)),
        Screen(name: "15-inch laptop, larger text", area: CGRect(x: 0, y: 33, width: 1440, height: 899)),
        Screen(name: "16-inch laptop", area: CGRect(x: 0, y: 33, width: 1728, height: 1084)),
        Screen(name: "16-inch laptop, larger text", area: CGRect(x: 0, y: 33, width: 1496, height: 934)),
        Screen(name: "16-inch laptop, more space", area: CGRect(x: 0, y: 33, width: 2056, height: 1296)),
        Screen(name: "13-inch laptop without a camera housing", area: CGRect(x: 0, y: 24, width: 1440, height: 876)),
        Screen(name: "13-inch laptop without a camera housing, larger text", area: CGRect(x: 0, y: 24, width: 1280, height: 776)),
        Screen(name: "full HD display", area: CGRect(x: 0, y: 30, width: 1920, height: 1050)),
        Screen(name: "QHD display", area: CGRect(x: 0, y: 25, width: 2560, height: 1415)),
        Screen(name: "24-inch all-in-one", area: CGRect(x: 0, y: 25, width: 2240, height: 1235)),
        Screen(name: "6K display", area: CGRect(x: 0, y: 25, width: 3008, height: 1667)),
        Screen(name: "full HD display in portrait", area: CGRect(x: 0, y: 30, width: 1080, height: 1890)),
        Screen(name: "QHD display in portrait", area: CGRect(x: 0, y: 25, width: 1440, height: 2535)),
        Screen(name: "tablet as a display", area: CGRect(x: 0, y: 24, width: 1366, height: 1000)),
        Screen(name: "full HD display left of the main one", area: CGRect(x: -1920, y: 25, width: 1920, height: 1055)),
    ]

    struct Kind {
        let name: String
        let minimum: SizeKnowledge
        var maximum: CGSize?
    }

    /// Windows by their limits: an unknown minimum, small tools, apps of 600 to 1280 points, a window fixed at 740 points wide,
    /// and one taller than the work area of a laptop with larger text.
    static let kinds: [Kind] = [
        Kind(name: "unknown", minimum: .unknown),
        Kind(name: "300", minimum: .known(CGSize(width: 300, height: 200))),
        Kind(name: "400", minimum: .known(CGSize(width: 400, height: 300))),
        Kind(name: "600", minimum: .known(CGSize(width: 600, height: 400))),
        Kind(name: "fixed 740", minimum: .known(CGSize(width: 740, height: 500)), maximum: CGSize(width: 740, height: 0)),
        Kind(name: "800", minimum: .known(CGSize(width: 800, height: 500))),
        Kind(name: "840", minimum: .known(CGSize(width: 840, height: 500))),
        Kind(name: "1000", minimum: .known(CGSize(width: 1000, height: 600))),
        Kind(name: "1280", minimum: .known(CGSize(width: 1280, height: 700))),
        Kind(name: "tall 900", minimum: .known(CGSize(width: 400, height: 900))),
    ]

    /// Windows by height, for columns.
    static let tallKinds: [Kind] = [
        Kind(name: "h300", minimum: .known(CGSize(width: 400, height: 300))),
        Kind(name: "h500", minimum: .known(CGSize(width: 400, height: 500))),
        Kind(name: "h700", minimum: .known(CGSize(width: 400, height: 700))),
        Kind(name: "h900", minimum: .known(CGSize(width: 400, height: 900))),
    ]

    /// Every sequence of 1 to `length` kinds, in every order.
    static func ordered(_ count: Int, upTo length: Int) -> [[Int]] {
        var level: [[Int]] = [[]]
        var all: [[Int]] = []
        for _ in 0..<length {
            level = level.flatMap { s in (0..<count).map { s + [$0] } }
            all += level
        }
        return all
    }

    /// Every combination of `k` kinds, repeats allowed, in one order.
    static func combinations(_ count: Int, _ k: Int, from start: Int = 0) -> [[Int]] {
        if k == 0 { return [[]] }
        return (start..<count).flatMap { first in combinations(count, k - 1, from: first).map { [first] + $0 } }
    }

    struct Case {
        let screen: Screen
        let kinds: [Kind]
        let options: PlannerOptions
        var label: String { "\(screen.name), gap \(Int(options.gap)): \(kinds.map(\.name).joined(separator: " + "))" }
    }

    func ids(_ count: Int) -> [WindowID] { (0..<count).map { WindowID(UInt32($0 + 1)) } }

    func constraints(_ kinds: [Kind]) -> [WindowID: SizeKnowledge] {
        Dictionary(uniqueKeysWithValues: zip(ids(kinds.count), kinds.map(\.minimum)))
    }

    func maximums(_ kinds: [Kind]) -> [WindowID: CGSize] {
        Dictionary(uniqueKeysWithValues: zip(ids(kinds.count), kinds.map(\.maximum)).compactMap { id, cap in cap.map { (id, $0) } })
    }

    /// What the planner counts as the window's minimum: its known size, else the provisional minimum, in whole points.
    func minimum(_ kind: Kind, _ options: PlannerOptions) -> CGSize {
        let known = kind.minimum.size ?? .zero
        return CGSize(width: ceil(known.width > 0 ? known.width : options.unknownFloor.width),
                      height: ceil(known.height > 0 ? known.height : options.unknownFloor.height))
    }

    /// The length a window takes in a folded split: its minimum, or the preferred minimum when larger and its cap allows, within the room left by the strips.
    func foldedLength(_ kind: Kind, index: Int, count: Int, along axis: Axis, room: Double, options: PlannerOptions) -> Double {
        let strip = options.accordionStrip
        let inset = index == 0 || index == count - 1 ? strip : strip * 2
        let need = axis == .horizontal ? minimum(kind, options).width : minimum(kind, options).height
        let preferred = axis == .horizontal ? options.preferredMinimum.width : options.preferredMinimum.height
        let capValue = axis == .horizontal ? kind.maximum?.width : kind.maximum?.height
        let cap = (capValue ?? 0) > 0 ? capValue! : .infinity
        return min(room - inset, ceil(max(need, min(cap, preferred))))
    }

    func span(_ r: CGRect, _ axis: Axis) -> (Double, Double) { axis == .horizontal ? (r.minX, r.maxX) : (r.minY, r.maxY) }

    /// The first stretch between `start` and `end` that no span covers and that is wider than `allowed`, if any.
    func hole(in spans: [(Double, Double)], from start: Double, to end: Double, allowed: Double) -> (Double, Double)? {
        var reached = start
        for (low, high) in spans.sorted(by: { $0.0 < $1.0 }) {
            if low > reached + allowed + 0.5 { return (reached, low) }
            reached = max(reached, high)
        }
        return reached + allowed + 0.5 < end ? (reached, end) : nil
    }
    func length(_ r: CGRect, _ axis: Axis) -> Double { axis == .horizontal ? r.width : r.height }

    /// A split of the kinds along one axis: whether it fits, folds, and where every window goes, from the rules in DEVELOPMENT.md (Folding).
    func checkSplit(_ c: Case, along axis: Axis, failures: inout [String]) {
        let windowIDs = ids(c.kinds.count)
        let node: LayoutNode = windowIDs.count == 1 ? .leaf(windowIDs[0])
            : .split(axis, children: windowIDs.map { .leaf($0) }, ratios: Array(repeating: 1.0 / Double(windowIDs.count), count: windowIDs.count))
        let layout = Layout(root: node)
        let box = c.options.tilingArea(c.screen.area)
        let room = length(box, axis), across = axis == .horizontal ? box.height : box.width
        let strip = c.options.accordionStrip
        let gap = c.options.innerGap(along: axis)
        let mins = c.kinds.map { minimum($0, c.options) }
        let along = mins.map { axis == .horizontal ? $0.width : $0.height }
        let acrossNeed = mins.map { axis == .horizontal ? $0.height : $0.width }
        let count = c.kinds.count
        let tiles = along.reduce(0, +) + Double(count - 1) * gap <= room
        let foldFits = along.indices.allSatisfy { along[$0] <= room - (count == 1 ? 0 : ($0 == 0 || $0 == count - 1 ? strip : strip * 2)) }
        let shouldFit = acrossNeed.allSatisfy { $0 <= across } && (tiles || foldFits)
        let label = "\(axis == .horizontal ? "row" : "column") on \(c.label)"

        switch Planner.fit(layout, in: c.screen.area, constraints: constraints(c.kinds), options: c.options, maximums: maximums(c.kinds)) {
        case .unfit(let unfit):
            if shouldFit { failures.append("\(label): unfit (\(unfit.cause)) although it fits \(tiles ? "side by side" : "folded")") }
        case .fits(let plan):
            guard shouldFit else { return failures.append("\(label): fits although a window is larger than its room even folded") }
            let rects = windowIDs.map { plan.rects[$0] }
            guard rects.allSatisfy({ $0 != nil }) else { return failures.append("\(label): a window has no frame") }
            let frames = rects.map { $0! }
            for (index, frame) in frames.enumerated() {
                if !box.insetBy(dx: -0.5, dy: -0.5).contains(frame) { failures.append("\(label): window \(index + 1) \(frame) leaves the area \(box)") }
                if frame.width + 0.5 < mins[index].width || frame.height + 0.5 < mins[index].height {
                    failures.append("\(label): window \(index + 1) \(frame.size) is below its minimum \(mins[index])")
                }
                if let cap = c.kinds[index].maximum, cap.width > 0, frame.width > cap.width + 0.5 {
                    failures.append("\(label): window \(index + 1) is wider than its cap")
                }
            }
            if count == 1 { return }
            if tiles {
                if plan.folded { failures.append("\(label): folded although the windows fit side by side") }
                for i in 1..<count where span(frames[i], axis).0 + 0.5 < span(frames[i - 1], axis).1 + gap {
                    failures.append("\(label): windows \(i) and \(i + 1) overlap although they fit side by side")
                }
                // Width a capped window cannot use goes to the others; only a row of capped windows leaves some unused.
                if !c.kinds.allSatisfy({ $0.maximum != nil }) {
                    if abs(span(frames[0], axis).0 - span(box, axis).0) > 0.5 || abs(span(frames[count - 1], axis).1 - span(box, axis).1) > 0.5 {
                        failures.append("\(label): the row does not fill the area")
                    }
                    if let hole = hole(in: frames.map { span($0, axis) }, from: span(box, axis).0, to: span(box, axis).1, allowed: gap) {
                        failures.append("\(label): nothing covers \(hole) in a row that fits")
                    }
                }
                return
            }
            if !plan.folded { failures.append("\(label): not reported as folded although it overlaps") }
            if plan.shape.root?.box?.accordion != true { failures.append("\(label): the shape is not an accordion") }
            if plan.layout != layout { failures.append("\(label): the intent changed") }
            let (start, end) = span(box, axis)
            let lengths = c.kinds.indices.map { foldedLength(c.kinds[$0], index: $0, count: count, along: axis, room: room, options: c.options) }
            // The shortage is split evenly over the joints in whole points, and a window between the ends stays inside both end strips.
            let shortage = lengths.reduce(0, +) - room
            var reached = start
            for (index, frame) in frames.enumerated() {
                if abs(length(frame, axis) - lengths[index]) > 0.5 { failures.append("\(label): window \(index + 1) is \(length(frame, axis)) long, not \(lengths[index])") }
                var expected = reached - (Double(index) * shortage / Double(count - 1)).rounded()
                if index > 0, index < count - 1 { expected = min(max(expected, start + strip), end - lengths[index] - strip) }
                if abs(span(frame, axis).0 - expected) > 0.5 { failures.append("\(label): window \(index + 1) starts at \(span(frame, axis).0), not \(expected)") }
                reached += lengths[index]
            }
            if abs(span(frames[0], axis).0 - start) > 0.5 { failures.append("\(label): the first window does not keep the leading edge") }
            if abs(span(frames[count - 1], axis).1 - end) > 0.5 { failures.append("\(label): the last window does not keep the trailing edge") }
            if span(frames[1], axis).0 + 0.5 < start + strip { failures.append("\(label): the first window shows less than a strip") }
            if span(frames[count - 2], axis).1 - 0.5 > end - strip { failures.append("\(label): the last window shows less than a strip") }
            // A short window between long ones may be covered entirely, so the order of the edges is not a rule; leaving no hole is.
            // A row that is short only by its gaps folds without overlapping, and its windows keep smaller gaps instead: it looks like its tiles.
            if let hole = hole(in: frames.map { span($0, axis) }, from: start, to: end, allowed: gap) {
                failures.append("\(label): nothing covers \(hole) in a row that lacks length")
            }
            if count == 2 {
                let overlap = span(frames[0], axis).1 - span(frames[1], axis).0
                let lacking = frames.map { length($0, axis) }.reduce(0, +) - room
                if abs(overlap - lacking) > 0.5 { failures.append("\(label): overlaps \(overlap), not the \(lacking) it lacks") }
            }
            let focusedLast = Planner.fit(layout, in: c.screen.area, constraints: constraints(c.kinds), options: c.options, maximums: maximums(c.kinds), focused: windowIDs[count - 1])
            if case .fits(let other) = focusedLast, other.rects != plan.rects { failures.append("\(label): the frames depend on focus") }
        }
    }

    func testRowsOnEveryScreen() {
        var failures: [String] = []
        let cases = Self.ordered(Self.kinds.count, upTo: 3) + Self.combinations(Self.kinds.count, 4)
        for screen in Self.screens {
            for gap in [0.0, 8.0] {
                let options = PlannerOptions(gap: gap)
                for sequence in cases {
                    checkSplit(Case(screen: screen, kinds: sequence.map { Self.kinds[$0] }, options: options), along: .horizontal, failures: &failures)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    func testColumnsOnEveryScreen() {
        var failures: [String] = []
        let cases = Self.ordered(Self.tallKinds.count, upTo: 3) + Self.combinations(Self.tallKinds.count, 4)
        for screen in Self.screens {
            for gap in [0.0, 8.0] {
                let options = PlannerOptions(gap: gap)
                for sequence in cases {
                    checkSplit(Case(screen: screen, kinds: sequence.map { Self.tallKinds[$0] }, options: options), along: .vertical, failures: &failures)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// Splits that fit do not overlap along their axis, folded splits keep both edges and show a strip of each end window, and nothing leaves the area.
    func checkShape(_ node: LayoutNode, rects: [WindowID: CGRect], options: PlannerOptions, label: String, failures: inout [String]) {
        guard let box = node.box else { return }
        let (axis, children, accordion) = (box.axis, box.children, box.accordion)
        let unions = children.map { child in child.windowIDs.compactMap { rects[$0] }.reduce(CGRect.null) { $0.union($1) } }
        if accordion, unions.count > 1 {
            let strip = options.accordionStrip
            let (start, end) = (span(unions[0], axis).0, span(unions[unions.count - 1], axis).1)
            if unions.contains(where: { span($0, axis).0 + 0.5 < start || span($0, axis).1 - 0.5 > end }) { failures.append("\(label): a fold reaches past its first or last part") }
            if let hole = hole(in: unions.map { span($0, axis) }, from: start, to: end, allowed: options.innerGap(along: axis)) { failures.append("\(label): nothing covers \(hole) in a fold") }
            if span(unions[1], axis).0 + 0.5 < start + strip { failures.append("\(label): the first part of a fold shows less than a strip") }
            if span(unions[unions.count - 2], axis).1 - 0.5 > end - strip { failures.append("\(label): the last part of a fold shows less than a strip") }
        } else {
            for i in 1..<unions.count where span(unions[i], axis).0 + 0.5 < span(unions[i - 1], axis).1 + options.innerGap(along: axis) {
                failures.append("\(label): parts of a split that fits overlap")
            }
        }
        for child in children { checkShape(child, rects: rects, options: options, label: label, failures: &failures) }
    }

    /// The initial layout for windows in any combination: it fits whenever one folded row does, it prefers comfortable rows without folding,
    /// and every frame keeps its minimum inside the area.
    func testInitialLayoutsOnEveryScreen() {
        var failures: [String] = []
        // Five windows leave out the tall kind (the last), which keeps the run short.
        let cases = Self.ordered(Self.kinds.count, upTo: 2) + (3...4).flatMap { Self.combinations(Self.kinds.count, $0) } + Self.combinations(Self.kinds.count - 1, 5)
        let options = PlannerOptions()
        for screen in Self.screens {
            for sequence in cases {
                let kinds = sequence.map { Self.kinds[$0] }
                let c = Case(screen: screen, kinds: kinds, options: options)
                let windowIDs = ids(kinds.count)
                let box = options.tilingArea(screen.area)
                let strip = options.accordionStrip
                let mins = kinds.map { minimum($0, options) }
                let n = kinds.count
                let oneRowFits = mins.allSatisfy { $0.height <= box.height }
                    && mins.indices.allSatisfy { mins[$0].width <= box.width - (n == 1 ? 0 : ($0 == 0 || $0 == n - 1 ? strip : strip * 2)) }
                // The documented order: the fewest comfortable rows without folding, one folded row, the fewest rows that fit without folding,
                // the fewest folded rows, and unfit only when no number of rows fits.
                let comfortable = { (p: Plan) in p.rects.values.allSatisfy { $0.width >= options.preferredMinimum.width && $0.height >= options.preferredMinimum.height } }
                var candidates: [(rows: Int, plan: Plan)] = []
                for rows in 1...min(options.maxRows, n) {
                    if case .fits(let p) = Planner.fit(Planner.rowLayout(windowIDs, rows: rows), in: screen.area, constraints: constraints(kinds), options: options, maximums: maximums(kinds)) {
                        candidates.append((rows, p))
                    }
                }
                let expected = candidates.first { !$0.plan.folded && comfortable($0.plan) }
                    ?? candidates.first { $0.rows == 1 && $0.plan.folded }
                    ?? candidates.first { !$0.plan.folded }
                    ?? candidates.first
                switch Planner.initial(for: windowIDs, in: screen.area, constraints: constraints(kinds), options: options, maximums: maximums(kinds)) {
                case .unfit(let unfit):
                    if oneRowFits { failures.append("initial on \(c.label): unfit (\(unfit.cause)) although one folded row fits") }
                    if let expected { failures.append("initial on \(c.label): unfit although \(expected.rows) rows fit") }
                case .fits(let plan):
                    if let expected, expected.rows != plan.rows || expected.plan.folded != plan.folded {
                        failures.append("initial on \(c.label): chose \(plan.rows) rows\(plan.folded ? " folded" : ""), not \(expected.rows)\(expected.plan.folded ? " folded" : "")")
                    }
                    for (index, id) in windowIDs.enumerated() {
                        guard let frame = plan.rects[id] else { failures.append("initial on \(c.label): window \(index + 1) has no frame"); continue }
                        if !box.insetBy(dx: -0.5, dy: -0.5).contains(frame) { failures.append("initial on \(c.label): window \(index + 1) leaves the area") }
                        if frame.width + 0.5 < mins[index].width || frame.height + 0.5 < mins[index].height {
                            failures.append("initial on \(c.label): window \(index + 1) \(frame.size) is below its minimum")
                        }
                    }
                    if let root = plan.shape.root { checkShape(root, rects: plan.rects, options: options, label: "initial on \(c.label)", failures: &failures) }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// Minimum lengths a point either side of each rule on each screen: two or three windows filling the row exactly, a window fitting
    /// between two strips, beside one strip, and alone.
    func testSplitsAtTheThresholdsOfEveryScreen() {
        var failures: [String] = []
        for screen in Self.screens {
            for gap in [0.0, 8.0] {
                let options = PlannerOptions(gap: gap)
                let box = options.tilingArea(screen.area)
                let strip = options.accordionStrip
                for axis in [Axis.horizontal, .vertical] {
                    let room = length(box, axis), across = axis == .horizontal ? box.height : box.width
                    let half = floor((room - gap) / 2), third = floor((room - 2 * gap) / 3)
                    let lengths = Set([half, half + 1, third, third + 1, room - 2 * strip - 1, room - 2 * strip, room - 2 * strip + 1, room - strip, room - strip + 1, room, room + 1])
                    let kinds = lengths.sorted().map { value in
                        Kind(name: "\(Int(value))", minimum: .known(axis == .horizontal ? CGSize(width: value, height: min(200, across)) : CGSize(width: min(400, across), height: value)))
                    }
                    for sequence in Self.ordered(kinds.count, upTo: 3) {
                        checkSplit(Case(screen: screen, kinds: sequence.map { kinds[$0] }, options: options), along: axis, failures: &failures)
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// The same rules without strips, and with outer gaps and a vertical gap of its own.
    func testSplitsWithOtherOptions() {
        var failures: [String] = []
        let variants = [PlannerOptions(gap: 8, accordionPadding: 0), PlannerOptions(gap: 6, gapVertical: 12, outerLeft: 10, outerTop: 10, outerRight: 10, outerBottom: 10)]
        for screen in Self.screens {
            for options in variants {
                for sequence in Self.ordered(Self.kinds.count, upTo: 2) + Self.combinations(Self.kinds.count, 3) {
                    checkSplit(Case(screen: screen, kinds: sequence.map { Self.kinds[$0] }, options: options), along: .horizontal, failures: &failures)
                }
                for sequence in Self.ordered(Self.tallKinds.count, upTo: 3) {
                    checkSplit(Case(screen: screen, kinds: sequence.map { Self.tallKinds[$0] }, options: options), along: .vertical, failures: &failures)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// A node's minimum as DEVELOPMENT.md (Folding) gives it: a split needs the smaller of its tiled need (sum plus gaps) and its folded need
    /// (longest child plus two strips) along its axis, and its largest child across it.
    func expectedMinimum(_ node: LayoutNode, _ kinds: [Kind], _ options: PlannerOptions) -> CGSize {
        guard let box = node.box else {
            guard case .leaf(let id) = node else { return .zero }
            return minimum(kinds[Int(id.raw) - 1], options)
        }
        let mins = box.children.map { expectedMinimum($0, kinds, options) }
        let along = mins.map { box.axis == .horizontal ? $0.width : $0.height }, across = mins.map { box.axis == .horizontal ? $0.height : $0.width }
        let need = min(along.reduce(0, +) + Double(along.count - 1) * options.innerGap(along: box.axis), along.max()! + 2 * options.accordionStrip)
        return box.axis == .horizontal ? CGSize(width: need, height: across.max()!) : CGSize(width: across.max()!, height: need)
    }

    /// Layouts with splits inside splits: one whose minimum fits the area always fits, and then every frame keeps its minimum inside the area,
    /// parts of a split that fits do not overlap, folds keep their edges and strips, the outer split folds only when its parts do not fit
    /// side by side at their own minimums, and no frame depends on focus.
    func testNestedLayoutsOnEveryScreen() {
        var failures: [String] = []
        let options = PlannerOptions()
        func row(_ nodes: [LayoutNode]) -> LayoutNode { .split(.horizontal, children: nodes, ratios: Array(repeating: 1 / Double(nodes.count), count: nodes.count)) }
        func column(_ nodes: [LayoutNode]) -> LayoutNode { .split(.vertical, children: nodes, ratios: Array(repeating: 1 / Double(nodes.count), count: nodes.count)) }
        let w = ids(4).map { LayoutNode.leaf($0) }
        let shapes: [(name: String, count: Int, node: LayoutNode)] = [
            ("a window beside a column of two", 3, row([w[0], column([w[1], w[2]])])),
            ("a row of two above a window", 3, column([row([w[0], w[1]]), w[2]])),
            ("two columns of two", 4, row([column([w[0], w[1]]), column([w[2], w[3]])])),
            ("a window beside a column holding a row", 4, row([w[0], column([w[1], row([w[2], w[3]])])])),
        ]
        for screen in Self.screens {
            let box = options.tilingArea(screen.area)
            for shape in shapes {
                for sequence in Self.combinations(Self.kinds.count, shape.count) {
                    let kinds = sequence.map { Self.kinds[$0] }
                    let label = "\(shape.name) on \(screen.name): \(kinds.map(\.name).joined(separator: " + "))"
                    let layout = Layout(root: shape.node)
                    let need = Planner.minimumSize(of: layout, constraints: constraints(kinds), options: options)
                    switch Planner.fit(layout, in: screen.area, constraints: constraints(kinds), options: options, maximums: maximums(kinds)) {
                    case .unfit(let unfit):
                        if need.width <= box.width, need.height <= box.height { failures.append("\(label): unfit (\(unfit.cause)) although its minimum \(need) fits") }
                    case .fits(let plan):
                        for (index, id) in ids(kinds.count).enumerated() {
                            guard let frame = plan.rects[id] else { failures.append("\(label): window \(index + 1) has no frame"); continue }
                            if !box.insetBy(dx: -0.5, dy: -0.5).contains(frame) { failures.append("\(label): window \(index + 1) \(frame) leaves the area") }
                            let least = minimum(kinds[index], options)
                            if frame.width + 0.5 < least.width || frame.height + 0.5 < least.height { failures.append("\(label): window \(index + 1) \(frame.size) is below its minimum") }
                        }
                        if let root = plan.shape.root { checkShape(root, rects: plan.rects, options: options, label: label, failures: &failures) }
                        if let outer = shape.node.box, plan.shape.root?.box?.accordion == true {
                            let parts = outer.children.map { expectedMinimum($0, kinds, options) }.map { outer.axis == .horizontal ? $0.width : $0.height }
                            if parts.reduce(0, +) + Double(parts.count - 1) * options.innerGap(along: outer.axis) <= length(box, outer.axis) {
                                failures.append("\(label): the outer split folds although its parts fit side by side at \(parts)")
                            }
                        }
                        if case .fits(let other) = Planner.fit(layout, in: screen.area, constraints: constraints(kinds), options: options, maximums: maximums(kinds), focused: ids(kinds.count).last),
                           other.rects != plan.rects { failures.append("\(label): the frames depend on focus") }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// The list covers screens where two common apps no longer fit side by side, screens where three do, a portrait display, and a display left of the main one.
    func testTheListCoversNarrowAndWideScreens() {
        let widths = Self.screens.map(\.area.width)
        XCTAssertTrue(widths.contains(1512))
        XCTAssertLessThan(widths.min()!, 840 + 400, "a screen where two common apps already need to overlap")
        XCTAssertGreaterThan(widths.max()!, 840 + 1000 + 800, "a screen where three wide apps fit side by side")
        XCTAssertTrue(Self.screens.contains { $0.area.height > $0.area.width }, "a portrait display")
        XCTAssertTrue(Self.screens.contains { $0.area.minX < 0 }, "a display left of the main one")
    }
}
