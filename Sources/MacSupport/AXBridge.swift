import AppKit
import ApplicationServices
import Foundation

public enum AXTrust {
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Requests the system permission dialog. The click result and actual usability are checked separately.
    public static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

public enum AXFailure: Error, Equatable {
    case invalidElement
    case cannotComplete
    case notImplemented
    case attributeUnsupported
    case apiDisabled
    case other(Int32)

    init(_ err: AXError) {
        switch err {
        case .invalidUIElement: self = .invalidElement
        case .cannotComplete: self = .cannotComplete
        case .notImplemented: self = .notImplemented
        case .attributeUnsupported: self = .attributeUnsupported
        case .apiDisabled: self = .apiDisabled
        default: self = .other(err.rawValue)
        }
    }

    public var label: String {
        switch self {
        case .invalidElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .attributeUnsupported: return "attributeUnsupported"
        case .apiDisabled: return "apiDisabled"
        case .other(let code): return "AXError(\(code))"
        }
    }
}

/// A thin AXUIElement wrapper. Never reads titles or content.
public struct AXElement {
    public let raw: AXUIElement

    public init(raw: AXUIElement) { self.raw = raw }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid))
    }

    public func setMessagingTimeout(_ seconds: TimeInterval) {
        AXUIElementSetMessagingTimeout(raw, Float(seconds))
    }

    public func copyAttribute(_ name: String) -> Result<CFTypeRef, AXFailure> {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("axRead")
        #endif
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        guard err == .success, let value else { return .failure(AXFailure(err == .success ? .noValue : err)) }
        return .success(value)
    }

    public func string(_ name: String) -> String? {
        if case .success(let v) = copyAttribute(name) { return v as? String }
        return nil
    }

    public func bool(_ name: String) -> Bool? {
        if case .success(let v) = copyAttribute(name) { return (v as? NSNumber)?.boolValue }
        return nil
    }

    public func windows() -> Result<[AXElement], AXFailure> {
        switch copyAttribute(kAXWindowsAttribute) {
        case .failure(let f): return .failure(f)
        case .success(let v):
            // Anything but a list of elements is a failed read, never "no windows" (which would let a saved layout lose this app's windows).
            guard let array = v as? [AnyObject], array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return .failure(.other(AXError.failure.rawValue)) }
            return .success(array.map { AXElement(raw: unsafeBitCast($0, to: AXUIElement.self)) })
        }
    }

    public func point(_ name: String) -> Result<CGPoint, AXFailure> {
        switch copyAttribute(name) {
        case .failure(let f): return .failure(f)
        case .success(let v):
            var p = CGPoint.zero
            guard CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return .failure(.attributeUnsupported) }
            return .success(p)
        }
    }

    public func size(_ name: String) -> Result<CGSize, AXFailure> {
        switch copyAttribute(name) {
        case .failure(let f): return .failure(f)
        case .success(let v):
            var s = CGSize.zero
            guard CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &s) else { return .failure(.attributeUnsupported) }
            return .success(s)
        }
    }

    public func frame() -> Result<CGRect, AXFailure> {
        switch point(kAXPositionAttribute) {
        case .failure(let f): return .failure(f)
        case .success(let p):
            switch size(kAXSizeAttribute) {
            case .failure(let f): return .failure(f)
            case .success(let s): return .success(CGRect(origin: p, size: s))
            }
        }
    }

    public func setPosition(_ p: CGPoint) -> AXFailure? {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("axWrite")
        #endif
        var point = p
        guard let value = AXValueCreate(.cgPoint, &point) else { return .other(-1) }
        let err = AXUIElementSetAttributeValue(raw, kAXPositionAttribute as CFString, value)
        return err == .success ? nil : AXFailure(err)
    }

    public func setSize(_ s: CGSize) -> AXFailure? {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("axWrite")
        #endif
        var size = s
        guard let value = AXValueCreate(.cgSize, &size) else { return .other(-1) }
        let err = AXUIElementSetAttributeValue(raw, kAXSizeAttribute as CFString, value)
        return err == .success ? nil : AXFailure(err)
    }

    /// CGWindowID; nil without the private `_AXUIElementGetWindow`.
    public func windowID() -> CGWindowID? {
        guard let fn = PrivateSymbols.axUIElementGetWindow else { return nil }
        var wid: CGWindowID = 0
        guard fn(raw, &wid) == .success, wid != 0 else { return nil }
        return wid
    }
}

/// One CGWindowList entry.
public struct CGWindowRecord: Equatable {
    public var id: CGWindowID
    public var pid: pid_t
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var onScreen: Bool

    public init(id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect, alpha: Double, onScreen: Bool) {
        self.id = id; self.pid = pid; self.layer = layer; self.bounds = bounds; self.alpha = alpha; self.onScreen = onScreen
    }
}

/// The front app's pid. Apps missing from LaunchServices (for example, Xcode's Device Hub) report a `frontmostApplication`
/// processIdentifier of -1. Then use the pid of the single on-screen normal-layer window owner with the same bundle identifier.
/// Accessibility is not asked (no waiting on unresponsive apps). Otherwise unknown.
public enum FrontmostApp {
    public static func pid() -> pid_t? { resolve(NSWorkspace.shared.frontmostApplication) }

