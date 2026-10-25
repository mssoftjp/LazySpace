import CoreGraphics
import Foundation

/// A computed candidate, not yet written to the OS.
public struct Plan: Equatable {
    public var layout: Layout
    public var rects: [WindowID: CGRect]
    /// Windows with unknown constraints, computed with the provisional minimum.
    public var assumedUnknown: Set<WindowID>
    /// Rows used by the initial layout; 0 when recalculating the user's structure.
    public var rows: Int
}

/// Why it does not fit. Anything found before changing the layout is never written to the OS.
public struct Unfit: Equatable {
    public enum Cause: Equatable {
        /// The children's minimum total in this split exceeds the available length.
        case splitOverflow(Axis, required: Double, available: Double, members: [WindowID])
        /// A single window is larger than the area.
        case windowLargerThanArea(WindowID, required: CGSize, available: CGSize)
    }
    public var cause: Cause
    public var offending: [WindowID] {
        switch cause {
        case .splitOverflow(_, _, _, let m): return m
        case .windowLargerThanArea(let id, _, _): return [id]
        }
    }
}

public enum PlanOutcome: Equatable {
    case fits(Plan)
    case unfit(Unfit)
}

public struct PlannerOptions: Equatable {
    /// Gap between windows side by side.
    public var gap: Double
    /// Gap between stacked windows; same as `gap` when unset.
    public var gapVertical: Double
    /// Inset inside the work area, added after excluding the menu bar and Dock.
    public var outerLeft: Double
    public var outerTop: Double
    public var outerRight: Double
    public var outerBottom: Double
    /// Minimum assumed for windows with unknown constraints. A layout below it never counts as fitting.
    public var unknownFloor: CGSize
    /// Maximum rows considered for the initial layout, to keep it bounded.
    public var maxRows: Int
    /// Size each window should get in the initial layout. Prefers the fewest rows where every window reaches it, else the fewest rows that fit.
    /// A preference, not a constraint, so recalculating the user's structure (fit) ignores it.
    public var preferredMinimum: CGSize
    /// Width (pt) of the visible strip of unfocused accordion windows; 0 overlaps them completely.
    public var accordionPadding: Double
    /// Width reserved on the right for the dialog region (region plus gap); 0 for none.
    public var reservedRight: Double = 0
    /// Height reserved at the bottom for the dialog region (region plus gap). Never used together with the right reservation.
    public var reservedBottom: Double = 0

    public init(gap: Double = 0, unknownFloor: CGSize = CGSize(width: 120, height: 120), maxRows: Int = 4, preferredMinimum: CGSize = CGSize(width: 400, height: 300), accordionPadding: Double = 30, gapVertical: Double? = nil, outerLeft: Double = 0, outerTop: Double = 0, outerRight: Double = 0, outerBottom: Double = 0) {
        self.gap = gap
        self.gapVertical = gapVertical ?? gap
        self.outerLeft = outerLeft
        self.outerTop = outerTop
        self.outerRight = outerRight
        self.outerBottom = outerBottom
        self.unknownFloor = unknownFloor
        self.maxRows = maxRows
        self.preferredMinimum = preferredMinimum
        self.accordionPadding = accordionPadding
    }

    /// Gaps and accordion strips are rounded to whole points, like the tiling area, so every tile starts on a whole point
    /// and ratios written back from the tiles reproduce the same tiles.
    public func innerGap(along axis: Axis) -> Double {
        (axis == .horizontal ? gap : gapVertical).rounded()
    }

    var accordionStrip: Double { max(0, accordionPadding).rounded() }

    /// The area for tiles: minus outer gaps and the region reservation (from the width on the right, the height at the bottom). Returned unchanged when the gaps exceed the area.
    /// If a reservation would leave less than 1 pt on its axis, only that reservation is ignored (callers prevent it with limits; the gaps are kept so the region is not silently lost here).
    /// The region packs from integer-rounded edges (right and bottom rounded down), so the reservation is taken from those edges too (the gap to the region is not eaten by rounding).
    public func tilingArea(_ area: CGRect) -> CGRect {
        var rect = insetArea(area)
        if reservedRight > 0 {
            let width = floor(rect.maxX) - reservedRight - rect.minX
            if width >= 1 { rect.size.width = width }
        }
        if reservedBottom > 0 {
            let height = floor(rect.maxY) - reservedBottom - rect.minY
            if height >= 1 { rect.size.height = height }
        }
        return rect
    }

