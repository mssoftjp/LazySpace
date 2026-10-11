import CoreGraphics
import Foundation
import LayoutCore

/// Size constraints inferred from measurements, scoped to a window and environment, and invalidated by expiry, disappearance, or contradiction.
public final class ConstraintKnowledge {
    public struct Entry: Equatable, Codable {
        public var minimum: CGSize
        /// Actual size on axes corrected below the request (0 = unknown). Used to detect fixed-size windows.
        public var maximum: CGSize
        public var observedAt: Date
        public var spaceID: UInt64?
        public var workArea: CGRect
        /// When the maximum was learned. `observedAt` advances on every observation, so it is not used for expiry.
        public var maximumLearnedAt: Date?
        /// Work area where the maximum was learned. A maximum from another screen is not used.
        public var maximumWorkArea: CGRect?

        public init(minimum: CGSize, maximum: CGSize, observedAt: Date, spaceID: UInt64?, workArea: CGRect, maximumLearnedAt: Date? = nil, maximumWorkArea: CGRect? = nil) {
            self.minimum = minimum
            self.maximum = maximum
            self.observedAt = observedAt
            self.spaceID = spaceID
            self.workArea = workArea
            self.maximumLearnedAt = maximumLearnedAt
            self.maximumWorkArea = maximumWorkArea
        }

        private enum CodingKeys: String, CodingKey {
            case minimum, maximum, observedAt, spaceID, workArea, maximumLearnedAt, maximumWorkArea
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            minimum = try c.decode(CGSize.self, forKey: .minimum)
            maximum = try c.decode(CGSize.self, forKey: .maximum)
            observedAt = try c.decode(Date.self, forKey: .observedAt)
            spaceID = try c.decodeIfPresent(UInt64.self, forKey: .spaceID)
            workArea = try c.decode(CGRect.self, forKey: .workArea)
            maximumLearnedAt = try c.decodeIfPresent(Date.self, forKey: .maximumLearnedAt)
            maximumWorkArea = try c.decodeIfPresent(CGRect.self, forKey: .maximumWorkArea)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(minimum, forKey: .minimum)
            try c.encode(maximum, forKey: .maximum)
            try c.encode(observedAt, forKey: .observedAt)
            try c.encodeIfPresent(spaceID, forKey: .spaceID)
            try c.encode(workArea, forKey: .workArea)
            try c.encodeIfPresent(maximumLearnedAt, forKey: .maximumLearnedAt)
            try c.encodeIfPresent(maximumWorkArea, forKey: .maximumWorkArea)
        }
    }

    private let lock = NSLock()
    private var entries: [WindowID: Entry] = [:]
    /// Keyed by bundle ID and subrole. Kept across window ID changes until contradicted.
    private var profiles: [String: Entry] = [:]
    private var profileOfWindow: [WindowID: String] = [:]
    private let ttl: TimeInterval
    private let now: () -> Date

    private static func profileKey(bundle: String, subrole: String) -> String { bundle + "\n" + subrole }

