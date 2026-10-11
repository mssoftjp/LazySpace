import AppKit
import CoreGraphics
import Foundation

/// Raw window list for judging direct-switch app candidates: every CGWindowList window (all displays) with SkyLight membership. No AX.
/// `SpaceOverview` skips small windows and apps of windows with unknown membership, so it cannot prove "this app's windows are only on the target".
/// The decisions (`eligibleApps` / `isEligible`) are pure functions of the values, separate from reading (`take`).
public struct AppWindowInventory: Equatable {
    public struct App: Equatable {
        public var pid: pid_t
        public var bundleID: String?
        public var regular: Bool
        public var hidden: Bool

        public init(pid: pid_t, bundleID: String?, regular: Bool, hidden: Bool) {
            self.pid = pid; self.bundleID = bundleID; self.regular = regular; self.hidden = hidden
        }
    }

    /// One layer-0 window. `spaces` is SkyLight membership (empty = unknown).
    /// `orderedIn` is false for a window the app keeps ordered out (a closed settings window can still list a Space); nil is unknown.
    public struct Window: Equatable {
        public var id: CGWindowID
        public var pid: pid_t
        public var onScreen: Bool
        public var spaces: [UInt64]
        public var orderedIn: Bool?

        public init(id: CGWindowID, pid: pid_t, onScreen: Bool, spaces: [UInt64], orderedIn: Bool? = nil) {
            self.id = id; self.pid = pid; self.onScreen = onScreen; self.spaces = spaces; self.orderedIn = orderedIn
        }
    }

    /// An activation candidate. Identity is checked by both pid and bundle ID.
    public struct Candidate: Equatable {
        public var pid: pid_t
        public var bundleID: String
    }

    /// LazySpace's own pid, never a candidate.
    public var selfPID: pid_t
    /// Spaces shown on each display. A window there that is not on screen is known to be minimized.
    public var visibleSpaces: Set<UInt64>
    public var apps: [pid_t: App]
    public var windows: [Window]

    public init(selfPID: pid_t, visibleSpaces: Set<UInt64>, apps: [pid_t: App], windows: [Window]) {
        self.selfPID = selfPID; self.visibleSpaces = visibleSpaces; self.apps = apps; self.windows = windows
    }

    /// The Dock and Finder are never activation candidates (they own the desktop and their windows behave unlike other apps).
    public static let excludedBundleIDs: Set<String> = ["com.apple.dock", "com.apple.finder"]

    /// Why an app is not a candidate; also explains an empty candidate table during field checks.
    public enum Exclusion: Equatable, CustomStringConvertible {
        case lazySpace
        case excludedApp(String)
        case notRegular
        case hidden
        case noBundleID
        /// No window only on the target Space (ignoring auxiliary windows).
        case noWindowOnTarget
        /// A window with other membership (current Space, all Spaces, another Space); the first one found.
        case windowElsewhere(CGWindowID, spaces: [UInt64])
        /// A window with unknown membership is on screen (visible on the current Space).
        case visibleUnknownWindow(CGWindowID)
        /// The app's windows on the target are all known to be minimized.
        case onlyMinimized

        public var description: String {
            switch self {
            case .lazySpace: return "LazySpace itself"
            case .excludedApp(let id): return "excluded app (\(id))"
            case .notRegular: return "not a regular app"
            case .hidden: return "hidden"
            case .noBundleID: return "no bundle identifier"
            case .noWindowOnTarget: return "no window only on the target Space"
            case .windowElsewhere(let wid, let spaces): return "window \(wid) on \(spaces)"
            case .visibleUnknownWindow(let wid): return "on-screen window \(wid) with unknown Space"
            case .onlyMinimized: return "only minimized windows on the target Space"
            }
        }
    }

    /// Apps with standard windows only on `target`, by ascending pid.
    public func eligibleApps(on target: UInt64) -> [Candidate] {
        apps.keys.sorted().compactMap { pid in
            guard let bundleID = apps[pid]?.bundleID, exclusion(of: pid, on: target) == nil else { return nil }
            return Candidate(pid: pid, bundleID: bundleID)
        }
    }