    public static func resolve(_ app: NSRunningApplication?) -> pid_t? {
        guard let app else { return nil }
        return resolve(app.processIdentifier, bundleID: { app.bundleIdentifier }, owners: onScreenOwners,
                       bundleOf: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }

    /// The bundle identifier is a LaunchServices query, so it is not read when a pid was reported.
    static func resolve(_ reported: pid_t, bundleID: () -> String?, owners: () -> Set<pid_t>, bundleOf: (pid_t) -> String?) -> pid_t? {
        if reported > 0 { return reported }
        guard let bundleID = bundleID() else { return nil }
        let matches = owners().filter { bundleOf($0) == bundleID }
        return matches.count == 1 ? matches.first : nil
    }

    static func onScreenOwners() -> Set<pid_t> { owners(WindowList.entries([.optionOnScreenOnly, .excludeDesktopElements])) }

    static func owners(_ entries: [NSDictionary]?) -> Set<pid_t> {
        Set((entries ?? []).compactMap { d in (d[kCGWindowLayer] as? Int) == 0 ? (d[kCGWindowOwnerPID] as? NSNumber)?.int32Value : nil })
    }
}

/// Activates an app. For apps missing from LaunchServices (reported with processIdentifier -1), `activate()` may not arrive,
/// so `AXFrontmost` is also set through the window owner's pid. Regular apps get only `activate()`.
/// `allowed` (the caller's gate) is checked right before each request; before `AXFrontmost`, `stillOwner` (the pid still owns the window) is checked first, then the gate.
public enum AppActivation {
    public static func activate(_ app: NSRunningApplication, pid: pid_t, allowed: () -> Bool, stillOwner: () -> Bool) {
        activate(reportedPID: app.processIdentifier, pid: pid, allowed: allowed, stillOwner: stillOwner,
                 activateApp: { app.activate() }, setFrontmost: setFrontmost)
    }

    static func activate(reportedPID: pid_t, pid: pid_t, allowed: () -> Bool, stillOwner: () -> Bool,
                         activateApp: () -> Bool, setFrontmost: (pid_t) -> Void) {
        guard allowed() else { return }
        _ = activateApp()
        // The owner check reads the list and takes time; if the gate closed meanwhile, do not write (the gate is checked right before writing).
        guard reportedPID <= 0, pid > 0, stillOwner(), allowed() else { return }
        setFrontmost(pid)
    }

    static func setFrontmost(_ pid: pid_t) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        _ = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

public enum WindowList {
    public static func all() -> [CGWindowID: CGWindowRecord] { allIfAvailable() ?? [:] }

    /// The full window list, or nil when unavailable (distinct from an empty list; never evidence that a window closed).
    public static func allIfAvailable() -> [CGWindowID: CGWindowRecord]? {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("cgList")
        #endif
        return records(entries([.optionAll, .excludeDesktopElements]))
    }

    /// One window's record without copying the whole list; nil when it is not listed or the read failed.
    public static func record(_ id: CGWindowID) -> CGWindowRecord? {
        // The array holds the ID itself as a pointer-sized value; bridging a Swift array would box it into an object.
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let ids = CFArrayCreate(nil, &values, 1, nil) else { return nil }
        return records(CGWindowListCreateDescriptionFromArray(ids) as? [NSDictionary])?[id]
    }

    /// Passes the list macOS returned without converting entries to Swift dictionaries; readers look up only their fields
    /// (converting every entry took most of the observation CPU). nil when unavailable or when an entry is not a dictionary.
    static func entries(_ options: CGWindowListOption) -> [NSDictionary]? {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary]
    }

    static func records(_ entries: [NSDictionary]?) -> [CGWindowID: CGWindowRecord]? {
        guard let entries else { return nil }
        var out: [CGWindowID: CGWindowRecord] = [:]
        for d in entries {
            guard let num = d[kCGWindowNumber] as? NSNumber,
                  let pid = d[kCGWindowOwnerPID] as? NSNumber else { continue }
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: b) ?? .zero
            }
            out[num.uint32Value] = CGWindowRecord(
                id: num.uint32Value, pid: pid.int32Value,
                layer: (d[kCGWindowLayer] as? NSNumber)?.intValue ?? 0,
                bounds: bounds,
                alpha: (d[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1,
                onScreen: (d[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false)
        }
        return out
    }

    /// On-screen windows front to back, 0 frontmost. The full list's order spans Spaces, so it is not used.
    public static func onScreenOrder() -> [CGWindowID: Int] {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("cgList")
        #endif
        return order(entries([.optionOnScreenOnly, .excludeDesktopElements]))
    }

    static func order(_ entries: [NSDictionary]?) -> [CGWindowID: Int] {
        var out: [CGWindowID: Int] = [:]
        for (order, d) in (entries ?? []).enumerated() {
            guard let num = d[kCGWindowNumber] as? NSNumber else { continue }
            out[num.uint32Value] = order
        }
        return out
    }

    public static func exists(_ id: CGWindowID) -> Bool {
        // An unavailable list is no evidence of disappearance. An AX error means .gone only when a valid list
        // confirms the window is absent (invalidElement is decided separately).
        mayExist(id, in: existingIDsIfAvailable())
    }

    static func mayExist(_ id: CGWindowID, in ids: Set<CGWindowID>?) -> Bool { ids?.contains(id) ?? true }

    /// Existence checks for one observation; nil on failure. `exists` copies the full window list on every call.
    public static func existingIDsIfAvailable() -> Set<CGWindowID>? {
        #if LAZYSPACE_PERF
        ObservationMetrics.record("cgList")
        #endif
        return ids(entries([.optionAll]))
    }

    static func ids(_ entries: [NSDictionary]?) -> Set<CGWindowID>? {
        guard let entries else { return nil }
        var ids = Set<CGWindowID>()
        for d in entries {
            if let num = d[kCGWindowNumber] as? NSNumber { ids.insert(num.uint32Value) }
        }
        return ids
    }
}
