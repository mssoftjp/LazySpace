import CoreGraphics
import Foundation

/// Window identifier: the CGWindowID itself.
public struct WindowID: Hashable, Codable, Comparable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public static func < (a: WindowID, b: WindowID) -> Bool { a.raw < b.raw }
    public var description: String { "w\(raw)" }
}

public enum Axis: String, Codable {
    case horizontal
    case vertical
}

/// Knowledge of size constraints. "Unknown" is not "no minimum size".
public enum SizeKnowledge: Equatable, Codable {
    /// A value obtained from the OS or app.
    case known(CGSize)
    /// Inferred from measurements; invalidated by expiry or contradiction.
    case estimated(CGSize)
    case unknown

    public var size: CGSize? {
        switch self {
        case .known(let s), .estimated(let s): return s
        case .unknown: return nil
        }
    }

    /// Combines two pieces of knowledge: known > estimated > unknown; the same kind takes the larger value per axis.
    public func merged(with other: SizeKnowledge) -> SizeKnowledge {
        switch (self, other) {
        case (.unknown, _): return other
        case (_, .unknown): return self
        case (.known(let a), .known(let b)): return .known(CGSize(width: max(a.width, b.width), height: max(a.height, b.height)))
        case (.known, .estimated): return self
        case (.estimated, .known): return other
        case (.estimated(let a), .estimated(let b)): return .estimated(CGSize(width: max(a.width, b.width), height: max(a.height, b.height)))
        }
    }
}

/// Layout intent: split structure and ratios, without positions or sizes.
/// An accordion has the same children and ratios, but the focused window takes most of the frame instead of following the ratios.
public indirect enum LayoutNode: Equatable, Codable {
    case leaf(WindowID)
    case split(Axis, children: [LayoutNode], ratios: [Double])
    case accordion(Axis, children: [LayoutNode], ratios: [Double])

    /// Contents shared by tile splits and accordions; nil for a leaf.
    public var box: (axis: Axis, children: [LayoutNode], ratios: [Double], accordion: Bool)? {
        switch self {
        case .leaf: return nil
        case .split(let axis, let children, let ratios): return (axis, children, ratios, false)
        case .accordion(let axis, let children, let ratios): return (axis, children, ratios, true)
        }
    }

    public static func container(axis: Axis, children: [LayoutNode], ratios: [Double], accordion: Bool) -> LayoutNode {
        accordion
            ? .accordion(axis, children: children, ratios: ratios)
            : .split(axis, children: children, ratios: ratios)
    }

    public var windowIDs: [WindowID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let children, _), .accordion(_, let children, _): return children.flatMap { $0.windowIDs }
        }
    }

    /// There is an accordion split containing id.
    public func containsAccordion(around id: WindowID? = nil) -> Bool {
        switch self {
        case .leaf:
            return false
        case .split(_, let children, _):
            return children.contains { $0.containsAccordion(around: id) }
        case .accordion(_, let children, _):
            guard let id else { return true }
            if windowIDs.contains(id) { return true }
            return children.contains { $0.containsAccordion(around: id) }
        }
    }

    public var leafCount: Int { windowIDs.count }

    private enum CodingKeys: String, CodingKey { case kind, id, axis, children, ratios }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        if kind == "leaf" {
            self = .leaf(try c.decode(WindowID.self, forKey: .id))
        } else {
            let axis = try c.decode(Axis.self, forKey: .axis)
            let children = try c.decode([LayoutNode].self, forKey: .children)
            guard !children.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "A container needs at least one child.")
            }
            let ratios = Self.repairedRatios(try c.decode([Double].self, forKey: .ratios), count: children.count)
            self = kind == "accordion"
                ? .accordion(axis, children: children, ratios: ratios)
                : .split(axis, children: children, ratios: ratios)
        }
    }

    /// Resets saved ratios to equal shares when they do not match the child count or are not positive and finite, so out-of-range reads never crash.
    static func repairedRatios(_ ratios: [Double], count: Int) -> [Double] {
        if ratios.count == count, ratios.allSatisfy({ $0.isFinite && $0 > 0 }) { return ratios }
        return Array(repeating: 1 / Double(count), count: count)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode("leaf", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .split(let axis, let children, let ratios):
            try c.encode("split", forKey: .kind)
            try c.encode(axis, forKey: .axis)
            try c.encode(children, forKey: .children)
            try c.encode(ratios, forKey: .ratios)
        case .accordion(let axis, let children, let ratios):
            try c.encode("accordion", forKey: .kind)
            try c.encode(axis, forKey: .axis)
            try c.encode(children, forKey: .children)
            try c.encode(ratios, forKey: .ratios)
        }
    }
}

