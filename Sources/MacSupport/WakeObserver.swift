import AppKit
import ApplicationServices
import Foundation
import LayoutCore

/// Treats per-app AX notifications as a hint to observe sooner. Window additions and removals are decided only from
/// CGWindowList differences; without notifications the regular interval catches up. The times of move and resize notifications
/// are evidence that windows stood still, used only to adopt a mouse edit before the quiet time (`geometryQuiet`).
/// The notification run loop lives on its own thread so main is never blocked.
/// Every regular app is observed, so a window opened by an app with no window on the current Space is announced too;
/// only window creation wakes for such apps, other notifications wake only for apps in the current census.
public final class WakeObserver {
    private var observers: [pid_t: AXObserver] = [:] {
        didSet {
            let attached = Set(observers.keys)
            loopLock.lock()
            gate.attached = attached
            loopLock.unlock()
        }
    }
    /// Guarded by loopLock, like `census` and `regular`.
    private var gate = WatchGate()
    /// Apps with a window in the last census (any thread writes through `watch`; the notification callback reads it).
    private var census: Set<pid_t> = []
    /// Regular running apps, read on main (reading the running-apps list off main costs about 25 ms).
    private var regular: Set<pid_t> = []
    /// Apps with an attachment in flight (main only).
    private var attaching: Set<pid_t> = []
    /// Time of the last window move or resize notification per app, and the apps whose observer registered both (guarded by loopLock).
    private var geometryNotices: [pid_t: Date] = [:]
    private var geometryCovered: Set<pid_t> = []
    private let me = ProcessInfo.processInfo.processIdentifier
    private var tokens: [NSObjectProtocol] = []
    private let onWake: (WindowID?) -> Void
    private let attachQueue = DispatchQueue(label: "jp.lazyspace.wake-attach", qos: .utility)
    private var loopThread: Thread?
    private var loop: CFRunLoop?
    private let loopReady = DispatchSemaphore(value: 0)
    private let loopLock = NSLock()
    /// Keeps the thread alive if `CFRunLoopRun` returns before a source is attached.
    private var stopRequested = false
    private var _loopPasses = 0
    /// Passes of the notification thread's loop; used to check it is not spinning.
    public var loopPasses: Int {
        get { loopLock.lock(); defer { loopLock.unlock() }; return _loopPasses }
    }

    public init(onWake: @escaping (WindowID?) -> Void) {
        self.onWake = onWake
    }

