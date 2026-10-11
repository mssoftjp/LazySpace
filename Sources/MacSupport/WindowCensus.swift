import AppKit
import Foundation
import LayoutCore
import Operations

/// Cheap observation for automatic arrangement: CGWindowList (on-screen) only, no AX.
/// On-screen layer-0 windows are those visible on the current Space. Windows on all Spaces and dialogs
/// are mixed in, but the snapshot excludes them when an operation runs.
public enum WindowCensus {
    private static var policyCache: [pid_t: (NSApplication.ActivationPolicy, Date)] = [:]
    private static let policyLock = NSLock()

    private static func isRegularApp(_ pid: pid_t) -> Bool {
        policyLock.lock()
        defer { policyLock.unlock() }
        let now = Date()
        if let (policy, at) = policyCache[pid], now.timeIntervalSince(at) < 30 { return policy == .regular }
        let policy = NSRunningApplication(processIdentifier: pid)?.activationPolicy ?? .prohibited
        policyCache[pid] = (policy, now)
        return policy == .regular
    }

    /// Windows fainter than this count as invisible. A closing window stays listed for about 0.3 s after fading
    /// below 0.01; counting it would delay refilling the gap by that much.
    public static let vanishingAlpha = 0.05

    static func isVisible(alpha: Double) -> Bool { alpha >= vanishingAlpha }

    public static func take(spaceID: UInt64?) -> Census {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("census")
        #endif
        let me = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = FrontmostApp.pid()
        return census(WindowList.entries([.optionOnScreenOnly, .excludeDesktopElements]), spaceID: spaceID,
                      me: me, frontmostPID: frontmostPID, isRegular: isRegularApp)
    }

    static func census(_ entries: [NSDictionary]?, spaceID: UInt64?, me: pid_t, frontmostPID: pid_t?,
                       isRegular: (pid_t) -> Bool) -> Census {
        var windows: [WindowID: Int32] = [:]
        var bounds: [WindowID: CGRect] = [:]
        var frontWindow: WindowID?
        // CGWindowList returns front to back; the front app's first standard window stands for the focused window.
        for d in entries ?? [] {
            guard let num = d[kCGWindowNumber] as? NSNumber,
                  let pidNum = d[kCGWindowOwnerPID] as? NSNumber,
                  (d[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  isVisible(alpha: (d[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) else { continue }
            let pid = pidNum.int32Value
            guard pid != me, isRegular(pid) else { continue }
            var rect = CGRect.zero
            if let b = d[kCGWindowBounds] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { rect = r }
            if rect.width < 60 || rect.height < 40 { continue } // tooltips and other tiny windows
            windows[WindowID(num.uint32Value)] = pid
            bounds[WindowID(num.uint32Value)] = rect
            if frontWindow == nil, pid == frontmostPID { frontWindow = WindowID(num.uint32Value) }
        }
        return Census(windows: windows, frontmostPID: frontmostPID, spaceID: spaceID, bounds: bounds, frontWindow: frontWindow)
    }
}