public struct Layout: Equatable, Codable {
    public var root: LayoutNode?
    /// Heights of leaves that did not fill their column, keeping short leaves that horizontal ratios cannot express for the next calculation.
    public var leftoverHeights: [WindowID: Double]
    public init(root: LayoutNode?, leftoverHeights: [WindowID: Double] = [:]) {
        self.root = root
        self.leftoverHeights = leftoverHeights.filter { $0.value > 0 }
    }
    public var windowIDs: [WindowID] { root?.windowIDs ?? [] }

    public func containsAccordion(around id: WindowID? = nil) -> Bool {
        root?.containsAccordion(around: id) ?? false
    }

    private enum CodingKeys: String, CodingKey { case root, leftoverHeights }

    private struct HeightEntry: Codable {
        var id: WindowID
        var height: Double
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(LayoutNode.self, forKey: .root)
        let entries = try c.decodeIfPresent([HeightEntry].self, forKey: .leftoverHeights) ?? []
        // Saved state with duplicate IDs does not crash; the first value wins.
        leftoverHeights = Dictionary(entries.map { ($0.id, $0.height) }, uniquingKeysWith: { first, _ in first })
            .filter { $0.value.isFinite && $0.value > 0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(root, forKey: .root)
        if !leftoverHeights.isEmpty {
            try c.encode(leftoverHeights.map { HeightEntry(id: $0.key, height: $0.value) }.sorted { $0.id < $1.id }, forKey: .leftoverHeights)
        }
    }

    public func replacingRoot(_ newRoot: LayoutNode?) -> Layout {
        Layout(root: newRoot, leftoverHeights: leftoverHeights)
    }

    /// Replaces a leaf's ID; used when a tab switch swaps windows in the same frame.
    public func replacing(_ id: WindowID, with newID: WindowID) -> Layout {
        guard let root, windowIDs.contains(id) else { return self }
        func go(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .leaf(let leaf): return .leaf(leaf == id ? newID : leaf)
            case .split(let axis, let children, let ratios): return .split(axis, children: children.map(go), ratios: ratios)
            case .accordion(let axis, let children, let ratios): return .accordion(axis, children: children.map(go), ratios: ratios)
            }
        }
        var heights = leftoverHeights
        if let height = heights.removeValue(forKey: id) { heights[newID] = height }
        return Layout(root: go(root), leftoverHeights: heights)
    }

    /// Collapses single-child splits and merges nested splits of the parent's direction in place.
    /// Ratios are multiplied by the parent's share, so frames do not change; remaining nested splits run opposite to their parent.
    public func normalized() -> Layout {
        Layout(root: root.map(Layout.flattenSameAxis), leftoverHeights: leftoverHeights)
    }