    /// Whether a region is reserved.
    public var reservesRegion: Bool { reservedRight > 0 || reservedBottom > 0 }

    /// Whether the region reservation does not fit the current area (and is ignored on that axis).
    public func reservationIgnored(in area: CGRect) -> Bool {
        let inset = insetArea(area)
        return (reservedRight > 0 && floor(inset.maxX) - reservedRight - inset.minX < 1) || (reservedBottom > 0 && floor(inset.maxY) - reservedBottom - inset.minY < 1)
    }

    /// The area minus outer gaps only (the dialog region is taken at its right or bottom edge).
    public func insetArea(_ area: CGRect) -> CGRect {
        let width = area.width - outerLeft - outerRight
        let height = area.height - outerTop - outerBottom
        guard width >= 1, height >= 1 else { return area }
        return CGRect(x: area.minX + outerLeft, y: area.minY + outerTop, width: width, height: height)
    }
}

public enum Planner {
    /// Distributes the area while keeping the existing layout intent (structure and ratios) and meeting constraints.
    /// Ratios give way toward minimums only when they cannot be met; the rest is distributed proportionally.
    public static func fit(
        _ layout: Layout,
        in area: CGRect,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions = PlannerOptions(),
        maximums: [WindowID: CGSize] = [:],
        focused: WindowID? = nil
    ) -> PlanOutcome {
        guard let root = layout.root else {
            return .fits(Plan(layout: layout, rects: [:], assumedUnknown: [], rows: 0))
        }
        // Rounded once for the whole layout, so tiles share their edges and ratios written back from them reproduce the same tiles.
        let tileArea = options.tilingArea(area).integralInset
        var assumed = Set<WindowID>()
        let need = minimum(of: root, constraints: constraints, options: options, assumed: &assumed)
        if need.width > tileArea.width + 0.5 || need.height > tileArea.height + 0.5 {
            if case .leaf(let id) = root {
                return .unfit(Unfit(cause: .windowLargerThanArea(id, required: need, available: tileArea.size)))
            }
        }
        var caps = maximums
        // A single window ignores remembered short heights and fills the work area, as in AeroSpace.
        if layout.windowIDs.count != 1 {
            for (id, height) in layout.leftoverHeights where height > 0 {
                var size = caps[id] ?? .zero
                size.height = size.height > 0 ? min(size.height, height) : height
                caps[id] = size
            }
        }
        // A cap below the window's known minimum (a remembered short height, or a maximum learned at another width) gives way to the minimum,
        // since a window whose height follows its width would otherwise be asked again and again for less than it can be. An axis without a cap stays uncapped.
        for (id, cap) in caps {
            guard let minimum = constraints[id]?.size else { continue }
            caps[id] = CGSize(width: cap.width > 0 ? max(cap.width, minimum.width) : 0,
                              height: cap.height > 0 ? max(cap.height, minimum.height) : 0)
        }
        var rects: [WindowID: CGRect] = [:]
        if let unfit = place(root, in: tileArea, constraints: constraints, options: options, maximums: caps, focused: focused, rects: &rects) {
            return .unfit(unfit)
        }
        return .fits(Plan(layout: layout, rects: rects, assumedUnknown: assumed, rows: 0))
    }

    /// Initial layout. Prefers horizontal; if one row does not fit, adds rows up to a bound.
    /// Candidates are limited to rows of horizontal splits stacked vertically.
    public static func initial(
        for ids: [WindowID],
        in area: CGRect,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions = PlannerOptions(),
        maximums: [WindowID: CGSize] = [:]
    ) -> PlanOutcome {
        guard !ids.isEmpty else {
            return .fits(Plan(layout: Layout(root: nil), rects: [:], assumedUnknown: [], rows: 0))
        }
        var firstFailure: Unfit?
        var firstFit: Plan?
        for rows in 1...max(1, min(options.maxRows, ids.count)) {
            let layout = rowLayout(ids, rows: rows)
            switch fit(layout, in: area, constraints: constraints, options: options, maximums: maximums) {
            case .fits(var plan):
                plan.rows = rows
                let comfortable = plan.rects.values.allSatisfy { $0.width >= options.preferredMinimum.width && $0.height >= options.preferredMinimum.height }
                if comfortable { return .fits(plan) }
                if firstFit == nil { firstFit = plan }
            case .unfit(let u):
                if firstFailure == nil { firstFailure = u }
            }
        }
        if let firstFit { return .fits(firstFit) }
        return .unfit(firstFailure!)
    }

