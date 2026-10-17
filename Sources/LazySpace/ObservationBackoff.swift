import CoreGraphics
import Foundation
import LayoutCore

/// Retry for a window to integrate that was missing from observation, or looked like it was on another Space, of unknown membership, or of unknown kind.
/// That is transient right after a Space change, so it is not counted as a failure; retries double the interval (up to 4 s).
/// After `maxAttempts`, automatic retries stop until the frame changes, focus moves, or it lands on another Space
/// (so a window that always looks like it is on another Space, such as one on another display, is not queried forever). Read only under Coordinator's lock.
struct ObservationBackoff {
    static let firstDelay: TimeInterval = 0.25
    static let maxDelay: TimeInterval = 4
    /// 0.25 + 0.5 + 1 + 2 + 4 + 4 ≈ 12 s.
    static let maxAttempts = 6

    private struct Entry {
        var attempts: Int
        var notBefore: Date
        var frame: CGRect?
    }

    private var entries: [WindowID: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Counts a missed observation and pushes back the next allowed attempt.
    mutating func note(_ ids: some Sequence<WindowID>, frames: [WindowID: CGRect] = [:], now: Date = Date()) {
        for id in ids {
            let attempts = (entries[id]?.attempts ?? 0) + 1
            let delay = min(Self.maxDelay, Self.firstDelay * pow(2, Double(attempts - 1)))
            entries[id] = Entry(attempts: attempts, notBefore: now.addingTimeInterval(delay), frame: frames[id] ?? entries[id]?.frame)
        }
    }

    /// Waiting for the interval, or out of retries.
    func isWaiting(_ id: WindowID, now: Date = Date()) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.attempts >= Self.maxAttempts || entry.notBefore > now
    }

    /// The earliest attempt time among windows waiting for their interval. Windows out of retries are excluded.
    func nextAttempt(among ids: some Sequence<WindowID>, now: Date = Date()) -> Date? {
        ids.compactMap { entries[$0] }.filter { $0.attempts < Self.maxAttempts && $0.notBefore > now }.map(\.notBefore).min()
    }

    func attempts(_ id: WindowID) -> Int { entries[id]?.attempts ?? 0 }

    mutating func clear(_ id: WindowID) { entries[id] = nil }

    /// Waits without a schedule until cleared (or the frame changes): for windows looked at only after a change.
    mutating func hold(_ ids: some Sequence<WindowID>, frames: [WindowID: CGRect] = [:]) {
        for id in ids { entries[id] = Entry(attempts: Self.maxAttempts, notBefore: .distantFuture, frame: frames[id] ?? entries[id]?.frame) }
    }

    mutating func removeAll() { entries.removeAll() }

    /// Keeps only windows still seen as unplaced. Forgets windows that were placed, disappeared, or whose frame changed.
    mutating func keep(only frames: [WindowID: CGRect], tolerance: Double) {
        entries = entries.filter { id, entry in
            guard let now = frames[id] else { return false }
            guard let then = entry.frame else { return true }
            return now.matches(then, tolerance: tolerance)
        }
    }
}
