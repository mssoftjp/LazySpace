import CoreGraphics
import Foundation

public enum Direction: String, Codable, CaseIterable {
    case left, right, up, down

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    public var isForward: Bool { self == .right || self == .down }
}

/// Edits to layout intent. Positions and sizes come only from computed frames (rects); never touches the OS.
public enum LayoutEdit {
    // MARK: Neighbors

    /// Among windows touching in the direction, the one with the largest edge overlap.
    public static func neighbor(of id: WindowID, direction: Direction, rects: [WindowID: CGRect], tolerance: Double = 2, layout: Layout? = nil) -> WindowID? {
        if let layout, let sibling = accordionNeighbor(of: id, direction: direction, in: layout) { return sibling }
        guard let me = rects[id] else { return nil }
        var candidates: [(id: WindowID, overlap: Double, distance: Double, crossPosition: Double)] = []
        for (other, r) in rects where other != id {
            let overlap: Double
            let distance: Double
            switch direction {
            case .right: overlap = verticalOverlap(me, r); distance = r.minX - me.maxX
            case .left: overlap = verticalOverlap(me, r); distance = me.minX - r.maxX
            case .down: overlap = horizontalOverlap(me, r); distance = r.minY - me.maxY
            case .up: overlap = horizontalOverlap(me, r); distance = me.minY - r.maxY
            }
            guard overlap > 0, distance >= -tolerance else { continue }
            candidates.append((other, overlap, distance, direction.axis == .horizontal ? r.minY : r.minX))
        }
        // Measure the tolerance from the nearest edge. Comparing candidates with each other chains proximity, and dictionary order would change the result.
        guard let nearest = candidates.map(\.distance).min() else { return nil }
        return candidates.filter { $0.distance <= nearest + tolerance }.sorted {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.crossPosition != $1.crossPosition { return $0.crossPosition < $1.crossPosition }
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.id.raw < $1.id.raw
        }.first?.id
    }