    private static func flattenSameAxis(_ node: LayoutNode) -> LayoutNode {
        guard let box = node.box else { return node }
        var flatChildren: [LayoutNode] = []
        var flatRatios: [Double] = []
        for (child, ratio) in zip(box.children, box.ratios) {
            let flat = flattenSameAxis(child)
            // Merging an accordion into a tile parent would lose its strip order; an accordion parent does absorb same-direction tiles.
            if let nested = flat.box, nested.axis == box.axis, box.accordion || !nested.accordion {
                for (nestedChild, nestedRatio) in zip(nested.children, nested.ratios) {
                    flatChildren.append(nestedChild)
                    flatRatios.append(ratio * nestedRatio)
                }
            } else {
                flatChildren.append(flat)
                flatRatios.append(ratio)
            }
        }
        if flatChildren.count == 1 { return flatChildren[0] }
        let total = flatRatios.reduce(0, +)
        let scaled = total > 0
            ? flatRatios.map { $0 / total }
            : Array(repeating: 1 / Double(flatChildren.count), count: flatChildren.count)
        return LayoutNode.container(axis: box.axis, children: flatChildren, ratios: scaled, accordion: box.accordion)
    }

    /// Removes vanished windows from the layout intent, collapsing single-child splits.
    /// When a leaf other than the first of a vertical split remains, its short height is dropped so it fills the column.
    public func removing(_ gone: Set<WindowID>, keepHeights: Set<WindowID> = []) -> Layout {
        let promoted = root.map { Layout.guestsPromoted(byPruning: $0, gone: gone) } ?? []
        var heights = leftoverHeights
        for id in gone.union(promoted) where !keepHeights.contains(id) { heights[id] = nil }
        let layout = Layout(root: root.flatMap { Layout.prune($0, gone: gone) }, leftoverHeights: heights).normalized()
        // A single remaining window does not inherit the column's short height. Heights of removed windows are kept for restoring.
        if layout.windowIDs.count <= 1 {
            var kept = layout.leftoverHeights
            for id in layout.windowIDs { kept[id] = nil }
            return Layout(root: layout.root, leftoverHeights: kept)
        }
        return layout
    }

    /// Unused height below a leaf: among leaves meeting need in width and height, the one with the largest area.
    public struct UnusedStackHost: Equatable {
        public var id: WindowID
        public var usedHeight: Double
        public var unusedHeight: Double
        public init(id: WindowID, usedHeight: Double, unusedHeight: Double) {
            self.id = id
            self.usedHeight = usedHeight
            self.unusedHeight = unusedHeight
        }
    }

    public func unusedStackHost(rects: [WindowID: CGRect], area: CGRect, need: CGSize, tolerance: CGFloat = 1) -> UnusedStackHost? {
        var best: UnusedStackHost?
        var bestArea = 0.0
        for id in windowIDs {
            guard let frame = rects[id] else { continue }
            var bottom = area.maxY
            for otherID in windowIDs where otherID != id {
                guard let other = rects[otherID] else { continue }
                let overlapX = other.minX < frame.maxX - tolerance && other.maxX > frame.minX + tolerance
                if overlapX, other.minY >= frame.maxY - tolerance {
                    bottom = min(bottom, other.minY)
                }
            }
            let unused = bottom - frame.maxY
            guard frame.width + tolerance >= need.width, unused + tolerance >= need.height else { continue }
            let score = unused * frame.width
            if score > bestArea {
                bestArea = score
                best = UnusedStackHost(id: id, usedHeight: frame.height, unusedHeight: unused)
            }
        }
        return best
    }

    /// Adds a new window while keeping the existing structure.
    /// - Empty: a leaf. A leaf: a horizontal split. A horizontal split: appended, weighted at the siblings' average.
    /// - A vertical split (stacked rows): added to the row with the fewest leaves (the last one on a tie).
    public func inserting(_ id: WindowID) -> Layout {
        if windowIDs.contains(id) { return self }
        guard let root else { return replacingRoot(.leaf(id)) }
        return replacingRoot(Layout.insert(id, into: root)).normalized()
    }

