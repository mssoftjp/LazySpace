import AppKit
import CoreGraphics
import Copy
import Foundation
import LayoutCore
import Operations

/// Window identity: window ID, owner pid, and process launch time.
/// Tells pid reuse (another process) and window ID reuse in another process apart. Window ID reuse within one process is
/// told apart by `WindowRouter` through window lifetimes (confirmed disappearance).
struct WindowIdentity: Hashable, Codable {
    var window: WindowID
    var pid: Int32
    /// Lifetime number of this window ID (`WindowRouter` adds 1 each time it confirms a close); tells ID reuse within a process apart.
    var lifetime: Int = 0
    /// Process launch time; nil when unreadable (the window is then compared by pid only).
    var processStart: Date?
}

/// A window whose send was issued with an uncertain result (unconfirmed, another Space, interrupted). Layout writes stop and membership reconciles it.
/// Reconciled when membership is only the destination (-> awaiting arrival), or only the source, unchanged for 3 s with a still frame (-> normal placement).
/// While unreadable or flapping, the exclusion stays (time alone never resumes writes; seeing source membership cannot rule out a late move).
/// Released once the window is confirmed gone (absent from the full window list). Shared by B (default `move-to-space` send) and C (rules).
struct SendHold: Equatable {
    var identity: WindowIdentity
    var source: UInt64
    var target: UInt64
    var targetUUID: String?
    var startedAt: Date
    /// When the window was first seen only on the source Space (cleared on any change).
    var sourceStableSince: Date?
    /// Its frame at that time.
    var sourceFrame: CGRect?

    static let stableInterval: TimeInterval = 3

    enum Decision: Equatable {
        /// Keep excluding (recheck next observation).
        case keep
        /// Membership became only the destination (await arrival).
        case arrived
        /// Confirmed it stayed on the source (back to normal placement).
        case stayed
        /// The window is gone.
        case gone
    }

    /// Rechecks for one observation. `exists` is presence in the full window list (nil = unreadable); `frame` is its frame there.
    mutating func evaluate(membership: [UInt64]?, frame: CGRect?, exists: Bool?, now: Date, tolerance: Double) -> Decision {
        if exists == false { return .gone }
        guard let membership, !membership.isEmpty else { sourceStableSince = nil; sourceFrame = nil; return .keep }
        if membership == [target] { return .arrived }
        guard membership == [source], let frame else { sourceStableSince = nil; sourceFrame = nil; return .keep }
        if let since = sourceStableSince, let seen = sourceFrame, seen.matches(frame, tolerance: tolerance) {
            return now.timeIntervalSince(since) >= Self.stableInterval ? .stayed : .keep
        }
        sourceStableSince = now
        sourceFrame = frame
        return .keep
    }

    /// Reason shown in the window list and for layout exclusion.
    static var reason: String {
        L(.windowRoutingReason)
    }
}


extension Census {
    /// The observation without windows kept out of the layout (reconciling, classifying, or sending windows are hidden from every placement path).
    func excluding(_ ids: Set<WindowID>) -> Census {
        var copy = self
        for id in ids { copy.windows[id] = nil; copy.bounds[id] = nil }
        if let front = copy.frontWindow, ids.contains(front) { copy.frontWindow = nil }
        return copy
    }
}

/// Tracks new windows for `action = "space"` rules. Holds pure state only;
/// Coordinator observes, reads, and sends. Only the operations queue touches it.
///
/// - Seeding: at launch (full window list) and on a Space observed for the first time, windows present then are "seen" (existing windows are never mistaken for new).
/// - New window: an unknown window ID appearing on a seeded Space (or a confirmed-gone ID reappearing, or another process's window).
///   An ID that keeps appearing without confirmed disappearance stays known (size or title changes do not make it new; it is not sent).
/// - Phases: seen -> classifying (up to 1.5 s) -> ready (waiting for an operation slot, up to 3 s) -> sending -> consumed. consumed is never resent.
///   While classifying, ready, or sending, the window is excluded from every placement path. Past the deadline it returns to seen (normal placement). Later title changes never send.
/// - Recreate loop: 3 sends within 10 s for the same app, Space, and rule pause that rule on that Space for 1 minute.
struct WindowRouter {
    enum Phase: Equatable {
        case seen
        case classifying(since: Date, space: UInt64)
        case ready(since: Date, space: UInt64, rule: Int)
        /// Sending. `readySince` is when it became ready (if a gate stopped the send, it returns to ready with the 3 s deadline still counted from this time).
        case sending(space: UInt64, rule: Int, readySince: Date)
        case consumed
    }