    /// Accordion windows overlap, so the neighbor along its direction comes from tree siblings. At the end, nil, and frames lead out to the tiles beyond.
    private static func accordionNeighbor(of id: WindowID, direction: Direction, in layout: Layout) -> WindowID? {
        guard let root = layout.root, let path = pathTo(id, in: root) else { return nil }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let node = node(at: Array(path.prefix(depth)), in: root)
            guard let box = node.box, box.accordion, box.axis == direction.axis else { continue }
            let next = direction.isForward ? path[depth] + 1 : path[depth] - 1
            guard box.children.indices.contains(next) else { continue }
            return box.children[next].windowIDs.first
        }
        return nil
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> Double { max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) }
    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> Double { max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }

    // MARK: Swap

    public static func swap(_ a: WindowID, _ b: WindowID, in layout: Layout) -> Layout {
        guard a != b, layout.windowIDs.contains(a), layout.windowIDs.contains(b), let root = layout.root else { return layout }
        return layout.replacingRoot(mapLeaves(root) { $0 == a ? b : ($0 == b ? a : $0) }).normalized()
    }

    // MARK: Move

    /// When b is id's adjacent sibling on the direction side in a split along the direction, only the order changes and every window keeps its share,
    /// as AeroSpace does (reinsertion would halve b's share and hand id's share to another window).
    /// Otherwise takes id out of the tree and places it beside neighbor b (on the direction side). If b's parent has the same axis, id shares b's share as a sibling;
    /// otherwise b's place becomes a [id, b] / [b, id] split.
    /// When moving up or down, the two drop their short height caps and share the column.
    public static func move(_ id: WindowID, toward b: WindowID, direction: Direction, in layout: Layout) -> Layout {
        guard id != b, layout.windowIDs.contains(id), layout.windowIDs.contains(b), let root = layout.root else { return layout }
        let next: Layout
        if let reordered = reorderingSiblings(id, b, direction: direction, in: root) {
            next = layout.replacingRoot(reordered)
        } else {
            guard let pruned = Layout.pruneForEdit(root, removing: id) else { return layout }
            next = layout.replacingRoot(insertBeside(b, in: pruned, id: id, direction: direction))
        }
        guard direction.axis == .vertical else { return next.normalized() }
        var heights = next.leftoverHeights
        heights[id] = nil
        heights[b] = nil
        return Layout(root: next.root, leftoverHeights: heights).normalized()
    }

    /// The root with id and b exchanged, with their shares, when both are leaves of one split along the direction and b is next to id on that side; nil otherwise.
    private static func reorderingSiblings(_ id: WindowID, _ b: WindowID, direction: Direction, in root: LayoutNode) -> LayoutNode? {
        guard let pathA = pathTo(id, in: root), let pathB = pathTo(b, in: root), let i = pathA.last, let j = pathB.last,
              pathA.dropLast() == pathB.dropLast(), j == (direction.isForward ? i + 1 : i - 1) else { return nil }
        let parentPath = Array(pathA.dropLast())
        guard let box = node(at: parentPath, in: root).box, box.axis == direction.axis else { return nil }
        var children = box.children
        var ratios = box.ratios
        children.swapAt(i, j)
        ratios.swapAt(i, j)
        return replace(at: parentPath, in: root, with: LayoutNode.container(axis: box.axis, children: children, ratios: ratios, accordion: box.accordion))
    }

    private static func insertBeside(_ b: WindowID, in node: LayoutNode, id: WindowID, direction: Direction) -> LayoutNode {
        switch node {
        case .leaf(let leaf):
            guard leaf == b else { return node }
            let pair: [LayoutNode] = direction.isForward ? [.leaf(b), .leaf(id)] : [.leaf(id), .leaf(b)]
            return .split(direction.axis, children: pair, ratios: [0.5, 0.5])
        case .split(let axis, let children, let ratios), .accordion(let axis, let children, let ratios):
            let accordion = node.box?.accordion ?? false
            if axis == direction.axis, let index = children.firstIndex(where: { if case .leaf(let l) = $0 { return l == b } else { return false } }) {
                var newChildren = children
                var newRatios = ratios
                let share = ratios[index] / 2
                newRatios[index] = share
                let insertAt = direction.isForward ? index + 1 : index
                newChildren.insert(.leaf(id), at: insertAt)
                newRatios.insert(share, at: insertAt)
                return LayoutNode.container(axis: axis, children: newChildren, ratios: newRatios, accordion: accordion)
            }
            return LayoutNode.container(axis: axis, children: children.map { insertBeside(b, in: $0, id: id, direction: direction) }, ratios: ratios, accordion: accordion)
        }
    }

    // MARK: Join

    /// Puts id into neighbor b's place, sharing it with b in a nested split perpendicular to the direction.
    public static func join(_ id: WindowID, with b: WindowID, direction: Direction, in layout: Layout) -> Layout {
        guard id != b, layout.windowIDs.contains(id), layout.windowIDs.contains(b), let root = layout.root else { return layout }
        guard let pruned = Layout.pruneForEdit(root, removing: id) else { return layout }
        let perpendicular: Axis = direction.axis == .horizontal ? .vertical : .horizontal
        let replaced = mapNodes(pruned) { node in
            if case .leaf(let l) = node, l == b {
                return .split(perpendicular, children: [.leaf(b), .leaf(id)], ratios: [0.5, 0.5])
            }
            return node
        }
        var next = layout.replacingRoot(replaced)
        if perpendicular == .vertical {
            var heights = next.leftoverHeights
            heights[id] = nil
            heights[b] = nil
            next = Layout(root: next.root, leftoverHeights: heights)
        }
        return next.normalized()
    }

    // MARK: Resize

    /// In the nearest same-axis split containing id, grows id's share by delta (shrinks if negative), taking it from a neighboring sibling.
    /// With edge, the sibling beside the moved boundary compensates; edit commands without one prefer the next sibling.
    public static func resize(_ id: WindowID, axis: Axis, by delta: Double, in layout: Layout, edge: Direction? = nil, minimumRatio: Double = 0.05) -> Layout? {
        guard delta.isFinite, let root = layout.root, let path = pathTo(id, in: root) else { return nil }
        // Walk up from the leaf to find a same-axis split.
        var node = root
        var nodesOnPath: [LayoutNode] = [root]
        for index in path {
            guard let children = node.box?.children else { break }
            node = children[index]
            nodesOnPath.append(node)
        }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            guard let box = nodesOnPath[depth].box, box.axis == axis, box.children.count >= 2 else { continue }
            let children = box.children
            var ratios = box.ratios
            let accordion = box.accordion
            let i = path[depth]
            let j: Int
            if edge == .left || edge == .up {
                guard i > 0 else { return nil }
                j = i - 1
            } else if edge == .right || edge == .down {
                guard i + 1 < children.count else { return nil }
                j = i + 1
            } else {
                j = i + 1 < children.count ? i + 1 : i - 1
            }
            let change = min(delta, ratios[j] - minimumRatio)
            let applied = max(change, minimumRatio - ratios[i])
            if applied == 0 { return nil }
            ratios[i] += applied
            ratios[j] -= applied
            let newNode = LayoutNode.container(axis: box.axis, children: children, ratios: ratios, accordion: accordion)
            let resized = layout.replacingRoot(replace(at: Array(path.prefix(depth)), in: root, with: newNode))
            // A leaf whose vertical share changed drops its short height cap so the new ratio applies.
            guard axis == .vertical else { return resized.normalized() }
            var heights = resized.leftoverHeights
            for id in newNode.windowIDs { heights[id] = nil }
            return Layout(root: resized.root, leftoverHeights: heights).normalized()
        }
        return nil
    }

    // MARK: Orientation

    /// Flips the orientation of id's parent split; nil without a parent.
    public static func toggleOrientation(of id: WindowID, in layout: Layout) -> Layout? {
        guard let root = layout.root, let path = pathTo(id, in: root), !path.isEmpty else { return nil }
        let parentPath = Array(path.dropLast())
        guard let box = node(at: parentPath, in: root).box else { return nil }
        let newAxis: Axis = box.axis == .horizontal ? .vertical : .horizontal
        let flipped = LayoutNode.container(axis: newAxis, children: box.children, ratios: box.ratios, accordion: box.accordion)
        var next = layout.replacingRoot(replace(at: parentPath, in: root, with: flipped))
        if newAxis == .vertical {
            var heights = next.leftoverHeights
            for leaf in flipped.windowIDs { heights[leaf] = nil }
            next = Layout(root: next.root, leftoverHeights: heights)
        }
        return next.normalized()
    }

    /// Toggles the focused window's parent between tiles and accordion, keeping orientation and ratios.
    public static func toggleAccordion(of id: WindowID, in layout: Layout) -> Layout? {
        guard let root = layout.root, let path = pathTo(id, in: root), !path.isEmpty else { return nil }
        let parentPath = Array(path.dropLast())
        guard let box = node(at: parentPath, in: root).box, box.children.count >= 2 else { return nil }
        let flipped = LayoutNode.container(axis: box.axis, children: box.children, ratios: box.ratios, accordion: !box.accordion)
        return layout.replacingRoot(replace(at: parentPath, in: root, with: flipped)).normalized()
    }

    // MARK: - Tree helpers

    static func mapLeaves(_ node: LayoutNode, _ f: (WindowID) -> WindowID) -> LayoutNode {
        switch node {
        case .leaf(let id): return .leaf(f(id))
        case .split(let a, let c, let r): return .split(a, children: c.map { mapLeaves($0, f) }, ratios: r)
        case .accordion(let a, let c, let r): return .accordion(a, children: c.map { mapLeaves($0, f) }, ratios: r)
        }
    }

    static func mapNodes(_ node: LayoutNode, _ f: (LayoutNode) -> LayoutNode) -> LayoutNode {
        let mapped = f(node)
        if let box = mapped.box, mapped == node {
            return LayoutNode.container(axis: box.axis, children: box.children.map { mapNodes($0, f) }, ratios: box.ratios, accordion: box.accordion)
        }
        return mapped
    }

    static func pathTo(_ id: WindowID, in node: LayoutNode) -> [Int]? {
        switch node {
        case .leaf(let l): return l == id ? [] : nil
        case .split(_, let children, _), .accordion(_, let children, _):
            for (i, c) in children.enumerated() {
                if let p = pathTo(id, in: c) { return [i] + p }
            }
            return nil
        }
    }

    static func node(at path: [Int], in root: LayoutNode) -> LayoutNode {
        var n = root
        for i in path {
            guard let children = n.box?.children else { return n }
            n = children[i]
        }
        return n
    }

    static func replace(at path: [Int], in root: LayoutNode, with newNode: LayoutNode) -> LayoutNode {
        guard let first = path.first else { return newNode }
        guard let box = root.box else { return newNode }
        var children = box.children
        children[first] = replace(at: Array(path.dropFirst()), in: children[first], with: newNode)
        return LayoutNode.container(axis: box.axis, children: children, ratios: box.ratios, accordion: box.accordion)
    }
}