    public init(ttl: TimeInterval = 15 * 60, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    public func constraints(for ids: [WindowID], spaceID: UInt64?, workArea: CGRect) -> [WindowID: SizeKnowledge] {
        lock.lock(); defer { lock.unlock() }
        var out: [WindowID: SizeKnowledge] = [:]
        for id in ids {
            guard let e = entries[id], e.minimum != .zero else { out[id] = .unknown; continue }
            out[id] = .estimated(e.minimum)
        }
        return out
    }

    /// Maximum sizes still unexpired and learned in the same work area; an axis of 0 is unknown.
    /// Expired maximums and those from other screens are not returned, but not forgotten either.
    public func maximums(for ids: [WindowID], workArea: CGRect) -> [WindowID: CGSize] {
        lock.lock(); defer { lock.unlock() }
        var out: [WindowID: CGSize] = [:]
        for id in ids {
            guard let entry = entries[id] ?? profileEntry(for: id) else { continue }
            let cap = applicableMaximum(entry, workArea: workArea)
            if cap != .zero { out[id] = cap }
        }
        return out
    }

    /// Only the axes of the maximum that meet expiry and work area; the others are 0.
    private func applicableMaximum(_ entry: Entry, workArea: CGRect) -> CGSize {
        guard entry.maximum != .zero, let learned = entry.maximumLearnedAt, now().timeIntervalSince(learned) < ttl,
              let learnedArea = entry.maximumWorkArea, learnedArea.matches(workArea, tolerance: 1) else { return .zero }
        return entry.maximum
    }

    private func profileEntry(for id: WindowID) -> Entry? {
        profileOfWindow[id].flatMap { profiles[$0] }
    }

    /// Infers a minimum only on axes that came back larger than requested.
    public func recordPushback(id: WindowID, requested: CGRect, actual: CGRect, spaceID: UInt64?, workArea: CGRect, tolerance: Double, bundle: String? = nil, subrole: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[id] ?? Entry(minimum: .zero, maximum: .zero, observedAt: now(), spaceID: spaceID, workArea: workArea)
        if actual.width > requested.width + tolerance { e.minimum.width = max(e.minimum.width, actual.width) }
        if actual.height > requested.height + tolerance { e.minimum.height = max(e.minimum.height, actual.height) }
        e.observedAt = now(); e.spaceID = spaceID; e.workArea = workArea
        entries[id] = e
        storeProfile(id: id, from: e, bundle: bundle, subrole: subrole, raiseOnly: true)
    }

    /// Infers a maximum only on axes corrected below the request.
    public func recordPullback(id: WindowID, requested: CGRect, actual: CGRect, spaceID: UInt64?, workArea: CGRect, tolerance: Double) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[id] ?? Entry(minimum: .zero, maximum: .zero, observedAt: now(), spaceID: spaceID, workArea: workArea)
        var learnedMaximum = false
        if actual.width < requested.width - tolerance { e.maximum.width = actual.width; learnedMaximum = true }
        if actual.height < requested.height - tolerance { e.maximum.height = actual.height; learnedMaximum = true }
        if learnedMaximum {
            e.maximumLearnedAt = now()
            e.maximumWorkArea = workArea
        }
        e.observedAt = now(); e.spaceID = spaceID; e.workArea = workArea
        entries[id] = e
        storeProfile(id: id, from: e, bundle: nil, subrole: nil, raiseOnly: false)
    }

    /// Checks inferences against the current size: lowers them on contradiction, otherwise updates the observation time.
    public func recordObservedSize(id: WindowID, actual: CGSize) {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[id] else { return }
        if e.minimum.width > 0, actual.width < e.minimum.width { e.minimum.width = actual.width }
        if e.minimum.height > 0, actual.height < e.minimum.height { e.minimum.height = actual.height }
        if e.maximum.width > 0, actual.width > e.maximum.width { e.maximum.width = 0 }
        if e.maximum.height > 0, actual.height > e.maximum.height { e.maximum.height = 0 }
        if e.maximum == .zero {
            e.maximumLearnedAt = nil
            e.maximumWorkArea = nil
        }
        e.observedAt = now()
        entries[id] = e
        if let key = profileOfWindow[id] {
            profiles[key] = e
        }
    }

    private func storeProfile(id: WindowID, from entry: Entry, bundle: String?, subrole: String?, raiseOnly: Bool) {
        let key: String
        if let bundle, !bundle.isEmpty {
            key = Self.profileKey(bundle: bundle, subrole: subrole ?? "")
            profileOfWindow[id] = key
        } else if let known = profileOfWindow[id] {
            key = known
        } else {
            return
        }
        if raiseOnly, var existing = profiles[key] {
            existing.minimum.width = max(existing.minimum.width, entry.minimum.width)
            existing.minimum.height = max(existing.minimum.height, entry.minimum.height)
            if entry.maximum.width > 0 { existing.maximum.width = entry.maximum.width }
            if entry.maximum.height > 0 { existing.maximum.height = entry.maximum.height }
            if entry.maximum != .zero, let learned = entry.maximumLearnedAt {
                existing.maximumLearnedAt = learned
                existing.maximumWorkArea = entry.maximumWorkArea
            }
            existing.observedAt = entry.observedAt
            profiles[key] = existing
        } else {
            profiles[key] = entry
        }
    }

    public func forget(_ id: WindowID) {
        lock.lock(); entries[id] = nil; lock.unlock()
    }

    public func forgetAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// Restores saved measurements stamped at restore time; they are checked against current sizes before the next arrangement.
    public func restore(_ facts: [WindowID: Entry], observedAt stamp: Date) {
        lock.lock(); defer { lock.unlock() }
        entries = facts
        for id in entries.keys {
            entries[id]?.observedAt = stamp
            guard var entry = entries[id], entry.maximum != .zero else { continue }
            let fresh = entry.maximumLearnedAt.map { stamp.timeIntervalSince($0) < ttl } ?? false
            if !fresh {
                entry.maximum = .zero
                entry.maximumLearnedAt = nil
                entry.maximumWorkArea = nil
                entries[id] = entry
            }
        }
    }

    public var snapshot: [WindowID: Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
