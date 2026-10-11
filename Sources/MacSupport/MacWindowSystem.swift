import AppKit
import ApplicationServices
import Copy
import Foundation
import LayoutCore
import Operations

/// macOS integration: observation, plus issuing and reading back authorized operations. Holds no layout intent.
public final class MacWindowSystem: WindowSystem {
    private struct Cached {
        var element: AXElement
        var app: AXElement
        var pid: pid_t
        var bundleID: String
        /// The Space where this element was observed. Writes to a hidden Space use only elements seen on that Space.
        var observedSpace: UInt64? = nil
    }

    private let lock = NSLock()
    private var cache: [WindowID: Cached] = [:]
    /// Apps that returned a window list during this launch, and consecutive failures of apps that never did. Read and written under `lock`.
    private var listedPIDs: Set<pid_t> = []
    private var unlistedFailures: [pid_t: Int] = [:]
    private let spaces = SpaceObserver()
    public let input = InputMonitor()
    private let readTimeout: TimeInterval
    // Only for comparison checks in development builds. Release always changes and restores the attribute temporarily.
    private var suppressAXAnimations: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LAZYSPACE_AX_ANIMATIONS"] != "preserve"
        #else
        return true
        #endif
    }

    /// Whether a failed window-list request leaves it unknown whether the app has windows.
    /// Unknown when it does not respond or permission is missing; no windows when it quit (invalid element) or has no list (unsupported, unimplemented, no value).
    /// Other failures are unknown too, except that an app failing 3 times in a row without ever returning a list (games that always fail, for example)
    /// is treated as having no list (so it never keeps other windows' arrangement from completing; a single failure right after a restart does not count).
    static func windowListUnobserved(_ failure: AXFailure, listedBefore: Bool, failuresWithoutList: Int) -> Bool {
        switch failure {
        case .invalidElement, .attributeUnsupported, .notImplemented: return false
        case .other(let code): return code != AXError.noValue.rawValue && (listedBefore || failuresWithoutList < 3)
        case .cannotComplete, .apiDisabled: return true
        }
    }

    public init(readTimeout: TimeInterval = 1.0) {
        self.readTimeout = readTimeout
    }

    public var spaceObservationAvailable: Bool { spaces != nil && PrivateSymbols.axUIElementGetWindow != nil }

    // MARK: WindowSystem

    public func currentSpaceID() -> UInt64? { spaces?.activeSpace() }

    public func existingSpaceIDs() -> Set<UInt64>? {
        spaces.map { Set($0.managedDisplays().flatMap(\.spaces)) }
    }

    public var inputActivityCount: UInt64 { input.count }
    public var mouseButtonDown: Bool { input.leftMouseDown }

    /// Work area of the display showing the Space, or the main display if the Space is unknown.
    public func workArea(forSpace spaceID: UInt64?) -> CGRect {
        guard let spaces, let spaceID else { return Screens.primaryWorkArea() }
        let display = spaces.managedDisplays().first { $0.currentSpace == spaceID }?.display
        return Screens.workArea(displayUUID: display)
    }

    public func currentWorkArea() -> CGRect { workArea(forSpace: currentSpaceID()) }

    private struct AppObservation {
        var windows: [ObservedWindow] = []
        var cache: [WindowID: Cached] = [:]
        var unresponsive = false
    }

    public func snapshot() -> Snapshot { snapshot(limitingTo: nil) }

    public func membershipOf(_ id: WindowID) -> ObservedWindow.Membership? {
        guard let spaces, let active = currentSpaceID() else { return nil }
        let list = spaces.spaces(for: id.raw)
        if list.isEmpty { return WindowList.exists(id.raw) ? .unknown : nil }
        if list.count > 1, list.contains(active) { return .allSpaces }
        if list.contains(active) { return .current }
        return .other
    }

    public var axTrusted: Bool { AXTrust.isTrusted() }

    public func snapshot(limitingTo ids: Set<WindowID>?) -> Snapshot {
        snapshot(limitingTo: ids, before: nil)
    }

    /// Bounded observation (for classifying new windows). Before each per-app query and each per-window attribute read, the query limit is reset to the time
    /// left until the deadline (no request waits longer). An app that runs out of time is marked unobservable without finishing.
    public func snapshot(limitingTo ids: Set<WindowID>, deadline: Date) -> Snapshot {
        snapshot(limitingTo: ids, before: deadline)
    }

    /// `space` observes that Space as if it were current (a Space another display is showing); nil observes the current Space.
    private func snapshot(limitingTo ids: Set<WindowID>?, before deadline: Date?, space: UInt64? = nil) -> Snapshot {
        let trusted = AXTrust.isTrusted()
        let active = space ?? spaces?.activeSpace()
        // Split View and fullscreen transition windows can report AXFullScreen
        // late or false. The native Space type also excludes them from tiling.
        let onFullscreenSpace = active.flatMap { spaces?.spaceType($0) } == 4
        let workArea = workArea(forSpace: active)
        guard trusted else {
            return Snapshot(trusted: false, spaceID: active, workArea: workArea, windows: [], spaceObservationAvailable: spaceObservationAvailable)
        }
        // Record whether the full window list was read. If not, it is treated as empty but never as evidence of closing.
        let fullList = WindowList.allIfAvailable()
        let cgWindows = fullList ?? [:]
        let stackOrder = WindowList.onScreenOrder()
        let me = ProcessInfo.processInfo.processIdentifier
        // With membership, only window owners can be asked, so the running-apps list is not read (see `runningAppsToStartFrom`).
        let listed = Self.runningAppsToStartFrom(membershipAvailable: spaces != nil && active != nil) { NSWorkspace.shared.runningApplications }
        // Use pids from the list or from window owners (CGWindowList), never NSRunningApplication's.
        // Apps missing from LaunchServices (for example, Xcode's Device Hub) are not listed, and looking them up by pid gives processIdentifier -1.
        let byPID = Dictionary(listed.filter { $0.processIdentifier > 0 }.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var lookedUp: [pid_t: NSRunningApplication] = [:]
        let regular: [(pid: pid_t, app: NSRunningApplication)] = Self.appsToAsk(
            listed: listed.map { (pid: $0.processIdentifier, regular: $0.activationPolicy == .regular && !$0.isTerminated) },
            windowOwners: Set(cgWindows.values.filter { $0.layer == 0 }.map(\.pid)), me: me,
            isRegular: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, !app.isTerminated else { return false }
                lookedUp[pid] = app
                return true
            }).compactMap { pid in (byPID[pid] ?? lookedUp[pid]).map { (pid: pid, app: $0) } }

        // Membership is asked of SkyLight per CGWindowList window (before AX, independent of app responsiveness).
        // Apps with no normal-layer window on the current Space are not asked through AX,
        // so an unrelated unresponsive app never makes arrangement partial or delays it by its timeout.
        var membership: [CGWindowID: ObservedWindow.Membership] = [:]
        var relevantPIDs: Set<pid_t>?
        // While several displays share one Space, only windows centered on the menu-bar display count as windows of the current Space.
        let sharedDisplay = !NSScreen.screensHaveSeparateSpaces && NSScreen.screens.count > 1 ? NSScreen.screens.first.map { Screens.topLeft($0.frame) } : nil
        if let spaces, let active {
            let regularPIDs = Set(regular.map(\.pid))
            var pids: Set<pid_t> = []
            for (wid, rec) in cgWindows where rec.layer == 0 && regularPIDs.contains(rec.pid) {
                if let ids, !ids.contains(WindowID(wid)) { continue }
                let list = spaces.spaces(for: wid)
                let m: ObservedWindow.Membership
                if list.isEmpty { m = .unknown }
                else if list.count > 1 && list.contains(active) { m = .allSpaces }
                else if list.contains(active) {
                    m = sharedDisplay.map { $0.contains(CGPoint(x: rec.bounds.midX, y: rec.bounds.midY)) } ?? true ? .current : .otherDisplay
                }
                else { m = .other }
                membership[wid] = m
                // Windows with unknown membership are invisible helper windows many apps have; unless on screen, they alone are no reason to query.
                if m == .current || m == .allSpaces || (m == .unknown && rec.onScreen) { pids.insert(rec.pid) }
            }
            relevantPIDs = pids
        }
        if let ids {
            let allowed = Set(ids.compactMap { cgWindows[$0.raw]?.pid })
            relevantPIDs = relevantPIDs.map { $0.intersection(allowed) } ?? allowed
        }
        let apps = regular.filter { relevantPIDs?.contains($0.pid) ?? true }

        // Per-app AX queries are independent, so they run in parallel; an unresponsive app does not hold up the others.
        let readTimeout = readTimeout
        let collect = NSLock()
        var observations = [AppObservation?](repeating: nil, count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let (pid, app) = apps[i]
            let bundleID = app.bundleIdentifier ?? "pid\(pid)"
            let appElement = AXElement.application(pid: pid)
            appElement.setMessagingTimeout(readTimeout)
            var out = AppObservation()
            let budget = AXReadBudget(timeout: readTimeout, deadline: deadline)
            // With a deadline, each request's limit is cut to the remaining time; false when none is left (not finished).
            func limit(_ element: AXElement) -> Bool {
                budget.prepare(element)
            }
            guard limit(appElement) else {
                out.unresponsive = true
                collect.lock(); observations[i] = out; collect.unlock()
                return
            }
            switch appElement.windows() {
            case .failure(let e):
                // If the answer leaves window presence unknown, record it as unobservable instead of silently dropping targets.
                self.lock.lock()
                let listedBefore = self.listedPIDs.contains(pid)
                if !listedBefore { self.unlistedFailures[pid, default: 0] += 1 }
                let failures = self.unlistedFailures[pid] ?? 0
                self.lock.unlock()
                out.unresponsive = Self.windowListUnobserved(e, listedBefore: listedBefore, failuresWithoutList: failures)
            case .success(let axWindows):
                self.lock.lock(); self.listedPIDs.insert(pid); self.unlistedFailures[pid] = nil; self.lock.unlock()
                for w in axWindows {
                    guard limit(w) else { out.unresponsive = true; break }
                    guard let wid = w.windowID() else { continue }
                    let id = WindowID(wid)
                    // Narrow by window, not just by pid; this also drops the same app's windows on other Spaces.
                    if let ids, !ids.contains(id) { continue }
                    // In a bounded observation, each attribute read resets the limit to the remaining time; if it runs out, this window is not finished.
                    guard limit(w) else { out.unresponsive = true; break }
                    let role = w.string(kAXRoleAttribute) ?? "?"
                    guard limit(w) else { out.unresponsive = true; break }
                    let subrole = w.string(kAXSubroleAttribute) ?? "?"
                    let frame: CGRect
                    switch budget.frame(w) {
                    case .success(let f): frame = f
                    case .failure: frame = cgWindows[wid]?.bounds ?? .zero
                    }
                    guard limit(w) else { out.unresponsive = true; break }
                    // A timed-out read leaves the app unobserved: a minimized window taken as not minimized would be tiled, and writing it restores it.
                    // Other failures keep counting as false (apps that do not implement the attribute answer with errors).
                    guard let minimized = Self.boolUnlessTimedOut(w, kAXMinimizedAttribute) else { out.unresponsive = true; break }
                    guard limit(w) else { out.unresponsive = true; break }
                    guard let fullscreen = Self.boolUnlessTimedOut(w, "AXFullScreen") else { out.unresponsive = true; break }
                    let layer = cgWindows[wid]?.layer ?? 0
                    guard limit(w) else { out.unresponsive = true; break }
                    let dialogHasZoom = subrole == kAXDialogSubrole && {
                        if case .success = w.copyAttribute(kAXZoomButtonAttribute) { return true }
                        return false
                    }()
                    guard limit(w) else { out.unresponsive = true; break }
                    let fullscreenButtonEnabled = Self.fullscreenButtonEnabled(w, limit: { limit($0) })
                    // Only windows without an enabled full-screen button are checked for resizability (unreadable counts as not resizable).
                    let resizable = !fullscreenButtonEnabled && limit(w) && Self.isResizable(w, limit: { limit($0) }) == true
                    let kind = ObservedWindow.Kind.observed(
                        hiddenApp: app.isHidden, minimized: minimized, fullscreen: fullscreen, layer: layer,
                        role: role, subrole: subrole, dialogHasZoomButton: dialogHasZoom,
                        fullscreenButtonEnabled: fullscreenButtonEnabled, resizable: resizable, onFullscreenSpace: onFullscreenSpace
                    )

                    // Windows not looked up beforehand (visible only to AX, non-normal layers, and the like) get their membership asked here.
                    let m: ObservedWindow.Membership
                    if let known = membership[wid] { m = known }
                    else if let spaces, let active {
                        let list = spaces.spaces(for: wid)
                        if list.isEmpty { m = .unknown }
                        else if list.count > 1 && list.contains(active) { m = .allSpaces }
                        else if list.contains(active) { m = .current }
                        else { m = .other }
                    } else { m = .unknown }

                    guard limit(w) else { out.unresponsive = true; break }
                    let title = w.string(kAXTitleAttribute) ?? ""
                    out.windows.append(ObservedWindow(id: id, pid: pid, app: bundleID, frame: frame, membership: m, kind: kind, detail: "\(role)/\(subrole) layer=\(layer)", subrole: subrole, stackOrder: stackOrder[wid] ?? Int.max, title: title))
                    out.cache[id] = Cached(element: budget.prepareForCaching(w), app: appElement, pid: pid, bundleID: bundleID,
                                           observedSpace: m == .current ? active : nil)
                }
            }
            collect.lock(); observations[i] = out; collect.unlock()
        }

        var windows: [ObservedWindow] = []
        var unobserved: [String] = []
        var newCache: [WindowID: Cached] = [:]
        for (entry, obs) in zip(apps, observations) {
            guard let obs else { continue }
            if obs.unresponsive { unobserved.append(entry.app.bundleIdentifier ?? "pid\(entry.pid)") }
            windows.append(contentsOf: obs.windows)
            newCache.merge(obs.cache) { _, new in new }
        }
        lock.lock()
        for (k, v) in newCache { cache[k] = v }
        // Do not keep elements of closed windows (only when the list was read; windows on other Spaces are listed and stay).
        for id in Self.closedCacheEntries(Set(cache.keys), allWindows: fullList.map { Set($0.keys) }) { cache[id] = nil }
        lock.unlock()
        return Snapshot(trusted: true, spaceID: active, workArea: workArea, windows: windows, spaceObservationAvailable: spaceObservationAvailable, unobservedApps: unobserved,
                        windowListAvailable: fullList != nil)
    }

    /// Windows absent from the full window list (closed). Returns nothing if the list could not be read.
    static func closedCacheEntries(_ cached: Set<WindowID>, allWindows: Set<CGWindowID>?) -> Set<WindowID> {
        guard let allWindows else { return [] }
        return cached.filter { !allWindows.contains($0.raw) }
    }

    /// Reads the window lists once and only retains elements. Per-app queries run in parallel, each request checks the time left until the deadline, and stops when none is left.
    /// Only windows whose SkyLight membership is the current Space alone are retained (no current-Space origin for windows visible on another display).
    /// If the Space changed during collection, nothing is retained. Unresponsive apps are dropped (observation backoff is left to normal observation).
    public func retainElements(for ids: Set<WindowID>, deadline: Date) {
        guard !ids.isEmpty, AXTrust.isTrusted(), let spaces, let active = spaces.activeSpace() else { return }
        let fullList = WindowList.allIfAvailable()
        let cgWindows = fullList ?? [:]
        // This runs on every arrival even while paused; drop elements of closed windows here too (only when the list was read).
        lock.lock()
        for id in Self.closedCacheEntries(Set(cache.keys), allWindows: fullList.map { Set($0.keys) }) { cache[id] = nil }
        lock.unlock()
        let me = ProcessInfo.processInfo.processIdentifier
        let wanted = ids.filter { cgWindows[$0.raw] != nil && spaces.spaces(for: $0.raw) == [active] }
        let pids = Set(wanted.compactMap { cgWindows[$0.raw]?.pid }).subtracting([me])
        // Apps missing from the running-apps list (absent from LaunchServices) are also looked up by window-owner pid, and that pid is used.
        let apps: [(pid: pid_t, app: NSRunningApplication)] = pids.sorted().compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular, !app.isTerminated else { return nil }
            return (pid: pid, app: app)
        }
        guard !apps.isEmpty else { return }
        let readTimeout = readTimeout
        let collect = NSLock()
        var found: [WindowID: Cached] = [:]
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.01 else { return }
            let (pid, app) = apps[i]
            let appElement = AXElement.application(pid: pid)
            appElement.setMessagingTimeout(min(readTimeout, remaining))
            guard case .success(let axWindows) = appElement.windows() else { return }
            let bundleID = app.bundleIdentifier ?? "pid\(pid)"
            for w in axWindows {
                // If reading the list used up the time, give the next request (mapping window IDs) a short limit, or stop.
                let left = deadline.timeIntervalSinceNow
                guard left > 0.01 else { return }
                appElement.setMessagingTimeout(min(readTimeout, left))
                w.setMessagingTimeout(min(readTimeout, left))
                let mapped = w.windowID()
                // The element is retained, so do not leave the short limit on it (0 restores the default). Later raises and reads/writes set only the app-level limit.
                w.setMessagingTimeout(0)
                guard let wid = mapped, wanted.contains(WindowID(wid)) else { continue }
                let entry = Cached(element: w, app: appElement, pid: pid, bundleID: bundleID, observedSpace: active)
                collect.lock(); found[WindowID(wid)] = entry; collect.unlock()
            }
        }
        guard spaces.activeSpace() == active else { return }
        lock.lock()
        for (k, v) in found { cache[k] = v }
        lock.unlock()
    }

    private func cached(_ id: WindowID) -> Cached? {
        lock.lock()
        if let c = cache[id] { lock.unlock(); return c }
        lock.unlock()
        // A window that appeared after the last observation (close / full screen right after opening, for example). If it exists, observe once, then look it up.
        guard WindowList.exists(id.raw) else { return nil }
        _ = snapshot(limitingTo: [id])
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    public func readFrame(_ id: WindowID) -> FrameRead {
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .failed(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(readTimeout)
        switch c.element.frame() {
        case .success(let f): return .frame(f)
        case .failure(let e):
            if e == .invalidElement || !WindowList.exists(id.raw) {
                lock.lock(); cache[id] = nil; lock.unlock()
                return .gone
            }
            return .failed(e.label)
        }
    }

    /// The only path for authorized writes.
    public func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(timeout)
        let current: CGRect
        switch c.element.frame() {
        case .success(let f): current = f
        case .failure(let e):
            if e == .invalidElement || !WindowList.exists(id.raw) { return .gone }
            if e == .cannotComplete { return .timedOut }
            return .rejected(e.label)
        }
        return writeFrame(id, frame: frame, currentFrame: current, timeout: timeout, shouldContinue: shouldContinue)
    }

    public func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(timeout)
        return AXFrameWriter.write(current: currentFrame, target: frame,
            enhancedUI: { self.suppressAXAnimations ? c.app.bool("AXEnhancedUserInterface") : nil },
            setEnhancedUI: { value in
                let error = AXUIElementSetAttributeValue(c.app.raw, "AXEnhancedUserInterface" as CFString,
                                                        value ? kCFBooleanTrue : kCFBooleanFalse)
                return error == .success ? nil : AXFailure(error)
            },
            setPosition: { c.element.setPosition($0) },
            setSize: { c.element.setSize($0) },
            isGone: { !WindowList.exists(id.raw) }, shouldContinue: shouldContinue)
    }

    /// Reads only windows seen in the last observation; never reobserves for an unseen window.
    public func windowTitle(_ id: WindowID) -> String? {
        lock.lock(); let c = cache[id]; lock.unlock()
        guard let c else { return nil }
        c.app.setMessagingTimeout(readTimeout)
        return c.element.string(kAXTitleAttribute)
    }

    public func focusedWindowID() -> WindowID? { focusedWindowID(within: readTimeout) }

    public func focusedWindowID(within timeout: TimeInterval) -> WindowID? {
        guard let pid = FrontmostApp.pid() else { return nil }
        let appElement = AXElement.application(pid: pid)
        appElement.setMessagingTimeout(timeout)
        guard case .success(let v) = appElement.copyAttribute(kAXFocusedWindowAttribute) else { return nil }
        let element = AXElement(raw: unsafeBitCast(v, to: AXUIElement.self))
        return element.windowID().map(WindowID.init)
    }

    /// Checks `activateIf` again right before AXRaise too (resolving the element can take time) and refuses without sending anything if false.
    /// After AXRaise, activates the app on the main thread if `activateIf` is true; never after the operation has ended or was interrupted.
    public func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult {
        // `activated` is called exactly once on the main thread for any return value (nil on paths that queue no activation).
        func notActivated(_ result: WriteResult) -> WriteResult {
            if let activated { DispatchQueue.main.async { activated(nil) } }
            return result
        }
        guard let c = cached(id) else { return notActivated(WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone) }
        guard activateIf() else { return notActivated(.rejected(L("The operation was interrupted before the window was raised.", "ウインドウを前面にする前に操作が中断されました。"))) }
        c.app.setMessagingTimeout(timeout)
        let err = AXUIElementPerformAction(c.element.raw, kAXRaiseAction as CFString)
        if err == .invalidUIElement || !WindowList.exists(id.raw) { return notActivated(.gone) }
        // AXRaise may have arrived, but no activation was queued.
        if err == .cannotComplete { return notActivated(.timedOut) }
        if err != .success { return notActivated(.rejected(AXFailure(err).label)) }
        let pid = c.pid
        guard let app = NSRunningApplication(processIdentifier: pid) else { return notActivated(.issued) }
        DispatchQueue.main.async {
            if activateIf() {
                AppActivation.activate(app, pid: pid, allowed: activateIf, stillOwner: { WindowList.all()[id.raw]?.pid == pid })
                activated?(pid)
            } else { activated?(nil) }
        }
        return .issued
    }

    /// Presses the close button. Called only from the user's key action. Writes no geometry.
    public func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(timeout)
        switch c.element.copyAttribute(kAXCloseButtonAttribute) {
        case .failure(let e):
            if e == .invalidElement || !WindowList.exists(id.raw) { return .gone }
            if e == .cannotComplete { return .timedOut }
            return .rejected(L("The window has no close button: \(e.label)", "ウインドウに閉じるボタンがありません: \(e.label)"))
        case .success(let v):
            let button = unsafeBitCast(v, to: AXUIElement.self)
            guard shouldContinue() else { return .interrupted }
            let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
            if err == .cannotComplete { return .timedOut }
            if err != .success { return .rejected(AXFailure(err).label) }
            return .issued
        }
    }

    public func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard shouldContinue() else { return .interrupted }
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(timeout)
        let name = attribute == .fullscreen ? "AXFullScreen" : kAXMinimizedAttribute
        switch c.element.copyAttribute(name) {
        case .failure(let e):
            if e == .invalidElement || !WindowList.exists(id.raw) { return .gone }
            if e == .cannotComplete { return .timedOut }
            return .rejected(L("Could not read the window attribute: \(e.label)", "ウインドウの属性を読めません: \(e.label)"))
        case .success(let v):
            let now = (v as? NSNumber)?.boolValue ?? false
            guard shouldContinue() else { return .interrupted }
            let err = AXUIElementSetAttributeValue(c.element.raw, name as CFString, now ? kCFBooleanFalse : kCFBooleanTrue)
            if err == .cannotComplete { return .timedOut }
            if err == .success { return .issued }
            // For apps that do not accept the attribute write, press the button like the user would (full-screen or minimize button).
            let buttonName = attribute == .fullscreen ? kAXFullScreenButtonAttribute : kAXMinimizeButtonAttribute
            guard shouldContinue() else { return .interrupted }
            guard case .success(let b) = c.element.copyAttribute(buttonName) else { return .rejected(AXFailure(err).label) }
            guard shouldContinue() else { return .interrupted }
            let pressed = AXUIElementPerformAction(unsafeBitCast(b, to: AXUIElement.self), kAXPressAction as CFString)
            if pressed == .cannotComplete { return .timedOut }
            if pressed != .success { return .rejected(AXFailure(pressed).label) }
            return .issued
        }
    }

    public func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard let c = cached(id) else { return .gone }
        guard shouldContinue() else { return .interrupted }
        c.app.setMessagingTimeout(timeout)
        let name = attribute == .fullscreen ? "AXFullScreen" : kAXMinimizedAttribute
        // Absolute assignment only. A button fallback could reverse a state that changed after the read.
        let error = AXUIElementSetAttributeValue(c.element.raw, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
        if error == .success { return .issued }
        if error == .cannotComplete { return .timedOut }
        if error == .invalidUIElement { return .gone }
        return .rejected(AXFailure(error).label)
    }

    public func readWindowState(_ id: WindowID, _ attribute: WindowStateAttribute) -> Bool? {
        guard let c = cached(id) else { return nil }
        c.app.setMessagingTimeout(readTimeout)
        return c.element.bool(attribute == .fullscreen ? "AXFullScreen" : kAXMinimizedAttribute)
    }

    /// Full-window-list entries (including off-screen and other Spaces) for the given windows; nil if the list is unavailable. Missing windows have no key.
    public func windowRecords(_ ids: Set<WindowID>) -> [WindowID: CGWindowRecord]? {
        guard let all = WindowList.allIfAvailable() else { return nil }
        var out: [WindowID: CGWindowRecord] = [:]
        for id in ids { if let r = all[id.raw] { out[id] = r } }
        return out
    }

    /// Whether an observed window is minimized, read within the time left until the deadline without re-enumerating; nil when unreadable.
    public func readMinimized(_ id: WindowID, deadline: Date) -> Bool? {
        lock.lock(); let c = cache[id]; lock.unlock()
        guard let c, Self.within(deadline, c) else { return nil }
        switch c.element.copyAttribute(kAXMinimizedAttribute) {
        case .success(let v): return (v as? NSNumber)?.boolValue
        case .failure: return nil
        }
    }

    // MARK: Hidden Space

    /// Spaces the window belongs to (SkyLight); empty means undecided, nil when Spaces cannot be observed.
    public func spacesOf(_ id: WindowID) -> [UInt64]? { spaces?.spaces(for: id.raw) }

    public func windowRecord(_ id: WindowID) -> CGWindowRecord? { WindowList.record(id.raw) }

    /// Work area of a hidden Space, returned only when exactly one display holds it, it is a standard Space,
    /// and the screen can be identified. Never falls back to the main display (so nothing is written in another display's coordinates).
    /// nil if any display's shown Space is unknown (being hidden cannot be confirmed).
    public func spaceDisplay(_ space: UInt64) -> SpaceDisplay? {
        guard let spaces else { return nil }
        let displays = spaces.managedDisplays()
        guard !displays.isEmpty, displays.allSatisfy({ $0.currentSpace != nil }),
              let display = SpaceDisplay.holding(space, in: displays),
              let area = Screens.knownWorkArea(displayUUID: display.display), area.width > 0, area.height > 0 else { return nil }
        return SpaceDisplay(display: display.display, workArea: area, shown: display.currentSpace == space)
    }

    /// Fresh, bounded observation of a Space another display is showing (never the current Space). Elements are cached as observed on that Space,
    /// so `readFrame(inSpace:)` and `writeFrame(inSpace:)` can use them.
    public func snapshot(ofShownSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        let unavailable = Snapshot(trusted: AXTrust.isTrusted(), spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
        guard AXTrust.isTrusted(), let spaces, let display = spaceDisplay(space), display.shown, spaces.activeSpace() != space else { return unavailable }
        var snap = snapshot(limitingTo: ids, before: deadline, space: space)
        // The Space must still be shown, not current, and on the same display with the same work area after the reads.
        // The work area is the matched display's (never the main display's fallback).
        guard spaceDisplay(space) == display, spaces.activeSpace() != space else { return unavailable }
        snap.workArea = display.workArea
        return snap
    }

    /// Observes windows of a hidden Space using only AX elements observed on that Space, without re-enumerating.
    /// Returns only windows whose window ID and pid match and whose attributes were all read; the others go into `unobservedApps`.
    /// Each AX request is cut off at the time left until the deadline, and none is sent after it.
    public func snapshot(ofHiddenSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        let unavailable = Snapshot(trusted: AXTrust.isTrusted(), spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
        guard AXTrust.isTrusted(), let spaces, let display = spaceDisplay(space), !display.shown,
              spaces.activeSpace() != space else { return unavailable }
        let fullList = WindowList.allIfAvailable()
        let cgWindows = fullList ?? [:]
        var windows: [ObservedWindow] = []
        var unobserved: [String] = []
        for id in ids.sorted() {
            guard let c = retained(id, on: space, deadline: deadline) else {
                if Date() >= deadline { unobserved.append("deadline"); break }
                continue
            }
            guard let record = cgWindows[id.raw], let app = NSRunningApplication(processIdentifier: c.pid), !app.isTerminated else { continue }
            let list = spaces.spaces(for: id.raw)
            let membership: ObservedWindow.Membership
            if list.isEmpty { membership = .unknown }
            else if list.count > 1 && list.contains(space) { membership = .allSpaces }
            else if list.contains(space) { membership = .current }
            else { membership = .other }
            func read<T>(_ body: () -> T?) -> T? { Self.within(deadline, c) ? body() : nil }
            guard let role = read({ Self.strictString(c.element, kAXRoleAttribute) }),
                  let subrole = read({ Self.strictString(c.element, kAXSubroleAttribute) }),
                  let minimized = read({ Self.strictBool(c.element, kAXMinimizedAttribute) }),
                  let fullscreen = read({ Self.strictBool(c.element, "AXFullScreen") }),
                  let fullscreenButton = Self.strictFullscreenButtonEnabled(c, deadline: deadline),
                  case .success(let frame) = Self.frame(c, deadline: deadline) else { unobserved.append(c.bundleID); continue }
            // The same tests as observing a visible Space (AXDialog with a zoom button, resizable windows).
            let dialogHasZoom = subrole == kAXDialogSubrole && Self.within(deadline, c) && {
                if case .success = c.element.copyAttribute(kAXZoomButtonAttribute) { return true }
                return false
            }()
            let resizable = !fullscreenButton && Self.within(deadline, c)
                && Self.isResizable(c.element, limit: { _ in Self.within(deadline, c) }) == true
            let kind = ObservedWindow.Kind.observed(
                hiddenApp: app.isHidden, minimized: minimized, fullscreen: fullscreen, layer: record.layer,
                role: role, subrole: subrole, dialogHasZoomButton: dialogHasZoom, fullscreenButtonEnabled: fullscreenButton, resizable: resizable)
            windows.append(ObservedWindow(id: id, pid: c.pid, app: c.bundleID, frame: frame, membership: membership, kind: kind,
                                          detail: "\(role)/\(subrole) layer=\(record.layer) hidden-space", subrole: subrole, stackOrder: Int.max, title: ""))
        }
        return Snapshot(trusted: true, spaceID: space, workArea: display.workArea, windows: windows, spaceObservationAvailable: true, unobservedApps: unobserved,
                        windowListAvailable: fullList != nil)
    }

    /// Frame of a window on a Space other than the current one, using only elements observed on that Space; not read after the deadline.
    public func readFrame(inSpace id: WindowID, space: UInt64, deadline: Date) -> FrameRead {
        guard let c = retained(id, on: space, deadline: deadline) else { return WindowList.exists(id.raw) ? .failed(L("The window can't be read on that Space.", "その操作スペースのウインドウを読めません。")) : .gone }
        switch Self.frame(c, deadline: deadline) {
        case .success(let f): return .frame(f)
        case .failure(let e): return e == .invalidElement || !WindowList.exists(id.raw) ? .gone : .failed(e.label)
        }
    }

    /// Geometry write to a window on a Space other than the current one. Checks `shouldContinue` and the deadline before the frame read and each size -> position -> size request.
    /// Never touches app-wide attributes (AXEnhancedUserInterface), and never focuses, raises, or activates.
    public func writeFrame(inSpace id: WindowID, space: UInt64, frame target: CGRect, deadline: Date, shouldContinue: @escaping () -> Bool) -> WriteResult {
        let stopped = WriteResult.rejected(L("Stopped because the Space, the window, input, or the time limit changed.", "操作スペース・ウインドウ・入力・時間の条件が変わったため中止しました。"))
        guard shouldContinue() else { return stopped }
        guard let c = retained(id, on: space, deadline: deadline) else { return WindowList.exists(id.raw) ? stopped : .gone }
        guard shouldContinue() else { return stopped }
        let current: CGRect
        switch Self.frame(c, deadline: deadline) {
        case .success(let f): current = f
        case .failure(let e):
            if e == .invalidElement || !WindowList.exists(id.raw) { return .gone }
            return e == .cannotComplete ? .timedOut : .rejected(e.label)
        }
        let proceed = { shouldContinue() && Self.within(deadline, c) }
        return AXFrameWriter.write(current: current, target: target,
            enhancedUI: { nil }, setEnhancedUI: { _ in nil },
            setPosition: { proceed() ? c.element.setPosition($0) : .other(-1) },
            setSize: { proceed() ? c.element.setSize($0) : .other(-1) },
            isGone: { !WindowList.exists(id.raw) })
    }

    /// The element observed on that Space, only if the window ID has not changed (not reused by another window).
    private func retained(_ id: WindowID, on space: UInt64, deadline: Date) -> Cached? {
        lock.lock(); let c = cache[id]; lock.unlock()
        guard let c, c.observedSpace == space, let record = WindowList.all()[id.raw], record.pid == c.pid,
              Self.within(deadline, c), c.element.windowID() == id.raw else { return nil }
        return c
    }

    /// Uses the time left until the deadline as the next AX request's limit; false when none is left.
    private static func within(_ deadline: Date, _ c: Cached) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.01 else { return false }
        c.app.setMessagingTimeout(remaining)
        c.element.setMessagingTimeout(remaining)
        return true
    }

    /// Reads position and size, each within the time left until the deadline; no further request after the deadline.
    private static func frame(_ c: Cached, deadline: Date) -> Result<CGRect, AXFailure> {
        guard within(deadline, c) else { return .failure(.cannotComplete) }
        let origin: CGPoint
        switch c.element.point(kAXPositionAttribute) {
        case .success(let p): origin = p
        case .failure(let e): return .failure(e)
        }
        guard within(deadline, c) else { return .failure(.cannotComplete) }
        switch c.element.size(kAXSizeAttribute) {
        case .success(let size): return .success(CGRect(origin: origin, size: size))
        case .failure(let e): return .failure(e)
        }
    }

    /// Tells unreadable, no value, and unsupported apart: unsupported and no value give the default, other failures nil (unobservable).
    /// The value, false when it cannot be read, or nil when the read timed out.
    private static func boolUnlessTimedOut(_ element: AXElement, _ name: String) -> Bool? {
        switch element.copyAttribute(name) {
        case .success(let v): return (v as? NSNumber)?.boolValue ?? false
        case .failure(.cannotComplete): return nil
        case .failure: return false
        }
    }

    private static func strictBool(_ element: AXElement, _ name: String) -> Bool? {
        switch element.copyAttribute(name) {
        case .success(let v): return (v as? NSNumber)?.boolValue ?? false
        case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return false
        case .failure: return nil
        }
    }

    private static func strictString(_ element: AXElement, _ name: String) -> String? {
        switch element.copyAttribute(name) {
        case .success(let v): return v as? String
        case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return "?"
        case .failure: return nil
        }
    }

    /// The same test as `fullscreenButtonEnabled`, but nil when unreadable (never assumed enabled).
    /// The button element also gets the remaining time as its limit before reading.
    private static func strictFullscreenButtonEnabled(_ c: Cached, deadline: Date) -> Bool? {
        guard within(deadline, c) else { return nil }
        switch c.element.copyAttribute(kAXFullScreenButtonAttribute) {
        case .success(let raw):
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            let button = AXElement(raw: unsafeBitCast(raw, to: AXUIElement.self))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.01 else { return nil }
            button.setMessagingTimeout(remaining)
            switch button.copyAttribute(kAXEnabledAttribute) {
            case .success(let v): return (v as? NSNumber)?.boolValue ?? true
            case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return true
            case .failure: return nil
            }
        case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return false
        case .failure: return nil
        }
    }

    /// Running apps a snapshot starts from. With Space membership every asked app owns a layer-0 window, so window owners are looked up
    /// by their own pid instead: reading the properties of every running app is costly on every snapshot.
    /// Without membership, apps are taken from the running-apps list as before.
    static func runningAppsToStartFrom<App>(membershipAvailable: Bool, read: () -> [App]) -> [App] {
        membershipAvailable ? [] : read()
    }

    /// Pids of apps to query for windows through AX: regular apps in the running-apps list plus owners of normal-layer windows (list order, then by pid).
    /// Apps missing from LaunchServices (for example, Xcode's Device Hub) are not listed but do own windows; looked up by pid as in the overview and census.
    static func appsToAsk(listed: [(pid: pid_t, regular: Bool)], windowOwners: Set<pid_t>, me: pid_t, isRegular: (pid_t) -> Bool) -> [pid_t] {
        var out: [pid_t] = []
        var seen: Set<pid_t> = [me]
        for app in listed where app.regular && app.pid > 0 && seen.insert(app.pid).inserted { out.append(app.pid) }
        for pid in windowOwners.sorted() where !seen.contains(pid) && isRegular(pid) {
            seen.insert(pid)
            out.append(pid)
        }
        return out
    }

    // MARK: Position-only writes and dialog evidence

    /// Writes only the position (no size, activation, or focus), using the element retained by observation and checking `shouldContinue` right before writing.
    public func writePosition(_ id: WindowID, origin: CGPoint, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        guard let c = cached(id) else { return WindowList.exists(id.raw) ? .rejected(L("The window has not been inspected yet.", "まだ確認していないウインドウです。")) : .gone }
        c.app.setMessagingTimeout(timeout)
        c.element.setMessagingTimeout(timeout)
        guard shouldContinue() else { return .interrupted }
        switch c.element.setPosition(origin) {
        case nil: return .issued
        case .invalidElement?: return .gone
        case .cannotComplete?: return .timedOut
        case let failure?: return .rejected(failure.label)
        }
    }

    /// Dialog-region evidence (one window, bounded). A missing attribute counts as known; any unreadable attribute gives nil.
    public func dialogEvidence(pid: pid_t, window id: WindowID, deadline: Date) -> DialogEvidence? {
        let budget = AXReadBudget(timeout: readTimeout, deadline: deadline)
        func read(_ element: AXElement, _ name: String) -> CFTypeRef?? {
            guard budget.prepare(element) else { return nil }
            switch element.copyAttribute(name) {
            case .success(let value): return .some(value)
            case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(AXError.noValue.rawValue)): return .some(nil)
            case .failure: return nil
            }
        }
        /// A button. `enabledWhenUnknown` decides the case with no "enabled" value (full-screen button enabled, as in observation; zoom button disabled).
        func button(_ window: AXElement, _ name: String, enabledWhenUnknown: Bool) -> DialogEvidence.Button? {
            guard let value = read(window, name) else { return nil }
            guard let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .absent }
            guard let enabled = read(AXElement(raw: unsafeBitCast(raw, to: AXUIElement.self)), kAXEnabledAttribute) else { return nil }
            guard let flag = (enabled as? NSNumber)?.boolValue else { return enabledWhenUnknown ? .enabled : .disabled }
            return flag ? .enabled : .disabled
        }
        let app = AXElement.application(pid: pid)
        guard budget.prepare(app), case .success(let windows) = app.windows() else { return nil }
        for window in windows {
            guard budget.prepare(window) else { return nil }
            guard window.windowID() == id.raw else { continue }
            var settable: DarwinBoolean = false
            guard let roleValue = read(window, kAXRoleAttribute), let role = roleValue as? String,
                  let subroleValue = read(window, kAXSubroleAttribute),
                  let minimizedValue = read(window, kAXMinimizedAttribute),
                  let fullscreenValue = read(window, "AXFullScreen"),
                  let fullscreenButton = button(window, kAXFullScreenButtonAttribute, enabledWhenUnknown: true),
                  let zoomButton = button(window, kAXZoomButtonAttribute, enabledWhenUnknown: false),
                  let titleValue = read(window, kAXTitleAttribute),
                  budget.prepare(window),
                  AXUIElementIsAttributeSettable(window.raw, kAXSizeAttribute as CFString, &settable) == .success else { return nil }
            return DialogEvidence(role: role, subrole: subroleValue as? String,
                                  minimized: (minimizedValue as? NSNumber)?.boolValue ?? false,
                                  fullscreen: (fullscreenValue as? NSNumber)?.boolValue ?? false,
                                  fullscreenButton: fullscreenButton, zoomButton: zoomButton, sizeSettable: settable.boolValue,
                                  title: titleValue as? String ?? "")
        }
        return nil
    }

    /// Resizable: the size is writable and the zoom (green) button exists and is enabled; nil if any is unreadable.
    /// `limit` cuts the request limit to the remaining time (nil once exhausted).
    static func isResizable(_ window: AXElement, limit: (AXElement) -> Bool = { _ in true }) -> Bool? {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window.raw, kAXSizeAttribute as CFString, &settable) == .success else { return nil }
        guard settable.boolValue else { return false }
        guard limit(window) else { return nil }
        switch window.copyAttribute(kAXZoomButtonAttribute) {
        case .success(let raw):
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            let button = AXElement(raw: unsafeBitCast(raw, to: AXUIElement.self))
            guard limit(button) else { return nil }
            // The zoom button is enabled only when read as enabled (no value or unreadable is not enabled).
            switch button.copyAttribute(kAXEnabledAttribute) {
            case .success(let v): return (v as? NSNumber)?.boolValue == true
            case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return false
            case .failure: return nil
            }
        case .failure(.attributeUnsupported), .failure(.notImplemented), .failure(.other(-25212)): return false
        case .failure: return nil
        }
    }

    /// True if a full-screen button exists and is not disabled. Windows without one are treated as dialogs.
    /// `limit` cuts the button request limit to the remaining time in bounded observations (once exhausted, the default true without reading).
    private static func fullscreenButtonEnabled(_ window: AXElement, limit: (AXElement) -> Bool = { _ in true }) -> Bool {
        guard case .success(let raw) = window.copyAttribute(kAXFullScreenButtonAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let button = AXElement(raw: unsafeBitCast(raw, to: AXUIElement.self))
        guard limit(button) else { return true }
        return button.bool(kAXEnabledAttribute) ?? true
    }
}

/// Names shown to the user: the running app, then the installed app, then the bundle identifier itself.
public enum AppNames {
    public static func localized(_ bundleID: String) -> String { knownName(bundleID) ?? bundleID }

    /// The app's display name, or nil when neither a running nor an installed app has that exact identifier.
    public static func knownName(_ bundleID: String) -> String? {
        knownName(bundleID, running: runningName, installed: installedName)
    }

    static func knownName(_ bundleID: String, running: (String) -> String?, installed: (String) -> String?) -> String? {
        if let name = running(bundleID), !name.isEmpty { return name }
        if let name = installed(bundleID), !name.isEmpty { return name }
        return nil
    }

    /// Apps missing from the running-apps list (absent from LaunchServices) are looked up again by bundle identifier.
    private static func runningName(_ bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
    }

    private static func installedName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else { return nil }
        return bundleName(bundle, for: bundleID)
    }

    /// LaunchServices matches identifiers without regard to case, while rules match exactly, so the bundle must carry the identifier as written.
    static func bundleName(_ bundle: Bundle, for bundleID: String) -> String? {
        guard bundle.bundleIdentifier == bundleID else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty { return name }
        }
        return nil
    }
}
