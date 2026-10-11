import CoreGraphics
import Foundation

/// Per-Space region for dialogs (right or bottom edge). Dialogs keep their size; only their position is decided.
/// Tiles fill the work area minus the region (and one gap).
public struct DialogRegion: Equatable, Codable {
    /// One dialog in the region. Carries identity (pid, process launch time) so another window is never mistaken for it after a restart.
    public struct Member: Equatable, Codable {
        public var id: WindowID
        public var pid: Int32
        public var processStart: Date
        public var size: CGSize
        /// Placement position (top-left-origin logical coordinates).
        public var origin: CGPoint

        public init(id: WindowID, pid: Int32, processStart: Date, size: CGSize, origin: CGPoint) {
            self.id = id; self.pid = pid; self.processStart = processStart; self.size = size; self.origin = origin
        }

        public var frame: CGRect { CGRect(origin: origin, size: size) }
    }

    /// The edge the region takes.
    public enum Edge: String, Codable { case right, bottom }

    public var edge: Edge
    /// Tile area at planning time (work area minus outer gaps, rounded to integers); nil if unknown (treated as changed).
    public var area: CGRect?
    /// Tile minimum size at planning time (the edge is reconsidered when it changes).
    public var tileMinimum: CGSize?
    /// The other edge would be better but could not be switched to (unmovable window, just switched). Reconsidered once switching is possible.
    public var edgeReview: Bool
    /// Region thickness (width on the right, height at the bottom), not including the gap to the tiles.
    public var thickness: Double
    /// In arrival order.
    public var members: [Member]

    public init(edge: Edge = .right, area: CGRect? = nil, tileMinimum: CGSize? = nil, edgeReview: Bool = false, thickness: Double, members: [Member]) {
        self.edge = edge; self.area = area; self.tileMinimum = tileMinimum; self.edgeReview = edgeReview
        self.thickness = thickness
        self.members = members
    }

    /// Amount taken from the tile area (thickness plus the rounded-up gap): from the width on the right, the height at the bottom; 0 when empty.
    /// The region packs from the integer-rounded edge, so the tile area is reduced from that edge too (`PlannerOptions.tilingArea`).
    public func reservation(gap: Double, gapVertical: Double) -> (right: Double, bottom: Double) {
        guard !members.isEmpty else { return (0, 0) }
        switch edge {
        case .right: return (thickness + ceil(gap), 0)
        case .bottom: return (0, thickness + ceil(gapVertical))
        }
    }
}

/// Region calculation. No clocks or AppKit; the same input gives the same result.
public enum DialogRegionPlanner {
    /// Dialogs newly entering the region, in arrival order.
    public struct Arrival: Equatable {
        public var id: WindowID
        public var pid: Int32
        public var processStart: Date
        public var size: CGSize
        public init(id: WindowID, pid: Int32, processStart: Date, size: CGSize) {
            self.id = id; self.pid = pid; self.processStart = processStart; self.size = size
        }
    }

    public struct Input {
        public var previous: DialogRegion?
        public var arrivals: [Arrival]
        /// Windows confirmed to have left.
        public var departed: Set<WindowID>
        /// Current sizes of movable members (or the recorded size).
        public var sizes: [WindowID: CGSize]
        /// Members that cannot move this time (in front, unreadable, awaiting a rewrite, or being checked for being put back).
        public var pinned: Set<WindowID>
        /// Tile area (work area minus outer gaps, before the region is taken).
        public var area: CGRect
        public var gap: Double
        public var gapVertical: Double
        /// Minimum size of the live tile tree.
        public var tileMinimum: CGSize
        /// Whether the bottom edge is allowed (false: right only).
        public var allowBottom: Bool
        /// Edge to use without a region (last used on that Space); nil to choose for the first time.
        public var rememberedEdge: DialogRegion.Edge?
        /// Whether switching edges is allowed (false right after a switch).
        public var allowSwitch: Bool