    /// Recheck right before activation. If the pid's app has a different bundle ID (pid reuse), it is not eligible.
    public func isEligible(pid: pid_t, bundleID: String, on target: UInt64) -> Bool {
        guard apps[pid]?.bundleID == bundleID else { return false }
        return exclusion(of: pid, on: target) == nil
    }

    /// Window ID -> owner pid, used to order candidates (front history, relation to the layout).
    public var owners: [CGWindowID: pid_t] {
        Dictionary(windows.map { ($0.id, $0.pid) }, uniquingKeysWith: { a, _ in a })
    }

    /// Why the app is not a candidate; nil when eligible.
    /// Eligible: regular, not hidden, not ourselves, the Dock, or Finder; at least one window only on `target` that is not ordered out;
    /// no window with other membership (current Space, all Spaces, another Space); and no on-screen window with unknown membership.
    /// Off-screen windows with unknown membership are deliberately ignored as auxiliary. In practice every app has a few such layer-0 windows
    /// (full-width thin strips, small windows, 1x1), and treating them as conflicts would leave no candidates.
    /// An on-screen window with unknown membership is visible on the current Space, so it conflicts.
    /// Apps whose only target windows are known minimized (on a shown Space but not on screen) are excluded too.
    /// Windows on a Space not shown are usually not on screen and cannot be told from minimized ones, so the post-send check decides.
    public func exclusion(of pid: pid_t, on target: UInt64) -> Exclusion? {
        guard let app = apps[pid] else { return .noWindowOnTarget }
        if app.pid == selfPID { return .lazySpace }
        guard let bundleID = app.bundleID else { return .noBundleID }
        if Self.excludedBundleIDs.contains(bundleID) { return .excludedApp(bundleID) }
        if !app.regular { return .notRegular }
        if app.hidden { return .hidden }
        var onTarget: [Window] = []
        for w in windows where w.pid == pid {
            if w.spaces.isEmpty {
                if w.onScreen { return .visibleUnknownWindow(w.id) }
                continue
            }
            guard w.spaces == [target] else { return .windowElsewhere(w.id, spaces: w.spaces) }
            // Ordered-out windows (closed but kept, or minimized) are shown nowhere: activating the app cannot switch to them.
            // They still conflict above, as any window on another Space does.
            if w.orderedIn != false { onTarget.append(w) }
        }
        if onTarget.isEmpty { return .noWindowOnTarget }
        let knownMinimized = { (w: Window) in !w.onScreen && self.visibleSpaces.contains(target) }
        return onTarget.allSatisfy(knownMinimized) ? .onlyMinimized : nil
    }

    /// Reads the full window list and memberships; nil when the list is unavailable (distinct from empty).
    /// Windows of non-regular apps or unknown owners do not affect the decision, so their membership is not queried.
    public static func take() -> AppWindowInventory? {
        guard let observer = SpaceObserver(), let list = WindowList.allIfAvailable() else { return nil }
        let visible = Set(observer.managedDisplays().compactMap(\.currentSpace) + [observer.activeSpace()].compactMap { $0 })
        var apps: [pid_t: App] = [:]
        var unresolved = Set<pid_t>()
        var windows: [Window] = []
        for (wid, rec) in list where rec.layer == 0 {
            if unresolved.contains(rec.pid) { continue }
            let app: App
            if let known = apps[rec.pid] { app = known } else {
                guard let running = NSRunningApplication(processIdentifier: rec.pid), !running.isTerminated else { unresolved.insert(rec.pid); continue }
                app = App(pid: rec.pid, bundleID: running.bundleIdentifier, regular: running.activationPolicy == .regular, hidden: running.isHidden)
                apps[rec.pid] = app
            }
            guard app.regular else { continue }
            // A fully transparent window (fading out as it closes) counts as ordered out too.
            let orderedIn = rec.alpha > 0 ? observer.isOrderedIn(wid) : false
            windows.append(Window(id: wid, pid: rec.pid, onScreen: rec.onScreen, spaces: observer.spaces(for: wid), orderedIn: orderedIn))
        }
        return AppWindowInventory(selfPID: ProcessInfo.processInfo.processIdentifier, visibleSpaces: visible,
                                  apps: apps, windows: windows.sorted { $0.id < $1.id })
    }
}