    /// Stacks into the unused space below the given leaf, with ratios of its current height to the space. Other leaves' frames stay.
    public func inserting(_ id: WindowID, stackingBelow target: WindowID, hostHeight: Double, unusedHeight: Double) -> Layout {
        if windowIDs.contains(id) { return self }
        guard let root, windowIDs.contains(target) else { return inserting(id) }
        let total = hostHeight + unusedHeight
        let ratios = total > 0 ? [hostHeight / total, unusedHeight / total] : [0.5, 0.5]
        var next = replacingRoot(Layout.replaceLeaf(root, target: target, with: .split(.vertical, children: [.leaf(target), .leaf(id)], ratios: ratios)))
        if next.leftoverHeights[target] == nil, hostHeight > 0 {
            next.leftoverHeights[target] = hostHeight
        }
        return next.normalized()
    }

    /// Adds a new window sharing the given leaf's place (other leaves' frames stay).
    /// The split is horizontal if the leaf's frame is wider than tall, vertical otherwise.
    public func inserting(_ id: WindowID, splitting target: WindowID, targetRect: CGRect) -> Layout {
        if windowIDs.contains(id) { return self }
        guard let root, windowIDs.contains(target) else { return inserting(id) }
        let axis: Axis = targetRect.width >= targetRect.height ? .horizontal : .vertical
        return replacingRoot(Layout.replaceLeaf(root, target: target, with: .split(axis, children: [.leaf(target), .leaf(id)], ratios: [0.5, 0.5]))).normalized()
    }

    /// Adds a new window as the next sibling of the given leaf (i3 / AeroSpace "open next to the focused window").
    /// Its weight is the siblings' average, so an even row shrinks evenly after normalizing.
    /// A root leaf becomes a horizontal split; without the leaf, the window is appended.
    public func inserting(_ id: WindowID, beside target: WindowID, after: Bool = true) -> Layout {
        if windowIDs.contains(id) { return self }
        guard let root, windowIDs.contains(target) else { return inserting(id) }
        if case .leaf = root {
            let pair: [LayoutNode] = after ? [root, .leaf(id)] : [.leaf(id), root]
            return replacingRoot(.split(.horizontal, children: pair, ratios: [0.5, 0.5])).normalized()
        }
        return replacingRoot(Layout.insertSibling(id, beside: target, after: after, in: root)).normalized()
    }

    /// Returns a window from floating. If the remaining order is unchanged since it floated, uses the tree from before;
    /// otherwise puts it back into the current tree, outside the group it was beside.
    /// Windows that left the same home together come back as that home when the rest of the layout still matches it;
    /// otherwise they return one at a time (a stack of three cannot be rebuilt from its parts one by one).
    public func returning(_ ids: [WindowID], home: Layout) -> Layout {
        let set = Set(ids)
        if set.isSubset(of: Set(home.windowIDs)), Layout.sameShape(root, home.removing(set, keepHeights: set).root) { return home.normalized() }
        return ids.reduce(self) { $0.returning($1, home: home) }
    }

    public func returning(_ id: WindowID, home: Layout) -> Layout {
        guard home.windowIDs.contains(id) else { return inserting(id) }
        if Layout.sameShape(root, home.removing([id], keepHeights: [id]).root) { return home.normalized() }
        var next = home.returnAnchor(for: id).map { inserting(id, at: $0) } ?? inserting(id)
        if next.leftoverHeights[id] == nil, let height = home.leftoverHeights[id], height > 0 {
            next.leftoverHeights[id] = height
        }
        return next.normalized()
    }

    /// Inserts a new window where the floated window would return; appended if its neighbors are gone.
    public func inserting(_ id: WindowID, inPlaceOf floated: WindowID, home: Layout) -> Layout {
        guard home.windowIDs.contains(floated), let anchor = home.returnAnchor(for: floated) else { return inserting(id) }
        return inserting(id, at: anchor)
    }

    private func inserting(_ id: WindowID, at anchor: ReturnAnchor) -> Layout {
        let present = Set(anchor.sibling.windowIDs).intersection(Set(windowIDs))
        guard let group = Layout.findExact(root, ids: present) else { return inserting(id) }
        if case .leaf(let target) = group {
            return inserting(id, beside: target, after: anchor.after).normalized()
        }
        return insertingBesideGroup(id, group: group, after: anchor.after, axis: anchor.axis).normalized()
    }