    struct Entry: Equatable {
        var identity: WindowIdentity
        var phase: Phase
        /// The last observed Space.
        var space: UInt64?
    }

    static let classifyWindow: TimeInterval = 1.5
    static let readyTimeout: TimeInterval = 3
    static let loopLimit = 3
    static let loopWindow: TimeInterval = 10
    static let loopPause: TimeInterval = 60

    private(set) var entries: [WindowID: Entry] = [:]
    /// Spaces observed (shown). On the first observation, every window there becomes known (never sent, before or after launch).
    private(set) var seededSpaces: Set<UInt64> = []
    /// Whether windows were marked known from the full window list at launch (Spaces are not marked observed).
    private(set) var seededAtLaunch = false
    /// Window IDs confirmed gone (a reappearance is a new window).
    private(set) var destroyed: Set<WindowID> = []
    /// Lifetime number per window ID (incremented on each confirmed close).
    private(set) var lifetimes: [WindowID: Int] = [:]

    func lifetime(of id: WindowID) -> Int { lifetimes[id] ?? 0 }
    private var sends: [String: [Date]] = [:]
    private var pausedRules: [String: Date] = [:]

    /// At launch: every window in the full window list becomes known (a window from another Space moving into an observed Space later is not mistaken for new).
    /// Spaces are not marked observed: a Space not yet seen marks all its windows known when first seen (windows opened after launch are not sent either).
    mutating func seedAtLaunch(_ windows: [(identity: WindowIdentity, spaces: [UInt64])]) {
        for window in windows where entries[window.identity.window] == nil {
            entries[window.identity.window] = Entry(identity: window.identity, phase: .seen, space: window.spaces.count == 1 ? window.spaces[0] : nil)
        }
        seededAtLaunch = true
    }

    /// Observation of the current Space; returns windows that started classifying. `candidate` says whether the app has a `space` rule.
    mutating func observe(_ windows: [WindowIdentity], space: UInt64, now: Date, candidate: (WindowIdentity) -> Bool) -> [WindowID] {
        guard seededSpaces.contains(space) else {
            // A Space shown for the first time: every window there is known (not provably new).
            for identity in windows where entries[identity.window]?.identity != identity {
                entries[identity.window] = Entry(identity: identity, phase: .seen, space: space)
            }
            for identity in windows { entries[identity.window]?.space = space }
            seededSpaces.insert(space)
            return []
        }
        var started: [WindowID] = []
        for identity in windows {
            let id = identity.window
            if let entry = entries[id], Self.sameWindow(entry.identity, identity), !destroyed.contains(id) {
                entries[id]?.space = space
                continue
            }
            // Identity changed while classifying, ready, or sending (another process, different launch time): ambiguous, so not sent (normal placement).
            if let entry = entries[id], !destroyed.contains(id) {
                switch entry.phase {
                case .classifying, .ready, .sending:
                    entries[id] = Entry(identity: identity, phase: .seen, space: space)
                    continue
                case .seen, .consumed: break
                }
            }
            // An unknown ID, a confirmed-gone ID reappearing, or another process's window: a new window.
            destroyed.remove(id)
            if candidate(identity) {
                entries[id] = Entry(identity: identity, phase: .classifying(since: now, space: space), space: space)
                started.append(id)
            } else {
                entries[id] = Entry(identity: identity, phase: .seen, space: space)
            }
        }
        return started
    }

    /// Same window: same ID, lifetime, and pid, and matching launch times where both are known. Launch time tells pid reuse apart; lifetime tells ID reuse within a process apart.
    static func sameWindow(_ a: WindowIdentity, _ b: WindowIdentity) -> Bool {
        guard a.window == b.window, a.pid == b.pid, a.lifetime == b.lifetime else { return false }
        if let x = a.processStart, let y = b.processStart { return abs(x.timeIntervalSince(y)) < 1 }
        return true
    }

    /// Windows confirmed absent from the full window list (closed). Forgets them so the same ID reappearing counts as new.
    mutating func noteDestroyed(_ ids: Set<WindowID>) {
        for id in ids {
            entries[id] = nil
            destroyed.insert(id)
            lifetimes[id, default: 0] += 1
        }
    }

    /// Forgets windows of a process that quit.
    mutating func forgetProcess(_ pid: Int32) {
        entries = entries.filter { $0.value.identity.pid != pid }
    }

