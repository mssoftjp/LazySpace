import CoreGraphics
import Foundation
import LayoutCore

/// Size constraints inferred from measurements, scoped to a window and environment, and invalidated by expiry, disappearance, or contradiction.
/// A confirmed maximum also becomes the maximum of the window's kind, which a new window of that kind can borrow (`reconcileKinds`).
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

    /// One axis of a kind's maximum: the value a window of that kind confirmed, when, and in which work area.
    private struct KindCap {
        var value: Double
        var confirmedAt: Date
        var workArea: CGRect
    }

    private struct KindCaps {
        var width: KindCap?
        var height: KindCap?
    }

    /// The axes of its maximum a window took from its kind, each with the kind's confirmation time.
    private struct Borrowed {
        var kind: String
        var width: Date?
        var height: Date?
        var isEmpty: Bool { width == nil && height == nil }
    }

    /// One arrangement target that has a kind (`ObservedWindow.kindKey`), with its current size.
    public struct KindTarget: Equatable {
        public var id: WindowID
        public var kind: String
        public var size: CGSize
        public var fullScreenButtonEnabled: Bool

        public init(id: WindowID, kind: String, size: CGSize, fullScreenButtonEnabled: Bool) {
            self.id = id
            self.kind = kind
            self.size = size
            self.fullScreenButtonEnabled = fullScreenButtonEnabled
        }
    }

    private let lock = NSLock()
    private var entries: [WindowID: Entry] = [:]
    /// Confirmed maximums per kind, axis by axis. In memory only: never written to the state file.
    private var kinds: [String: KindCaps] = [:]
    private var kindOfWindow: [WindowID: String] = [:]
    private var borrowed: [WindowID: Borrowed] = [:]
    private let ttl: TimeInterval
    private let now: () -> Date

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
            guard let entry = entries[id] else { continue }
            var cap = applicableMaximum(entry, workArea: workArea)
            // A borrowed axis expires with its kind's confirmation, even after the window confirmed its other axis.
            if let b = borrowed[id] {
                if let at = b.width, !fresh(at) { cap.width = 0 }
                if let at = b.height, !fresh(at) { cap.height = 0 }
            }
            if cap != .zero { out[id] = cap }
        }
        return out
    }

    private func fresh(_ confirmedAt: Date) -> Bool { now().timeIntervalSince(confirmedAt) < ttl }

    /// Only the axes of the maximum that meet expiry and work area; the others are 0.
    private func applicableMaximum(_ entry: Entry, workArea: CGRect) -> CGSize {
        guard entry.maximum != .zero, let learned = entry.maximumLearnedAt, fresh(learned),
              let learnedArea = entry.maximumWorkArea, learnedArea.matches(workArea, tolerance: 1) else { return .zero }
        return entry.maximum
    }

    /// Infers a minimum only on axes that came back larger than requested.
    public func recordPushback(id: WindowID, requested: CGRect, actual: CGRect, spaceID: UInt64?, workArea: CGRect, tolerance: Double) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[id] ?? Entry(minimum: .zero, maximum: .zero, observedAt: now(), spaceID: spaceID, workArea: workArea)
        if actual.width > requested.width + tolerance { e.minimum.width = max(e.minimum.width, actual.width) }
        if actual.height > requested.height + tolerance { e.minimum.height = max(e.minimum.height, actual.height) }
        e.observedAt = now(); e.spaceID = spaceID; e.workArea = workArea
        entries[id] = e
    }

    /// Before an arrangement plans: first drops every kind axis one of the targets is larger than, with the copies other windows borrowed from it,
    /// so the result does not depend on the order of the targets. Then, with `adopt`, a target with no maximum of its own and no enabled
    /// full-screen button borrows each axis of its kind that is unexpired, was learned in this work area, and equals its current size.
    /// Borrowed values carry the kind's confirmation time and never refresh the kind.
    public func reconcileKinds(_ targets: [KindTarget], adopt: Bool, spaceID: UInt64?, workArea: CGRect, tolerance: Double) {
        lock.lock(); defer { lock.unlock() }
        for target in targets {
            kindOfWindow[target.id] = target.kind
            dropKindAxes(target.kind, exceededBy: target.size, tolerance: tolerance)
        }
        guard adopt else { return }
        for target in targets where !target.fullScreenButtonEnabled {
            guard (entries[target.id]?.maximum ?? .zero) == .zero, let caps = kinds[target.kind] else { continue }
            func usable(_ cap: KindCap?, current: Double) -> KindCap? {
                guard let cap, fresh(cap.confirmedAt), cap.workArea.matches(workArea, tolerance: 1),
                      abs(current - cap.value) <= tolerance else { return nil }
                return cap
            }
            let width = usable(caps.width, current: target.size.width)
            let height = usable(caps.height, current: target.size.height)
            guard width != nil || height != nil else { continue }
            var e = entries[target.id] ?? Entry(minimum: .zero, maximum: .zero, observedAt: now(), spaceID: spaceID, workArea: workArea)
            e.maximum = CGSize(width: width?.value ?? 0, height: height?.value ?? 0)
            // The newest confirmation keeps the entry; `maximums(for:)` expires each borrowed axis at its own confirmation's age.
            e.maximumLearnedAt = [width?.confirmedAt, height?.confirmedAt].compactMap { $0 }.max()
            e.maximumWorkArea = workArea
            entries[target.id] = e
            borrowed[target.id] = Borrowed(kind: target.kind, width: width?.confirmedAt, height: height?.confirmedAt)
        }
    }

    /// A window larger than its kind's maximum on an axis shows the kind has no such limit: that axis goes, and so does every copy of it
    /// another window borrowed. A window's own confirmed maximum stays. Call with the lock held.
    private func dropKindAxes(_ kind: String, exceededBy size: CGSize, tolerance: Double) {
        guard var caps = kinds[kind] else { return }
        let width = caps.width.map { size.width > $0.value + tolerance } ?? false
        let height = caps.height.map { size.height > $0.value + tolerance } ?? false
        guard width || height else { return }
        if width { caps.width = nil }
        if height { caps.height = nil }
        kinds[kind] = caps.width == nil && caps.height == nil ? nil : caps
        for (id, var b) in borrowed where b.kind == kind {
            guard var e = entries[id] else { borrowed[id] = nil; continue }
            if width, b.width != nil { e.maximum.width = 0; b.width = nil }
            if height, b.height != nil { e.maximum.height = 0; b.height = nil }
            if e.maximum == .zero { e.maximumLearnedAt = nil; e.maximumWorkArea = nil }
            entries[id] = e
            borrowed[id] = b.isEmpty ? nil : b
        }
    }

    /// Infers a maximum only on axes corrected below the request. Those axes also become the maximum of the window's kind.
    public func recordPullback(id: WindowID, requested: CGRect, actual: CGRect, spaceID: UInt64?, workArea: CGRect, tolerance: Double, kind: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[id] ?? Entry(minimum: .zero, maximum: .zero, observedAt: now(), spaceID: spaceID, workArea: workArea)
        let width = actual.width < requested.width - tolerance
        let height = actual.height < requested.height - tolerance
        // A maximum learned in another work area replaces the whole maximum: an axis from elsewhere, own or borrowed, is not carried over.
        if width || height, let learnedArea = e.maximumWorkArea, !learnedArea.matches(workArea, tolerance: 1) {
            e.maximum = .zero
            borrowed[id] = nil
        }
        if width { e.maximum.width = actual.width }
        if height { e.maximum.height = actual.height }
        if width || height {
            e.maximumLearnedAt = now()
            e.maximumWorkArea = workArea
        }
        e.observedAt = now(); e.spaceID = spaceID; e.workArea = workArea
        entries[id] = e
        // The window's own confirmation: those axes are no longer borrowed.
        if var b = borrowed[id] {
            if width { b.width = nil }
            if height { b.height = nil }
            borrowed[id] = b.isEmpty ? nil : b
        }
        guard let kind, width || height else { return }
        kindOfWindow[id] = kind
        var caps = kinds[kind] ?? KindCaps()
        if width { caps.width = KindCap(value: actual.width, confirmedAt: now(), workArea: workArea) }
        if height { caps.height = KindCap(value: actual.height, confirmedAt: now(), workArea: workArea) }
        kinds[kind] = caps
    }

    /// Checks inferences against the current size: lowers them on contradiction, otherwise updates the observation time.
    /// A window larger than its kind's maximum also drops that kind axis (a borrowed window the user widened, for example).
    public func recordObservedSize(id: WindowID, actual: CGSize) {
        lock.lock(); defer { lock.unlock() }
        if let kind = kindOfWindow[id] { dropKindAxes(kind, exceededBy: actual, tolerance: 0) }
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
    }

    public func forget(_ id: WindowID) {
        lock.lock(); entries[id] = nil; borrowed[id] = nil; kindOfWindow[id] = nil; lock.unlock()
    }

    public func forgetAll() {
        lock.lock(); entries.removeAll(); kinds.removeAll(); borrowed.removeAll(); kindOfWindow.removeAll(); lock.unlock()
    }

    /// Restores saved measurements stamped at restore time; they are checked against current sizes before the next arrangement.
    public func restore(_ facts: [WindowID: Entry], observedAt stamp: Date) {
        lock.lock(); defer { lock.unlock() }
        entries = facts
        borrowed.removeAll()
        kindOfWindow.removeAll()
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

    /// The entries as saved in the state file. Borrowed axes are left out: the kind evidence behind them is not kept across launches.
    public var snapshot: [WindowID: Entry] {
        lock.lock(); defer { lock.unlock() }
        var out = entries
        for (id, b) in borrowed {
            guard var e = out[id] else { continue }
            if b.width != nil { e.maximum.width = 0 }
            if b.height != nil { e.maximum.height = 0 }
            if e.maximum == .zero { e.maximumLearnedAt = nil; e.maximumWorkArea = nil }
            out[id] = e
        }
        return out
    }
}
