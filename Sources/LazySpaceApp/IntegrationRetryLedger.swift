import CoreGraphics
import Foundation
import LayoutCore

/// How many times automatic integration failed at the same frame. Read only under Coordinator's lock.
struct IntegrationRetryLedger {
    private struct Failure {
        var count: Int
        var frame: CGRect
        /// Input count when the failure was recorded. Frame changes while it stays the same are not the user's doing.
        var inputCount: UInt64
    }

    private var failures: [WindowID: Failure] = [:]

    var isEmpty: Bool { failures.isEmpty }

    mutating func clear(_ id: WindowID) {
        failures[id] = nil
    }

    func gaveUp(_ id: WindowID) -> Bool {
        (failures[id]?.count ?? 0) >= 2
    }

    /// Forgets the record only when the input count changed and the frame moved beyond the tolerance.
    @discardableResult
    mutating func forgiveMoved(id: WindowID, frame: CGRect, inputCount: UInt64, tolerance: Double) -> Bool {
        guard let entry = failures[id], entry.inputCount != inputCount,
              !frame.matches(entry.frame, tolerance: tolerance) else { return false }
        failures[id] = nil
        return true
    }

    mutating func record(_ ids: [WindowID], bounds: [WindowID: CGRect], inputCount: UInt64, tolerance: Double) {
        for id in ids {
            let frame = bounds[id] ?? failures[id]?.frame ?? .zero
            var entry = failures[id] ?? Failure(count: 0, frame: frame, inputCount: inputCount)
            if entry.inputCount != inputCount, !frame.matches(entry.frame, tolerance: tolerance) {
                entry = Failure(count: 0, frame: frame, inputCount: inputCount)
            }
            entry.count += 1
            entry.frame = frame
            entry.inputCount = inputCount
            failures[id] = entry
        }
    }
}