        public init(previous: DialogRegion?, arrivals: [Arrival], departed: Set<WindowID>, sizes: [WindowID: CGSize], pinned: Set<WindowID>,
                    area: CGRect, gap: Double, gapVertical: Double, tileMinimum: CGSize, allowBottom: Bool = false,
                    rememberedEdge: DialogRegion.Edge? = nil, allowSwitch: Bool = true) {
            self.previous = previous; self.arrivals = arrivals; self.departed = departed; self.sizes = sizes; self.pinned = pinned
            self.area = area; self.gap = gap; self.gapVertical = gapVertical; self.tileMinimum = tileMinimum; self.allowBottom = allowBottom
            self.rememberedEdge = rememberedEdge; self.allowSwitch = allowSwitch
        }
    }

    public struct Result: Equatable {
        /// The next region; nil without members.
        public var region: DialogRegion?
        /// Windows that do not fit in total and will be retried later (arrival order).
        public var pending: [WindowID]
        /// Windows that cannot fit alone on the returned edge (thicker than the limit, longer than the region).
        public var inadmissible: [WindowID]
        /// Repacking (and switching edges) was deferred for unmovable members.
        public var deferred: Bool
        /// The edge was switched.
        public var switched: Bool
    }

    public static let maxMembers = 8
    public static let maxShare = 0.5
    /// With equal counts, how much smaller the share taken from tiles must be to switch to the other edge.
    public static let switchMargin = 0.10