extension Layout {
    /// Removal for edits: collapses single children and normalizes ratios.
    static func pruneForEdit(_ root: LayoutNode, removing id: WindowID) -> LayoutNode? {
        Layout(root: root).removing([id]).root
    }
}

extension LayoutEdit {
    /// Length covered by the nearest same-axis split containing id (union of its leaves' frames); nil if none.
    public static func containerExtent(of id: WindowID, axis: Axis, in layout: Layout, rects: [WindowID: CGRect]) -> Double? {
        guard let n = nearestContainer(of: id, axis: axis, in: layout) else { return nil }
        let leafRects = n.windowIDs.compactMap { rects[$0] }
        guard let first = leafRects.first else { return nil }
        let union = leafRects.dropFirst().reduce(first) { $0.union($1) }
        return axis == .horizontal ? union.width : union.height
    }

    /// The nearest split or accordion of this axis containing id.
    static func nearestContainer(of id: WindowID, axis: Axis, in layout: Layout) -> LayoutNode? {
        guard let root = layout.root, let path = pathTo(id, in: root) else { return nil }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let n = node(at: Array(path.prefix(depth)), in: root)
            if let box = n.box, box.axis == axis { return n }
        }
        return nil
    }

    /// The other windows of the innermost accordion containing id; empty outside accordions.
    static func accordionSiblings(of id: WindowID, in layout: Layout) -> Set<WindowID> {
        guard let root = layout.root, let path = pathTo(id, in: root) else { return [] }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let n = node(at: Array(path.prefix(depth)), in: root)
            if n.box?.accordion == true { return Set(n.windowIDs).subtracting([id]) }
        }
        return []
    }
}

