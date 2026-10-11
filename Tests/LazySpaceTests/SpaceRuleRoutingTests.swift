import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

/// Space observation for running the real `sendWindow` on CoordinatorSystem.
private final class SystemSpaces: SpaceObserving {
    let system: CoordinatorSystem
    init(_ system: CoordinatorSystem) { self.system = system }
    func activeSpace() -> UInt64? { system.space }
    func spaces(for windowID: CGWindowID) -> [UInt64] { system.spaceOf[WindowID(windowID)].map { [$0] } ?? [] }
    func isOrderedIn(_ windowID: CGWindowID) -> Bool? { nil }
    func managedDisplays() -> [SpaceObserver.ManagedDisplay] {
        [SpaceObserver.ManagedDisplay(display: "d", currentSpace: system.space, records: [7, 8, 9].map { .init(id: $0, type: 0) })]
    }
}

private struct RoutingListing: SpaceListing {
    var order: [UInt64]
    var uuids: [UInt64: String]
    var active: () -> UInt64?
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
    func currentDisplayUUIDs() -> [UInt64: String]? { uuids }
}

/// `action = "space"` rules through Coordinator.
/// Spaces 7, 8, 9 (uuids U7, U8, U9). Window 1 (the chat app, pid 101) exists from the start. The rule's destination is Space 3 (= 9).
final class SpaceRuleRoutingTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var clock = Date(timeIntervalSince1970: 50_000)
    private var sends: [(CGWindowID, UInt64)] = []
    private var sendOutcome: SpaceControl.SendOutcome?
    private var hookEnvs: [[String: String]] = []
    private var spaceHooks: [String] = []
    private let chat = "com.example.chat"

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var inventory: AppWindowInventory?

    private func make(rule: String = "space = 3") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 8, 9]
        system.hiddenSpaces = true
        system.frames = [WindowID(1): CGRect(x: 0, y: 0, width: 960, height: 1080)]
        system.spaceOf = [WindowID(1): 7]
        system.pids = [WindowID(1): 101]
        system.apps = [WindowID(1): chat]
        system.focused = WindowID(1)
        let configURL = root.appendingPathComponent("config.toml")
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil }, takeInventory: { [unowned self] in inventory })
        coordinator.limits.settleDelay = 0
        coordinator.spaceListingOverride = RoutingListing(order: [7, 8, 9], uuids: [7: "U7", 8: "U8", 9: "U9"], active: { self.system.space })
        coordinator.routingClock = { [unowned self] in clock }
        coordinator.processStartTime = { _ in Date(timeIntervalSince1970: 1_000) }
        coordinator.appBundleID = { [unowned self] pid in system.pids.first { $0.value == pid }.flatMap { system.apps[$0.key] } }
        coordinator.windowSentObserver = { [unowned self] env in hookEnvs.append(env) }
        coordinator.spaceChangeHookObserver = { [unowned self] from, to in spaceHooks.append("\(from.map(String.init) ?? "-")→\(to)") }
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, _ in
            sends.append((wid, dest))
            if let sendOutcome { return sendOutcome }
            system.spaceOf[WindowID(wid)] = dest
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        try "[[rule]]\napp = \"\(chat)\"\naction = \"space\"\n\(rule)\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick() // first observation: windows on Space 7 become known
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func tick(after seconds: TimeInterval = 0.2) {
        clock.addTimeInterval(seconds)
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    /// Opens a new window on Space 7.
    private func open(_ id: UInt32, pid: Int32 = 105, app: String? = nil, title: String = "", kind: ObservedWindow.Kind = .standard) {
        let window = WindowID(id)
        system.frames[window] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        system.spaceOf[window] = 7
        system.pids[window] = pid
        system.apps[window] = app ?? chat
        system.titles[window] = title
        system.kindOf[window] = kind
    }

    // MARK: -

    /// Existing windows are not sent. A new window is classified, takes an operation slot, is sent, and awaits arrival once confirmed.
    /// The hook runs only for confirmed sends and never gets the title. Nothing appears on screen.
    func testANewWindowIsSentAndExistingWindowsAreNot() throws {
        try make()
        XCTAssertTrue(sends.isEmpty, "the window that existed at the first observation is not new")
        open(5, title: "Secret meeting")
        open(6, pid: 106, title: "Another")
        tick()
        tick()
        XCTAssertEqual(sends.map(\.1), [9, 9])
        XCTAssertEqual(Set(sends.map(\.0)), [5, 6])
        XCTAssertEqual(coordinator.lastResult?.kind, "auto-route")
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete, coordinator.lastResult?.message ?? "")
        XCTAssertEqual(Set(coordinator.testingRouting().pending["U9"]?.keys.map(\.window) ?? []), [WindowID(5), WindowID(6)])
        XCTAssertEqual(coordinator.testingRouterPhase(WindowID(5)), .consumed)
        XCTAssertEqual(hookEnvs.count, 2)
        XCTAssertEqual(hookEnvs.first?["LAZYSPACE_APP"], chat)
        XCTAssertEqual(hookEnvs.first?["LAZYSPACE_FROM_SPACE"], "1")
        XCTAssertEqual(hookEnvs.first?["LAZYSPACE_TO_SPACE"], "3")
        XCTAssertFalse(hookEnvs.contains { $0.values.contains { $0.contains("Secret") } }, "titles are never passed")
        XCTAssertTrue(spaceHooks.isEmpty, "no Space change without follow")
        // A window moved back to its original Space by hand is not sent again.
        system.spaceOf[WindowID(5)] = 7
        tick(); tick()
        XCTAssertEqual(sends.count, 2)
    }

    /// A hook that cannot start is still explained after the send that ran it has published its result.
    func testAHookThatCannotStartIsReportedAfterTheSend() throws {
        try make()
        let saved = HookRunner.disclaim
        HookRunner.disclaim = { _ in false }
        defer { HookRunner.disclaim = saved }
        try "exec-on-window-sent = [\"/usr/bin/true\"]\n[[rule]]\napp = \"\(chat)\"\naction = \"space\"\nspace = 3\n"
            .write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        open(5)
        tick()
        tick()
        XCTAssertEqual(coordinator.lastResult?.kind, "auto-route")
        XCTAssertEqual(coordinator.status().lastRefusal, "Could not start hook /usr/bin/true: macOS cannot run it apart from LazySpace's permissions.")
    }

    /// Title conditions: sent if the title matches within the classification period (1.5 s). Afterward it returns to normal placement and a later match never sends.
    func testTitleRulesMatchOnlyWithinTheClassificationPeriod() throws {
        try make(rule: "title = \"Meet\"\nspace = 3")
        open(5)
        tick()
        XCTAssertTrue(sends.isEmpty)
        XCTAssertNotNil(coordinator.testingRouting().excluded[WindowID(5)], "kept out of placement while classifying")
        // The window list only reads, and shows classifying apart from normal waiting.
        let inspection = coordinator.inspectSnapshot(system.snapshot())
        XCTAssertTrue(inspection.excluded.contains { $0.window.id == WindowID(5) && $0.reason.contains("Space rule") }, "\(inspection.excluded.map(\.reason))")
        system.titles[WindowID(5)] = "Google Meet"
        tick(after: 0.8)
        XCTAssertEqual(sends.map(\.0), [5], "the title arrived in time")

        open(6, pid: 106)
        tick()
        tick(after: 1.6)
        XCTAssertEqual(coordinator.testingRouterPhase(WindowID(6)), .seen)
        XCTAssertNil(coordinator.testingRouting().excluded[WindowID(6)], "ordinary placement after the period")
        system.titles[WindowID(6)] = "Meet"
        tick(); tick()
        XCTAssertEqual(sends.map(\.0), [5], "a later title change never sends")
    }

    /// Non-standard windows such as sheets and dialogs are not sent. While classifying they show separately in the window list and stay out of the layout.
    func testNonStandardWindowsAreClassifiedThenLeftAlone() throws {
        try make()
        open(5, kind: .dialog)
        tick()
        let reason = coordinator.testingRouting().excluded[WindowID(5)]
        XCTAssertTrue(reason?.contains("Space rule") == true, reason ?? "")
        tick(after: 1.6)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertNil(coordinator.testingRouting().excluded[WindowID(5)])
    }

    /// Gates: no sending during global pause, this Space's pause, loss of input observation, or a held mouse button (after 3 s, normal placement).
    func testGatesStopSending() throws {
        for gate in ["pause", "space pause", "input observation", "mouse"] {
            try make()
            switch gate {
            case "pause": coordinator.pause()
            case "space pause": coordinator.setCurrentSpaceAutoPaused(true)
            case "input observation": system.inputAvailable = false
            case "mouse": system.input.record(.leftMouseDown, event: CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!)
            default: break
            }
            open(5)
            tick(); tick(); tick(after: 3.5)
            XCTAssertTrue(sends.isEmpty, gate)
            XCTAssertNil(coordinator.testingRouting().excluded[WindowID(5)], "\(gate): released to ordinary placement")
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A configuration reload after the send is accepted but before it is issued stops the send.
    func testAConfigReloadBeforeIssueStopsTheSend() throws {
        try make()
        open(5)
        let gate = DispatchSemaphore(value: 0)
        clock.addTimeInterval(0.2)
        coordinator.operationsQueue.async { self.coordinator.tick() }
        coordinator.operationsQueue.async { gate.wait() }
        // The tick accepted the send (the body is waiting); reload the configuration now.
        Thread.sleep(forTimeInterval: 0.2)
        _ = coordinator.reloadConfig(source: "test")
        gate.signal()
        drain()
        XCTAssertTrue(sends.isEmpty, "not issued after a reload")
        XCTAssertEqual(coordinator.lastResult?.kind, "auto-route")
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete)
    }

    /// A send with an uncertain result keeps the window out of the layout and reconciles by membership (as in B).
    func testAnUncertainRouteIsHeld() throws {
        try make()
        sendOutcome = .unconfirmed([7])
        open(5)
        tick()
        XCTAssertEqual(coordinator.lastResult?.outcome, .partial)
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(5)])
        XCTAssertEqual(coordinator.testingRouting().excluded[WindowID(5)], SendHold.reason)
        system.spaceOf[WindowID(5)] = 9 // arrived late
        tick()
        XCTAssertNil(coordinator.testingRouting().holds[WindowID(5)])
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(5)])
    }

    /// Recreate loop: 3 sends within 10 s pause this rule on this Space for 1 minute.
    func testRecreateLoopPausesTheRule() throws {
        try make()
        for id: UInt32 in [5, 6, 7] { open(id, pid: Int32(100 + id)); tick() }
        XCTAssertEqual(sends.count, 3)
        XCTAssertTrue(coordinator.lastResult?.message.contains("paused") == true, coordinator.lastResult?.message ?? "")
        open(8, pid: 108)
        tick()
        XCTAssertEqual(sends.count, 3, "paused for a minute")
        XCTAssertTrue(coordinator.lastResult?.message.contains("paused") == true)
        clock.addTimeInterval(61)
        open(9, pid: 109)
        tick()
        XCTAssertEqual(sends.count, 4)
    }

    /// follow = true: switches to that Space after sending and records the transition before publishing (`space back` returns to the original Space).
    func testFollowSwitchesAndRecordsTheTransition() throws {
        try make(rule: "space = 3\nfollow = true")
        var switched: [UInt64] = []
        coordinator.spaceSwitcherOverride = { [unowned self] dest, plan, _ in
            switched.append(dest)
            XCTAssertEqual(plan.windows[dest], [.window(5)], "raise the sent window")
            system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        open(5)
        tick()
        XCTAssertEqual(switched, [9])
        XCTAssertEqual(spaceHooks, ["7→9"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
    }

    /// Window ID reuse within a process: an ID confirmed closed (absent from the full window list) that reappears is classified as new.
    func testAReusedWindowIDAfterCloseIsNewAgain() throws {
        try make()
        open(5)
        tick()
        XCTAssertEqual(sends.count, 1)
        // A window sent to Space 9 is in the full window list, so it is not closed.
        system.space = 7
        tick()
        system.frames[WindowID(5)] = nil // closed
        tick()
        open(5)
        tick()
        XCTAssertEqual(sends.count, 2, "the reused ID is a new window")
    }

    /// Pending arrivals: entries that moved to another Space or closed are removed; visible ones stay until placed.
    func testPendingArrivalsAreCleanedUp() throws {
        try make()
        open(5); tick()
        open(6, pid: 106); tick()
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.count, 2)
        system.spaceOf[WindowID(5)] = 8 // moved to another Space by hand
        system.frames[WindowID(6)] = nil // closed
        open(7, pid: 107); tick() // a third one
        system.space = 9
        tick()
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(7)])
    }

    /// Session key: a changed login session (logout and login within one launch), a malformed key, or an unreadable session all
    /// discard remembered window IDs (layouts). The same key keeps them.
    func testSessionKeyDistinguishesLogoutAndFailsClosed() throws {
        try make()
        XCTAssertEqual(Coordinator.sessionKey(boot: "1000-user", loginSession: "42"), "1000-user-session42")
        XCTAssertNil(Coordinator.sessionKey(boot: "1000-user", loginSession: nil))
        // macOS 27's dictionary has no kCGSSessionIDKey. Use the UUID, then the audit session ID, then the old key.
        XCTAssertEqual(Coordinator.loginSessionIdentifier(from: ["CGSSessionUniqueSessionUUID": "B8F5", "kCGSSessionAuditIDKey": NSNumber(value: 100019)]), "uuid-B8F5")
        XCTAssertEqual(Coordinator.loginSessionIdentifier(from: ["kCGSSessionAuditIDKey": NSNumber(value: 100019), "kCGSSessionIDKey": NSNumber(value: 7)]), "audit-100019")
        XCTAssertEqual(Coordinator.loginSessionIdentifier(from: ["kCGSSessionIDKey": NSNumber(value: 7)]), "7")
        XCTAssertNil(Coordinator.loginSessionIdentifier(from: ["CGSSessionUniqueSessionUUID": ""]))
        func reopen(stored: String) {
            let store = StateStore(root: root)
            var state = store.load()
            state.layouts["7"] = Planner.rowLayout([WindowID(1)], rows: 1)
            state.sessionKey = stored
            store.save(state)
            drain()
            coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        }
        reopen(stored: "1000-user-session42")
        coordinator.discardLayouts(sessionKey: "1000-user-session42")
        XCTAssertNotNil(coordinator.state.layouts["7"], "the same login session keeps window-ID state")
        coordinator.discardLayouts(sessionKey: "1000-user-session43")
        XCTAssertNil(coordinator.state.layouts["7"], "a new login session in the same boot discards window-ID state")
        XCTAssertTrue(coordinator.lastRefusal?.contains("new login session") == true, coordinator.lastRefusal ?? "")
        reopen(stored: "1000-user")
        coordinator.discardLayouts(sessionKey: "1000-user-session42")
        XCTAssertNil(coordinator.state.layouts["7"], "a key in another form cannot establish continuity")
        reopen(stored: "1000-user-session42")
        coordinator.discardLayouts(sessionKey: nil)
        XCTAssertNil(coordinator.state.layouts["7"], "an unreadable login session cannot establish continuity")
    }

    /// The full window list at launch only marks windows known, not Spaces observed: a Space not yet seen marks every window there
    /// known when first seen (windows opened after launch are not sent either). Windows opened after that first look are new.
    /// A window present since launch moving into an observed Space is not treated as new.
    func testLaunchSeedingKnowsWindowsButFirstVisitsStillSeed() throws {
        inventory = AppWindowInventory(selfPID: 1, visibleSpaces: [7], apps: [:],
                                       windows: [.init(id: 1, pid: 101, onScreen: true, spaces: [7]), .init(id: 20, pid: 120, onScreen: false, spaces: [8])])
        try make()
        func place(_ id: UInt32, pid: Int32, on space: UInt64) {
            let window = WindowID(id)
            system.frames[window] = CGRect(x: 0, y: 0, width: 800, height: 600)
            system.spaceOf[window] = space
            system.pids[window] = pid
            system.apps[window] = chat
        }
        // After launch, window 21 opened on Space 8 while the user was away. Window 20 has existed since launch.
        place(20, pid: 120, on: 8)
        place(21, pid: 121, on: 8)
        system.space = 8
        tick(); tick()
        XCTAssertTrue(sends.isEmpty, "the first visit of Space 8 seeds every window there, including ones opened after launch")
        place(22, pid: 122, on: 8)
        tick()
        XCTAssertEqual(sends.map(\.0), [22], "a window opened after the first visit is new")
    }

    /// A window on another Space since launch moving into an observed Space is not treated as new.
    func testAWindowKnownAtLaunchMovingInIsNotNew() throws {
        inventory = AppWindowInventory(selfPID: 1, visibleSpaces: [7], apps: [:],
                                       windows: [.init(id: 1, pid: 101, onScreen: true, spaces: [7]), .init(id: 23, pid: 123, onScreen: false, spaces: [9])])
        try make()
        open(23, pid: 123) // moved from 9 to 7
        tick(); tick()
        XCTAssertTrue(sends.isEmpty)
    }

    // MARK: - Issuance gates

    /// Gates are also checked right before issuing (after changes during slow reads). A configuration reload ends it (no retry); pause and the like retry within the deadline.
    func testGatesAreCheckedAtIssuanceAfterTheSlowReads() throws {
        for change in ["reload", "space pause", "pause", "input observation"] {
            try make()
            var issued = 0
            coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
                // State changes during the read right before `sendWindow` issues.
                switch change {
                case "reload": _ = coordinator.reloadConfig(source: "test")
                case "space pause": coordinator.setCurrentSpaceAutoPaused(true)
                case "pause": coordinator.control.paused = true
                default: system.inputAvailable = false
                }
                guard gates.beforeIssue() else { return .notIssued(.interrupted) }
                issued += 1
                sends.append((wid, dest))
                return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
            }
            open(5)
            tick()
            XCTAssertEqual(issued, 0, "\(change): not issued")
            if change == "reload" {
                XCTAssertEqual(coordinator.testingRouterPhase(WindowID(5)), .consumed, "a configuration change ends the attempt")
            } else {
                if case .ready? = coordinator.testingRouterPhase(WindowID(5)) {} else { XCTFail("\(change): retried within the deadline: \(String(describing: coordinator.testingRouterPhase(WindowID(5))))") }
            }
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A configuration reload during the body's slow read (rereading the window) stops the send.
    func testAReloadDuringTheWindowReadStopsTheSend() throws {
        try make()
        open(5)
        // Reads of window 5 alone: the first classifies, the second rereads before issuing; reload during the second.
        var reads = 0
        system.onSnapshot = { [unowned self] in
            guard system.snapshotScopes.last == [WindowID(5)] else { return }
            reads += 1
            if reads == 2 { _ = coordinator.reloadConfig(source: "test") }
        }
        tick()
        XCTAssertTrue(sends.isEmpty)
        XCTAssertTrue(coordinator.lastResult?.message.contains("settings changed") == true, coordinator.lastResult?.message ?? "")
    }

    /// A send stopped by a gate before issuing is sent with a new authorization when the gate opens, within 3 s of first becoming ready.
    func testAGateBlockedSendIsRetriedWithinTheDeadline() throws {
        try make()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(.leftMouseDown, event: down)
        open(5)
        tick()
        tick(after: 1)
        XCTAssertTrue(sends.isEmpty, "not while the mouse button is held")
        system.input.record(.leftMouseUp, event: up)
        tick(after: 1)
        XCTAssertEqual(sends.map(\.0), [5], "sent once the gate opened, within the ready deadline")
    }

    /// Windows leave the layout before the classification read, so an arrangement accepted during the read does not write a classifying window.
    /// An arrangement accepted before classification started also excludes it right before running.
    func testArrangeNeverWritesAClassifyingWindow() throws {
        try make(rule: "title = \"Meet\"\nspace = 3")
        open(5)
        system.frames[WindowID(5)] = CGRect(x: 300, y: 300, width: 500, height: 500)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var blocked = false
        system.onSnapshot = {
            guard !Thread.isMainThread, !blocked else { return }
            blocked = true
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        clock.addTimeInterval(0.2)
        coordinator.operationsQueue.async { self.coordinator.tick() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the classification read started")
        XCTAssertNotNil(coordinator.testingExcludedNow()[WindowID(5)], "excluded before the AX read")
        system.written = []
        _ = coordinator.arrange(source: "test") // arrangement accepted during the classification read
        release.signal()
        drain(); drain()
        XCTAssertFalse(system.written.contains { $0.0 == WindowID(5) }, "the classifying window is not written: \(system.written)")

        // Arrangement accepted before classification started: excluded right before running.
        system.onSnapshot = nil
        open(6, pid: 106)
        system.frames[WindowID(6)] = CGRect(x: 200, y: 200, width: 500, height: 500)
        let gate = DispatchSemaphore(value: 0)
        coordinator.operationsQueue.async { gate.wait() }
        clock.addTimeInterval(0.2)
        coordinator.operationsQueue.async { self.coordinator.tick() } // starts classifying (runs before the arrangement body)
        system.written = []
        _ = coordinator.arrange(source: "test") // accepted while nothing was excluded yet
        gate.signal()
        drain(); drain()
        XCTAssertFalse(system.written.contains { $0.0 == WindowID(6) }, "excluded again when the queued arrange runs: \(system.written)")
    }

    /// Identity throughout: the same ID gaining another owner during reconciliation -> reconciliation stops without awaiting arrival. A pending arrival's process replaced ->
    /// removed from pending arrivals. A process replaced while classifying -> ambiguous, not sent.
    func testIdentityIsCheckedThroughTheLifecycle() throws {
        try make()
        var starts: [Int32: Date] = [:]
        coordinator.processStartTime = { pid in starts[pid] ?? Date(timeIntervalSince1970: 1_000) }
        // Owner change during reconciliation.
        sendOutcome = .unconfirmed([7])
        open(5)
        tick()
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(5)])
        system.pids[WindowID(5)] = 555 // same ID, window of another process
        system.spaceOf[WindowID(5)] = 9
        tick()
        XCTAssertNil(coordinator.testingRouting().holds[WindowID(5)], "lost identity: the hold ends")
        XCTAssertNil(coordinator.testingRouting().pending["U9"], "and does not become a pending arrival")
        // Process replaced while awaiting arrival.
        sendOutcome = nil
        open(6, pid: 106)
        tick()
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(6)])
        starts[106] = Date(timeIntervalSince1970: 9_000) // pid 106 becomes another process
        system.space = 9
        tick()
        XCTAssertNil(coordinator.testingRouting().pending["U9"], "a reused pid is not the window that was sent")
        // Replaced while classifying.
        system.space = 7
        tick()
        lockTitleRule()
        open(7, pid: 107)
        tick()
        starts[107] = Date(timeIntervalSince1970: 9_500)
        system.titles[WindowID(7)] = "Meet"
        tick(); tick()
        XCTAssertFalse(sends.contains { $0.0 == 7 }, "ambiguous identity while classifying: never sent")
    }

    func testUnreadableProcessStartDoesNotReleaseAnUnconfirmedSend() throws {
        try make()
        sendOutcome = .unconfirmed([7])
        open(5)
        tick()
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(5)])
        coordinator.processStartTime = { _ in nil }
        tick()
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(5)], "unknown process start is not proof of a different window")
        XCTAssertNotNil(coordinator.testingRouting().excluded[WindowID(5)])
        coordinator.processStartTime = { _ in Date(timeIntervalSince1970: 1_000) }
        system.spaceOf[WindowID(5)] = 9
        tick()
        XCTAssertNil(coordinator.testingRouting().holds[WindowID(5)])
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(5)])
    }

    func testUnreadableProcessStartKeepsAPendingArrival() throws {
        try make()
        open(5)
        tick()
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(5)])
        coordinator.processStartTime = { _ in nil }
        system.space = 9
        tick()
        XCTAssertEqual(coordinator.testingRouting().pending["U9"]?.keys.map(\.window), [WindowID(5)], "a missing process timestamp must not lose the requested arrival")
    }

    /// Switches to a title rule (to keep a window in classification).
    private func lockTitleRule() {
        try? "[[rule]]\napp = \"\(chat)\"\naction = \"space\"\ntitle = \"Meet\"\nspace = 3\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        drain()
        tick()
    }

    /// A title matching on the first observation past the deadline does not send (the deadline is checked first). Apps with slow reads are skipped for a while.
    func testClassificationDeadlineAndSlowApps() throws {
        try make(rule: "title = \"Meet\"\nspace = 3")
        open(5)
        tick()
        system.titles[WindowID(5)] = "Meet"
        tick(after: 1.6) // no expired observation in between
        XCTAssertTrue(sends.isEmpty, "a match on the first observation after 1.5 s is not sent")
        XCTAssertEqual(coordinator.testingRouterPhase(WindowID(5)), .seen)

        // A slow app: the read took 1.6 s -> past the deadline, so not sent. Its windows are not read for a while.
        open(6, pid: 106, title: "Meet")
        var reads = 0
        system.onSnapshot = { [unowned self] in
            guard let scope = system.snapshotScopes.last, scope?.contains(WindowID(6)) == true || scope?.contains(WindowID(8)) == true else { return }
            reads += 1
            clock.addTimeInterval(1.6)
        }
        tick()
        XCTAssertTrue(sends.isEmpty, "the slow read finished after the deadline")
        let after = reads
        open(8, pid: 106, title: "Meet")
        tick(after: 0.1)
        XCTAssertEqual(reads, after, "the unresponsive app is not read again for a while")
        XCTAssertTrue(sends.isEmpty)
    }

    /// Result contract: if the requested follow cannot be confirmed, partial (still reporting the send succeeded). For a rule without follow, if the display moved to another Space during restoration,
    /// the position note and record come from the last observation (no tick in between).
    func testRuleResultContract() throws {
        try make(rule: "space = 3\nfollow = true")
        coordinator.spaceSwitcherOverride = { _, _, _ in .failure(.interrupted) }
        open(5)
        tick()
        let failed = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(failed.outcome, .partial)
        XCTAssertTrue(failed.message.contains("Sent a new"), failed.message)
        XCTAssertTrue(failed.message.contains("could not be confirmed"), failed.message)
        XCTAssertEqual(sends.count, 1, "the send itself is not retried")

        try? FileManager.default.removeItem(at: root)
        drain()
        try make()
        system.raiseActivatesOwner = true
        system.pids[WindowID(1)] = 101
        system.frontPID = 105
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        open(5)
        system.focused = WindowID(5) // the window to send is in front
        system.onRaiseActivated = { _ in self.system.space = 8 } // the restoring activation moves the display
        tick()
        let moved = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(moved.outcome, .complete)
        XCTAssertTrue(moved.message.contains("The display then moved to Desktop 2."), moved.message)
        XCTAssertEqual(spaceHooks, ["7→8"], "recorded before publishing")
    }

    // MARK: - Bounded reads

    /// Classification reads are bounded: even an unresponsive app (blocking for 30 s) is not waited on beyond the budget (0.25 s), and it is skipped for a while.
    func testClassificationReadsAreBounded() throws {
        try make()
        system.blockingPIDs[106] = 30
        open(6, pid: 106)
        let started = Date()
        tick()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the operations queue was not held by the unresponsive app")
        XCTAssertLessThanOrEqual(system.boundedReadBudgets.last ?? 99, Coordinator.classificationReadBudget + 0.01, "the read got the aggregate deadline")
        XCTAssertTrue(sends.isEmpty)
        let reads = system.boundedReadBudgets.count
        tick()
        XCTAssertEqual(system.boundedReadBudgets.count, reads, "backed off: not read again for a while")
        tick(after: 1.6)
        XCTAssertEqual(coordinator.testingRouterPhase(WindowID(6)), .seen, "never classified: ordinary placement after the period")
    }

    /// After issuing, the source Space is not required: with the real `sendWindow`, if macOS switches Spaces right after the send, membership only on the destination is still
    /// confirmed (the hook runs). The result notes the display moved, and the transition is recorded before publishing.
    func testAnOSInitiatedSwitchAfterIssueIsStillAConfirmedSend() throws {
        try make()
        let control = SpaceControl(spaces: SystemSpaces(system), inputCount: { [unowned self] in system.inputActivityCount }, hotkey: { _ in .unknown })
        control.direct = SpaceControl.DirectPath(move: { [unowned self] wid, dest in
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest // macOS switched the display to the sent window
            return true
        }, raise: { _, _, _ in .refused }, reactivate: { _, _, _, _ in })
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            sends.append((wid, dest))
            return control.sendWindow(wid, toSpace: dest, beforeIssue: gates.beforeIssue, afterIssue: gates.afterIssue)
        }
        open(5)
        tick()
        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertTrue(result.message.contains("The display then moved to Desktop 3."), result.message)
        XCTAssertEqual(hookEnvs.count, 1, "a confirmed send runs the hook")
        XCTAssertEqual(spaceHooks, ["7→9"], "the observed switch is recorded before publishing")
        XCTAssertNil(coordinator.testingRouting().holds[WindowID(5)], "not held: the send was confirmed")
    }
}