    public func start() {
        startLoop()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                // A quit app's retry state goes; an activated app that had given up is tried again.
                if let pid, name == NSWorkspace.didTerminateApplicationNotification || name == NSWorkspace.didActivateApplicationNotification {
                    loopLock.lock(); gate.forget(pid); loopLock.unlock()
                }
                if [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                    NSWorkspace.didActivateApplicationNotification].contains(name) { refreshRegularApps() }
                onWake(nil)
            }
        }
        refreshRegularApps()
    }

    /// Main only.
    private func refreshRegularApps() {
        let apps = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier > 0 }.map(\.processIdentifier))
        loopLock.lock(); regular = apps; loopLock.unlock()
        reconcile(census: nil)
    }

    /// Records the apps of the current census and reconciles observers; nothing happens on main when nothing would change.
    /// Called on every observation, so a request with nothing to do finishes without waking main.
    public func watch(_ pids: Set<pid_t>) { reconcile(census: pids) }

    /// `census` nil keeps the current census (a regular-app update must not write back an older copy over a newer observation).
    private func reconcile(census pids: Set<pid_t>?) {
        let onMain = Thread.isMainThread
        let now = Date()
        loopLock.lock()
        if let pids { census = pids }
        let desired = Self.desired(census: census, regular: regular, me: me)
        gate.prune(keeping: desired, census: census)
        let needed = gate.needsMain(desired, now: now)
        if needed, !onMain { gate.pending += 1 }
        loopLock.unlock()
        guard needed else { return }
        if !onMain {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply()
                self.endPending()
            }
            return
        }
        apply()
    }

    /// Whether none of these apps reported a window move or resize since `since`; nil when one of them has no attached observer,
    /// so there is no evidence either way. Any thread.
    public func geometryQuiet(pids: Set<pid_t>, since: Date) -> Bool? {
        loopLock.lock(); defer { loopLock.unlock() }
        return Self.geometryQuiet(pids: pids, covered: geometryCovered.intersection(gate.attached), notices: geometryNotices, since: since)
    }

    /// nil unless every app registered both the move and the resize notification; otherwise whether none of them reported one since `since`.
    static func geometryQuiet(pids: Set<pid_t>, covered: Set<pid_t>, notices: [pid_t: Date], since: Date) -> Bool? {
        guard pids.isSubset(of: covered) else { return nil }
        return !pids.contains { notices[$0].map { $0 >= since } ?? false }
    }

    /// Apps to observe: the census apps (which include apps missing from LaunchServices) and every regular app, never LazySpace itself.
    static func desired(census: Set<pid_t>, regular: Set<pid_t>, me: pid_t) -> Set<pid_t> {
        census.union(regular).filter { $0 != me && $0 > 0 }
    }

    /// Attachment order: the front app, then census apps, then the rest, so an unresponsive background app does not delay the apps that matter.
    static func attachOrder(_ pids: Set<pid_t>, front: pid_t?, census: Set<pid_t>) -> [pid_t] {
        pids.sorted { a, b in
            func rank(_ p: pid_t) -> Int { p == front ? 0 : census.contains(p) ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a < b
        }
    }

    /// Only window creation wakes for an app without a window in the census; its announcement is checked by the next observation.
    static func wakes(created: Bool, pid: pid_t?, census: Set<pid_t>) -> Bool {
        created || pid.map { $0 > 0 && census.contains($0) } ?? false
    }

    /// What main should observe now, from the current snapshots; quit processes are left out so a stale census cannot bring them back.
    private func currentDesired() -> Set<pid_t> {
        loopLock.lock(); let desired = Self.desired(census: census, regular: regular, me: me); loopLock.unlock()
        return desired.filter(Self.isAlive)
    }

    private static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func endPending() {
        loopLock.lock()
        gate.pending -= 1
        loopLock.unlock()
    }

    /// Main only.
    private func endAttach(_ pid: pid_t) {
        attaching.remove(pid)
        endPending()
    }

    /// Main only. A failure is recorded only for an app still wanted, so a late completion cannot recreate retry state that was pruned.
    private func attachFailed(_ pid: pid_t, loop: CFRunLoop) {
        let alive = Self.isAlive(pid)
        // Checked and recorded under one lock, so a `watch` that prunes the app in between cannot be undone by this completion.
        loopLock.lock()
        if alive, self.loop === loop, Self.desired(census: census, regular: regular, me: me).contains(pid) {
            gate.noteAttachFailure(pid, now: Date(), inCensus: census.contains(pid))
        }
        loopLock.unlock()
        endAttach(pid)
    }

    /// Main only. Detaches with the full desired set; attaches only apps whose retry is due.
    private func apply() {
        guard AXTrust.isTrusted() else { return }
        let desired = currentDesired()
        let now = Date()
        loopLock.lock()
        let due = desired.filter { gate.mayAttach($0, now: now) }
        let currentCensus = census
        loopLock.unlock()
        let known = Set(observers.keys)
        for pid in known.subtracting(desired) { detach(pid) }
        let missing = due.subtracting(known).subtracting(attaching)
        for pid in Self.attachOrder(missing, front: FrontmostApp.pid(), census: currentCensus) { attach(pid) }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
        for pid in Array(observers.keys) { detach(pid) }
        loopLock.lock()
        stopRequested = true
        let currentLoop = loop
        let thread = loopThread
        loopLock.unlock()
        if let currentLoop { CFRunLoopStop(currentLoop) }
        if let thread, Thread.current != thread {
            let deadline = Date().addingTimeInterval(2)
            while !thread.isFinished, Date() < deadline {
                if let currentLoop { CFRunLoopStop(currentLoop) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        loopLock.lock()
        loopThread = nil
        loop = nil
        loopLock.unlock()
    }

    private func startLoop() {
        loopLock.lock()
        if loopThread != nil { loopLock.unlock(); return }
        stopRequested = false
        loopLock.unlock()
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            guard let self else { return }
            self.loopLock.lock()
            self.loop = runLoop
            self.loopLock.unlock()
            // A run loop with no sources or timers returns at once and spins; a timer that never fires keeps it waiting.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
            self.loopReady.signal()
            while true {
                self.loopLock.lock()
                let stop = self.stopRequested
                if !stop { self._loopPasses += 1 }
                self.loopLock.unlock()
                if stop { break }
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
            CFRunLoopRemoveTimer(runLoop, keepAlive, .defaultMode)
        }
        thread.name = "LazySpace.AX"
        loopLock.lock()
        loopThread = thread
        loopLock.unlock()
        thread.start()
        _ = loopReady.wait(timeout: .now() + 2)
    }

    private func currentLoop() -> CFRunLoop? {
        loopLock.lock(); defer { loopLock.unlock() }
        return loop
    }

    private func detach(_ pid: pid_t) {
        loopLock.lock(); geometryCovered.remove(pid); geometryNotices[pid] = nil; loopLock.unlock()
        guard let observer = observers.removeValue(forKey: pid), let loop else { return }
        CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func attach(_ pid: pid_t) {
        guard observers[pid] == nil, let loop else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        attaching.insert(pid)
        loopLock.lock()
        gate.pending += 1
        loopLock.unlock()
        attachQueue.async { [weak self] in
            var created: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                let me = Unmanaged<WakeObserver>.fromOpaque(refcon).takeUnretainedValue()
                let isCreation = (notification as String) == (kAXWindowCreatedNotification as String)
                var owner: pid_t = 0
                let pid: pid_t? = AXUIElementGetPid(element, &owner) == .success ? owner : nil
                let isGeometry = [kAXWindowMovedNotification, kAXWindowResizedNotification].contains(notification as String)
                me.loopLock.lock()
                if isGeometry, let pid { me.geometryNotices[pid] = Date() }
                let census = me.census
                me.loopLock.unlock()
                guard WakeObserver.wakes(created: isCreation, pid: pid, census: census) else { return }
                let announced = isCreation ? AXElement(raw: element).windowID().map(WindowID.init) : nil
                // The observer is alive on the notification thread. Take the handler here so nothing touches it if it is freed after handing off to main.
                let wake = me.onWake
                DispatchQueue.main.async { wake(announced) }
            }
            guard AXObserverCreate(pid, callback, &created) == .success, let created else {
                DispatchQueue.main.async { self?.attachFailed(pid, loop: loop) }
                return
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            // Window creation first: if an app does not answer it (still launching, or hung), the other registrations would only wait again.
            let creation = AXObserverAddNotification(created, app, kAXWindowCreatedNotification as CFString, refcon)
            let registered = creation == .success || creation == .notificationAlreadyRegistered
            var geometry = 0
            if registered {
                for name in [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                             kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                    let added = AXObserverAddNotification(created, app, name as CFString, refcon)
                    if name == kAXWindowMovedNotification || name == kAXWindowResizedNotification, added == .success || added == .notificationAlreadyRegistered { geometry += 1 }
                }
            }
            let coversGeometry = geometry == 2
            DispatchQueue.main.async {
                guard let self else { return }
                // An app that does not answer yet would otherwise keep an observer that never delivers anything; retry it later.
                guard registered else { self.attachFailed(pid, loop: loop); return }
                defer { self.endAttach(pid) }
                // If stopped, the run loop was replaced, or the app is no longer wanted while creating, do not add it.
                guard self.observers[pid] == nil, self.currentLoop() === loop, self.currentDesired().contains(pid) else { return }
                CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(created), .defaultMode)
                self.observers[pid] = created
                self.loopLock.lock()
                self.gate.noteAttached(pid)
                // Only an observer that receives both moves and resizes is evidence that the app's windows stood still.
                if coversGeometry { self.geometryCovered.insert(pid) } else { self.geometryCovered.remove(pid) }
                self.loopLock.unlock()
            }
        }
    }
}

/// Tells which per-observation watch requests need not wake main: only when no request is waiting on main,
/// no observer is being attached, and the requested set equals the attached set (main would do nothing).
/// With work waiting, the observer table may change after it, so the request goes through.
/// An app whose attachment failed is retried after 1 s, doubling to 8 s; an app outside the census gives up at 8 s
/// until it enters the census or is activated (an app that never answers would otherwise cost an attempt every 8 s forever).
struct WatchGate {
    /// Apps with an attached observer, copied whenever the observer table changes.
    var attached: Set<pid_t> = []
    /// Watch requests waiting on main plus observers being attached.
    var pending = 0
    /// Earliest time to try an app again after a failed attachment (`distantFuture` once given up).
    private(set) var retryNotBefore: [pid_t: Date] = [:]
    private var retryDelay: [pid_t: TimeInterval] = [:]

    func mayAttach(_ pid: pid_t, now: Date) -> Bool { retryNotBefore[pid].map { $0 <= now } ?? true }

    /// Apps still backing off do not count as missing, so observations in between do not wake main for them.
    func needsMain(_ wanted: Set<pid_t>, now: Date = Date()) -> Bool {
        pending > 0 || wanted.filter { attached.contains($0) || mayAttach($0, now: now) } != attached
    }

    mutating func noteAttachFailure(_ pid: pid_t, now: Date, inCensus: Bool = true) {
        if !inCensus, retryDelay[pid] == 8 { retryNotBefore[pid] = .distantFuture; return }
        let delay = min(8, (retryDelay[pid] ?? 0.5) * 2)
        retryDelay[pid] = delay
        retryNotBefore[pid] = now.addingTimeInterval(delay)
    }

    mutating func noteAttached(_ pid: pid_t) { forget(pid) }

    mutating func forget(_ pid: pid_t) {
        retryDelay[pid] = nil
        retryNotBefore[pid] = nil
    }

    /// Drops retry state of apps no longer wanted, and lets an app that gave up start over once it is in the census.
    mutating func prune(keeping wanted: Set<pid_t>, census: Set<pid_t>) {
        for pid in retryNotBefore.keys where !wanted.contains(pid) || (census.contains(pid) && retryNotBefore[pid] == .distantFuture) { forget(pid) }
    }
}