    /// Tile area rounded inward to integers. Packing and written positions use this area's integers.
    public static func wholeArea(_ area: CGRect) -> CGRect {
        let minX = ceil(area.minX), minY = ceil(area.minY)
        let maxX = floor(area.maxX), maxY = floor(area.maxY)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Thickness limit: half the area, and what leaves room for the tile minimum and the gap (integer).
    public static func limit(edge: DialogRegion.Edge, area: CGRect, tileMinimum: CGSize, gap: Double, gapVertical: Double) -> Double {
        let a = wholeArea(area)
        switch edge {
        case .right: return floor(min(maxShare * Double(a.width), Double(a.width) - Double(tileMinimum.width) - ceil(gap)))
        case .bottom: return floor(min(maxShare * Double(a.height), Double(a.height) - Double(tileMinimum.height) - ceil(gapVertical)))
        }
    }

    struct Entry { var id: WindowID; var pid: Int32; var processStart: Date; var size: CGSize }

    /// Result of packing on one edge.
    struct Packing {
        var members: [DialogRegion.Member]
        var pending: [WindowID]
        var inadmissible: [WindowID]
        var thickness: Double
    }

    /// Places windows one at a time in arrival order: free spots nearest the outer edge first, then nearest the start of the region. Candidate spots are corners of placed windows.
    /// A position depends only on earlier windows, the area, the limit, and gaps (appending never moves earlier windows).
    static func pack(_ order: [Entry], edge: DialogRegion.Edge, area: CGRect, limit: Double, gap: Double, gapVertical: Double) -> Packing {
        let a = wholeArea(area)
        let gapU = ceil(edge == .right ? gap : gapVertical)
        let gapV = ceil(edge == .right ? gapVertical : gap)
        let length = Double(edge == .right ? a.height : a.width)
        struct Slot { var u: Double; var v: Double; var du: Double; var dv: Double }
        var placed: [(entry: Entry, slot: Slot)] = []
        var pending: [WindowID] = []
        var inadmissible: [WindowID] = []
        for entry in order {
            let w = ceil(Double(entry.size.width)), h = ceil(Double(entry.size.height))
            let du = edge == .right ? w : h, dv = edge == .right ? h : w
            guard du > 0, dv > 0, du <= limit, dv <= length else { inadmissible.append(entry.id); continue }
            guard placed.count < maxMembers else { pending.append(entry.id); continue }
            let us = Set([0] + placed.map { $0.slot.u + $0.slot.du + gapU }).sorted()
            let vs = Set([0] + placed.map { $0.slot.v + $0.slot.dv + gapV }).sorted()
            var found: Slot?
            search: for u in us where u + du <= limit {
                for v in vs where v + dv <= length {
                    let free = placed.allSatisfy { p in
                        u >= p.slot.u + p.slot.du + gapU || p.slot.u >= u + du + gapU
                            || v >= p.slot.v + p.slot.dv + gapV || p.slot.v >= v + dv + gapV
                    }
                    if free { found = Slot(u: u, v: v, du: du, dv: dv); break search }
                }
            }
            if let found { placed.append((entry, found)) } else { pending.append(entry.id) }
        }
        let members = placed.map { item -> DialogRegion.Member in
            let s = item.slot
            let origin: CGPoint
            switch edge {
            case .right: origin = CGPoint(x: Double(a.maxX) - s.u - s.du, y: Double(a.minY) + s.v)
            case .bottom: origin = CGPoint(x: Double(a.minX) + s.v, y: Double(a.maxY) - s.u - s.du)
            }
            return DialogRegion.Member(id: item.entry.id, pid: item.entry.pid, processStart: item.entry.processStart, size: item.entry.size, origin: origin)
        }
        let thickness = placed.map { $0.slot.u + $0.slot.du }.max() ?? 0
        return Packing(members: members, pending: pending, inadmissible: inadmissible, thickness: thickness)
    }

    /// Share taken from the tiles.
    static func loss(_ packing: Packing, edge: DialogRegion.Edge, area: CGRect, gap: Double, gapVertical: Double) -> Double {
        guard !packing.members.isEmpty else { return 0 }
        let a = wholeArea(area)
        switch edge {
        case .right: return a.width > 0 ? (packing.thickness + ceil(gap)) / Double(a.width) : 1
        case .bottom: return a.height > 0 ? (packing.thickness + ceil(gapVertical)) / Double(a.height) : 1
        }
    }

    /// Decides the next region: existing members first, arrivals after.
    public static func plan(_ input: Input) -> Result {
        let previous = input.previous
        let departed = input.departed
        var order: [Entry] = (previous?.members ?? []).filter { !departed.contains($0.id) }.map {
            Entry(id: $0.id, pid: $0.pid, processStart: $0.processStart, size: input.sizes[$0.id] ?? $0.size)
        }
        let known = Set(order.map(\.id))
        var arrivals: [Entry] = []
        var seen = known
        for arrival in input.arrivals where !seen.contains(arrival.id) && !departed.contains(arrival.id) {
            seen.insert(arrival.id)
            arrivals.append(Entry(id: arrival.id, pid: arrival.pid, processStart: arrival.processStart, size: arrival.size))
        }
        order += arrivals
        let area = wholeArea(input.area)
        let current = previous?.edge ?? input.rememberedEdge ?? .right
        func limitFor(_ edge: DialogRegion.Edge) -> Double {
            limit(edge: edge, area: area, tileMinimum: input.tileMinimum, gap: input.gap, gapVertical: input.gapVertical)
        }
        func packed(_ edge: DialogRegion.Edge) -> Packing {
            pack(order, edge: edge, area: area, limit: limitFor(edge), gap: input.gap, gapVertical: input.gapVertical)
        }
        func region(_ packing: Packing, _ edge: DialogRegion.Edge, review: Bool = false) -> DialogRegion? {
            packing.members.isEmpty ? nil : DialogRegion(edge: edge, area: area, tileMinimum: input.tileMinimum, edgeReview: review, thickness: packing.thickness, members: packing.members)
        }
        let remaining = Set(order.map(\.id)).subtracting(arrivals.map(\.id))
        let pinnedRemaining = input.pinned.intersection(remaining)
        /// Whether the result moves an unmovable member (position or size changes, or it leaves the region).
        func movesPinned(_ packing: Packing) -> Bool {
            guard let previous else { return false }
            return pinnedRemaining.contains { id in
                guard let before = previous.members.first(where: { $0.id == id }) else { return false }
                guard let after = packing.members.first(where: { $0.id == id }) else { return true }
                return after.origin != before.origin || after.size != before.size
            }
        }
        /// Deferral (as in stage 1): only remove departed windows. No arrivals, and edge and thickness stay.
        /// A region whose area changed or that no longer fits the current limit is dropped (members stay in place and re-enter as candidates later).
        func deferredResult(pending: [WindowID], inadmissible: [WindowID], review: Bool) -> Result {
            guard let previous else { return Result(region: nil, pending: pending, inadmissible: inadmissible, deferred: true, switched: false) }
            let kept = previous.members.filter { !departed.contains($0.id) }
            let u = limitFor(previous.edge)
            let v = Double(previous.edge == .right ? area.height : area.width)
            let fits = previous.area == area && previous.thickness <= u && kept.allSatisfy { m in
                let du = Double(previous.edge == .right ? m.size.width : m.size.height)
                let dv = Double(previous.edge == .right ? m.size.height : m.size.width)
                return du <= u && dv <= v
            }
            guard fits else { return Result(region: nil, pending: [], inadmissible: [], deferred: true, switched: false) }
            let frozen = kept.isEmpty ? nil : DialogRegion(edge: previous.edge, area: previous.area, tileMinimum: previous.tileMinimum,
                                                           edgeReview: previous.edgeReview || review, thickness: previous.thickness, members: kept)
            let waiting = pending + arrivals.map(\.id).filter { !pending.contains($0) && !inadmissible.contains($0) }
            return Result(region: frozen, pending: waiting, inadmissible: inadmissible, deferred: true, switched: false)
        }
        let mine = packed(current)
        // Reconsider the edge only for admitted arrivals, confirmed departures, or area / tile minimum changes (size changes alone never switch it).
        if input.allowBottom {
            let other: DialogRegion.Edge = current == .right ? .bottom : .right
            let theirs = packed(other)
            let mineIDs = Set(mine.members.map(\.id))
            let admittedArrival = arrivals.contains { a in mineIDs.contains(a.id) || theirs.members.contains { $0.id == a.id } }
            let trigger: Bool
            if let previous {
                trigger = previous.edgeReview || !departed.intersection(previous.members.map(\.id)).isEmpty || admittedArrival
                    || previous.area != area || previous.tileMinimum != input.tileMinimum
            } else {
                trigger = input.rememberedEdge == nil || admittedArrival
            }
            if trigger {
                let theirIDs = Set(theirs.members.map(\.id))
                let keepsAll = mineIDs.isSubset(of: theirIDs)
                let lossMine = loss(mine, edge: current, area: area, gap: input.gap, gapVertical: input.gapVertical)
                let lossTheirs = loss(theirs, edge: other, area: area, gap: input.gap, gapVertical: input.gapVertical)
                let better = keepsAll && (theirs.members.count > mine.members.count
                    || (theirs.members.count == mine.members.count && !theirs.members.isEmpty && lossTheirs <= lossMine - switchMargin))
                if better {
                    // With unmovable members, or right after a switch, keep the current edge and carry the review over.
                    if pinnedRemaining.isEmpty, input.allowSwitch {
                        return Result(region: region(theirs, other), pending: theirs.pending, inadmissible: theirs.inadmissible, deferred: false, switched: true)
                    }
                    if movesPinned(mine) { return deferredResult(pending: mine.pending, inadmissible: mine.inadmissible, review: true) }
                    return Result(region: region(mine, current, review: true), pending: mine.pending, inadmissible: mine.inadmissible,
                                  deferred: !pinnedRemaining.isEmpty, switched: false)
                }
                // No switch needed: the review is done (the region built below has edgeReview = false).
            }
        }
        // If a review is owed but switching is impossible (unmovable window, just switched), carry it over; clear it only when reviewed while switching was possible.
        let owed = input.allowBottom && previous?.edgeReview == true && (!pinnedRemaining.isEmpty || !input.allowSwitch)
        if movesPinned(mine) { return deferredResult(pending: mine.pending, inadmissible: mine.inadmissible, review: owed) }
        return Result(region: region(mine, current, review: owed), pending: mine.pending, inadmissible: mine.inadmissible, deferred: false, switched: false)
    }
}
