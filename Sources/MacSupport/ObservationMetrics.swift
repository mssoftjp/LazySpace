#if LAZYSPACE_PERF
import Foundation

/// Measurement builds only. Product builds keep neither the counters nor the lock.
public enum ObservationMetrics {
    private static let lock = NSLock()
    private static var values: [String: Int] = [:]
    public static func record(_ name: String) {
        lock.lock(); values[name, default: 0] += 1; lock.unlock()
    }
    public static func reset() { lock.lock(); values.removeAll(keepingCapacity: true); lock.unlock() }
    public static func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return values }
}
#endif
