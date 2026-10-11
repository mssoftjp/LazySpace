import AppKit
import Foundation

/// Space observation. Membership rests only on SkyLight's answers, never on guesses.
public struct SpaceObserver {
    /// Mission Control numbers only ordinary desktops. Full-screen / Split View
    /// spaces stay in the navigation order but never consume a desktop number.
    /// An incomplete or ambiguous inventory must not produce shifted numbers.
    public static func desktopNumbers(_ order: [(id: UInt64, type: Int32?)]) -> [UInt64: Int] {
        guard order.allSatisfy({ $0.type != nil }), Set(order.map(\.id)).count == order.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: order.filter { $0.type == 0 }.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    /// One Space in the managed-display list. id, type, and uuid are read from the same dictionary (separate arrays would misalign on a missing item).
    /// `uuid` is macOS's per-Space identifier (also stored in `com.apple.spaces`); nil when absent.
    public struct Space: Codable, Equatable {
        public var id: UInt64
        public var type: Int32?
        public var uuid: String?
        public init(id: UInt64, type: Int32?, uuid: String? = nil) { self.id = id; self.type = type; self.uuid = uuid }
    }

    public struct ManagedDisplay: Codable, Equatable {
        public var display: String
        public var currentSpace: UInt64?
        public var spaces: [UInt64]
        /// Types of the Spaces whose type was readable. Shorter than `spaces` if any is missing (the types are then not trusted).
        public var spaceTypes: [Int32]
        /// Per-Space records, in the same order as `spaces`.
        public var records: [Space]

        public init(display: String, currentSpace: UInt64?, spaces: [UInt64], spaceTypes: [Int32]) {
            self.display = display; self.currentSpace = currentSpace; self.spaces = spaces; self.spaceTypes = spaceTypes
            // If the type list is incomplete, no Space's type is known (all nil).
            let types = spaceTypes, aligned = spaces.count == spaceTypes.count
            records = spaces.enumerated().map { Space(id: $0.element, type: aligned ? types[$0.offset] : nil) }
        }

        public init(display: String, currentSpace: UInt64?, records: [Space]) {
            self.display = display; self.currentSpace = currentSpace; self.records = records
            spaces = records.map(\.id)
            spaceTypes = records.compactMap(\.type)
        }

        /// Reads one managed-display dictionary (also used by tests). Spaces without an id are skipped.
        public static func parse(_ d: [String: Any]) -> ManagedDisplay {
            let spaces = (d["Spaces"] as? [[String: Any]]) ?? []
            let records = spaces.compactMap { item -> Space? in
                guard let id = (item["id64"] as? NSNumber)?.uint64Value ?? (item["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                let uuid = (item["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Space(id: id, type: (item["type"] as? NSNumber)?.int32Value, uuid: uuid)
            }
            let current = (d["Current Space"] as? [String: Any]).flatMap { ($0["id64"] as? NSNumber)?.uint64Value ?? ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            return ManagedDisplay(display: (d["Display Identifier"] as? String) ?? "?", currentSpace: current, records: records)
        }
    }

    /// The OS uuids that are unique (appear once across all displays). Spaces with a missing or duplicate uuid are left out (not tied to a number).
    public static func uniqueUUIDs(_ displays: [ManagedDisplay]) -> [UInt64: String] {
        let all = displays.flatMap(\.records)
        var counts: [String: Int] = [:]
        for uuid in all.compactMap(\.uuid) { counts[uuid, default: 0] += 1 }
        var result: [UInt64: String] = [:]
        for record in all { if let uuid = record.uuid, counts[uuid] == 1 { result[record.id] = uuid } }
        return result
    }

    private let sls: PrivateSymbols.SkyLight
    private let cid: Int32

    public init?() {
        guard let sls = PrivateSymbols.skyLight else { return nil }
        self.sls = sls
        self.cid = sls.mainConnectionID()
    }

    public func activeSpace() -> UInt64? {
        let s = sls.getActiveSpace(cid)
        return s == 0 ? nil : s
    }

    public func spaceType(_ id: UInt64) -> Int32? {
        sls.spaceGetType?(cid, id)
    }

    /// Whether a window participates in its Space's display order, even on a
    /// different desktop. Unlike CG onScreen, this excludes ordered-out helper
    /// windows without excluding ordinary windows on other Spaces. Read-only;
    /// unavailable/error is unknown, never evidence of a closed window.
    public func isOrderedIn(_ windowID: CGWindowID) -> Bool? {
        guard let read = sls.windowIsOrderedIn else { return nil }
        var ordered: UInt8 = 0
        guard read(cid, windowID, &ordered) == 0 else { return nil }
        return ordered != 0
    }

    /// Spaces the window belongs to. Empty means membership is unknown.
    public func spaces(for windowID: CGWindowID) -> [UInt64] {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("windowMembership")
        #endif
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let raw = sls.copySpacesForWindows(cid, 0x7, ids)?.takeRetainedValue() else { return [] }
        return (raw as? [NSNumber])?.map { $0.uint64Value } ?? []
    }

    public func managedDisplays() -> [ManagedDisplay] {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("spaceList")
        #endif
        guard let raw = sls.copyManagedDisplaySpaces(cid)?.takeRetainedValue(), let dicts = raw as? [[String: Any]] else { return [] }
        return dicts.map(ManagedDisplay.parse)
    }
}

/// Space change notifications (public API). Counts changes only.
public final class SpaceChangeCounter {
    private var token: NSObjectProtocol?
    private let lock = NSLock()
    private var _count: UInt64 = 0

    public init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self._count += 1; self.lock.unlock()
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    public var count: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
}