    private struct ReturnAnchor {
        var sibling: LayoutNode
        var after: Bool
        var axis: Axis
    }

    private func returnAnchor(for id: WindowID) -> ReturnAnchor? {
        guard let root, let path = LayoutEdit.pathTo(id, in: root), let index = path.last else { return nil }
        guard let box = LayoutEdit.node(at: Array(path.dropLast()), in: root).box else { return nil }
        let axis = box.axis
        let children = box.children
        if index > 0 {
            return ReturnAnchor(sibling: children[index - 1], after: true, axis: axis)
        }
        if index + 1 < children.count {
            return ReturnAnchor(sibling: children[index + 1], after: false, axis: axis)
        }
        return nil
    }

    /// If the neighbor is a split, places the window beside the whole split, not inside it. If the group is the current root, wraps it in the orientation from when the window floated.
    private func insertingBesideGroup(_ id: WindowID, group: LayoutNode, after: Bool, axis: Axis) -> Layout {
        if windowIDs.contains(id) { return self }
        guard let root else { return inserting(id) }
        if root == group {
            let pair: [LayoutNode] = after ? [root, .leaf(id)] : [.leaf(id), root]
            return replacingRoot(.split(axis, children: pair, ratios: [0.5, 0.5]))
        }
        guard let replaced = Layout.insertBeside(id, target: group, after: after, in: root) else {
            return inserting(id)
        }
        return replacingRoot(replaced)
    }

    private static func findExact(_ node: LayoutNode?, ids: Set<WindowID>) -> LayoutNode? {
        guard let node, !ids.isEmpty else { return nil }
        if Set(node.windowIDs) == ids { return node }
        if let box = node.box {
            for child in box.children {
                if let found = findExact(child, ids: ids) { return found }
            }
        }
        return nil
    }

    private static func insertBeside(_ id: WindowID, target: LayoutNode, after: Bool, in node: LayoutNode) -> LayoutNode? {
        guard let box = node.box else { return nil }
        if let index = box.children.firstIndex(of: target) {
            var newChildren = box.children
            let insertAt = after ? index + 1 : index
            newChildren.insert(.leaf(id), at: insertAt)
            return LayoutNode.container(axis: box.axis, children: newChildren, ratios: ratiosAdmitting(box.ratios, at: insertAt), accordion: box.accordion)
        }
        for (i, child) in box.children.enumerated() {
            if let updated = insertBeside(id, target: target, after: after, in: child) {
                var copy = box.children
                copy[i] = updated
                return LayoutNode.container(axis: box.axis, children: copy, ratios: box.ratios, accordion: box.accordion)
            }
        }
        return nil
    }

