import AppKit
import CoreGraphics
import Copy
import Foundation
import Operations

/// Switching Spaces and moving windows to another Space.
///
/// There is no public API to move a window to another Space, and the private `SLSMoveWindowsToManagedSpace` does not work on macOS 27.
/// Moving a window first tries `direct` (change membership with SkyLight's bridged operation, then bring the window forward so the OS switches straight to the target).
/// Switching tries, in order: bringing forward a window on the target, activating an app with windows only there, then one jump to an intermediate Space plus stepping.
/// Without a route, with a target that is not a standard Desktop, or when the request cannot be sent, it steps one Space at a time as before. If membership does not change
/// after a request was sent, it reports `moveUnconfirmed` and never falls back to stepping. The keys are Mission Control's "Move left/right a Space" (symbolic hotkeys 79 / 81),
/// read once at the start of the operation and sent unchanged for every step. Settings are never written. If unreadable, disabled, or unsupported, nothing is sent and there is no fallback to default keys.
/// Stepping grabs the title bar before sending the key and releases after switching. Both paths confirm the result through SkyLight membership and the active Space.
///
/// Synthetic input is this app's command, not user input, so `InputMonitor` excludes it by tag.
/// The tag still reaches registered Carbon hotkeys, so combinations equal to this app's registered command keys are refused before sending.
/// User input (click or key) midway releases the grabbed window and pressed keys and interrupts.
protocol SpaceObserving {
    func activeSpace() -> UInt64?
    func spaces(for windowID: CGWindowID) -> [UInt64]
    func managedDisplays() -> [SpaceObserver.ManagedDisplay]
    /// False for a window kept ordered out (shown nowhere, though still listed on a Space); nil is unknown.
    func isOrderedIn(_ windowID: CGWindowID) -> Bool?
}

extension SpaceObserver: SpaceObserving {}

/// Mission Control's move left/right (symbolic hotkeys 79 / 81), read without sending.
/// Only ctrl / alt / shift / cmd are compared; Fn and the like are not.
public enum SystemSpaceShortcut: Equatable {
    public enum Issue: Equatable {
        case unassigned, invalidKey, modifierOnly, shiftOnly, needsModifier
        case capsLock, unknownFlags, fnOnOtherKey, functionKey, mediaKey, extendedKey
    }

    case unread
    case disabled
    case unusable(Issue)
    case usable(keyCode: UInt16, modifiers: Set<String>)
}

public final class SpaceControl {
    public enum Failure: Error, Equatable {
        case unavailable(String)
        case noSuchSpace
        case alreadyThere
        case interrupted
        case timedOut(String)
        case notMoved
        /// Right after reaching the target, the OS moved to another Space (an app with windows there brought another Space forward, for example).
        case drifted(to: UInt64)
        /// The window moved but landed on a Space other than the target (the OS moved Spaces mid-move, for example).
        case movedElsewhere(to: UInt64)
        /// The direct path changed the window's membership to the target, but the switch to that Space was not confirmed. The window is on the target.
        case notSwitched
        /// The direct-path request was sent, but membership did not change in time. No fallback to stepping, so a late move and a drag cannot collide.
        case moveUnconfirmed
        /// After the direct-path request, the window read as belonging to several Spaces (possibly including the target). Where it landed is unknown.
        case onSeveralSpaces([UInt64])
        /// After the direct-path request, membership was unreadable (the window may have closed).
        case membershipUnreadable
        /// The window is on the target, but the current Space was unreadable.
        case activeSpaceUnreadable
        /// A switch-only direct path brought a window (or app) on the target forward, but no switch happened. An issued activation may take effect late, so no fallback to stepping.
        case switchUnconfirmed
        /// After one jump to an intermediate Space, the display order changed so the remaining steps cannot follow the plan. The remaining keys were not sent.
        case routeChanged
        /// The us -> target-app activation switched Spaces, but the app was not confirmed in front (timeout, or given up on recheck).
        /// LazySpace may be left in front. Stop there without starting another path or stepping.
        case activationUnconfirmed
        /// macOS "Switch to Desktop N" was sent, but neither a switch nor pass-through (the key reaching LazySpace) was confirmed in time.
        /// The Dock may just be behind, so no other path starts.
        case hotkeyUnconfirmed
        /// "Move left/right a Space" for stepping is unusable (suppressed, no pass-through tap), or was sent but macOS did not respond.
        /// Without a response, it stops on the spot instead of starting another path from an intermediate Space.
        case steppingUnavailable(SteppingIssue)
        /// The window moved to the target and the Space switched, but the carried window's app was not confirmed in front (activation refused or timed out).
        case frontUnconfirmed
        /// The target is on another display and no window or app there could be brought forward (the other routes act on the current display).
        case otherDisplayNoRoute
        /// Moving to another display's Space needs the direct move (the drag steps through the Spaces of one display).
        case otherDisplayNeedsDirectMove
    }

    /// Why stepping is unusable (shortcut off, unassigned, unsendable, or conflicting still returns `unavailable` with the setting name, as before).
    public enum SteppingIssue: Equatable {
        /// Not used because macOS did not respond before, with this Dock and this setting.
        case suppressed(right: Bool)
        /// The pass-through tap could not be prepared.
        case noTap
        /// Sent, but macOS did not take it as a hotkey (the tap swallowed the main keyDown).
        case notHonored(right: Bool)
        /// The shortcut setting or a conflict changed after the preflight (including after moving to an intermediate Space, after sending steps, and while dragging).
        /// The text adds the setting name and reason and says "the rest of the moves were not sent" (with the place note).
        case configuration(String)
    }

    // MARK: - Hotkey parts

    /// Kind of hotkey to send: left/right are symbolic hotkeys 79 / 81, Desktop N is 118 + N - 1.
    public enum HotkeyKind: Equatable {
        case arrowLeft, arrowRight, desktop(Int)
        public var id: Int32 {
            switch self {
            case .arrowLeft: return 79
            case .arrowRight: return 81
            case .desktop(let n): return Int32(117 + n)
            }
        }
    }

    /// One post. `source` is the Space that must be visible right before sending, `expected` the Space to reach.
    public struct HotkeyStep: Equatable {
        public var kind: HotkeyKind
        public var source: UInt64
        public var expected: UInt64
        public init(kind: HotkeyKind, source: UInt64, expected: UInt64) { self.kind = kind; self.source = source; self.expected = expected }
    }

    /// Why nothing was sent (moving on to another path is fine).
    public enum HotkeyNotIssued: Error, Equatable {
        case unread, disabled, unusable, conflict, suppressed, noTap
        /// The kind's eligibility failed (Desktop conditions, left/right adjacency, a changed settings fingerprint, and so on).
        case ineligible(String)
    }

    /// Why the operation stops (sent or not, no other path starts).
    public enum HotkeyStopped: Equatable {
        /// Input, authorization, the source Space, or the tap failed.
        case interrupted
        case unexpectedSpace(UInt64)
        /// Neither arrival nor pass-through was confirmed in time.
        case unconfirmed
        /// The system disabled the tap after sending, so pass-through cannot serve as evidence.
        case compromised
        case activeUnreadable
    }

    public enum HotkeyOutcome: Equatable {
        case arrived(ms: Double)
        /// The tap swallowed the main keyDown (nothing happened). `recorded` says whether a suppression record was added.
        case passedThrough(recorded: Bool)
        case notIssued(HotkeyNotIssued)
        case stopped(HotkeyStopped)
    }

    /// The read setting of "Move left/right a Space"; also the key (with the Dock pid) for suppression and confirmation records.
    public struct ArrowHotkey: Hashable {
        public var right: Bool
        public var keyCode: UInt32
        public var flags: UInt32
        public var id: Int32 { right ? 81 : 79 }
        public init(right: Bool, keyCode: UInt32, flags: UInt32) { self.right = right; self.keyCode = keyCode; self.flags = flags }
    }

    /// Result of reading "Move left/right a Space". Settings are never written.
    public enum ArrowShortcutRead: Equatable {
        case unread
        case off
        case unusable(SystemSpaceShortcut.Issue)
        case conflict(ArrowHotkey)
        case usable(ArrowHotkey)
    }

    /// Left/right key suppression and records (held by Coordinator), recorded separately for left and right.
    public struct ArrowPolicy {
        /// Whether a pass-through in a switching context is already recorded for this Dock and setting.
        public var isSuppressed: (ArrowHotkey) -> Bool
        /// Conditions outside SpaceControl (the same Dock). Called right before sending and before recording a pass-through.
        public var stillEligible: () -> Bool
        /// Arrived (`arrived`), or confirmed pass-through in a switching context (`passedThrough`; not called while dragging).
        public var report: (ArrowHotkey, HotkeyEvent) -> Void

        public init(isSuppressed: @escaping (ArrowHotkey) -> Bool = { _ in false }, stillEligible: @escaping () -> Bool = { true },
                    report: @escaping (ArrowHotkey, HotkeyEvent) -> Void = { _, _ in }) {
            self.isSuppressed = isSuppressed; self.stillEligible = stillEligible; self.report = report
        }
    }

    /// Result of `raise`. `unknown` means the request may have reached the app (AX timeout and the like), so it counts as issued like `issued`.
    public enum RaiseOutcome: Equatable { case issued, refused, unknown }

    /// Result of activating an app. `notIssued`: neither our activation nor the target's was issued (moving to the next candidate is fine).
    /// `issued` once either was issued; `unknown` when it is not known (no report from the main thread in time).
    /// `activateApp` returns what is known when called: `notIssued` if nothing was queued, `unknown` if queued on the main thread (`ActivationStage` tells the rest).
    public enum ActivationOutcome: Equatable { case notIssued, issued, unknown }

    /// Progress of the us -> target-app activation hand-off, reported from the main thread.
    /// `declined`: nothing issued (recheck or gate false). `began`: we came forward.
    /// `requested(pid)`: the target app's activation was requested (whether it came forward is observed separately). `abandoned`: after we came forward, the target's activation was given up (gate false or recheck).
    public enum ActivationStage: Equatable { case declined, began, requested(pid_t), abandoned }

    /// The read setting of macOS "Switch to Desktop N" (symbolic hotkeys 118-133); also the key (with the Dock pid) for suppression and confirmation records.
    public struct DesktopHotkey: Hashable {
        public var desktop: Int
        public var id: Int32
        public var enabled: Bool
        public var keyCode: UInt32
        public var flags: UInt32

        public init(desktop: Int, id: Int32, enabled: Bool = true, keyCode: UInt32, flags: UInt32) {
            self.desktop = desktop; self.id = id; self.enabled = enabled; self.keyCode = keyCode; self.flags = flags
        }
    }

    /// Result of reading "Switch to Desktop N". Settings are never written.
    public enum DesktopShortcutRead: Equatable {
        case unread
        case off
        /// An assignment that cannot be sent (fails `classify`).
        case unusable
        /// Overlaps a registered LazySpace shortcut (synthetic tags do not stop Carbon registrations, so it is not sent).
        case conflict(DesktopHotkey)
        case usable(DesktopHotkey)
    }

    /// Material for tier 0 (Desktop N shortcuts). Coordinator checks the conditions and passes it.
    public struct HotkeyPlan {
        public var shortcut: DesktopHotkey
        public var dockPID: pid_t
        /// Conditions and fingerprint outside SpaceControl (one physical display, rearranging off, the same Dock, no suppression record). Called first, right before each keyDown, and before recording a pass-through.
        public var stillEligible: () -> Bool
        /// Confirmed arrival (`arrived`), or confirmed pass-through and continued with existing paths (`passedThrough`). Called from the operations queue.
        public var report: (HotkeyEvent) -> Void

        public init(shortcut: DesktopHotkey, dockPID: pid_t, stillEligible: @escaping () -> Bool = { true }, report: @escaping (HotkeyEvent) -> Void = { _ in }) {
            self.shortcut = shortcut; self.dockPID = dockPID; self.stillEligible = stillEligible; self.report = report
        }
    }

    public enum HotkeyEvent: Equatable { case arrived, passedThrough }

    /// Result of trying tier 0 alone (for lzprobe).
    public enum DesktopShortcutAttempt: Equatable {
        case switched(Result)
        /// Conditions unmet, nothing issued, or not recorded because the setting changed after pass-through.
        case notUsed
        /// Confirmed and recorded pass-through (the front app did not change).
        case passedThrough
        case failed(Failure)
    }

    /// A direct-switch candidate. Windows are raised through retained AX elements; apps are activated. Identity is both pid and bundle ID.
    public enum Candidate: Equatable {
        case window(CGWindowID)
        case app(pid_t, bundleID: String)
    }

    public struct Result: Equatable {
        public var fromSpace: UInt64
        public var toSpace: UInt64
        /// Number of left/right key steps sent; 0 when moved by the direct path (membership change -> activation).
        public var steps: Int
        public var wallMs: Double
        /// The follow was confirmed, then input, Pause, cancellation, or a lost permission or input observation ended the watch after it:
        /// the window moved and has focus, but the caller does nothing more.
        public var stoppedWhileWatching: Bool

        public init(fromSpace: UInt64, toSpace: UInt64, steps: Int, wallMs: Double, stoppedWhileWatching: Bool = false) {
            self.fromSpace = fromSpace; self.toSpace = toSpace; self.steps = steps; self.wallMs = wallMs
            self.stoppedWhileWatching = stoppedWhileWatching
        }
    }

    /// Identifier of synthetic events (`CGEventField.eventSourceUserData`).
    public static let syntheticTag: Int64 = 0x4C5A_5350_0001 // "LZSP" 1
    /// Whether this is a synthetic event of this app (including lzprobe). Two forms are accepted:
    /// the older tag for stepping and the like (bits 16-63 equal to `syntheticTag`, any low 16 bits), and
    /// the Desktop N shortcut attempt tag (bits 48-63 equal to `PassThroughFilter.marker`; `PassThroughFilter.tag(attempt:)`).
    public static func isSynthetic(_ userData: Int64) -> Bool {
        userData >> 16 == syntheticTag >> 16 || (userData >> 48) & 0xFFFF == PassThroughFilter.marker
    }