    /// Returns classifying and ready windows past their deadline to seen (normal placement) and returns them.
    mutating func expire(now: Date) -> [WindowID] {
        var released: [WindowID] = []
        for (id, entry) in entries {
            switch entry.phase {
            case .classifying(let since, _) where now.timeIntervalSince(since) > Self.classifyWindow,
                 .ready(let since, _, _) where now.timeIntervalSince(since) > Self.readyTimeout:
                entries[id]?.phase = .seen
                released.append(id)
            default: break
            }
        }
        return released
    }

    /// Within the classification deadline (1.5 s after opening); rechecked after slow reads.
    func isClassifying(_ id: WindowID, at now: Date) -> Bool {
        guard case .classifying(let since, _)? = entries[id]?.phase else { return false }
        return now.timeIntervalSince(since) <= Self.classifyWindow
    }

    /// Ready to send (only within the classification deadline).
    mutating func markReady(_ id: WindowID, rule: Int, now: Date) {
        guard isClassifying(id, at: now), case .classifying(_, let space)? = entries[id]?.phase else { return }
        entries[id]?.phase = .ready(since: now, space: space, rule: rule)
    }

    mutating func markSending(_ id: WindowID) {
        guard case .ready(let since, let space, let rule)? = entries[id]?.phase else { return }
        entries[id]?.phase = .sending(space: space, rule: rule, readySince: since)
    }

    /// A gate stopped the send (not issued): back to ready. The deadline still counts from when it first became ready (never extended).
    mutating func retry(_ id: WindowID) {
        guard case .sending(let space, let rule, let since)? = entries[id]?.phase else { return }
        entries[id]?.phase = .ready(since: since, space: space, rule: rule)
    }

    /// Back to normal placement without sending (no rule match, could not classify).
    mutating func release(_ id: WindowID) { if entries[id] != nil { entries[id]?.phase = .seen } }

    /// A send was attempted (whatever the result) or decided against: never send again.
    mutating func consume(_ id: WindowID) { if entries[id] != nil { entries[id]?.phase = .consumed } }

    func phase(of id: WindowID) -> Phase? { entries[id]?.phase }

    /// Classifying windows on this Space.
    func classifying(on space: UInt64) -> [WindowID] {
        entries.compactMap { id, entry in
            if case .classifying(_, let s) = entry.phase, s == space { return id }
            return nil
        }.sorted { $0.raw < $1.raw }
    }

    /// Windows ready to send on this Space, with their rules.
    func ready(on space: UInt64) -> [(window: WindowID, rule: Int)] {
        entries.compactMap { id, entry in
            if case .ready(_, let s, let rule) = entry.phase, s == space { return (id, rule) }
            return nil
        }.sorted { $0.window.raw < $1.window.raw }
    }

    /// Windows kept out of the layout (classifying, ready, sending).
    func exclusions() -> [WindowID: Phase] {
        entries.compactMapValues { entry in
            switch entry.phase {
            case .classifying, .ready, .sending: return entry.phase
            case .seen, .consumed: return nil
            }
        }
    }

    /// Counts one send. At 3 within 10 s, pauses that rule on that Space for 1 minute and returns true.
    mutating func noteSend(app: String, space: UInt64, rule: Int, now: Date) -> Bool {
        let key = "\(app)|\(space)|\(rule)"
        var recent = (sends[key] ?? []).filter { now.timeIntervalSince($0) < Self.loopWindow }
        recent.append(now)
        sends[key] = recent
        guard recent.count >= Self.loopLimit else { return false }
        pausedRules["\(space)|\(rule)"] = now.addingTimeInterval(Self.loopPause)
        sends[key] = []
        return true
    }

    func isPaused(space: UInt64, rule: Int, now: Date) -> Bool {
        guard let until = pausedRules["\(space)|\(rule)"] else { return false }
        return now < until
    }

    /// Known windows not observed on their Space (closed, moved, minimized); disappearance is confirmed against the full window list.
    func missing(on space: UInt64, present: Set<WindowID>) -> Set<WindowID> {
        Set(entries.filter { $0.value.space == space && !present.contains($0.key) }.keys)
    }
}

extension WindowRouter.Phase {
    /// Reason shown in the window list and for layout exclusion.
    var reason: String {
        switch self {
        case .classifying: return L(.windowRoutingJustOpenedCheckingWhetherA)
        case .ready, .sending: return L(.windowRoutingBeingSentToAnotherSpace)
        case .seen, .consumed: return ""
        }
    }
}

/// Number of app activations (`NSWorkspace.didActivateApplicationNotification`). The front-restore gate uses it to see whether another activation happened after acceptance.
/// Counting starts at the first read.
final class ActivationCounter {
    static let shared = ActivationCounter()
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var token: NSObjectProtocol?

    private init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.value &+= 1; self.lock.unlock()
        }
    }

    var count: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}