    private static func sameShape(_ lhs: LayoutNode?, _ rhs: LayoutNode?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.leaf(let a), .leaf(let b)):
            return a == b
        case (.split(let axis, let children, let ratios), .split(let otherAxis, let otherChildren, let otherRatios)),
             (.accordion(let axis, let children, let ratios), .accordion(let otherAxis, let otherChildren, let otherRatios)):
            guard axis == otherAxis, children.count == otherChildren.count, ratios.count == otherRatios.count else { return false }
            for (ratio, other) in zip(ratios, otherRatios) where abs(ratio - other) > 0.02 { return false }
            return zip(children, otherChildren).allSatisfy { sameShape($0, $1) }
        default:
            return false
        }
    }

    private static func insertSibling(_ id: WindowID, beside target: WindowID, after: Bool, in node: LayoutNode) -> LayoutNode {
        guard let box = node.box else { return node }
        if let index = box.children.firstIndex(where: { if case .leaf(let l) = $0 { return l == target } else { return false } }) {
            var newChildren = box.children
            let insertAt = after ? index + 1 : index
            newChildren.insert(.leaf(id), at: insertAt)
            return LayoutNode.container(axis: box.axis, children: newChildren, ratios: ratiosAdmitting(box.ratios, at: insertAt), accordion: box.accordion)
        }
        return LayoutNode.container(axis: box.axis, children: box.children.map { insertSibling(id, beside: target, after: after, in: $0) }, ratios: box.ratios, accordion: box.accordion)
    }

    /// Writes split ratios back from actual frames, so a distribution shrunk by caps becomes the intent for the next calculation.
    /// Only leaves with space below them in their column keep a height in leftoverHeights; leaves reaching the bottom are just split vertically.
    public func packing(rects: [WindowID: CGRect]) -> Layout {
        var heights = leftoverHeights
        let bottom = rects.values.map(\.maxY).max() ?? 0
        let accordionIDs = root.map(Layout.accordionMembers) ?? []
        for id in windowIDs where !accordionIDs.contains(id) {
            guard let frame = rects[id] else { continue }
            let hasBelow = windowIDs.contains { other in
                guard other != id, let otherFrame = rects[other] else { return false }
                let overlapX = otherFrame.minX < frame.maxX - 1 && otherFrame.maxX > frame.minX + 1
                return overlapX && otherFrame.minY >= frame.maxY - 1
            }
            if hasBelow { continue }
            if bottom - frame.maxY > 1 {
                heights[id] = frame.height
            } else {
                heights[id] = nil
            }
        }
        return Layout(root: root.map { Layout.pack($0, rects: rects) }, leftoverHeights: heights)
    }

    /// Remembering accordion overlap as free height would make the next calculation shrink the strips further.
    private static func accordionMembers(_ node: LayoutNode) -> Set<WindowID> {
        switch node {
        case .leaf:
            return []
        case .split(_, let children, _):
            return children.reduce(into: Set<WindowID>()) { $0.formUnion(accordionMembers($1)) }
        case .accordion:
            return Set(node.windowIDs)
        }
    }

    private static func pack(_ node: LayoutNode, rects: [WindowID: CGRect]) -> LayoutNode {
        switch node {
        case .leaf:
            return node
        case .accordion(let axis, let children, let ratios):
            return .accordion(axis, children: children.map { pack($0, rects: rects) }, ratios: ratios)
        case .split(let axis, let children, let ratios):
            let packed = children.map { pack($0, rects: rects) }
            let lengths = children.map { span($0, along: axis, rects: rects) }
            let total = lengths.reduce(0, +)
            return .split(axis, children: packed, ratios: total > 0 ? lengths.map { $0 / total } : ratios)
        }
    }

    private static func span(_ node: LayoutNode, along axis: Axis, rects: [WindowID: CGRect]) -> Double {
        let frames = node.windowIDs.compactMap { rects[$0] }
        guard let first = frames.first else { return 0 }
        switch axis {
        case .horizontal:
            return (frames.map(\.maxX).max() ?? first.maxX) - (frames.map(\.minX).min() ?? first.minX)
        case .vertical:
            return (frames.map(\.maxY).max() ?? first.maxY) - (frames.map(\.minY).min() ?? first.minY)
        }
    }

    /// Evens out every split's ratios, keeping the structure.
    /// Leaves in an evened vertical split drop their short heights; short leaves side by side keep them.
    public func balanced() -> Layout {
        func go(_ node: LayoutNode) -> LayoutNode {
            guard let box = node.box else { return node }
            return LayoutNode.container(axis: box.axis, children: box.children.map(go), ratios: Array(repeating: 1 / Double(box.children.count), count: box.children.count), accordion: box.accordion)
        }
        guard let root else { return self }
        let nextRoot = go(root)
        var heights = leftoverHeights
        func dropVertical(_ node: LayoutNode) {
            switch node {
            case .leaf:
                break
            case .split(let axis, let children, _), .accordion(let axis, let children, _):
                if axis == .vertical {
                    for id in node.windowIDs { heights[id] = nil }
                }
                for child in children { dropVertical(child) }
            }
        }
        dropVertical(nextRoot)
        return Layout(root: nextRoot, leftoverHeights: heights).normalized()
    }

    /// Axis of id's parent split; nil for a root leaf.
    public func parentAxis(of id: WindowID) -> Axis? {
        func go(_ node: LayoutNode) -> Axis? {
            guard let box = node.box else { return nil }
            for child in box.children {
                if case .leaf(let l) = child, l == id { return box.axis }
                if let found = go(child) { return found }
            }
            return nil
        }
        return root.flatMap(go)
    }

    private static func replaceLeaf(_ node: LayoutNode, target: WindowID, with replacement: LayoutNode) -> LayoutNode {
        switch node {
        case .leaf(let l): return l == target ? replacement : node
        case .split(let a, let c, let r): return .split(a, children: c.map { replaceLeaf($0, target: target, with: replacement) }, ratios: r)
        case .accordion(let a, let c, let r): return .accordion(a, children: c.map { replaceLeaf($0, target: target, with: replacement) }, ratios: r)
        }
    }

    /// A new sibling's weight is the existing siblings' average: with a sum of 1, the new window gets 1/(n+1) and the others n/(n+1).
    static func ratiosAdmitting(_ ratios: [Double], at index: Int) -> [Double] {
        guard !ratios.isEmpty else { return [1] }
        let average = ratios.reduce(0, +) / Double(ratios.count)
        var next = ratios
        let at = min(max(index, 0), next.count)
        next.insert(average, at: at)
        let total = next.reduce(0, +)
        guard total > 0 else {
            let share = 1 / Double(next.count)
            return Array(repeating: share, count: next.count)
        }
        return next.map { $0 / total }
    }

    private static func insert(_ id: WindowID, into node: LayoutNode) -> LayoutNode {
        guard let box = node.box else {
            return .split(.horizontal, children: [node, .leaf(id)], ratios: [0.5, 0.5])
        }
        // In an accordion or a horizontal row, a new window is appended as a sibling.
        if box.accordion || box.axis == .horizontal {
            return LayoutNode.container(axis: box.axis, children: box.children + [.leaf(id)], ratios: ratiosAdmitting(box.ratios, at: box.ratios.count), accordion: box.accordion)
        }
        var best = box.children.count - 1
        for (i, c) in box.children.enumerated() where c.leafCount < box.children[best].leafCount { best = i }
        var updated = box.children
        updated[best] = insert(id, into: box.children[best])
        return .split(.vertical, children: updated, ratios: box.ratios)
    }

    /// When the first child of a vertical split vanishes and the rest collapses, the rest was stacked into free space, so its short height is dropped.
    private static func guestsPromoted(byPruning node: LayoutNode, gone: Set<WindowID>) -> Set<WindowID> {
        guard let box = node.box else { return [] }
        let axis = box.axis
        let children = box.children
        var promoted = Set<WindowID>()
        let kept = children.compactMap { prune($0, gone: gone) }
        if axis == .vertical, kept.count == 1, let host = children.first, prune(host, gone: gone) == nil {
            promoted.formUnion(kept[0].windowIDs)
        }
        for child in children {
            promoted.formUnion(guestsPromoted(byPruning: child, gone: gone))
        }
        return promoted
    }

    private static func prune(_ node: LayoutNode, gone: Set<WindowID>) -> LayoutNode? {
        switch node {
        case .leaf(let id):
            return gone.contains(id) ? nil : node
        case .split(let axis, let children, let ratios), .accordion(let axis, let children, let ratios):
            let accordion = node.box?.accordion ?? false
            var keptChildren: [LayoutNode] = []
            var keptRatios: [Double] = []
            for (child, ratio) in zip(children, ratios) {
                if let kept = prune(child, gone: gone) {
                    keptChildren.append(kept)
                    keptRatios.append(ratio)
                }
            }
            if keptChildren.isEmpty { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            let total = keptRatios.reduce(0, +)
            return LayoutNode.container(axis: axis, children: keptChildren, ratios: keptRatios.map { $0 / total }, accordion: accordion)
        }
    }
}