    /// Paths that move a window to the target Space in one go and switch Spaces in one go, without synthetic input.
    /// Membership changes are asynchronous with no return value, so `move` returning true means "sent"; membership is reread through `SpaceObserving`. With `move` nil, windows move only by stepping.
    /// Switching relies on macOS switching straight to a Space when a window there is raised (`raise`) or an app with windows only there is activated (`activateApp`).
    /// When the window's app is already in front and `raise` has no effect, `reactivate` (briefly bring us forward, then the window's app) fills in.
    /// `raise`'s activation and `reactivate` / `activateApp` run later on the main thread, so gates are checked before each stage, and nothing happens once the operation has ended.
    /// After queuing its activation, `raise` reports on the main thread `requested(pid)` if it requested one and `abandoned` if not (waited on when jumping to an intermediate Space).
    /// `reactivate` / `activateApp` have two gates: `mayBegin` (may we come forward; while still on the source Space) and
    /// `mayFinish` (may the target app come forward again; once begun, always restored even if the target was reached midway). Progress is reported through `report` from the main thread.
    /// `activateApp(pid, bundleID, target, …)` rechecks when called whether the app still has windows only on `target`, and returns `notIssued` without queuing if not.
    /// After queuing, the same check runs again on the main thread right before we come forward and right before the target comes forward (`handOff`).
    public struct DirectPath {
        public var move: ((CGWindowID, UInt64) -> Bool)?
        public var raise: (CGWindowID, _ isCurrent: @escaping () -> Bool, _ report: @escaping (ActivationStage) -> Void) -> RaiseOutcome
        public var reactivate: (CGWindowID, _ mayBegin: @escaping () -> Bool, _ mayFinish: @escaping () -> Bool, _ report: @escaping (ActivationStage) -> Void) -> Void
        public var activateApp: ((pid_t, _ bundleID: String, _ target: UInt64, _ mayBegin: @escaping () -> Bool, _ mayFinish: @escaping () -> Bool,
                                  _ report: @escaping (ActivationStage) -> Void) -> ActivationOutcome)?
        /// The front app's focused window. Completing a move observes the carried window itself.
        public var focusedWindow: () -> CGWindowID?

        public init(move: ((CGWindowID, UInt64) -> Bool)?, raise: @escaping (CGWindowID, _ isCurrent: @escaping () -> Bool, _ report: @escaping (ActivationStage) -> Void) -> RaiseOutcome,
                    reactivate: @escaping (CGWindowID, _ mayBegin: @escaping () -> Bool, _ mayFinish: @escaping () -> Bool, _ report: @escaping (ActivationStage) -> Void) -> Void,
                    activateApp: ((pid_t, _ bundleID: String, _ target: UInt64, _ mayBegin: @escaping () -> Bool, _ mayFinish: @escaping () -> Bool,
                                   _ report: @escaping (ActivationStage) -> Void) -> ActivationOutcome)? = nil,
                    focusedWindow: @escaping () -> CGWindowID? = { nil }) {
            self.move = move; self.raise = raise; self.reactivate = reactivate; self.activateApp = activateApp
            self.focusedWindow = focusedWindow
        }
    }

    /// The wait after observing arrival (per route). Success means "observed reaching the target Space"; it does not promise the switch animation finished.
    /// Whatever the wait, the final authorization, input, and arrival checks run after it (sent keys, modifiers included, are already released).
    /// Shortcut routes (Desktop N, the last step of left/right stepping, follow with Desktop N) do not wait; back-to-back commands with no gap must still end on the right Space
    /// without false arrivals or false suppression records.
    /// Space switches by activation, app, or hop watch for 0.3 s. Follow after moving a window confirms activation and the target window's focus, so it adds no wait;
    /// it then watches the front app until `followWatch` after arrival.
    /// Waits can be restored per route (`fixedWaits` holds the old values; lzprobe `--settle fixed`). Drag step intervals and post-release checks are kept separately.
    public struct Settle: Equatable {
        /// After reaching the target by tier 0 (Desktop N).
        public var desktopHotkey: TimeInterval = 0
        /// After the last left/right step (no wait between steps).
        public var arrowFinal: TimeInterval = 0
        /// After following with Desktop N (before the membership / active checks and the raise).
        public var hotkeyFollow: TimeInterval = 0
        /// After reaching the target by raising a window or activating an app.
        public var directArrival: TimeInterval = 0.3
        /// From reaching the intermediate Space to starting the steps.
        public var hop: TimeInterval = 0.3
        /// After following by raise / reactivate. The target window's focus is already confirmed, so no extra wait by default.
        public var raiseFollow: TimeInterval = 0
        /// How long after arrival a confirmed follow by raise / reactivate keeps watching the front app, so another app that came forward
        /// as the switch completed (seen late through the main thread's copy) is handed back. Input ends it at once.
        public var followWatch: TimeInterval = 0.2
        public init() {}

        /// Same as the default (shortcuts return on arrival; window follow returns once the target window's focus is observed and the short watch ends).
        public static var observedArrival: Settle { Settle() }

        /// The fixed waits from before step 1 (Desktop N 0.3 s, last left/right step 0.4 s, Desktop N follow 0.3 s), for comparison and restoring.
        /// No watch: its time from arrival has passed by the end of the fixed wait.
        public static var fixedWaits: Settle {
            var settle = Settle()
            settle.desktopHotkey = 0.3; settle.arrowFinal = 0.4; settle.hotkeyFollow = 0.3; settle.raiseFollow = 0.3; settle.followWatch = 0
            return settle
        }
    }

    public var settle = Settle()

    /// Timeline of the running operation (held only during `switchTo` / `moveWindow` / the tier-0 entry). Touched only from the operations queue.
    private var timeline: OperationTimeline?
    /// Stepping step (from 1); the timeline's `step`.
    private var currentStep: Int?
    /// Calls to `sendHotkey` in this operation; the timeline's `attempt`.
    private var hotkeySends = 0

    /// No wait for 0.
    private func settleFor(_ interval: TimeInterval) { if interval > 0 { sleep(interval) } }

    private func beginTrace(_ timeline: OperationTimeline?) { self.timeline = timeline; currentStep = nil; hotkeySends = 0 }
    private func endTrace() { timeline = nil; currentStep = nil }
    private func trace(_ event: String, attempt: Int? = nil) { timeline?.mark(event, step: currentStep, attempt: attempt) }

    /// nil uses stepping only.
    public var direct: DirectPath?
    /// The pass-through tap (an active annotated-session tap), used for every hotkey post (Desktop N and left/right) and working without `direct`.
    /// Created on first use and kept for good. nil means no tap, and no hotkeys are sent (`noTap`).
    public let passThroughTap: PassThroughTap?

    /// Always returns the switching paths (raise / activate). Only moving windows (`move`) depends on SkyLight's bridged operation and is nil without it.
    /// `raise` brings a window forward through its retained AX element (held by Coordinator).
    public static func systemDirectPath(raise: @escaping (CGWindowID, _ isCurrent: @escaping () -> Bool, _ report: @escaping (ActivationStage) -> Void) -> RaiseOutcome,
                                        focusedWindow: @escaping () -> CGWindowID? = { nil }) -> DirectPath {
        let move = PrivateSymbols.bridgedSpaceMove.map { bridged in { (wid: CGWindowID, space: UInt64) in bridged.move([wid], to: space) } }
        return DirectPath(move: move, raise: raise, reactivate: { wid, mayBegin, mayFinish, report in
            guard let pid = WindowList.all()[wid]?.pid, let app = NSRunningApplication(processIdentifier: pid) else { report(.declined); return }
            systemHandOff(to: app, pid: pid, eligible: { !app.isTerminated }, stillOwner: { WindowList.all()[wid]?.pid == pid },
                          mayBegin: mayBegin, mayFinish: mayFinish, report: report)
        }, activateApp: { pid, bundleID, target, mayBegin, mayFinish, report in
            // Identity is checked by both pid and bundle ID, and from then on only the retained NSRunningApplication is used (pid reuse never activates another process).
            // Windows open, close, and move, and apps hide, so eligibility is rechecked against the current raw list rather than the candidate table, and again before each stage.
            guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID else { return .notIssued }
            func eligibleNow() -> Bool {
                !app.isTerminated && !app.isHidden && AppWindowInventory.take()?.isEligible(pid: pid, bundleID: bundleID, on: target) == true
            }
            guard eligibleNow() else { return .notIssued }
            systemHandOff(to: app, pid: pid, eligible: eligibleNow, stillOwner: eligibleNow, mayBegin: mayBegin, mayFinish: mayFinish, report: report)
            return .unknown
        }, focusedWindow: focusedWindow)
    }