    /// Distributes n windows evenly over rows, from the front.
    public static func rowLayout(_ ids: [WindowID], rows: Int) -> Layout {
        precondition(rows >= 1)
        if rows == 1 {
            return Layout(root: rowNode(ids))
        }
        let base = ids.count / rows
        let extra = ids.count % rows
        var rowsNodes: [LayoutNode] = []
        var index = 0
        for r in 0..<rows {
            let count = base + (r < extra ? 1 : 0)
            if count == 0 { continue }
            rowsNodes.append(rowNode(Array(ids[index..<(index + count)])))
            index += count
        }
        if rowsNodes.count == 1 { return Layout(root: rowsNodes[0]) }
        let ratio = 1.0 / Double(rowsNodes.count)
        return Layout(root: .split(.vertical, children: rowsNodes, ratios: Array(repeating: ratio, count: rowsNodes.count)))
    }

    private static func rowNode(_ ids: [WindowID]) -> LayoutNode {
        if ids.count == 1 { return .leaf(ids[0]) }
        let ratio = 1.0 / Double(ids.count)
        return .split(.horizontal, children: ids.map { .leaf($0) }, ratios: Array(repeating: ratio, count: ids.count))
    }

    /// Minimum size the whole layout tree needs (used to check that the dialog region does not crush the tiles); 0 for an empty tree.
    /// Unknowns are filled with the provisional minimum.
    public static func minimumSize(of layout: Layout, constraints: [WindowID: SizeKnowledge], options: PlannerOptions) -> CGSize {
        guard let root = layout.root else { return .zero }
        var assumed: Set<WindowID> = []
        return minimum(of: root, constraints: constraints, options: options, assumed: &assumed)
    }

    static func minimum(
        of node: LayoutNode,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions,
        assumed: inout Set<WindowID>
    ) -> CGSize {
        switch node {
        case .leaf(let id):
            switch constraints[id] ?? .unknown {
            case .known(let s), .estimated(let s):
                // If only one axis is known (the other 0), fill that axis with the provisional minimum.
                var out = s
                if out.width <= 0 { out.width = options.unknownFloor.width; assumed.insert(id) }
                if out.height <= 0 { out.height = options.unknownFloor.height; assumed.insert(id) }
                return out
            case .unknown:
                assumed.insert(id)
                return options.unknownFloor
            }
        case .split(let axis, let children, _):
            let mins = children.map { minimum(of: $0, constraints: constraints, options: options, assumed: &assumed) }
            let gaps = Double(max(0, children.count - 1)) * options.innerGap(along: axis)
            switch axis {
            case .horizontal:
                return CGSize(width: mins.map(\.width).reduce(0, +) + gaps, height: mins.map(\.height).max() ?? 0)
            case .vertical:
                return CGSize(width: mins.map(\.width).max() ?? 0, height: mins.map(\.height).reduce(0, +) + gaps)
            }
        case .accordion(let axis, let children, _):
            let mins = children.map { minimum(of: $0, constraints: constraints, options: options, assumed: &assumed) }
            let pad = children.count > 1 ? options.accordionStrip * 2 : 0
            switch axis {
            case .horizontal:
                return CGSize(width: (mins.map(\.width).max() ?? 0) + pad, height: mins.map(\.height).max() ?? 0)
            case .vertical:
                return CGSize(width: mins.map(\.width).max() ?? 0, height: (mins.map(\.height).max() ?? 0) + pad)
            }
        }
    }

    /// The most a child can take along this axis; 0 or unset means no cap.
    /// A split of only capped windows does not grow beyond their total.
    static func maximumLength(of node: LayoutNode, along axis: Axis, maximums: [WindowID: CGSize], options: PlannerOptions) -> Double {
        switch node {
        case .leaf(let id):
            guard let cap = maximums[id] else { return .infinity }
            let value = axis == .horizontal ? cap.width : cap.height
            return value > 0 ? value : .infinity
        case .split(let childAxis, let children, _):
            let parts = children.map { maximumLength(of: $0, along: axis, maximums: maximums, options: options) }
            if parts.contains(where: \.isInfinite) { return .infinity }
            if childAxis == axis {
                let gaps = Double(max(0, children.count - 1)) * options.innerGap(along: axis)
                return parts.reduce(0, +) + gaps
            }
            return parts.max() ?? .infinity
        case .accordion(let childAxis, let children, _):
            let parts = children.map { maximumLength(of: $0, along: axis, maximums: maximums, options: options) }
            if parts.contains(where: \.isInfinite) { return .infinity }
            let longest = parts.max() ?? .infinity
            if childAxis == axis, children.count > 1 { return longest + options.accordionStrip * 2 }
            return longest
        }
    }