/// Decides how a mouse edit (manual move or resize) is adopted into layout intent. Never touches the OS.
public enum ManualEdit: Equatable {
    /// An edge moved: ratio changes per axis.
    case resize(WindowID, [(Axis, Double, Direction)])
    /// Dropped onto another managed window.
    case dropOnto(WindowID, WindowID)
    /// Moved out of the layout (including OS snapping): float it in place.
    case float(WindowID)

    public static func == (a: ManualEdit, b: ManualEdit) -> Bool {
        switch (a, b) {
        case (.resize(let x, let dx), .resize(let y, let dy)): return x == y && dx.map { "\($0.0)\($0.1)\($0.2)" } == dy.map { "\($0.0)\($0.1)\($0.2)" }
        case (.dropOnto(let a1, let a2), .dropOnto(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.float(let x), .float(let y)): return x == y
        default: return false
        }
    }

    /// Identifies one user edit from the difference between the planned and actual frames; nil when there is none.
    /// `layout` is the intent, and `shape` the plan's tree as placed, when it differs. Resizing along an accordion's axis, folded or not, is no edit.
    /// A drop never targets a sibling in a real accordion, whose frames do not tell where it landed; in a fold it swaps, as between tiles.
    /// A drop is judged at `pointer`, where the button was released, when `actual` holds it (the window was dragged by it), otherwise at its center.
    public static func detect(id: WindowID, planned: CGRect, actual: CGRect, layout: Layout, shape: Layout? = nil, plannedRects: [WindowID: CGRect], tolerance: Double = 1,
                              pointer: CGPoint? = nil) -> ManualEdit? {
        if actual.matches(planned, tolerance: tolerance) { return nil }
        let sizeChanged = abs(actual.width - planned.width) > tolerance || abs(actual.height - planned.height) > tolerance
        let leftFixed = abs(actual.minX - planned.minX) <= tolerance, rightFixed = abs(actual.maxX - planned.maxX) <= tolerance
        let topFixed = abs(actual.minY - planned.minY) <= tolerance, bottomFixed = abs(actual.maxY - planned.maxY) <= tolerance
        let anchored = (leftFixed || rightFixed) && (topFixed || bottomFixed)
        if sizeChanged && anchored {
            var deltas: [(Axis, Double, Direction)] = []
            var alongAccordion = false
            func delta(_ axis: Axis, _ change: Double, _ direction: Direction) {
                guard abs(change) > tolerance else { return }
                if LayoutEdit.nearestContainer(of: id, axis: axis, in: shape ?? layout)?.box?.accordion == true { alongAccordion = true; return }
                guard let extent = LayoutEdit.containerExtent(of: id, axis: axis, in: shape ?? layout, rects: plannedRects), extent > 0 else { return }
                deltas.append((axis, change / extent, direction))
            }
            delta(.horizontal, actual.width - planned.width, leftFixed ? .right : .left)
            delta(.vertical, actual.height - planned.height, topFixed ? .down : .up)
            if !deltas.isEmpty { return .resize(id, deltas) }
            return alongAccordion ? nil : .float(id)
        }
        if !sizeChanged {
            // Where it was dropped: the pointer at release when the window holds it, otherwise the window's center.
            let point = pointer.flatMap { actual.contains($0) ? $0 : nil } ?? CGPoint(x: actual.midX, y: actual.midY)
            let siblings = LayoutEdit.accordionSiblings(of: id, in: layout)
            let order = Dictionary(layout.windowIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            // Frames can overlap, so a drop point still over the window's own frame is no drop: any nudge in a fold would swap.
            let under = planned.contains(point) ? [] : plannedRects.filter { $0.key != id && !siblings.contains($0.key) && $0.value.contains(point) }.map(\.key)
            // A real accordion counts once, by the first of its windows in the tree, which is the one in front while the dragged window has focus.
            let targets = under.filter { target in
                !LayoutEdit.accordionSiblings(of: target, in: layout).contains { under.contains($0) && (order[$0] ?? Int.max) < (order[target] ?? Int.max) }
            }
            // In a fold it lands on the window whose center is nearest to the drop point; the first in the tree on a tie.
            func distance(_ target: WindowID) -> Double {
                plannedRects[target].map { hypot($0.midX - point.x, $0.midY - point.y) } ?? .infinity
            }
            if let target = targets.min(by: { (distance($0), order[$0] ?? Int.max, $0.raw) < (distance($1), order[$1] ?? Int.max, $1.raw) }) { return .dropOnto(id, target) }
            // Still over its own accordion: no edit, and drift puts it back.
            if siblings.contains(where: { plannedRects[$0]?.contains(point) ?? false }) { return nil }
            return .float(id)
        }
        return .float(id)
    }
}