    /// `pid` is the window owner's pid. For apps missing from LaunchServices, `app.processIdentifier` is -1, so it is not used.
    private static func systemHandOff(to app: NSRunningApplication, pid: pid_t, eligible: @escaping () -> Bool, stillOwner: @escaping () -> Bool,
                                      mayBegin: @escaping () -> Bool,
                                      mayFinish: @escaping () -> Bool, report: @escaping (ActivationStage) -> Void) {
        handOff(pid: pid, eligible: eligible, mayBegin: mayBegin, mayFinish: mayFinish,
                activateSelf: { NSApp.activate(ignoringOtherApps: true) }, activateTarget: { AppActivation.activate(app, pid: pid, allowed: mayFinish, stillOwner: stillOwner) }, report: report,
                onMain: { DispatchQueue.main.async(execute: $0) }, after: { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) })
    }

    /// Briefly brings us forward, then the target app (this switches Spaces even if the target is already in front). Both on the main thread, each after checking eligibility and the gate.
    /// Declining before we come forward reports `declined` (nothing issued). After we came forward, a false gate or changed eligibility skips the target and reports `abandoned`.
    /// `requested` means only requested; the caller observes whether it came forward. Scheduling is replaceable (tests run it synchronously).
    static func handOff(pid: pid_t, eligible: @escaping () -> Bool, mayBegin: @escaping () -> Bool, mayFinish: @escaping () -> Bool,
                        activateSelf: @escaping () -> Void, activateTarget: @escaping () -> Void, report: @escaping (ActivationStage) -> Void,
                        onMain: (@escaping () -> Void) -> Void, after: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        onMain {
            guard eligible(), mayBegin() else { report(.declined); return }
            activateSelf()
            report(.began)
            after(0.1) {
                // Once we came forward, restore whenever possible; give up only on interruption, end, an unexpected Space, or ineligibility.
                // The eligibility check reads the full window list and takes time, so the gate is checked again after it, right before activating, to catch input, interruption, or Space changes.
                guard mayFinish(), eligible(), mayFinish() else { report(.abandoned); return }
                activateTarget()
                report(.requested(pid))
            }
        }
    }

    /// Place read after release. active nil or an empty window array means that item was not read.
    struct PlaceNote: Equatable {
        var active: UInt64?
        /// nil for a switch (no window watched). Empty means read but membership undecided.
        var window: [UInt64]?
    }

    private(set) var placeNote: PlaceNote?

    private let spaces: SpaceObserving
    private let inputCount: () -> UInt64
    private let inputAvailable: () -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void
    private let cursorPosition: () -> CGPoint
    private let warpCursor: (CGPoint) -> Void
    private let postEvent: (CGEvent) -> Void
    private let hotkey: (Int32) -> PrivateSymbols.SymbolicHotKey
    private let commandConflicts: (UInt16, CGEventFlags) -> Bool
    /// The front app's pid, observed to see whether the us -> target-app hand-off worked.
    private let frontmostPID: () -> pid_t?
    /// LazySpace's own pid: in front during a hand-off, never a reason to hand focus back.
    private let ownPID: pid_t
    private let source: CGEventSource?

    public convenience init?(input: InputMonitor) {
        guard let spaces = SpaceObserver() else { return nil }
        // Start reading the copy of the front app on the creating (main) thread; notifications update it, and the operations queue reads it under a lock.
        _ = FrontmostApplication.shared
        self.init(spaces: spaces, inputCount: { input.count }, inputAvailable: { input.mode == .mouseAndKeyboard },
                  hotkey: { PrivateSymbols.symbolicHotKey($0) },
                  commandConflicts: { code, flags in input.matchesCommand(keyCode: Int64(code), flags: flags) },
                  passThroughTap: SystemPassThroughTap())
    }

    /// Tests replace observation, clock, event posting, and hotkey reads, and issue no real input.
    init(spaces: SpaceObserving, inputCount: @escaping () -> UInt64,
         inputAvailable: @escaping () -> Bool = { true },
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         cursorPosition: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         warpCursor: @escaping (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) },
         postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         hotkey: @escaping (Int32) -> PrivateSymbols.SymbolicHotKey,
         commandConflicts: @escaping (UInt16, CGEventFlags) -> Bool = { _, _ in false },
         frontmostPID: @escaping () -> pid_t? = { FrontmostApplication.shared.pid },
         ownPID: pid_t = getpid(),
         passThroughTap: PassThroughTap? = nil) {
        self.spaces = spaces
        self.inputCount = inputCount
        self.inputAvailable = inputAvailable
        self.now = now
        self.sleep = sleep
        self.cursorPosition = cursorPosition
        self.warpCursor = warpCursor
        self.postEvent = postEvent
        self.hotkey = hotkey
        self.commandConflicts = commandConflicts
        self.frontmostPID = frontmostPID
        self.ownPID = ownPID
        self.passThroughTap = passThroughTap
        source = CGEventSource(stateID: .privateState)
    }

    // MARK: - Order

    /// Spaces of the display containing the current Space, in Mission Control order.
    public func orderedSpaces() -> [(id: UInt64, type: Int32?)] {
        guard let active = spaces.activeSpace() else { return [] }
        let displays = spaces.managedDisplays()
        guard let display = displays.first(where: { $0.spaces.contains(active) }) else { return [] }
        return display.records.map { (id: $0.id, type: $0.type) }
    }

    /// uuids of the current display's Spaces (excluding missing ones and ones duplicated across displays).
    /// nil when the Space list is unreadable.
    public func currentDisplayUUIDs() -> [UInt64: String]? {
        guard let active = spaces.activeSpace() else { return nil }
        let displays = spaces.managedDisplays()
        guard let display = displays.first(where: { $0.spaces.contains(active) }) else { return nil }
        let unique = SpaceObserver.uniqueUUIDs(displays)
        return unique.filter { display.spaces.contains($0.key) }
    }

    /// The current display's Spaces and every display, from one read; nil when unreadable. `uuids` covers every display.
    public func displaySnapshot() -> (order: [(id: UInt64, type: Int32?)], uuids: [UInt64: String], display: String, active: UInt64, displays: [SpaceObserver.ManagedDisplay])? {
        guard let active = spaces.activeSpace() else { return nil }
        let displays = spaces.managedDisplays()
        guard let display = displays.first(where: { $0.spaces.contains(active) }) else { return nil }
        return (display.records.map { (id: $0.id, type: $0.type) }, SpaceObserver.uniqueUUIDs(displays), display.display, active, displays)
    }

    /// The Space's record on any display; nil when no display lists it.
    private func record(of id: UInt64) -> SpaceObserver.Space? {
        spaces.managedDisplays().lazy.flatMap(\.records).first { $0.id == id }
    }

    /// Identifier of the display with the current Space; nil when unreadable.
    public func currentDisplayIdentifier() -> String? {
        guard let active = spaces.activeSpace() else { return nil }
        return spaces.managedDisplays().first(where: { $0.spaces.contains(active) })?.display
    }

    /// 1-based number (same order as `list-spaces`) -> Space ID.
    public func spaceID(atIndex index: Int) -> UInt64? {
        SpaceObserver.desktopNumbers(orderedSpaces()).first { $0.value == index }?.key
    }

    public func neighbor(offset: Int) -> UInt64? {
        let order = orderedSpaces()
        guard let active = spaces.activeSpace(), let i = order.firstIndex(where: { $0.id == active }) else { return nil }
        let j = i + offset
        guard j >= 0, j < order.count else { return nil }
        return order[j].id
    }

    // MARK: - Switching

    /// Switches Spaces. `candidates` are windows on the target Space, in priority order. With `direct`, bringing one forward
    /// makes the OS switch straight to the target (without passing intermediate Spaces). Without candidates, or if no activation could be issued,
    /// it reads the shortcut for the needed direction once and sends the same key per step to let the OS switch.
    /// If an activation was issued but no switch happened, `switchUnconfirmed` (no fallback to stepping).
    public func switchTo(spaceID target: UInt64, candidates: [CGWindowID] = [], shouldContinue: @escaping () -> Bool = { true }) -> Swift.Result<Result, Failure> {
        switchTo(spaceID: target, plan: SwitchPlan(windows: [target: candidates.map { .window($0) }], hopAllowed: false), shouldContinue: shouldContinue)
    }

    /// Material for one switch.
    public struct SwitchPlan {
        /// The source Space the caller authorized. Compared with the visible Space before the first action; a mismatch interrupts (the Space changed without input during candidate collection, for example).
        public var source: UInt64?
        /// Window candidates per Space (priority order), for the target and intermediate Spaces.
        public var windows: [UInt64: [Candidate]]
        /// App candidates per Space (priority order). Called once, only when no window on the target could be issued (it reads the raw window list, so it is lazy).
        public var apps: () -> [UInt64: [Candidate]]
        /// Whether one jump to an intermediate Space plus stepping is allowed (false with rearranging on).
        public var hopAllowed: Bool
        /// Tier 0 (macOS Desktop N shortcuts); nil when the conditions are unmet.
        public var hotkey: HotkeyPlan?
        /// Suppression and records for stepping's left/right keys; nil ignores suppression and records nothing.
        public var arrows: ArrowPolicy?
        /// The operation's timeline. SpaceControl adds `mainKeyPosted`, `arrivalObserved`, and `activationConfirmed`.
        public var timeline: OperationTimeline?

        public init(source: UInt64? = nil, windows: [UInt64: [Candidate]], apps: @escaping () -> [UInt64: [Candidate]] = { [:] }, hopAllowed: Bool,
                    hotkey: HotkeyPlan? = nil, arrows: ArrowPolicy? = nil, timeline: OperationTimeline? = nil) {
            self.source = source; self.windows = windows; self.apps = apps; self.hopAllowed = hopAllowed; self.hotkey = hotkey; self.arrows = arrows
            self.timeline = timeline
        }
    }

    /// Switches Spaces.
    /// 1. Bring a window on the target forward to switch in one go. If none can be issued, collect app candidates and activate one to switch in one go.
    /// 2. If nothing could be issued and `hopAllowed`, jump with a candidate to the intermediate Space nearest the target, then step to the target.
    ///    The stepping shortcut is validated before jumping. One input and interruption baseline covers the whole trip.
    /// 3. Otherwise, step from the source.
    /// If something was issued but no switch happened, `switchUnconfirmed` (no keys are sent afterward).
    public func switchTo(spaceID target: UInt64, plan: SwitchPlan, shouldContinue: @escaping () -> Bool = { true }) -> Swift.Result<Result, Failure> {
        placeNote = nil
        beginTrace(plan.timeline)
        defer { endTrace() }
        let outcome = switchToBody(spaceID: target, plan: plan, shouldContinue: shouldContinue)
        notePlace(outcome, window: nil)
        return outcome
    }

    private func switchToBody(spaceID target: UInt64, plan: SwitchPlan, shouldContinue: @escaping () -> Bool) -> Swift.Result<Result, Failure> {
        let t0 = now()
        guard let active = spaces.activeSpace() else { return .failure(.unavailable(L(.spaceControlCouldNotDetermineTheCurrent))) }
        // Do not start from a Space other than the authorized source.
        if let source = plan.source, active != source { return .failure(.interrupted) }
        if active == target { return .failure(.alreadyThere) }
        // nil steps: the target is on another display, reachable only by bringing a window or app there forward.
        let steps = stepPlan(from: active, to: target)
        guard steps != nil || record(of: target) != nil else { return .failure(.noSuchSpace) }
        let baseline = inputCount()
        guard inputAvailable() else { return .failure(.unavailable(L(.spaceControlMouseAndKeyboardInputObservation))) }
        // This one baseline decides interruption across candidate search, activation, settle waits, and stepping.
        let canContinue = { self.inputAvailable() && shouldContinue() && self.inputCount() == baseline }
        let gates = Gates(canContinue: canContinue)

        // Tier 0 is tried once, before window and app candidates. If not sent or passed through, move on to the next tier.
        if let hotkey = plan.hotkey {
            switch desktopShortcutTier(to: target, from: active, plan: hotkey, startedAt: t0, gates: gates) {
            case .switched(let result): return .success(result)
            case .failed(let failure): return .failure(failure)
            case .notUsed, .passedThrough: break
            }
        }

        switch directSwitch(to: target, from: active, candidates: plan.windows[target] ?? [], startedAt: t0, canContinue: canContinue) {
        case .done(let result): return .success(result)
        case .failed(let failure): return .failure(failure)
        case .fallback: break
        }
        // No window was usable, so collect app candidates only now. If input or a Space change happens meanwhile, do nothing.
        let apps = direct?.activateApp == nil ? [:] : plan.apps()
        guard canContinue(), spaces.activeSpace() == active else { return .failure(.interrupted) }
        switch directSwitch(to: target, from: active, candidates: apps[target] ?? [], startedAt: t0, canContinue: canContinue) {
        case .done(let result): return .success(result)
        case .failed(let failure): return .failure(failure)
        case .fallback: break
        }

        guard let steps else { return .failure(.otherDisplayNoRoute) }
        guard let direction = steps.first?.right else { return .failure(.alreadyThere) }
        // Before jumping to an intermediate Space or sending the first step, preflight the keys for the remaining steps (read, conflicts, suppression, tap). On failure, no jump.
        let fingerprint: ArrowHotkey
        switch prepareArrow(right: direction, policy: plan.arrows, source: active, gates: gates) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): fingerprint = value
        }
        if plan.hopAllowed {
            let candidates = plan.windows.merging(apps) { windows, apps in windows + apps }
            switch hopSwitch(to: target, from: active, fingerprint: fingerprint, policy: plan.arrows, candidates: candidates, startedAt: t0, gates: gates) {
            case .done(let result): return .success(result)
            case .failed(let failure): return .failure(failure)
            case .fallback: break
            }
        }
        return stepAndConfirm(from: active, origin: active, to: target, fingerprint: fingerprint, policy: plan.arrows, startedAt: t0, gates: gates)
    }

    // MARK: - Tier 0 (macOS "Switch to Desktop N")

    /// Tries tier 0 alone (for lzprobe). The interruption baseline is built as in `switchTo`.
    public func switchViaDesktopShortcut(spaceID target: UInt64, plan: HotkeyPlan, source: UInt64? = nil, timeline: OperationTimeline? = nil,
                                         shouldContinue: @escaping () -> Bool = { true }) -> DesktopShortcutAttempt {
        placeNote = nil
        beginTrace(timeline)
        defer { endTrace() }
        let t0 = now()
        guard let active = spaces.activeSpace(), active != target, source == nil || source == active else { return .notUsed }
        let baseline = inputCount()
        guard inputAvailable() else { return .notUsed }
        let canContinue = { self.inputAvailable() && shouldContinue() && self.inputCount() == baseline }
        let attempt = desktopShortcutTier(to: target, from: active, plan: plan, startedAt: t0, gates: Gates(canContinue: canContinue))
        if case .failed(let failure) = attempt { notePlace(.failure(failure), window: nil) }
        return attempt
    }

    /// Desktop number = count of standard Desktops (type 0) up to the target (1-based). Returned only with one managed display holding both the current Space and the target,
    /// every type in the order readable, a standard Desktop target, and a number of 1-16. Unknown types are never counted as full screen.
    public static func desktopNumber(of target: UInt64, active: UInt64?, displays: [SpaceObserver.ManagedDisplay]) -> Int? {
        guard displays.count == 1, let d = displays.first, d.spaceTypes.count == d.spaces.count,
              let active, d.spaces.contains(active), let i = d.spaces.firstIndex(of: target), d.spaceTypes[i] == 0 else { return nil }
        let number = d.spaceTypes[...i].filter { $0 == 0 }.count
        return (1...16).contains(number) ? number : nil
    }

    public func desktopNumber(of target: UInt64) -> Int? {
        Self.desktopNumber(of: target, active: spaces.activeSpace(), displays: spaces.managedDisplays())
    }

    /// Number of standard Desktops on this display (same conditions as `desktopNumber`, for status); nil when unmet.
    public func ordinaryDesktopCount() -> Int? {
        let displays = spaces.managedDisplays()
        guard displays.count == 1, let d = displays.first, d.spaceTypes.count == d.spaces.count,
              let active = spaces.activeSpace(), d.spaces.contains(active) else { return nil }
        return d.spaceTypes.filter { $0 == 0 }.count
    }

    /// Reads "Switch to Desktop N" (118 + N - 1) and checks `classify` and overlap with registered LazySpace shortcuts. Settings are never written.
    public func desktopShortcut(_ desktop: Int) -> DesktopShortcutRead {
        guard (1...16).contains(desktop) else { return .unusable }
        let id = Int32(117 + desktop)
        switch hotkey(id) {
        case .unknown: return .unread
        case .disabled: return .off
        case .enabled(let keyCode, let flags):
            guard case .ready(let prepared) = classify(keyCode: keyCode, flags: flags) else { return .unusable }
            let config = DesktopHotkey(desktop: desktop, id: id, keyCode: keyCode, flags: flags)
            return commandConflicts(prepared.key, prepared.flags) ? .conflict(config) : .usable(config)
        }
    }

    /// Reads "Move left/right a Space" (79 / 81) and checks `classify` and overlap with registered LazySpace shortcuts. Settings are never written.
    public func arrowShortcut(right: Bool) -> ArrowShortcutRead { readArrow(right: right).read }

    private func readArrow(right: Bool) -> (read: ArrowShortcutRead, chord: ResolvedChord?) {
        let id: Int32 = right ? 81 : 79
        switch hotkey(id) {
        case .unknown: return (.unread, nil)
        case .disabled: return (.off, nil)
        case .enabled(let keyCode, let flags):
            switch classify(keyCode: keyCode, flags: flags) {
            case .unusable(let issue): return (.unusable(issue), nil)
            case .unread: return (.unread, nil)
            case .disabled: return (.off, nil)
            case .ready(let prepared):
                let arrow = ArrowHotkey(right: right, keyCode: keyCode, flags: flags)
                if commandConflicts(prepared.key, prepared.flags) { return (.conflict(arrow), nil) }
                return (.usable(arrow), ResolvedChord(key: CGKeyCode(prepared.key), modifiers: prepared.modifiers, arrow: prepared.arrow))
            }
        }
    }

    // MARK: - Hotkey parts (shared by Desktop N and left/right)

    /// One interruption baseline for the whole operation (input observation, authorization, input baseline). The public `switchTo` / `moveWindow` / tier-0 entry builds it once and every step and tier shares it.
    struct Gates { let canContinue: () -> Bool }

    /// Per-kind validation and recording.
    struct HotkeyBinding {
        /// Reread right before sending (before each keyDown): the kind's eligibility, the settings fingerprint, overlap with LazySpace shortcuts, suppression, and outside conditions.
        var validate: () -> Swift.Result<ResolvedChord, HotkeyNotIssued>
        /// Records a pass-through (called after rereading the fingerprint and the final gate check); nil records nothing (while dragging, for example).
        var recordPassThrough: (() -> Void)?
    }

    /// Desktop N: one display, a standard Desktop, rearranging off, every type known, a number of 1-16, and the settings fingerprint (the same as Coordinator's plan).
    private func desktopBinding(_ plan: HotkeyPlan, target: UInt64) -> HotkeyBinding {
        HotkeyBinding(validate: { [self] in
            guard plan.stillEligible() else { return .failure(.ineligible("conditions")) }
            guard desktopNumber(of: target) == plan.shortcut.desktop else { return .failure(.ineligible("desktop number")) }
            switch desktopShortcut(plan.shortcut.desktop) {
            case .unread: return .failure(.unread)
            case .off: return .failure(.disabled)
            case .unusable: return .failure(.unusable)
            case .conflict: return .failure(.conflict)
            case .usable(let config):
                guard config == plan.shortcut, case .ready(let prepared) = classify(keyCode: config.keyCode, flags: config.flags) else {
                    return .failure(.ineligible("configuration"))
                }
                return .success(ResolvedChord(key: CGKeyCode(prepared.key), modifiers: prepared.modifiers, arrow: prepared.arrow))
            }
        }, recordPassThrough: { plan.report(.passedThrough) })
    }

    /// Left/right: the settings fingerprint (read in the preflight), conflicts, suppression, the same Dock, and `expected` next to `source` in the current display's order.
    /// No display-count or rearranging limits. Pass-through is recorded only in a switching context (`record`).
    private func arrowBinding(_ step: HotkeyStep, fingerprint: ArrowHotkey, policy: ArrowPolicy?, record: Bool) -> HotkeyBinding {
        HotkeyBinding(validate: { [self] in
            let (read, chord) = readArrow(right: fingerprint.right)
            switch read {
            case .unread: return .failure(.unread)
            case .off: return .failure(.disabled)
            case .unusable: return .failure(.unusable)
            case .conflict: return .failure(.conflict)
            case .usable(let current):
                guard current == fingerprint, let chord else { return .failure(.ineligible("configuration")) }
                if let policy {
                    guard policy.stillEligible() else { return .failure(.ineligible("conditions")) }
                    if policy.isSuppressed(current) { return .failure(.suppressed) }
                }
                guard let path = stepPlan(from: step.source, to: step.expected), path.count == 1, path[0].right == fingerprint.right else {
                    return .failure(.ineligible("order"))
                }
                return .success(chord)
            }
        }, recordPassThrough: record && policy != nil ? { policy?.report(fingerprint, .passedThrough) } : nil)
    }

    private enum TapReadiness { case ready(PassThroughTap), unavailable, interrupted }

    /// Waits up to 1 s for the pass-through tap to be ready (created and enabled on a dedicated thread the first time), checking the gates and source Space meanwhile.
    private func readyTap(source: UInt64, gates: Gates) -> TapReadiness {
        guard let tap = passThroughTap else { return .unavailable }
        tap.start()
        let deadline = now().addingTimeInterval(1.0)
        while tap.state != .ready {
            guard gates.canContinue(), spaces.activeSpace() == source else { return .interrupted }
            if tap.state == .failed || now() >= deadline { return .unavailable }
            sleep(0.02)
        }
        // Even when ready, a tap the system disabled cannot swallow.
        return tap.isEnabled ? .ready(tap) : .unavailable
    }

    /// Sends a hotkey once, detects pass-through with the tap, and observes arrival. The single part shared by Desktop N and left/right.
    /// - If preparation (read, classify, conflicts, suppression, the kind's eligibility, tap) fails: `notIssued` (nothing sent).
    /// - Right before each keyDown (modifiers, main key), the kind's validation runs again in full, then the cheap gates (tap, authorization, source Space).
    ///   Failed validation sends no main key and returns `notIssued`; a failed gate returns `stopped(.interrupted)`. Pressed modifiers are always released either way.
    /// - Observation (deadline: Desktop 0.8 s, left/right 2.0 s): arrival -> `arrived`. Main keyDown swallowed -> `passedThrough` (arrival wins if seen in the same check).
    ///   A Space that is neither source nor expected -> `stopped(.unexpectedSpace)`. Unreadable active -> `stopped(.activeUnreadable)`. Deadline -> `compromised` if damaged, else `unconfirmed`.
    /// - A pass-through is recorded only after rereading the fingerprint and keeping the result, checking damage and gates, with an unchanged fingerprint and somewhere to record.
    /// The settle wait and final check after arrival are the caller's. Interruptions by the caller always return `stopped`, never `notIssued`.
    func sendHotkey(_ step: HotkeyStep, gates: Gates, binding: HotkeyBinding) -> HotkeyOutcome {
        let t0 = now()
        // Keep the validation result, and check stop conditions (interruption, authorization, source Space) before classifying it as "not sent".
        let validation = binding.validate()
        guard gates.canContinue(), spaces.activeSpace() == step.source else { return .stopped(.interrupted) }
        let chord: ResolvedChord
        switch validation {
        case .failure(let reason): return .notIssued(reason)
        case .success(let value): chord = value
        }
        let tap: PassThroughTap
        switch readyTap(source: step.source, gates: gates) {
        case .ready(let value): tap = value
        case .unavailable: return .notIssued(.noTap)
        case .interrupted: return .stopped(.interrupted)
        }
        let filter = tap.filter
        let attempt = PassThroughFilter.Attempt(tag: filter.tag(attempt: PassThroughFilter.nextAttempt()), mainKey: UInt16(chord.key))
        filter.begin(attempt)
        defer { filter.retire(attempt) }
        hotkeySends += 1
        let send = hotkeySends

        var blocked: HotkeyOutcome?
        let readyToSend: () -> Bool = { [spaces] in
            // The heavy read (the kind's validation) first. Keep the result and check stop conditions (tap, damage, authorization, source Space) before classifying.
            let current = binding.validate()
            guard tap.isEnabled, !filter.isCompromised(attempt), gates.canContinue(), spaces.activeSpace() == step.source else {
                blocked = .stopped(.interrupted); return false
            }
            switch current {
            case .failure(let reason): blocked = .notIssued(reason); return false
            case .success(let value) where value != chord: blocked = .notIssued(.ineligible("configuration")); return false
            case .success: return true
            }
        }
        do {
            try press(chord, tag: attempt.tag, checkBeforeRelease: false, shouldContinue: readyToSend, onPosted: { filter.notePosted() },
                      onMainKeyDown: { self.trace("mainKeyPosted", attempt: send) })
        }
        catch {
            if let blocked { return blocked }
            // The key events could not be created (nothing sent).
            if case Failure.unavailable = error { return .notIssued(.unusable) }
            return .stopped(.interrupted)
        }

        let desktop: Bool = { if case .desktop = step.kind { return true } else { return false } }()
        let deadline = now().addingTimeInterval(desktop ? 0.8 : 2.0)
        while true {
            guard gates.canContinue() else { return .stopped(.interrupted) }
            let passedThrough = filter.mainKeyDownObserved(attempt) && !filter.isCompromised(attempt)
            guard let seen = spaces.activeSpace() else { return .stopped(.activeUnreadable) }
            if seen == step.expected {
                trace("arrivalObserved", attempt: send)
                return .arrived(ms: now().timeIntervalSince(t0) * 1000)
            }
            if seen != step.source { return .stopped(.unexpectedSpace(seen)) }
            if passedThrough { break }
            if now() >= deadline { return .stopped(filter.isCompromised(attempt) ? .compromised : .unconfirmed) }
            sleep(desktop ? 0.02 : 0.05)
        }
        // Pass-through. Reread the fingerprint and keep the result, check damage (including being disabled during the reread) and finally the gates, then decide whether to record.
        let unchanged: Bool = { if case .success(let current) = binding.validate() { return current == chord } else { return false } }()
        guard !filter.isCompromised(attempt) else { return .stopped(.compromised) }
        guard gates.canContinue(), spaces.activeSpace() == step.source else { return .stopped(.interrupted) }
        guard unchanged, let record = binding.recordPassThrough else { return .passedThrough(recorded: false) }
        record()
        return .passedThrough(recorded: true)
    }

    /// Tier 0. Sends the Desktop N shortcut with `sendHotkey`. On observed arrival, succeeds (`steps` 0) after the `settle.desktopHotkey` wait and final check, and records the arrival.
    /// Recorded pass-through -> `passedThrough`; not sent or not recorded -> `notUsed` (both go to tier 1). Stopped -> failure.
    private func desktopShortcutTier(to target: UInt64, from active: UInt64, plan: HotkeyPlan, startedAt t0: Date, gates: Gates) -> DesktopShortcutAttempt {
        let step = HotkeyStep(kind: .desktop(plan.shortcut.desktop), source: active, expected: target)
        switch sendHotkey(step, gates: gates, binding: desktopBinding(plan, target: target)) {
        case .arrived:
            // Arrival observed. After the wait, check the final authorization, input, and arrival (keys are released).
            settleFor(settle.desktopHotkey)
            guard gates.canContinue() else { return .failed(.interrupted) }
            guard let final = spaces.activeSpace() else { return .failed(.unavailable(L(.spaceControlCouldNotConfirmTheSpace))) }
            if final != target { return .failed(.drifted(to: final)) }
            plan.report(.arrived)
            return .switched(Result(fromSpace: active, toSpace: target, steps: 0, wallMs: now().timeIntervalSince(t0) * 1000))
        case .passedThrough(let recorded): return recorded ? .passedThrough : .notUsed
        case .notIssued: return .notUsed
        case .stopped(let reason): return .failed(Self.desktopFailure(reason))
        }
    }

    /// Failure when the Desktop N shortcut stopped. Timeout and damage are "sent but unconfirmed".
    private static func desktopFailure(_ reason: HotkeyStopped) -> Failure {
        switch reason {
        case .interrupted, .unexpectedSpace, .activeUnreadable: return .interrupted
        case .unconfirmed, .compromised: return .hotkeyUnconfirmed
        }
    }

    /// Failure when stepping (left/right) stopped. A timeout is a timeout as before (suggesting a check of the Mission Control settings).
    private static func steppingFailure(_ reason: HotkeyStopped) -> Failure {
        switch reason {
        case .interrupted, .unexpectedSpace: return .interrupted
        case .unconfirmed, .compromised: return .timedOut(L(.spaceControlCouldNotConfirmTheSpaceSwitch))
        case .activeUnreadable: return .unavailable(L(.spaceControlCouldNotConfirmTheSpace))
        }
    }

    /// Stepping preflight (before the first step, before jumping to an intermediate Space, before the drag's mouse-down): read, classify, conflicts, suppression, outside conditions,
    /// and the tap (ready and enabled). After waiting for the tap (up to 1 s), it rereads to confirm the same setting is usable.
    /// Shortcut setting problems return `unavailable` with the setting name as before (nothing sent yet); suppression, outside conditions, and the tap return `steppingUnavailable`.
    private func prepareArrow(right: Bool, policy: ArrowPolicy?, source: UInt64, gates: Gates) -> Swift.Result<ArrowHotkey, Failure> {
        let fingerprint: ArrowHotkey
        switch readArrow(right: right).read {
        case .unread: return .failure(refused(.unread, right: right))
        case .off: return .failure(refused(.disabled, right: right))
        case .unusable(let issue): return .failure(refused(ShortcutIssue(issue), right: right))
        case .conflict: return .failure(refused(.conflict, right: right))
        case .usable(let value): fingerprint = value
        }
        if policy?.isSuppressed(fingerprint) == true { return .failure(.steppingUnavailable(.suppressed(right: right))) }
        if policy?.stillEligible() == false { return .failure(.steppingUnavailable(.configuration(changedText(right: right, sent: false)))) }
        switch readyTap(source: source, gates: gates) {
        case .ready: break
        case .unavailable: return .failure(.steppingUnavailable(.noTap))
        case .interrupted: return .failure(.interrupted)
        }
        // Did the setting change while waiting for readiness?
        if let failure = arrowUnusable(fingerprint, policy: policy, sent: false) { return .failure(failure) }
        guard gates.canContinue(), spaces.activeSpace() == source else { return .failure(.interrupted) }
        return .success(fingerprint)
    }

    /// Whether the left/right keys read in the preflight are still usable with the same setting (right before jumping to an intermediate Space, before the drag's mouse-down, after waiting for readiness).
    /// Returns the failure if not. `sent` says whether the route has already started (steps sent, moved to an intermediate Space, window grabbed).
    private func arrowUnusable(_ fingerprint: ArrowHotkey, policy: ArrowPolicy?, sent: Bool) -> Failure? {
        let right = fingerprint.right
        func issue(_ issue: ShortcutIssue) -> Failure {
            sent ? .steppingUnavailable(.configuration(remainingText(issue, right: right))) : refused(issue, right: right)
        }
        switch readArrow(right: right).read {
        case .usable(let current) where current == fingerprint: break
        case .usable: return .steppingUnavailable(.configuration(changedText(right: right, sent: sent)))
        case .unread: return issue(.unread)
        case .off: return issue(.disabled)
        case .unusable(let value): return issue(ShortcutIssue(value))
        case .conflict: return issue(.conflict)
        }
        if policy?.isSuppressed(fingerprint) == true { return .steppingUnavailable(.suppressed(right: right)) }
        if policy?.stillEligible() == false { return .steppingUnavailable(.configuration(changedText(right: right, sent: sent))) }
        guard let tap = passThroughTap, tap.state == .ready, tap.isEnabled else { return .steppingUnavailable(.noTap) }
        return nil
    }

    /// Text for a shortcut setting problem found after the route started: setting name and reason, and that the rest of the moves were not sent.
    private func remainingText(_ issue: ShortcutIssue, right: Bool) -> String {
        let settings = L(.spaceControlSystemSettingsKeyboardKeyboardShortcuts)
        return Self.lead(issue, right: right) + Copy.sentenceSeparator + L(.spaceControlTheRemainingStepsWereNot(settings))
    }

    /// Text for an assignment or Dock change after the preflight.
    private func changedText(right: Bool, sent: Bool) -> String {
        let name = MacItem.moveSpace(right: right)
        return sent
            ? L(.spaceControlTheMissionControlShortcutOr(name))
            : L(.spaceControlTheMissionControlShortcutOrThe(name))
    }

    /// Failure when stepping becomes "not sent" midway (the caller decides whether to replan for an order change). It is after the preflight, so setting problems
    /// get the "the rest of the moves were not sent" text and the place note (`steppingUnavailable(.configuration)`).
    private func steppingFailure(_ reason: HotkeyNotIssued, right: Bool) -> Failure {
        switch reason {
        case .suppressed: return .steppingUnavailable(.suppressed(right: right))
        case .noTap: return .steppingUnavailable(.noTap)
        case .ineligible("order"): return .routeChanged
        case .ineligible: return .steppingUnavailable(.configuration(changedText(right: right, sent: true)))
        case .unread: return .steppingUnavailable(.configuration(remainingText(.unread, right: right)))
        case .disabled: return .steppingUnavailable(.configuration(remainingText(.disabled, right: right)))
        case .conflict: return .steppingUnavailable(.configuration(remainingText(.conflict, right: right)))
        case .unusable:
            if case .unusable(let value) = readArrow(right: right).read { return .steppingUnavailable(.configuration(remainingText(ShortcutIssue(value), right: right))) }
            return .steppingUnavailable(.configuration(changedText(right: right, sent: true)))
        }
    }

    /// Left/right stepping, each step sent with `sendHotkey`. If the order changes so the next Space is no longer adjacent, the plan is redone once.
    /// Pass-through -> `steppingUnavailable(.notHonored)` on the spot (recorded as a switching context when `record`). `afterEachStep` is the drag signal and the like.
    /// Returns the number of steps sent; the last settle wait and check are the caller's.
    /// `replan` is for switching only (while dragging, a window is grabbed, so an order change releases and stops instead of replanning).
    private func stepAlong(from start: UInt64, to target: UInt64, fingerprint: ArrowHotkey, policy: ArrowPolicy?, record: Bool, replan: Bool, gates: Gates,
                           afterEachStep: () throws -> Void = {}) -> Swift.Result<Int, Failure> {
        let right = fingerprint.right
        guard var path = stepPlan(from: start, to: target), !path.isEmpty, path.allSatisfy({ $0.right == right }) else { return .failure(.routeChanged) }
        var current = start
        var sent = 0
        var replanned = false
        while !path.isEmpty {
            let next = path.removeFirst()
            let step = HotkeyStep(kind: right ? .arrowRight : .arrowLeft, source: current, expected: next.expected)
            currentStep = sent + 1
            defer { currentStep = nil }
            switch sendHotkey(step, gates: gates, binding: arrowBinding(step, fingerprint: fingerprint, policy: policy, record: record)) {
            case .arrived:
                sent += 1
                current = next.expected
                policy?.report(fingerprint, .arrived)
                do { try afterEachStep() } catch let failure as Failure { return .failure(failure) } catch { return .failure(.interrupted) }
            case .passedThrough:
                return .failure(.steppingUnavailable(.notHonored(right: right)))
            case .notIssued(.ineligible("order")) where replan && !replanned:
                // The order changed. Redo the plan once from the current Space (if the direction changed, unvalidated keys are not sent).
                replanned = true
                guard let fresh = stepPlan(from: current, to: target), !fresh.isEmpty, fresh.allSatisfy({ $0.right == right }) else { return .failure(.routeChanged) }
                path = fresh
            case .notIssued(let reason):
                return .failure(steppingFailure(reason, right: right))
            case .stopped(let reason):
                return .failure(Self.steppingFailure(reason))
            }
        }
        return .success(sent)
    }

    /// Waits until tier-0 attempt events have stopped flowing for a while (used before lzprobe exits, since the tap dies with the process).
    /// **Best effort**: a quiet stretch does not prove no events are still queued in front of WindowServer.
    /// True once `quiet` seconds passed since the last post or arrival; false after giving up at `timeout` seconds.
    public func drainPassThrough(quiet: TimeInterval = 1.0, timeout: TimeInterval = 5.0) -> Bool {
        guard let filter = passThroughTap?.filter else { return true }
        let deadline = now().addingTimeInterval(timeout)
        while true {
            guard let last = filter.lastActivityAt, now().timeIntervalSince(last) < quiet else { return true }
            if now() >= deadline { return false }
            sleep(0.05)
        }
    }

    /// Steps left/right to the target (`stepAlong`, recording pass-through as a switching context) and finally checks it stays on the target.
    /// `start` is where stepping begins, `origin` the operation's source (the result's `fromSpace`). `steps` is the number of steps sent.
    private func stepAndConfirm(from start: UInt64, origin: UInt64, to target: UInt64, fingerprint: ArrowHotkey, policy: ArrowPolicy?,
                                startedAt t0: Date, gates: Gates) -> Swift.Result<Result, Failure> {
        let sent: Int
        switch stepAlong(from: start, to: target, fingerprint: fingerprint, policy: policy, record: true, replan: true, gates: gates) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): sent = value
        }
        // Arrival of the last step observed. After the wait, check the final authorization, input, and arrival.
        settleFor(settle.arrowFinal)
        guard gates.canContinue() else { return .failure(.interrupted) }
        guard let final = spaces.activeSpace() else { return .failure(.unavailable(L(.spaceControlCouldNotConfirmTheSpace))) }
        if final != target { return .failure(.drifted(to: final)) }
        return .success(Result(fromSpace: origin, toSpace: target, steps: sent, wallMs: now().timeIntervalSince(t0) * 1000))
    }

    /// Display number (1-based, same as `list-spaces`); the ID itself if not in the order.
    public func label(_ id: UInt64) -> String {
        let order = orderedSpaces()
        if let n = SpaceObserver.desktopNumbers(order)[id] { return Copy.desktop(n) }
        if order.first(where: { $0.id == id })?.type == 4 { return L(.spaceControlFullScreen) }
        return L(.spaceControlSpace(String(id)))
    }

    // MARK: - Moving

    // MARK: - Sending (without switching)

    /// Result of `sendWindow`.
    /// After issuing (anything but `confirmed`), membership may change late, so it never says "stayed on the original Space".
    public enum SendOutcome: Equatable {
        /// Nothing issued (no route, conditions unmet, interrupted).
        case notIssued(Failure)
        /// Confirmed that membership became only the target Space.
        case confirmed(Result)
        /// Issued, but membership did not become only the target in time (unreadable, several, still the source). The last membership read.
        case unconfirmed([UInt64])
        /// After issuing, it belonged to one Space other than the target.
        case elsewhere(UInt64)
        /// After issuing, waiting stopped for input, cancellation, or pause.
        case interrupted
    }

    /// Whether the bridged move is available (`move-to-space` without follow is refused without it; dragging switches Spaces, so it is no substitute).
    public var canSendWithoutFollowing: Bool { direct?.move != nil }

    /// Changes only the window's membership, without switching (no follow) or activation. After issuing, waits up to 1 s for membership to become only the target.
    /// Gates are split around issuing: `beforeIssue` right before issuing (may include being on the source Space), `afterIssue` while waiting afterward
    /// (input, cancellation, pause; the source Space is not required). If macOS changes the current Space while waiting, it is not an interruption (the caller observes and reports it, without reverting).
    public func sendWindow(_ wid: CGWindowID, toSpace target: UInt64, timeline: OperationTimeline? = nil,
                           beforeIssue: @escaping () -> Bool = { true }, afterIssue: @escaping () -> Bool = { true }) -> SendOutcome {
        beginTrace(timeline)
        defer { endTrace() }
        let t0 = now()
        // Take the input baseline first (input during the slow reads below also prevents issuing).
        let baseline = inputCount()
        guard let direct, let move = direct.move else {
            return .notIssued(.unavailable(L(.spaceControlSendingAWindowWithoutSwitching)))
        }
        guard let active = spaces.activeSpace() else { return .notIssued(.unavailable(L(.spaceControlCouldNotDetermineTheCurrent))) }
        if active == target { return .notIssued(.alreadyThere) }
        // The direct move is only for standard Desktops (type 0); full screen and others are unverified.
        guard let entry = record(of: target) else { return .notIssued(.noSuchSpace) }
        guard entry.type == 0 else { return .notIssued(.unavailable(L(.spaceControlAWindowCanBeSent))) }
        guard spaces.spaces(for: wid) == [active] else { return .notIssued(.unavailable(L(.spaceControlTheWindowMovedToA))) }
        guard inputAvailable() else { return .notIssued(.unavailable(L(.spaceControlMouseAndKeyboardInputObservation))) }
        let inputQuiet = { self.inputAvailable() && self.inputCount() == baseline }
        let canContinue = { inputQuiet() && afterIssue() }
        // Right before issuing, the cheap gates and the current Space once more.
        guard inputQuiet(), beforeIssue(), spaces.activeSpace() == active else { return .notIssued(.interrupted) }
        guard move(wid, target) else { return .notIssued(.unavailable(L(.spaceControlTheWindowCouldNotBe))) }
        trace("moveIssued")
        var membership = spaces.spaces(for: wid)
        let deadline = now().addingTimeInterval(1.0)
        while membership != [target], now() < deadline {
            guard canContinue() else { return .interrupted }
            sleep(0.02)
            membership = spaces.spaces(for: wid)
        }
        // After the last membership read, the cheap gates once more.
        guard canContinue() else { return .interrupted }
        if membership == [target] {
            trace("arrivalObserved")
            return .confirmed(Result(fromSpace: active, toSpace: target, steps: 0, wallMs: now().timeIntervalSince(t0) * 1000))
        }
        if membership.count == 1, membership[0] != active { return .elsewhere(membership[0]) }
        return .unconfirmed(membership)
    }

    /// Caller checks inside a move.
    public struct MoveHooks {
        /// Right before the direct move is issued or the window is grabbed; false issues nothing (`.interrupted`).
        public var beforeIssue: () -> Bool
        /// After the direct move is confirmed and before the window is brought forward (fitting it onto another display, for example).
        public var beforeRaise: () -> Void
        public init(beforeIssue: @escaping () -> Bool = { true }, beforeRaise: @escaping () -> Void = {}) {
            self.beforeIssue = beforeIssue; self.beforeRaise = beforeRaise
        }
    }

    /// Changes membership and brings the window forward; if a direct move is impossible, grabs the window and switches Spaces. frame is the current frame (top-left-origin logical coordinates).
    /// The drag grabs the top center of the title bar (draggable in most apps; tabbed apps may not allow it).
    /// `follow` is lzprobe's comparison Desktop N follow, nil in normal calls. `arrows` is the left/right key suppression for drag stepping (nothing is recorded).
    public func moveWindow(_ wid: CGWindowID, frame: CGRect, toSpace target: UInt64, follow: HotkeyPlan? = nil, arrows: ArrowPolicy? = nil,
                           timeline: OperationTimeline? = nil, hooks: MoveHooks = MoveHooks(), shouldContinue: @escaping () -> Bool = { true }) -> Swift.Result<Result, Failure> {
        placeNote = nil
        beginTrace(timeline)
        defer { endTrace() }
        let outcome = moveWindowBody(wid, frame: frame, toSpace: target, follow: follow, arrows: arrows, hooks: hooks, shouldContinue: shouldContinue)
        notePlace(outcome, window: wid)
        return outcome
    }

    private func moveWindowBody(_ wid: CGWindowID, frame: CGRect, toSpace target: UInt64, follow: HotkeyPlan?, arrows: ArrowPolicy?,
                                hooks: MoveHooks, shouldContinue: @escaping () -> Bool) -> Swift.Result<Result, Failure> {
        let t0 = now()
        guard let active = spaces.activeSpace() else { return .failure(.unavailable(L(.spaceControlCouldNotDetermineTheCurrent))) }
        if active == target { return .failure(.alreadyThere) }
        // nil steps: the target is on another display, reachable only by the direct move.
        let steps = stepPlan(from: active, to: target)
        guard steps != nil || record(of: target)?.type == 0 else { return .failure(.noSuchSpace) }
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width >= 40, frame.height >= 20 else { return .failure(.unavailable(L(.spaceControlCouldNotReadTheWindows))) }
        // Do not grab sticky windows or windows that moved to another Space after acceptance.
        guard spaces.spaces(for: wid) == [active] else { return .failure(.unavailable(L(.spaceControlTheWindowMovedToA))) }

        // Interruption conditions are the same on both paths: input observation available, caller authorization holds, no user input.
        let baseline = inputCount()
        guard inputAvailable() else { return .failure(.unavailable(L(.spaceControlMouseAndKeyboardInputObservation))) }
        let canContinue = { self.inputAvailable() && shouldContinue() && self.inputCount() == baseline }
        let gates = Gates(canContinue: canContinue)

        switch directMove(wid, from: active, to: target, follow: follow, hooks: hooks, startedAt: t0, gates: gates) {
        case .done(let result): return .success(result)
        case .failed(let failure): return .failure(failure)
        case .fallback: break
        }

        guard let steps else { return .failure(.otherDisplayNeedsDirectMove) }
        let grab = CGPoint(x: frame.midX, y: frame.minY + 6)
        let originalCursor = cursorPosition()
        guard let direction = steps.first?.right else { return .failure(.alreadyThere) }
        // Preflight the stepping keys before the mouse goes down (read, conflicts, suppression, tap).
        let fingerprint: ArrowHotkey
        switch prepareArrow(right: direction, policy: arrows, source: active, gates: gates) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): fingerprint = value
        }
        var mouseDown = false
        defer {
            // After an interruption, release only the button where the user moved it; do not push the cursor back.
            if mouseDown { post(mouse(.leftMouseUp, at: cursorPosition())) }
            if canContinue() { warpCursor(originalCursor) }
        }
        do {
            try requireContinuation(canContinue)
            warpCursor(grab)
            post(mouse(.mouseMoved, at: grab))
            sleep(0.05)
            try requireContinuation(canContinue)
            guard spaces.activeSpace() == active else { return .failure(.interrupted) }
            // Right before the mouse goes down, reconfirm the stepping keys are usable with the same setting (the window is not grabbed yet).
            if let failure = arrowUnusable(fingerprint, policy: arrows, sent: false) { return .failure(failure) }
            // If the Space changed (without input) during the reads above, do not grab a window on another Space.
            try requireContinuation(canContinue)
            guard spaces.activeSpace() == active else { return .failure(.interrupted) }
            guard hooks.beforeIssue(), canContinue(), spaces.activeSpace() == active else { return .failure(.interrupted) }
            post(mouse(.leftMouseDown, at: grab)); mouseDown = true
            for d in [3.0, 6.0, 3.0, 0.0] {
                sleep(0.03)
                try requireContinuation(canContinue)
                post(mouse(.leftMouseDragged, at: CGPoint(x: grab.x + d, y: grab.y + d)))
            }
            sleep(0.1)
            // Each step is `sendHotkey`. Pass-through while dragging is not recorded (just stop and release). On every exit, defer releases the mouse before the place is noted.
            switch stepAlong(from: active, to: target, fingerprint: fingerprint, policy: arrows, record: false, replan: false, gates: gates, afterEachStep: {
                try requireContinuation(canContinue)
                post(mouse(.leftMouseDragged, at: grab))
                sleep(0.15)
            }) {
            case .failure(let failure): return .failure(failure)
            case .success: break
            }
            sleep(0.2)
            try requireContinuation(canContinue)
            guard spaces.activeSpace() == target else { return .failure(.interrupted) }
            post(mouse(.leftMouseDragged, at: grab))
            sleep(0.05)
            try requireContinuation(canContinue)
            post(mouse(.leftMouseUp, at: grab)); mouseDown = false

            let deadline = now().addingTimeInterval(1.5)
            while now() < deadline {
                try requireContinuation(canContinue)
                if spaces.spaces(for: wid) == [target] {
                    guard let final = spaces.activeSpace() else { return .failure(.unavailable(L(.spaceControlCouldNotConfirmTheSpaceAfter))) }
                    guard final == target else { return .failure(.drifted(to: final)) }
                    return .success(Result(fromSpace: active, toSpace: target, steps: steps.count, wallMs: now().timeIntervalSince(t0) * 1000))
                }
                sleep(0.1)
            }
            let finalSpaces = spaces.spaces(for: wid)
            if let elsewhere = finalSpaces.first, !finalSpaces.contains(active) { return .failure(.movedElsewhere(to: elsewhere)) }
            return .failure(.notMoved)
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(.interrupted) }
    }

    // MARK: - Direct path

    private enum DirectOutcome { case done(Result), fallback, failed(Failure) }

    /// Switches in one go with the target's candidates. `.fallback` (to the next tier) only when nothing was issued.
    /// If something was issued but no switch happened, `switchUnconfirmed` (an issued AXRaise or activation cannot be cancelled, and taking effect late would overlap stepping and overshoot).
    private func directSwitch(to target: UInt64, from active: UInt64, candidates: [Candidate], startedAt t0: Date, canContinue: @escaping () -> Bool) -> DirectOutcome {
        guard direct != nil, !candidates.isEmpty else { return .fallback }
        guard record(of: target)?.type == 0 else { return .fallback }
        let liveness = Liveness()
        defer { liveness.live = false }
        switch jump(to: target, from: active, candidates: candidates, liveness: liveness, canContinue: canContinue) {
        case .arrived: return finishDirectSwitch(target, from: active, startedAt: t0, canContinue: canContinue)
        case .nothingIssued: return .fallback
        case .failed(let failure): return .failed(failure)
        }
    }

    private enum Jump { case arrived, nothingIssued, failed(Failure) }

    /// A flag about a candidate window (seen leaving the target Space, or read ordered out). Read from several threads.
    private final class DepartureLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
        func clear() { lock.lock(); value = false; lock.unlock() }
    }

    /// Tries `dest`'s candidates in order. Only windows belonging to `dest` alone are raised (closed windows and windows on other Spaces are skipped), and refused windows (no AX element, for example) are skipped.
    /// Apps are skipped only when `activateApp` rechecked and queued nothing, or the main thread declined without issuing anything.
    /// Stops at the first candidate whose activation was issued (or unknown) and waits for the switch; windows get reactivate when needed.
    /// When an activation was queued (from raise, or us -> target app), it does not return after arriving until the target app is observed in front (`waitForHandoff`).
    /// Candidates are bounded by the caller's list (8 recent front windows, layout, observation, eligible apps), and an AX timeout stops once as `unknown`.
    /// Arriving by raise alone also waits until the raise's queued activation takes effect and the window's app is seen in front (on intermediate and target Spaces alike),
    /// since taking effect late would pull back to that window's Space mid-stepping or mid-next-command (closing the gate cannot cancel a requested activation).
    private func jump(to dest: UInt64, from source: UInt64, candidates: [Candidate], liveness: Liveness, canContinue: @escaping () -> Bool) -> Jump {
        guard let direct else { return .nothingIssued }
        let onExpectedSpace: () -> Bool = { [spaces] in
            guard let seen = spaces.activeSpace() else { return false }
            return seen == source || seen == dest
        }
        let isCurrent = { liveness.live && canContinue() && onExpectedSpace() }
        let stillOnSource = { [spaces] in liveness.live && canContinue() && spaces.activeSpace() == source }
        for candidate in candidates {
            guard canContinue(), spaces.activeSpace() == source else { return .failed(.interrupted) }
            switch candidate {
            case .window(let wid):
                // Raise only windows belonging to the target Space alone (so windows on other Spaces or all Spaces never cause the switch),
                // and never one kept ordered out (a closed window still listed there switches nothing).
                guard spaces.spaces(for: wid) == [dest], spaces.isOrderedIn(wid) != false else { continue }
                // If input or a switch happened during the membership query, AXRaise is not sent.
                guard canContinue(), spaces.activeSpace() == source else { return .failed(.interrupted) }
                // Right before activation and its late activate too, check the window has not moved from the target to another Space.
                // When membership is unknown (empty), proceed on the earlier check.
                // Once seen off the target, it is never allowed again even if membership becomes unknown (shared by activation and retry; called from both main and the operations queue).
                let departed = DepartureLatch()
                // A window closed or minimized meanwhile stays listed on the target but ordered out; raising it would switch nothing.
                // Unlike leaving, this is undone by a later ordered-in read (a window can read ordered out for a moment), never by an unknown one.
                // Membership is read first, so leaving while ordered out (moved and minimized) is still recorded.
                let orderedOut = DepartureLatch()
                let stillOnDest = { [spaces] () -> Bool in
                    if departed.isSet { return false }
                    let now = spaces.spaces(for: wid)
                    if !now.isEmpty, now != [dest] { departed.set(); return false }
                    switch spaces.isOrderedIn(wid) {
                    case false?: orderedOut.set(); return false
                    case true?: orderedOut.clear(); return true
                    case nil: return !orderedOut.isSet
                    }
                }
                // Input, pause, or a Space change can happen during the membership read, so the same gate is checked after it too.
                let isCurrentHere = { isCurrent() && stillOnDest() && isCurrent() }
                let stillOnSourceHere = { stillOnSource() && stillOnDest() && stillOnSource() }
                let raised = Handoff()
                if direct.raise(wid, isCurrentHere, raised.note) == .refused { continue }
                // The activation queued by raise is confirmed as a hand-off too (requested, and the window's app seen in front).
                let confirmRaise = { self.waitForHandoff(raised, on: dest, canContinue: canContinue) }
                switch waitForArrival(dest, from: source, within: 0.8, canContinue: canContinue) {
                case .arrived: return confirmRaise()
                case .interrupted: return .failed(.interrupted)
                case .stillOnSource:
                    let handoff = Handoff()
                    direct.reactivate(wid, stillOnSourceHere, isCurrentHere, handoff.note)
                    switch waitForArrival(dest, from: source, within: 1.5, canContinue: canContinue) {
                    case .arrived:
                        let handedOff = waitForHandoff(handoff, on: dest, canContinue: canContinue)
                        guard case .arrived = handedOff else { return handedOff }
                        return confirmRaise()
                    case .interrupted: return .failed(.interrupted)
                    case .stillOnSource: return .failed(.switchUnconfirmed)
                    }
                }
            case .app(let pid, let bundleID):
                guard let activate = direct.activateApp else { continue }
                let handoff = Handoff()
                if activate(pid, bundleID, dest, stillOnSource, isCurrent, handoff.note) == .notIssued { continue }
                switch waitForActivation(dest, from: source, handoff: handoff, within: 2.0, canContinue: canContinue) {
                case .notIssued: continue
                case .arrived: return waitForHandoff(handoff, on: dest, canContinue: canContinue)
                case .interrupted: return .failed(.interrupted)
                // We came forward (issued), or no report from the main thread (unknown). Either may take effect late.
                case .unconfirmed: return .failed(.switchUnconfirmed)
                }
            }
        }
        return .nothingIssued
    }

    /// Progress of the us -> target-app hand-off. Written by the main thread and read by the operations queue, so lock-protected.
    private final class Handoff {
        private let lock = NSLock()
        private var declinedSeen = false, beganSeen = false, abandonedSeen = false
        private var requestedPID: pid_t?
        func note(_ stage: ActivationStage) {
            lock.lock(); defer { lock.unlock() }
            switch stage {
            case .declined: declinedSeen = true
            case .began: beganSeen = true
            case .requested(let pid): requestedPID = pid
            case .abandoned: abandonedSeen = true
            }
        }
        /// Ended without issuing anything.
        var declined: Bool { lock.lock(); defer { lock.unlock() }; return declinedSeen && !beganSeen }
        /// We came forward, but the target's activation was given up.
        var abandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandonedSeen }
        /// The target whose activation was requested.
        var requested: pid_t? { lock.lock(); defer { lock.unlock() }; return requestedPID }
    }

    private enum Activation { case arrived, notIssued, interrupted, unconfirmed }

    /// Waits for the activation result: seeing the target means arrival; a Space other than source and target interrupts.
    /// If the main thread reports declining without issuing, `notIssued` (next candidate). If it gave up after we came forward, or nothing arrived in time,
    /// it may have been issued, so `unconfirmed` (neither the next candidate nor stepping).
    private func waitForActivation(_ dest: UInt64, from source: UInt64, handoff: Handoff, within timeout: TimeInterval, canContinue: () -> Bool) -> Activation {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            guard canContinue() else { return .interrupted }
            switch spaces.activeSpace() {
            case dest: trace("arrivalObserved"); return .arrived
            case source: break
            default: return .interrupted
            }
            if handoff.declined { return .notIssued }
            if handoff.abandoned || now() >= deadline { return .unconfirmed }
            sleep(0.02)
        }
    }

    /// After arriving, waits until the us -> target-app hand-off ends: either it declined without issuing (the arrival had another cause)
    /// or the requested target app is observed in front. Just `requested` is not the end, since taking effect late would pull back to that window's Space.
    /// Window follow waits for focus within the same deadline. Even unissued or abandoned, AXRaise may take effect late, so once the pending request clears, the target window decides.
    /// If declined before reactivation began, it also confirms the original raise's pending request cleared (`fallback`).
    private func waitForHandoff(_ handoff: Handoff, on dest: UInt64, window: CGWindowID? = nil, ifDeclined fallback: Handoff? = nil, canContinue: () -> Bool) -> Jump {
        let deadline = now().addingTimeInterval(1.5)
        while true {
            guard canContinue() else { return .failed(.interrupted) }
            let front = frontmostPID()
            guard spaces.activeSpace() == dest else { return .failed(.interrupted) }
            let current = handoff.declined ? (fallback ?? handoff) : handoff
            let endedWithoutRequest = current.declined || current.abandoned
            if window == nil {
                if current.declined { return .arrived }
                if current.abandoned { return .failed(.activationUnconfirmed) }
            }
            // focusedWindow is read from the front app. With no request left, a window ID unique across apps and a stable front pid confirm it.
            let expectedPID = window != nil && endedWithoutRequest ? front : current.requested
            if let pid = expectedPID, front == pid {
                let focused = window == nil || direct?.focusedWindow() == window
                // Input or Space switches during the AX read do not count as success either.
                guard canContinue(), spaces.activeSpace() == dest else { return .failed(.interrupted) }
                if focused && frontmostPID() == pid {
                    trace("activationConfirmed")
                    if window != nil { trace("focusConfirmed") }
                    return .arrived
                }
            }
            if now() >= deadline { return .failed(.activationUnconfirmed) }
            sleep(0.02)
        }
    }

    /// Tier 3. Called only when every target candidate was skipped or definitely refused.
    /// Looks at Spaces between source and target (ends excluded, standard Desktops on the same display) nearest the target first, and steps to the target from the first Space `X` reachable in one go with a candidate.
    /// If no candidate of `X` can be issued, the next nearest is tried. If nowhere is reachable, `.fallback` (step from the source).
    /// Unused when the target is not a standard Desktop. The fingerprint is the key validated before jumping.
    private func hopSwitch(to target: UInt64, from active: UInt64, fingerprint: ArrowHotkey, policy: ArrowPolicy?, candidates: [UInt64: [Candidate]],
                           startedAt t0: Date, gates: Gates) -> DirectOutcome {
        guard direct != nil else { return .fallback }
        let right = fingerprint.right
        let canContinue = gates.canContinue
        let order = orderedSpaces()
        guard let i = order.firstIndex(where: { $0.id == active }), let j = order.firstIndex(where: { $0.id == target }),
              (j > i) == right, order[j].type == 0 else { return .fallback }
        let between = right ? Array(order[(i + 1)..<j].reversed()) : Array(order[(j + 1)..<i])
        for hop in between where hop.type == 0 {
            let list = candidates[hop.id] ?? []
            if list.isEmpty { continue }
            // Right before jumping, reconfirm the remaining stepping keys are usable with the same setting (nothing sent yet).
            if let failure = arrowUnusable(fingerprint, policy: policy, sent: false) { return .failed(failure) }
            guard canContinue(), spaces.activeSpace() == active else { return .failed(.interrupted) }
            let liveness = Liveness()
            let jumped = jump(to: hop.id, from: active, candidates: list, liveness: liveness, canContinue: canContinue)
            // Close the gate once the hand-off ended (the target app seen in front) or was abandoned on interruption; queued activations do nothing afterward.
            liveness.live = false
            switch jumped {
            case .nothingIssued: continue
            case .failed(let failure): return .failed(failure)
            case .arrived:
                settleFor(settle.hop)
                guard canContinue(), spaces.activeSpace() == hop.id else { return .failed(.interrupted) }
                // The target is kept as a Space ID. Reread the order; if the target is gone or the direction changed (needing an unvalidated key), the rest is not sent.
                guard stepPlan(from: hop.id, to: target).map({ !$0.isEmpty && $0.allSatisfy { $0.right == right } }) == true else { return .failed(.routeChanged) }
                // `stepAlong` sends the rest from the same order (rechecking adjacency before each step).
                switch stepAndConfirm(from: hop.id, origin: active, to: target, fingerprint: fingerprint, policy: policy, startedAt: t0, gates: gates) {
                case .success(let result): return .done(result)
                case .failure(let failure): return .failed(failure)
                }
            }
        }
        return .fallback
    }

    private func finishDirectSwitch(_ target: UInt64, from active: UInt64, startedAt t0: Date, canContinue: () -> Bool) -> DirectOutcome {
        settleFor(settle.directArrival)
        guard canContinue() else { return .failed(.interrupted) }
        guard let final = spaces.activeSpace() else { return .failed(.unavailable(L(.spaceControlCouldNotConfirmTheSpace))) }
        if final != target { return .failed(.drifted(to: final)) }
        return .done(Result(fromSpace: active, toSpace: target, steps: 0, wallMs: now().timeIntervalSince(t0) * 1000))
    }

    /// True only while the operation continues: the gate for activations that run later on the main thread. Dropped by the operations queue and read by the main thread, so lock-protected.
    private final class Liveness {
        private let lock = NSLock()
        private var value = true
        var live: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Changes membership, confirms, then switches by activation.
    /// `.fallback` (to stepping) only when nothing happened: no route, a target that is not a standard Desktop, or the request could not be sent.
    /// After the request is sent, no fallback to stepping even if membership does not change (an asynchronous move arriving late could make a drag grab another window).
    /// Membership changed with only the switch left is `notSwitched`. Membership and active are reread right before returning.
    private func directMove(_ wid: CGWindowID, from active: UInt64, to target: UInt64, follow: HotkeyPlan?, hooks: MoveHooks, startedAt t0: Date, gates: Gates) -> DirectOutcome {
        let canContinue = gates.canContinue
        guard let direct, let move = direct.move else { return .fallback }
        // Direct moves to full-screen and other Spaces are unverified; standard Desktops (type 0) only.
        guard record(of: target)?.type == 0 else { return .fallback }
        // The caller's check reads slowly, so the Space and the gates are checked again after it.
        guard canContinue(), spaces.activeSpace() == active, hooks.beforeIssue(), canContinue(), spaces.activeSpace() == active else { return .failed(.interrupted) }
        guard move(wid, target) else { return .fallback }

        var membership = spaces.spaces(for: wid)
        let deadline = now().addingTimeInterval(1.0)
        while membership != [target], now() < deadline {
            guard canContinue(), spaces.activeSpace() == active else { return .failed(.interrupted) }
            sleep(0.02)
            membership = spaces.spaces(for: wid)
        }
        // Catch the user switching or acting at the interval of the last read, before the raise.
        guard canContinue(), spaces.activeSpace() == active else { return .failed(.interrupted) }
        if let failure = Self.membershipFailure(membership, source: active, target: target, confirmed: false) { return .failed(failure) }
        hooks.beforeRaise()
        guard canContinue(), spaces.activeSpace() == active else { return .failed(.interrupted) }

        // Only when lzprobe asks for the comparison Desktop N follow, the shortcut goes first.
        // Not sent or passed through: normal follow (raise -> reactivate). Stopped: no other path (the window is on the target).
        if let follow {
            let step = HotkeyStep(kind: .desktop(follow.shortcut.desktop), source: active, expected: target)
            switch sendHotkey(step, gates: gates, binding: desktopBinding(follow, target: target)) {
            case .arrived: return confirmHotkeyFollow(wid, from: active, to: target, plan: follow, startedAt: t0, gates: gates)
            case .passedThrough, .notIssued: break
            case .stopped(let reason): return .failed(Self.followFailure(reason))
            }
        }

        // Gate for activations that run later on the main thread: only while the operation runs, without interruption, and with the source or target visible,
        // so an activation never overrides a switch not counted as input (another app changing the Space, for example).
        let liveness = Liveness()
        defer { liveness.live = false }
        let onExpectedSpace: () -> Bool = { [spaces] in
            guard let seen = spaces.activeSpace() else { return false }
            return seen == active || seen == target
        }
        let isCurrent = { [spaces] in
            liveness.live && spaces.spaces(for: wid) == [target] && onExpectedSpace() && canContinue() && liveness.live
        }
        // The reactivation workaround starts only while still on the source Space (if the raise took effect late, nothing happens).
        // Once started, restoring (bringing the window's app forward) happens even if the target was reached midway (`isCurrent`).
        let stillOnSource = { [spaces] in isCurrent() && spaces.activeSpace() == active }
        let raised = Handoff()
        trace("followRaiseRequested")
        _ = direct.raise(wid, isCurrent, raised.note)
        var focusedHandoff = raised
        switch waitForArrival(target, from: active, within: 0.8, canContinue: canContinue) {
        case .arrived: break
        case .interrupted: return .failed(.interrupted)
        case .stillOnSource:
            let reactivated = Handoff()
            trace("followReactivateRequested")
            direct.reactivate(wid, stillOnSource, isCurrent, reactivated.note)
            switch waitForArrival(target, from: active, within: 1.5, canContinue: canContinue) {
            case .arrived: break
            case .interrupted: return .failed(.interrupted)
            case .stillOnSource:
                // The window should be on the target; reread before saying so.
                if let failure = Self.membershipFailure(spaces.spaces(for: wid), source: active, target: target, confirmed: true) { return .failed(failure) }
                return .failed(.notSwitched)
            }
            focusedHandoff = reactivated
        }
        // Wait for activation and the target window's focus under one deadline. If a late arrival made reactivation unnecessary, check the original raise.
        return completeFollow(wid, from: active, to: target, handoff: focusedHandoff, ifDeclined: raised, liveness: liveness, startedAt: t0, canContinue: canContinue)
    }

    /// A hand-back starts only with at least this much of the confirmation deadline left, so a begun hand-off has time to finish.
    private static let handBackStartBudget: TimeInterval = 0.5

    /// What the hand-back decision did: issued it, found it not needed or not allowed (used, no request, not another app, too late),
    /// stopped on input, Pause, or a lost permission during its reads, or saw the window or the Space change.
    private enum HandBack { case issued, notNeeded, stopped, place(Failure) }

    /// After arriving by raise / reactivate: confirms under one deadline (1.5 s from arrival) that the requested app is in front with the moved window
    /// focused, runs the final checks, then watches the front app until `settle.followWatch` after arrival. macOS sometimes brings another app
    /// (Finder) forward as the switch completes, and LazySpace may see it only later through the main thread's copy of the front app.
    /// Another app in front on the destination (neither the owner nor LazySpace) after the owner's activation was requested is handed back once
    /// through the reactivation hand-off, whether it is seen while confirming, by the final checks, or during the watch.
    /// Input, Pause, or another stop ends the watch with the confirmed move; while confirming or handing back, it interrupts.
    private func completeFollow(_ wid: CGWindowID, from active: UInt64, to target: UInt64, handoff: Handoff, ifDeclined fallback: Handoff,
                                liveness: Liveness, startedAt t0: Date, canContinue: @escaping () -> Bool) -> DirectOutcome {
        let arrivedAt = now()
        let deadline = arrivedAt.addingTimeInterval(1.5)
        let watchEnd = arrivedAt.addingTimeInterval(settle.followWatch)
        var handBack: Handoff?
        // The hand-off whose request decides confirmation: a declined reactivation falls back to the raise, a declined hand-back to that.
        var base: Handoff { handoff.declined ? fallback : handoff }
        var current: Handoff { handBack.map { $0.declined ? base : $0 } ?? base }
        // The pid confirmed in front with the moved window focused; nil while confirming.
        var confirmed: pid_t?
        func done(stopped: Bool = false) -> DirectOutcome {
            .done(Result(fromSpace: active, toSpace: target, steps: 0, wallMs: now().timeIntervalSince(t0) * 1000, stoppedWhileWatching: stopped))
        }

        // The membership read (taken first) is classified before the Space read after it, as in `finishFollow`.
        func placeFailure(_ membership: [UInt64]) -> Failure? {
            if let failure = Self.membershipFailure(membership, source: active, target: target, confirmed: true) { return failure }
            guard let space = spaces.activeSpace() else { return .activeSpaceUnreadable }
            return space == target ? nil : .drifted(to: space)
        }

        // Hands focus back once when `front` (one sample) is another app on the destination.
        func handBackIfStolen(_ front: pid_t?) -> HandBack {
            guard handBack == nil, let direct, let owner = base.requested, let front, front != owner, front != ownPID else { return .notNeeded }
            // Membership is the slower read; the cheap gates, the place, and the start budget are checked after it.
            let membership = spaces.spaces(for: wid)
            guard canContinue() else { return .stopped }
            if let failure = placeFailure(membership) { return .place(failure) }
            guard liveness.live, deadline.timeIntervalSince(now()) >= Self.handBackStartBudget else { return .notNeeded }
            let attempt = Handoff()
            handBack = attempt
            trace("followRecoverRequested")
            let onlyOnTarget = { [spaces] in spaces.spaces(for: wid) == [target] }
            direct.reactivate(wid, { [self] in
                // Begins only on the destination, with another app still in front and time left.
                guard liveness.live, onlyOnTarget() else { return false }
                let front = frontmostPID()
                return front != nil && front != owner && front != ownPID && canContinue() && spaces.activeSpace() == target
                    && deadline.timeIntervalSince(now()) >= Self.handBackStartBudget && liveness.live
            }, { [spaces] in
                // Finishes only on the destination (the original reactivation may finish on the source).
                liveness.live && onlyOnTarget() && canContinue() && spaces.activeSpace() == target && liveness.live
            }, attempt.note)
            return .issued
        }

        while true {
            if let pid = confirmed {
                // Watching. Input, Pause, or another stop ends the watch with the confirmed move. Membership is the slower read,
                // so the stop, the Space, and the front app are read after it, and nothing returns success on reads taken before it.
                guard canContinue() else { return done(stopped: true) }
                let membership = spaces.spaces(for: wid)
                guard canContinue() else { return done(stopped: true) }
                if let failure = placeFailure(membership) { return canContinue() ? .failed(failure) : done(stopped: true) }
                if let front = frontmostPID(), front != pid, front != ownPID {
                    switch handBackIfStolen(front) {
                    case .issued: confirmed = nil; sleep(0.02); continue
                    case .stopped: return done(stopped: true)
                    case .place(let failure): return canContinue() ? .failed(failure) : done(stopped: true)
                    case .notNeeded: return .failed(.frontUnconfirmed)
                    }
                }
                let left = watchEnd.timeIntervalSince(now())
                if left <= 0 { return done() }
                sleep(min(0.02, left))
                continue
            }
            // Confirming: the requested app in front with the moved window focused (as `waitForHandoff` with a window).
            guard canContinue() else { return .failed(.interrupted) }
            let front = frontmostPID()
            guard spaces.activeSpace() == target else { return .failed(.interrupted) }
            let hand = current
            // With no request left, a window ID unique across apps and a stable front pid confirm it (an AXRaise that took effect late).
            let expectedPID = hand.declined || hand.abandoned ? front : hand.requested
            if let pid = expectedPID, front == pid {
                let focused = direct?.focusedWindow() == wid
                // Input or Space switches during the AX read do not count as success either.
                guard canContinue(), spaces.activeSpace() == target else { return .failed(.interrupted) }
                if focused && frontmostPID() == pid {
                    trace("activationConfirmed")
                    trace("focusConfirmed")
                    settleFor(settle.raiseFollow)
                    guard canContinue() else { return .failed(.interrupted) }
                    switch finishFollow(wid, from: active, to: target, startedAt: t0, canContinue: canContinue) {
                    case .done: confirmed = pid
                    case .failed(.frontUnconfirmed):
                        // Another app may have come forward during the final reads.
                        switch handBackIfStolen(frontmostPID()) {
                        case .issued: sleep(0.02)
                        case .stopped: return .failed(.interrupted)
                        case .place(let failure): return .failed(failure)
                        case .notNeeded: return .failed(.frontUnconfirmed)
                        }
                    case let other: return other
                    }
                    continue
                }
            }
            // While confirming, a stop or another Space interrupts (as the next poll would say), and a membership change is that failure.
            switch handBackIfStolen(front) {
            case .issued: sleep(0.02); continue
            case .stopped, .place(.drifted), .place(.activeSpaceUnreadable): return .failed(.interrupted)
            case .place(let failure): return .failed(failure)
            case .notNeeded: break
            }
            if now() >= deadline { return .failed(.frontUnconfirmed) }
            sleep(0.02)
        }
    }

    /// Final follow check (raise / reactivate and Desktop N alike): read membership, then recheck the cheap gates (interruption, authorization, input) and
    /// the current Space after that read before succeeding. Membership reads can be slow, and input, interruption, or pause during them must not count as success.
    private func finishFollow(_ wid: CGWindowID, from active: UInt64, to target: UInt64, startedAt t0: Date, canContinue: () -> Bool) -> DirectOutcome {
        if let failure = Self.membershipFailure(spaces.spaces(for: wid), source: active, target: target, confirmed: true) { return .failed(failure) }
        let owner = frontmostPID()
        let focused = direct?.focusedWindow() == wid && owner != nil && frontmostPID() == owner
        guard canContinue() else { return .failed(.interrupted) }
        guard let final = spaces.activeSpace() else { return .failed(.activeSpaceUnreadable) }
        if final != target { return .failed(.drifted(to: final)) }
        guard focused else { return .failed(.frontUnconfirmed) }
        return .done(Result(fromSpace: active, toSpace: target, steps: 0, wallMs: now().timeIntervalSince(t0) * 1000))
    }

    /// After reaching the target by shortcut: the `settle.hotkeyFollow` wait and membership / active checks -> raise the carried window ->
    /// observe within 1.5 s that its app is in front, the carried window has focus, and it stays on the target -> recheck membership and authorization, then succeed.
    /// If activation is refused or not observed, `frontUnconfirmed` (the window is on the target and the switch is done; no other moves).
    private func confirmHotkeyFollow(_ wid: CGWindowID, from active: UInt64, to target: UInt64, plan: HotkeyPlan, startedAt t0: Date, gates: Gates) -> DirectOutcome {
        let canContinue = gates.canContinue
        settleFor(settle.hotkeyFollow)
        guard canContinue() else { return .failed(.interrupted) }
        if let failure = Self.membershipFailure(spaces.spaces(for: wid), source: active, target: target, confirmed: true) { return .failed(failure) }
        guard let arrived = spaces.activeSpace() else { return .failed(.activeSpaceUnreadable) }
        if arrived != target { return .failed(.drifted(to: arrived)) }
        plan.report(.arrived)
        guard let direct else { return .failed(.frontUnconfirmed) }
        let liveness = Liveness()
        defer { liveness.live = false }
        let isCurrent = { [spaces] in liveness.live && canContinue() && spaces.activeSpace() == target }
        let raised = Handoff()
        if direct.raise(wid, isCurrent, raised.note) == .refused { return .failed(.frontUnconfirmed) }
        switch waitForHandoff(raised, on: target, window: wid, canContinue: canContinue) {
        case .arrived: break
        case .failed(.activationUnconfirmed), .nothingIssued: return .failed(.frontUnconfirmed)
        case .failed(let failure): return .failed(failure)
        }
        guard canContinue() else { return .failed(.interrupted) }
        return finishFollow(wid, from: active, to: target, startedAt: t0, canContinue: canContinue)
    }

    /// Failure when follow's shortcut stopped. A timeout uses the "sent but unconfirmed" text (the place note says the window is on the target).
    private static func followFailure(_ reason: HotkeyStopped) -> Failure {
        switch reason {
        case .interrupted, .unexpectedSpace: return .interrupted
        case .unconfirmed, .compromised: return .hotkeyUnconfirmed
        case .activeUnreadable: return .activeSpaceUnreadable
        }
    }

    /// Classifies membership read after a direct-path request; nil (fine) when it is the target alone.
    /// Empty: unreadable. Several: where it landed is not stated. One other: a Space other than the target.
    /// The source alone: "unchanged" if the target was never confirmed, "back on the source" (a Space other than the target) if it was.
    static func membershipFailure(_ membership: [UInt64], source: UInt64, target: UInt64, confirmed: Bool) -> Failure? {
        if membership == [target] { return nil }
        if membership.isEmpty { return .membershipUnreadable }
        if membership.count > 1 { return .onSeveralSpaces(membership) }
        if membership == [source], !confirmed { return .moveUnconfirmed }
        return .movedElsewhere(to: membership[0])
    }

    private enum Arrival { case arrived, stillOnSource, interrupted }

    /// Waits until the target is reached. Seeing a Space other than source and target means the user switched, so it interrupts.
    private func waitForArrival(_ target: UInt64, from source: UInt64, within timeout: TimeInterval, canContinue: () -> Bool) -> Arrival {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            guard canContinue() else { return .interrupted }
            switch spaces.activeSpace() {
            case target: trace("arrivalObserved"); return .arrived
            case source: break
            default: return .interrupted
            }
            if now() >= deadline { return .stillOnSource }
            sleep(0.02)
        }
    }

    // MARK: - Internals

    private struct Step { var right: Bool; var expected: UInt64 }

    private func stepPlan(from: UInt64, to: UInt64) -> [Step]? {
        let order = orderedSpaces().map(\.id)
        guard let i = order.firstIndex(of: from), let j = order.firstIndex(of: to) else { return nil }
        if i == j { return [] }
        let right = j > i
        let path = right ? Array(order[(i + 1)...j]) : Array(order[j..<i].reversed())
        return path.map { Step(right: right, expected: $0) }
    }

    private func requireContinuation(_ shouldContinue: () -> Bool) throws {
        if !shouldContinue() { throw Failure.interrupted }
    }

    /// After an interruption, timeout, or transfer failure, adds the place read after release to the result text. Unread items are "unknown". Never claims a return to the source.
    private func notePlace(_ outcome: Swift.Result<Result, Failure>, window: CGWindowID?) {
        guard case .failure(let failure) = outcome, Self.recordsPlace(failure) else { return }
        placeNote = PlaceNote(active: spaces.activeSpace(), window: window.map { spaces.spaces(for: $0) })
    }

    private static func recordsPlace(_ failure: Failure) -> Bool {
        switch failure {
        case .interrupted, .timedOut, .notMoved, .movedElsewhere, .drifted, .notSwitched, .moveUnconfirmed, .onSeveralSpaces, .membershipUnreadable, .activeSpaceUnreadable, .switchUnconfirmed, .routeChanged, .activationUnconfirmed, .hotkeyUnconfirmed, .steppingUnavailable, .frontUnconfirmed: return true
        case .unavailable, .noSuchSpace, .alreadyThere, .otherDisplayNoRoute, .otherDisplayNeedsDirectMove: return false
        }
    }

    /// `active` is the display name from `label`; nil means unread. `window` nil means a switch, so no window sentence. An empty array means unread.
    static func formatPlace(active: String?, window: [String]?) -> String {
        let space = active ?? L(.spaceControlUnknown)
        guard let window else { return Copy.sentenceSeparator + L(.spaceControlCurrentSpace(space)) }
        let owned = window.isEmpty ? L(.spaceControlUnknown) : window.joined(separator: ", ")
        return Copy.sentenceSeparator + L(.spaceControlCurrentSpaceWindow(space, owned))
    }

    public func failureDetail(_ failure: Failure) -> String? {
        guard let placeNote, Self.recordsPlace(failure) else { return nil }
        let active = placeNote.active.map { label($0) }
        let window = placeNote.window.map { $0.map { label($0) } }
        return Self.formatPlace(active: active, window: window)
    }

    struct ResolvedChord: Equatable {
        var key: CGKeyCode
        var modifiers: CGEventFlags
        var arrow: Bool
    }

    /// Left modifiers, pressed in this order. Symbolic hotkeys do not distinguish right modifiers.
    private static let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
    ]
    private static let recognizedFlags: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn,
    ]
    /// Letters, digits, symbols, space, and the extra ISO key. Arrows are separate.
    private static let typingKeyCodes: Set<UInt16> = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13,
        0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D,
        0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x31, 0x32,
    ]
    private static let arrowKeyCodes: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E]
    private static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]
    private static let mediaKeyCodes: Set<UInt16> = [0x48, 0x49, 0x4A]
    private static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
    private static let extendedKeyCodes: Set<UInt16> = [
        0x24, 0x30, 0x33, 0x35, 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
        0x5D, 0x5E, 0x5F, 0x66, 0x68, 0x6E, 0x72, 0x73, 0x74, 0x75, 0x77, 0x79,
    ]

    private enum ShortcutIssue {
        case unread, disabled, unassigned, invalidKey, modifierOnly, shiftOnly, needsModifier
        case capsLock, unknownFlags, fnOnOtherKey, functionKey, mediaKey, extendedKey, conflict

        init(_ issue: SystemSpaceShortcut.Issue) {
            switch issue {
            case .unassigned: self = .unassigned
            case .invalidKey: self = .invalidKey
            case .modifierOnly: self = .modifierOnly
            case .shiftOnly: self = .shiftOnly
            case .needsModifier: self = .needsModifier
            case .capsLock: self = .capsLock
            case .unknownFlags: self = .unknownFlags
            case .fnOnOtherKey: self = .fnOnOtherKey
            case .functionKey: self = .functionKey
            case .mediaKey: self = .mediaKey
            case .extendedKey: self = .extendedKey
            }
        }
    }

    private struct PreparedShortcut {
        var key: UInt16
        /// Validated flags for conflict checks. Keeps the arrows' Fn; separate from the modifier set used when sending.
        var flags: CGEventFlags
        var modifiers: CGEventFlags
        var names: Set<String>
        var arrow: Bool
    }

    private enum PreparedRead {
        case unread
        case disabled
        case unusable(SystemSpaceShortcut.Issue)
        case ready(PreparedShortcut)
    }

    /// 79 is left, 81 right. Only reads and validates (except conflicts); creates no events.
    public func nativeShortcut(right: Bool) -> SystemSpaceShortcut {
        switch readShortcut(right: right) {
        case .unread: return .unread
        case .disabled: return .disabled
        case .unusable(let issue): return .unusable(issue)
        case .ready(let prepared): return .usable(keyCode: prepared.key, modifiers: prepared.names)
        }
    }

    /// The only place an operation reads that direction. Does not go on to conflict checks or event creation.
    private func readShortcut(right: Bool) -> PreparedRead { readShortcut(id: right ? 81 : 79) }

    /// Reads one symbolic hotkey and validates it with `classify` (shared by 79 / 81 and Desktop N's 118-133).
    private func readShortcut(id: Int32) -> PreparedRead {
        switch hotkey(id) {
        case .unknown: return .unread
        case .disabled: return .disabled
        case .enabled(let keyCode, let flags): return classify(keyCode: keyCode, flags: flags)
        }
    }

    private func classify(keyCode: UInt32, flags rawFlags: UInt32) -> PreparedRead {
        if keyCode == 0xFFFF { return .unusable(.unassigned) }
        guard keyCode <= UInt32(UInt16.max) else { return .unusable(.invalidKey) }
        let key = UInt16(keyCode)
        if Self.modifierKeyCodes.contains(key) { return .unusable(.modifierOnly) }
        if Self.functionKeyCodes.contains(key) { return .unusable(.functionKey) }
        if Self.mediaKeyCodes.contains(key) { return .unusable(.mediaKey) }
        if Self.extendedKeyCodes.contains(key) { return .unusable(.extendedKey) }
        let arrow = Self.arrowKeyCodes.contains(key)
        if !arrow, !Self.typingKeyCodes.contains(key) { return .unusable(.invalidKey) }
        let flags = CGEventFlags(rawValue: UInt64(rawFlags))
        if !flags.subtracting(Self.recognizedFlags).isEmpty { return .unusable(.unknownFlags) }
        if flags.contains(.maskAlphaShift) { return .unusable(.capsLock) }
        // NumericPad or Help in the read flags depends on state, so drop it and send nothing.
        if !flags.intersection([.maskNumericPad, .maskHelp]).isEmpty { return .unusable(.unknownFlags) }
        if flags.contains(.maskSecondaryFn), !arrow { return .unusable(.fnOnOtherKey) }
        let modifiers = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if modifiers.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty {
            return .unusable(modifiers.contains(.maskShift) ? .shiftOnly : .needsModifier)
        }
        return .ready(PreparedShortcut(key: key, flags: flags, modifiers: modifiers, names: Self.modifierNames(modifiers), arrow: arrow))
    }

    private static func modifierNames(_ flags: CGEventFlags) -> Set<String> {
        var names = Set<String>()
        if flags.contains(.maskControl) { names.insert("ctrl") }
        if flags.contains(.maskAlternate) { names.insert("alt") }
        if flags.contains(.maskShift) { names.insert("shift") }
        if flags.contains(.maskCommand) { names.insert("cmd") }
        return names
    }

    /// The first sentence of the refusal reason, reused by Settings. Says nothing about whether anything was sent.
    public static func refusalLead(_ issue: SystemSpaceShortcut.Issue, right: Bool) -> String {
        lead(ShortcutIssue(issue), right: right)
    }

    private func refused(_ issue: ShortcutIssue, right: Bool) -> Failure {
        let settings = L(.spaceControlSystemSettingsKeyboardKeyboardShortcuts)
        let tail = L(.spaceControlNothingWasSent(settings))
        return .unavailable(Self.lead(issue, right: right) + Copy.sentenceSeparator + tail)
    }

    private static func lead(_ issue: ShortcutIssue, right: Bool) -> String {
        let name = MacItem.moveSpace(right: right)
        switch issue {
        case .unread:
            return L(.spaceControlCouldNotReadTheMission(name))
        case .disabled:
            return L(.spaceControlTheMissionControlShortcutIs(name))
        case .unassigned:
            return L(.spaceControlTheMissionControlShortcutHas(name))
        case .invalidKey:
            return L(.spaceControlTheKeyForTheMission(name))
        case .modifierOnly:
            return L(.spaceControlTheMissionControlShortcutIsA(name))
        case .shiftOnly:
            return L(.spaceControlTheMissionControlShortcutUses(name))
        case .needsModifier:
            return L(.spaceControlTheMissionControlShortcutDoes(name))
        case .capsLock:
            return L(.spaceControlTheMissionControlShortcutIncludes(name))
        case .unknownFlags:
            return L(.spaceControlTheMissionControlShortcutIncludesFlags(name))
        case .fnOnOtherKey:
            return L(.spaceControlTheMissionControlShortcutUsesFn(name))
        case .functionKey:
            return L(.spaceControlTheMissionControlShortcutUsesA(name))
        case .mediaKey:
            return L(.spaceControlTheMissionControlShortcutUsesAMedia(name))
        case .extendedKey:
            return L(.spaceControlTheMissionControlShortcutUsesAn(name))
        case .conflict:
            return L(.spaceControlTheMissionControlShortcutMatches(name))
        }
    }

    /// Modifiers are pressed while accumulating flags, and after the main key's down/up released in reverse while removing flags. All events are created before pressing.
    /// Modifier keys are created as keyDown, but Core Graphics delivers them as flagsChanged. The default Control+arrow keeps this sequence.
    /// `tag` goes into `eventSourceUserData`. With `checkBeforeRelease` false, keys are released without checking after the main keyDown
    /// (a Desktop N shortcut changes the Space and front when it works, so that is no reason to hold the release). Pressed keys are always released, even on interruption.
    /// `onPosted` runs for each posted event (the tier-0 tap counts whether it observed the whole sequence).
    private func press(_ chord: ResolvedChord, tag: Int64 = SpaceControl.syntheticTag, checkBeforeRelease: Bool = true, shouldContinue: () -> Bool,
                       onPosted: () -> Void = {}, onMainKeyDown: () -> Void = {}) throws {
        let halves = try chordEvents(chord)
        var held: [CGEvent] = []
        func send(_ event: CGEvent) { post(event, tag: tag); onPosted() }
        defer { for event in held.reversed() { send(event) } }
        for (index, half) in halves.enumerated() {
            try requireContinuation(shouldContinue)
            send(half.down)
            held.append(half.up)
            // The last pair is the main key.
            if index == halves.count - 1 { onMainKeyDown() }
            sleep(0.02)
        }
        if checkBeforeRelease { try requireContinuation(shouldContinue) }
        send(held.removeLast())
        sleep(0.02)
        while let up = held.popLast() {
            send(up)
            if !held.isEmpty { sleep(0.02) }
        }
    }

    private func chordEvents(_ chord: ResolvedChord) throws -> [(down: CGEvent, up: CGEvent)] {
        var halves: [(down: CGEvent, up: CGEvent)] = []
        var heldFlags: CGEventFlags = []
        for item in Self.modifierKeys where chord.modifiers.contains(item.flag) {
            heldFlags.insert(item.flag)
            let released = heldFlags.subtracting(item.flag)
            halves.append((try key(item.code, down: true, flags: heldFlags), try key(item.code, down: false, flags: released)))
        }
        var body = heldFlags
        // Physical arrow keys carry Fn and NumericPad; normal keys do not. The default ⌃← / ⌃→ keep this form.
        if chord.arrow { body.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        halves.append((try key(chord.key, down: true, flags: body), try key(chord.key, down: false, flags: body)))
        return halves
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw Failure.unavailable(L(.spaceControlCouldNotCreateTheKeyboard))
        }
        event.flags = flags
        return event
    }

    private func mouse(_ type: CGEventType, at p: CGPoint) -> CGEvent? {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    }

    private func post(_ event: CGEvent?, tag: Int64 = SpaceControl.syntheticTag) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        postEvent(event)
    }
}

/// A copy of the front app's pid, updated by `NSWorkspace.didActivateApplicationNotification` (delivered on the main thread) and read under a lock.
/// The first value is read from `frontmostApplication` on the main thread (queued to main if created elsewhere),
/// so the operations queue never reads AppKit state directly while waits and deadlines stay with it.
final class FrontmostApplication {
    static let shared = FrontmostApplication()

    private let lock = NSLock()
    private var value: pid_t?
    private var token: NSObjectProtocol?

    private init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            // Apps missing from LaunchServices arrive with pid -1, so resolve to the pid of the app with focus.
            self?.set(FrontmostApp.resolve(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication))
        }
        let publish: () -> Void = { [weak self] in self?.set(FrontmostApp.pid()) }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func set(_ pid: pid_t?) { lock.lock(); value = pid; lock.unlock() }

    var pid: pid_t? { lock.lock(); defer { lock.unlock() }; return value }
}