    private static func place(
        _ node: LayoutNode,
        in area: CGRect,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions,
        maximums: [WindowID: CGSize],
        focused: WindowID?,
        centersUnusedWidth: Bool = true,
        rects: inout [WindowID: CGRect]
    ) -> Unfit? {
        switch node {
        case .leaf(let id):
            var ignored = Set<WindowID>()
            let need = minimum(of: node, constraints: constraints, options: options, assumed: &ignored)
            if need.width > area.width + 0.5 || need.height > area.height + 0.5 {
                return Unfit(cause: .windowLargerThanArea(id, required: need, available: area.size))
            }
            var rect = area.integralInset
            if let cap = maximums[id] {
                // Width the window can't use is split evenly on both sides. Height it can't use stays below it, where a new window can join.
                if cap.width > 0, cap.width < rect.width {
                    if centersUnusedWidth { rect.origin.x += floor((rect.width - cap.width) / 2) }
                    rect.size.width = cap.width
                }
                if cap.height > 0 { rect.size.height = min(rect.height, cap.height) }
            }
            rects[id] = rect
            return nil
        case .split(let axis, let children, let ratios):
            var ignored = Set<WindowID>()
            let mins = children.map { minimum(of: $0, constraints: constraints, options: options, assumed: &ignored) }
            let gaps = Double(max(0, children.count - 1)) * options.innerGap(along: axis)
            let available = (axis == .horizontal ? area.width : area.height) - gaps
            let required: [Double] = mins.map { Double(axis == .horizontal ? $0.width : $0.height) }
            let caps = children.map { maximumLength(of: $0, along: axis, maximums: maximums, options: options) }
            guard let lengths = distribute(available: available, ratios: ratios, minimums: required, maximums: caps) else {
                return Unfit(cause: .splitOverflow(axis, required: required.reduce(0, +) + gaps, available: available + gaps, members: node.windowIDs))
            }
            // Width that capped children leave unused is split evenly on both sides of the row, as for a single capped window.
            let unusedWidth = axis == .horizontal && centersUnusedWidth ? max(0, available - lengths.reduce(0, +)) : 0
            var cursor = axis == .horizontal ? area.minX + floor(unusedWidth / 2) : area.minY
            for (index, child) in children.enumerated() {
                let length = lengths[index]
                let childArea: CGRect
                switch axis {
                case .horizontal:
                    childArea = CGRect(x: cursor, y: area.minY, width: length, height: area.height)
                case .vertical:
                    childArea = CGRect(x: area.minX, y: cursor, width: area.width, height: length)
                }
                if let unfit = place(child, in: childArea, constraints: constraints, options: options, maximums: maximums, focused: focused, centersUnusedWidth: centersUnusedWidth, rects: &rects) {
                    return unfit
                }
                cursor += length + options.innerGap(along: axis)
            }
            return nil
        case .accordion(let axis, let children, _):
            let padding = options.accordionStrip
            let mru = focused.flatMap { id in children.firstIndex { $0.windowIDs.contains(id) } } ?? 0
            for (index, child) in children.enumerated() {
                let (leading, trailing) = accordionInset(index: index, count: children.count, mru: mru, padding: padding)
                let childArea: CGRect
                switch axis {
                case .horizontal:
                    childArea = CGRect(x: area.minX + leading, y: area.minY, width: area.width - leading - trailing, height: area.height)
                case .vertical:
                    childArea = CGRect(x: area.minX, y: area.minY + leading, width: area.width, height: area.height - leading - trailing)
                }
                if childArea.width < -0.5 || childArea.height < -0.5 {
                    return Unfit(cause: .windowLargerThanArea(child.windowIDs.first ?? WindowID(0), required: childArea.size, available: area.size))
                }
                // Centering a window that sits behind the front one would hide the strip that shows it, so accordion windows keep their leading edge.
                if let unfit = place(child, in: childArea, constraints: constraints, options: options, maximums: maximums, focused: focused, centersUnusedWidth: false, rects: &rects) {
                    return unfit
                }
            }
            return nil
        }
    }

