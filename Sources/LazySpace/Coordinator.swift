import AppKit
import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations
import Settings

protocol CoordinatorWindowSystem: WindowSystem {
    var input: InputMonitor { get }
    var spaceObservationAvailable: Bool { get }
    /// Whether input can be observed. Without it, collisions between user actions and automatic arrangement cannot be prevented.
    var inputObservationAvailable: Bool { get }
    /// Work area of the display showing the current Space.
    func currentWorkArea() -> CGRect
    /// Title of one observed window, without querying every app.
    func windowTitle(_ id: WindowID) -> String?
    /// Only whether Spaces exist; no window lists or membership. nil when the list cannot be read.
    func existingSpaceIDs() -> Set<UInt64>?
    /// Whether the process has exited. Windows of a quit app never come back, so their disappearance is not waited for.
    func processExited(_ pid: Int32) -> Bool
    // Arranging Spaces other than the current one; unused where unsupported.
    /// Spaces the window belongs to (SkyLight); empty means undecided, nil when unobservable.
    func spacesOf(_ id: WindowID) -> [UInt64]?
    func spaceDisplay(_ space: UInt64) -> SpaceDisplay?
    func snapshot(ofHiddenSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot
    func snapshot(ofShownSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot
    func readFrame(inSpace id: WindowID, space: UInt64, deadline: Date) -> FrameRead
    func writeFrame(inSpace id: WindowID, space: UInt64, frame: CGRect, deadline: Date, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// Full-window-list entries (including off-screen and other Spaces); nil if the list is unavailable. Missing windows have no key.
    func windowRecords(_ ids: Set<WindowID>) -> [WindowID: CGWindowRecord]?
    /// One window's entry without reading the full list; nil when not listed or unreadable.
    func windowRecord(_ id: WindowID) -> CGWindowRecord?
    /// Whether the app is hidden; nil when unknown.
    func appHidden(pid: Int32) -> Bool?
    /// Whether an observed window is minimized; nil if not read by the deadline.
    func readMinimized(_ id: WindowID, deadline: Date) -> Bool?
    /// Whether Stage Manager is on (off when the key is absent).
    var stageManagerOn: Bool { get }
    /// Whether several displays share one Space ("Displays have separate Spaces" off).
    var displaysShareOneSpace: Bool { get }
    /// Whether any mouse button is held (left, right, middle, or another).
    var anyMouseButtonHeld: Bool { get }
    /// Frames and work areas of the connected displays.
    func displayFrames() -> [(frame: CGRect, workArea: CGRect)]
    /// Reads the focused window with a short deadline, so acceptance (shortcuts, menu, CLI) never blocks the main thread for long.
    func focusedWindowID(within timeout: TimeInterval) -> WindowID?
    /// Bounded observation (classifying new windows). No AX request waits beyond the time left; apps not finished go into `unobservedApps`.
    func snapshot(limitingTo ids: Set<WindowID>, deadline: Date) -> Snapshot
    /// Dialog-region evidence (one window). A missing attribute counts as known; any unreadable attribute gives nil.
    func dialogEvidence(pid: Int32, window id: WindowID, deadline: Date) -> DialogEvidence?
}

extension CoordinatorWindowSystem {
    func focusedWindowID(within timeout: TimeInterval) -> WindowID? { focusedWindowID() }
    func processExited(_ pid: Int32) -> Bool { false }
    func spacesOf(_ id: WindowID) -> [UInt64]? { nil }
    func spaceDisplay(_ space: UInt64) -> SpaceDisplay? { nil }
    func snapshot(ofHiddenSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        Snapshot(trusted: axTrusted, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
    }
    func snapshot(ofShownSpace space: UInt64, windows ids: Set<WindowID>, deadline: Date) -> Snapshot {
        Snapshot(trusted: axTrusted, spaceID: space, workArea: .zero, windows: [], spaceObservationAvailable: false)
    }
    func readFrame(inSpace id: WindowID, space: UInt64, deadline: Date) -> FrameRead { .failed(OtherSpaceWindowSystem.refusal) }
    /// Defaults to "none", so vanished windows are treated as closed as before.
    func windowRecords(_ ids: Set<WindowID>) -> [WindowID: CGWindowRecord]? { [:] }
    func windowRecord(_ id: WindowID) -> CGWindowRecord? { nil }
    func appHidden(pid: Int32) -> Bool? { nil }
    func readMinimized(_ id: WindowID, deadline: Date) -> Bool? { readWindowState(id, .minimized) }
    func snapshot(limitingTo ids: Set<WindowID>, deadline: Date) -> Snapshot { snapshot(limitingTo: ids) }
    /// Defaults to "unknown" (never enters the region).
    func dialogEvidence(pid: Int32, window id: WindowID, deadline: Date) -> DialogEvidence? { nil }
    func writeFrame(inSpace id: WindowID, space: UInt64, frame: CGRect, deadline: Date, shouldContinue: @escaping () -> Bool) -> WriteResult {
        .rejected(OtherSpaceWindowSystem.refusal)
    }
}

extension MacWindowSystem: CoordinatorWindowSystem {
    var inputObservationAvailable: Bool { input.mode != .unavailable }
    var stageManagerOn: Bool {
        (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) ?? false
    }
    var displaysShareOneSpace: Bool { !NSScreen.screensHaveSeparateSpaces && NSScreen.screens.count > 1 }
    var anyMouseButtonHeld: Bool { NSEvent.pressedMouseButtons != 0 }
    func displayFrames() -> [(frame: CGRect, workArea: CGRect)] { Screens.all().map { ($0.frame, $0.workArea) } }
    func processExited(_ pid: Int32) -> Bool { kill(pid, 0) != 0 && errno == ESRCH }
    func appHidden(pid: Int32) -> Bool? { NSRunningApplication(processIdentifier: pid)?.isHidden }
}

/// State shown to the user. Missing permission, Pause, and failures are kept distinct.
struct AppStatus: Codable, Equatable {
    enum Availability: String, Codable {
        case needsSetup
        case manualOnly
        case paused
        case automatic
    }
    enum Progress: String, Codable {
        case idle
        case running
        case pausing // stopping (waiting to confirm issued operations)
    }
    var availability: Availability
    var availabilityReason: String
    var manualAvailable: Bool
    var manualReason: String
    var autoAvailable: Bool
    var autoReason: String
    /// Whether the current Space has saved layout intent (automatic arrangement handles only such Spaces).
    var currentSpaceManaged: Bool
    var trusted: Bool
    var spaceObservation: Bool
    var inputObservation: String
    var paused: Bool
    var progress: Progress
    var progressText: String
    var waiting: [WindowID]
    var floating: [WindowID]
    var zoomed: WindowID?
    var lastRefusal: String?
    var configPath: String
    var configError: String?
    var configNotes: [String] = []
    var focusedWindow: WindowID?
    var lastResult: OperationResult?
    var version: String
    /// The current binding mode (default "main").
    var mode: String
    /// Declared mode names (including main).
    var modes: [String]
    /// Open at Login state (a sentence for the user).
    var loginItem: String
    var loginItemEnabled: Bool
    /// The queue and mouse handling are free. Stability after reobserving is confirmed by wait-settled's settlement.
    var idle: Bool = true
    /// Automatic arrangement is stopped for the current Space only; separate from the global pause.
    var currentSpaceAutoPaused: Bool = false
    var currentSpaceID: UInt64? = nil
    /// Whether LazySpace can use macOS "Switch to Desktop N" (a `lazyspace status` line); nil without Space observation.
    var desktopShortcuts: String? = nil
    /// State of "Move left/right a Space" (`lazyspace status`); nil without Space observation.
    var leftShortcut: String? = nil
    var rightShortcut: String? = nil
    /// Guidance when the keyboard shortcut settings file was saved after the Dock started (`DockShortcutFreshness`); nil otherwise or when unknown.
    var dockShortcutFreshness: String? = nil
    /// The dialog-region setting and the current Space's region (`lazyspace status`).
    var dialogRegion: String = ""
    /// Filled in by `AppDelegate` from the updater; nil when there is none or no update is available.
    var availableUpdate: UpdateOffer? = nil
}

protocol SpaceListing {
    func orderedSpaces() -> [(id: UInt64, type: Int32?)]
    func neighbor(offset: Int) -> UInt64?
    /// uuids of the current display's Spaces (excluding duplicated or missing ones across displays); nil when unreadable.
    func currentDisplayUUIDs() -> [UInt64: String]?
    /// Identifier of the display with the current Space.
    func currentDisplayIdentifier() -> String?
    /// One read used for resolving (order, uuids, display, current Space); nil when unreadable.
    func spaceSnapshot() -> SpaceSnapshot?
}

/// Space list built from one read, used for resolving and rechecking. `order`, `desktops`, and `display` are the current display's;
/// `uuids` (nil when unreadable) and `groups` cover every display. `groups` is empty with one display (`DisplayGroups.make`).
struct SpaceSnapshot: Equatable {
    var order: [UInt64]
    var desktops: [UInt64]
    var uuids: [UInt64: String]?
    var display: String?
    var active: UInt64?
    var groups: [DisplayGroup] = []

    /// The display holding the Space: its identifier, order, and desktops. The current display unless a group holds it.
    func holder(of id: UInt64) -> (display: String?, order: [UInt64], desktops: [UInt64])? {
        if order.contains(id) { return (display, order, desktops) }
        guard let group = groups.first(where: { $0.records.contains { $0.id == id } }) else { return nil }
        return (group.display, group.records.map(\.id), group.desktops)
    }
}

extension SpaceListing {
    func currentDisplayUUIDs() -> [UInt64: String]? { nil }
    func currentDisplayIdentifier() -> String? { nil }
    /// Default (test arrangement): assembled from separate reads. The product's SpaceControl builds it from one read.
    func spaceSnapshot() -> SpaceSnapshot? {
        let order = orderedSpaces()
        let numbers = SpaceObserver.desktopNumbers(order)
        return SpaceSnapshot(order: order.map(\.id), desktops: order.compactMap { numbers[$0.id] == nil ? nil : $0.id }, uuids: currentDisplayUUIDs(), display: currentDisplayIdentifier(), active: nil)
    }
}

/// The front window visible when the menu opened. Actions are never retargeted to another window, process, or Space.
struct MenuWindowTarget: Equatable {
    var window: WindowID
    var pid: Int32
    var spaceID: UInt64
}

/// A Space resolved at acceptance (id, uuid, and display from the same read). Carried through the queue and checked right before running.
struct ResolvedSpace: Equatable {
    var id: UInt64
    /// The OS's unique uuid (nil if none).
    var uuid: String?
    var display: String?
    var isDesktop: Bool
    /// On a display other than the current Space's (only the direct routes reach it).
    var otherDisplay: Bool = false
}

private struct SpaceControlListing: SpaceListing {
    let control: SpaceControl
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { control.orderedSpaces() }
    func neighbor(offset: Int) -> UInt64? { control.neighbor(offset: offset) }
    func currentDisplayUUIDs() -> [UInt64: String]? { control.currentDisplayUUIDs() }
    func currentDisplayIdentifier() -> String? { control.currentDisplayIdentifier() }
    func spaceSnapshot() -> SpaceSnapshot? {
        control.displaySnapshot().map { snapshot in
            let numbers = SpaceObserver.desktopNumbers(snapshot.order)
            return SpaceSnapshot(order: snapshot.order.map(\.id), desktops: snapshot.order.compactMap { numbers[$0.id] == nil ? nil : $0.id },
                                 uuids: snapshot.uuids, display: snapshot.display, active: snapshot.active,
                                 groups: DisplayGroups.make(snapshot.displays, names: DisplayGroups.screenNames()))
        }
    }
}

/// The single operation path shared by the UI and CLI. OS writes go only through ArrangeOperation -> MacWindowSystem.
final class Coordinator {
    static let shared = Coordinator()

    let system: CoordinatorWindowSystem
    private let takeCensus: (UInt64?) -> Census
    /// Windows `windowsOnOtherSpaces` confirmed on the current Space, with the Space and frame at that time. Only the operations queue touches it.
    private var localWindows: [WindowID: (space: UInt64, bounds: CGRect)] = [:]
    private let takeOverview: () -> SpaceOverview?
    /// Raw window list (all displays, all Spaces) for judging direct-switch app candidates.
    private let takeInventory: () -> AppWindowInventory?
    let control: OperationControl
    let knowledge: ConstraintKnowledge
    let store: StateStore
    private(set) var state: PersistedState
    private let queue = DispatchQueue(label: "jp.lazyspace.operations", qos: .userInitiated)
    private let queueToken = DispatchSpecificKey<UInt8>()
    /// When set, the operation body runs before acceptance returns. Production leaves this false.
    var completeSynchronouslyForTesting = false
    var operationsQueue: DispatchQueue { queue }
    let lock = NSLock()
    /// Copies the finished value into the receipt registry. Must not call back into Coordinator.
    var onTerminalResult: ((OperationResult) -> Void)?
    /// Called after an operation ID exists and before its body is enqueued. Must not call back into Coordinator.
    var onOperationID: ((String) -> Void)?
    private var running: String?
    private var progressText = ""
    private var cachedFocusedWindow: WindowID?
    private var focusRefreshInFlight = false
    private var lastFocusRefresh = Date.distantPast
    /// Touched by config loading, main-thread acceptance, and operations-queue execution; passed under the same lock as `config`.
    private var limitsStore = OperationLimits()
    var limits: OperationLimits {
        get { configLock.lock(); defer { configLock.unlock() }; return limitsStore }
        set { configLock.lock(); limitsStore = newValue; configLock.unlock() }
    }
    /// Written by config loading, read by main and the operations queue; values are handed over under this dedicated lock.
    private let configLock = NSLock()
    private var configStore = Config()
    private(set) var config: Config {
        get { configLock.lock(); defer { configLock.unlock() }; return configStore }
        set { configLock.lock(); configStore = newValue; configLock.unlock() }
    }
    private var configErrorStore: String?
    private var configNotesStore: [String] = []
    private var quietIntervalStore: TimeInterval = 0.6
    /// Written by config loading, read by main and the operations queue; passed under the same lock as `config`.
    private(set) var configError: String? {
        get { configLock.lock(); defer { configLock.unlock() }; return configErrorStore }
        set { configLock.lock(); configErrorStore = newValue; configLock.unlock() }
    }
    private(set) var configNotes: [String] {
        get { configLock.lock(); defer { configLock.unlock() }; return configNotesStore }
        set { configLock.lock(); configNotesStore = newValue; configLock.unlock() }
    }
    /// The configuration file. LAZYSPACE_CONFIG points elsewhere (for checks and switching configurations).
    let configURL: URL
    static var defaultConfigURL: URL {
        if let override = ProcessInfo.processInfo.environment["LAZYSPACE_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lazyspace/config.toml")
    }
    /// Called when the configuration changes (to re-register shortcuts). Main thread.
    var onConfigChange: ((Config) -> Void)?
    /// Read errors and non-fatal notes; nil when there are neither. Does not reload the draft or stop recording.
    var onConfigStatus: ((String?) -> Void)?
    /// Called when the binding mode changes (to swap shortcuts). Main thread.
    var onModeChange: ((String) -> Void)?
    /// The current binding mode.
    private(set) var mode: String = Config.mainModeName
    /// The Space last seen, for the Space-change hook.
    private var hookSpaceID: UInt64?
    /// The previous Space (`space back` target).
    private var previousSpaceID: UInt64?
    /// Space switching and window moves (synthetic input). Created only with startServices.
    private var spaceControl: SpaceControl?
    /// Tests substitute a listing without installing a live Space switcher.
    var spaceListingOverride: SpaceListing?
    /// Gates for one move: the operation gate and the caller's checks inside the move.
    struct MoveGates {
        var shouldContinue: () -> Bool
        var hooks: SpaceControl.MoveHooks
    }
    typealias SpaceMover = (CGWindowID, CGRect, UInt64, MoveGates) -> Swift.Result<SpaceControl.Result, SpaceControl.Failure>
    /// Tests substitute the direct move or drag with following (`move-to-space --follow`).
    var spaceMoverOverride: SpaceMover?
    /// Send gates: right before issuing (including being on the source Space), and while waiting after issuing (source Space not required).
    struct SendGates {
        var beforeIssue: () -> Bool
        var afterIssue: () -> Bool
        init(beforeIssue: @escaping () -> Bool, afterIssue: @escaping () -> Bool) { self.beforeIssue = beforeIssue; self.afterIssue = afterIssue }
        init(_ both: @escaping () -> Bool) { beforeIssue = both; afterIssue = both }
    }
    typealias SpaceSender = (CGWindowID, UInt64, SendGates) -> SpaceControl.SendOutcome
    /// Tests substitute the default `move-to-space` send (window, destination, should continue). Setting it also means the direct move exists.
    var spaceSenderOverride: SpaceSender?
    /// For tests: whether the direct move (bridged move) is available (the product uses SpaceControl's direct path).
    var sendAvailableOverride: Bool?
    typealias SpaceSwitcher = (UInt64, SpaceControl.SwitchPlan, @escaping () -> Bool) -> Swift.Result<SpaceControl.Result, SpaceControl.Failure>
    /// Tests substitute the Space switch of `space N` (target, plan, should continue).
    var spaceSwitcherOverride: SpaceSwitcher?
    /// Tier-0 reads (macOS Desktop N shortcuts). Replaced in tests (the product uses SpaceControl).
    var desktopShortcutSourceOverride: DesktopShortcutSource?
    /// Number of physical displays. Replaced in tests.
    var screenCount: () -> Int = { Screens.all().count }
    /// The Dock's pid. Replaced in tests.
    var dockProcessID: () -> pid_t? = { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first { $0.processIdentifier > 0 }?.processIdentifier }
    /// "Automatically rearrange Spaces based on most recent use". Replaced in tests.
    var reordersByRecentUse: () -> Bool = { SpaceOverview.dockReordersByRecentUse() }
    /// Windows of sends with uncertain results (`SendHold`). Only the operations queue touches it.
    private var sendHolds: [WindowID: SendHold] = [:]
    /// Pending arrivals of sent windows (destination Space uuid -> window -> generation), inserted without the arrival dwell only when that Space is shown. Operations queue.
    private var pendingArrivals: [String: [WindowIdentity: UInt64]] = [:]
    /// Windows kept out of every placement path (reconciling sends, rule windows being classified or sent) and why. Read under lock (manual arrangement reads from main).
    private var routingExcluded: [WindowID: String] = [:]
    /// Apps whose classification reads were slow (pid -> not read until this time). Operations queue.
    private var classificationBackoffUntil: [Int32: Date] = [:]
    /// Number of app activations (front-restore gate: no restoration if another activation happened after acceptance). Replaced in tests.
    var activationCount: () -> UInt64 = { ActivationCounter.shared.count }
    /// Tracking of new windows for `action = "space"` rules. Only the operations queue touches it.
    private var router = WindowRouter()
    /// Assessments of dialog-region candidates and members. Only the operations queue touches it.
    private var regionObservations: [WindowID: RegionObservation] = [:]
    /// Ledger of placed positions (window -> owner, written position, input count at write, count, differing frame being checked). Read and written under lock.
    private var regionLedger: [WindowID: RegionLedgerEntry] = [:]
    /// Windows that refused position writes or could not be read back are retried after an interval (window -> owner, next allowed time, failures). Read and written under lock.
    private var regionRetryAfter: [WindowID: (owner: RegionOwner, until: Date, failures: Int)] = [:]
    /// Starting point of the region assessment read order, rotated each time so unreadable windows never use up every read. Operations queue.
    private var regionReadCursor = 0
    /// Windows kept out of the region until they close (window -> owner). Read and written under lock.
    private var regionExcluded: [WindowID: RegionOwner] = [:]
    /// Per Space, the region edge last used and when it switched to it (memory only). Read and written under lock.
    private var regionEdgeMemory: [String: (edge: DialogRegion.Edge, changedAt: Date)] = [:]
    /// Windows assessed standard or ineligible last time (window -> pid), used by focus and border decisions. Read and written under lock.
    private var regionRuledOut: [WindowID: Int32] = [:]
    /// Whether the app is regular (nil when unreadable). Replaced in tests.
    var isRegularApp: (Int32) -> Bool? = { pid in NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy == .regular && !$0.isTerminated } }
    /// Cached process launch times (window identity). Operations queue.
    private var processStarts: [Int32: Date?] = [:]
    /// Number of configuration reloads (under lock). An accepted send is not issued after a reload.
    private(set) var configGeneration: UInt64 = 0
    /// The app's bundle identifier (replaced in tests).
    var appBundleID: (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    /// For tests: called with the environment each time `exec-on-window-sent` would run (even without a configured hook).
    var windowSentObserver: (([String: String]) -> Void)?
    /// Clock for send reconciliation and classification (replaced in tests).
    var routingClock: () -> Date = Date.init
    /// Clock for observation retry intervals (replaced in tests).
    var backoffClock: () -> Date = Date.init
    /// Process launch time (window identity; replaced in tests).
    var processStartTime: (Int32) -> Date? = { DockShortcutFreshness.Readers.system.startTime($0) }
    /// For tests: called each time the Space-change hook would run (even without a configured hook).
    var spaceChangeHookObserver: ((UInt64?, UInt64) -> Void)?
    /// For tests: the pass-through tap (the product uses SpaceControl's).
    var passThroughTapOverride: PassThroughTap?
    /// Whether the keyboard shortcut settings file was saved after the Dock started (read-only). Replaced in tests.
    var dockShortcutFreshness: () -> DockShortcutFreshness = { DockShortcutFreshness.read() }
    /// Pass-through suppression and arrival confirmation records. Touched only under `lock`.
    private var desktopHotkeys = HotkeyMemory()

    /// Automatic start of an unstarted Space: from one standard window, once input is quiet (with a deadline).
    private var pendingAutoStart: (spaceKey: String, front: WindowID, ids: Set<WindowID>, generation: UInt64, until: Date)?

    // Automatic arrangement
    private var autoTimer: DispatchSourceTimer?
    /// Whether input observation and the automatic loop run. Not in tests.
    private var servicesStarted = false
    /// When input observation was last restarted. If launched before permission, it is recreated after permission is granted.
    private var lastInputRestart = Date.distantPast
    /// When the current Space was reached. Right after arriving or while passing through, arrival is no reason to move windows.
    private var spaceArrivedAt = Date.distantPast
    let arrivalDwell: TimeInterval = 1.0
    private var nextTickDeadline: DispatchTime = .distantFuture
    /// After an AX hint, observe at a short interval until this time.
    private var wakeUntil: DispatchTime = .now()
    private var wake: WakeObserver?
    /// Window IDs known from kAXWindowCreated, to skip one stability check, with the time of the announcement.
    /// Written on main, read and consumed on the operations queue, under `lock`.
    private var announcedWindows: [WindowID: Date] = [:]
    /// An announcement older than this no longer shortens ticks or skips the second census.
    static let announcementLifetime: TimeInterval = 1
    /// How long a window removed from the layout keeps its place to return to.
    static let departureMemory: TimeInterval = 180
    var departureClock: () -> Date = Date.init
    var announcementClock: () -> Date = Date.init
    var displayClock: () -> Date = Date.init
    /// User commands received while busy. Repeated presses of the same kind merge into one. Read only under the lock.
    private var userQueue = UserWorkQueue()
    /// Identity of the configuration file last seen by `checkConfigFile`, and when it was seen. Only the operations queue touches it.
    private var lastConfigFingerprint: [Int]?
    private var configCheckedAt = Date.distantPast
    private var baseline: Census?
    /// The previous tick's observation. No decisions until the set is the same twice in a row (avoiding Space switches and windows being created).
    private var lastSeen: Census?
    private var lastInputCount: UInt64 = 0
    private var lastInputChange = Date.distantPast
    /// Per Space, standard windows waiting because they could not join the layout. Read and written only under the lock.
    private var waitingBySpace: [String: Set<WindowID>] = [:]
    /// The current Space's waiting windows. Call from outside the lock.
    var waiting: Set<WindowID> {
        let key = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock(); defer { lock.unlock() }
        return waitingBySpace[key] ?? []
    }
    /// Frames of windows that were not tiling targets; not reconsidered while the frame stays the same. Never a reason to remove from the layout.
    /// Only windows AX says are not standard; rule-excluded windows are not included (so they can return once the rule is removed).
    private var notTileable: [WindowID: CGRect] = [:]
    /// Windows that were not standard in the latest AX query; not queried again while the frame stays the same.
    private var lastUnclassified: [WindowID: Unclassified] = [:]
    private struct Unclassified {
        var frame: CGRect
        /// The title when a title-conditioned rule excluded it; reconsidered when it changes.
        var title: String?
    }
    /// Automatic integration failure counts. Read only under the lock.
    private var integrateLedger = IntegrationRetryLedger()
    /// Retry intervals for windows missing from observation, counted apart from failures. Read only under the lock.
    private var observationBackoff = ObservationBackoff()
    /// Redistribution for departed managed windows deferred because, for example, the button was held on arrival. Read and written on the operations queue.
    private var pendingDepartedRefit: (spaceKey: String, generation: UInt64)?
    /// Per Space, automatic fits (redistribution, display or launch fit) in a row that wrote nothing because an app did not answer, and when the next is due.
    /// Operations queue.
    private var unansweredFits: [String: (attempts: Int, notBefore: Date)] = [:]
    /// Windows a reclaim left out because their app did not answer. They are not polled: `placeMissing` reads one again only after a change on its Space
    /// (a window opening or closing, the front window changing), as AeroSpace restores such a window on the next event, until it rejoins a layout or
    /// `forgetClosedTrackedWindows` confirms it closed. Under the lock.
    private var reclaimedWindows: Set<WindowID> = []
    /// The window set and front window when reclaimed windows were last released for a look. Operations queue.
    private var reclaimLook: (front: WindowID?, windows: Set<WindowID>)?
    var fitRetryClock: () -> Date = Date.init
    /// Hidden Spaces whose managed windows SkyLight confirmed departed. The rest is redistributed while the user is on another Space.
    /// Read and written on the operations queue.
    private struct HiddenRefit {
        var departed: Set<WindowID>
        var attempts: Int
        var notBefore: Date
        var deadline: Date
    }
    private var hiddenRefits: [String: HiddenRefit] = [:]
    /// Departures out of retries. Not tried again for the same departure until returning to that Space or the window returning there. Operations queue.
    private var hiddenRefitExhausted: [String: Set<WindowID>] = [:]
    /// Windows a confirmed send put on a Space another display is showing. Each joins that Space's layout while it stays shown (`auto-arrive-shown`).
    /// Operations queue.
    private struct ShownArrival {
        var identity: WindowIdentity
        var space: UInt64
        var display: String
        var generation: UInt64
        var attempts: Int
        var notBefore: Date
        var deadline: Date
    }
    private var shownArrivals: [WindowID: ShownArrival] = [:]
    /// Windows on the current Space already checked for belonging to another Space's layout. Forgotten on each arrival. Operations queue.
    private var departureChecked: Set<WindowID> = []
    /// Spaces where a hidden redistribution stopped partway after writing some windows; redistributed on return. Read under the lock.
    private var hiddenRefitDirty: Set<String> = []
    /// Managed windows gone from the on-screen list but not yet confirmed closed, moved, or minimized, with when they first went missing.
    /// Meanwhile they stay in the layout (for windows briefly missing from the list, such as right after a drag). Operations queue.
    private var removalHolds: [WindowID: Date] = [:]
    /// A Space where redistribution was deferred on arrival because a managed window could not be confirmed. Its automatic arrangement stops until confirmed. Operations queue.
    private var removalGate: String?
    /// Limit for waiting on unconfirmed windows. Past it, redistribute without treating them as closed (focus does not move).
    let removalHold: TimeInterval = 1.0
    /// Attempts at redistributing to repair partial writes during this arrival. Operations queue.
    private var dirtyRepairs: [String: Int] = [:]
    /// The window carried by move-to-space; on the arrived Space it joins the layout without the arrival dwell (with a deadline).
    private var expectedArrival: (window: WindowID, spaceID: UInt64, generation: UInt64, until: Date)?
    /// Focused window in the previous observation, used to decide when to clear failure records.
    private var lastFocusForFailures: WindowID?
    /// CGWindowList front window when that focus was read. Even if AX disagrees, focus is not reread until the front changes.
    private var lastFrontForFailures: WindowID?
    /// After an AX hint or a click, reread focus once even with the same front window. Read and written on the operations queue.
    private var focusReadRequested = false
    /// Per Space, actual frames from the last completed operation, used to detect mouse edits.
    private var lastPlans: [String: [WindowID: CGRect]] = [:]
    /// The left button was held; after release, frame changes during the hold are adopted once.
    private var mouseHeld = false
    /// A mouse edit not yet adopted.
    private var pendingMouseEdit = false
    /// The post-drag quiet time other decisions wait for; it ends when input has been quiet for `quietInterval`, even if the edit was adopted earlier.
    private var dragQuietPending = false
    /// After an actual drag (not a click), the managed windows' bounds read on a tick after the release; an equal later read adopts the edit early.
    private var mouseEditSample: (bounds: [WindowID: CGRect], at: Date)?
    private var earlyMouseEdit = false
    /// Mouse-down count when the drag ended: any later press (a click, a double-click zoom) ends the early path.
    private var dragPresses: UInt64 = 0
    /// The Space the pending mouse edit belongs to; it never applies to another Space.
    private var mouseEditSpace: String?
    /// A still sample gave nothing to adopt early; short ticks stop until the bounds change again.
    private var earlyMouseEditDeclined = false
    /// Whether no window of these apps reported a move or resize since the date; nil when an app has no attached observer (no evidence).
    var geometryQuiet: (Set<Int32>, Date) -> Bool? = { _, _ in nil }
    /// Frames observed by the previous and current ticks. Drift is rewritten only after frames stop. Read on the operations queue.
    private var driftReference: [WindowID: CGRect] = [:]
    private var lastTickBounds: [WindowID: CGRect] = [:]
    private var lastCompletedMouseDrags: UInt64 = 0
    /// Per Space, how many times drift from the plan was rewritten; reset to 0 for that Space once it matches.
    private var reconcileAttempts: [String: Int] = [:]
    /// When invisible waiting, floating, or zoomed windows were last checked for disappearance against the full window list.
    private var lastAliveSweep = Date.distantPast
    /// Frames right after a correction that wrote nothing; the correction is not redone while they stay the same.
    private var noopReconcileBounds: [String: [WindowID: CGRect]] = [:]
    /// Single-window correction attempts. Not reset when other operations finish; reset only when the window or work area changes.
    /// Attempts for one window in one tiling area; another display or strip starts a new count.
    private struct SoloFillAttempt: Equatable {
        var id: WindowID
        var tiles: CGRect
        var count: Int
    }
    private var soloFillAttempts: [String: SoloFillAttempt] = [:]
    /// A cap and the tiling area in which the window asked for that whole area; the same pair is never tried again.
    /// Another display, or a strip that changes the tiling area, is a new pair.
    private struct SoloProbe: Equatable {
        var cap: CGSize
        var tiles: CGRect
    }
    private var soloProbed: [WindowID: SoloProbe] = [:]
    private var runningKind: String?
    /// The layout right before a window left the tree, remembered for a few minutes; if the same ID returns, it goes back to its place.
    private struct Departure {
        var home: Layout
        var at: Date
    }
    private var departures: [WindowID: Departure] = [:]
    private var lastWorkAreas: [CGRect]?
    /// When the display setup (work areas of all displays) last changed. Operations queue.
    private var displayChangedAt = Date.distantPast
    /// How long the setup must stay unchanged after a display change before the current Space is refit.
    var displaySettleInterval: TimeInterval = 2
    /// Spaces not yet fit to the new work area after a display change or launch, and how many attempts ended without fitting. Read and written under lock.
    private var displayRefitPending: Set<String> = []
    private var displayRefitFailures: [String: Int] = [:]

    /// Result of a redistribution after a display change. Done once complete. If only user input, pause, or a Space change stopped it,
    /// it is retried on the next quiet observation (not counted). Otherwise it gives up after 3 unfinished tries. Operations queue.
    private func noteDisplayRefit(_ result: OperationResult, spaceKey: String) {
        lock.lock(); let empty = state.layouts[spaceKey]?.windowIDs.isEmpty ?? true; lock.unlock()
        // A layout with no window left has nothing to fit, which is done too; an unreadable window list proves nothing and is tried again.
        let nothingLeft = result.outcome == .nothingToDo && result.stopReason == nil && empty
        if !nothingLeft, case .retry = unansweredStep(after: result, spaceKey: spaceKey) { return }
        lock.lock(); defer { lock.unlock() }
        if result.outcome == .complete || nothingLeft {
            displayRefitPending.remove(spaceKey)
            displayRefitFailures[spaceKey] = nil
            return
        }
        switch result.stopReason {
        case .userInput?, .cancelled?, .paused?, .spaceChanged?: return
        default:
            displayRefitFailures[spaceKey, default: 0] += 1
            if displayRefitFailures[spaceKey]! >= 3 { displayRefitPending.remove(spaceKey); displayRefitFailures[spaceKey] = nil }
        }
    }
    private(set) var quietInterval: TimeInterval {
        get { configLock.lock(); defer { configLock.unlock() }; return quietIntervalStore }
        set { configLock.lock(); quietIntervalStore = newValue; configLock.unlock() }
    }
    let tickInterval: TimeInterval = 0.5
    /// Short interval used only right after an observed change (stability checks of the window set do not wait a full cycle).
    let fastTickInterval: TimeInterval = 0.15
    /// Per-Space focus history (newest first, up to 8), built from CGWindowList front windows. For focus-back.
    private var focusHistory: [String: [WindowID]] = [:]
    /// The Space where AX elements were retained once after arriving and settling. Direct switches and hidden-Space writes use elements from when it was visible.
    private var elementsRetainedOn: UInt64?
    /// Per-Space layout intent history (newest first, up to 20) for undo. Within the login session only.
    private var layoutHistory: [String: [Layout]] = [:]

    /// Called on the main thread when state changes.
    var onChange: (() -> Void)?
    /// Called on the main thread when Accessibility permission changes.
    var onTrustChange: ((Bool) -> Void)?
    /// Region: time before a never-front candidate enters. Windows an app opens on its own often resize or close within seconds.
    var regionUnseenDelay: TimeInterval = 5
    /// Windows that have been in front on the current Space. Only the operations queue touches it.
    private var regionSeenFront: Set<WindowID> = []
    /// Permission last read. Read at launch, then touched only on the operations queue.
    private var lastTrusted: Bool
    /// Focus border position (CGWindowList bounds, top-left origin); nil means not drawn. Called on the main thread only when it changes.
    var onFocusFrame: ((CGRect?) -> Void)?
    /// The front window whose automatic start was tried on this arrival and the windows it tried to arrange; not retried while the same pair remains.
    private var autoStartArmed: [String: (front: WindowID, ids: Set<WindowID>)] = [:]
    /// How long a prepared automatic start waits for a quiet observation.
    var autoStartWindow: TimeInterval = 10
    /// A front window that did not qualify for the automatic start and the window set then; AX is not reread while both stay the same.
    private var autoStartDeclined: [String: (front: WindowID, windows: Set<WindowID>)] = [:]
    /// The configuration file could not be applied at launch and still has not been. Meanwhile only manual actions run with the built-in configuration. Read and written under lock.
    private var unappliedSinceLaunch = false
    /// Text of the configuration file last applied. Read and written under lock.
    private var appliedConfigText: String?

    /// Guidance for an unstarted Space, using the same name as the menu's arrange item.
    var notStartedMessage: String {
        lock.lock(); let key = config.keys(forMode: Config.mainModeName)?["arrange"]?.display; lock.unlock()
        return StatusMenuCopy.notStartedMessage(arrangeKey: key)
    }
    private var lastFocusFrame: CGRect?
    /// The latest acceptance refusal (a sentence for the user).
    private(set) var lastRefusal: String?
    /// The latest operation result, for status. Kept in memory only, so no record of operations reaches the disk.
    private(set) var lastResult: OperationResult?

    /// Call with lock held. Uses main's key if the current mode has no float.
    private func floatKeyDisplayLocked() -> String? {
        let current = config.keys(forMode: mode)?["float"]?.display
        let main = config.keys(forMode: Config.mainModeName)?["float"]?.display
        let display = (current?.isEmpty == false) ? current : main
        return (display?.isEmpty == false) ? display : nil
    }

    private func floatingHeldReason(display: String?) -> String {
        if let display { return L("Floating. Press \(display) to return it to the layout.", "フローティング中。\(display)でレイアウトに戻せます") }
        let item = EditCommand.toggleFloat.menuLabel(floating: true, zoomed: false)
        return L("Floating. Choose “\(item)” to return it to the layout.", "フローティング中。「\(item)」でレイアウトに戻せます")
    }

    private func floatingEditRefusal() -> String {
        lock.lock(); let display = floatKeyDisplayLocked(); lock.unlock()
        if let display { return L("The focused window is floating. Press \(display) to return it to the layout, then try again.", "フォーカス中のウインドウはフローティングです。\(display)でレイアウトに戻してから操作してください。") }
        let item = EditCommand.toggleFloat.menuLabel(floating: true, zoomed: false)
        return L("The focused window is floating. Choose “\(item)” to return it to the layout, then try again.", "フォーカス中のウインドウはフローティングです。「\(item)」でレイアウトに戻してから操作してください。")
    }

    func noteRefusal(_ text: String) {
        lock.lock(); lastRefusal = text; lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Hooks run inside operations, and publishing an operation's result clears the refusal text; queued behind the running
    /// operation, a hook's problem is noted after that.
    private func noteHookProblem(_ text: String) {
        queue.async { [weak self] in self?.noteRefusal(text) }
    }

    /// Result of a reload. Success only informs and clears refusal text left in the menu; failure stays as a refusal.
    @discardableResult
    func reportReload(source: String) -> String {
        let message = reloadConfig(source: source)
        if configError == nil {
            lock.lock(); lastRefusal = nil; lock.unlock()
            DispatchQueue.main.async { self.onChange?() }
        } else {
            noteRefusal(message)
        }
        return message
    }

    private convenience init() {
        self.init(system: MacWindowSystem(), store: StateStore(), startServices: true)
    }

    /// Tests replace the OS write path and storage and start neither input observation, configuration, nor the automatic loop.
    init(system: CoordinatorWindowSystem, store: StateStore, startServices: Bool = false, configURL: URL? = nil,
         knowledge: ConstraintKnowledge = ConstraintKnowledge(),
         takeCensus: @escaping (UInt64?) -> Census = { WindowCensus.take(spaceID: $0) },
         takeOverview: @escaping () -> SpaceOverview? = { SpaceOverview.take() },
         takeInventory: @escaping () -> AppWindowInventory? = { AppWindowInventory.take() }) {
        self.system = system
        lastTrusted = system.axTrusted
        self.knowledge = knowledge
        self.configURL = configURL ?? Self.defaultConfigURL
        self.store = store
        self.takeCensus = takeCensus
        self.takeOverview = takeOverview
        self.takeInventory = takeInventory
        queue.setSpecific(key: queueToken, value: 1)
        lastCompletedMouseDrags = system.input.completedMouseDrags
        state = store.load()
        control = OperationControl(paused: state.paused)
        servicesStarted = startServices
        // What changed while LazySpace was not running (windows moved, the display setup) is unknown: every saved layout is fit again, as after a display change.
        displayRefitPending = Set(state.layouts.keys)
        guard startServices else {
            knowledge.restore(Self.sizeFacts(state.sizeFacts), observedAt: Date())
            return
        }
        _ = system.input.start()
        spaceControl = SpaceControl(input: system.input)
        // Direct-path activation uses AX elements obtained while the window was visible (the same path as `focus`).
        // The result of raise's queued activation (the requested pid, or none) is passed on because SpaceControl waits for it when jumping to an intermediate Space.
        spaceControl?.direct = SpaceControl.systemDirectPath(raise: { [weak self] wid, isCurrent, report in
            guard let self else { return .refused }
            switch self.system.raise(WindowID(wid), timeout: self.limits.perAppTimeout, activateIf: isCurrent,
                                     activated: { pid in report(pid.map { .requested($0) } ?? .abandoned) }) {
            case .issued: return .issued
            case .timedOut: return .unknown // the request may reach the app and take effect late
            case .gone, .rejected: return .refused
            }
        }, focusedWindow: { [weak self] in self?.system.focusedWindowID()?.raw })
        discardLayoutsFromOtherSession()
        knowledge.restore(Self.sizeFacts(state.sizeFacts), observedAt: Date())
        reloadConfig(source: "launch")
        lastConfigFingerprint = configFingerprint()
        startAutoLoop()
        // Observe at a short interval from the moment a drag is released (not waiting for the next regular cycle).
        system.input.onLeftMouseUp = { [weak self] in self?.wakeFromAX() }
        DispatchQueue.main.async { [self] in
            let observer = WakeObserver { [weak self] id in
                if let id { self?.noteAnnouncedWindow(id) }
                self?.wakeFromAX()
            }
            observer.start()
            wake = observer
            geometryQuiet = { [weak observer] pids, since in observer?.geometryQuiet(pids: pids, since: since) }
        }
    }

    // MARK: - Config

    /// Rereads the configuration file without writing windows. If broken, the last valid configuration stays.
    /// Change notifications (`file`) never write the template (no overwrite when the file is briefly missing mid-save in an editor).
    /// Nothing happens while the file is absent, and identical bytes to the last applied file are not reapplied.
    @discardableResult
    func reloadConfig(source: String) -> String {
        if source != "file" { ConfigFile(url: configURL).ensureExists() }
        let unchanged = L("The configuration file has not changed.", "設定ファイルは変わっていません。")
        if source == "file", !FileManager.default.fileExists(atPath: configURL.path),
           (try? FileManager.default.destinationOfSymbolicLink(atPath: configURL.path)) == nil { return unchanged }
        let text = try? String(contentsOf: configURL, encoding: .utf8)
        if source == "file", let text {
            lock.lock(); let same = configError == nil && appliedConfigText.map { ConfigFile.sameUTF8($0, text) } == true; lock.unlock()
            if same { return unchanged }
        }
        guard let text else {
            let message = L("Could not read the configuration file: \(configURL.path)", "設定ファイルを読めません: \(configURL.path)")
            lock.lock(); configError = message; if source == "launch" { unappliedSinceLaunch = true }; lock.unlock()
            publishConfigStatus()
            return message
        }
        do {
            var loadNotes: [String] = []
            let loaded = try Config.load(toml: text, onNote: { loadNotes.append($0) })
            lock.lock()
            let previous = config
            config = loaded
            Copy.apply(setting: loaded.language)
            // Send gate: after a configuration reload, accepted sends are not issued either.
            configGeneration &+= 1
            appliedConfigText = text
            unappliedSinceLaunch = false
            autoStartDeclined.removeAll()
            let spaceRulesChanged = previous.rules.filter { $0.action == .space } != loaded.rules.filter { $0.action == .space }
            // Windows whose rule changed do not stay excluded with an old frame. Both are touched only by the operations queue.
            queue.async {
                self.notTileable.removeAll()
                self.lastUnclassified.removeAll()
                // When space rules change, window memory is rebuilt (existing windows become known on the next observation and are not treated as new).
                if spaceRulesChanged { self.router = WindowRouter(); self.updateRoutingExcluded() }
            }
            configLock.lock(); limitsStore.perAppTimeout = loaded.perAppTimeout; configLock.unlock()
            configError = nil
            configNotes = loadNotes
            quietInterval = loaded.quietInterval
            // If the current mode disappeared, back to main.
            let previousMode = mode
            let modeGone = mode != Config.mainModeName && loaded.modes[mode] == nil
            if modeGone { mode = Config.mainModeName }
            lock.unlock()
            var notes = loadNotes
            if modeGone { notes.append(L("Mode \(previousMode) was removed from the configuration, so the main mode is active again.", "モード\(previousMode)は設定から消えたためmainに戻りました。")) }
            // Open at Login: register / unregister with the OS only when a value is written and differs from before (or at launch).
            if let wanted = loaded.startAtLogin, wanted != previous.startAtLogin || source == "launch" {
                if let problem = LoginItem.set(wanted) { notes.append(problem) }
            }
            let loadMessage = loadNotes.isEmpty ? nil : loadNotes.joined(separator: "\n")
            DispatchQueue.main.async {
                self.onConfigChange?(loaded)
                self.onConfigStatus?(loadMessage)
                if modeGone { self.onModeChange?(Config.mainModeName) }
                self.onChange?()
            }
            return ([L("Configuration loaded. No windows were moved.", "設定を読み込みました。ウインドウは動かしていません。")] + notes).joined(separator: "\n")
        } catch let e as Config.LoadError {
            let message = L("The configuration has errors, so the last valid configuration is still in use:", "設定に誤りがあるため、直前の有効な設定を使っています:") + "\n" + e.problems.joined(separator: "\n")
            lock.lock(); configError = message; if source == "launch" { unappliedSinceLaunch = true }; lock.unlock()
            publishConfigStatus()
            DispatchQueue.main.async { self.onChange?() }
            return message
        } catch {
            let message = L("Could not read the configuration: \(error)", "設定を読めません: \(error)")
            lock.lock(); configError = message; if source == "launch" { unappliedSinceLaunch = true }; lock.unlock()
            publishConfigStatus()
            return message
        }
    }

    /// Updates only the Settings banner, delivered on the main thread.
    private func publishConfigStatus() {
        lock.lock(); let error = configError; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onConfigStatus?(error) }
    }

    /// Save from Settings: applies only changed values to the file, keeping comments and other lines.
    /// Nothing is written if the baseline differs from the current file's configuration. Returns a sentence for the user (nil on success). Windows never move.
    func saveConfig(_ draft: Config, baseline: Config, source: String) -> String? {
        switch ConfigFile(url: configURL).save(draft, baseline: baseline) {
        case .unchanged:
            return nil
        case .refused(let message):
            return message
        case .written:
            _ = reloadConfig(source: source)
            lock.lock(); let failed = configError; lock.unlock()
            if failed != nil {
                return L("The configuration was written but could not be loaded. Check the file.", "設定は書き込みましたが、読み込めませんでした。ファイルを確認してください。")
            }
            return nil
        }
    }

    // MARK: - Binding mode / login item / hooks

    enum ModeAccept: Equatable {
        case changed
        case unchanged
        case refused(String)
    }

    /// Switches the binding mode without writing windows. Undeclared modes are refused.
    @discardableResult
    func setMode(_ name: String, source: String) -> ModeAccept {
        lock.lock()
        let known = name == Config.mainModeName || config.modes[name] != nil
        guard known else {
            lock.unlock()
            let available = ([Config.mainModeName] + config.modes.keys.sorted()).joined(separator: ", ")
            return .refused(L("Mode \(name) is not in the configuration. Available modes: \(available).", "モード\(name)は設定にありません（使えるモード: \(available)）。"))
        }
        if mode == name { lock.unlock(); return .unchanged }
        mode = name
        let hook = config.execOnModeChange
        lock.unlock()
        DispatchQueue.main.async { self.onModeChange?(name); self.onChange?() }
        if !hook.isEmpty {
            HookRunner.run(hook, environment: ["LAZYSPACE_MODE": name]) { [weak self] in self?.noteHookProblem($0) }
        }
        return .changed
    }

    /// Whether to return to main after one command in the current mode.
    var shouldReturnToMainAfterCommand: Bool {
        lock.lock(); defer { lock.unlock() }
        guard mode != Config.mainModeName else { return false }
        return config.modes[mode]?.returnToMain ?? true
    }

    /// Toggles Open at Login (from the menu). If the configuration file sets start-at-login, it wins on the next reload.
    func setLoginItem(_ enabled: Bool) {
        if let problem = LoginItem.set(enabled) { noteRefusal(problem) }
        else if let fixed = config.startAtLogin, fixed != enabled {
            noteRefusal(enabled
                ? L("Turned on Open at Login. The configuration file sets start-at-login = \(fixed), so the next reload changes it back. Update the configuration file as well.",
                    "「ログイン時に開く」をオンにしました。設定ファイルにstart-at-login = \(fixed)があるため、次の再読み込みで戻ります。設定ファイルも変更してください。")
                : L("Turned off Open at Login. The configuration file sets start-at-login = \(fixed), so the next reload changes it back. Update the configuration file as well.",
                    "「ログイン時に開く」をオフにしました。設定ファイルにstart-at-login = \(fixed)があるため、次の再読み込みで戻ります。設定ファイルも変更してください。"))
        } else {
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    private func runSpaceChangeHook(from previous: UInt64?, to current: UInt64) {
        spaceChangeHookObserver?(previous, current)
        lock.lock(); let hook = config.execOnSpaceChange; lock.unlock()
        guard !hook.isEmpty else { return }
        HookRunner.run(hook, environment: Self.spaceChangeEnvironment(current: current, previous: previous)) { [weak self] in self?.noteHookProblem($0) }
    }

    /// Environment for `exec-on-space-change`, passing OS Space IDs.
    static func spaceChangeEnvironment(current: UInt64, previous: UInt64?) -> [String: String] {
        ["LAZYSPACE_SPACE_ID": String(current), "LAZYSPACE_PREV_SPACE_ID": previous.map(String.init) ?? ""]
    }

    private static func sizeFacts(_ saved: [PersistedSizeFact]) -> [WindowID: ConstraintKnowledge.Entry] {
        var facts: [WindowID: ConstraintKnowledge.Entry] = [:]
        for fact in saved { facts[fact.id] = fact.entry }
        return facts
    }

    /// Window IDs from a previous login session are not trusted: discards layout intent, floating, zoom, and measured sizes, keeping Pause.
    private func discardLayoutsFromOtherSession() {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boottime, &size, nil, 0)
        let boot = "\(boottime.tv_sec)-\(NSUserName())"
        discardLayouts(sessionKey: Self.sessionKey(boot: boot, loginSession: Self.loginSessionIdentifier()))
    }

    /// Identifier of the login (WindowServer) session; changes when logging out and back in within one launch. nil when unreadable.
    static func loginSessionIdentifier() -> String? {
        loginSessionIdentifier(from: (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:])
    }

    /// Picks an identifier from the session dictionary. macOS 27 has no `kCGSSessionIDKey`, so use the per-session UUID,
    /// then the audit session ID, then the old key, each prefixed with a marker showing its source.
    static func loginSessionIdentifier(from info: [String: Any]) -> String? {
        if let uuid = info["CGSSessionUniqueSessionUUID"] as? String, !uuid.isEmpty { return "uuid-\(uuid)" }
        if let audit = info["kCGSSessionAuditIDKey"] as? NSNumber { return "audit-\(audit.intValue)" }
        return (info["kCGSSessionIDKey"] as? NSNumber).map { String($0.intValue) }
    }

    /// Session key: launch time + user name + login session; nil when the login session is unreadable (sameness cannot be confirmed).
    static func sessionKey(boot: String, loginSession: String?) -> String? {
        loginSession.map { "\(boot)-session\($0)" }
    }

    /// Memory tied to window IDs (layout, floating, zoom, measured sizes) is used only when the same login session is confirmed.
    /// It is discarded when the key differs or the login session is unreadable (nil). Pauses stay.
    func discardLayouts(sessionKey key: String?) {
        if let key, state.sessionKey == key { return }
        let had = state.layouts.count
        state.layouts.removeAll(); state.floating.removeAll(); state.zoomed.removeAll(); state.sizeFacts.removeAll(); state.floatHomes.removeAll(); state.dialogRegions = nil
        displayRefitPending.removeAll()
        knowledge.forgetAll()
        state.sessionKey = key ?? ""
        store.save(state)
        if had > 0 {
            let spaces = had == 1 ? "1 Space" : "\(had) Spaces"
            lastRefusal = key == nil
                ? L("The login session could not be identified, so the saved layouts for \(spaces) are not used. No windows were moved.",
                    "ログインセッションを確かめられないため、保存していた\(had)つの操作スペースのレイアウトは使いません（ウインドウは動かしません）。")
                : L("This is a new login session, so the saved layouts for \(spaces) are not used. No windows were moved.",
                    "前回とは別のログインセッションのため、保存していた\(had)つの操作スペースのレイアウトは使いません（ウインドウは動かしません）。")
        }
    }

    /// Version shown on screen and in status; builds of the same version are told apart.
    var versionLabel: String { BundleVersion.label() }

    // MARK: - Auto gate

    struct AutoGate: Equatable {
        var allowed: Bool
        var reason: String
    }

    /// Automatic arrangement is available when input can be observed, on top of Accessibility and Space observation (the manual arrangement conditions). Exclusions come from rules.
    func autoGate() -> AutoGate {
        guard system.inputObservationAvailable else {
            return AutoGate(allowed: false, reason: L("Automatic arrangement is off because input cannot be observed, so windows could move while you use them. Check the \(AccessPane.name()) permission.",
                                                      "入力を観測できないため、自動整列を止めています。操作中のウインドウを動かさないためです。「\(AccessPane.name())」の許可を確認してください。"))
        }
        lock.lock(); let unapplied = unappliedSinceLaunch; lock.unlock()
        guard !unapplied else {
            return AutoGate(allowed: false, reason: L("Automatic arrangement is off because the configuration file could not be applied. It turns on when the file is fixed.",
                                                      "設定ファイルを適用できないため、自動整列を止めています。ファイルを直すと使えるようになります。"))
        }
        if system.stageManagerOn {
            return AutoGate(allowed: false, reason: L("Automatic arrangement is off while \(MacItem.stageManager) is on. Turn off \(MacItem.stageManager) to use it.",
                                                      "\(MacItem.stageManager)の使用中は、自動整列を止めています。使うには\(MacItem.stageManager)をオフにしてください。"))
        }
        if system.displaysShareOneSpace {
            return AutoGate(allowed: false, reason: L("Automatic arrangement is off because more than one display is connected and Mission Control’s “\(MacItem.separateSpaces)” is off. Turn it on in System Settings › Desktop & Dock, then log out and back in.",
                                                      "複数のディスプレイをつないでいて、Mission Controlの「\(MacItem.separateSpaces)」がオフのため、自動整列を止めています。システム設定 › デスクトップとDockでオンにしてから、ログアウトしてログインし直してください。"))
        }
        return AutoGate(allowed: true, reason: L("Automatic arrangement is available. Use window rules to exclude apps.", "自動整列を利用できます。除外するアプリはルールで指定します。"))
    }

    // MARK: - Status

    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return running != nil }

    /// The menu uses the visible front app's window without waiting for the slow AX focus cache.
    /// This value only decides availability and pins the target; run-time AX, membership, and kind checks are not skipped.
    func menuWindowTarget() -> MenuWindowTarget? {
        guard system.axTrusted, system.spaceObservationAvailable, let space = system.currentSpaceID() else { return nil }
        let census = takeCensus(space)
        guard census.spaceID == space, system.currentSpaceID() == space,
              let front = census.frontWindow, let pid = census.frontmostPID,
              census.windows[front] == pid else { return nil }
        return MenuWindowTarget(window: front, pid: pid, spaceID: space)
    }

    /// Automatic arrangement can be interrupted by user actions, so only the menu is disabled, without blocking the priority queue.
    var canSendFromMenu: Bool {
        guard system.axTrusted, system.spaceObservationAvailable, !control.paused else { return false }
        lock.lock(); defer { lock.unlock() }
        return running == nil || runningKind?.hasPrefix("auto-") == true
    }

    private func refreshFocusedWindow() {
        lock.lock()
        guard !focusRefreshInFlight, Date().timeIntervalSince(lastFocusRefresh) >= 0.5 else { lock.unlock(); return }
        focusRefreshInFlight = true
        lastFocusRefresh = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let focused = system.focusedWindowID()
            lock.lock()
            cachedFocusedWindow = focused
            focusRefreshInFlight = false
            lock.unlock()
        }
    }

    /// Caller holds lock; does not query SMAppService or AX focus.
    private func idleLocked() -> Bool {
        running == nil && userQueue.isEmpty && !mouseHeld && !pendingMouseEdit
            && !system.mouseButtonDown && system.input.completedMouseDrags == lastCompletedMouseDrags
    }

    func status() -> AppStatus {
        let desktopShortcuts = desktopShortcutStatus() // read outside the lock (hotkeys and Space order)
        let arrows = arrowShortcutStates()
        let freshness = dockShortcutFreshness()
        let trusted = system.axTrusted
        if trusted { refreshFocusedWindow() }
        lock.lock(); let focusedWindow = cachedFocusedWindow; lock.unlock()
        let spaceOK = system.spaceObservationAvailable
        let paused = control.paused
        let busy = isBusy
        var manual = true
        var manualReason = L("Available", "利用できます")
        if !trusted { manual = false; manualReason = L("The \(AccessPane.name()) permission is required.", "「\(AccessPane.name())」の許可が必要です") }
        else if !spaceOK { manual = false; manualReason = L("This version of macOS does not report which Space a window is on.", "このmacOSではウインドウがどの操作スペースにあるかを確認できません") }
        let gate = autoGate()
        let autoOK = manual && gate.allowed
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        let login = LoginItem.state() // SMAppService is queried outside the lock
        lock.lock()
        defer { lock.unlock() }
        let managed = state.layouts[spaceKey] != nil
        let spacePaused = state.pausedSpaces.contains(spaceKey)
        let availability: AppStatus.Availability
        let reason: String
        if !manual { availability = .needsSetup; reason = manualReason }
        else if paused {
            availability = .paused
            reason = L("Paused in all Spaces. Resuming does not itself move windows; automatic arrangement can continue afterward.",
                       "すべての操作スペースで一時停止中です。再開の操作だけではウインドウは動きません。再開後は自動整列を続けられます。")
        }
        else if spacePaused {
            availability = .automatic
            reason = L("Automatic arrangement is off in this Space. Manual arrangement is still available, and other Spaces continue.",
                       "この操作スペースの自動整列はオフです。手動の整列は使えます。他の操作スペースは続きます。")
        }
        else if autoOK {
            availability = .automatic
            if managed { reason = L("Automatic arrangement is active in this Space.", "この操作スペースは自動整列中です。") }
            else {
                reason = L("Waiting to start. This Space starts tiling from an eligible focused window after you stay on it and input settles.",
                           "開始待ちです。この操作スペースに留まり、入力が落ち着くと、フォーカス中の対象ウインドウから整列を始めます。")
            }
        }
        else { availability = .manualOnly; reason = L("Manual arrangement only. ", "手動整列のみ。") + gate.reason }
        let progress: AppStatus.Progress = busy ? (paused ? .pausing : .running) : .idle
        let settled = idleLocked()
        return AppStatus(
            availability: availability, availabilityReason: reason,
            manualAvailable: manual, manualReason: manualReason,
            autoAvailable: autoOK, autoReason: manual ? gate.reason : manualReason,
            currentSpaceManaged: managed,
            trusted: trusted, spaceObservation: spaceOK,
            inputObservation: system.input.mode.rawValue,
            paused: paused, progress: progress,
            progressText: busy ? (paused ? L("Pausing: checking windows that had started to move", "停止処理中: 動かし始めたウインドウを確認しています") : progressText) : "",
            waiting: (waitingBySpace[spaceKey] ?? []).sorted(),
            floating: state.floating[spaceKey] ?? [],
            zoomed: state.zoomed[spaceKey],
            lastRefusal: lastRefusal,
            configPath: configURL.path, configError: configError, configNotes: configNotes,
            focusedWindow: trusted ? focusedWindow : nil,
            lastResult: lastResult,
            version: versionLabel,
            mode: mode, modes: [Config.mainModeName] + config.modes.keys.sorted(),
            loginItem: login.text, loginItemEnabled: login == .enabled,
            idle: settled,
            currentSpaceAutoPaused: spacePaused, currentSpaceID: system.currentSpaceID(), desktopShortcuts: desktopShortcuts,
            leftShortcut: arrows.map { DesktopShortcuts.arrowStatusText($0.left) }, rightShortcut: arrows.map { DesktopShortcuts.arrowStatusText($0.right) },
            dockShortcutFreshness: freshness == .preferencesNewer ? DockShortcutFreshness.message : nil,
            dialogRegion: dialogRegionStatusLocked(spaceKey: spaceKey))
    }

    /// Whether "Arrange this Space automatically" is off for the current Space.
    var currentSpaceAutoPaused: Bool {
        let key = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock(); defer { lock.unlock() }
        return state.pausedSpaces.contains(key)
    }

    /// Global pause, or automatic arrangement stopped for this Space only. Manual actions are refused only under the global pause.
    func autoPaused(_ spaceKey: String) -> Bool {
        if control.paused { return true }
        lock.lock(); defer { lock.unlock() }
        return state.pausedSpaces.contains(spaceKey)
    }

    /// Stops or restores automatic arrangement for the current Space only. Remembered across restarts.
    func setCurrentSpaceAutoPaused(_ pause: Bool) {
        guard let sid = system.currentSpaceID() else { return }
        let key = String(sid)
        lock.lock()
        if pause { state.pausedSpaces.insert(key) } else { state.pausedSpaces.remove(key) }
        if pause, pendingAutoStart?.spaceKey == key { pendingAutoStart = nil }
        // Turning it back on forgets earlier automatic-start attempts (it can start again with the same windows).
        if !pause { autoStartArmed[key] = nil; autoStartDeclined[key] = nil }
        let stopAuto = pause && (runningKind?.hasPrefix("auto-") == true || runningKind?.hasPrefix("mouse-") == true)
        store.save(state)
        lock.unlock()
        if stopAuto { control.invalidate() }
        if !pause { queue.async { [self] in baseline = nil; lastSeen = nil } }
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - Inspect (no writes)

    func inspect(completion: @escaping (Inspection) -> Void) {
        queue.async { [self] in
            let snap = system.snapshot()
            let ins = inspectSnapshot(snap)
            DispatchQueue.main.async { completion(ins); self.onChange?() }
        }
    }

    /// Aligns rule and manual-float targets between the window list, the CLI, and explicit arrangement.
    func inspectSnapshot(_ snapshot: Snapshot) -> Inspection {
        lock.lock()
        let cfg = config
        let floating = state.floating[snapshot.spaceID.map(String.init) ?? "-"] ?? []
        let floatDisplay = floatKeyDisplayLocked()
        let routing = routingExcluded
        lock.unlock()
        var held = Dictionary(uniqueKeysWithValues: floating.map { ($0, floatingHeldReason(display: floatDisplay)) })
        // The window list only reads, and shows classifying and unconfirmed sends apart from normal waiting.
        for (id, reason) in routing { held[id] = reason }
        return TargetSelection.inspect(snapshot, appRule: { cfg.tilingExclusionReason(bundleID: $0.app, title: $0.title) }, heldOut: held)
    }

    /// Recent operation results by ID (for the CLI's completion wait). Even if automatic arrangement overwrites lastResult,
    /// accepted operations' results stay here.
    private var recentResults: [OperationResult] = []
    /// Queued acceptance ID -> ID of the operation that actually ran.
    private var resultAliases: [String: String] = [:]
    func result(id: String) -> OperationResult? {
        lock.lock(); defer { lock.unlock() }
        if let direct = recentResults.first(where: { $0.id == id }) { return direct }
        var seen = Set<String>()
        var current = id
        while seen.insert(current).inserted, let next = resultAliases[current] {
            if let direct = recentResults.first(where: { $0.id == next }) { return direct }
            current = next
        }
        return nil
    }

    private func bindTicket(_ ticket: String, to operationID: String) {
        guard ticket != operationID else { return }
        lock.lock(); resultAliases[ticket] = operationID; lock.unlock()
    }

    /// Records a queued command that never ran, so the waiting CLI can finish.
    /// A queued operation refused when dequeued. With a timeline (Space switch or move), it is published with the timeline since acceptance.
    /// For a Space switch or move (`spaceCommand`), the Space visible on the operations queue is recorded before publishing (hooks, arrival, `space back` target),
    /// so even when the operation ahead did not handle Spaces, the Space the user moved to while waiting reaches the next `space back` without waiting for a tick.
    private func noteQueuedRefusal(_ ticket: String, _ message: String, timeline: OperationTimeline? = nil, spaceCommand: Bool = false) {
        let publish = { [self] in
            if spaceCommand, let sid = system.currentSpaceID() { noteSpaceTransition(to: sid) }
            var note = OperationResult.note(kind: "queued", spaceID: system.currentSpaceID(), message: message, ok: false)
            note.id = ticket
            if let timeline { timeline.mark("published"); note.timeline = timeline.events }
            lock.lock()
            record(note)
            store.save(state)
            lock.unlock()
        }
        // Only the operations queue touches Space records (dropping on pause is called from main).
        if spaceCommand, DispatchQueue.getSpecific(key: queueToken) == nil { performOnOperationQueue(publish) } else { publish() }
    }

    /// Destination resolved before queuing (number, ID). next, prev, and back are resolved when dequeued.
    private static func absoluteDestination(_ command: EditCommand) -> SpaceTarget? {
        switch command {
        case .space(let target), .moveToSpace(let target), .sendToSpace(let target):
            switch target {
            case .index, .id, .desktop: return target
            case .next, .prev, .back: return nil
            }
        default: return nil
        }
    }

    /// Whether this is a Space switch or move (refusing such a queued item records the visible Space).
    private static func isSpaceCommand(_ command: EditCommand?) -> Bool {
        switch command {
        case .space?, .moveToSpace?, .sendToSpace?: return true
        default: return false
        }
    }
    /// Call with lock held. The hook receives the value copy and must not re-enter Coordinator.
    private func record(_ result: OperationResult) {
        settleRevision &+= 1
        lastResult = result
        lastRefusal = nil
        recentResults.insert(result, at: 0)
        if recentResults.count > 32 { recentResults.removeLast(recentResults.count - 32) }
        onTerminalResult?(result)
    }

    func testingRecord(_ result: OperationResult) {
        lock.lock(); record(result); lock.unlock()
    }

    /// Runs the operation body on the operation queue. A test can make that body finish before acceptance returns.
    private func performOnOperationQueue(_ body: @escaping () -> Void) {
        if completeSynchronouslyForTesting, DispatchQueue.getSpecific(key: queueToken) == nil {
            queue.sync(execute: body)
        } else {
            queue.async(execute: body)
        }
    }

    private var settleRevision: UInt64 = 0 // protected by lock
    private var observedSettleRevision: UInt64 = 0
    private var settleLastObserved = Date.distantPast
    private var settleCensus: Census?
    private var settleSince = Date.distantPast
    private var settleDeferred = false

    /// A fresh pass on the operation queue, followed by a bounded interval of unchanged
    /// current-Space census. This is an observation barrier, not a desktop lock.
    func observeSettlement(completion: @escaping (ControlPort.Settlement) -> Void) {
        queue.async { [self] in
            tick()
            let current = takeCensus(system.currentSpaceID())
            let now = Date()
            var blockers: [String] = []
            lock.lock(); let idle = idleLocked(); lock.unlock()
            if !idle { blockers.append("operations-or-mouse") }
            if current.spaceID == nil || current.spaceID != system.currentSpaceID() { blockers.append("space-unavailable") }
            if !system.axTrusted { blockers.append("accessibility-unavailable") }
            if now.timeIntervalSince(lastInputChange) < quietInterval { blockers.append("input") }
            if now.timeIntervalSince(spaceArrivedAt) < arrivalDwell { blockers.append("arrival") }
            if settleDeferred { blockers.append("deferred") }
            lock.lock(); let pending = pendingAutoStart != nil; let revision = settleRevision; lock.unlock()
            if pending { blockers.append("auto-start") }
            if settleCensus != current || !blockers.isEmpty || revision != observedSettleRevision || now.timeIntervalSince(settleLastObserved) > 2 { settleSince = now }
            observedSettleRevision = revision
            settleLastObserved = now
            settleCensus = current
            let stableFor = now.timeIntervalSince(settleSince)
            if stableFor < max(arrivalDwell, quietInterval) { blockers.append("observing") }
            completion(ControlPort.Settlement(settled: blockers.isEmpty, spaceID: current.spaceID, observedAt: now,
                                               stableFor: stableFor, requiredStableFor: max(arrivalDwell, quietInterval), blockers: blockers))
        }
    }

    // MARK: - Arrange

    enum Accept: Equatable {
        case started(String)
        case busy
        /// The decision's premise (this Space's layout) vanished before acceptance. Not retried.
        case notApplicable
    }

    /// The state an edit proposes. Not saved on refusal, interruption, or partial application.
    struct EditState {
        var floating: [WindowID]
        var zoomed: WindowID?
        var undoHistory: [Layout]? = nil
        var floatHome: FloatHome? = nil
        var clearFloatHome: WindowID? = nil
    }

    /// Explicit arrangement. A running user command goes into the short queue; a running automatic arrangement is cancelled first.
    /// - kind: "arrange" (explicit, all targets), "integrate-waiting" (explicit integration of waiting windows), "auto-integrate", "auto-refit"
    @discardableResult
    func arrange(source: String, kind: String = "arrange", heldOut: [WindowID: String] = [:],
                 transform: ArrangeOperation.Transform? = nil, transformFailure: String = L("This layout change cannot be made.", "この編集は実行できません。"),
                 layoutOverride: Layout? = nil, ignoreZoom: Bool = false,
                 adding: Set<WindowID> = [], automaticFront: WindowID? = nil,
                 editState: EditState? = nil,
                 authorization: OperationAuthorization? = nil,
                 pressedAt: Date? = nil,
                 resultTicket: String? = nil,
                 probeMaximums: Bool = false,
                 otherSpace: (space: UInt64, mode: OtherSpaceWindowSystem.Mode)? = nil,
                 region: RegionApply? = nil,
                 followsUserCommand: Bool = false,
                 unanswered: ArrangeOperation.UnansweredPolicy = .arrangeAround,
                 completion: ((OperationResult) -> Void)? = nil) -> Accept {
        // Continuations of a user command (rewriting the accordion to follow a focus move) skip the automatic-arrangement gate.
        let automatic = kind.hasPrefix("auto-") && !followsUserCommand
        // A mouse edit's arrangement follows automatic arrangement's availability too: turning it off stops and does not commit it.
        let followsAutomatic = automatic || kind.hasPrefix("mouse-")
        lock.lock()
        if running != nil {
            let currentKind = runningKind
            let queueThis = !control.paused && !kind.hasPrefix("auto-") && UserWorkQueue.queuesWhileBusy(source)
            lock.unlock()
            if queueThis {
                if currentKind?.hasPrefix("auto-") == true { control.invalidate() }
                let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
                let ticket = enqueueUser(edit: nil, arrange: UserWorkQueue.Arrange(kind: kind, heldOut: heldOut, ignoreZoom: ignoreZoom), source: source, pressedAt: pressedAt ?? Date(), spaceKey: spaceKey, ticket: resultTicket)
                control.hurrySettle = true
                return .started(ticket)
            }
            if kind.hasPrefix("auto-"), currentKind?.hasPrefix("auto-") == true { control.invalidate() }
            return .busy
        }
        // An arrangement of another Space (hidden, or shown on another display) targets that Space's layout.
        let spaceKey = otherSpace.map { String($0.space) } ?? system.currentSpaceID().map(String.init) ?? "-"
        let prior = layoutOverride ?? state.layouts[spaceKey]
        // While input cannot be observed, nothing is written automatically, since it could collide with windows being handled.
        if kind.hasPrefix("auto-"), !system.inputObservationAvailable { lock.unlock(); return .notApplicable }
        // If Resume discarded the layout after the decision, a stale automatic decision does not restart managing the Space.
        if kind.hasPrefix("auto-"), kind != "auto-start", state.layouts[spaceKey] == nil { lock.unlock(); return .notApplicable }
        // Automatic arrangement also checks at acceptance that the Space's automatic arrangement is on (turned off after the decision, it does not start).
        if automatic, state.pausedSpaces.contains(spaceKey) { lock.unlock(); return .notApplicable }
        if kind == "auto-start", adding.isEmpty || automaticFront == nil { lock.unlock(); return .notApplicable }
        let generation = control.cancellationGeneration
        let configRevision = configGeneration
        let allowedWindows = kind.hasPrefix("auto-") ? Set(prior?.windowIDs ?? []).union(adding) : nil
        var held = heldOut
        // No arrangement writes windows that are reconciling a send, or being classified or sent by a rule.
        for (id, reason) in routingExcluded where held[id] == nil { held[id] = reason }
        let floatDisplay = floatKeyDisplayLocked()
        for id in editState?.floating ?? state.floating[spaceKey] ?? [] where held[id] == nil { held[id] = floatingHeldReason(display: floatDisplay) }
        let requestedZoom = editState.map { $0.zoomed } ?? state.zoomed[spaceKey]
        let zoomed = ignoreZoom ? nil : requestedZoom
        var observed = allowedWindows ?? (kind.hasPrefix("edit:") ? Set(prior?.windowIDs ?? []).union(adding).union(authorization?.expectedWindow.map { [$0.id] } ?? []) : nil)
        // Also observe dialogs to place in the region (to retain their elements, write positions, and read back).
        if let region, observed != nil { observed?.formUnion(region.placements.map(\.id)) }
        // Dialog region: reserve the given region (region operations) or the saved one (other arrangements) on the right; nothing when the feature is inactive.
        var options = config.plannerOptions
        if let region {
            let reservation = region.plan?.reservation(gap: options.gap, gapVertical: options.gapVertical) ?? (right: 0, bottom: 0)
            options.reservedRight = reservation.right
            options.reservedBottom = reservation.bottom
        }
        else { options = plannerOptionsLocked(forSpaceKey: spaceKey) }
        let opSystem: WindowSystem = otherSpace.map {
            OtherSpaceWindowSystem(base: system, control: control, space: $0.space, mode: $0.mode, windows: Set(prior?.windowIDs ?? []).union(adding).subtracting(heldOut.keys))
        } ?? system
        let op = ArrangeOperation(system: opSystem, control: control, knowledge: knowledge, limits: limits, options: options, priorLayout: prior, adoptObservedProportions: layoutOverride == nil && kind != EditCommand.toggleZoom.kind, heldOut: held, allowedWindows: allowedWindows,
                                  adding: kind.hasPrefix("auto-") ? adding : [], kind: kind, unanswered: automatic ? unanswered : .arrangeAround,
                                  transform: transform, transformFailure: transformFailure, zoomed: zoomed, appRule: { [config] window in config.tilingExclusionReason(bundleID: window.app, title: window.title) },
                                  displayName: AppNames.localized, authorization: authorization, observedWindows: observed, probeMaximums: probeMaximums, pressedAt: pressedAt)
        if options.reservesRegion {
            var fallback = options
            fallback.reservedRight = 0
            fallback.reservedBottom = 0
            op.regionFallback = fallback
        }
        op.dialogPlacements = region?.placements ?? []
        op.appliesRegion = region != nil
        if followsAutomatic {
            // Each write of an automatic arrangement (and of a mouse edit's arrangement) checks that the environment still allows automatic arrangement (Stage Manager, display setup), the Space's automatic
            // arrangement is on, and no mouse button is held (a hidden-Space redistribution is unrelated to the button on the shown Space).
            // Region operations also check the region gate.
            op.extraGate = { [self] in
                guard !system.stageManagerOn, !system.displaysShareOneSpace else { return false }
                lock.lock(); let off = state.pausedSpaces.contains(spaceKey); lock.unlock()
                guard !off, otherSpace?.mode == .hidden || !(system.mouseButtonDown || system.anyMouseButtonHeld) else { return false }
                return region.map { $0.gate() } ?? true
            }
        } else if followsUserCommand {
            // Not automatic, but still no write while a mouse button is held (the user may be dragging).
            op.extraGate = { [self] in !(system.mouseButtonDown || system.anyMouseButtonHeld) && (region.map { $0.gate() } ?? true) }
        } else if let region { op.extraGate = region.gate }
        running = op.id
        runningKind = kind
        progressText = L("Accepted", "受け付けました")
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
        onOperationID?(op.id)

        performOnOperationQueue { [self] in
            var result: OperationResult
            if kind == "auto-start", takeCensus(system.currentSpaceID()).frontWindow != automaticFront {
                var cancelled = OperationResult.note(kind: kind, spaceID: system.currentSpaceID(), message: L("Not started because the front window changed.", "前面のウインドウが変わったため操作しません。"), ok: false)
                cancelled.id = op.id
                cancelled.stopReason = .cancelled
                result = cancelled
            } else {
                // Windows excluded after acceptance (reconciling, classifying, sending) are removed right before running too.
                lock.lock(); control.hurrySettle = !userQueue.isEmpty; op.heldOutAtExecution = routingExcluded; lock.unlock()
                result = op.run { text in
                    self.lock.lock(); self.progressText = text; self.lock.unlock()
                    DispatchQueue.main.async { self.onChange?() }
                }
            }
            // The window list is read outside the lock; only failed automatic integrations use it, to count retries at the same frame.
            let failedIntegrateBounds: [WindowID: CGRect]?
            if kind == "auto-integrate", result.outcome != .complete {
                failedIntegrateBounds = takeCensus(result.spaceID).bounds
            } else {
                failedIntegrateBounds = nil
            }
            if let region {
                // Record: region numbers (no titles).
                result.timeline += [TimelineEvent(at: 0, event: "region:members=\(region.plan?.members.count ?? 0)"),
                                    TimelineEvent(at: 0, event: "region:pending=\(region.pending)"),
                                    TimelineEvent(at: 0, event: "region:width=\(Int((region.plan?.thickness ?? 0).rounded()))"),
                                    TimelineEvent(at: 0, event: "region:edge=\(region.plan?.edge.rawValue ?? "none")"),
                                    TimelineEvent(at: 0, event: "region:switched=\(region.switched)"),
                                    TimelineEvent(at: 0, event: "region:dropped=\(op.regionDropped)"),
                                    TimelineEvent(at: 0, event: "region:frontSameApp=\(region.frontSharesProcess)")]
                // For each placed dialog: planned size, size in this operation's observation, and outcome (numbers and outcome names only).
                for placement in region.placements {
                    let observed = op.placementObservedSizes[placement.id].map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
                    let outcome = op.placementOutcomes[placement.id].map { "\($0)" } ?? "none"
                    result.timeline.append(TimelineEvent(at: 0, event: "region:place=\(placement.id.raw):planned=\(Int(placement.size.width))x\(Int(placement.size.height)):observed=\(observed):\(outcome)"))
                }
            }
            // Gates outside the lock (mouse button and the like) first; the settings generation and such are compared under the commit lock.
            let regionExternalOK = region.map { $0.gate() } ?? true
            let autoEnvironmentLost = followsAutomatic && (system.stageManagerOn || system.displaysShareOneSpace)
            let noopReconcile = kind == "auto-reconcile" && result.outcome == .complete && result.issued == 0
            let noopBounds = noopReconcile ? takeCensus(result.spaceID).bounds : nil
            lock.lock()
            running = nil
            runningKind = nil
            if region != nil { noteRegionPlacementsLocked(op.placementOutcomes, plan: region?.plan) }
            let regionStillValid = regionExternalOK && (region.map { regionCommitAllowedLocked($0, key: spaceKey) } ?? true)
            // Whether to commit is decided in one place and used for layout, region, edit state, and result alike.
            // An arrangement finishing after a pause, cancellation, or settings change is not committed (no mismatch between region reservation and settings; the next observation retries).
            let autoTurnedOff = followsAutomatic && (state.pausedSpaces.contains(spaceKey) || autoEnvironmentLost)
            let commitEligible = !control.paused && control.cancellationGeneration == generation && regionStillValid && configGeneration == configRevision && !autoTurnedOff
            if result.outcome == .complete, !commitEligible {
                result.outcome = .interrupted
                result.verified = false
                result.stopReason = result.stopReason ?? .cancelled
                result.message = L("The situation changed before the arrangement finished, so this change was not saved.",
                                   "整列の途中で状況が変わったため、この変更は保存していません。")
            }
            if result.outcome == .complete, let layout = op.resultingLayout, let sid = result.spaceID {
                let key = String(sid)
                // Undo history: only completions where a user edit changed structure or ratios.
                // Automatic arrangement (windows coming and going), undo itself, and float are not pushed (undo restores only the layout tree and leaves float state alone).
                if let before = state.layouts[key], before != layout, kind != EditCommand.undo.kind, kind != EditCommand.toggleFloat.kind, !kind.hasPrefix("auto-") {
                    pushLayoutHistory(before, spaceKey: key)
                }
                // The Space is arranged: a wait for an app that did not answer is over (operations queue).
                unansweredFits[key] = nil
                // A reclaim leaves out windows whose app did not answer (they stay where they are): remembered like departures, they return to their place.
                if !result.unobservedApps.isEmpty, let before = state.layouts[key] {
                    let left = before.windowIDs.filter { !layout.windowIDs.contains($0) }
                    rememberDeparturesLocked(left, spaceKey: key)
                    reclaimedWindows.formUnion(left)
                }
                reclaimedWindows.subtract(layout.windowIDs)
                state.layouts[key] = layout
                // A maximum learned from a request for the whole tiling area leaves the solo probe nothing to test.
                if layout.windowIDs.count == 1, let id = layout.windowIDs.first, let tiles = op.maximumsLearnedAlone[id],
                   let cap = knowledge.maximums(for: [id], workArea: result.workArea)[id] {
                    soloProbed[id] = SoloProbe(cap: cap, tiles: tiles)
                }
                // The region is committed with the layout intent: the region of a region operation; removed when dropped or when the feature is inactive.
                // The committed region matches the reservation actually used (a region operation's region; other arrangements keep the saved region only if they reserved it).
                if let region { setRegionLocked(key, op.regionDropped ? nil : region.plan) }
                else if op.regionDropped || !options.reservesRegion { setRegionLocked(key, nil) }
                lastPlans[key] = Dictionary(uniqueKeysWithValues: result.targets.compactMap { t in t.after.map { (t.id, $0) } })
                // The layout now fits the current work area: a pending display or launch fit is done.
                displayRefitPending.remove(key)
                displayRefitFailures[key] = nil
                let overflow = result.excluded.filter { $0.code == ArrangeOperation.overflowFloatCode }.map(\.window.id)
                if !overflow.isEmpty {
                    var list = state.floating[key] ?? []
                    for id in overflow where !list.contains(id) { list.append(id) }
                    state.floating[key] = list
                }
                // An operation back to normal tiling clears the saved zoom state too, not just the frames.
                if ignoreZoom { state.zoomed[key] = nil }
            }
            // Floating the last window: zero targets counts as success (except when targets were lost to no response).
            let floatedLastWindow = result.outcome == .nothingToDo && result.stopReason == nil
                && kind == EditCommand.toggleFloat.kind && prior?.root == nil && commitEligible
            if let editState, result.outcome == .complete || floatedLastWindow, let sid = result.spaceID {
                let key = String(sid)
                state.floating[key] = editState.floating.isEmpty ? nil : editState.floating
                state.zoomed[key] = ignoreZoom ? nil : editState.zoomed
                if let history = editState.undoHistory { layoutHistory[key] = history }
                if let home = editState.floatHome {
                    var homes = state.floatHomes[key] ?? []
                    homes.removeAll { $0.id == home.id }
                    homes.append(home)
                    state.floatHomes[key] = homes
                }
                if let id = editState.clearFloatHome {
                    var homes = state.floatHomes[key] ?? []
                    homes.removeAll { $0.id == id }
                    state.floatHomes[key] = homes.isEmpty ? nil : homes
                }
                if floatedLastWindow {
                    state.layouts[key] = prior; lastPlans[key] = [:]
                    result.outcome = .complete
                    result.verified = true
                    result.message = L("Window removed from tiling.", "ウインドウを整列対象から外しました。")
                }
            }
            lastFocusRefresh = .distantPast
            scheduleNextTick(after: 0.05) // observe sooner right after windows moved (border and history follow)
            // Placed windows leave the "unplaced" display; failures do not go to waiting either.
            // Windows left unplaced are inserted again by the same rule the next time this Space is quiet.
            for t in result.targets where result.outcome == .complete || t.status == .gone {
                for key in waitingBySpace.keys { waitingBySpace[key]?.remove(t.id) }
            }
            if let bounds = failedIntegrateBounds,
               Self.countsAsIntegrateFailure(kind: kind, outcome: result.outcome, stopReason: result.stopReason) {
                // Windows missing from observation, or seen on another Space or of unknown kind, can occur mid Space change: not failures, retried after an interval.
                let split = Self.integrateObservation(adding: adding, result: result)
                recordIntegrateFailure(split.settled, bounds: bounds)
                observationBackoff.note(split.transient, frames: bounds, now: backoffClock())
            }
            if let sid = result.spaceID {
                // If a hidden redistribution stopped partway, redistribute on return; any completed operation clears it.
                if result.outcome == .complete { hiddenRefitDirty.remove(String(sid)) }
                else if otherSpace != nil, result.issued > 0 {
                    // Drop the frame records so the partial frames are not mistaken for the user's mouse edit on return; the dirty redistribution fixes them.
                    hiddenRefitDirty.insert(String(sid))
                    lastPlans[String(sid)] = nil
                }
            }
            if kind != "auto-reconcile", let sid = result.spaceID {
                reconcileAttempts[String(sid)] = 0
            }
            if let sid = result.spaceID {
                noopReconcileBounds[String(sid)] = noopBounds
            }
            state.sizeFacts = knowledge.snapshot
                .map { PersistedSizeFact(id: $0.key, entry: $0.value) }
                .sorted { $0.id < $1.id }
            record(result)
            store.save(state)
            lock.unlock()
            // An integration that waited for another app counts toward the Space's tries; one whose own windows could not be read does not.
            // The reclaim ends the wait whatever its result.
            if kind == "auto-integrate", unanswered != .arrangeAround, let sid = result.spaceID,
               unanswered == .reclaim || result.targets.contains(where: { adding.contains($0.id) }) {
                _ = unansweredStep(after: result, spaceKey: String(sid))
            }
            completion?(result)
            drainUserQueue()
            DispatchQueue.main.async { self.onChange?() }
        }
        return .started(op.id)
    }

    /// Used by tests to insert given windows beside the last managed window. The product's automatic decisions do not call it.
    func integrateProtected(_ ids: [WindowID]) {
        let focused = system.focusedWindowID()
        lock.lock()
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        let managed = Set(state.layouts[spaceKey]?.windowIDs ?? [])
        lock.unlock()
        let anchor = focused.flatMap { !ids.contains($0) && managed.contains($0) ? $0 : nil }
        if integrateForeground(ids, beside: anchor) == .busy {
            revealAsNew(ids)
        }
    }

    /// Used by tests of explicit single integration to remember windows outside the layout.
    func parkWaiting(_ ids: some Sequence<WindowID>) {
        let key = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock(); waitingBySpace[key, default: []].formUnion(ids); lock.unlock()
    }

    /// Keeps them new in the next difference too.
    private func revealAsNew(_ ids: [WindowID]) {
        guard var base = baseline else { return }
        for id in ids { base.windows[id] = nil }
        baseline = base
    }

    /// Inserts one standard window outside the layout; other unplaced windows stay as they are in this operation.
    @discardableResult
    func integrateWaiting(source: String, pressedAt: Date? = nil, authorization: OperationAuthorization? = nil) -> Accept {
        let missing = unplacedStandardIDs()
        for id in missing { clearIntegrateFailure(id) }
        let focused = system.focusedWindowID(within: acceptanceFocusTimeout)
        let chosen = focused.flatMap { missing.contains($0) ? $0 : nil } ?? missing.first
        var held: [WindowID: String] = [:]
        if let chosen {
            for id in missing where id != chosen {
                held[id] = L("Add One Waiting Window adds one window at a time.", "この操作ではウインドウを1つだけ追加します")
            }
        }
        return arrange(source: source, kind: "integrate-waiting", heldOut: held, ignoreZoom: true, adding: chosen.map { [$0] } ?? [], authorization: authorization, pressedAt: pressedAt)
    }

    /// Adds a window opened in front to the layout: beside the previously focused window or at the end, as configured.
    @discardableResult
    /// `authorization` is the input at the start of the decision (input during the decision's reads also stops it). Taken here when omitted.
    /// `unanswered` is how a layout app that does not answer is treated (the Space's tries; callers on the operations queue pass `unansweredPolicy`).
    func integrateForeground(_ ids: [WindowID], beside anchor: WindowID?, inPlaceOf floated: WindowID? = nil, authorization: OperationAuthorization? = nil,
                             unanswered: ArrangeOperation.UnansweredPolicy = .arrangeAround) -> Accept {
        // Rebuilding after a failed insertion is part of the same automatic decision and inherits input, Pause, and Space changes along the way.
        let authorization = authorization ?? OperationAuthorization(system: system, control: control)
        lock.lock()
        let placement = config.newWindowPlacement
        // A window coming back (its app shown again, or restored from the Dock) returns to its place even when no managed window was in front.
        let returning = ids.contains { departures[$0].map { departureClock().timeIntervalSince($0.at) < Self.departureMemory } ?? false }
        lock.unlock()
        guard placement == .besideFocused, anchor != nil || floated != nil || returning else {
            return arrange(source: "auto", kind: "auto-integrate", ignoreZoom: true, adding: Set(ids), authorization: authorization, unanswered: unanswered)
        }
        let transform: ArrangeOperation.Transform = { [weak self] current, rects in
            guard let self else { return nil }
            self.lock.lock()
            let need = self.config.preferredMinimum
            let spaceKey = self.system.currentSpaceID().map(String.init) ?? "-"
            let home = floated.flatMap { id in (self.state.floatHomes[spaceKey] ?? []).first { $0.id == id }?.layout }
            let remembered = self.departures
            self.lock.unlock()
            let area = self.system.currentWorkArea()
            var layout = current
            var beside = anchor
            // Returning windows first, together with the others that left the same home, so a stack comes back whole and a new window cannot get in the way.
            let now = self.departureClock()
            let back = ids.sorted().filter { id in remembered[id].map { now.timeIntervalSince($0.at) < Self.departureMemory } ?? false }
            // An emptied layout starts from the planner's first layout, which already holds them: they are taken out and put back by their home.
            layout = layout.removing(Set(back))
            var homes: [(home: Layout, ids: [WindowID])] = []
            for id in back {
                let home = remembered[id]!.home
                if let i = homes.firstIndex(where: { $0.home == home }) { homes[i].ids.append(id) } else { homes.append((home, [id])) }
            }
            for group in homes { layout = layout.returning(group.ids, home: group.home) }
            for id in ids.sorted() where !layout.windowIDs.contains(id) {
                if let host = layout.unusedStackHost(rects: rects, area: area, need: need) {
                    layout = layout.inserting(id, stackingBelow: host.id, hostHeight: host.usedHeight, unusedHeight: host.unusedHeight)
                } else if let floated, let home {
                    layout = layout.inserting(id, inPlaceOf: floated, home: home)
                } else if let target = beside {
                    layout = layout.inserting(id, beside: target)
                    beside = id
                } else {
                    layout = layout.inserting(id)
                }
            }
            return layout
        }
        return arrange(source: "auto", kind: "auto-integrate", transform: transform, ignoreZoom: true, adding: Set(ids), authorization: authorization, unanswered: unanswered)
    }

    /// Remembers windows leaving this Space's layout with that layout, so they return to their place within `departureMemory`. Call with lock held.
    private func rememberDeparturesLocked(_ gone: [WindowID], spaceKey: String) {
        guard let layout = state.layouts[spaceKey] else { return }
        let now = departureClock()
        for id in gone { departures[id] = Departure(home: layout, at: now) }
        departures = departures.filter { now.timeIntervalSince($0.value.at) < Self.departureMemory }
    }

    /// Redistribution after managed windows vanished. If the front window closed and focus is left floating, focus moves to the window nearest the vanished one.
    /// `closedFront` is the front window confirmed closed; before moving focus, it is confirmed gone from the full window list.
    @discardableResult
    private func refitAfterRemoval(_ gone: [WindowID], wasFront: Bool, spaceKey: String, closedFront: WindowID? = nil, authorization: OperationAuthorization) -> Accept {
        lock.lock()
        let plan = lastPlans[spaceKey] ?? [:]
        let wantsFocus = wasFront && config.focusAfterClose
        rememberDeparturesLocked(gone, spaceKey: spaceKey)
        lock.unlock()
        // If user input, pause, or a Space change happens between deciding it closed and finishing the redistribution, focus does not move.
        let focusAuthorization = authorization
        let generation = control.cancellationGeneration
        return arrange(source: "auto", kind: "auto-refit", authorization: authorization, unanswered: unansweredPolicy(spaceKey), completion: { [weak self] result in
            guard let self else { return }
            rearmDepartedRefit(after: result, spaceKey: spaceKey, generation: generation)
            guard wantsFocus, result.outcome == .complete || result.outcome == .partial else { return }
            let remaining = result.targets.filter { $0.status == .verified || $0.status == .unchanged }
            guard !remaining.isEmpty else { return }
            // If the Space changed (the OS moved to a window on another Space, for example), do nothing; never pull back.
            let census = self.takeCensus(self.system.currentSpaceID())
            guard census.spaceID == result.spaceID, !self.system.mouseButtonDown,
                  focusAuthorization.interruptionReason(system: self.system, control: self.control) == nil else { return }
            // If a vanished window is back in the list, it did not close; focus stays.
            if gone.contains(where: { census.windows[$0] != nil }) { return }
            // Move only after confirming the closed front window is gone from the full window list; it lingers briefly after fading, so wait up to 0.5 s.
            let watched = Set(closedFront.map { [$0] } ?? gone)
            let deadline = Date().addingTimeInterval(0.5)
            while true {
                guard let records = self.system.windowRecords(watched) else { return }
                if records.isEmpty { break }
                guard Date() < deadline else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard focusAuthorization.interruptionReason(system: self.system, control: self.control) == nil, !self.system.mouseButtonDown else { return }
            // If the OS moved focus to a window on this Space (including other apps' and floating windows), do nothing.
            // If focus stays on the vanished window and that window still exists, it did not close, so do nothing.
            if let focused = self.system.focusedWindowID() {
                if self.takeCensus(result.spaceID).windows[focused] != nil { return }
                if gone.contains(focused), self.system.windowRecords([focused])?[focused] != nil { return }
            }
            // The remaining window nearest the vanished window's frame (center distance), or the first candidate if no vanished frame was recorded.
            func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
            let candidates = remaining.filter { census.windows[$0.id] != nil }
            guard var target = candidates.first?.id else { return }
            if let goneRect = gone.compactMap({ plan[$0] }).first {
                let c = center(goneRect)
                target = candidates.min { a, b in
                    let ca = center(a.after ?? a.before), cb = center(b.after ?? b.before)
                    return hypot(ca.x - c.x, ca.y - c.y) < hypot(cb.x - c.x, cb.y - c.y)
                }!.id
            }
            _ = self.runFocus(target, source: "auto:focus-after-close", authorization: focusAuthorization)
        })
    }

    // MARK: - Edit (layout edits; shortcuts, the menu, and the CLI all come here)

    private struct CodedRefusal: Equatable {
        var message: String
        var code: String
        var accept: EditAccept { .refused(message, code: code) }
    }

    enum EditAccept: Equatable {
        case started(String)
        case busy
        case refused(String, code: String)
    }

    static func preconditionCode(_ reason: StopReason) -> String {
        switch reason {
        case .paused: return "paused"
        case .userInput: return "input-changed"
        case .spaceChanged: return "space-changed"
        case .permissionLost: return "permission-lost"
        case .targetsChanged: return "targets-changed"
        case .cancelled: return "cancelled"
        case .appUnresponsive: return "app-unresponsive"
        }
    }

    /// Agent requests never enter the focus-dependent keyboard queue. Receipt-time
    /// authorization survives observation and execution, including Space and input changes.
    func agentEdit(_ command: EditCommand?, windowID: WindowID?, expectedSpaceID: UInt64?, expectedPID: Int32? = nil,
                   desiredState: Bool? = nil, timeline: OperationTimeline? = nil) -> EditAccept {
        if isBusy { return .busy }
        var authorization = OperationAuthorization(system: system, control: control, allowPaused: command.map { if case .space = $0 { return true }; return false } ?? false)
        authorization.expectedSpaceID = expectedSpaceID
        if let expectedSpaceID, authorization.spaceID != expectedSpaceID { return .refused("Expected Space does not match the current Space.", code: "space-mismatch") }
        if let windowID {
            guard expectedSpaceID != nil else { return .refused("A window target requires --expect-space-id.", code: "usage") }
            let snapshot = system.snapshot(limitingTo: [windowID])
            guard snapshot.trusted, let window = snapshot.windows.first(where: { $0.id == windowID && $0.membership == .current }),
                  expectedPID == nil || expectedPID == window.pid else { return .refused("The target window or its process could not be confirmed in this Space.", code: "target-not-found") }
            authorization.expectedWindow = window
            if let reason = authorization.stopReason(system: system, control: control, snapshot: snapshot) {
                return .refused("Precondition changed: \(reason.rawValue).", code: Self.preconditionCode(reason))
            }
        }
        if let command {
            return edit(command, source: "agent", target: windowID, authorization: authorization, desiredState: desiredState, timeline: timeline)
        }
        guard let windowID else { return .refused("A focus target is required.", code: "usage") }
        return runFocus(windowID, source: "agent", authorization: authorization)
    }

    func resultPending(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = id
        var seen = Set<String>()
        while seen.insert(current).inserted {
            if running == current || userQueue.contains(ticket: current) { return true }
            guard let next = resultAliases[current] else { break }
            current = next
        }
        return false
    }

    /// Lets the menu disable actions that cannot run in the current layout.
    func canApplyEdit(_ command: EditCommand, focused: WindowID?) -> Bool {
        switch command {
        case .space: return true
        case .moveToSpace, .sendToSpace, .fullscreen, .minimize: return focused != nil
        default: break
        }
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock()
        let layout = state.layouts[spaceKey]
        let floating = Set(state.floating[spaceKey] ?? [])
        let history = layoutHistory[spaceKey] ?? []
        let focus = focusHistory[spaceKey] ?? []
        let waitingNow = waitingBySpace[spaceKey] ?? []
        lock.unlock()
        let rects: [WindowID: CGRect]
        if let layout {
            let workArea = system.currentWorkArea()
            let constraints = knowledge.constraints(for: layout.windowIDs, spaceID: system.currentSpaceID(), workArea: workArea)
            let maximums = knowledge.maximums(for: layout.windowIDs, workArea: workArea)
            if case .fits(let plan) = Planner.fit(layout, in: workArea, constraints: constraints, options: plannerOptions(forSpaceKey: spaceKey), maximums: maximums) {
                rects = plan.rects
            } else {
                rects = [:]
            }
        } else {
            rects = [:]
        }
        // Only directional focus includes strip dialogs' frames among neighbor candidates.
        var focusRects = rects
        var members: [WindowID: CGRect] = [:]
        if case .focus = command, layout != nil {
            members = regionLiveMembers(takeCensus(system.currentSpaceID()), space: system.currentSpaceID())
            focusRects.merge(members) { tile, _ in tile }
        }
        return StatusMenuCopy.canApply(
            command, layout: layout, focused: focused, floating: floating, waiting: waitingNow,
            rects: focusRects, canUndo: !history.isEmpty, canFocusBack: focus.contains { $0 != focused },
            regionMembers: Set(members.keys)
        )
    }

    /// `timeline` has its origin at acceptance (created when ControlPort accepted, or at the first `edit` that queued it).
    /// nil makes this the origin for Space switches and moves (also created here and carried when queued while busy). Only Space switches and moves have timelines.
    @discardableResult
    func edit(_ command: EditCommand, source: String, pressedAt: Date? = nil, repeats: Int = 1, resultTicket: String? = nil, target: WindowID? = nil, authorization: OperationAuthorization? = nil, desiredState: Bool? = nil, timeline: OperationTimeline? = nil,
              resolved: ResolvedSpace? = nil, menuTarget: MenuWindowTarget? = nil) -> EditAccept {
        if let menuTarget, self.menuWindowTarget() != menuTarget {
            return .refused(L("The selected window changed. Open the menu again for the window you want to send.",
                              "対象のウインドウが変わりました。送りたいウインドウでメニューを開き直してください。"), code: "targets-changed")
        }
        let timeline: OperationTimeline? = {
            switch command {
            case .space, .moveToSpace, .sendToSpace: return timeline ?? OperationTimeline()
            default: return timeline
            }
        }()
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        let acceptedAt = pressedAt ?? Date()
        lock.lock()
        let layout = state.layouts[spaceKey]
        let floating = Set(state.floating[spaceKey] ?? [])
        let homes = state.floatHomes[spaceKey] ?? []
        let zoomed = state.zoomed[spaceKey]
        let waitingNow = waitingBySpace[spaceKey] ?? []
        let busy = running != nil
        let currentKind = runningKind
        lock.unlock()
        if busy {
            if control.paused {
                // Space switches run even while paused. During stop handling (waiting to confirm issued operations), refuse as busy.
                if case .space = command { return .busy }
                return .refused(L("All Spaces are paused, so the layout was not changed. Resume LazySpace, then try again.", "すべての操作スペースが一時停止中のため編集しません。再開してから操作してください。"), code: "paused")
            }
            guard UserWorkQueue.queuesWhileBusy(source) else { return .busy }
            if currentKind?.hasPrefix("auto-") == true { control.invalidate() }
            // Number and ID destinations are resolved before queuing (so reordering while waiting never targets another Space).
            // next, prev, and back are relative to the position after the previous operation, so they are resolved when dequeued.
            var accepted = resolved
            if accepted == nil, let destination = Self.absoluteDestination(command) {
                // Moves and sends resolve desktops only, as when they run at once; a queued run trusts this resolution.
                let desktopsOnly: Bool = { if case .space = command { return false } else { return true } }()
                switch resolveSpace(destination, desktopsOnly: desktopsOnly) {
                case .failure(let why): return why.accept
                case .success(let value): accepted = value
                }
            }
            let menuRequest = menuTarget.map {
                UserWorkQueue.MenuRequest(target: $0, inputCount: system.inputActivityCount, generation: control.cancellationGeneration)
            }
            let ticket = enqueueUser(edit: command, arrange: nil, source: source, pressedAt: acceptedAt, spaceKey: spaceKey, ticket: resultTicket, timeline: timeline, resolved: accepted, menuRequest: menuRequest)
            control.hurrySettle = true
            return .started(ticket)
        }
        // Space switches do not touch windows, so they run even while paused.
        if case .space(let target) = command { return runSpaceSwitch(target, source: source, authorization: authorization, timeline: timeline, resolved: resolved) }
        if control.paused { return .refused(L("All Spaces are paused, so the layout was not changed. Resume LazySpace, then try again.", "すべての操作スペースが一時停止中のため編集しません。再開してから操作してください。"), code: "paused") }
        // Edits that need no focused window, or no started Space.
        switch command {
        case .moveToSpace(let destination):
            // From the menu (with `follow-moved-window`), the window pinned when the menu opened, as for a send.
            guard let focused = menuTarget?.window ?? target ?? frontWindowForEdit() else { return .refused(L("Could not find the focused window. Select the window to move, then try again.", "フォーカス中のウインドウを確認できません。移動したいウインドウを選んでから操作してください。"), code: "no-focused-window") }
            return runMoveToSpace(focused, target: destination, source: source, authorization: authorization, timeline: timeline, resolved: resolved, menuTarget: menuTarget)
        case .sendToSpace(let destination):
            // Sending a background window with `--window-id` is not accepted (front window only, as with `move-to-space`).
            guard let focused = menuTarget?.window ?? target ?? frontWindowForEdit() else { return .refused(L("Could not find the focused window. Select the window to send, then try again.", "フォーカス中のウインドウを確認できません。送りたいウインドウを選んでから操作してください。"), code: "no-focused-window") }
            return runSendToSpace(focused, target: destination, source: source, authorization: authorization, timeline: timeline, resolved: resolved, menuTarget: menuTarget)
        case .fullscreen, .minimize:
            guard let focused = target ?? frontWindowForEdit() else { return .refused(L("Could not find the focused window.", "フォーカス中のウインドウを確認できません。"), code: "no-focused-window") }
            return runWindowState(focused, command == .fullscreen ? .fullscreen : .minimized, source: source, authorization: authorization, desiredState: desiredState, requireFocus: target == nil)
        case .undo:
            // undo restores only the layout tree (structure and ratios), leaving floating, zoom, and waiting state alone.
            let alive = Set(takeCensus(system.currentSpaceID()).windows.keys)
            lock.lock()
            var history = layoutHistory[spaceKey] ?? []
            // Skip entries equal to the current intent (compared without vanished and floating windows).
            var previous: Layout?
            while let candidate = history.first {
                history.removeFirst()
                let pruned = candidate.removing(Set(candidate.windowIDs).subtracting(alive).union(floating))
                if pruned.root != nil, pruned != layout { previous = pruned; break }
            }
            guard let previous else { lock.unlock(); return .refused(L("There is no layout change to undo.", "取り消せるレイアウトの変更がありません。"), code: "nothing-to-undo") }
            lock.unlock()
            return wrap(arrange(source: source, kind: command.kind, layoutOverride: previous, ignoreZoom: true,
                                editState: EditState(floating: Array(floating), zoomed: zoomed, undoHistory: history), authorization: authorization, pressedAt: acceptedAt))
        case .focusBack:
            guard layout != nil else { return .refused(notStartedMessage, code: "not-started") }
            lock.lock(); let history = focusHistory[spaceKey] ?? []; lock.unlock()
            let current = system.currentSpaceID()
            let census = takeCensus(current)
            // The most recently focused window other than the current front window that is still on this Space.
            // (When the front app has no window, the head of the history is the target as is.)
            // The census also lists other displays' windows; one SkyLight puts only on other Spaces is skipped (unknown membership keeps it).
            let onThisSpace = { (id: WindowID) in current.flatMap { space in self.system.spacesOf(id).map { $0.isEmpty || $0.contains(space) } } ?? true }
            guard let target = history.first(where: { $0 != census.frontWindow && census.windows[$0] != nil && onThisSpace($0) }) else { return .refused(L("There is no previously focused window in this Space.", "直前にフォーカスしていたウインドウがありません。"), code: "no-focus-history") }
            return runFocus(target, source: source, pressedAt: acceptedAt, authorization: authorization)
        default: break
        }
        guard let layout else { return .refused(notStartedMessage, code: "not-started") }
        guard let focused = target ?? frontWindowForEdit() else { return .refused(L("Could not find the focused window. Select a tiled window, then try again.", "フォーカス中のウインドウを確認できません。整列対象のウインドウを選んでから操作してください。"), code: "no-focused-window") }

        func requireManaged() -> CodedRefusal? {
            if floating.contains(focused) { return CodedRefusal(message: floatingEditRefusal(), code: "not-tiled") }
            if !layout.windowIDs.contains(focused) {
                return CodedRefusal(message: L("The focused window is not in the layout. It is excluded or waiting.", "フォーカス中のウインドウはレイアウトに含まれていません（除外か待機中）。"), code: "not-tiled")
            }
            return nil
        }
        func neighborFailure(_ d: Direction) -> String {
            switch d.rawValue {
            case "left": return L("There is no window to the left.", "左に隣のウインドウがありません。")
            case "right": return L("There is no window to the right.", "右に隣のウインドウがありません。")
            case "up": return L("There is no window above.", "上に隣のウインドウがありません。")
            default: return L("There is no window below.", "下に隣のウインドウがありません。")
            }
        }

        if let desiredState, command == .toggleFloat || command == .toggleZoom {
            let current = command == .toggleFloat ? floating.contains(focused) : zoomed == focused
            if current == desiredState {
                return runSimple(kind: command.kind, progress: "Checking requested state", source: source,
                                 target: focused, requireFocus: target == nil, authorization: authorization) { auth in
                    self.lock.lock()
                    let key = auth.spaceID.map(String.init) ?? "-"
                    let actual = command == .toggleFloat ? (self.state.floating[key] ?? []).contains(focused) : self.state.zoomed[key] == focused
                    self.lock.unlock()
                    var result = OperationResult.note(kind: command.kind, spaceID: auth.spaceID, message: L("Already in the requested state.", "指定した状態です。"), ok: actual == desiredState)
                    result.issued = 0
                    result.verified = actual == desiredState
                    return result
                }
            }
        }
        switch command {
        case .focus(let d):
            // Strip dialogs (with identity, membership, and process confirmed) also serve as neighbor candidates and focus origins.
            let space = system.currentSpaceID()
            let live = regionLiveMemberIdentities(takeCensus(space), space: space)
            let members = live.mapValues(\.frame)
            if members[focused] == nil, let why = requireManaged() { return why.accept }
            // Neighbors come from the saved layout intent's frames; repeated presses walk within the same observation.
            let workArea = system.currentWorkArea()
            let constraints = knowledge.constraints(for: layout.windowIDs, spaceID: space, workArea: workArea)
            let maximums = knowledge.maximums(for: layout.windowIDs, workArea: workArea)
            let tileFocus = layout.windowIDs.contains(focused) ? focused : nil
            guard case .fits(let plan) = Planner.fit(layout, in: workArea, constraints: constraints, options: plannerOptions(forSpaceKey: spaceKey), maximums: maximums, focused: tileFocus) else {
                return .refused(L("The layout could not be fitted to the work area.", "作業領域にレイアウトを配置できません。"), code: "layout-unavailable")
            }
            let rects = plan.rects.merging(members) { tile, _ in tile }
            var cursor = focused
            var target: WindowID?
            for _ in 0..<max(repeats, 1) {
                guard let next = LayoutEdit.neighbor(of: cursor, direction: d, rects: rects, layout: layout) else { break }
                target = next
                cursor = next
            }
            guard let target else { return .refused(neighborFailure(d), code: "no-neighbor") }
            var destination: FocusOperation.RegionDestination?
            // Moving to a strip dialog passes the confirmed owner as is (not treated as a normal window).
            if let member = live[target], !layout.windowIDs.contains(target), let space {
                destination = FocusOperation.RegionDestination(pid: member.pid) { [self] in
                    regionLiveMembers(takeCensus(space), space: space, only: [target])[target] != nil
                }
            }
            return runFocus(target, source: source, pressedAt: acceptedAt, authorization: authorization, regionDestination: destination)

        case .swap(let d), .move(let d), .join(let d):
            if let why = requireManaged() { return why.accept }
            let transform: ArrangeOperation.Transform = { current, rects in
                guard let other = LayoutEdit.neighbor(of: focused, direction: d, rects: rects, layout: current) else { return nil }
                switch command {
                case .swap: return LayoutEdit.swap(focused, other, in: current)
                case .move: return LayoutEdit.move(focused, toward: other, direction: d, in: current)
                default: return LayoutEdit.join(focused, with: other, direction: d, in: current)
                }
            }
            return wrap(arrange(source: source, kind: command.kind, transform: transform, transformFailure: neighborFailure(d), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .resize(let axis, let delta):
            if let why = requireManaged() { return why.accept }
            let transform: ArrangeOperation.Transform = { current, _ in LayoutEdit.resize(focused, axis: axis, by: delta, in: current) }
            return wrap(arrange(source: source, kind: command.kind, transform: transform,
                                transformFailure: axis == .horizontal
                                    ? L("The width cannot change because no window shares this row.", "横方向に分け合う隣がないため幅を変えられません。")
                                    : L("The height cannot change because no window shares this column.", "縦方向に分け合う隣がないため高さを変えられません。"), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .resizeSmart(let delta):
            if let why = requireManaged() { return why.accept }
            guard let axis = layout.parentAxis(of: focused) else { return .refused(L("The share cannot change because there is only one window.", "ウインドウが1つだけのため割合を変えられません。"), code: "single-window") }
            let transform: ArrangeOperation.Transform = { current, _ in LayoutEdit.resize(focused, axis: axis, by: delta, in: current) }
            return wrap(arrange(source: source, kind: command.kind, transform: transform, transformFailure: L("The share cannot change because no neighboring window shares the split.", "分け合う隣がないため割合を変えられません。"), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .balance:
            let transform: ArrangeOperation.Transform = { current, _ in
                let balanced = current.balanced()
                return balanced == current ? nil : balanced
            }
            return wrap(arrange(source: source, kind: command.kind, transform: transform, transformFailure: L("The layout is already balanced.", "割合は既に均等です。"), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .close:
            if floating.contains(focused) || layout.windowIDs.contains(focused) || waitingNow.contains(focused) {
                return runClose(focused, source: source, authorization: authorization, requireFocus: target == nil)
            }
            return .refused(L("The focused window is not tiled. Close it in the app with ⌘W.", "フォーカス中のウインドウは整列対象ではありません。アプリの⌘Wで閉じてください。"), code: "not-tiled")

        case .toggleOrientation:
            if let why = requireManaged() { return why.accept }
            let transform: ArrangeOperation.Transform = { current, _ in LayoutEdit.toggleOrientation(of: focused, in: current) }
            return wrap(arrange(source: source, kind: command.kind, transform: transform, transformFailure: L("The split orientation cannot change because there is only one window.", "ウインドウが1つだけのため分割の向きを切り替えられません。"), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .toggleAccordion:
            if let why = requireManaged() { return why.accept }
            let transform: ArrangeOperation.Transform = { current, _ in LayoutEdit.toggleAccordion(of: focused, in: current) }
            return wrap(arrange(source: source, kind: command.kind, transform: transform, transformFailure: L("Accordion layout needs more than one window.", "ウインドウが1つだけのためアコーディオン表示に切り替えられません。"), ignoreZoom: true, authorization: authorization, pressedAt: acceptedAt))

        case .toggleFloat:
            var list = Array(floating)
            let wasFloating = list.contains(focused)
            if wasFloating { list.removeAll { $0 == focused } } else { list.append(focused) }
            // Floating remembers the tree before removal. Returning goes into that tree if the remaining order is unchanged, otherwise beside in the current tree.
            let remembered = homes.first { $0.id == focused }?.layout ?? layout
            let override = wasFloating
                ? layout.returning(focused, home: remembered).removing(Set(list), keepHeights: Set(list))
                : layout.removing([focused], keepHeights: [focused])
            let editState = EditState(
                floating: list,
                zoomed: zoomed == focused ? nil : zoomed,
                floatHome: wasFloating ? nil : FloatHome(id: focused, layout: layout),
                clearFloatHome: wasFloating ? focused : nil
            )
            return wrap(arrange(source: source, kind: command.kind,
                                layoutOverride: override, ignoreZoom: true, editState: editState, authorization: authorization, pressedAt: acceptedAt))

        case .toggleZoom:
            if let why = requireManaged() { return why.accept }
            let turningOn = zoomed != focused
            return wrap(arrange(source: source, kind: command.kind,
                                editState: EditState(floating: Array(floating), zoomed: turningOn ? focused : nil), authorization: authorization, pressedAt: acceptedAt))

        case .undo, .focusBack, .space, .moveToSpace, .sendToSpace, .fullscreen, .minimize:
            return .refused(L("Internal error.", "内部エラー"), code: "internal-error") // handled above
        }
    }

    // MARK: - Space switches and moves

    /// Resolves a reference to a Space. Numbers follow `list-spaces`; id, uuid, and display come from one read.
    private enum SpaceResolution { case success(ResolvedSpace), failure(CodedRefusal) }
    private func spaceListing() -> SpaceListing? {
        if let spaceListingOverride { return spaceListingOverride }
        return spaceControl.map { SpaceControlListing(control: $0) }
    }
    private func resolveSpace(_ target: SpaceTarget, desktopsOnly: Bool = false) -> SpaceResolution {
        guard let listing = spaceListing(), let snapshot = listing.spaceSnapshot() else {
            return .failure(CodedRefusal(message: L("Spaces cannot be used because Space detection is unavailable.", "操作スペースの観測が使えないため、操作スペースを扱えません。"), code: "space-unavailable"))
        }
        // Order, uuids, display, and current Space from one read (so a reorder between reads never yields a mismatched set).
        let order = snapshot.order
        func resolved(_ id: UInt64) -> SpaceResolution {
            guard let holder = snapshot.holder(of: id) else {
                return .failure(CodedRefusal(message: L("That Space is no longer available.", "その操作スペースは利用できません。"), code: "space-not-found"))
            }
            return .success(ResolvedSpace(id: id, uuid: snapshot.uuids?[id], display: holder.display, isDesktop: holder.desktops.contains(id),
                                          otherDisplay: holder.display != snapshot.display))
        }
        var target = target
        // `--display`: the current display resolves as a plain number; another display only by its desktop number.
        if case .desktop(let n, let display) = target {
            let count = max(snapshot.groups.count, 1)
            guard display >= 1, display <= count else {
                return .failure(CodedRefusal(message: L("There is no display \(display). \(count == 1 ? "1 display is" : "\(count) displays are") connected.",
                                                        "ディスプレイ\(display)はありません（つないでいるディスプレイは\(count)台）。"), code: "space-not-found"))
            }
            if let group = snapshot.groups.dropFirst(display - 1).first, group.display != snapshot.display {
                guard n >= 1, n <= group.desktops.count else {
                    return .failure(CodedRefusal(message: L("There is no \(Copy.desktop(n)) on \(group.name). It has \(group.desktops.count == 1 ? "1 desktop" : "\(group.desktops.count) desktops").",
                                                            "\(group.name)には\(Copy.desktop(n))はありません（\(group.desktops.count)個）。"), code: "space-not-found"))
                }
                return resolved(group.desktops[n - 1])
            }
            target = .index(n)
        }
        func neighbor(_ offset: Int) -> UInt64? {
            if let active = snapshot.active ?? system.currentSpaceID() {
                guard let i = order.firstIndex(of: active) else { return nil }
                let candidates = offset > 0 ? Array(order.dropFirst(i + 1)) : Array(order.prefix(i).reversed())
                return candidates.first { !desktopsOnly || snapshot.desktops.contains($0) }
            }
            return listing.neighbor(offset: offset).flatMap { order.contains($0) && (!desktopsOnly || snapshot.desktops.contains($0)) ? $0 : nil }
        }
        switch target {
        case .desktop: return .failure(CodedRefusal(message: "Unresolved display target.", code: "invalid-request"))
        case .index(let n):
            guard n >= 1, n <= snapshot.desktops.count else {
                let count = snapshot.desktops.count == 1 ? "1 desktop" : "\(snapshot.desktops.count) desktops"
                return .failure(CodedRefusal(message: L("There is no \(Copy.desktop(n)). This display has \(count).", "\(Copy.desktop(n))はありません（このディスプレイには\(snapshot.desktops.count)個）。"), code: "space-not-found"))
            }
            return resolved(snapshot.desktops[n - 1])
        case .next:
            guard let id = neighbor(1) else { return .failure(CodedRefusal(message: L("There is no Space to the right.", "右に操作スペースがありません。"), code: "space-not-found")) }
            return resolved(id)
        case .prev:
            guard let id = neighbor(-1) else { return .failure(CodedRefusal(message: L("There is no Space to the left.", "左に操作スペースがありません。"), code: "space-not-found")) }
            return resolved(id)
        case .back:
            lock.lock(); let prev = previousSpaceID; lock.unlock()
            guard let prev, snapshot.holder(of: prev) != nil else { return .failure(CodedRefusal(message: L("There is no previous Space to return to.", "直前にいた操作スペースがありません。"), code: "space-not-found")) }
            return resolved(prev)
        case .id(let id):
            guard let holder = snapshot.holder(of: id), !desktopsOnly || holder.desktops.contains(id) else {
                return .failure(CodedRefusal(message: L("That Space is no longer available.", "その操作スペースは利用できません。"), code: "space-not-found"))
            }
            return resolved(id)
        }
    }

    /// Whether the destination at acceptance is still the same Space right before running (so swapped Spaces never send it elsewhere).
    /// A destination with a uuid must read, in the current single read, with the same id and uuid, and the same display if one was noted (otherwise it does not run).
    /// Only number destinations without a uuid (the Space has no identifier) proceed by id as before.
    private func destinationStillValid(_ resolved: ResolvedSpace) -> Bool {
        guard let snapshot = spaceListing()?.spaceSnapshot(), let holder = snapshot.holder(of: resolved.id) else { return false }
        if let display = resolved.display { guard holder.display == display else { return false } }
        if resolved.isDesktop, !holder.desktops.contains(resolved.id) { return false }
        guard let uuid = resolved.uuid else { return true }
        guard let uuids = snapshot.uuids else { return false }
        return uuids[resolved.id] == uuid
    }

    private static var destinationChanged: String {
        L("The destination Space changed after the request, so nothing was done.", "受け付けたあとで移動先の操作スペースが変わったため、何もしていません。")
    }

    /// Without the direct move a send is refused. A shortcut or the menu names the setting that makes them follow; the command line names `--follow`.
    /// With the setting already on, only a send accepted before it was turned on gets here, and trying again follows.
    static func sendUnavailable(fromShortcutOrMenu: Bool, followSetting: Bool) -> String {
        let reason = L("Sending a window without switching needs the direct move, which is not available on this macOS.", "切り替えずに送るには直接の移動が必要ですが、このmacOSでは使えません。")
        let remedy: String
        if !fromShortcutOrMenu {
            remedy = L("To move and follow the window, use move-to-space --follow.", "移動先へ追従してよければmove-to-space --followを使ってください。")
        } else if followSetting {
            remedy = L("Try again to move the window and switch to its Space.", "もう一度操作すると、ウインドウと一緒に切り替えます。")
        } else {
            let title = SettingsCopy.followMovedWindowTitle
            remedy = L("To move the window and switch with it, turn on “\(title)” in Settings › Shortcuts.",
                       "ウインドウと一緒に切り替えるには、設定 › ショートカットの「\(title)」をオンにしてください。")
        }
        return reason + Copy.sentenceSeparator + remedy
    }

    /// For the menu and results: the current display's Spaces, or every display's when there are groups, in display order.
    func spaceList() -> [SpaceListItem] {
        guard let snapshot = spaceListing()?.spaceSnapshot() else { return [] }
        let current = snapshot.active ?? system.currentSpaceID()
        guard !snapshot.groups.isEmpty else {
            let numbers = Dictionary(uniqueKeysWithValues: snapshot.desktops.enumerated().map { ($0.element, $0.offset + 1) })
            return snapshot.order.map { SpaceListItem(index: numbers[$0], id: $0, isCurrent: $0 == current, isShown: $0 == current) }
        }
        return snapshot.groups.flatMap { group in
            let numbers = Dictionary(uniqueKeysWithValues: group.desktops.enumerated().map { ($0.element, $0.offset + 1) })
            return group.records.map { SpaceListItem(index: numbers[$0.id], id: $0.id, isCurrent: $0.id == current, isShown: $0.id == group.shown,
                                                     displayName: group.name, otherDisplay: group.display != snapshot.display) }
        }
    }

    /// The menu's Space list: window counts, app names, and whether numbers change with recent use.
    func spaceMenu() -> (entries: [SpaceMenuEntry], reordersByRecentUse: Bool) {
        Self.spaceMenu(list: spaceList(), overview: takeOverview())
    }

    static func spaceMenu(list: [SpaceListItem], overview: SpaceOverview?) -> (entries: [SpaceMenuEntry], reordersByRecentUse: Bool) {
        let byID = Dictionary((overview?.spaces ?? []).map { ($0.spaceID, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = list.map { sp in
            let e = overview == nil ? nil : byID[sp.id]
            return SpaceMenuEntry(index: sp.index, id: sp.id, isCurrent: sp.isCurrent, windows: e?.type == 4 ? nil : e?.windowIDs.count,
                                  apps: e?.apps, fullScreen: e?.type == 4, isShown: sp.isShown, displayName: sp.displayName, otherDisplay: sp.otherDisplay)
        }
        return (entries, overview?.reordersByRecentUse ?? false)
    }

    /// The Space the source's display now shows, when it is not the source. Nil when that cannot be read.
    private func spaceShown(insteadOf source: UInt64?) -> SpaceListItem? {
        let list = spaceList()
        guard let item = list.first(where: { $0.id == source }), !item.isShown else { return nil }
        return list.first { $0.displayName == item.displayName && $0.isShown }
    }

    /// Results also number only standard desktops. A desktop of another display is named with its display;
    /// `list` fixes the display the label is relative to.
    private func spaceLabel(_ id: UInt64, in list: [SpaceListItem]? = nil) -> String {
        if let item = (list ?? spaceList()).first(where: { $0.id == id }), let n = item.index {
            guard item.otherDisplay, let name = item.displayName else { return Copy.desktop(n) }
            return L("\(Copy.desktop(n)) on \(name)", "\(name)の\(Copy.desktop(n))")
        }
        return spaceControl?.label(id) ?? L("Full Screen", "フルスクリーン")
    }

    /// For Settings: reads 79 / 81 with the same function as at run time, sending no events. Unread without observation.
    func systemSpaceShortcut(right: Bool) -> SystemSpaceShortcut {
        spaceControl?.nativeShortcut(right: right) ?? .unread
    }

    private func describe(_ f: SpaceControl.Failure) -> String {
        let text: String
        switch f {
        case .unavailable(let why): text = why
        case .noSuchSpace: text = L("That Space is not on this display.", "その操作スペースはこのディスプレイにありません。")
        case .alreadyThere: text = L("You are already on that Space.", "既にその操作スペースにいます。")
        case .interrupted: text = L("Stopped because input, pause state, or the current Space changed.", "入力・停止・操作スペースの状態が変わったため中断しました。")
        case .timedOut(let why):
            let left = MacItem.moveSpace(right: false), right = MacItem.moveSpace(right: true)
            text = why + Copy.sentenceSeparator + L("Check “\(left)” and “\(right)” in System Settings › Keyboard › Keyboard Shortcuts… › Mission Control.",
                                                    "システム設定 › キーボード › キーボードショートカット… › Mission Controlの「\(left)」と「\(right)」を確認してください。")
        case .notMoved: text = L("Could not confirm that the window moved to the target Space. Check the \(AccessPane.name()) permission, input observation, Mission Control settings, and whether the top center of the window can be dragged.",
                                 "目標の操作スペースへのウインドウの移動を確認できませんでした。「\(AccessPane.name())」の許可・入力監視・Mission Controlの設定と、ウインドウの上端中央をドラッグできるかを確認してください。")
        case .drifted(let to): text = L("After reaching the target Space, the current Space changed to \(spaceLabel(to)). The cause could not be determined.",
                                        "目標の操作スペースを確認した後、現在の操作スペースが\(spaceLabel(to))に変わりました。切り替わった原因は確認できていません。")
        case .movedElsewhere(let to): text = L("The window ended up on \(spaceLabel(to)), not the target Space. The cause could not be determined.",
                                               "ウインドウは\(spaceLabel(to))にありました（目標とは別の操作スペース）。移動先が変わった原因は確認できていません。")
        case .notSwitched: text = L("The window moved to the target Space, but switching to that Space could not be confirmed.",
                                    "ウインドウは目標の操作スペースへ移りましたが、その操作スペースへの切り替えを確認できませんでした。")
        case .moveUnconfirmed: text = L("The move request was sent, but the window's Space did not change while LazySpace waited. No drag was attempted; the window may still move.",
                                        "移動の要求は送りましたが、待っている間にウインドウの所属は変わりませんでした。ドラッグには切り替えていません。遅れて移動することがあります。")
        case .onSeveralSpaces(let ids): text = L("After the move request, the window belongs to several Spaces (\(ids.map { spaceLabel($0) }.joined(separator: ", "))). Where it ended up could not be determined.",
                                                 "移動の要求のあと、ウインドウは複数の操作スペース（\(ids.map { spaceLabel($0) }.joined(separator: "、"))）に属しています。どこに着いたかは判断できません。")
        case .membershipUnreadable: text = L("After the move request, the window's Space could not be read. The window may have closed.",
                                             "移動の要求のあと、ウインドウの所属を読めませんでした。ウインドウが閉じた可能性があります。")
        case .activeSpaceUnreadable: text = L("The window is on the target Space, but the current Space could not be read.",
                                              "ウインドウは目標の操作スペースにありますが、現在の操作スペースを読めませんでした。")
        case .switchUnconfirmed: text = L("LazySpace asked a window or app on the target Space to come to the front, but the Space switch could not be confirmed. Stepping was not attempted because the switch may still happen.",
                                          "目標の操作スペースのウインドウまたはアプリを前面にするよう要求しましたが、操作スペースの切り替えを確認できませんでした。遅れて切り替わることがあるため、1つずつの移動は行っていません。")
        case .activationUnconfirmed: text = L("LazySpace brought an app forward, but could not confirm that the app became active, so it stopped there. LazySpace itself may still be the active app.",
                                              "アプリを前面にしましたが、そのアプリが前面になったことを確認できなかったため、そこで止めました。LazySpaceが前面のまま残っていることがあります。")
        case .hotkeyUnconfirmed:
            let name = MacItem.switchToDesktop(nil)
            text = L("LazySpace sent the macOS “\(name)” shortcut, but could not confirm the Space switch. Nothing else was tried because the switch may still happen.",
                     "macOSの「\(name)」のショートカットを送りましたが、操作スペースの切り替えを確認できませんでした。遅れて切り替わることがあるため、ほかの方法は試していません。")
        case .steppingUnavailable(let issue): text = DesktopShortcuts.steppingText(issue)
        case .frontUnconfirmed: text = L("The window moved to the target Space and LazySpace switched there, but could not confirm focus on the moved window.",
                                         "ウインドウは目標の操作スペースへ移り、その操作スペースへも切り替えましたが、移動したウインドウへのフォーカスを確認できませんでした。")
        case .otherDisplayNoRoute: text = L("LazySpace can switch to a Space of another display only by bringing forward a window or app there, and none could be used.",
                                            "別のディスプレイの操作スペースへは、そこにあるウインドウかアプリを前面にすることでしか切り替えられません。使えるものがありませんでした。")
        case .otherDisplayNeedsDirectMove: text = L("Moving a window to a Space of another display needs the direct move, which is not available on this macOS.",
                                                    "別のディスプレイの操作スペースへウインドウを移すには直接の移動が必要ですが、このmacOSでは使えません。")
        case .routeChanged: text = L("LazySpace switched to a Space on the way, but the order of Spaces on this display then changed, so the remaining steps were not sent.",
                                     "途中の操作スペースへ切り替えましたが、その後このディスプレイの操作スペースの並びが変わったため、残りの移動は送っていません。")
        }
        if let place = spaceControl?.failureDetail(f) { return text + place }
        return text
    }

    /// Switches Spaces without touching windows or settings: in one go via a window or app on the target, one jump to an intermediate Space plus stepping,
    /// or step by step with the read Mission Control shortcut, in that order (`SpaceControl.switchTo`). The whole trip is one operation.
    private func runSpaceSwitch(_ target: SpaceTarget, source: String, authorization: OperationAuthorization? = nil, timeline: OperationTimeline? = nil,
                                resolved accepted: ResolvedSpace? = nil) -> EditAccept {
        let resolved: ResolvedSpace
        if let accepted { resolved = accepted } else {
            switch resolveSpace(target) {
            case .failure(let why): return why.accept
            case .success(let value): resolved = value
            }
        }
        let dest = resolved.id
        if system.currentSpaceID() == dest { return .refused(L("You are already on that Space.", "既にその操作スペースにいます。"), code: "same-space") }
        let switcher: SpaceSwitcher
        if let override = spaceSwitcherOverride { switcher = override }
        else if let sc = spaceControl { switcher = { sc.switchTo(spaceID: $0, plan: $1, shouldContinue: $2) } }
        else { return .refused(L("Space detection is unavailable.", "操作スペースの観測が使えません。"), code: "space-unavailable") }
        prestartPassThroughTap()
        let landing = SpaceLanding(dest: dest)
        return runSimple(kind: "space", progress: L("Switching Spaces", "操作スペースを切り替えています"), source: source, allowPaused: true, authorization: authorization,
                         timeline: timeline, finalize: { [self] in finishSpaceBookkeeping(landing) }) { [self] authorization in
            let overview = takeOverview()
            let spaces = switchCandidateSpaces(to: dest)
            // With rearranging on, the order changes with every switch, so the route via an intermediate Space would change; no jump plus stepping. Not when unknown either.
            let plan = SpaceControl.SwitchPlan(source: authorization.spaceID, windows: windowCandidateTable(spaces, overview: overview),
                                               apps: { [self] in appCandidateTable(spaces, inventory: takeInventory()) },
                                               hopAllowed: overview.map { !$0.reordersByRecentUse } ?? false,
                                               hotkey: desktopShortcutPlan(to: dest),
                                               arrows: arrowPolicy(), timeline: timeline)
            timeline?.mark("prepared")
            // Whether the destination at acceptance (uuid) is still the same Space, so swapped Spaces never send it elsewhere.
            guard destinationStillValid(resolved) else { return OperationResult.note(kind: "space", spaceID: dest, message: Self.destinationChanged, ok: false) }
            switch switcher(dest, plan, { authorization.interruptionReason(system: self.system, control: self.control) == nil }) {
            case .success(let result):
                // Record the arrival (hooks, arrival). `finishSpaceBookkeeping` settles the visible Space and back target right before publishing.
                noteSpaceTransition(to: dest)
                landing.origin = result.fromSpace
                return OperationResult.note(kind: "space", spaceID: dest, message: L("Switched to \(spaceLabel(dest)).", "\(spaceLabel(dest))へ切り替えました。"), ok: true)
            case .failure(let f):
                return OperationResult.note(kind: "space", spaceID: dest, message: describe(f), ok: false)
            }
        }
    }

    // MARK: - Tier 0 (macOS "Switch to Desktop N")

    private var desktopShortcutSource: DesktopShortcutSource? { desktopShortcutSourceOverride ?? spaceControl }

    /// The tier-0 plan; nil when conditions are unmet. A pass-through is recorded here and shown only in `lazyspace status`.
    private func desktopShortcutPlan(to dest: UInt64) -> SpaceControl.HotkeyPlan? {
        guard let source = desktopShortcutSource else { return nil }
        let desktop = source.desktopNumber(of: dest)
        let read = desktop.map { source.desktopShortcut($0) }
        let dock = dockProcessID()
        let screens = screenCount()
        let reorders = reordersByRecentUse()
        lock.lock()
        desktopHotkeys.forget(exceptDock: dock)
        if let desktop, let read { desktopHotkeys.observe(desktop: desktop, read) }
        let decision = DesktopShortcuts.decide(screens: screens, reorders: reorders, desktop: desktop, read: read, dockPID: dock, memory: desktopHotkeys)
        lock.unlock()
        guard case .use(let shortcut, let dockPID) = decision else { return nil }
        return SpaceControl.HotkeyPlan(shortcut: shortcut, dockPID: dockPID, stillEligible: { [self] in
            // Reread conditions outside SpaceControl right before sending too.
            guard screenCount() == 1, !reordersByRecentUse(), dockProcessID() == dockPID else { return false }
            lock.lock(); defer { lock.unlock() }
            return !desktopHotkeys.isSuppressed(dock: dockPID, shortcut)
        }, report: { [self] event in
            lock.lock()
            switch event {
            case .arrived: desktopHotkeys.recordArrival(dock: dockPID, shortcut)
            case .passedThrough: desktopHotkeys.recordPassThrough(dock: dockPID, shortcut)
            }
            lock.unlock()
        })
    }

    /// Suppression and records for stepping's left/right keys, separate for left and right. Expiry is the same for planning and status (`HotkeyMemory.observe`). nil without Space observation.
    private func arrowPolicy() -> SpaceControl.ArrowPolicy? {
        guard let source = desktopShortcutSource else { return nil }
        let dock = dockProcessID()
        let reads = [false, true].map { ($0, source.arrowShortcut(right: $0)) }
        lock.lock()
        desktopHotkeys.forget(exceptDock: dock)
        for (right, read) in reads { desktopHotkeys.observe(right: right, read) }
        lock.unlock()
        return SpaceControl.ArrowPolicy(isSuppressed: { [self] shortcut in
            guard let dock else { return false }
            lock.lock(); defer { lock.unlock() }
            return desktopHotkeys.isSuppressed(dock: dock, shortcut)
        }, stillEligible: { [self] in dockProcessID() == dock }, report: { [self] shortcut, event in
            guard let dock else { return }
            lock.lock()
            switch event {
            case .arrived: desktopHotkeys.recordArrival(dock: dock, shortcut)
            case .passedThrough: desktopHotkeys.recordPassThrough(dock: dock, shortcut)
            }
            lock.unlock()
        })
    }

    /// Left and right states for `lazyspace status` and Settings (nil without Space observation).
    func arrowShortcutStates() -> (left: DesktopShortcuts.State, right: DesktopShortcuts.State)? {
        guard let source = desktopShortcutSource else { return nil }
        let dock = dockProcessID()
        let left = source.arrowShortcut(right: false), right = source.arrowShortcut(right: true)
        lock.lock(); defer { lock.unlock() }
        desktopHotkeys.forget(exceptDock: dock)
        desktopHotkeys.observe(right: false, left)
        desktopHotkeys.observe(right: true, right)
        return (DesktopShortcuts.arrowState(left, dock: dock, memory: desktopHotkeys), DesktopShortcuts.arrowState(right, dock: dock, memory: desktopHotkeys))
    }

    /// The `lazyspace status` line; nil without Space observation.
    func desktopShortcutStatus() -> String? {
        desktopShortcutStates().map { DesktopShortcuts.statusLine(global: $0.global, states: $0.states) }
    }

    /// Per-Desktop state. Numbers are macOS Desktop numbers (counting standard Desktops), within the range of existing Desktops (up to 16).
    func desktopShortcutStates() -> (global: DesktopShortcutBlock?, states: [(desktop: Int, state: DesktopShortcuts.State)])? {
        guard let source = desktopShortcutSource else { return nil }
        let dock = dockProcessID()
        let global: DesktopShortcutBlock?
        let count = source.ordinaryDesktopCount()
        if screenCount() != 1 { global = .multipleDisplays }
        else if reordersByRecentUse() { global = .reordersByRecentUse }
        else if count == nil { global = .notOrdinaryDesktop }
        else if dock == nil { global = .dockUnknown }
        else { global = nil }
        guard global == nil, let count, let dock else { return (global, []) }
        let reads = (count > 0 ? Array(1...min(count, 16)) : []).map { ($0, source.desktopShortcut($0)) }
        lock.lock(); defer { lock.unlock() }
        // Same expiry as planning: the Dock changed, or the setting changed (off, a different assignment). A Carbon overlap is not a settings change, so records stay.
        desktopHotkeys.forget(exceptDock: dock)
        for (desktop, read) in reads { desktopHotkeys.observe(desktop: desktop, read) }
        let states: [(desktop: Int, state: DesktopShortcuts.State)] = reads.map { desktop, read in
            switch read {
            case .usable(let shortcut):
                if desktopHotkeys.isSuppressed(dock: dock, shortcut) { return (desktop, .paused) }
                return (desktop, desktopHotkeys.isConfirmed(dock: dock, shortcut) ? .working : .unverified)
            case .conflict: return (desktop, .ineligible(.conflict))
            case .off: return (desktop, .ineligible(.off))
            case .unusable: return (desktop, .ineligible(.unusable))
            case .unread: return (desktop, .ineligible(.unread))
            }
        }
        return (nil, states)
    }

    /// Spaces to build candidates for: the target and the Spaces between it and the current one (jump-plus-stepping waypoints).
    private func switchCandidateSpaces(to dest: UInt64) -> [UInt64] {
        var spaces = [dest]
        if let order = spaceListing()?.orderedSpaces().map(\.id), let current = system.currentSpaceID(),
           let i = order.firstIndex(of: current), let j = order.firstIndex(of: dest), abs(i - j) > 1 {
            spaces += Array(order[(min(i, j) + 1)..<max(i, j)])
        }
        return spaces
    }

    private func focusAndLayout(_ space: UInt64) -> (recent: [WindowID], arranged: [WindowID]) {
        let key = String(space)
        lock.lock(); defer { lock.unlock() }
        return (focusHistory[key] ?? [], state.layouts[key]?.windowIDs ?? [])
    }

    /// Window candidate table. The raw window list is not read.
    func windowCandidateTable(_ spaces: [UInt64], overview: SpaceOverview?) -> [UInt64: [SpaceControl.Candidate]] {
        var table: [UInt64: [SpaceControl.Candidate]] = [:]
        for space in spaces {
            let (recent, arranged) = focusAndLayout(space)
            table[space] = Self.windowCandidates(recent: recent, arranged: arranged, seen: overview?.spaces.first { $0.spaceID == space }?.windowIDs ?? [])
        }
        return table
    }

    /// App candidate table. SpaceControl calls it once when no window candidate was usable (on the operations queue, under the same authorization baseline).
    func appCandidateTable(_ spaces: [UInt64], inventory: AppWindowInventory?) -> [UInt64: [SpaceControl.Candidate]] {
        guard let inventory else { return [:] }
        let owners = inventory.owners
        var table: [UInt64: [SpaceControl.Candidate]] = [:]
        for space in spaces {
            let (recent, arranged) = focusAndLayout(space)
            table[space] = Self.appCandidates(recent: recent, arranged: arranged, apps: inventory.eligibleApps(on: space), owners: owners)
        }
        return table
    }

    /// Window candidates for one Space (priority order): the window last in front there, layout windows, then observed windows (by ID).
    /// `raise` refuses windows without a retained AX element, so SpaceControl moves to the next candidate.
    static func windowCandidates(recent: [WindowID], arranged: [WindowID], seen: [WindowID]) -> [SpaceControl.Candidate] {
        var windows: [CGWindowID] = []
        // Observation order is dictionary order, so fix it by window ID.
        for id in recent + arranged + seen.sorted(by: { $0.raw < $1.raw }) where !windows.contains(id.raw) { windows.append(id.raw) }
        return windows.map { .window($0) }
    }

    /// App candidates for one Space (apps with windows only there): those with windows in the front history (newest first) -> those with layout windows -> ascending pid. Deduplicated by pid.
    static func appCandidates(recent: [WindowID], arranged: [WindowID], apps: [AppWindowInventory.Candidate], owners: [CGWindowID: pid_t]) -> [SpaceControl.Candidate] {
        func rank(_ pid: pid_t) -> (Int, Int, pid_t) {
            if let i = recent.firstIndex(where: { owners[$0.raw] == pid }) { return (0, i, pid) }
            if let i = arranged.firstIndex(where: { owners[$0.raw] == pid }) { return (1, i, pid) }
            return (2, 0, pid)
        }
        var pids = Set<pid_t>()
        return apps.filter { pids.insert($0.pid).inserted }.sorted { rank($0.pid) < rank($1.pid) }.map { .app($0.pid, bundleID: $0.bundleID) }
    }

    /// Sends the focused window to another Space (membership change and activation with the direct path, otherwise a synthesized Mission Control drag), follows to that Space, and integrates the window if it has a layout.
    /// `menuTarget`: the window pinned by the menu, checked instead of the focused window (an old AX focus of the same app is not reused), as in `runSendToSpace`.
    private func runMoveToSpace(_ target: WindowID, target spaceTarget: SpaceTarget, source: String, authorization: OperationAuthorization? = nil,
                                timeline: OperationTimeline? = nil, resolved accepted: ResolvedSpace? = nil, menuTarget: MenuWindowTarget? = nil) -> EditAccept {
        let resolved: ResolvedSpace
        if let accepted { resolved = accepted } else {
            switch resolveSpace(spaceTarget, desktopsOnly: true) {
            case .failure(let why): return why.accept
            case .success(let value): resolved = value
            }
        }
        let dest = resolved.id
        let current = system.currentSpaceID()
        if current == dest { return .refused(L("The window is already on that Space.", "ウインドウは既にその操作スペースにあります。"), code: "same-space") }
        let census = takeCensus(current)
        guard let targetPID = census.windows[target] else { return .refused(L("The focused window is not on the current Space.", "フォーカス中のウインドウは現在の操作スペースにありません。"), code: "target-not-found") }
        let mover: SpaceMover
        if let override = spaceMoverOverride { mover = override }
        else if let sc = spaceControl {
            // After moving, follow by bringing the carried window forward; follow never depends on the Desktop key's response.
            // Only the drag used without the direct move uses the left/right shortcuts.
            mover = { [self] wid, frame, dest, gates in
                sc.moveWindow(wid, frame: frame, toSpace: dest, arrows: arrowPolicy(), timeline: timeline, hooks: gates.hooks, shouldContinue: gates.shouldContinue)
            }
        }
        else { return .refused(L("Space detection is unavailable.", "操作スペースの観測が使えません。"), code: "space-unavailable") }
        prestartPassThroughTap()
        let landing = SpaceLanding(dest: dest)
        let sameTarget = { [self] in menuTarget.map { self.menuWindowTarget() == $0 } ?? (frontWindowForEdit() == target) }
        return runSimple(kind: "move-to-space", progress: L("Moving the window to another Space", "ウインドウを別の操作スペースへ移動しています"), source: source, target: target,
                         requireFocus: menuTarget == nil, authorization: authorization,
                         timeline: timeline, finalize: { [self] in finishSpaceBookkeeping(landing) }) { [self] authorization in
            guard case .frame(let frame) = system.readFrame(target), sameTarget(),
                  system.currentSpaceID() == authorization.spaceID,
                  authorization.interruptionReason(system: system, control: control) == nil else {
                return OperationResult.note(kind: "move-to-space", spaceID: current, message: L("Not moved because the window or the pause state changed.", "ウインドウまたは停止状態が変わったため移動しません。"), ok: false)
            }
            timeline?.mark("prepared")
            guard destinationStillValid(resolved), system.currentSpaceID() != dest else {
                return OperationResult.note(kind: "move-to-space", spaceID: current, message: Self.destinationChanged, ok: false)
            }
            let authorized = { authorization.interruptionReason(system: self.system, control: self.control) == nil }
            // Another display: the direct move keeps the old frame, so the window is fitted onto that display before it is brought forward there.
            var fitted: Bool?
            let hooks = SpaceControl.MoveHooks(beforeIssue: {
                (menuTarget.map { self.menuWindowTarget() == $0 } ?? true) && authorized() && self.destinationStillValid(resolved) && authorized()
            }, beforeRaise: { [self] in
                if resolved.otherDisplay { fitted = fitOntoDisplay(target, pid: targetPID, resolved: resolved, gate: authorized) }
            })
            let moved = mover(CGWindowID(target.raw), frame, dest, MoveGates(shouldContinue: authorized, hooks: hooks))
            // Judge the departure from the window's actual membership, not the returned success (a reported failure may still have moved it to an intermediate Space).
            let departedTo = current.flatMap { noteDepartureIfConfirmed(target, from: $0) }
            // Record the arrival (hooks, arrival). After position correction, `finishSpaceBookkeeping` settles the visible Space and back target right before publishing.
            if case .success(let result) = moved {
                noteSpaceTransition(to: dest)
                landing.origin = result.fromSpace
            }
            switch moved {
            case .success:
                guard authorization.interruptionReason(system: system, control: control) == nil, system.currentSpaceID() == dest else {
                    return OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("After the window moved, input, pause state, or the current Space changed, so position correction and adding it to the layout were canceled.",
                                                                                                "ウインドウの移動後に入力・停止・操作スペースの状態が変わったため、位置の補正とレイアウトへの追加を中止しました。"), ok: false)
                }
                if resolved.otherDisplay {
                    if fitted == false {
                        var result = OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("The window moved to \(spaceLabel(dest)), but moving it onto that display could not be confirmed.",
                                                                                                         "ウインドウは\(spaceLabel(dest))へ移りましたが、そのディスプレイの上へ動かせたかは確認できませんでした。"), ok: false)
                        result.outcome = .partial
                        return result
                    }
                }
                // Undo the few points of offset used for drag recognition (if the destination has a layout, integration moves it again anyway).
                else if case .frame(let after) = system.readFrame(target), after != frame, after.size == frame.size,
                   abs(after.origin.x - frame.origin.x) <= 20, abs(after.origin.y - frame.origin.y) <= 20 {
                    guard authorization.interruptionReason(system: system, control: control) == nil, system.currentSpaceID() == dest else {
                        return OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("Position correction after the move was canceled.", "移動後の位置の補正を中断しました。"), ok: false)
                    }
                    let write = system.writeFrame(target, frame: frame, currentFrame: after, timeout: limits.perAppTimeout) { [self] in
                        system.axTrusted && authorization.interruptionReason(system: system, control: control) == nil && system.currentSpaceID() == dest
                    }
                    guard write == .issued, case .frame(let actual) = system.readFrame(target), actual.matches(frame, tolerance: limits.tolerance) else {
                        var result = OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("The window moved to the Space, but its position correction could not be confirmed.", "操作スペースへの移動は確認しましたが、移動後の位置の補正は確認できませんでした。"), ok: false)
                        result.outcome = .partial
                        return result
                    }
                }
                // Recheck input, pause, cancellation, and Space changes during position correction (writes and readback) or the frame read, before creating arrival handling and before reporting success.
                // If it stops here, no arrival handling is created under the new cancellation generation and it is not success (the window is on the destination).
                guard authorization.interruptionReason(system: system, control: control) == nil, system.currentSpaceID() == dest else {
                    return OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("The window moved to \(spaceLabel(dest)), but input, pause state, or the current Space changed before the move finished, so it was not added to the layout.",
                                                                                                "ウインドウは\(spaceLabel(dest))へ移りましたが、移動の終わりまでに入力・停止・操作スペースの状態が変わったため、レイアウトには加えていません。"), ok: false)
                }
                // On the arrived Space, this window joins the layout without the arrival dwell, on the same operations queue as the tick.
                expectArrival(of: target, on: dest)
                return OperationResult.note(kind: "move-to-space", spaceID: dest, message: L("Moved the window to \(spaceLabel(dest)).", "ウインドウを\(spaceLabel(dest))へ移動しました"), ok: true)
            case .failure(let f):
                var result = OperationResult.note(kind: "move-to-space", spaceID: dest, message: describe(f), ok: false)
                if departedTo != nil { result.outcome = .partial }
                return result
            }
        }
    }

    /// Default `move-to-space`: changes only the window's membership without switching. Refused without the bridged move (dragging switches Spaces).
    /// The destination is resolved once at acceptance and rechecked right before issuing for uuid, same display, and differing from the current Space.
    /// After sending, the newest other window taken from the front history at acceptance is brought forward only when the contract is confirmed (`restoreFront`).
    /// If macOS changes the Space, the observed Space is noted and not reverted. No Space-change hook or `space back` target is created,
    /// except that an actually observed change is recorded before publishing (the same record as a tick, without waiting for one).
    private func runSendToSpace(_ target: WindowID, target spaceTarget: SpaceTarget, source: String, authorization: OperationAuthorization? = nil,
                                timeline: OperationTimeline? = nil, resolved accepted: ResolvedSpace? = nil, menuTarget: MenuWindowTarget? = nil) -> EditAccept {
        let resolved: ResolvedSpace
        if let accepted { resolved = accepted } else {
            switch resolveSpace(spaceTarget, desktopsOnly: true) {
            case .failure(let why): return why.accept
            case .success(let value): resolved = value
            }
        }
        let dest = resolved.id
        let current = system.currentSpaceID()
        if current == dest { return .refused(L("The window is already on that Space.", "ウインドウは既にその操作スペースにあります。"), code: "same-space") }
        let sender: SpaceSender
        if let override = spaceSenderOverride { sender = override }
        else if let sc = spaceControl { sender = { sc.sendWindow($0, toSpace: $1, timeline: timeline, beforeIssue: $2.beforeIssue, afterIssue: $2.afterIssue) } }
        else { return .refused(L("Space detection is unavailable.", "操作スペースの観測が使えません。"), code: "space-unavailable") }
        // Dragging instead would switch Spaces, so without the direct move it is refused.
        guard sendAvailableOverride ?? spaceControl?.canSendWithoutFollowing ?? true else {
            return .refused(Self.sendUnavailable(fromShortcutOrMenu: UserWorkQueue.queuesWhileBusy(source), followSetting: config.followMovedWindow), code: "send-unavailable")
        }
        let census = takeCensus(current)
        guard let targetPID = census.windows[target] else { return .refused(L("The focused window is not on the current Space.", "フォーカス中のウインドウは現在の操作スペースにありません。"), code: "target-not-found") }
        // The restore candidate comes from the front history before sending (unaffected by history updates after). The front app at acceptance is noted too
        // (if another app comes forward later without input, no restoration).
        let restore = current.flatMap { restoreCandidate(excluding: target, space: $0, census: census) }
            .map { RestoreContext(candidate: $0, acceptedFrontPID: census.frontmostPID ?? targetPID, sentWindow: target, activations: activationCount()) }
        // No follow, so no back target; but if macOS is observed to have actually changed the Space, record it before publishing (without waiting for a tick).
        let finalize = { [self] in
            if let observed = system.currentSpaceID(), observed != current { noteSpaceTransition(to: observed) }
        }
        return runSimple(kind: "send-to-space", progress: L("Sending the window to another Space", "ウインドウを別の操作スペースへ送っています"), source: source, target: target,
                         requireFocus: menuTarget == nil, authorization: authorization, timeline: timeline, finalize: finalize) { [self] authorization in
            // The menu sticks to the CG front window that decided availability; an old AX focus of the same app is not reused.
            let sameTarget = menuTarget.map { self.menuWindowTarget() == $0 } ?? (frontWindowForEdit() == target)
            guard sameTarget, system.currentSpaceID() == authorization.spaceID,
                  authorization.interruptionReason(system: system, control: control) == nil else {
                return OperationResult.note(kind: "send-to-space", spaceID: current, message: L("Not sent because the window or the pause state changed.", "ウインドウまたは停止状態が変わったため送りません。"), ok: false)
            }
            guard destinationStillValid(resolved), system.currentSpaceID() != dest else {
                return OperationResult.note(kind: "send-to-space", spaceID: current, message: Self.destinationChanged, ok: false)
            }
            timeline?.mark("prepared")
            let identity = identity(of: target, pid: targetPID)
            // Labels are relative to the source display (after a send to another display, focus can take the current Space there).
            let labels = spaceList()
            let destLabel = spaceLabel(dest, in: labels)
            let authorized = { authorization.interruptionReason(system: self.system, control: self.control) == nil }
            let outcome = sender(CGWindowID(target.raw), dest, SendGates(beforeIssue: {
                let sameTarget = menuTarget.map { self.menuWindowTarget() == $0 } ?? true
                // A display disconnected or swapped after acceptance never redirects the window.
                return sameTarget && authorized() && self.destinationStillValid(resolved) && authorized()
            }, afterIssue: authorized))
            // The departure is recorded from the window's actual membership, independent of overall success.
            if let current { noteDepartureIfConfirmed(target, from: current) }
            let source = authorization.spaceID
            var fitNote = ""
            if case .confirmed = outcome, resolved.otherDisplay, fitOntoDisplay(target, pid: targetPID, resolved: resolved, gate: authorized) == false {
                fitNote = Copy.sentenceSeparator + L("Moving it onto that display could not be confirmed, so it may not be visible there yet.",
                                                     "そのディスプレイの上へ動かせたかは確認できなかったため、まだ見えないことがあります。")
            }
            // Front restoration only for confirmed sends, and only while still on the source Space,
            // or while focus that went with the window to another display left the source shown there (focus comes back to the source display).
            // macOS can move focus there at any moment, so for another display every gate accepts the destination as current.
            var restoreNote = ""
            var restored = false
            if case .confirmed = outcome, let source, let restore {
                // One read decides both cases; later changes are rechecked by the gates inside.
                let current = system.currentSpaceID()
                let focusWent = resolved.otherDisplay && current == dest && system.spaceDisplay(source)?.shown == true
                if current == source || focusWent {
                    restored = restoreFront(restore, on: source, comingFrom: resolved.otherDisplay ? dest : nil, authorization: authorization)
                    if !restored { restoreNote = Copy.sentenceSeparator + L("The previous window was not brought forward.", "直前のウインドウは前面に戻していません。") }
                }
            }
            // Focus left on the destination's display is named, since the shortcuts now act on that display.
            // This includes a restoration not attempted because the source's display could not be read: focus is still there.
            if case .confirmed = outcome, resolved.otherDisplay, system.currentSpaceID() == dest, let name = labels.first(where: { $0.id == dest })?.displayName {
                restoreNote = Copy.sentenceSeparator + (restore == nil
                    ? L("Focus went with the window to \(name).", "フォーカスはウインドウとともに\(name)へ移りました。")
                    : restored
                    ? L("Focus then went to \(name).", "その後、フォーカスは\(name)へ移りました。")
                    : L("The previous window was not brought forward, so focus stays on \(name).", "直前のウインドウは前面に戻していないため、フォーカスは\(name)に移ったままです。"))
            }
            // The position note comes from the last observation after restoration (restoration may move the display to another Space). `finalize` records with the same observation right before publishing.
            // If macOS changed the Space without follow, only note what was observed (no revert).
            // It names what the source display shows; focus alone can follow the window to another display.
            let moved = spaceShown(insteadOf: source).map { shown in
                let label = spaceLabel(shown.id, in: labels)
                // With several displays, the display is named so it is not mistaken for the one the window went to.
                return Copy.sentenceSeparator + (shown.displayName.map { L("\($0) then moved to \(label).", "その後、\($0)の表示が\(label)に移りました。") }
                    ?? L("The display then moved to \(label).", "その後、表示が\(label)に移りました。"))
            } ?? ""
            // With an uncertain result, stop layout writes to that window and reconcile by membership (no resend, no drag).
            switch outcome {
            case .unconfirmed, .elsewhere, .interrupted:
                if let source { holdUncertainSend(identity, source: source, target: dest, targetUUID: resolved.uuid) }
            case .confirmed:
                if let uuid = resolved.uuid { addPendingArrival(identity, spaceUUID: uuid) }
                if resolved.otherDisplay, let display = resolved.display { noteShownArrival(identity, space: dest, display: display) }
            case .notIssued: break
            }
            switch outcome {
            case .confirmed:
                let message = L("Sent the window to \(destLabel).", "ウインドウを\(destLabel)へ送りました。") + fitNote + (moved.isEmpty ? restoreNote : moved)
                return OperationResult.note(kind: "send-to-space", spaceID: source, message: message, ok: true)
            case .notIssued(let failure):
                return OperationResult.note(kind: "send-to-space", spaceID: source, message: describe(failure), ok: false)
            case .unconfirmed:
                var result = OperationResult.note(kind: "send-to-space", spaceID: source, message: L("The request to send the window was made, but its new Space could not be confirmed. It may still move.", "ウインドウを送る要求はしましたが、移った先を確認できませんでした。あとで移ることがあります。") + moved, ok: false)
                result.outcome = .partial
                return result
            case .elsewhere(let space):
                var result = OperationResult.note(kind: "send-to-space", spaceID: source, message: L("The window ended up on \(spaceLabel(space, in: labels)) instead of \(destLabel).", "ウインドウは\(destLabel)ではなく\(spaceLabel(space, in: labels))に移りました。") + moved, ok: false)
                result.outcome = .partial
                return result
            case .interrupted:
                var result = OperationResult.note(kind: "send-to-space", spaceID: source, message: L("Stopped after the request to send the window was made, because of input, pausing or cancellation. The window may still move.", "ウインドウを送る要求のあと、入力・停止・取消のため確認をやめました。ウインドウがあとで移ることがあります。") + moved, ok: false)
                result.outcome = .partial
                return result
            }
        }
    }

    /// After a confirmed move to another display's Space: one frame that fits the window into that display's work area (same size when it fits, centered),
    /// unless its center is already there. Before each setter: `gate`, the same window (pid), membership only the destination, and the destination still on the
    /// same display with the same work area. nil: nothing needed; true: written and read back on that display; false: not confirmed.
    private func fitOntoDisplay(_ id: WindowID, pid: Int32, resolved: ResolvedSpace, gate: @escaping () -> Bool) -> Bool? {
        guard let display = system.spaceDisplay(resolved.id), display.display == resolved.display, case .frame(let frame) = system.readFrame(id) else { return false }
        let area = display.workArea
        if area.contains(CGPoint(x: frame.midX, y: frame.midY)) { return nil }
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let fitted = CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        // The gate once more after the slower reads, so input during them stops the setter.
        let still = { [self] in
            gate() && system.spacesOf(id) == [resolved.id] && system.windowRecords([id])?[id]?.pid == pid
                && system.spaceDisplay(resolved.id).map { $0.display == resolved.display && $0.workArea == area } == true && gate()
        }
        guard still(), system.writeFrame(id, frame: fitted, timeout: limits.perAppTimeout, shouldContinue: still) == .issued,
              case .frame(let actual) = system.readFrame(id) else { return false }
        return area.contains(CGPoint(x: actual.midX, y: actual.midY))
    }

    /// Restore candidate: a window and its owner pid, chosen at acceptance by `restoreCandidate`.
    struct RestoreCandidate: Equatable { var window: WindowID; var pid: Int32 }
    /// Restoration context: the candidate, the front app at acceptance, the sent window, and the activation count at acceptance.
    struct RestoreContext: Equatable {
        var candidate: RestoreCandidate
        var acceptedFrontPID: Int32
        var sentWindow: WindowID
        var activations: UInt64
    }

    /// The latest window in the front history that is still visible and only on this Space.
    /// The census also lists other displays' windows, and the history can name windows that left this Space since.
    private func restoreCandidate(excluding sent: WindowID, space: UInt64, census: Census) -> RestoreCandidate? {
        lock.lock(); let history = focusHistory[String(space)] ?? []; lock.unlock()
        for id in history where id != sent {
            if let pid = census.windows[id], system.spacesOf(id) == [space] { return RestoreCandidate(window: id, pid: pid) }
        }
        return nil
    }

    /// Brings the candidate forward after sending. Contract: the same owner process is alive, the window is visible on the current Space with membership only the source, and it is a
    /// standard window on the current Space; then a gated `raise` (operation running, no interruption, still on the source). Success once this raise reports it requested the owner's
    /// activation (`requested(owner)`) and the owner app is observed in front. If anything is missing, no restoration (never another app's window).
    /// Gates (before AXRaise and before the activation that runs later on the main thread): no interruption, input observable, still on the source, the caller's gate,
    /// no activation since acceptance (activation count unchanged; also counts another app coming forward and the original coming back),
    /// front app and window known, the front app is the acceptance-time app or the candidate's, and the front window is the sent window, the candidate, or none (another window of the same app in front blocks it).
    /// An unknown front means no restoration.
    /// `comingFrom`: the destination on another display that focus went to with the sent window. It may be current until the candidate comes forward,
    /// the candidate is observed on the shown source meanwhile, and success also needs the source to be current again.
    private func restoreFront(_ context: RestoreContext, on source: UInt64, comingFrom: UInt64? = nil, authorization: OperationAuthorization, gate: (() -> Bool)? = nil) -> Bool {
        let candidate = context.candidate
        // While focus is on `comingFrom`, the source must still be shown on its display (unknown stops it).
        let onSourceOrComing = { [self] in
            let current = system.currentSpaceID()
            return current == source || (comingFrom != nil && current == comingFrom && system.spaceDisplay(source)?.shown == true)
        }
        let handoff = RestoreHandoff()
        defer { handoff.finish() }
        // Whether this raise reported requesting the candidate app's activation (a synchronized receipt). Count increases after that report are our own.
        let ownActivationReported = { handoff.requested == .some(.some(candidate.pid)) }
        let ok = { [self] in
            guard authorization.interruptionReason(system: system, control: control) == nil, system.inputObservationAvailable,
                  onSourceOrComing(), gate?() ?? true else { return false }
            // Until our own activation is reported (before AXRaise and right before the later main-thread activation), the count must equal the acceptance count.
            // After the report the count naturally rises, so only the front observation decides (our own report is never mistaken for an intervening activation).
            if activationCount() != context.activations, !ownActivationReported() { return false }
            let census = takeCensus(source)
            guard let front = census.frontmostPID, front == context.acceptedFrontPID || front == candidate.pid else { return false }
            if let window = census.frontWindow, window != context.sentWindow, window != candidate.window { return false }
            return true
        }
        guard ok(), !system.processExited(candidate.pid), takeCensus(source).windows[candidate.window] == candidate.pid,
              system.spacesOf(candidate.window) == [source] else { return false }
        // Observed on the source: as the current Space, or as the shown Space while focus is on `comingFrom`.
        let observe = { [self] () -> ObservedWindow? in
            let observed = system.currentSpaceID() == source
                ? system.snapshot(limitingTo: [candidate.window])
                : system.snapshot(ofShownSpace: source, windows: [candidate.window], deadline: Date().addingTimeInterval(limits.perAppTimeout))
            guard observed.spaceID == source else { return nil }
            return observed.windows.first { $0.id == candidate.window }
        }
        // Focus can move between displays during the read, so one more read after the gate.
        guard let window = observe() ?? (comingFrom != nil && ok() ? observe() : nil),
              window.kind == .standard, window.membership == .current, window.pid == candidate.pid else { return false }
        guard ok() else { return false }
        let write = system.raise(candidate.window, timeout: limits.perAppTimeout, activateIf: { handoff.live && ok() }, activated: { handoff.report($0) })
        guard write == .issued else { return false }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            // Receive the report first, then check the gates.
            let requested = handoff.requested
            if case .some(.none) = requested { return false } // no activation was queued
            if case .some(.some(let pid)) = requested, pid != candidate.pid { return false }
            guard ok() else { return false }
            if case .some(.some) = requested, takeCensus(source).frontmostPID == candidate.pid, system.currentSpaceID() == source { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// The restoring raise's report (from the main thread) and whether the operation continues.
    private final class RestoreHandoff {
        private let lock = NSLock()
        private var reported: Int32?? = nil
        private var alive = true
        var live: Bool { lock.lock(); defer { lock.unlock() }; return alive }
        var requested: Int32?? { lock.lock(); defer { lock.unlock() }; return reported }
        func report(_ pid: Int32?) { lock.lock(); if reported == nil { reported = .some(pid) }; lock.unlock() }
        func finish() { lock.lock(); alive = false; lock.unlock() }
    }

    /// Toggles native full screen / minimize (one AX attribute). Leaving and rejoining the layout is picked up by the tick.
    private func runWindowState(_ target: WindowID, _ attribute: WindowStateAttribute, source: String, authorization: OperationAuthorization? = nil, desiredState: Bool? = nil, requireFocus: Bool = true) -> EditAccept {
        let kind = attribute == .fullscreen ? "edit:fullscreen" : "edit:minimize"
        return runSimple(kind: kind, progress: attribute == .fullscreen ? L("Toggling full screen", "フルスクリーンを切り替えています") : L("Minimizing", "最小化しています"), source: source,
                         target: target, allowFullscreen: attribute == .fullscreen, allowMinimized: attribute == .minimized && desiredState != nil, requireFocus: requireFocus, authorization: authorization) { [self] authorization in
            guard let before = system.readWindowState(target, attribute) else {
                return OperationResult.note(kind: kind, spaceID: authorization.spaceID, message: L("Not changed because the window's current state could not be read.", "ウインドウの現在の状態を確認できないため操作しません。"), ok: false)
            }
            guard authorization.interruptionReason(system: system, control: control) == nil, system.currentSpaceID() == authorization.spaceID, (!requireFocus || frontWindowForEdit() == target) else {
                return OperationResult.note(kind: kind, spaceID: authorization.spaceID, message: L("Not changed because the pause state, input, or the current Space changed.", "停止・入力・操作スペースの状態が変わったため操作しません。"), ok: false)
            }
            if desiredState == before {
                var result = OperationResult.note(kind: kind, spaceID: authorization.spaceID, message: L("Already in the requested state.", "指定した状態です。"), ok: true)
                result.issued = 0
                result.verified = true
                return result
            }
            let mayWrite = { [self] in
                let focused = !requireFocus || frontWindowForEdit() == target
                return focused && system.axTrusted && authorization.interruptionReason(system: system, control: control) == nil
                    && system.currentSpaceID() == authorization.spaceID
            }
            let r = desiredState.map { system.setWindowState(target, attribute, value: $0, timeout: limits.perAppTimeout, shouldContinue: mayWrite) }
                ?? system.toggleWindowState(target, attribute, timeout: limits.perAppTimeout, shouldContinue: mayWrite)
            switch r {
            case .issued:
                Thread.sleep(forTimeInterval: limits.settleDelay)
                let expected = desiredState ?? !before
                let deadline = Date().addingTimeInterval(attribute == .fullscreen ? 1.5 : 0.5)
                var after = system.readWindowState(target, attribute)
                while after != expected && Date() < deadline && authorization.interruptionReason(system: system, control: control) == nil {
                    Thread.sleep(forTimeInterval: 0.05)
                    after = system.readWindowState(target, attribute)
                }
                let verified = after == expected
                var result = OperationResult.note(kind: kind, spaceID: system.currentSpaceID(),
                    message: verified
                        ? (attribute == .fullscreen ? L("Full screen toggled.", "フルスクリーンの切替を確認しました") : (expected ? L("Window minimized.", "最小化を確認しました") : L("Window restored.", "最小化の解除を確認しました")))
                        : L("The app accepted the request, but the window's state change could not be confirmed.", "要求は受け付けましたが、ウインドウの状態変化を確認できませんでした。"), ok: true)
                result.outcome = verified ? .complete : .partial
                result.verified = verified
                result.issued = 1
                return result
            case .gone: return OperationResult.note(kind: kind, spaceID: system.currentSpaceID(), message: L("The window could not be found.", "ウインドウが見つかりません。"), ok: false)
            case .timedOut: return OperationResult.note(kind: kind, spaceID: system.currentSpaceID(), message: L("The app did not respond.", "アプリが応答しませんでした。"), ok: false)
            case .rejected(let why): return OperationResult.note(kind: kind, spaceID: system.currentSpaceID(), message: L("The app rejected the request: \(why)", "アプリが受け付けませんでした: \(why)"), ok: false)
            }
        }
    }

    /// Limit for waiting on AX focus at acceptance.
    let acceptanceFocusTimeout: TimeInterval = 0.2

    /// The front window targeted by edits and single actions (fullscreen / minimize / move-to-space).
    /// The AX focused window if visible on this Space; otherwise the front app's first window in CGWindowList order
    /// (on a full-screen Space, the app's AX focused window may point at a standard window left on the original Space; seen with TextEdit).
    func frontWindowForEdit() -> WindowID? {
        guard let space = system.currentSpaceID() else { return nil }
        let census = takeCensus(space)
        // Acceptance often runs on the main thread; if the front app does not respond, use the front window from the window list.
        let focused = system.focusedWindowID(within: acceptanceFocusTimeout)
        guard census.spaceID == space, system.currentSpaceID() == space, let pid = census.frontmostPID else { return nil }
        if let focused, census.windows[focused] == pid { return focused }
        return census.frontWindow.flatMap { census.windows[$0] == pid ? $0 : nil }
    }

    /// Runs a single action that does not change the layout on the operations queue, taking the running slot.
    func runSimple(kind: String, progress: String, source: String, target: WindowID? = nil,
                           allowFullscreen: Bool = false, allowPaused: Bool = false, allowMinimized: Bool = false,
                           requireFocus: Bool = true, authorization suppliedAuthorization: OperationAuthorization? = nil,
                           timeline: OperationTimeline? = nil, finalize: (() -> Void)? = nil,
                           body: @escaping (OperationAuthorization) -> OperationResult) -> EditAccept {
        lock.lock()
        if running != nil { lock.unlock(); return .busy }
        let id = UUID().uuidString
        let authorization = suppliedAuthorization ?? OperationAuthorization(system: system, control: control, allowPaused: allowPaused)
        running = id
        // Note the kind too (so the Space's pause can cancel automatic operations, including `auto-route`).
        runningKind = kind
        progressText = progress
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
        onOperationID?(id)
        performOnOperationQueue { [self] in
            timeline?.mark("queued")
            // Space switches have no target window: check the same authorization as before without waiting on a window.
            let snap = target == nil
                ? Snapshot(trusted: system.axTrusted, spaceID: system.currentSpaceID(), workArea: .zero,
                           windows: [], spaceObservationAvailable: system.spaceObservationAvailable)
                : system.snapshot(limitingTo: target.map { [$0] })
            func refusal(_ reason: StopReason, _ message: String) -> OperationResult {
                var r = OperationResult.note(kind: kind, spaceID: authorization.spaceID, message: message, ok: false)
                r.stopReason = reason
                return r
            }
            let resultCandidate: OperationResult
            let focused = target == nil || !requireFocus ? nil : frontWindowForEdit()
            if !snap.trusted {
                resultCandidate = refusal(.permissionLost, L("Not run because the \(AccessPane.name()) permission is not granted.", "「\(AccessPane.name())」の許可がないため操作しません。"))
            } else if let reason = authorization.stopReason(system: system, control: control, snapshot: snap) {
                resultCandidate = refusal(reason, L("Not run because the pause state, input, or the current Space changed after the request.", "受付後に停止・入力・操作スペースの状態が変わったため操作しません。"))
            } else if let target, (requireFocus && focused != target) || !snap.windows.contains(where: {
                $0.id == target && $0.membership == .current && ($0.kind == .standard || (allowFullscreen && $0.kind == .fullscreen) || (allowMinimized && $0.kind == .minimized))
            }) {
                resultCandidate = refusal(.targetsChanged, L("Not run because the target window's Space, type, or focus changed.", "対象ウインドウの所属・種類・フォーカスが変わったため操作しません。"))
            } else {
                resultCandidate = body(authorization)
            }
            var result = resultCandidate
            result.id = id
            // The record right before publishing (after the body's AX work, and also when refused before the body).
            finalize?()
            // Even on failure, keep the timeline so far on the result (also returned by the receipt-ID lookup).
            if let timeline { timeline.mark("published"); result.timeline = timeline.events }
            lock.lock()
            running = nil
            runningKind = nil
            lastFocusRefresh = .distantPast
            scheduleNextTick(after: 0.05)
            record(result)
            store.save(state)
            lock.unlock()
            drainUserQueue()
            DispatchQueue.main.async { self.onChange?() }
        }
        return .started(id)
    }

    /// Presses the close button. The automatic-arrangement tick picks up the window vanishing and redistributes.
    private func runClose(_ target: WindowID, source: String, authorization: OperationAuthorization? = nil, requireFocus: Bool = true) -> EditAccept {
        lock.lock()
        if running != nil { lock.unlock(); return .busy }
        let op = CloseOperation(system: system, control: control, target: target, limits: limits, authorization: authorization, requireFocus: requireFocus)
        running = op.id
        progressText = L("Closing the window", "ウインドウを閉じています")
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
        onOperationID?(op.id)
        performOnOperationQueue { [self] in
            let result = op.run()
            lock.lock()
            running = nil
            lastFocusRefresh = .distantPast
            scheduleNextTick(after: 0.05) // observe sooner right after windows moved (border and history follow)
            record(result)
            store.save(state)
            lock.unlock()
            if result.outcome != .complete { noteRefusal(result.message) }
            drainUserQueue()
            DispatchQueue.main.async { self.onChange?() }
        }
        return .started(op.id)
    }

    private func wrap(_ a: Accept) -> EditAccept {
        switch a {
        case .started(let id): return .started(id)
        case .busy: return .busy
        case .notApplicable: return .refused(L("This Space has no layout.", "この操作スペースのレイアウトがありません。"), code: "not-started")
        }
    }

    func runFocus(_ target: WindowID, source: String, pressedAt: Date? = nil, authorization: OperationAuthorization? = nil,
                  regionDestination: FocusOperation.RegionDestination? = nil) -> EditAccept {
        lock.lock()
        if running != nil { lock.unlock(); return .busy }
        let op = FocusOperation(system: system, control: control, limits: limits, target: target, pressedAt: pressedAt, authorization: authorization,
                                regionDestination: regionDestination)
        running = op.id
        progressText = L("Moving focus", "フォーカスを移しています")
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
        onOperationID?(op.id)
        performOnOperationQueue { [self] in
            let result = op.run()
            lock.lock()
            running = nil
            // The move was confirmed within the operation; reflect it without waiting for status to reread.
            if result.outcome == .complete { cachedFocusedWindow = target }
            record(result)
            store.save(state)
            lastFocusRefresh = .distantPast
            scheduleNextTick(after: 0.05) // observe sooner right after windows moved (border and history follow)
            lock.unlock()
            lock.lock(); let queued = !userQueue.isEmpty; lock.unlock()
            if !queued, result.stopReason == nil, result.outcome == .complete {
                self.reflowAccordionAfterFocus(target)
            }
            drainUserQueue()
            DispatchQueue.main.async { self.onChange?() }
        }
        return .started(op.id)
    }

    /// When focus moves within an accordion, realigns the strips to that window.
    /// Writes and the raise go through `arrange`, passing the stop check right before sending.
    private func reflowAccordionAfterFocus(_ target: WindowID) {
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock()
        let layout = state.layouts[spaceKey]
        let zoomed = state.zoomed[spaceKey]
        lock.unlock()
        guard zoomed == nil, !control.paused, let layout, layout.containsAccordion(around: target) else { return }
        _ = arrange(source: "auto", kind: "auto-reconcile", followsUserCommand: true)
    }

    // MARK: - Pause / Resume

    func noteAnnouncedWindow(_ id: WindowID) {
        let now = announcementClock()
        lock.lock(); announcedWindows[id] = now; lock.unlock()
    }

    /// Drops announcements that expired, were already decided, or will never be in this census (another Space only, or a layer other than 0),
    /// and returns whether any is left. Unknown membership, a tiny window, and a window fading in keep theirs. OS reads happen outside the lock.
    private func keepsPendingAnnouncements(spaceID: UInt64) -> Bool {
        let now = announcementClock()
        lock.lock(); let entries = announcedWindows; lock.unlock()
        guard !entries.isEmpty else { return false }
        var dropped: [WindowID: Date] = [:]
        for (id, at) in entries {
            if now.timeIntervalSince(at) >= Self.announcementLifetime || baseline?.windows[id] != nil { dropped[id] = at; continue }
            if let spaces = system.spacesOf(id), !spaces.isEmpty, !spaces.contains(spaceID) { dropped[id] = at; continue }
            if let record = system.windowRecord(id), record.layer != 0 { dropped[id] = at }
        }
        lock.lock(); defer { lock.unlock() }
        // A re-announcement made during the reads has a newer time and stays.
        for (id, at) in dropped where announcedWindows[id] == at { announcedWindows[id] = nil }
        return !announcedWindows.isEmpty
    }

    /// For tests.
    func testingAnnouncedWindows() -> Set<WindowID> { lock.lock(); defer { lock.unlock() }; return Set(announcedWindows.keys) }
    /// For tests, on the operations queue: seconds until the next scheduled tick.
    func testingNextTickDelay() -> TimeInterval { Double(Int64(nextTickDeadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)) / 1e9 }

    /// Queue length, for tests.
    var pendingUserWork: Int { lock.lock(); defer { lock.unlock() }; return userQueue.count }

    @discardableResult
    private func enqueueUser(edit: EditCommand?, arrange: UserWorkQueue.Arrange?, source: String, pressedAt: Date, spaceKey: String, ticket: String? = nil,
                             timeline: OperationTimeline? = nil, resolved: ResolvedSpace? = nil, menuRequest: UserWorkQueue.MenuRequest? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        return userQueue.enqueue(edit: edit, arrange: arrange, source: source, pressedAt: pressedAt, spaceKey: spaceKey, ticket: ticket, timeline: timeline, resolved: resolved, menuRequest: menuRequest)
    }

    private func drainUserQueue() {
        lock.lock()
        guard running == nil, !control.paused, let next = userQueue.popFirst() else { lock.unlock(); return }
        let repeats = next.repeats
        lock.unlock()
        let currentSpace = system.currentSpaceID().map(String.init) ?? "-"
        if next.spaceKey != currentSpace {
            noteQueuedRefusal(next.ticket, L("Not run because the current Space changed.", "操作スペースが変わったため実行しません"), timeline: next.timeline,
                              spaceCommand: Self.isSpaceCommand(next.edit))
            drainUserQueue()
            return
        }
        if let job = next.arrange {
            let accept = arrange(source: next.source, kind: job.kind, heldOut: job.heldOut, ignoreZoom: job.ignoreZoom, pressedAt: next.pressedAt, resultTicket: next.ticket)
            switch accept {
            case .started(let id): bindTicket(next.ticket, to: id)
            case .busy:
                noteQueuedRefusal(next.ticket, L("Not accepted because another operation is in progress.", "処理中のため受け付けません"))
                drainUserQueue()
            case .notApplicable:
                noteQueuedRefusal(next.ticket, L("This Space has no layout.", "この操作スペースのレイアウトがありません。"))
                drainUserQueue()
            }
            return
        }
        if let command = next.edit {
            if let request = next.menuRequest,
               request.inputCount != system.inputActivityCount || request.generation != control.cancellationGeneration {
                noteQueuedRefusal(next.ticket, L("Not sent because input or the pause state changed while waiting.",
                                                 "待っている間に入力または停止状態が変わったため送りません。"), timeline: next.timeline, spaceCommand: true)
                drainUserQueue()
                return
            }
            let accept = edit(command, source: next.source, pressedAt: next.pressedAt, repeats: repeats, resultTicket: next.ticket, timeline: next.timeline, resolved: next.resolved, menuTarget: next.menuRequest?.target)
            switch accept {
            case .started(let id): bindTicket(next.ticket, to: id)
            case .busy:
                noteQueuedRefusal(next.ticket, L("Not accepted because another operation is in progress.", "処理中のため受け付けません"), timeline: next.timeline,
                                  spaceCommand: Self.isSpaceCommand(command))
                drainUserQueue()
            case .refused(let why, _):
                noteQueuedRefusal(next.ticket, why, timeline: next.timeline, spaceCommand: Self.isSpaceCommand(command))
                drainUserQueue()
            }
        }
    }

    deinit {
        // The handler retains itself, so the timer stays unless cancelled.
        autoTimer?.cancel()
        // Main owns observer registration; stop on main wherever the last reference drops.
        if let wake { DispatchQueue.main.async { wake.stop() } }
    }

    /// Identity, modification time, and size of the configuration file (the link target for a link); nil when absent.
    /// Changes on replacement, recreation, relinking, or swapping the whole folder.
    private func configFingerprint() -> [Int]? {
        var info = stat()
        guard stat(configURL.path, &info) == 0 else { return nil }
        // Also the status change time (ctime), so restoring read permission on an unreadable file triggers a reread too.
        return [Int(info.st_dev), Int(info.st_ino), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
                info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec, Int(info.st_size)]
    }

    /// Detects configuration file changes by comparing identity each tick (at most once a second). Nothing while absent. Operations queue.
    private func checkConfigFile() {
        guard Date().timeIntervalSince(configCheckedAt) >= 1 else { return }
        configCheckedAt = Date()
        let now = configFingerprint()
        guard now != lastConfigFingerprint else { return }
        lastConfigFingerprint = now
        if now != nil { reloadConfig(source: "file") }
    }

    /// Stops new requests. "Stopping" until issued ones are confirmed. The queue is discarded.
    func pause() {
        control.paused = true
        control.hurrySettle = false
        lock.lock()
        let dropped = userQueue.removeAll()
        pendingAutoStart = nil
        autoStartArmed.removeAll()
        autoStartDeclined.removeAll()
        lastRefusal = nil
        state.paused = true
        store.save(state)
        lock.unlock()
        for item in dropped {
            noteQueuedRefusal(item.ticket, L("Not run because all Spaces were paused.", "すべての操作スペースを一時停止したため受け付けませんでした。"), timeline: item.timeline,
                              spaceCommand: Self.isSpaceCommand(item.edit))
        }
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Adopts the latest actual layout, issuing no geometry, focus, or raise.
    /// The saved layout stays and frames changed while paused are taken into the ratios. Automatic arrangement continues.
    @discardableResult
    func resume() -> String? {
        guard control.paused else { return nil }
        let authorization = OperationAuthorization(system: system, control: control, allowPaused: true)
        let refusal = L("Could not confirm the current window layout. All Spaces remain paused. Try Resume again.",
                        "現在のウインドウ配置を確認できないため、一時停止を続けています。もう一度再開してください。")
        func refuse(_ message: String = refusal) -> String { noteRefusal(message); return message }
        // For reasons resuming cannot fix, say what to do instead of suggesting to resume again.
        guard system.axTrusted else {
            let resume = StatusMenuCopy.globalPauseTitle(paused: true)
            return refuse(L("All Spaces remain paused because LazySpace is not allowed in \(AccessPane.name()). Allow it, then choose \(resume).",
                            "「\(AccessPane.name())」でLazySpaceが許可されていないため、一時停止を続けています。許可してから「\(resume)」を選んでください。"))
        }
        guard let sid = authorization.spaceID else { return refuse() }
        let key = String(sid)
        lock.lock(); let prior = state.layouts[key]; lock.unlock()
        var adopted = prior
        if let prior {
            // While waiting on AX, keep Pause and the saved layout, without locking the UI's state reads.
            let ids = Set(prior.windowIDs)
            let snap = system.snapshot(limitingTo: ids, deadline: Date().addingTimeInterval(0.5))
            if !snap.unobservedApps.isEmpty {
                let apps = snap.unobservedApps.map(AppNames.localized).joined(separator: L(", ", "、"))
                let resume = StatusMenuCopy.globalPauseTitle(paused: true)
                let after = snap.unobservedApps.count == 1 ? "when it responds, or quit it" : "when they respond, or quit them"
                return refuse(L("All Spaces remain paused because \(apps) did not respond, so the current window layout could not be confirmed. Choose \(resume) again \(after).",
                                "\(apps)が応答しないため現在のウインドウ配置を確認できず、一時停止を続けています。応答してから「\(resume)」をもう一度選ぶか、終了してください。"))
            }
            guard snap.trusted,
                  authorization.stopReason(system: system, control: control, snapshot: snap) == nil,
                  !snap.windows.contains(where: { $0.kind == .unknownRole }) else { return refuse() }
            let unseen = ids.subtracting(snap.windows.map(\.id))
            if !unseen.isEmpty {
                // Missing from the AX list alone is not closing. Only windows gone from the full window list, or confirmed by SkyLight to have moved to one other Space
                // (including entering full screen; an app's AX list does not return windows on other Spaces), leave the layout.
                guard let records = system.windowRecords(unseen),
                      records.keys.allSatisfy({ id in system.spacesOf(id).map { $0.count == 1 && $0[0] != sid } ?? false }) else { return refuse() }
            }
            let targets = snap.windows.filter { $0.kind == .standard && ($0.membership == .current || $0.membership == .unknown) }
            let layout = prior.removing(ids.subtracting(targets.map(\.id)))
            adopted = layout.root == nil ? nil : layout.packing(rects: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.frame) }))
        }
        guard system.axTrusted, system.currentSpaceID() == sid,
              authorization.interruptionReason(system: system, control: control) == nil else { return refuse() }
        lock.lock()
        guard state.layouts[key] == prior, control.paused,
              authorization.interruptionReason(system: system, control: control) == nil else {
            lock.unlock(); return refuse()
        }
        state.layouts[key] = adopted
        if adopted == nil { lastPlans[key] = nil; layoutHistory[key] = nil; state.dialogRegions?[key] = nil }
        // The adopted layout is where the windows are: a pending display or launch fit of this Space is done.
        displayRefitPending.remove(key)
        displayRefitFailures[key] = nil
        state.paused = false
        control.paused = false
        lastRefusal = nil
        store.save(state)
        lock.unlock()
        queue.async { [self] in baseline = nil; lastSeen = nil; unansweredFits[key] = nil }
        DispatchQueue.main.async { self.onChange?() }
        return nil
    }

    func markFirstLaunchDone() {
        lock.lock(); state.firstLaunchDone = true; store.save(state); lock.unlock()
    }

    // MARK: - Accessibility

    /// Called from the system permission notification; checks without waiting for the next tick.
    func checkTrust() {
        queue.async { self.observeTrust() }
    }

    /// Reports permission changes to the UI. Revoked: stop input observation; restored: recreate it.
    private func observeTrust() {
        let trusted = system.axTrusted
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        if servicesStarted {
            if trusted {
                lastInputRestart = Date()
                _ = system.input.start()
            } else {
                system.input.stop()
            }
        }
        DispatchQueue.main.async {
            self.onTrustChange?(trusted)
            self.onChange?()
        }
    }

    // MARK: - Auto loop

    private func startAutoLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        autoTimer = t
    }

    /// Brings the next tick forward (right after an observed change or an AX hint), unless one is already scheduled sooner.
    /// Called on the operations queue.
    private func scheduleNextTick(after delay: TimeInterval) {
        let deadline = DispatchTime.now() + max(0.05, min(delay, tickInterval))
        guard deadline < nextTickDeadline else { return }
        nextTickDeadline = deadline
        autoTimer?.schedule(deadline: deadline, repeating: tickInterval)
    }

    /// AX notifications (front app window creation, focus moves). No decisions; only brings the next observation forward.
    /// AX notifications can arrive before the window appears on screen, so observation stays at a short interval for a while (0.6 s).
    private func wakeFromAX() {
        queue.async { [weak self] in
            guard let self else { return }
            requestFocusRead()
            wakeUntil = .now() + 0.6
            scheduleNextTick(after: 0.05)
        }
    }

    /// Pushes onto the undo history. Call with lock held.
    private func pushLayoutHistory(_ before: Layout, spaceKey: String) {
        var history = layoutHistory[spaceKey] ?? []
        guard history.first != before else { return }
        history.insert(before, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        layoutHistory[spaceKey] = history
    }

    /// Frame for the focus border; nil when the feature is off, the Space is unstarted, there is no front window, or the front window is waiting.
    private func focusFrame(in census: Census, spaceKey: String) -> CGRect? {
        lock.lock()
        guard config.focusBorder.enabled, !control.paused, let layout = state.layouts[spaceKey],
              let front = census.frontWindow else { lock.unlock(); return nil }
        let managed = layout.windowIDs.contains(front) || (state.floating[spaceKey] ?? []).contains(front)
        lock.unlock()
        if managed { return census.bounds[front] }
        // Also shown on strip dialogs (with identity, membership, and process confirmed).
        return regionLiveMembers(census, space: UInt64(spaceKey), only: [front])[front]
    }

    /// Reports only when the frame changes, following at a short interval while moving (drag and the like). Call on the operations queue.
    private func publishFocusFrame(_ frame: CGRect?) {
        guard frame != lastFocusFrame else { return }
        if frame != nil, lastFocusFrame != nil { scheduleNextTick(after: fastTickInterval) }
        lastFocusFrame = frame
        DispatchQueue.main.async { [self] in onFocusFrame?(frame) }
    }

    /// Front window history (for focus-back), updated from the CGWindowList front window only, without AX.
    func noteFront(_ front: WindowID?, spaceKey: String) {
        guard let front else { return }
        lock.lock(); defer { lock.unlock() }
        var history = focusHistory[spaceKey] ?? []
        guard history.first != front else { return }
        history.removeAll { $0 == front }
        history.insert(front, at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
        focusHistory[spaceKey] = history
    }

    /// Landing of a Space switch or move. On success the body sets the source Space. Only the operations queue touches it.
    private final class SpaceLanding {
        var dest: UInt64
        var origin: UInt64?
        init(dest: UInt64) { self.dest = dest }
    }

    /// Right before publishing a Space switch or move result (after the body's AX work, and also when refused after acceptance before the body). Call on the operations queue.
    /// Records the visible Space (hooks, arrival, `space back` target, dropping arrival handling for a Space left), and if the operation succeeded and stays on the target,
    /// sets the back target to the source Space (not a Space passed through; no tick runs during the operation, so intermediate Spaces are not recorded).
    /// The next operation is accepted after publishing, so `space back` returns to the right Space without waiting for a tick.
    private func finishSpaceBookkeeping(_ landing: SpaceLanding) {
        guard let sid = system.currentSpaceID() ?? (landing.origin != nil ? landing.dest : nil) else { return }
        noteSpaceTransition(to: sid)
        if let origin = landing.origin, sid == landing.dest { lock.lock(); previousSpaceID = origin; lock.unlock() }
    }

    /// When the first Space operation is accepted, starts creating the pass-through tap ahead of time (asynchronous, safe to call repeatedly; recreated on the next operation after a failure).
    /// SpaceControl still checks "ready and enabled" before sending, as before.
    private func prestartPassThroughTap() {
        (passThroughTapOverride ?? spaceControl?.passThroughTap)?.start()
    }

    /// For tests: arrival records (`space back` target, the Space the hook last saw, the window awaiting arrival, arrival time). Call from outside the operations queue.
    func testingSpaceBookkeeping() -> (previous: UInt64?, hookSpace: UInt64?, expected: (window: WindowID, spaceID: UInt64)?, arrivedAt: Date) {
        operationsQueue.sync {
            lock.lock(); let previous = previousSpaceID; lock.unlock()
            return (previous, hookSpaceID, expectedArrival.map { ($0.window, $0.spaceID) }, spaceArrivedAt)
        }
    }

    /// Records the visible Space (Space-change hook, `space back` target, arrival). Called on the operations queue by the tick and when `space N` completes.
    private func noteSpaceTransition(to sid: UInt64) {
        if let prev = hookSpaceID, prev != sid {
            // Dialog-region assessments belong to that Space.
            regionObservations.removeAll()
            runSpaceChangeHook(from: prev, to: sid)
            // Waiting windows belong to the Space left; the arrived Space's are recounted by the observation after settling (`placeMissing`).
            lock.lock(); previousSpaceID = prev; lock.unlock()
        }
        if hookSpaceID != sid { noteSpaceArrival() }
        hookSpaceID = sid
        // Leaving the Space of a window carried by move-to-space drops its arrival handling.
        if let expected = expectedArrival, expected.spaceID != sid { expectedArrival = nil }
    }

    /// Every 0.5 s (0.15 s right after a change). No AX; only CGWindowList differences.
    func tick() {
        if servicesStarted { checkConfigFile() }
        observeTrust()
        // Process launch times are reread per observation (so a stale cache never misses pid reuse).
        processStarts.removeAll()
        settleDeferred = false
        nextTickDeadline = .now() + tickInterval
        if DispatchTime.now() < wakeUntil { scheduleNextTick(after: fastTickInterval) }
        let count = system.inputActivityCount
        if count != lastInputCount { lastInputCount = count; lastInputChange = Date() }
        let sinceInput = Date().timeIntervalSince(lastInputChange)
        // Drags and mouse edits come from the left button; any held button keeps automatic decisions waiting, matching the write gate.
        let leftButtonDown = system.mouseButtonDown
        let buttonDown = leftButtonDown || system.anyMouseButtonHeld
        // This observation's automatic decisions use the input seen here as their baseline; input during the decision's reads also stops the operation.
        let decision = OperationAuthorization(system: system, control: control)
        let completedDrags = system.input.completedMouseDrags
        let presses = system.input.breakdown.mouseDown
        let dragged = completedDrags != lastCompletedMouseDrags
        let pressSpace = system.currentSpaceID().map(String.init)
        if dragged {
            lastCompletedMouseDrags = completedDrags
            pendingMouseEdit = true
            dragQuietPending = true
            mouseEditSpace = pressSpace
            dragPresses = system.input.completedDragPresses
            earlyMouseEdit = !leftButtonDown
            mouseEditSample = nil
            earlyMouseEditDeclined = false
        }
        if leftButtonDown {
            mouseHeld = true
            earlyMouseEdit = false
            mouseEditSample = nil
        } else if mouseHeld {
            mouseHeld = false
            pendingMouseEdit = true
            dragQuietPending = true
            if !dragged { mouseEditSpace = pressSpace }
        }
        // A press after the drag ended (a click, a title-bar double-click zoom), even between observations, keeps the quiet path.
        if presses != dragPresses { earlyMouseEdit = false; mouseEditSample = nil }
        // A pending mouse edit belongs to its Space and to that time: a Space change or Pause drops it (Resume never replays an old drag).
        // Checked before any early return of this observation, so a brief visit to another Space cannot be skipped over.
        if pendingMouseEdit {
            lock.lock(); let off = control.paused || pressSpace.map { state.pausedSpaces.contains($0) } ?? true; lock.unlock()
            if off || mouseEditSpace != pressSpace { clearPendingMouseEdit() }
        }
        // The quiet wait applies only while the mouse is held and after a drag; key input alone never delays arrangement.
        let quiet = !buttonDown && (dragQuietPending ? sinceInput >= quietInterval : true)
        if quiet { dragQuietPending = false }

        // Space-change hook (independent of whether automatic arrangement is available; writes no windows).
        if let sid = system.currentSpaceID() { noteSpaceTransition(to: sid) }
        // Recheck membership of windows from sends with uncertain results (no writes; only whether to lift the exclusion).
        reconcileHolds()

        guard system.axTrusted else { baseline = nil; lastSeen = nil; publishFocusFrame(nil); return }
        // A disabled tap may not notify its callback; check every time, and if it cannot be re-enabled, recreate it as unobservable.
        if servicesStarted { system.input.reviveIfDisabled() }
        if servicesStarted, !system.inputObservationAvailable, Date().timeIntervalSince(lastInputRestart) >= 5 {
            lastInputRestart = Date()
            _ = system.input.start()
        }
        let settledOnSpace = Date().timeIntervalSince(spaceArrivedAt) >= arrivalDwell

        // Focus history and the border are used by manual arrangement too, so they are read before the automatic-arrangement check.
        let spaceBefore = system.currentSpaceID()
        var current = takeCensus(spaceBefore)
        guard let spaceBefore, system.currentSpaceID() == spaceBefore else { lastSeen = nil; publishFocusFrame(nil); scheduleNextTick(after: fastTickInterval); return }
        let spaceKey = String(spaceBefore)
        driftReference = lastTickBounds
        lastTickBounds = current.bounds
        // While windows move (close / open animations, the app moving them, drags), observe at a short interval
        // to catch the moment a window vanishes after its close animation without waiting for the regular 0.5 s.
        if Self.anyWindowMoved(from: driftReference, to: current.bounds, tolerance: limits.tolerance) { scheduleNextTick(after: fastTickInterval) }
        noteFront(current.frontWindow, spaceKey: spaceKey)
        regionNoteFront(current)
        publishFocusFrame(focusFrame(in: current, spaceKey: spaceKey))
        wake?.watch(Set(current.windows.values.map { pid_t($0) }))
        // Even on a Space only stayed on, retain window AX elements once after settling (no operation means no observation otherwise).
        // Reads only the window list, bounded, and writes no windows; independent of automatic arrangement and pause. Once per arrival.
        // If the Space or input changed meanwhile, do not act on the stale observation and leave it to the next tick; otherwise retake the observation and continue.
        if settledOnSpace, elementsRetainedOn != spaceBefore, !isBusy {
            elementsRetainedOn = spaceBefore
            let inputBefore = system.inputActivityCount
            system.retainElements(for: Set(current.windows.keys), deadline: Date().addingTimeInterval(0.5))
            guard system.currentSpaceID() == spaceBefore, system.inputActivityCount == inputBefore, !system.mouseButtonDown else {
                scheduleNextTick(after: fastTickInterval); return
            }
            current = takeCensus(spaceBefore)
            // The retaken observation also checks the Space after reading, like the first.
            guard system.currentSpaceID() == spaceBefore, system.inputActivityCount == inputBefore else { scheduleNextTick(after: fastTickInterval); return }
        }
        // New-window rules (classification and sending), with gates separate from automatic arrangement.
        routeNewWindows(current, space: spaceBefore)
        // Clean up pending arrivals (remove entries integrated, floated, gone, or moved to another Space).
        _ = pendingArrivalPresent(in: current)
        // Windows reconciling, classifying, or sending are hidden from every placement path in this observation (enrollment, integration, correction).
        lock.lock(); let excluded = Set(routingExcluded.keys); lock.unlock()
        if !excluded.isEmpty { current = current.excluding(excluded) }
        guard autoGate().allowed else { baseline = nil; lastSeen = nil; return }
        if isBusy { return } // the baseline does not advance while busy; differences are evaluated together afterward

        // Display setup changed (displays added or removed, resolution, Dock or menu bar area): drop recent frame records and mark every Space with a layout
        // to be refit. The current Space is fit once the setup stays unchanged for `displaySettleInterval` and input is quiet; other Spaces when shown.
        // Different displays per Space are not a setup change, so compare work areas of all displays.
        let workAreas = system.displayFrames().map(\.workArea)
        if let last = lastWorkAreas, last != workAreas {
            lock.lock()
            lastPlans.removeAll()
            displayRefitPending = Set(state.layouts.keys)
            displayRefitFailures.removeAll()
            lock.unlock()
            displayChangedAt = displayClock()
            scheduleNextTick(after: displaySettleInterval)
        }
        lastWorkAreas = workAreas
        // Windows on another display's Space do not count as this Space's windows (never integrated as new).
        let foreign = windowsOnOtherSpaces(current, space: spaceBefore, spaceKey: spaceKey)
        if !foreign.isEmpty { current = current.excluding(foreign) }
        // An announced window usually reaches the list some 20 ms after kAXWindowCreated: look again after the 50 ms floor instead of the 150 ms fast tick.
        // Only here, after the gate and busy checks: nothing could consume it otherwise, and every operation schedules a 50 ms tick when it ends.
        if keepsPendingAnnouncements(spaceID: spaceBefore) { scheduleNextTick(after: 0.05) }

        // Wait until the window set is stable, checking at a short interval right after a change,
        // except skip that one check when only arrivals whose IDs are known from kAXWindowCreated are involved.
        lock.lock()
        let announced = announcedWindows
        lock.unlock()
        if let seen = lastSeen, seen.spaceID == current.spaceID {
            let added = Set(current.windows.keys).subtracting(seen.windows.keys)
            let removed = Set(seen.windows.keys).subtracting(current.windows.keys)
            if !added.isEmpty, removed.isEmpty, added.isSubset(of: Set(announced.keys)) {
                lock.lock()
                for id in added where announcedWindows[id] == announced[id] { announcedWindows[id] = nil }
                lock.unlock()
                lastSeen = current
            } else if added.isEmpty, !removed.isEmpty, removed.allSatisfy({ seen.windows[$0].map(system.processExited) ?? false }) {
                // If only windows of an app that quit vanished, refill without waiting for a second observation.
                lastSeen = current
            }
        }
        guard let seen = lastSeen, seen.windows == current.windows, seen.spaceID == current.spaceID else {
            lastSeen = current
            scheduleNextTick(after: fastTickInterval)
            return
        }
        noteArrivalsFromOtherSpaces(current, spaceKey: spaceKey)
        guard let prev = baseline else {
            baseline = current
            oweUnobservedDepartures(current: current, spaceKey: spaceKey)
            // Windows present since launch never show as differences; before taking the baseline unstarted, judge once with the current count.
            if enrollUnstartedSpace(previous: current, current: current, spaceKey: spaceKey, quiet: quiet, authorization: decision) { return }
            // A Space that already has a layout aligns visible standard windows with it even without differences.
            if quiet, settledOnSpace, !control.paused { placeMissing(current: current, spaceKey: spaceKey, authorization: decision) }
            return
        }

        // A lock, or an observation where windows suddenly drop to zero, does not break the layout.
        if current.windows.isEmpty, prev.windows.count >= 2 { return }

        if adoptTabSwitch(previous: prev, current: current, spaceKey: spaceKey) {
            baseline = current
            lastSeen = current
            return
        }

        lock.lock()
        let layout = state.layouts[spaceKey]
        let managed = Set(layout?.windowIDs ?? [])
        let paused = control.paused
        let autoOff = paused || state.pausedSpaces.contains(spaceKey)
        lock.unlock()

        // Window count changes do not wait for stillness unless a drag moved a managed window. The slight wobble of clicking a close button or menu
        // counts as a drag, so waiting would delay only mouse actions by 0.6 s.
        // Until the displays settle after a setup change, arrangement for window count changes waits too (never fitting an intermediate work area).
        let displaysSettled = displayClock().timeIntervalSince(displayChangedAt) >= displaySettleInterval
        let setQuiet = displaysSettled && (quiet || (!buttonDown && !managedWindowsMoved(current, spaceKey: spaceKey, managed: managed)))
        let out = AutoDecide.decide(.init(previous: prev, current: current, inputQuiet: setQuiet, paused: autoOff, hasLayout: layout != nil, managed: managed))
        if layout == nil, !autoOff, enrollUnstartedSpace(previous: prev, current: current, spaceKey: spaceKey, quiet: quiet, authorization: decision) { return }

        var changed = false
        var retryAdded: [WindowID] = []
        var retryRemoved: [WindowID] = []
        // Confirm whether managed windows missing from the list really closed, moved, or were minimized. If any cannot be confirmed,
        // all decisions in this observation are deferred (so other arrangement meanwhile never drops that window from the layout).
        removalHolds = removalHolds.filter { current.windows[$0.key] == nil }
        var closedGone: Set<WindowID> = []
        var holdingRemoval = false
        // While a window deferred on arrival is still unconfirmed, all automatic arrangement on this Space stays stopped.
        // A deferred redistribution (arriving with the button held, for example) is also checked before other arrangement in this observation.
        if removalGate != nil || pendingDepartedRefit?.spaceKey == spaceKey {
            let missing = removalGate.map { $0 == spaceKey } ?? true ? (layout?.windowIDs ?? []).filter { current.windows[$0] == nil } : []
            if !missing.isEmpty, assessRemovals(missing, pids: [:], spaceID: spaceBefore).held {
                holdingRemoval = true
                removalGate = spaceKey
            } else { removalGate = nil }
        }
        for case .refitAfterRemoval(let gone, _) in out.actions {
            let assessed = assessRemovals(gone, pids: prev.windows, spaceID: spaceBefore)
            closedGone.formUnion(assessed.closed)
            holdingRemoval = holdingRemoval || assessed.held
        }
        if holdingRemoval {
            for action in out.actions {
                switch action {
                case .integrate(let ids, _): retryAdded.append(contentsOf: ids)
                case .refitAfterRemoval(let gone, _): retryRemoved.append(contentsOf: gone)
                case .rebase: break
                }
            }
        }
        for action in out.actions where !holdingRemoval {
            switch action {
            case .rebase:
                baseline = current
                lastSeen = current
                let expected = arrivalExpected(in: current)
                arrivedOnRebase(current: current, spaceKey: spaceKey, quiet: quiet && (settledOnSpace || expected), refitNow: setQuiet, authorization: decision)
                if !autoOff, !buttonDown { scheduleSettleDeadline(settledOnSpace: settledOnSpace, quiet: quiet, sinceInput: sinceInput) }
                return
            case .integrate(let ids, let anchor):
                // During the delay after an app did not answer, a new window is left to `placeMissing`, which tries once the delay is over.
                guard unansweredFitDue(spaceKey) else { break }
                // If another operation is running and this is not accepted, it is kept out of the baseline and seen as "new" again on the next tick.
                // If the front window is floating, the new window goes where that window was before it left the layout.
                var floated: WindowID? = nil
                if anchor == nil, let front = prev.frontWindow {
                    lock.lock()
                    if (state.floating[spaceKey] ?? []).contains(front) { floated = front }
                    lock.unlock()
                }
                if integrateForeground(ids, beside: anchor, inPlaceOf: floated, authorization: decision, unanswered: unansweredPolicy(spaceKey)) == .busy {
                    retryAdded.append(contentsOf: ids)
                }
            case .refitAfterRemoval(let gone, let wasFront):
                // During that delay the redistribution is owed instead (without focus-after-close) and runs once the delay is over.
                // The windows that left are remembered now, before another arrangement can replace the layout they belong to.
                guard unansweredFitDue(spaceKey) else {
                    lock.lock(); let generation = control.cancellationGeneration; rememberDeparturesLocked(gone, spaceKey: spaceKey); lock.unlock()
                    if pendingDepartedRefit == nil { pendingDepartedRefit = (spaceKey, generation) }
                    break
                }
                // Focus moves only when the window confirmed closed was in front; not for windows that moved to another Space or were minimized.
                let closedFront = wasFront ? prev.frontWindow.flatMap { closedGone.contains($0) ? $0 : nil } : nil
                if refitAfterRemoval(gone, wasFront: closedFront != nil, spaceKey: spaceKey, closedFront: closedFront, authorization: decision) == .busy { retryRemoved.append(contentsOf: gone) }
            }
        }
        settleDeferred = !retryAdded.isEmpty || !retryRemoved.isEmpty || !out.deferredAdded.isEmpty || !out.deferredRemoved.isEmpty
        if !retryAdded.isEmpty || !retryRemoved.isEmpty { scheduleNextTick(after: fastTickInterval) }
        // Decisions deferred for input are revisited when the quiet time is up (not at the next regular interval).
        if !out.deferredAdded.isEmpty || !out.deferredRemoved.isEmpty { scheduleNextTick(after: max(quietInterval - sinceInput, fastTickInterval)) }
        // After an actual drag, the edit is adopted once the managed windows are still after the release (two equal reads, no geometry
        // notification in between), without waiting for the input quiet time; only when nothing else is pending and every change is a resize or a swap.
        if pendingMouseEdit, earlyMouseEdit, !quiet, !buttonDown, out.actions.isEmpty, out.deferredAdded.isEmpty, out.deferredRemoved.isEmpty,
           !holdingRemoval, removalGate == nil, !autoOff, let layout, !isBusy,
           adoptStillMouseEdit(current: current, spaceKey: spaceKey, layout: layout, managed: managed, authorization: decision) { return }
        // Only changes after the left button is released are adopted, as ratio updates or swaps.
        if out.actions.isEmpty, !holdingRemoval, pendingMouseEdit, quiet, !buttonDown, !autoOff, layout != nil, !isBusy {
            switch applyFirstManualEdit(current: current, spaceKey: spaceKey, layout: layout!, managed: managed, authorization: decision) {
            case .applied: clearPendingMouseEdit(); return
            case .none: clearPendingMouseEdit()
            // Input or a change arrived during this observation: the drag waits for the quiet time again instead of being lost.
            case .interrupted: dragQuietPending = true
            }
        }
        // Redistribution for departed managed windows deferred on arrival: runs once the button is up and no managed window was moved.
        // The drag result (swap, ratios) is adopted first; redistributing first would overwrite the user's edit with the old layout.
        // The layout was read at the start of the tick, so this is reached only when no edit was adopted.
        if let pending = pendingDepartedRefit, pending.spaceKey != spaceKey || autoOff { pendingDepartedRefit = nil }
        // A partial write made while hidden is redistributed here until fixed (up to 3 times). If input stops it midway, the next quiet tick retries.
        lock.lock(); let dirty = hiddenRefitDirty.contains(spaceKey); lock.unlock()
        let dirtyRepair = dirty && pendingDepartedRefit == nil && dirtyRepairs[spaceKey, default: 0] < 3
        if out.actions.isEmpty, !holdingRemoval, setQuiet, !autoOff, let layout, !isBusy, pendingDepartedRefit != nil || dirtyRepair, unansweredFitDue(spaceKey) {
            let pending = pendingDepartedRefit
            pendingDepartedRefit = nil
            lock.lock(); let generation = control.cancellationGeneration; lock.unlock()
            let departed = layout.windowIDs.filter { current.windows[$0] == nil }
            let held = !departed.isEmpty && current.spaceID.map { assessRemovals(departed, pids: current.windows, spaceID: $0).held } ?? false
            if held {
                pendingDepartedRefit = pending ?? (spaceKey, generation)
                removalGate = spaceKey
                holdingRemoval = true
                scheduleNextTick(after: fastTickInterval)
            } else if pending.map({ $0.generation == generation }) ?? true, !departed.isEmpty || dirty {
                if pending == nil { dirtyRepairs[spaceKey, default: 0] += 1 }
                lock.lock(); rememberDeparturesLocked(departed, spaceKey: spaceKey); lock.unlock()
                if arrange(source: "auto", kind: "auto-refit", heldOut: [:], authorization: decision, unanswered: unansweredPolicy(spaceKey),
                           completion: { [weak self] result in
                    self?.rearmDepartedRefit(after: result, spaceKey: spaceKey, generation: generation)
                }) == .busy {
                    pendingDepartedRefit = pending ?? (spaceKey, generation)
                    scheduleNextTick(after: fastTickInterval)
                }
            }
        }
        // Even without a difference, standard windows not in the layout are inserted by the same rule.
        // Leaving full screen or moving from another display is already in the observation on arrival, so it never shows as a difference.
        // Fitting windows right after arriving waits until the user stays on the Space; Spaces only passed through are left alone.
        // Windows carried by move-to-space are inserted without the arrival dwell (other corrections wait).
        // Inserting fits the whole layout, so it goes before the display or launch fit below, which a completed insertion makes unnecessary.
        if out.actions.isEmpty, !holdingRemoval, quiet, displaysSettled, settledOnSpace || arrivalExpected(in: current), !buttonDown, !autoOff, layout != nil, !isBusy {
            _ = placeMissing(current: current, spaceKey: spaceKey, authorization: decision)
        }
        // A Space whose display setup changed (or any saved layout after launch) is fit to the work area once the setup stays unchanged for `displaySettleInterval`, the user stays on the Space,
        // and input is quiet. Until then, other corrections (rewriting drift, refilling a single window) wait too. Any completed arrangement of the Space also counts.
        lock.lock(); let displayRefit = displayRefitPending.contains(spaceKey); lock.unlock()
        if displayRefit, displaysSettled, out.actions.isEmpty, !holdingRemoval, pendingDepartedRefit == nil, quiet, settledOnSpace, !buttonDown, !autoOff, layout != nil, !isBusy,
           unansweredFitDue(spaceKey) {
            if case .started = arrange(source: "auto", kind: "auto-refit", authorization: decision, unanswered: unansweredPolicy(spaceKey),
                                       completion: { [weak self] in self?.noteDisplayRefit($0, spaceKey: spaceKey) }) { return }
        }
        if out.actions.isEmpty, !buttonDown, !autoOff, layout != nil {
            scheduleSettleDeadline(settledOnSpace: settledOnSpace, quiet: quiet, sinceInput: sinceInput)
        }
        if out.actions.isEmpty, !holdingRemoval, !displayRefit, quiet, settledOnSpace, !buttonDown, !autoOff, layout != nil, !isBusy {
            if reconcileDrift(current: current, spaceKey: spaceKey, layout: layout!, managed: managed, authorization: decision) { return }
        }
        if out.actions.isEmpty, !holdingRemoval, !displayRefit, quiet, settledOnSpace, !buttonDown, !autoOff, layout != nil, !isBusy {
            if fillSoloIfNeeded(current: current, spaceKey: spaceKey, authorization: decision) { return }
        }
        // Once the current Space has nothing to do, redistribute the source Space of departed windows without showing it.
        // Both wait for the display setup to settle, so they never write to an intermediate work area.
        if out.actions.isEmpty, !holdingRemoval, displaysSettled, quiet, !buttonDown, !paused, !isBusy {
            if runHiddenRefitIfDue(currentKey: spaceKey) { return }
            // A window sent to a Space another display shows joins that layout without the user going there.
            if runShownArrivalIfDue(currentKey: spaceKey, authorization: decision) { return }
        }
        // Dialog region: decided only when all arrangement work is done and the mouse is not in use.
        if out.actions.isEmpty, !holdingRemoval, displaysSettled, !displayRefit, !settleDeferred, !dragQuietPending, pendingDepartedRefit == nil, quiet, settledOnSpace, !buttonDown, !autoOff, layout != nil, !isBusy {
            regionStep(current, space: spaceBefore)
        }

        if forgetClosedTrackedWindows(current: current, spaceKey: spaceKey) { changed = true }

        // Adjust the baseline so deferred items look new / gone again next time. The front window also stays the pre-deferral one (used for insertion point and close detection).
        let pendingAdded = out.deferredAdded + retryAdded
        let pendingRemoved = out.deferredRemoved + retryRemoved
        for id in pendingAdded { current.windows[id] = nil }
        for id in pendingRemoved { if let pid = prev.windows[id] { current.windows[id] = pid } }
        if let front = current.frontWindow, pendingAdded.contains(front) { current.frontWindow = prev.frontWindow }
        if let front = prev.frontWindow, pendingRemoved.contains(front) { current.frontWindow = front }
        baseline = current
        if changed { DispatchQueue.main.async { self.onChange?() } }
    }

    /// Layout windows that left while the observation was stopped (LazySpace not running included) never show as a difference; their redistribution is owed
    /// as the pending departed refit, which assesses them like any other removal on the next quiet tick. Nothing is owed under Pause (Resume adopts the layout)
    /// or with this Space turned off. One still owed for another Space (left while the observation was stopped) is replaced; it would be dropped here anyway.
    /// The missing windows are remembered at once (a window only briefly missing stays in the layout, so the record goes unused), so another arrangement
    /// running before the refit cannot drop them without a place to return to.
    private func oweUnobservedDepartures(current: Census, spaceKey: String) {
        lock.lock()
        let missing = state.layouts[spaceKey]?.windowIDs.filter { current.windows[$0] == nil } ?? []
        let off = control.paused || state.pausedSpaces.contains(spaceKey)
        let generation = control.cancellationGeneration
        if !missing.isEmpty, !off { rememberDeparturesLocked(missing, spaceKey: spaceKey) }
        lock.unlock()
        guard !missing.isEmpty, !off, pendingDepartedRefit?.spaceKey != spaceKey else { return }
        pendingDepartedRefit = (spaceKey, generation)
        scheduleNextTick(after: fastTickInterval)
    }

    /// Forgets only waiting windows, floating windows, return targets, and zoom for windows confirmed closed. Read failures and being off screen are no evidence of disappearance.
    /// Waiting windows that joined this Space's layout or floating set, or that SkyLight confirms moved to one other Space, are removed too (even on Spaces with automatic arrangement off).
    private func forgetClosedTrackedWindows(current: Census, spaceKey: String) -> Bool {
        lock.lock()
        let managed = Set(state.layouts[spaceKey]?.windowIDs ?? []).union(state.floating[spaceKey] ?? [])
        let waitingHere = waitingBySpace[spaceKey] ?? []
        let placedWaiting = waitingHere.intersection(managed)
        if !placedWaiting.isEmpty { setWaitingLocked(waitingHere.subtracting(placedWaiting), spaceKey: spaceKey) }
        var tracked = waitingHere.subtracting(placedWaiting).union(state.floating[spaceKey] ?? []).union((state.floatHomes[spaceKey] ?? []).map(\.id)).union(soloProbed.keys)
            .union(reclaimedWindows)
        if let zoomed = state.zoomed[spaceKey] { tracked.insert(zoomed) }
        lock.unlock()
        let unseen = Self.windowsNeedingListCheck(tracked: tracked, visible: Set(current.windows.keys))
        guard !unseen.isEmpty, Date().timeIntervalSince(lastAliveSweep) >= 3 else { return !placedWaiting.isEmpty }
        lastAliveSweep = Date()
        guard let records = system.windowRecords(unseen) else { return !placedWaiting.isEmpty }
        let gone = unseen.subtracting(records.keys)
        let departedWaiting: Set<WindowID> = current.spaceID.map { sid in
            Set(records.keys.filter { id in waitingHere.contains(id) && (system.spacesOf(id).map { $0.count == 1 && $0[0] != sid } ?? false) })
        } ?? []
        guard !gone.isEmpty || !departedWaiting.isEmpty else { return !placedWaiting.isEmpty }
        lock.lock(); defer { lock.unlock() }
        let waitingGone = (waitingBySpace[spaceKey] ?? []).intersection(gone.union(departedWaiting))
        setWaitingLocked((waitingBySpace[spaceKey] ?? []).subtracting(waitingGone), spaceKey: spaceKey)
        var stateChanged = false
        if let floating = state.floating[spaceKey] {
            let alive = floating.filter { !gone.contains($0) }
            if alive.count != floating.count { state.floating[spaceKey] = alive.isEmpty ? nil : alive; stateChanged = true }
        }
        if let homes = state.floatHomes[spaceKey] {
            let alive = homes.filter { !gone.contains($0.id) }
            if alive.count != homes.count {
                state.floatHomes[spaceKey] = alive.isEmpty ? nil : alive
                stateChanged = true
            }
        }
        if let zoomed = state.zoomed[spaceKey], gone.contains(zoomed) { state.zoomed[spaceKey] = nil; stateChanged = true }
        soloProbed = soloProbed.filter { !gone.contains($0.key) }
        reclaimedWindows.subtract(gone)
        if stateChanged { store.save(state) }
        return stateChanged || !waitingGone.isEmpty || !placedWaiting.isEmpty
    }

    /// Replaces this Space's waiting windows; empty removes the Space's entry. Call with lock held.
    private func setWaitingLocked(_ ids: Set<WindowID>, spaceKey: String) {
        waitingBySpace[spaceKey] = ids.isEmpty ? nil : ids
    }

    /// Judges an unstarted Space once for this arrival; true if it started (the tick returns there).
    private func enrollUnstartedSpace(previous: Census, current: Census, spaceKey: String, quiet: Bool, authorization: OperationAuthorization) -> Bool {
        armAutomaticStart(previous: previous, current: current, spaceKey: spaceKey)
        if startPendingAutomaticSpace(current: current, spaceKey: spaceKey, quiet: quiet, authorization: authorization) { return true }
        lock.lock(); let hasPending = pendingAutoStart != nil; lock.unlock()
        if hasPending {
            let now = Date()
            let wait = max(quietInterval - now.timeIntervalSince(lastInputChange), arrivalDwell - now.timeIntervalSince(spaceArrivedAt))
            scheduleNextTick(after: max(wait, fastTickInterval))
        }
        return false
    }

    /// Prepares the automatic start of an unstarted Space from one standard window (windows present since launch count too). Moves no windows here.
    func armAutomaticStart(previous: Census, current: Census, spaceKey: String) {
        if autoPaused(spaceKey) { return }
        // An arrival that already tried the automatic start does not extend the deadline again with the same observation.
        // A front window that did not qualify (full screen, fixed size, rule-excluded) is not reread until the front or the window set changes.
        let windows = Set(current.windows.keys)
        lock.lock()
        let attempt = autoStartArmed[spaceKey]
        let already = attempt?.front == current.frontWindow && attempt?.ids.isSubset(of: windows) == true
        let declined = autoStartDeclined[spaceKey].map { $0.front == current.frontWindow && $0.windows == windows } ?? false
        let started = state.layouts[spaceKey] != nil
        lock.unlock()
        guard !already, !declined, !started, previous.spaceID == current.spaceID,
              let front = current.frontWindow, current.windows[front] == current.frontmostPID else { return }
        let snap = system.snapshot()
        guard snap.trusted, snap.spaceObservationAvailable, snap.spaceID == current.spaceID else { return }
        lock.lock(); let cfg = config; let held = Set(state.floating[spaceKey] ?? []); lock.unlock()
        let standard = TargetSelection.inspect(snap).targets.filter { cfg.rule(for: $0.app, title: $0.title) == nil && !held.contains($0.id) }.map(\.id)
        let enroll = automaticEnrollment(front: front, standard: standard)
        guard !standard.isEmpty, standard.contains(front), !enroll.isEmpty else {
            // Remember only when the front window was read and confirmed not to qualify (windows that could not be read, looked mid-move,
            // or matched a title-dependent rule are reread on the next observation).
            if let window = snap.windows.first(where: { $0.id == front }), !snap.unobservedApps.contains(window.app),
               !Self.observationIsTransient(window), cfg.rule(for: window.app, title: window.title).map({ $0.title.isEmpty }) ?? true {
                lock.lock(); autoStartDeclined[spaceKey] = (front, windows); lock.unlock()
            }
            return
        }
        lock.lock()
        let ids = Set(enroll)
        autoStartArmed[spaceKey] = (front, ids)
        pendingAutoStart = (spaceKey, front, ids, control.cancellationGeneration, Date().addingTimeInterval(autoStartWindow))
        lock.unlock()
    }

    /// Windows the automatic start arranges: the front window first, then every visible standard window.
    func automaticEnrollment(front: WindowID, standard: [WindowID]) -> [WindowID] {
        guard standard.contains(front) else { return standard }
        return [front] + standard.filter { $0 != front }
    }

    /// Starts with the observed targets only while the triggering front window, Space, and stop generation hold.
    @discardableResult
    /// `authorization` is the input at the start of the decision (input during preparation reads also stops it). Taken here when omitted.
    func startPendingAutomaticSpace(current: Census, spaceKey: String, quiet: Bool, authorization: OperationAuthorization? = nil) -> Bool {
        let authorization = authorization ?? OperationAuthorization(system: system, control: control)
        lock.lock()
        guard let pending = pendingAutoStart else { lock.unlock(); return false }
        guard !control.paused, !state.pausedSpaces.contains(pending.spaceKey), pending.generation == control.cancellationGeneration,
              pending.spaceKey == spaceKey, current.spaceID.map(String.init) == spaceKey,
              system.currentSpaceID() == current.spaceID, pending.until > Date(),
              current.frontWindow == pending.front, current.windows[pending.front] == current.frontmostPID,
              pending.ids.isSubset(of: Set(current.windows.keys)), state.layouts[spaceKey] == nil else {
            // Forgetting the preparation lets the next quiet observation prepare again (input that outlasted the deadline only postpones the start).
            pendingAutoStart = nil; autoStartArmed[pending.spaceKey] = nil; lock.unlock(); return false
        }
        // Do not start while crossing Spaces by key or on a just-arrived Space; key input also counts as not quiet.
        let now = Date()
        let settled = now.timeIntervalSince(spaceArrivedAt) >= arrivalDwell && now.timeIntervalSince(lastInputChange) >= quietInterval
        guard quiet, settled else { lock.unlock(); return false }
        pendingAutoStart = nil
        lock.unlock()
        // If only input, pause, or a Space change stopped it, prepare again on the next quiet observation even with the same front window.
        let started = arrange(source: "auto", kind: "auto-start", adding: pending.ids, automaticFront: pending.front, authorization: authorization) { [weak self] result in
            guard let self, result.outcome != .complete else { return }
            switch result.stopReason {
            case .userInput?, .cancelled?, .paused?, .spaceChanged?:
                lock.lock(); autoStartArmed[spaceKey] = nil; lock.unlock()
            default: break
            }
        }
        if case .started = started { return true }
        return false
    }

    /// On arriving at a Space: aligns visible standard windows with that Space's layout.
    /// New windows, leaving full screen, and moving from another display are not told apart here. Saved intent for Spaces that no longer exist is discarded.
    /// With `refitNow` false (button held, a drag moved a managed window), redistribution for departed managed windows waits for a later tick.
    func arrivedOnRebase(current: Census, spaceKey: String, quiet: Bool = true, refitNow: Bool = true, authorization: OperationAuthorization? = nil) {
        let authorization = authorization ?? OperationAuthorization(system: system, control: control)
        pendingDepartedRefit = nil
        removalHolds.removeAll()
        removalGate = nil
        // A Space we returned to is handled here, not by the hidden-Space redistribution.
        hiddenRefits[spaceKey] = nil
        hiddenRefitExhausted[spaceKey] = nil
        dirtyRepairs[spaceKey] = nil
        unansweredFits[spaceKey] = nil
        lock.lock()
        let dirty = hiddenRefitDirty.contains(spaceKey)
        if pendingAutoStart?.spaceKey != spaceKey { pendingAutoStart = nil }
        autoStartArmed[spaceKey] = nil
        autoStartDeclined[spaceKey] = nil
        let layout = state.layouts[spaceKey]
        let paused = control.paused || state.pausedSpaces.contains(spaceKey)
        lock.unlock()
        // If the list is unreadable or lacks the current Space (mid display change or wake), per-Space state is not dropped.
        if let spaces = system.existingSpaceIDs(), let here = current.spaceID, spaces.contains(here) {
            let existing = Set(spaces.map(String.init))
            lock.lock()
            // "Arrange this Space automatically" being off is not dropped: Spaces leave the list only while a display is disconnected and return with the same ID.
            let stale = state.layouts.keys.filter { !existing.contains($0) }
            waitingBySpace = waitingBySpace.filter { existing.contains($0.key) }
            if !stale.isEmpty {
                for k in stale { state.layouts[k] = nil; state.floating[k] = nil; state.zoomed[k] = nil; state.dialogRegions?[k] = nil }
                store.save(state)
            }
            lock.unlock()
        }
        guard let layout else {
            // Windows present on arriving at a Space without a layout are also judged once, without waiting for a difference.
            if !paused { armAutomaticStart(previous: current, current: current, spaceKey: spaceKey) }
            return
        }
        // Redistribute departed managed windows; incoming standard windows go beside in the same operation when quiet.
        var departed = layout.windowIDs.filter { current.windows[$0] == nil }
        // Windows that may still be on this Space (briefly missing from the list) are not redistributed until confirmed.
        var departedHeld = false
        if !departed.isEmpty, let sid = current.spaceID, assessRemovals(departed, pids: [:], spaceID: sid).held {
            departed = []
            departedHeld = true
            removalGate = spaceKey
        }
        notTileable = notTileable.filter { current.windows[$0.key] != nil }
        // Remembered before anything rearranges the layout they belong to, so they return to their place.
        if !departed.isEmpty { lock.lock(); rememberDeparturesLocked(departed, spaceKey: spaceKey); lock.unlock() }
        let placed = !paused && quiet && !departedHeld && placeMissing(current: current, spaceKey: spaceKey, authorization: authorization)
        if departedHeld, !paused {
            lock.lock(); let generation = control.cancellationGeneration; lock.unlock()
            pendingDepartedRefit = (spaceKey, generation)
            scheduleNextTick(after: fastTickInterval)
        } else if !placed, !departed.isEmpty || dirty, !paused, system.currentSpaceID() == current.spaceID {
            // The baseline advances with this arrival, so a deferred redistribution never comes back as a difference; remember it separately.
            lock.lock(); let generation = control.cancellationGeneration; lock.unlock()
            if !refitNow || arrange(source: "auto", kind: "auto-refit", heldOut: [:], authorization: authorization, unanswered: unansweredPolicy(spaceKey), completion: { [weak self] result in
                self?.rearmDepartedRefit(after: result, spaceKey: spaceKey, generation: generation)
            }) == .busy {
                pendingDepartedRefit = (spaceKey, generation)
                scheduleNextTick(after: fastTickInterval)
            }
        }
    }

    /// Inserts visible standard windows that are in neither the layout nor the floating set beside the focus.
    /// True if started. Windows AX says are not standard are not reobserved until their frame changes.
    /// Rule-excluded windows do not go into `notTileable`. After failing twice at the same frame, automatic retries stop.
    @discardableResult
    /// `authorization` is the input at the start of the decision. Taken here when omitted.
    func placeMissing(current: Census, spaceKey: String, authorization: OperationAuthorization? = nil) -> Bool {
        let authorization = authorization ?? OperationAuthorization(system: system, control: control)
        guard !autoPaused(spaceKey), system.currentSpaceID().map(String.init) == spaceKey,
              current.spaceID.map(String.init) == spaceKey, unansweredFitDue(spaceKey) else { return false }
        // Cleared only when focus moves to it; while the same window stays watched, the count is kept.
        let backoffNow = backoffClock()
        lock.lock()
        let known = Set(state.layouts[spaceKey]?.windowIDs ?? []).union(state.floating[spaceKey] ?? [])
        // Windows waiting for an observation retry do not query focus every time (only when the front window changes).
        let needsFocus = focusReadRequested || !integrateLedger.isEmpty || current.frontWindow != lastFrontForFailures
            || current.windows.keys.contains { !known.contains($0) && !observationBackoff.isWaiting($0, now: backoffNow) }
        lock.unlock()
        // Focus is read at most once per call (a front app that does not answer costs one read timeout).
        var focusRead: WindowID?? = nil
        if needsFocus {
            let focused = system.focusedWindowID()
            focusRead = .some(focused)
            if let focused, focused != lastFocusForFailures { clearIntegrateFailure(focused) }
            lastFocusForFailures = focused
            lastFrontForFailures = current.frontWindow
            focusReadRequested = false
        }
        // Cleared only when the user moved it; a frame change from our own late write keeps the count.
        let inputCount = system.inputActivityCount
        for id in current.windows.keys {
            guard let frame = current.bounds[id] else { continue }
            lock.lock()
            integrateLedger.forgiveMoved(id: id, frame: frame, inputCount: inputCount, tolerance: limits.tolerance)
            lock.unlock()
        }
        lock.lock()
        let layout = state.layouts[spaceKey]
        let floating = Set(state.floating[spaceKey] ?? [])
        let cfg = config
        lock.unlock()
        guard let layout else { return false }
        let layoutIDs = Set(layout.windowIDs)
        let unknown = current.windows.keys.filter { id in
            guard !layoutIDs.contains(id), !floating.contains(id) else { return false }
            if let seen = notTileable[id], let now = current.bounds[id], now.matches(seen, tolerance: limits.tolerance) { return false }
            return true
        }
        guard !unknown.isEmpty else {
            lock.lock(); waitingBySpace[spaceKey]?.subtract(layoutIDs); lock.unlock()
            return false
        }
        lock.lock()
        observationBackoff.keep(only: current.bounds.filter { unknown.contains($0.key) }, tolerance: limits.tolerance)
        // Reclaimed windows are read again only after a change on the Space, until they rejoin or are confirmed closed.
        let look = (front: current.frontWindow, windows: Set(current.windows.keys))
        let reclaimedHere = reclaimedWindows.intersection(unknown)
        if !reclaimedHere.isEmpty, reclaimLook.map({ $0.front != look.front || $0.windows != look.windows }) ?? true {
            reclaimLook = look
            for id in reclaimedHere { observationBackoff.clear(id) }
        }
        let backingOff = Set(unknown.filter { observationBackoff.isWaiting($0, now: backoffNow) })
        let retryAt = observationBackoff.nextAttempt(among: backingOff, now: backoffNow)
        lock.unlock()
        if let retryAt { scheduleNextTick(after: max(retryAt.timeIntervalSince(backoffNow), fastTickInterval)) }
        let needsLook = unknown.filter { id in
            if integrateGaveUp(id) || backingOff.contains(id) { return false }
            guard let frame = current.bounds[id] else { return true }
            guard let seen = lastUnclassified[id], frame.matches(seen.frame, tolerance: limits.tolerance) else { return true }
            // A window excluded by a title rule is reconsidered when its title changes (reading only that window).
            if let title = seen.title, system.windowTitle(id) != title { return true }
            return false
        }
        guard !needsLook.isEmpty else {
            let held = unknown.filter { integrateGaveUp($0) }
            lock.lock()
            waitingBySpace[spaceKey] = held.isEmpty ? nil : Set(held)
            lock.unlock()
            return false
        }
        // Only the windows looked at are read, so an app that does not answer elsewhere on the Space does not stall the look.
        let snap = system.snapshot(limitingTo: Set(needsLook))
        guard snap.spaceID == current.spaceID, system.currentSpaceID() == current.spaceID else { return false }
        let standard = Set(TargetSelection.inspect(snap, appRule: { cfg.tilingExclusionReason(bundleID: $0.app, title: $0.title) }).targets.map(\.id))
        var transient: [WindowID] = []
        for id in needsLook where !standard.contains(id) {
            // Windows missing from observation, seen on another Space or with unknown membership, or of undecidable kind can occur mid Space change.
            // They are not remembered by frame; they are reconsidered after an interval.
            guard let window = snap.windows.first(where: { $0.id == id }) else { transient.append(id); continue }
            if Self.observationIsTransient(window) { transient.append(id); continue }
            guard let frame = current.bounds[id] else { continue }
            // Windows AX says are not standard are remembered by frame only; rule-excluded windows separately, so they return if the rule is removed.
            if TargetSelection.exclusionReason(window) != nil {
                notTileable[id] = frame
            } else {
                let byTitle = cfg.rule(for: window.app, title: window.title).map { !$0.title.isEmpty } ?? false
                lastUnclassified[id] = Unclassified(frame: frame, title: byTitle ? window.title : nil)
            }
        }
        if !transient.isEmpty {
            lock.lock()
            let held = transient.filter { reclaimedWindows.contains($0) }
            let retried = transient.filter { !reclaimedWindows.contains($0) }
            observationBackoff.hold(held, frames: current.bounds)
            observationBackoff.note(retried, frames: current.bounds, now: backoffClock())
            lock.unlock()
            if !retried.isEmpty { scheduleNextTick(after: ObservationBackoff.firstDelay) }
        }
        let missing = unknown.filter { standard.contains($0) && !integrateGaveUp($0) && !backingOff.contains($0) }
        let gaveUp = unknown.filter { standard.contains($0) && integrateGaveUp($0) }
        lock.lock()
        let waitingNow = Set(missing + gaveUp)
        waitingBySpace[spaceKey] = waitingNow.isEmpty ? nil : waitingNow
        lock.unlock()
        guard !missing.isEmpty else { return false }
        let focused = focusRead ?? system.focusedWindowID()
        let accept = integrateForeground(missing, beside: focusedManaged(focused, in: layout, spaceKey: spaceKey), authorization: authorization,
                                         unanswered: unansweredPolicy(spaceKey))
        if case .started = accept { return true }
        if case .busy = accept { revealAsNew(missing) }
        return false
    }

    private func clearIntegrateFailure(_ id: WindowID) {
        lock.lock(); integrateLedger.clear(id); observationBackoff.clear(id); lock.unlock()
    }

    private func integrateGaveUp(_ id: WindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return integrateLedger.gaveUp(id)
    }

    func noteSpaceArrival(at date: Date = Date()) {
        spaceArrivedAt = date
        departureChecked.removeAll()
        elementsRetainedOn = nil
        // A new arrival reconsiders windows that could not be observed on the previous Space right away.
        lock.lock(); observationBackoff.removeAll(); lock.unlock()
    }

    /// A hint that focus may have moved; the next placeMissing reads focus once. Call on the operations queue.
    func requestFocusRead() {
        focusReadRequested = true
    }

    // MARK: - Removal assessment

    /// Verdict on a managed window missing from the list.
    enum RemovalVerdict: Equatable {
        /// Closed (process exited, gone from the full window list, or now another process's window).
        case closed
        /// Visible but fading out while closing. Removed from the layout, but focus moves only once it is confirmed gone from the list.
        case fading
        /// Moved to one other Space.
        case departed
        /// Minimized, its app hidden, or still unconfirmed after waiting. Removed from the layout but not treated as closed.
        case lost
        /// Still on this Space (or unconfirmed). Wait without removing it from the layout.
        case held
    }

    /// `record` is the full-window-list entry (nil: not in the list). `listAvailable` false means the list could not be read.
    static func removalVerdict(listAvailable: Bool, record: CGWindowRecord?, expectedPID: Int32?, spaces: [UInt64]?, currentSpace: UInt64,
                               minimized: Bool?, appHidden: Bool?, heldSince: Date?, now: Date, hold: TimeInterval) -> RemovalVerdict {
        let expired = heldSince.map { now.timeIntervalSince($0) >= hold } ?? false
        guard listAvailable else { return expired ? .lost : .held }
        guard let record, expectedPID.map({ $0 == record.pid }) ?? true else { return .closed }
        // Firm evidence of moving to another Space or minimizing is checked before faintness.
        if let spaces, spaces.count == 1, spaces[0] != currentSpace { return .departed }
        // A hidden app reading false is no evidence either way (an incomplete LaunchServices record reads false).
        if minimized == true || appHidden == true { return .lost }
        if record.alpha < WindowCensus.vanishingAlpha { return .fading }
        return expired ? .lost : .held
    }

    /// Judges vanished managed windows together. `held` if any window must be waited for; returns windows seen closed or fading. Operations queue.
    /// Windows decided by the list and membership are not queried through AX; minimize checks get at most 0.3 s for the whole judgment.
    private func assessRemovals(_ gone: [WindowID], pids: [WindowID: Int32], spaceID: UInt64) -> (held: Bool, closed: Set<WindowID>) {
        let exited = Set(gone.filter { id in pids[id].map(system.processExited) ?? false })
        let rest = Set(gone).subtracting(exited)
        guard !rest.isEmpty else {
            for id in gone { removalHolds[id] = nil }
            return (false, exited)
        }
        let records = system.windowRecords(rest)
        let now = Date()
        let axDeadline = now.addingTimeInterval(0.3)
        var held = false
        var closed = exited
        // One lookup per app; "Hide Others" removes many windows at once.
        var hiddenApps: [Int32: Bool?] = [:]
        for id in rest.sorted() {
            let record = records?[id]
            let spaces = record == nil ? nil : system.spacesOf(id)
            let hidden: Bool? = record.flatMap { record in
                if let known = hiddenApps[record.pid] { return known }
                let value = system.appHidden(pid: record.pid)
                hiddenApps[record.pid] = .some(value)
                return value
            }
            func verdict(minimized: Bool?) -> RemovalVerdict {
                Self.removalVerdict(listAvailable: records != nil, record: record, expectedPID: pids[id], spaces: spaces,
                                    currentSpace: spaceID, minimized: minimized, appHidden: hidden, heldSince: removalHolds[id], now: now, hold: removalHold)
            }
            // The hidden app is checked before the minimized state, so it never spends the AX budget.
            var result = verdict(minimized: nil)
            // Only windows that would otherwise be waited for are checked for being minimized (one observed window's attribute, time-limited).
            if result == .held, record != nil, Date() < axDeadline, let minimized = system.readMinimized(id, deadline: axDeadline) {
                result = verdict(minimized: minimized)
            }
            switch result {
            case .held:
                if removalHolds[id] == nil { removalHolds[id] = now }
                held = true
            case .closed, .fading:
                closed.insert(id)
                removalHolds[id] = nil
            case .departed:
                removalHolds[id] = nil
            case .lost:
                // A window whose wait ran out stays so while other windows in the same observation are waited for (holds do not extend each other).
                break
            }
        }
        if held { scheduleNextTick(after: fastTickInterval) }
        return (held, closed)
    }

    // MARK: - Hidden Space refit

    /// Remembers a departure when SkyLight confirms the window moved from the `source` Space to one other Space. Operations queue.
    @discardableResult
    private func noteDepartureIfConfirmed(_ id: WindowID, from source: UInt64) -> UInt64? {
        guard let list = system.spacesOf(id), list.count == 1, list[0] != source else { return nil }
        noteDeparture(of: [id], from: String(source))
        return list[0]
    }

    /// Remembers departures. Seeing the same departure again does not extend the deadline; exhausted departures are not tried until new evidence appears.
    private func noteDeparture(of ids: Set<WindowID>, from spaceKey: String) {
        lock.lock(); let layoutIDs = Set(state.layouts[spaceKey]?.windowIDs ?? []); lock.unlock()
        let fresh = ids.intersection(layoutIDs).subtracting(hiddenRefitExhausted[spaceKey] ?? [])
        guard !fresh.isEmpty else { return }
        let now = Date()
        if var record = hiddenRefits[spaceKey] {
            record.departed.formUnion(fresh)
            hiddenRefits[spaceKey] = record
        } else {
            hiddenRefits[spaceKey] = HiddenRefit(departed: fresh, attempts: 0, notBefore: now, deadline: now.addingTimeInterval(30))
        }
        scheduleNextTick(after: fastTickInterval)
    }

    /// Windows visible on the current Space that belong to another Space's layout: if SkyLight puts them only on the current Space, that is a departure from the other Space.
    /// Windows with undecided membership are not marked done (used once decided).
    /// On-screen windows that SkyLight puts only on other Spaces (windows on another display's Space): windows outside the layout, and managed windows
    /// whose center is outside the current display's work area (dragged or sent to another display; they then leave through the usual removal path).
    /// Windows known to be on the current Space are not queried again until their frame changes; windows on other Spaces are queried every time
    /// (right after moving in, the old Space's membership may linger; once settled they count as current-Space windows at once).
    /// Windows with unreadable membership are treated as current-Space windows. Operations queue.
    private func windowsOnOtherSpaces(_ census: Census, space: UInt64, spaceKey: String) -> Set<WindowID> {
        lock.lock(); let managed = Set(state.layouts[spaceKey]?.windowIDs ?? []); lock.unlock()
        localWindows = localWindows.filter { census.bounds[$0.key] == $0.value.bounds && $0.value.space == space }
        let area = system.currentWorkArea()
        var foreign: Set<WindowID> = []
        for (id, bounds) in census.bounds {
            // Managed windows off this display are asked every time: membership can lag behind a move to another display.
            let offDisplay = managed.contains(id) && !area.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            guard offDisplay || (!managed.contains(id) && localWindows[id] == nil) else { continue }
            guard let list = system.spacesOf(id) else { continue }
            if !list.isEmpty && !list.contains(space) { foreign.insert(id) }
            else if !offDisplay { localWindows[id] = (space, bounds) }
        }
        return foreign
    }

    private func noteArrivalsFromOtherSpaces(_ current: Census, spaceKey: String) {
        guard let sid = current.spaceID else { return }
        lock.lock()
        let layouts = state.layouts
        lock.unlock()
        let candidates = current.windows.keys.filter { id in
            !departureChecked.contains(id) && layouts.contains { $0.key != spaceKey && $0.value.windowIDs.contains(id) }
        }
        for id in candidates {
            // Mid-move, the old Space's membership may linger; mark done only once settled on the current Space alone.
            guard let list = system.spacesOf(id), list == [sid] else { continue }
            departureChecked.insert(id)
            for (key, layout) in layouts where key != spaceKey && layout.windowIDs.contains(id) {
                noteDeparture(of: [id], from: key)
            }
        }
        // Windows back on their original Space leave the exhausted departures.
        if var exhausted = hiddenRefitExhausted[spaceKey] {
            exhausted.subtract(current.windows.keys)
            hiddenRefitExhausted[spaceKey] = exhausted.isEmpty ? nil : exhausted
        }
    }

    /// Redistributes one due departure while its Space stays hidden. True if started. Operations queue.
    @discardableResult
    func runHiddenRefitIfDue(currentKey: String) -> Bool {
        guard !hiddenRefits.isEmpty else { return false }
        // An unreadable Space list (waking from sleep, a display change) proves nothing about the departures; they wait for a readable one.
        guard let existing = system.existingSpaceIDs() else { return false }
        let now = Date()
        var nextWake: Date?
        for key in hiddenRefits.keys.sorted(by: { hiddenRefits[$0]!.deadline < hiddenRefits[$1]!.deadline }) {
            guard var record = hiddenRefits[key] else { continue }
            lock.lock()
            let layout = state.layouts[key]
            let blocked = control.paused || state.pausedSpaces.contains(key) || state.zoomed[key] != nil
            lock.unlock()
            // Reconfirm on each try: windows back on the source or with unknown membership leave the departure.
            let departed = record.departed.intersection(layout?.windowIDs ?? []).filter { id in
                guard let list = system.spacesOf(id), list.count == 1, let space = UInt64(key) else { return false }
                return list[0] != space
            }
            let remaining = Set(layout?.windowIDs ?? []).subtracting(departed)
            guard key != currentKey, !blocked, let space = UInt64(key), existing.contains(space),
                  !departed.isEmpty, !remaining.isEmpty, system.inputObservationAvailable,
                  let display = system.spaceDisplay(space), !display.shown else {
                // Departures that fail the conditions are dropped and left to the redistribution on returning to that Space.
                hiddenRefits[key] = nil
                continue
            }
            if record.deadline <= now || record.attempts >= 2 {
                hiddenRefitExhausted[key, default: []].formUnion(record.departed)
                hiddenRefits[key] = nil
                continue
            }
            if record.notBefore > now {
                nextWake = min(nextWake ?? record.notBefore, record.notBefore)
                continue
            }
            record.departed = departed
            hiddenRefits[key] = record
            let reason = L("Moved to another Space", "別の操作スペースへ移動した")
            let accept = arrange(source: "auto", kind: "auto-refit-hidden", heldOut: Dictionary(uniqueKeysWithValues: departed.map { ($0, reason) }),
                                 otherSpace: (space, .hidden)) { [weak self] result in
                self?.hiddenRefitFinished(key: key, departed: departed, result: result)
            }
            switch accept {
            case .started: return true
            case .busy: scheduleNextTick(after: fastTickInterval); return false
            case .notApplicable: hiddenRefits[key] = nil; return false
            }
        }
        if let nextWake { scheduleNextTick(after: max(nextWake.timeIntervalSinceNow, fastTickInterval)) }
        return false
    }

    /// Clears the departure once the layout is adopted; otherwise retries once after a pause. Operations queue.
    private func hiddenRefitFinished(key: String, departed: Set<WindowID>, result: OperationResult) {
        lock.lock()
        let adopted = !(state.layouts[key]?.windowIDs.contains { departed.contains($0) } ?? true)
        lock.unlock()
        guard var record = hiddenRefits[key] else { return }
        if adopted {
            record.departed.subtract(departed)
            hiddenRefits[key] = record.departed.isEmpty ? nil : record
            return
        }
        if result.stopReason == .spaceChanged, system.currentSpaceID().map(String.init) == key {
            hiddenRefits[key] = nil
            return
        }
        record.attempts += 1
        record.notBefore = Date().addingTimeInterval(1)
        hiddenRefits[key] = record
        scheduleNextTick(after: 1)
    }

    // MARK: - Arrival on a Space another display shows

    /// Remembers a window sent to a Space another display is showing (operations queue). A Space that is hidden or has no layout waits for the user instead.
    private func noteShownArrival(_ identity: WindowIdentity, space: UInt64, display: String) {
        guard let shown = system.spaceDisplay(space), shown.shown, shown.display == display else { return }
        lock.lock(); let managed = state.layouts[String(space)] != nil; let generation = control.cancellationGeneration; lock.unlock()
        guard managed else { return }
        let now = Date()
        shownArrivals[identity.window] = ShownArrival(identity: identity, space: space, display: display, generation: generation,
                                                      attempts: 0, notBefore: now, deadline: now.addingTimeInterval(30))
        scheduleNextTick(after: fastTickInterval)
    }

    /// Adds one due arrival to the layout of the Space another display shows. True if started. Operations queue.
    @discardableResult
    /// `authorization` is the observation's decision baseline, so input or cancellation since the tick began stops it.
    func runShownArrivalIfDue(currentKey: String, authorization: OperationAuthorization) -> Bool {
        // An unreadable Space list leaves every display unknown; the arrivals wait for a readable one until their deadline.
        guard !shownArrivals.isEmpty, system.existingSpaceIDs() != nil else { return false }
        let now = Date()
        var nextWake: Date?
        for (id, record) in shownArrivals.sorted(by: { $0.value.deadline < $1.value.deadline }) {
            let key = String(record.space)
            lock.lock()
            let layout = state.layouts[key]
            let blocked = control.paused || state.pausedSpaces.contains(key) || state.zoomed[key] != nil
            let generation = control.cancellationGeneration
            lock.unlock()
            let owner = system.windowRecords([id])?[id].map { identity(of: id, pid: $0.pid) }
            guard key != currentKey, !blocked, let layout, !layout.windowIDs.contains(id), record.generation == generation,
                  record.deadline > now, record.attempts < 2, owner.map({ WindowRouter.sameWindow($0, record.identity) }) == true,
                  system.spacesOf(id) == [record.space], system.inputObservationAvailable,
                  let display = system.spaceDisplay(record.space), display.shown, display.display == record.display else {
                // Left to the arrival on that Space when the user goes there.
                shownArrivals[id] = nil
                continue
            }
            if record.notBefore > now {
                nextWake = min(nextWake ?? record.notBefore, record.notBefore)
                continue
            }
            guard authorization.interruptionReason(system: system, control: control) == nil else { scheduleNextTick(after: fastTickInterval); return false }
            // Layout windows SkyLight puts on exactly one other Space left this Space (dragged away, for example); they are dropped, not observed there.
            let departed = layout.windowIDs.filter { other in
                guard let list = system.spacesOf(other), list.count == 1 else { return false }
                return list[0] != record.space
            }
            let reason = L("Moved to another Space", "別の操作スペースへ移動した")
            let accept = arrange(source: "auto", kind: "auto-arrive-shown", heldOut: Dictionary(uniqueKeysWithValues: departed.map { ($0, reason) }), adding: [id],
                                 authorization: authorization.retargeted(to: record.space),
                                 otherSpace: (record.space, .shown(display: record.display))) { [weak self] result in
                self?.shownArrivalFinished(id, key: key, result: result)
            }
            switch accept {
            case .started: return true
            case .busy: scheduleNextTick(after: fastTickInterval); return false
            case .notApplicable: shownArrivals[id] = nil; return false
            }
        }
        if let nextWake { scheduleNextTick(after: max(nextWake.timeIntervalSinceNow, fastTickInterval)) }
        return false
    }

    /// Done once the window is in the layout; otherwise one retry after a pause. Operations queue.
    private func shownArrivalFinished(_ id: WindowID, key: String, result: OperationResult) {
        lock.lock(); let placed = state.layouts[key]?.windowIDs.contains(id) ?? false; lock.unlock()
        guard var record = shownArrivals[id] else { return }
        if placed { shownArrivals[id] = nil; return }
        record.attempts += 1
        record.notBefore = Date().addingTimeInterval(1)
        shownArrivals[id] = record
        scheduleNextTick(after: 1)
    }

    // MARK: - Send reconciliation and pending arrivals

    /// Window identity (window ID, pid, process launch time, lifetime number). Launch times are cached for one observation (discarded at the start of each tick; operations queue).
    func identity(of window: WindowID, pid: Int32) -> WindowIdentity {
        let start: Date?
        if let cached = processStarts[pid] { start = cached } else { start = processStartTime(pid); processStarts[pid] = start }
        return WindowIdentity(window: window, pid: pid, lifetime: router.lifetime(of: window), processStart: start)
    }

    /// Excludes the window of a send with an uncertain result and starts reconciling (operations queue).
    private func holdUncertainSend(_ identity: WindowIdentity, source: UInt64, target: UInt64, targetUUID: String?) {
        sendHolds[identity.window] = SendHold(identity: identity, source: source, target: target, targetUUID: targetUUID, startedAt: routingClock())
        updateRoutingExcluded()
        reconcileHolds()
    }

    /// Rechecks reconciling windows (each tick and right after a send). Membership only the destination -> pending arrival; only the source and still for 3 s -> normal placement; gone -> forgotten.
    /// Otherwise the exclusion stays (time alone never lifts it). Operations queue.
    private func reconcileHolds() {
        guard !sendHolds.isEmpty else { return }
        let records = system.windowRecords(Set(sendHolds.keys))
        let now = routingClock()
        for (id, var hold) in sendHolds {
            // The same ID with a different owner (pid, launch time, lifetime) is another window: stop reconciling (and create no pending arrival for it).
            var exists: Bool? = system.processExited(hold.identity.pid) ? false : records.map { $0[id] != nil }
            if let record = records?[id], !WindowRouter.sameWindow(identity(of: id, pid: record.pid), hold.identity) { exists = false }
            switch hold.evaluate(membership: system.spacesOf(id), frame: records?[id]?.bounds, exists: exists, now: now, tolerance: limits.tolerance) {
            case .keep: sendHolds[id] = hold
            case .arrived:
                sendHolds[id] = nil
                if let uuid = hold.targetUUID { addPendingArrival(hold.identity, spaceUUID: uuid) }
            case .stayed, .gone:
                sendHolds[id] = nil
            }
        }
        updateRoutingExcluded()
        if !sendHolds.isEmpty { scheduleNextTick(after: 0.5) }
    }

    /// Adds a pending arrival (when the destination Space is shown, it is inserted without the arrival dwell). Operations queue.
    private func addPendingArrival(_ identity: WindowIdentity, spaceUUID: String) {
        lock.lock(); let generation = control.cancellationGeneration; lock.unlock()
        pendingArrivals[spaceUUID, default: [:]][identity] = generation
    }

    /// Whether a pending-arrival window is visible on the current Space without being placed. Entries placed, floated, gone, moved to another Space, or from an old generation are removed.
    private func pendingArrivalPresent(in current: Census) -> Bool {
        guard !pendingArrivals.isEmpty, let space = current.spaceID, let uuid = spaceListing()?.currentDisplayUUIDs()?[space],
              var entries = pendingArrivals[uuid] else { return false }
        lock.lock()
        let key = String(space)
        let placed = Set(state.layouts[key]?.windowIDs ?? []).union(state.floating[key] ?? [])
        let generation = control.cancellationGeneration
        let cfg = config
        lock.unlock()
        var present = false
        let missing = Set(entries.keys.map(\.window)).subtracting(current.windows.keys)
        let records = missing.isEmpty ? [:] : system.windowRecords(missing)
        for (identity, entryGeneration) in entries {
            let id = identity.window
            if entryGeneration != generation || placed.contains(id) || system.processExited(identity.pid) { entries[identity] = nil; continue }
            if let pid = current.windows[id] {
                // The same ID with a different owner (pid, launch time, lifetime) is another window.
                if !WindowRouter.sameWindow(self.identity(of: id, pid: pid), identity) { entries[identity] = nil; continue }
                // Rule-excluded windows (ignore, float) are not inserted.
                if let app = system.snapshot(limitingTo: [id]).windows.first(where: { $0.id == id }), cfg.tilingExclusionReason(bundleID: app.app, title: app.title) != nil {
                    entries[identity] = nil; continue
                }
                present = true
            } else if let records, records[id] == nil {
                entries[identity] = nil
            } else if let membership = system.spacesOf(id), !membership.isEmpty, membership != [space] {
                entries[identity] = nil
            }
        }
        pendingArrivals[uuid] = entries.isEmpty ? nil : entries
        return present
    }

    /// Rebuilds the table of windows kept out of the layout (reconciling sends, and rule windows being classified or sent).
    private func updateRoutingExcluded() {
        var map: [WindowID: String] = [:]
        for id in sendHolds.keys { map[id] = SendHold.reason }
        for (id, reason) in routerExclusions() { map[id] = reason }
        lock.lock(); routingExcluded = map; lock.unlock()
    }

    /// Rule windows being classified or sent (C).
    private func routerExclusions() -> [WindowID: String] { router.exclusions().mapValues(\.reason) }

    // MARK: - `action = "space"` rules

    /// Per tick observation: finds new windows, removes them from the layout before classifying, and sends ready windows (if an operation slot is free and the gates pass). Operations queue.
    /// Does nothing without space rules (when a rule is added, memory is rebuilt so existing windows are not treated as new).
    private func routeNewWindows(_ current: Census, space: UInt64) {
        lock.lock(); let cfg = config; lock.unlock()
        guard cfg.rules.contains(where: { $0.action == .space }) else { return }
        // At launch: mark windows in the full window list known (Spaces are not marked observed; a Space not yet seen is seeded when first seen).
        if !router.seededAtLaunch {
            var seeds: [(identity: WindowIdentity, spaces: [UInt64])] = []
            if let inventory = takeInventory() {
                for window in inventory.windows { seeds.append((identity(of: WindowID(window.id), pid: window.pid), window.spaces)) }
            }
            router.seedAtLaunch(seeds)
        }
        // Forget windows of processes that quit. Windows gone from this Space that are absent from the full window list are closed (the same ID reappearing is a new window).
        for pid in Set(router.entries.values.map(\.identity.pid)) where system.processExited(pid) { router.forgetProcess(pid) }
        let missing = router.missing(on: space, present: Set(current.windows.keys)).subtracting(sendHolds.keys)
        if !missing.isEmpty, let records = system.windowRecords(missing) {
            router.noteDestroyed(missing.filter { records[$0] == nil })
        }
        // Return expired classifying / ready windows first (an expired window is not sent even if it matches in this observation).
        _ = router.expire(now: routingClock())
        let identities = current.windows.map { identity(of: $0.key, pid: $0.value) }
        let started = router.observe(identities, space: space, now: routingClock()) { [self] identity in
            appBundleID(identity.pid).map { cfg.hasSpaceRule(forApp: $0) } ?? false
        }
        // Before the AX read, remove classifying windows from the layout (an arrangement accepted during the read does not write them either).
        updateRoutingExcluded()
        classify(on: space, config: cfg)
        _ = router.expire(now: routingClock())
        updateRoutingExcluded()
        if !started.isEmpty || !router.classifying(on: space).isEmpty || !router.ready(on: space).isEmpty { scheduleNextTick(after: fastTickInterval) }
        // Send one ready window (taking an operation slot; if unavailable or a gate is closed, next tick within the ready deadline).
        guard let next = router.ready(on: space).first, !isBusy, routeGatesOpen(spaceKey: String(space)) else { return }
        startRoute(next.window, rule: next.rule, source: space, census: current)
    }

    /// Limit for one classification read (slower apps are skipped for a while) and the number of windows read at once.
    static let classificationReadBudget: TimeInterval = 0.25
    static let classificationBackoff: TimeInterval = 2
    static let classificationReadsPerTick = 4

    /// Classification: a normal window (AX standard window, not a sheet, dialog, or popover, on the current Space) matching a rule.
    /// Reads are limited to the windows, a few at a time. Apps that read slowly are skipped for a while (their windows go to normal placement at the deadline).
    /// The deadline is rechecked after reading (past it after a slow read, nothing is sent).
    private func classify(on space: UInt64, config cfg: Config) {
        let now = routingClock()
        let waiting = router.classifying(on: space).filter { id in
            guard let pid = router.entries[id]?.identity.pid else { return false }
            return (classificationBackoffUntil[pid] ?? .distantPast) <= now
        }
        guard !waiting.isEmpty else { return }
        let batch = Array(waiting.prefix(Self.classificationReadsPerTick))
        // Pass a deadline for the whole read (each AX request's limit is cut to the remaining time), so an unresponsive app never stalls the operations queue.
        let snap = system.snapshot(limitingTo: Set(batch), deadline: Date().addingTimeInterval(Self.classificationReadBudget))
        let after = routingClock()
        // Apps that did not finish by the deadline or exceeded the budget are skipped for a while (their windows go to normal placement at the deadline).
        let slow = after.timeIntervalSince(now) > Self.classificationReadBudget
        for id in batch {
            guard let pid = router.entries[id]?.identity.pid else { continue }
            let label = appBundleID(pid) ?? "pid\(pid)"
            let unread = !snap.windows.contains { $0.id == id } && (snap.unobservedApps.contains(label) || snap.unobservedApps.contains("pid\(pid)"))
            if slow || unread { classificationBackoffUntil[pid] = after.addingTimeInterval(Self.classificationBackoff) }
        }
        for id in batch {
            guard router.isClassifying(id, at: after), let entry = router.entries[id],
                  let window = snap.windows.first(where: { $0.id == id }), window.pid == entry.identity.pid else { continue }
            if !cfg.hasSpaceRule(forApp: window.app) { router.release(id); continue }
            guard window.kind == .standard, window.membership == .current, TargetSelection.exclusionReason(window) == nil else { continue }
            if let match = cfg.spaceRule(for: window.app, title: window.title) { router.markReady(id, rule: match.index, now: after) }
            // Windows not yet matching a title condition are reconsidered until the deadline (past it, never sent; later title changes never send).
        }
    }

    /// Send gates: global pause, the Space's pause, Accessibility, input observation, mouse button.
    private func routeGatesOpen(spaceKey: String) -> Bool {
        lock.lock(); let spacePaused = state.pausedSpaces.contains(spaceKey); lock.unlock()
        return !control.paused && !spacePaused && system.axTrusted && system.inputObservationAvailable && !system.mouseButtonDown
    }

    /// Runs a rule's send in an operation slot (never concurrently with automatic arrangement, enrollment, corrections, or manual operations).
    /// Gates (settings generation, global and Space pause, Accessibility, input observation, mouse button, interruption, source Space) are checked
    /// after slow reads and right before issuing (`sendWindow`'s continuation check), and carried into follow and front restoration.
    /// When a gate stopped it before issuing, it retries on the next tick with a new authorization within the ready deadline (3 s from first becoming ready, never extended).
    /// Issued sends and sends with uncertain results are not retried. A settings change, lost identity, no longer matching the rule, or no destination ends it.
    private func startRoute(_ id: WindowID, rule ruleIndex: Int, source: UInt64, census: Census) {
        lock.lock(); let cfg = config; let generation = configGeneration; lock.unlock()
        guard cfg.rules.indices.contains(ruleIndex), cfg.rules[ruleIndex].action == .space, let pid = census.windows[id],
              let saved = router.entries[id]?.identity else { router.consume(id); updateRoutingExcluded(); return }
        let rule = cfg.rules[ruleIndex]
        let sender: SpaceSender
        if let override = spaceSenderOverride { sender = override }
        else if let sc = spaceControl { sender = { sc.sendWindow($0, toSpace: $1, beforeIssue: $2.beforeIssue, afterIssue: $2.afterIssue) } }
        else { router.consume(id); updateRoutingExcluded(); return }
        // Without the direct move, nothing is sent (dragging switches Spaces); the window is arranged as usual.
        guard sendAvailableOverride ?? spaceControl?.canSendWithoutFollowing ?? true else { router.consume(id); updateRoutingExcluded(); return }
        // Front restoration (the same contract as B) only when the sent window was in front; note the front at acceptance and the activation count.
        let restore = census.frontWindow == id
            ? restoreCandidate(excluding: id, space: source, census: census).map {
                RestoreContext(candidate: $0, acceptedFrontPID: census.frontmostPID ?? pid, sentWindow: id, activations: activationCount()) }
            : nil
        let landing = SpaceLanding(dest: 0)
        let finalize = { [self] in
            // Only after a follow, or when macOS changed the Space, is the observed transition recorded before publishing.
            guard let observed = system.currentSpaceID(), observed != source else { return }
            noteSpaceTransition(to: observed)
            if let origin = landing.origin, observed == landing.dest { lock.lock(); previousSpaceID = origin; lock.unlock() }
        }
        _ = runSimple(kind: "auto-route", progress: L("Sending a new window to another Space", "新しいウインドウを別の操作スペースへ送っています"), source: "auto",
                      finalize: finalize) { [self] authorization in
            router.markSending(id)
            updateRoutingExcluded()
            var retry = false
            defer {
                if retry { router.retry(id) } else { router.consume(id) }
                updateRoutingExcluded(); lastSeen = nil; scheduleNextTick(after: fastTickInterval)
            }
            func skipped(_ message: String) -> OperationResult { OperationResult.note(kind: "auto-route", spaceID: source, message: message, ok: false) }
            // Gates. `followed` covers follow and restoration (the Space may change).
            func configChanged() -> Bool { lock.lock(); defer { lock.unlock() }; return configGeneration != generation }
            func gate(onSource: Bool = true) -> Bool {
                guard !configChanged(), routeGatesOpen(spaceKey: String(source)),
                      authorization.interruptionReason(system: system, control: control) == nil else { return false }
                return !onSource || system.currentSpaceID() == source
            }
            let blocked = L("A new window was not sent yet because of the pause state, input, or a Space change; it is tried again for a moment.",
                            "停止・入力・操作スペースの変化のため、新しいウインドウはまだ送っていません。しばらく試し直します。")
            if configChanged() { return skipped(L("A new window was not sent because the settings changed.", "設定が変わったため、新しいウインドウを送りませんでした。")) }
            guard gate() else { retry = true; return skipped(blocked) }
            // Identity (pid, launch time, lifetime) and whether the rule still matches; gates are rechecked after slow reads.
            guard WindowRouter.sameWindow(identity(of: id, pid: pid), saved),
                  let window = system.snapshot(limitingTo: [id]).windows.first(where: { $0.id == id }), window.pid == pid, window.kind == .standard,
                  window.membership == .current, TargetSelection.exclusionReason(window) == nil,
                  cfg.spaceRule(for: window.app, title: window.title)?.index == ruleIndex else {
                return skipped(L("A new window was not sent because it no longer matched the rule.", "新しいウインドウがルールに合わなくなったため、送りませんでした。"))
            }
            if configChanged() { return skipped(L("A new window was not sent because the settings changed.", "設定が変わったため、新しいウインドウを送りませんでした。")) }
            guard gate() else { retry = true; return skipped(blocked) }
            // Loading has confirmed that space rules have a number.
            guard let desktop = rule.space else { return skipped("") }
            let target = SpaceTarget.index(desktop)
            let resolved: ResolvedSpace
            switch resolveSpace(target) {
            case .failure(let why):
                return skipped(L("A Space rule for \(AppNames.localized(window.app)) did not send a window: \(why.message)", "\(AppNames.localized(window.app))の操作スペースのルールはウインドウを送りませんでした: \(why.message)"))
            case .success(let value): resolved = value
            }
            guard resolved.id != source else { return skipped(L("The window is already on the rule's Space.", "ウインドウはすでにルールの操作スペースにあります。")) }
            guard !router.isPaused(space: source, rule: ruleIndex, now: routingClock()) else {
                return skipped(L("This rule is paused on this Space for a minute because the app kept opening new windows after they were sent.", "送ったあとにアプリが新しいウインドウを開き続けたため、この操作スペースではこのルールを1分止めています。"))
            }
            guard destinationStillValid(resolved) else { return skipped(Self.destinationChanged) }
            let dest = resolved.id
            // Right before issuing, every gate including the source Space. After issuing, the source Space is not required (if macOS switched, membership only on the destination is still confirmed).
            let outcome = sender(CGWindowID(id.raw), dest, SendGates(beforeIssue: { gate() }, afterIssue: { gate(onSource: false) }))
            // The departure is recorded from the window's actual membership, independent of overall success.
            noteDepartureIfConfirmed(id, from: source)
            if case .notIssued(let failure) = outcome {
                // Only a stop at a gate (not issued) retries within the deadline; a settings change ends it.
                if failure == .interrupted, !configChanged() { retry = true; return skipped(blocked) }
                return skipped(describe(failure))
            }
            var looping = ""
            if router.noteSend(app: window.app, space: source, rule: ruleIndex, now: routingClock()) {
                looping = Copy.sentenceSeparator + L("The app kept opening new windows, so this rule is paused on this Space for a minute.", "アプリが新しいウインドウを開き続けたため、この操作スペースではこのルールを1分止めます。")
            }
            switch outcome {
            case .confirmed:
                if let uuid = resolved.uuid { addPendingArrival(saved, spaceUUID: uuid) }
                // A successful send stays successful regardless of follow and restoration. A requested follow that cannot be confirmed makes it partial.
                var followFailed = false
                var restoreNote = ""
                if rule.follow {
                    let switcher: SpaceSwitcher? = spaceSwitcherOverride ?? spaceControl.map { sc in { sc.switchTo(spaceID: $0, plan: $1, shouldContinue: $2) } }
                    if gate(onSource: true), let switcher,
                       case .success = switcher(dest, SpaceControl.SwitchPlan(source: source, windows: [dest: [.window(id.raw)]], hopAllowed: false), { gate(onSource: false) }) {
                        landing.origin = source
                        landing.dest = dest
                    } else {
                        followFailed = true
                    }
                } else if let restore, system.currentSpaceID() == source,
                          !restoreFront(restore, on: source, authorization: authorization, gate: { gate() }) {
                    restoreNote = Copy.sentenceSeparator + L("The previous window was not brought forward.", "直前のウインドウは前面に戻していません。")
                }
                announceSent(identity: saved, app: window.app, from: source, to: dest)
                // The position note comes from the last observation after follow and restoration.
                let after = system.currentSpaceID()
                let followed = rule.follow && !followFailed && after == dest
                let moved = after != nil && after != source && !followed ? Copy.sentenceSeparator + L("The display then moved to \(spaceLabel(after!)).", "その後、表示が\(spaceLabel(after!))に移りました。") : ""
                let sent = L("Sent a new \(AppNames.localized(window.app)) window to \(spaceLabel(dest)).", "新しい\(AppNames.localized(window.app))のウインドウを\(spaceLabel(dest))へ送りました。")
                if followFailed {
                    var result = OperationResult.note(kind: "auto-route", spaceID: source, message: sent + Copy.sentenceSeparator + L("Switching to that Space could not be confirmed.", "その操作スペースへの切り替えは確認できませんでした。") + moved + looping, ok: false)
                    result.outcome = .partial
                    result.issued = 1
                    return result
                }
                return OperationResult.note(kind: "auto-route", spaceID: source, message: sent + (moved.isEmpty ? restoreNote : moved) + looping, ok: true)
            case .notIssued:
                return skipped("")
            case .unconfirmed, .elsewhere, .interrupted:
                // With an uncertain result, stop layout writes to that window and reconcile by membership (no resend, no drag).
                holdUncertainSend(saved, source: source, target: dest, targetUUID: resolved.uuid)
                var result = OperationResult.note(kind: "auto-route", spaceID: source, message: L("A new window may not have reached \(spaceLabel(dest)); LazySpace leaves it alone until its Space is known.", "新しいウインドウが\(spaceLabel(dest))に届いたか確かめられません。所属が分かるまで、このウインドウには書き込みません。") + looping, ok: false)
                result.outcome = .partial
                return result
            }
        }
        // No operation slot, or stopped after acceptance before the body: stays ready and tries again next tick within the deadline.
    }

    // MARK: - Dialog region (`place-dialogs-beside`)

    /// What a region operation gets: the next region, dialogs to place, the gate from decision time (checked before writing tiles, writing dialogs, and committing), and numbers for the record.
    struct RegionApply {
        var plan: DialogRegion?
        var placements: [ArrangeOperation.DialogPlacement]
        var gate: () -> Bool = { true }
        var pending: Int = 0
        /// Whether this operation switches edges (for the record).
        var switched = false
        /// Settings generation at decision time, and whether this operation builds a region (compared under the commit lock).
        var generation: UInt64 = 0
        var requireActive = false
        /// Whether the front window at decision time belonged to the same app as the placed dialog (for the record).
        var frontSharesProcess = false
    }

    /// Assessment of a region candidate (one window).
    enum RegionVerdict: Equatable {
        /// A dialog that may enter the region.
        case candidate
        /// A standard (resizable) window; not for the region.
        case standard
        /// Definitely not a target (rule, another Space, all Spaces, another display, not a regular app, and so on).
        case ineligible
        /// Could not be confirmed (unreadable, temporarily held). Neither added nor removed.
        case unknown
    }

    struct RegionObservation {
        var pid: Int32
        var processStart: Date?
        var verdict: RegionVerdict
        var at: Date
        /// First observation with another window in front and this frame unchanged (enters after 1 s of that).
        var awaySince: Date?
        /// Last frame seen and when it took that frame (to see whether size and position settled).
        var frame: CGRect? = nil
        var frameSince: Date? = nil
        /// Came to the front since LazySpace last wrote its position (the user brought it forward). The user can only move it after bringing it forward.
        /// Reset when a write is confirmed or a new size is accepted.
        var frontSinceWrite = false
    }

    /// Owner of a region record (pid and process start time). When the ID is reused by another owner, records do not carry over.
    struct RegionOwner: Equatable {
        var pid: Int32
        var start: Date
        /// Same owner; compared by pid alone when the start time is unknown.
        func same(pid: Int32, start: Date?) -> Bool {
            pid == self.pid && (start.map { abs($0.timeIntervalSince(self.start)) < 1 } ?? true)
        }
    }

    struct RegionLedgerEntry {
        var owner: RegionOwner
        var target: CGRect?
        var strikes: Int
        /// Saw a frame different from the written position once (counted if seen again). No rewrite while checking.
        var seen: CGRect?
    }

    static let regionEvidenceInterval: TimeInterval = 3
    static let regionEvidenceReadsPerTick = 4
    static let regionAwayDelay: TimeInterval = 1

    static let regionMaxStrikes = 3
    /// Time after switching the region's edge before it may switch again.
    static let regionSwitchInterval: TimeInterval = 30

    /// Whether the region is active (setting on and Stage Manager off). Call under lock.
    private func regionActiveLocked() -> Bool { config.placeDialogsBeside && !system.stageManagerOn }

    /// Planner options for arranging that Space (reserving the saved region on the right; no reservation when the region is inactive). Call under lock.
    private func plannerOptionsLocked(forSpaceKey key: String) -> PlannerOptions {
        var options = config.plannerOptions
        if regionActiveLocked(), let region = state.dialogRegions?[key] {
            let reservation = region.reservation(gap: options.gap, gapVertical: options.gapVertical)
            options.reservedRight = reservation.right
            options.reservedBottom = reservation.bottom
        }
        return options
    }

    /// Version for use outside the lock.
    func plannerOptions(forSpaceKey key: String) -> PlannerOptions {
        lock.lock(); defer { lock.unlock() }
        return plannerOptionsLocked(forSpaceKey: key)
    }

    /// Commits the region (nil or empty removes it). Call under lock.
    private func setRegionLocked(_ key: String, _ region: DialogRegion?) {
        // If no edge is remembered, remember the edge of the region saved now (including one loaded after a restart).
        if regionEdgeMemory[key] == nil, let existing = state.dialogRegions?[key] { regionEdgeMemory[key] = (existing.edge, .distantPast) }
        if let region, !region.members.isEmpty {
            // Remember an edge change (no switch right after a switch; a new region after the strip empties starts from this edge).
            let remembered = regionEdgeMemory[key]
            if remembered?.edge != region.edge {
                regionEdgeMemory[key] = (region.edge, remembered == nil ? .distantPast : routingClock())
            }
            if state.dialogRegions == nil { state.dialogRegions = [:] }
            state.dialogRegions?[key] = region
        } else {
            state.dialogRegions?[key] = nil
            if state.dialogRegions?.isEmpty == true { state.dialogRegions = nil }
        }
    }

    /// Records placement results in the ledger (whether or not the commit succeeds). Counts once only when read back and different from the plan, and notes the written position when confirmed.
    /// Whether the user moved it or the app put it back is told by whether the dialog came to the front (input in other apps does not forgive). Call under lock.
    private func noteRegionPlacementsLocked(_ outcomes: [WindowID: ArrangeOperation.PlacementOutcome], plan: DialogRegion?) {
        let now = routingClock()
        for (id, outcome) in outcomes {
            guard let member = plan?.members.first(where: { $0.id == id }) else { continue }
            let owner = RegionOwner(pid: member.pid, start: member.processStart)
            let entry = regionLedger[id].flatMap { $0.owner == owner ? $0 : nil }
            let previous = regionObservations[id]?.frontSinceWrite == true ? 0 : entry?.strikes ?? 0
            switch outcome {
            case .verified:
                regionLedger[id] = RegionLedgerEntry(owner: owner, target: member.frame, strikes: previous, seen: nil)
                regionObservations[id]?.frontSinceWrite = false
                regionRetryAfter[id] = nil
            case .mismatch:
                countRegionStrikeLocked(id, owner: owner, strikes: previous + 1)
            case .unreadable, .failed, .skipped:
                // Refused, unreadable, or stale plan: not counted; retried after an interval (from 5 s, doubling, up to 5 minutes).
                let failures = (regionRetryAfter[id].flatMap { $0.owner == owner ? $0.failures : nil } ?? 0) + 1
                regionRetryAfter[id] = (owner, now.addingTimeInterval(min(5 * pow(2, Double(failures - 1)), 300)), failures)
            }
        }
    }

    private func countRegionStrikeLocked(_ id: WindowID, owner: RegionOwner, strikes: Int) {
        if strikes >= Self.regionMaxStrikes {
            regionExcluded[id] = owner
            regionLedger[id] = nil
        } else {
            regionLedger[id] = RegionLedgerEntry(owner: owner, target: nil, strikes: strikes, seen: nil)
        }
    }

    /// Compares the ledger with the current observation: if the dialog came to the front after the write, the count is reset (the user moved it).
    /// Otherwise, seeing the same frame different from the written position twice in a row counts once (not while moving).
    private func reviewRegionLedger(_ current: Census) {
        lock.lock(); defer { lock.unlock() }
        for (id, entry) in regionLedger {
            guard let pid = current.windows[id], pid == entry.owner.pid else { continue }
            if regionObservations[id]?.frontSinceWrite == true { regionLedger[id] = RegionLedgerEntry(owner: entry.owner, target: nil, strikes: 0, seen: nil); continue }
            guard let target = entry.target, let bounds = current.bounds[id], !bounds.matches(target, tolerance: limits.tolerance) else {
                regionLedger[id]?.seen = nil
                continue
            }
            if let seen = entry.seen, seen.matches(bounds, tolerance: limits.tolerance) {
                countRegionStrikeLocked(id, owner: entry.owner, strikes: entry.strikes + 1)
            } else {
                regionLedger[id]?.seen = bounds
            }
        }
    }

    /// Whether a region operation may commit (settings generation, feature, the Space's automatic arrangement). Call under the commit lock.
    private func regionCommitAllowedLocked(_ region: RegionApply, key: String) -> Bool {
        configGeneration == region.generation && (!region.requireActive || regionActiveLocked()) && !state.pausedSpaces.contains(key)
    }

    /// Recounts away time from the front and the Space's observation (also on ticks with no region decision). Windows that came to the front, an unknown front, or invisible windows restart.
    /// Windows whose frame (size, position) changed restart too (windows opening or being reopened by their app do not enter before settling).
    /// Notes when a strip dialog comes to the front (the user brought it forward; later moves and size changes are forgiven).
    private func regionNoteFront(_ current: Census) {
        // Windows that have been in front (seen by the user), noted even on ticks with no region decision. Invisible windows are forgotten.
        if let front = current.frontWindow { regionSeenFront.insert(front) }
        regionSeenFront = regionSeenFront.filter { current.windows[$0] != nil }
        guard !regionObservations.isEmpty else { return }
        if let front = current.frontWindow, regionObservations[front] != nil {
            regionObservations[front]?.frontSinceWrite = true
        }
        let now = routingClock()
        for (id, observation) in regionObservations {
            if let bounds = current.bounds[id], observation.frame.map({ !$0.matches(bounds, tolerance: limits.tolerance) }) ?? true {
                regionObservations[id]?.frame = bounds
                regionObservations[id]?.frameSince = now
                regionObservations[id]?.awaySince = nil
            }
            guard observation.awaySince != nil else { continue }
            if current.frontWindow == nil || current.frontWindow == id || current.windows[id] == nil { regionObservations[id]?.awaySince = nil }
        }
    }

    /// Frame of the display showing the current Space and frames of all displays; nil when unknown (never falls back to the main display).
    private func regionDisplays() -> (all: [CGRect], current: CGRect)? {
        let screens = system.displayFrames()
        let workArea = system.currentWorkArea()
        if screens.count == 1 { return ([screens[0].frame], screens[0].frame) }
        let matches = screens.filter { $0.workArea == workArea }
        guard matches.count == 1 else { return nil }
        return (screens.map(\.frame), matches[0].frame)
    }

    /// Assessment of one window (a fresh read). Call outside the lock.
    private func regionVerdict(_ id: WindowID, pid: Int32, space: UInt64, frame: CGRect?) -> (verdict: RegionVerdict, start: Date?) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return (.ineligible, nil) }
        guard !system.processExited(pid), let regular = isRegularApp(pid) else { return (.unknown, nil) }
        guard regular else { return (.ineligible, nil) }
        guard let start = processStartTime(pid), let app = appBundleID(pid) else { return (.unknown, nil) }
        guard let membership = system.spacesOf(id), !membership.isEmpty else { return (.unknown, start) }
        guard membership == [space] else { return (.ineligible, start) }
        guard let evidence = system.dialogEvidence(pid: pid, window: id, deadline: Date().addingTimeInterval(Self.classificationReadBudget)) else { return (.unknown, start) }
        if evidence.isStandard { return (.standard, start) }
        guard evidence.isDialog else { return (.ineligible, start) }
        lock.lock(); let cfg = config; lock.unlock()
        if cfg.rule(for: app, title: evidence.title) != nil { return (.ineligible, start) }
        // Only windows mostly on the current display (undecided when unknown).
        guard let frame, let displays = regionDisplays() else { return (.unknown, start) }
        if displays.all.count > 1 {
            let area = frame.width * frame.height
            let here = frame.intersection(displays.current)
            guard area > 0, !here.isNull, here.width * here.height * 2 > area else { return (.ineligible, start) }
        }
        return (.candidate, start)
    }

    /// Region decision (at the end of a tick, after arrangement work). Operations queue.
    /// Before slow reads, notes the decision's authorization (input, cancellation, Space) and settings generation and passes them to the arrangement operation.
    private func regionStep(_ current: Census, space: UInt64) {
        let key = String(space)
        let decision = OperationAuthorization(system: system, control: control)
        // Review the ledger first (windows this observation removes from the strip are used by this decision).
        reviewRegionLedger(current)
        lock.lock()
        let cfg = config
        let generation = configGeneration
        let active = regionActiveLocked()
        let saved = state.dialogRegions?[key]
        let layout = state.layouts[key]
        let floating = Set(state.floating[key] ?? [])
        let held = routingExcluded
        let queued = !userQueue.isEmpty
        let zoomed = state.zoomed[key] != nil
        lock.unlock()
        guard let layout, !queued, !zoomed, decision.spaceID == space else { return }
        /// Gate from decision time: same settings generation, the feature active (when building a region), the Space's automatic arrangement on, and no mouse button held.
        let gate: (Bool) -> () -> Bool = { [self] requireActive in
            { [self] in
                lock.lock()
                let ok = configGeneration == generation && (!requireActive || regionActiveLocked()) && !state.pausedSpaces.contains(key)
                lock.unlock()
                return ok && !system.anyMouseButtonHeld
            }
        }
        // Forget records of closed windows (removed from the strip, ledger, intervals); a new window with the same ID is handled afresh.
        lock.lock(); let tracked = Set(regionExcluded.keys).union(regionLedger.keys).union(regionRetryAfter.keys); lock.unlock()
        let gone = tracked.filter { current.windows[$0] == nil }
        if !gone.isEmpty, let records = system.windowRecords(Set(gone)) {
            lock.lock()
            for id in gone where records[id] == nil { regionExcluded[id] = nil; regionLedger[id] = nil; regionRetryAfter[id] = nil }
            lock.unlock()
        }
        // The region is inactive: if a region is saved, drop the reservation and rearrange (tiles expand; dialogs stay where they are).
        guard active else {
            regionObservations.removeAll()
            if saved != nil {
                _ = arrange(source: "auto", kind: "auto-dialog-region", authorization: decision,
                            region: RegionApply(plan: nil, placements: [], gate: gate(false), generation: generation, requireActive: false))
            }
            return
        }
        guard !system.anyMouseButtonHeld else { return }
        let now = routingClock()
        let front = current.frontWindow
        let me = ProcessInfo.processInfo.processIdentifier
        let layoutIDs = Set(layout.windowIDs)
        let memberIDs = Set(saved?.members.map(\.id) ?? [])
        // Assess candidates and strip members: each window every 3 s (unreadable ones too), up to 4 at a time, rotating the read order.
        let windows = current.windows.filter { !layoutIDs.contains($0.key) && $0.value != me }.sorted { $0.key < $1.key }
        let rotated = windows.isEmpty ? [] : Array(windows[(regionReadCursor % windows.count)...] + windows[..<(regionReadCursor % windows.count)])
        regionReadCursor &+= 1
        var reads = 0
        for (id, pid) in rotated {
            var observation = regionObservations[id].flatMap { $0.pid == pid ? $0 : nil }
            if floating.contains(id) || held[id] != nil || observationBackoffWaiting(id) {
                // User-floated windows are definitely not targets; held sends and observation waits are temporary (unknown).
                let verdict: RegionVerdict = floating.contains(id) ? .ineligible : .unknown
                regionObservations[id] = RegionObservation(pid: pid, processStart: observation?.processStart, verdict: verdict, at: now, awaySince: nil,
                                                           frame: observation?.frame, frameSince: observation?.frameSince, frontSinceWrite: observation?.frontSinceWrite ?? false)
                continue
            }
            if (observation == nil || now.timeIntervalSince(observation!.at) >= Self.regionEvidenceInterval), reads < Self.regionEvidenceReadsPerTick {
                reads += 1
                let read = regionVerdict(id, pid: pid, space: space, frame: current.bounds[id])
                observation = RegionObservation(pid: pid, processStart: read.start, verdict: read.verdict, at: now, awaySince: observation?.awaySince,
                                                frame: observation?.frame, frameSince: observation?.frameSince, frontSinceWrite: observation?.frontSinceWrite ?? false)
                // Became resizable (strip members and waiting or oversized windows alike): stop excluding it from arrangement by its frame record.
                if read.verdict == .standard { notTileable[id] = nil }
            }
            guard var updated = observation else { continue }
            // When the frame changes, recount from when it settles.
            if let bounds = current.bounds[id], updated.frame.map({ !$0.matches(bounds, tolerance: limits.tolerance) }) ?? true {
                updated.frame = bounds
                updated.frameSince = now
                updated.awaySince = nil
            }
            // Count away time only while another window is known to be in front (every time, read or not).
            if updated.verdict == .candidate, let front, front != id {
                updated.awaySince = updated.awaySince ?? now
            } else {
                updated.awaySince = nil
            }
            regionObservations[id] = updated
        }
        let present = Set(windows.map(\.key))
        regionObservations = regionObservations.filter { present.contains($0.key) || memberIDs.contains($0.key) }
        let ruledOut = regionObservations.compactMapValues { $0.verdict == .standard || $0.verdict == .ineligible ? $0.pid : nil }
        // Seeing the ID used by another owner (another pid, or another process with the same pid) means its records do not carry over.
        // Then note excluded windows, intervals, and windows being checked (used for this decision's plan and the pre-write checks).
        lock.lock()
        func ownerChanged(_ id: WindowID, _ owner: RegionOwner) -> Bool {
            guard let pid = current.windows[id] else { return false }
            if pid != owner.pid { return true }
            guard let observation = regionObservations[id], observation.pid == pid else { return false }
            return !owner.same(pid: pid, start: observation.processStart)
        }
        for (id, owner) in regionExcluded where ownerChanged(id, owner) { regionExcluded[id] = nil }
        for (id, entry) in regionLedger where ownerChanged(id, entry.owner) { regionLedger[id] = nil }
        for (id, entry) in regionRetryAfter where ownerChanged(id, entry.owner) { regionRetryAfter[id] = nil }
        regionRuledOut = ruledOut
        let excluded = regionExcluded
        let retryAfter = regionRetryAfter
        let awaitingConfirmation = Set(regionLedger.filter { $0.value.seen != nil }.keys)
        lock.unlock()
        // Members that left or definitely stopped being targets. Unconfirmed members are not moved (they keep their place).
        var departed = Set<WindowID>()
        var pinned = Set<WindowID>()
        var sizes: [WindowID: CGSize] = [:]
        let missing = (saved?.members ?? []).filter { current.windows[$0.id] == nil }
        let records = missing.isEmpty ? [:] : system.windowRecords(Set(missing.map(\.id)))
        for member in saved?.members ?? [] {
            if excluded[member.id]?.same(pid: member.pid, start: member.processStart) == true || layoutIDs.contains(member.id) { departed.insert(member.id); continue }
            if let pid = current.windows[member.id] {
                let observation = regionObservations[member.id]
                if pid != member.pid || observation?.processStart.map({ abs($0.timeIntervalSince(member.processStart)) >= 1 }) == true { departed.insert(member.id); continue }
                switch observation?.verdict {
                case .standard?:
                    departed.insert(member.id)
                case .ineligible?: departed.insert(member.id)
                case .candidate?:
                    // When the app resizes it, keep its current place and size until it settles. Then replan with the new size if the user brought it forward,
                    // otherwise (a window the app reopens on its own) remove it from the strip.
                    guard let bounds = current.bounds[member.id] else { break }
                    if abs(bounds.width - member.size.width) <= limits.tolerance, abs(bounds.height - member.size.height) <= limits.tolerance {
                        sizes[member.id] = bounds.size
                    } else if let since = observation?.frameSince, now.timeIntervalSince(since) >= Self.regionAwayDelay {
                        // Bringing it forward covers one size change (reset once accepted).
                        let forgiven = observation?.frontSinceWrite == true || member.id == front
                        if forgiven {
                            sizes[member.id] = bounds.size
                            regionObservations[member.id]?.frontSinceWrite = false
                        } else {
                            lock.lock(); regionExcluded[member.id] = RegionOwner(pid: member.pid, start: member.processStart); regionLedger[member.id] = nil; lock.unlock()
                            departed.insert(member.id)
                        }
                    } else {
                        pinned.insert(member.id)
                    }
                case .unknown?, nil: pinned.insert(member.id)
                }
                if member.id == front { pinned.insert(member.id) }
            } else if system.processExited(member.pid) || (records.map { $0[member.id] == nil } ?? false) {
                departed.insert(member.id)
            } else if let membership = system.spacesOf(member.id), membership.count == 1, membership[0] != space {
                departed.insert(member.id)
            } else if readMinimizedQuick(member.id) == true {
                departed.insert(member.id)
            } else {
                pinned.insert(member.id)
            }
            // Members awaiting a rewrite (mid-interval, or being checked for being put back) are not moved by this decision.
            // Packing the others while only skipping the write would stack them onto a place not yet vacated, so the plan protects it.
            if !departed.contains(member.id),
               retryAfter[member.id].map({ now < $0.until && $0.owner.same(pid: member.pid, start: member.processStart) }) == true
                || awaitingConfirmation.contains(member.id) {
                pinned.insert(member.id)
            }
        }
        // Arrivals: candidates with another window in front for 1 s (5 s if never in front) and an unchanged frame, in arrival order.
        let arrivals: [DialogRegionPlanner.Arrival] = regionObservations
            .filter { id, o in
                o.verdict == .candidate && !memberIDs.contains(id) && !layoutIDs.contains(id)
                    && !(excluded[id]?.same(pid: o.pid, start: o.processStart) ?? false)
                    && retryAfter[id].map { now >= $0.until || !$0.owner.same(pid: o.pid, start: o.processStart) } ?? true
                    && o.awaySince.map { now.timeIntervalSince($0) >= (regionSeenFront.contains(id) ? Self.regionAwayDelay : regionUnseenDelay) } == true
                    && o.processStart != nil && current.bounds[id] != nil
            }
            .sorted { ($0.value.awaySince!, $0.key) < ($1.value.awaySince!, $1.key) }
            .map { DialogRegionPlanner.Arrival(id: $0.key, pid: $0.value.pid, processStart: $0.value.processStart!, size: current.bounds[$0.key]!.size) }
        if arrivals.isEmpty, departed.isEmpty, saved == nil { return }
        // Plan: the right edge of the tile area (work area minus outer gaps). The limit is half and the tile minimum width.
        let workArea = system.currentWorkArea()
        let base = cfg.plannerOptions
        let area = base.insetArea(workArea)
        // Tiles confirmed departed (closed, moved to another Space, minimized, or their app hidden) do not count toward the minimum width (even with the last tile gone, the strip may use up to half).
        // The test is the same as for removing managed windows; tiles merely invisible or fading still count.
        // The on-screen list includes every display's windows, so a listed tile confirmed on one other Space does not count either (moved to another display's Space).
        let absentTiles = layoutIDs.filter { current.windows[$0] == nil }
        var closedTiles = layoutIDs.subtracting(absentTiles).filter { id in
            guard let spaces = system.spacesOf(id) else { return false }
            return spaces.count == 1 && spaces[0] != space
        }
        if !absentTiles.isEmpty, let records = system.windowRecords(absentTiles) {
            closedTiles.formUnion(absentTiles.filter { id in
                let record = records[id]
                let spaces = record == nil ? nil : system.spacesOf(id)
                func verdict(_ minimized: Bool?) -> RemovalVerdict {
                    Self.removalVerdict(listAvailable: true, record: record, expectedPID: nil, spaces: spaces, currentSpace: space,
                                        minimized: minimized, appHidden: record.flatMap { system.appHidden(pid: $0.pid) }, heldSince: nil, now: now, hold: .infinity)
                }
                switch verdict(nil) {
                case .closed, .departed, .lost: return true
                case .held: return readMinimizedQuick(id) == true
                default: return false
                }
            })
        }
        let liveLayout = layout.removing(closedTiles)
        let constraints = knowledge.constraints(for: liveLayout.windowIDs, spaceID: space, workArea: workArea)
        let tileMinimum = Planner.minimumSize(of: liveLayout, constraints: constraints, options: base)
        lock.lock(); let remembered = regionEdgeMemory[key]; lock.unlock()
        let allowSwitch = remembered.map { now.timeIntervalSince($0.changedAt) >= Self.regionSwitchInterval } ?? true
        let result = DialogRegionPlanner.plan(DialogRegionPlanner.Input(previous: saved, arrivals: arrivals, departed: departed, sizes: sizes, pinned: pinned,
                                                                        area: area, gap: base.gap, gapVertical: base.gapVertical, tileMinimum: tileMinimum,
                                                                        allowBottom: true, rememberedEdge: remembered?.edge, allowSwitch: allowSwitch))
        let next = result.region
        // Members needing placement (movable, current position differs from the plan). Unmovable members (including those awaiting a rewrite) are protected by the plan.
        let tolerance = limits.tolerance
        let toPlace = (next?.members ?? []).filter { member in
            !pinned.contains(member.id) && !(current.bounds[member.id].map { $0.matches(member.frame, tolerance: tolerance) } ?? false)
        }
        guard next != saved || !toPlace.isEmpty else { return }
        let placements = toPlace.map { member in
            ArrangeOperation.DialogPlacement(id: member.id, origin: member.origin, size: member.size) { [self] in
                regionPlacementStillValid(member, space: space, workArea: workArea, insets: area, generation: generation)
            }
        }
        _ = arrange(source: "auto", kind: "auto-dialog-region", authorization: decision,
                    region: RegionApply(plan: next, placements: placements, gate: gate(true), pending: result.pending.count,
                                        switched: result.switched || (saved == nil && next != nil && remembered != nil && remembered?.edge != next?.edge),
                                        generation: generation, requireActive: true,
                                        frontSharesProcess: current.frontmostPID.map { pid in toPlace.contains { $0.pid == pid } } ?? false))
    }

    /// Check right before writing: slow reads (identity, kind) first, then a fresh observation for front and size, and finally the cheap checks (settings, work area, Space, button).
    private func regionPlacementStillValid(_ member: DialogRegion.Member, space: UInt64, workArea: CGRect, insets: CGRect, generation: UInt64) -> Bool {
        let before = takeCensus(space)
        guard let pid = before.windows[member.id], pid == member.pid else { return false }
        let read = regionVerdict(member.id, pid: pid, space: space, frame: before.bounds[member.id])
        guard read.verdict == .candidate, read.start.map({ abs($0.timeIntervalSince(member.processStart)) < 1 }) == true else { return false }
        // It may have come forward or been resized during the slow reads: observe again.
        let census = takeCensus(space)
        guard census.windows[member.id] == member.pid,
              let bounds = census.bounds[member.id], abs(bounds.width - member.size.width) <= limits.tolerance, abs(bounds.height - member.size.height) <= limits.tolerance,
              let front = census.frontWindow, front != member.id,
              system.spacesOf(member.id) == [space], regionOnCurrentDisplay(bounds) == true else { return false }
        lock.lock(); let cfg = config; let unchanged = configGeneration == generation; let active = regionActiveLocked(); lock.unlock()
        return unchanged && active && system.currentWorkArea() == workArea && cfg.plannerOptions.insetArea(workArea) == insets
            && !system.anyMouseButtonHeld && system.currentSpaceID() == space
    }

    /// Whether most of the window is on the current display (always, with one display); nil when unknown.
    private func regionOnCurrentDisplay(_ frame: CGRect) -> Bool? {
        guard let displays = regionDisplays() else { return nil }
        guard displays.all.count > 1 else { return true }
        let area = frame.width * frame.height
        let here = frame.intersection(displays.current)
        guard area > 0, !here.isNull else { return false }
        return here.width * here.height * 2 > area
    }

    /// Strip members usable for focus and the border (observed frames): the feature is active, the member is in the saved region,
    /// visible in the current observation with the same pid, with membership exactly the current Space, the current process launch time equal to the saved one,
    /// and not assessed standard or ineligible last time. Left out if any of this cannot be confirmed. Callable from outside the operations queue.
    func regionLiveMembers(_ census: Census, space: UInt64?, only: Set<WindowID>? = nil) -> [WindowID: CGRect] {
        regionLiveMemberIdentities(census, space: space, only: only).mapValues(\.frame)
    }

    /// Same test as `regionLiveMembers`, also returning the saved owner (pid).
    func regionLiveMemberIdentities(_ census: Census, space: UInt64?, only: Set<WindowID>? = nil) -> [WindowID: (frame: CGRect, pid: Int32)] {
        guard let space else { return [:] }
        lock.lock()
        let members = regionActiveLocked() ? (state.dialogRegions?[String(space)]?.members ?? []) : []
        let ruledOut = regionRuledOut
        lock.unlock()
        var live: [WindowID: (frame: CGRect, pid: Int32)] = [:]
        for member in members where only?.contains(member.id) ?? true {
            guard census.windows[member.id] == member.pid, let frame = census.bounds[member.id], ruledOut[member.id] != member.pid,
                  system.spacesOf(member.id) == [space],
                  let start = processStartTime(member.pid), abs(start.timeIntervalSince(member.processStart)) < 1 else { continue }
            live[member.id] = (frame, member.pid)
        }
        return live
    }

    /// Whether the window is waiting for an observation retry (read under lock).
    private func observationBackoffWaiting(_ id: WindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return observationBackoff.isWaiting(id, now: backoffClock())
    }

    /// Whether minimized (time-limited); nil when unreadable.
    private func readMinimizedQuick(_ id: WindowID) -> Bool? {
        system.readMinimized(id, deadline: Date().addingTimeInterval(Self.classificationReadBudget))
    }

    /// The region line of `lazyspace status`. Call under lock.
    private func dialogRegionStatusLocked(spaceKey: String) -> String {
        guard config.placeDialogsBeside else { return L("Off", "オフ") }
        if system.stageManagerOn { return L("On, not in use while \(MacItem.stageManager) is on", "オン（\(MacItem.stageManager)の使用中は使いません）") }
        guard let region = state.dialogRegions?[spaceKey], !region.members.isEmpty else { return L("On", "オン") }
        let width = Int(region.thickness.rounded())
        let count = region.members.count
        let windows = count == 1 ? "1 window" : "\(count) windows"
        switch region.edge {
        case .right: return L("On, \(windows) at the right edge (width \(width) pt)", "オン、右端に\(count)つ（幅\(width)pt）")
        case .bottom: return L("On, \(windows) at the bottom edge (height \(width) pt)", "オン、下端に\(count)つ（高さ\(width)pt）")
        }
    }

    /// Confirmed sends only: the hook (once per window). Titles are never passed or recorded.
    private func announceSent(identity: WindowIdentity, app: String, from source: UInt64, to dest: UInt64) {
        lock.lock(); let hook = config.execOnWindowSent; lock.unlock()
        let env = Self.windowSentEnvironment(window: identity.window, app: app, from: source, to: dest, snapshot: spaceListing()?.spaceSnapshot())
        windowSentObserver?(env)
        if !hook.isEmpty { HookRunner.run(hook, environment: env) { [weak self] in self?.noteHookProblem($0) } }
    }

    /// Desktops are numbered on their own display; the display is its position in `list-spaces` (1 with one display). Unknown values are empty.
    static func windowSentEnvironment(window: WindowID, app: String, from source: UInt64, to dest: UInt64, snapshot: SpaceSnapshot?) -> [String: String] {
        func number(_ id: UInt64) -> String { snapshot?.holder(of: id)?.desktops.firstIndex(of: id).map { String($0 + 1) } ?? "" }
        func display(_ id: UInt64) -> String {
            guard let snapshot else { return "" }
            if snapshot.groups.isEmpty { return snapshot.order.contains(id) ? "1" : "" }
            return snapshot.groups.first { $0.records.contains { $0.id == id } }.map { String($0.index) } ?? ""
        }
        return ["LAZYSPACE_WINDOW_ID": String(window.raw), "LAZYSPACE_APP": app,
                "LAZYSPACE_FROM_SPACE": number(source), "LAZYSPACE_FROM_SPACE_ID": String(source), "LAZYSPACE_FROM_DISPLAY": display(source),
                "LAZYSPACE_TO_SPACE": number(dest), "LAZYSPACE_TO_SPACE_ID": String(dest), "LAZYSPACE_TO_DISPLAY": display(dest)]
    }

    /// For tests: a rule window's phase. Call from outside the operations queue.
    func testingRouterPhase(_ id: WindowID) -> WindowRouter.Phase? {
        operationsQueue.sync { router.phase(of: id) }
    }

    /// For tests: windows kept out of the layout (read under lock, so readable even while the operations queue is blocked).
    func testingExcludedNow() -> [WindowID: String] {
        lock.lock(); defer { lock.unlock() }
        return routingExcluded
    }

    /// For tests: reconciling sends and pending arrivals. Call from outside the operations queue.
    func testingRouting() -> (holds: [WindowID: SendHold], pending: [String: [WindowIdentity: UInt64]], excluded: [WindowID: String]) {
        operationsQueue.sync {
            lock.lock(); let excluded = routingExcluded; lock.unlock()
            return (sendHolds, pendingArrivals, excluded)
        }
    }

    func expectArrival(of window: WindowID, on spaceID: UInt64) {
        lock.lock(); let generation = control.cancellationGeneration; lock.unlock()
        expectedArrival = (window, spaceID, generation, Date().addingTimeInterval(3))
    }

    /// While a window carried by move-to-space is visible in the current Space's observation, it is inserted without the arrival dwell.
    /// Discarded on expiry, a stop generation change, or another Space. Read on the operations queue.
    private func arrivalExpected(in current: Census) -> Bool {
        if pendingArrivalPresent(in: current) { return true }
        guard let expected = expectedArrival else { return false }
        lock.lock()
        let generation = control.cancellationGeneration
        let placed = current.spaceID.map { key in
            let key = String(key)
            return (state.layouts[key]?.windowIDs.contains(expected.window) ?? false) || (state.floating[key] ?? []).contains(expected.window)
        } ?? false
        lock.unlock()
        // A window already placed or floated has no reason to skip the wait anymore.
        guard expected.spaceID == current.spaceID, expected.generation == generation, expected.until > Date(), !placed else {
            expectedArrival = nil
            return false
        }
        return current.windows[expected.window] != nil
    }

    /// Schedules the next tick for the longer remaining of the arrival dwell and the post-drag quiet time,
    /// so windows outside the layout are inserted at the deadline instead of on the regular interval.
    private func scheduleSettleDeadline(settledOnSpace: Bool, quiet: Bool, sinceInput: TimeInterval) {
        var wait: TimeInterval = 0
        if !settledOnSpace { wait = max(wait, arrivalDwell - Date().timeIntervalSince(spaceArrivedAt)) }
        if !quiet { wait = max(wait, quietInterval - sinceInput) }
        if wait > 0 { scheduleNextTick(after: max(wait, fastTickInterval)) }
    }

    private func unchangedSinceNoopReconcile(_ current: Census, spaceKey: String, ids: [WindowID]) -> Bool {
        lock.lock(); let seen = noopReconcileBounds[spaceKey]; lock.unlock()
        guard let seen, !ids.isEmpty else { return false }
        return ids.allSatisfy { id in
            guard let now = current.bounds[id], let then = seen[id] else { return false }
            return now.matches(then, tolerance: limits.tolerance)
        }
    }

    /// Tracked windows not visible on the current Space; only these need an existence check against the full window list.
    static func windowsNeedingListCheck(tracked: Set<WindowID>, visible: Set<WindowID>) -> Set<WindowID> {
        tracked.subtracting(visible)
    }

    /// Stopped by the user's input or a refusing write gate (a held button) before any frame was written. Callers also require the
    /// cancellation generation captured at acceptance, which rules out Pause, a Space turned off, and cancellations.
    static func stoppedBeforeWriting(_ result: OperationResult) -> Bool {
        result.outcome != .complete && result.issued == 0 && (result.stopReason == .userInput || result.stopReason == .cancelled)
    }

    /// Counted when automatic integration failed at the same frame because of the window's nature.
    /// Interruptions by user action or changed circumstances do not count toward the retry limit.
    static func countsAsIntegrateFailure(kind: String, outcome: Outcome, stopReason: StopReason?) -> Bool {
        guard kind == "auto-integrate", outcome != .complete, outcome != .interrupted else { return false }
        switch stopReason {
        case .paused, .userInput, .spaceChanged, .permissionLost, .targetsChanged, .cancelled:
            return false
        case .appUnresponsive:
            return true
        case nil:
            return outcome == .partial || outcome == .notPossible || outcome == .nothingToDo
        }
    }

    /// A state seen briefly mid Space change: membership not confirmed as the current Space, or the kind undecidable.
    static func observationIsTransient(_ window: ObservedWindow) -> Bool {
        switch window.membership {
        case .unknown, .other: return true
        case .current, .allSpaces, .otherDisplay: return window.kind == .unknownRole
        }
    }

    /// Splits windows requested for automatic integration into those whose nature the operation's observation confirmed (counted as failures)
    /// and those missing from observation or looking transient (retried after an interval).
    /// An app that did not return its window list is no failure of the windows being added: one whose own app did not answer is retried after an interval,
    /// and one that was read waited for another app (the Space's tries cover it) unless writes were issued and did not apply in time, which still counts,
    /// since each wait stalls operations.
    static func integrateObservation(adding: Set<WindowID>, result: OperationResult) -> (settled: [WindowID], transient: [WindowID]) {
        let targeted = Set(result.targets.map(\.id))
        if result.stopReason == .appUnresponsive {
            guard !result.unobservedApps.isEmpty else { return (adding.sorted(), []) }
            let read = adding.sorted().filter { targeted.contains($0) }
            return (result.issued > 0 ? read : [], adding.sorted().filter { !targeted.contains($0) })
        }
        var excluded: [WindowID: ObservedWindow] = [:]
        for exclusion in result.excluded { excluded[exclusion.window.id] = exclusion.window }
        var settled: [WindowID] = []
        var transient: [WindowID] = []
        for id in adding.sorted() {
            if targeted.contains(id) {
                settled.append(id)
            } else if let window = excluded[id], !observationIsTransient(window) {
                settled.append(id)
            } else {
                transient.append(id)
            }
        }
        return (settled, transient)
    }

    /// Call with `lock` held.
    private func recordIntegrateFailure(_ ids: [WindowID], bounds: [WindowID: CGRect]) {
        integrateLedger.record(ids, bounds: bounds, inputCount: system.inputActivityCount, tolerance: limits.tolerance)
    }

    /// Unplaced standard windows. An explicit "integrate one" picks from the current screen, not the saved waiting list.
    private func unplacedStandardIDs() -> [WindowID] {
        let spaceKey = system.currentSpaceID().map(String.init) ?? "-"
        lock.lock()
        let layoutIDs = Set(state.layouts[spaceKey]?.windowIDs ?? [])
        let floating = Set(state.floating[spaceKey] ?? [])
        let cfg = config
        lock.unlock()
        let order = TargetSelection.inspect(system.snapshot(), appRule: { cfg.tilingExclusionReason(bundleID: $0.app, title: $0.title) }).targets.map(\.id)
        return order.filter { !layoutIDs.contains($0) && !floating.contains($0) }
    }

    /// Reference for inserting an arriving window beside: the currently focused managed window.
    private func focusedManaged(_ focused: WindowID?, in layout: Layout, spaceKey: String) -> WindowID? {
        guard let focused, layout.windowIDs.contains(focused) else { return nil }
        lock.lock(); let floating = state.floating[spaceKey] ?? []; lock.unlock()
        return floating.contains(focused) ? nil : focused
    }

    /// In one observation, a window of the same app and frame being replaced is a tab switch, so the leaf ID is swapped.
    private func adoptTabSwitch(previous: Census, current: Census, spaceKey: String) -> Bool {
        let added = current.windows.keys.filter { previous.windows[$0] == nil }
        let removed = previous.windows.keys.filter { current.windows[$0] == nil }
        guard added.count == 1, removed.count == 1, let newID = added.first, let oldID = removed.first,
              current.windows[newID] == previous.windows[oldID],
              let newFrame = current.bounds[newID], let oldFrame = previous.bounds[oldID],
              newFrame.matches(oldFrame, tolerance: limits.tolerance) else { return false }
        lock.lock()
        guard var layout = state.layouts[spaceKey], layout.windowIDs.contains(oldID) else { lock.unlock(); return false }
        layout = layout.replacing(oldID, with: newID)
        state.layouts[spaceKey] = layout
        if var plan = lastPlans[spaceKey], let frame = plan.removeValue(forKey: oldID) {
            plan[newID] = frame
            lastPlans[spaceKey] = plan
        }
        store.save(state)
        lock.unlock()
        return true
    }

    /// When a managed Space has a single tile, rewrites an actual frame that differs from the plan.
    /// If the plan stopped at a cap not yet tested, requests the full area once without the cap.
    @discardableResult
    func fillSoloIfNeeded(current: Census, spaceKey: String, authorization: OperationAuthorization? = nil) -> Bool {
        guard !autoPaused(spaceKey), system.currentSpaceID().map(String.init) == spaceKey else { return false }
        lock.lock()
        let layout = state.layouts[spaceKey]
        let zoomed = state.zoomed[spaceKey]
        let floating = state.floating[spaceKey] ?? []
        lock.unlock()
        guard zoomed == nil, let layout, layout.windowIDs.count == 1,
              let id = layout.windowIDs.first, !floating.contains(id),
              let frame = current.bounds[id],
              !unchangedSinceNoopReconcile(current, spaceKey: spaceKey, ids: [id]) else { return false }
        let workArea = system.currentWorkArea()
        let options = plannerOptions(forSpaceKey: spaceKey)
        let tiles = options.tilingArea(workArea).integralInset
        var recorded = soloFillAttempts[spaceKey]
        if let known = recorded, known.id != id || known.tiles != tiles {
            soloFillAttempts[spaceKey] = nil
            recorded = nil
        }
        let count = recorded?.count ?? 0
        let constraints = knowledge.constraints(for: [id], spaceID: current.spaceID, workArea: workArea)
        let caps = knowledge.maximums(for: [id], workArea: workArea)
        guard case .fits(let plan) = Planner.fit(
            layout, in: workArea, constraints: constraints, options: options, maximums: caps
        ), let planned = plan.rects[id] else { return false }
        if frame.matches(planned, tolerance: limits.tolerance) {
            guard let cap = caps[id], cap != .zero, count < 3 else { return false }
            let probe = SoloProbe(cap: cap, tiles: tiles)
            guard soloProbed[id] != probe else { return false }
            let reserved = SoloFillAttempt(id: id, tiles: tiles, count: count + 1)
            let previousAttempt = recorded
            let previousProbe = soloProbed[id]
            let generation = control.cancellationGeneration
            // Reserved before starting: in tests the completion can run before `arrange` returns.
            soloFillAttempts[spaceKey] = reserved
            soloProbed[id] = probe
            // A probe stopped before writing by input or a held button is not spent.
            let refund = { [weak self] in
                guard let self else { return }
                if soloFillAttempts[spaceKey] == reserved { soloFillAttempts[spaceKey] = previousAttempt }
                if soloProbed[id] == probe { soloProbed[id] = previousProbe }
            }
            guard case .started = arrange(source: "auto", kind: "auto-reconcile", authorization: authorization, probeMaximums: true, completion: { [weak self] result in
                guard let self, Self.stoppedBeforeWriting(result), control.cancellationGeneration == generation else { return }
                refund()
            }) else {
                refund()
                return false
            }
            return true
        }
        guard count < 3 else { return false }
        soloFillAttempts[spaceKey] = SoloFillAttempt(id: id, tiles: tiles, count: count + 1)
        guard case .started = arrange(source: "auto", kind: "auto-reconcile", authorization: authorization) else {
            soloFillAttempts[spaceKey] = SoloFillAttempt(id: id, tiles: tiles, count: count)
            return false
        }
        return true
    }

    /// Whether any window present in both the previous and current observations changed frame. Additions and removals are handled separately.
    static func anyWindowMoved(from before: [WindowID: CGRect], to now: [WindowID: CGRect], tolerance: Double) -> Bool {
        now.contains { id, rect in before[id].map { !rect.matches($0, tolerance: tolerance) } ?? false }
    }

    /// Whether any managed, non-floating window moved from the last plan; true without a plan (unknown).
    func managedWindowsMoved(_ current: Census, spaceKey: String, managed: Set<WindowID>) -> Bool {
        lock.lock()
        let plan = lastPlans[spaceKey] ?? [:]
        let floating = Set(state.floating[spaceKey] ?? [])
        lock.unlock()
        guard !plan.isEmpty else { return true }
        return managed.contains { id in
            guard !floating.contains(id), let planned = plan[id], let actual = current.bounds[id] else { return false }
            return !actual.matches(planned, tolerance: limits.tolerance)
        }
    }

    /// While input is quiet and managed windows' actual frames differ from the plan, rewrites them from the tree within caps.
    func reconcileDrift(current: Census, spaceKey: String, layout: Layout, managed: Set<WindowID>, authorization: OperationAuthorization? = nil) -> Bool {
        lock.lock()
        let plan = lastPlans[spaceKey] ?? [:]
        lock.unlock()
        guard !plan.isEmpty else { return false }
        let drifted = managed.contains { id in
            guard let planned = plan[id], let actual = current.bounds[id] else { return false }
            return !actual.matches(planned, tolerance: limits.tolerance)
        }
        if !drifted {
            if reflowAccordion(current: current, spaceKey: spaceKey, layout: layout, authorization: authorization) { return true }
            reconcileAttempts[spaceKey] = 0
            return false
        }
        // If the last correction wrote nothing and frames have not changed since, this is an observation mismatch, not window drift.
        if unchangedSinceNoopReconcile(current, spaceKey: spaceKey, ids: layout.windowIDs) { return false }
        // Do not rewrite mid closing / opening animation or while the app moves the window itself. Querying a closing window through AX
        // can block for hundreds of ms, delaying the refill after it closes. Decide on the next observation after frames stop.
        let moving = managed.contains { id in
            guard let before = driftReference[id], let now = current.bounds[id] else { return false }
            return !now.matches(before, tolerance: limits.tolerance)
        }
        if moving { scheduleNextTick(after: fastTickInterval); return false }
        let attempts = reconcileAttempts[spaceKey] ?? 0
        guard attempts < 3 else { return false }
        reconcileAttempts[spaceKey] = attempts + 1
        if case .started = arrange(source: "auto", kind: "auto-reconcile", authorization: authorization) { return true }
        return false
    }

    /// The focused window changing moves the accordion strips too; rewrite if they differ from the plan.
    private func reflowAccordion(current: Census, spaceKey: String, layout: Layout, authorization: OperationAuthorization?) -> Bool {
        guard let front = current.frontWindow, layout.containsAccordion(around: front) else { return false }
        let workArea = system.currentWorkArea()
        let constraints = knowledge.constraints(for: layout.windowIDs, spaceID: current.spaceID, workArea: workArea)
        let maximums = knowledge.maximums(for: layout.windowIDs, workArea: workArea)
        guard case .fits(let desired) = Planner.fit(layout, in: workArea, constraints: constraints, options: plannerOptions(forSpaceKey: spaceKey), maximums: maximums, focused: front) else { return false }
        lock.lock()
        let plan = lastPlans[spaceKey] ?? [:]
        lock.unlock()
        let differs = layout.windowIDs.contains { id in
            guard let want = desired.rects[id], let had = plan[id] else { return false }
            return !want.matches(had, tolerance: limits.tolerance)
        }
        let attempts = reconcileAttempts[spaceKey] ?? 0
        guard differs, attempts < 3 else { return false }
        reconcileAttempts[spaceKey] = attempts + 1
        if case .started = arrange(source: "auto", kind: "auto-reconcile", authorization: authorization) { return true }
        return false
    }

    /// For tests: whether a mouse edit is still waiting to be adopted.
    func testingMouseEditPending() -> Bool { operationsQueue.sync { pendingMouseEdit } }

    /// For tests: the plan mouse edits and drift compare against.
    func testingPlan(spaceKey: String) -> [WindowID: CGRect]? { operationsQueue.sync { lock.lock(); defer { lock.unlock() }; return lastPlans[spaceKey] } }

    private func clearPendingMouseEdit() {
        pendingMouseEdit = false
        earlyMouseEdit = false
        mouseEditSample = nil
        earlyMouseEditDeclined = false
        mouseEditSpace = nil
    }

    enum MouseEditOutcome { case applied, none, interrupted }

    /// The early path of a drag. Takes a sample on the first read after the release and looks again after the 50 ms floor; adopts on an equal read
    /// when every changed window is a resize or a swap and every managed app has an observer that reported no geometry change since the sample.
    /// Otherwise the quiet path decides as before. Returns true when an edit was adopted.
    private func adoptStillMouseEdit(current: Census, spaceKey: String, layout: Layout, managed: Set<WindowID>, authorization: OperationAuthorization) -> Bool {
        // Every managed window must be on screen: a missing one is a removal still to be assessed.
        guard managed.allSatisfy({ current.windows[$0] != nil }) else { return false }
        let bounds = current.bounds.filter { managed.contains($0.key) }
        let pids = Set(managed.compactMap { current.windows[$0] })
        if let sample = mouseEditSample, sample.bounds == bounds, let still = geometryQuiet(pids, sample.at) {
            if !still {
                mouseEditSample = (bounds, Date())
                earlyMouseEditDeclined = false
                scheduleNextTick(after: 0.05)
                return false
            }
            if earlyMouseEditDeclined { return false }
            let edits = classifyManualEdits(current: current, spaceKey: spaceKey, layout: layout, managed: managed)
            guard let first = edits.first, edits.allSatisfy({ if case .float = $0.edit { return false } else { return true } }) else {
                earlyMouseEditDeclined = true
                return false
            }
            switch applyManualEdit(first.edit, layout: layout, spaceKey: spaceKey, authorization: authorization) {
            case .applied: clearPendingMouseEdit(); return true
            case .none: earlyMouseEditDeclined = true; return false
            // Input or a change arrived during this observation: the quiet path decides later.
            case .interrupted: earlyMouseEdit = false; return false
            }
        }
        // First read after the release, or the windows still move: sample again after the 50 ms floor (only when the evidence is available at all).
        mouseEditSample = (bounds, Date())
        earlyMouseEditDeclined = false
        if geometryQuiet(pids, .distantFuture) != nil { scheduleNextTick(after: 0.05) }
        return false
    }

    /// Mouse edits of every managed window whose frame differs from the last plan, in window order. None while zoomed (size differences are not intent).
    private func classifyManualEdits(current: Census, spaceKey: String, layout: Layout, managed: Set<WindowID>) -> [(id: WindowID, edit: ManualEdit)] {
        lock.lock()
        let plan = lastPlans[spaceKey] ?? [:]
        let floating = Set(state.floating[spaceKey] ?? [])
        let zoomed = state.zoomed[spaceKey]
        lock.unlock()
        guard zoomed == nil else { return [] }
        return plan.sorted(by: { $0.key < $1.key }).compactMap { id, planned in
            guard managed.contains(id), !floating.contains(id), let actual = current.bounds[id],
                  let edit = ManualEdit.detect(id: id, planned: planned, actual: actual, layout: layout, plannedRects: plan, tolerance: limits.tolerance) else { return nil }
            return (id, edit)
        }
    }

    /// Adopts the first mouse edit (for tests and the quiet path); true when one was applied.
    func detectManualEdit(current: Census, spaceKey: String, layout: Layout, managed: Set<WindowID>, authorization: OperationAuthorization? = nil) -> Bool {
        applyFirstManualEdit(current: current, spaceKey: spaceKey, layout: layout, managed: managed, authorization: authorization) == .applied
    }

    private func applyFirstManualEdit(current: Census, spaceKey: String, layout: Layout, managed: Set<WindowID>, authorization: OperationAuthorization?) -> MouseEditOutcome {
        guard let first = classifyManualEdits(current: current, spaceKey: spaceKey, layout: layout, managed: managed).first else { return .none }
        return applyManualEdit(first.edit, layout: layout, spaceKey: spaceKey, authorization: authorization)
    }

    /// Starts the arrangement for a mouse edit. The edited layout is committed (with undo history) only when that arrangement completes.
    /// Nothing starts once input, Pause, cancellation, a Space change, or automatic arrangement becoming unavailable for this Space invalidated the observation.
    private func applyManualEdit(_ edit: ManualEdit, layout: Layout, spaceKey: String, authorization: OperationAuthorization?) -> MouseEditOutcome {
        if let authorization {
            guard authorization.interruptionReason(system: system, control: control) == nil,
                  system.currentSpaceID().map(String.init) == spaceKey, autoGate().allowed else { return .interrupted }
            lock.lock(); let off = state.pausedSpaces.contains(spaceKey); lock.unlock()
            if off { return .interrupted }
        }
        // An arrangement stopped by the user's input or a held button leaves the drag for the quiet path. Not after a Pause, a Space turned off, or a cancellation
        // during it (the generation changed, even if re-enabled before it finished), and not after failures such as an app refusing the frame
        // (retrying those would repeat on every quiet tick).
        let generation = control.cancellationGeneration
        let retry: (OperationResult) -> Void = { [weak self] result in
            guard let self, result.outcome != .complete, result.stopReason == .userInput || result.stopReason == .cancelled,
                  control.cancellationGeneration == generation else { return }
            rearmMouseEdit(spaceKey: spaceKey)
        }
        let accepted: Accept
        switch edit {
        case .resize(let w, let deltas):
            var edited = layout
            for (axis, delta, edge) in deltas { if let l = LayoutEdit.resize(w, axis: axis, by: delta, in: edited, edge: edge) { edited = l } }
            if edited == layout { return .none }
            accepted = arrange(source: "mouse", kind: "mouse-resize", layoutOverride: edited, ignoreZoom: true, authorization: authorization, completion: retry)
        case .dropOnto(let w, let target):
            accepted = arrange(source: "mouse", kind: "mouse-swap", layoutOverride: LayoutEdit.swap(w, target, in: layout), ignoreZoom: true,
                               authorization: authorization, completion: retry)
        case .float:
            // A window dropped on empty space is not floated but returned to its planned frame; floating is only by explicit key.
            // It goes through the operation path with stop, input, and readback checks instead of a direct write.
            accepted = arrange(source: "mouse", kind: "mouse-return", ignoreZoom: true, authorization: authorization, completion: retry)
        }
        if case .started = accepted { return .applied }
        return .interrupted
    }

    /// Operations queue. Puts a drag whose arrangement did not complete back on the quiet path, if it still belongs to the current Space and nothing paused it.
    /// A redistribution stopped before writing is owed again as the pending departed refit; the next quiet tick recomputes the departed
    /// windows from a fresh census, so a window that came back stays. Focus-after-close is not repeated. Operations queue.
    private func rearmDepartedRefit(after result: OperationResult, spaceKey: String, generation: UInt64) {
        let step = unansweredStep(after: result, spaceKey: spaceKey)
        lock.lock(); let current = control.cancellationGeneration; let off = control.paused || state.pausedSpaces.contains(spaceKey); lock.unlock()
        let retry: TimeInterval? = if case .retry(let delay) = step { delay } else { nil }
        guard Self.stoppedBeforeWriting(result) || retry != nil, current == generation, !off,
              system.currentSpaceID().map(String.init) == spaceKey, pendingDepartedRefit == nil else { return }
        pendingDepartedRefit = (spaceKey, generation)
        scheduleNextTick(after: max(retry ?? 0, fastTickInterval))
    }

    private enum UnansweredStep: Equatable {
        /// Handled as any result (the Space's wait is over, unless input stopped the try before it wrote).
        case handled
        /// Read nothing to write (an app did not answer, or the window list could not be read): try again after the delay (the last try reclaims).
        case retry(after: TimeInterval)
    }

    /// Notes how a redistribution, a display or launch fit, or an integration that waited ended. One that wrote nothing because an app did not answer,
    /// or because nothing could be read, is tried again after 1, 2, then 4 s; then once more with `.reclaim`, which commits the windows that answered
    /// (the app's windows, left where they are, are remembered as departures). Whatever the reclaim's result, the wait is over; input that stopped a try
    /// before it wrote keeps the count.
    private func unansweredStep(after result: OperationResult, spaceKey: String) -> UnansweredStep {
        if Self.stoppedBeforeWriting(result) { return .handled }
        let attempts = unansweredEntry(spaceKey)?.attempts ?? 0
        let readNothing = result.issued == 0 && (result.stopReason == .appUnresponsive || (result.outcome == .nothingToDo && result.stopReason == nil))
        guard readNothing, attempts <= Self.unansweredRetryDelays.count else { unansweredFits[spaceKey] = nil; return .handled }
        let delay = attempts < Self.unansweredRetryDelays.count ? Self.unansweredRetryDelays[attempts] : 0
        unansweredFits[spaceKey] = (attempts + 1, fitRetryClock().addingTimeInterval(delay))
        return .retry(after: delay)
    }
    static let unansweredRetryDelays: [TimeInterval] = [1, 2, 4]
    /// A wait whose next try has not come for this long is over (the next silence starts with the full delay).
    static let unansweredWaitExpiry: TimeInterval = 10

    /// The Space's current run of tries, or nil when there is none or it is over.
    private func unansweredEntry(_ spaceKey: String) -> (attempts: Int, notBefore: Date)? {
        guard let entry = unansweredFits[spaceKey], fitRetryClock() <= entry.notBefore.addingTimeInterval(Self.unansweredWaitExpiry) else { return nil }
        return entry
    }

    /// How a fit or an integration of the Space treats an app that does not answer: wait while the Space's tries last, then reclaim.
    private func unansweredPolicy(_ spaceKey: String) -> ArrangeOperation.UnansweredPolicy {
        (unansweredEntry(spaceKey)?.attempts ?? 0) > Self.unansweredRetryDelays.count ? .reclaim : .wait
    }

    /// Whether an automatic fit of the Space may run now (not waiting out the delay after an app did not answer).
    private func unansweredFitDue(_ spaceKey: String) -> Bool {
        unansweredEntry(spaceKey).map { fitRetryClock() >= $0.notBefore } ?? true
    }

    private func rearmMouseEdit(spaceKey: String) {
        lock.lock(); let off = control.paused || state.pausedSpaces.contains(spaceKey); lock.unlock()
        guard !off, system.currentSpaceID().map(String.init) == spaceKey, !pendingMouseEdit, autoGate().allowed else { return }
        pendingMouseEdit = true
        dragQuietPending = true
        mouseEditSpace = spaceKey
        earlyMouseEdit = false
        mouseEditSample = nil
    }
}