    /// The same strips as AeroSpace's layoutAccordion: only the first, last, and focus neighbors differ in width; far windows hide behind the focused one.
    static func accordionInset(index: Int, count: Int, mru: Int, padding: Double) -> (Double, Double) {
        switch index {
        case 0 where count == 1: return (0, 0)
        case 0: return (0, padding)
        case count - 1: return (padding, 0)
        case mru - 1: return (0, padding * 2)
        case mru + 1: return (padding * 2, 0)
        default: return (padding, padding)
        }
    }

    /// Distributes by ratio, pins elements below their minimum to it and above their cap to it, and redistributes the rest.
    /// If pinning minimums and caps at once in the same pass leaves no fit, searches for a common scale on the ratios at which the lengths clamped
    /// to minimum and cap sum to the area (a re-pinnable distribution). nil when the minimums do not fit. When the caps sum to less than the area,
    /// space is left instead of stretching. Without caps, the remainder goes to the last element.
    /// length = clamp(scale x ratio, minimum, cap). The sum is monotonic in the scale, so bisection finds the scale that matches the area.
    /// The caller guarantees minimums sum to at most the area and caps sum to more than it.
    private static func scaledWithinBounds(available: Double, ratios: [Double], minimums: [Double], caps: [Double]) -> [Double] {
        let weights = ratios.reduce(0, +) > 0 ? ratios : ratios.map { _ in 1 }
        func lengths(_ scale: Double) -> [Double] {
            weights.indices.map { min(caps[$0], max(minimums[$0], scale * weights[$0])) }
        }
        var low = 0.0
        var high = available / max(weights.filter { $0 > 0 }.min() ?? 1, .ulpOfOne)
        for _ in 0..<100 {
            let mid = (low + high) / 2
            if lengths(mid).reduce(0, +) < available { low = mid } else { high = mid }
        }
        return lengths(high)
    }

    static func distribute(available: Double, ratios: [Double], minimums: [Double], maximums: [Double]? = nil) -> [Double]? {
        precondition(ratios.count == minimums.count)
        let n = ratios.count
        if n == 0 { return [] }
        if minimums.reduce(0, +) > available + 0.5 { return nil }
        let caps = maximums ?? Array(repeating: Double.infinity, count: n)
        precondition(caps.count == n)
        var atMin = [Bool](repeating: false, count: n)
        var atMax = [Bool](repeating: false, count: n)
        var lengths = [Double](repeating: 0, count: n)
        for _ in 0...n {
            var reserved = 0.0
            var ratioSum = 0.0
            var open = 0
            for i in 0..<n {
                if atMin[i] { reserved += minimums[i] }
                else if atMax[i] { reserved += caps[i] }
                else { ratioSum += ratios[i]; open += 1 }
            }
            let free = available - reserved
            if free < -0.5 {
                lengths = scaledWithinBounds(available: available, ratios: ratios, minimums: minimums, caps: caps)
                break
            }
            if open == 0 {
                for i in 0..<n { lengths[i] = atMax[i] ? caps[i] : minimums[i] }
                break
            }
            var changed = false
            for i in 0..<n where !atMin[i] && !atMax[i] {
                let share = ratioSum > 0 ? free * ratios[i] / ratioSum : free / Double(open)
                if share < minimums[i] {
                    atMin[i] = true
                    lengths[i] = minimums[i]
                    changed = true
                } else if share >= caps[i] {
                    atMax[i] = true
                    lengths[i] = caps[i]
                    changed = true
                } else {
                    lengths[i] = share
                }
            }
            if !changed { break }
        }
        var rounded = lengths.map { floor($0) }
        var leftover = available - rounded.reduce(0, +)
        if !caps.contains(where: \.isFinite) {
            if let last = rounded.indices.last { rounded[last] += floor(leftover) }
            return rounded
        }
        // Capped windows do not grow even by a remainder; leftover pixels go, from the back, to windows still below their cap.
        var index = n - 1
        while leftover >= 1, index >= 0 {
            let room = floor(caps[index] - rounded[index])
            if room > 0 {
                let give = min(leftover, room)
                rounded[index] += give
                leftover -= give
            }
            index -= 1
        }
        return rounded
    }
}

extension CGRect {
    /// Aligns to integer coordinates (origin rounded up, size rounded down).
    public var integralInset: CGRect {
        let x = ceil(minX), y = ceil(minY)
        let w = floor(maxX) - x, h = floor(maxY) - y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Whether every edge matches within tolerance.
    public func matches(_ other: CGRect, tolerance: Double) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}
