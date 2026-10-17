import AppKit
import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

private struct UUIDListing: SpaceListing {
    var order: [UInt64]
    var uuids: [UInt64: String]
    var active: () -> UInt64?
    var fullScreen: Set<UInt64> = []
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, fullScreen.contains($0) ? 4 : 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
    func currentDisplayUUIDs() -> [UInt64: String]? { uuids }
}

/// Default `move-to-space`: sending, restoring the front window, and safety with moves that complete late.
/// Windows 1 (pid 101) and 2 (pid 102) are on Space 7, window 2 in front. Front history is 2 -> 1.
final class SendToSpaceTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var listing: UUIDListing!
    private let hookLock = NSLock()
    private var hookCalls: [String] = []
    private var sends: [(CGWindowID, UInt64)] = []

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 8, 9]
        system.hiddenSpaces = true
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7]
        system.pids = [WindowID(1): 101, WindowID(2): 102]
        system.frontPID = 102
        system.focused = WindowID(2)
        system.raiseActivatesOwner = true
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil }, takeInventory: { nil })
        coordinator.limits.settleDelay = 0
        listing = UUIDListing(order: [7, 8, 9], uuids: [7: "U7", 8: "U8", 9: "U9"], active: { self.system.space })
        coordinator.spaceListingOverride = listing
        coordinator.spaceChangeHookObserver = { [weak self] from, to in
            guard let self else { return }
            hookLock.lock(); hookCalls.append("\(from.map(String.init) ?? "-")→\(to)"); hookLock.unlock()
        }
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        sends = []
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func click(_ row: NSMenuItem, type: NSEvent.EventType) throws {
        let app = NSApplication.shared
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 0))
        let idle = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  subtype: 0, data1: 0, data2: 0))
        defer {
            // Do not leave a synthetic mouse button as the current event for later menu tests.
            app.postEvent(idle, atStart: true)
            _ = app.nextEvent(matching: .applicationDefined, until: Date(), inMode: .default, dequeue: true)
        }
        app.postEvent(event, atStart: true)
        let dequeued = app.nextEvent(matching: NSEvent.EventTypeMask(type: type),
                                     until: Date(), inMode: .default, dequeue: true)
        XCTAssertEqual(dequeued?.type, type)
        XCTAssertEqual(app.currentEvent?.type, type)
        XCTAssertTrue(app.sendAction(try XCTUnwrap(row.action), to: row.target, from: row))
        drain()
    }

    /// Replaces the sender. Default: confirmed (the window is only on the target Space). `during` runs mid-send.
    private func sender(_ outcome: ((CGWindowID, UInt64) -> SpaceControl.SendOutcome)? = nil, during: (() -> Void)? = nil) {
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, _ in
            sends.append((wid, dest))
            during?()
            if let outcome { return outcome(wid, dest) }
            system.spaceOf[WindowID(wid)] = dest
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
    }

    private func send(_ target: SpaceTarget = .index(3), file: StaticString = #filePath, line: UInt = #line) -> OperationResult? {
        guard case .started = coordinator.edit(.sendToSpace(target), source: "test") else { XCTFail("send not started", file: file, line: line); return nil }
        drain()
        return coordinator.lastResult
    }

    func testRefusedWithoutTheDirectMove() {
        make()
        sender()
        coordinator.sendAvailableOverride = false
        guard case .refused(let message, let code) = coordinator.edit(.sendToSpace(.index(3)), source: "test") else { return XCTFail("accepted without the direct move") }
        XCTAssertEqual(code, "send-unavailable", "never falls back to a drag, which would switch Spaces")
        XCTAssertTrue(message.contains("--follow"), "the recovery guidance must name the explicit following mode")
        XCTAssertTrue(sends.isEmpty)
    }

    /// After sending, the previous window (1) is brought forward without switching. No Space-change hook and no `space back` target.
    func testSendKeepsTheSpaceRestoresThePreviousWindowAndRecordsNoTransition() throws {
        make()
        sender()
        let before = coordinator.testingSpaceBookkeeping()
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(result.message, "Sent the window to Desktop 3.")
        XCTAssertEqual(sends.map(\.1), [9])
        XCTAssertEqual(system.space, 7, "not followed")
        XCTAssertEqual(system.frontPID, 101, "the previous window's app is in front again")
        XCTAssertEqual(system.focused, WindowID(1))
        XCTAssertTrue(hookCalls.isEmpty, "no Space-change hook")
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, before.previous, "no space back target is fabricated")
        XCTAssertEqual(result.kind, "send-to-space")
    }

    /// The latest earlier window was closed since: the one before it comes forward, as when macOS closes a window.
    func testRestorationSkipsAWindowNoLongerOnThisSpace() throws {
        make()
        sender()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(5), spaceKey: "7") // closed: not in the census
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.message, "Sent the window to Desktop 3.")
        XCTAssertEqual(system.frontPID, 101)
        XCTAssertEqual(system.focused, WindowID(1))
    }

    /// No restoration when it cannot be done (no candidate (no note), gone, moved to another Space, another process, activation not requested, not activated,
    /// or input before restoring). The send stays successful with a different note. Other apps' windows are never brought forward.
    func testRestorationIsSkippedUnlessTheWholeContractHolds() throws {
        for mode in ["no candidate", "closed", "moved", "pid reused", "abandoned", "never frontmost", "input"] {
            make()
            sender()
            switch mode {
            case "no candidate":
                coordinator.noteFront(WindowID(2), spaceKey: "7")
                system.frames[WindowID(1)] = nil // not visible on the current Space at acceptance
            case "closed": sender(during: { self.system.frames[WindowID(1)] = nil })
            case "moved": sender(during: { self.system.spaceOf[WindowID(1)] = 8 })
            case "pid reused": sender(during: { self.system.pids[WindowID(1)] = 555 })
            case "abandoned": system.raiseActivatesOwner = false // no activation queued (`activated(nil)`)
            case "never frontmost":
                // raise reports that activation was requested, but the app does not come forward.
                system.raiseActivatesOwner = false
                system.raiseReportsWithoutEffect = true
            case "input":
                // The send is confirmed, then input arrives before restoring.
                sender(during: { self.system.inputActivityCount += 1 })
            default: break
            }
            let result = try XCTUnwrap(send(), mode)
            XCTAssertEqual(result.outcome, .complete, "\(mode): the send stays successful — \(result.message)")
            // No candidate: nothing to restore (no note). A candidate that fails the contract: not restored, with a note.
            XCTAssertEqual(result.message.contains("The previous window was not brought forward."), mode != "no candidate", "\(mode): \(result.message)")
            XCTAssertNotEqual(system.frontPID, 555, mode)
            if mode != "never frontmost" { XCTAssertNotEqual(system.frontPID, 101, "\(mode): not restored") }
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// macOS changed the Space without follow: report the observed Space, do not revert, and do not restore the front. The observed change is recorded before publishing.
    func testAnObservedSpaceChangeIsReportedNotReverted() throws {
        make()
        var switched = false
        coordinator.spaceSwitcherOverride = { _, _, _ in switched = true; return .failure(.interrupted) }
        sender(during: { self.system.space = 9 })
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertTrue(result.message.contains("The display then moved to Desktop 3."), result.message)
        XCTAssertFalse(switched, "never switches back")
        XCTAssertEqual(system.space, 9)
        XCTAssertNotEqual(system.frontPID, 101, "no restoration on another Space")
        // The actual change (7 -> 9) is recorded once before publishing (no tick wait). No made-up return target.
        XCTAssertEqual(hookCalls, ["7→9"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        XCTAssertEqual(hookCalls, ["7→9"], "the next tick does not record it again")
    }

    /// The four endings after issuing are not success (notPossible before issuing, partial after).
    func testOutcomesAfterIssuance() throws {
        let cases: [(String, SpaceControl.SendOutcome, Outcome)] = [
            ("not issued", .notIssued(.alreadyThere), .notPossible),
            ("unconfirmed", .unconfirmed([]), .partial),
            ("elsewhere", .elsewhere(8), .partial),
            ("interrupted", .interrupted, .partial),
        ]
        for (label, outcome, expected) in cases {
            make()
            sender { _, _ in outcome }
            let result = try XCTUnwrap(send(), label)
            XCTAssertEqual(result.outcome, expected, "\(label): \(result.message)")
            XCTAssertNotEqual(system.frontPID, 101, "\(label): no restoration")
            if label == "elsewhere" { XCTAssertTrue(result.message.contains("Desktop 2"), result.message) }
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// After acceptance, the destination is rechecked right before issuing (uuid changed, became the current Space), also when sending by number.
    func testDestinationIsRevalidatedBeforeIssue() throws {
        make()
        sender()
        let gate = DispatchSemaphore(value: 0)
        coordinator.operationsQueue.async { gate.wait() }
        guard case .started = coordinator.edit(.sendToSpace(.index(3)), source: "test") else { gate.signal(); return XCTFail("not accepted") }
        listing.uuids[9] = "U9-replaced"
        coordinator.spaceListingOverride = listing
        gate.signal()
        drain()
        XCTAssertTrue(sends.isEmpty, "not issued")
        XCTAssertEqual(coordinator.lastResult?.outcome, .notPossible)

        let result = try XCTUnwrap(send(.index(2)))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(sends.map(\.1), [8])
    }

    /// Receipt identity: resending with the same receipt ID but different follow causes no other change (request-conflict).
    func testDefaultSendAndExplicitFollowHaveDifferentReceiptIdentities() throws {
        make()
        sender()
        var moves = 0
        coordinator.spaceMoverOverride = { _, _, _, _ in moves += 1; return .failure(.interrupted) }
        let receipts = MutationReceiptRegistry(now: { 10_000 })
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator, receipts: receipts)
        let token = try XCTUnwrap(delegate.handle(.init(cmd: "request-token.v3")).requestID)
        let first = delegate.handle(.init(cmd: "edit.v3", arg: "move-to-space-3", requestID: token))
        XCTAssertEqual(first.code, "pending", first.message)
        drain()
        let retry = delegate.handle(.init(cmd: "edit.v3", arg: "move-to-space-follow-3", requestID: token))
        XCTAssertEqual(retry.code, "request-conflict")
        drain()
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(moves, 0, "the follow mode did not run under the same receipt")
        let same = delegate.handle(.init(cmd: "edit.v3", arg: "move-to-space-3", requestID: token))
        XCTAssertEqual(same.code, "finished")
        XCTAssertEqual(sends.count, 1, "the same receipt does not send again")
    }

    func testSpaceMenuSendsWithoutFollowingAndKeepsTheObservedDestination() throws {
        make()
        sender()
        var followed = false
        coordinator.spaceMoverOverride = { _, _, _, _ in followed = true; return .failure(.interrupted) }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let destinations = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu)
        let item = try XCTUnwrap(destinations.items.last)
        XCTAssertEqual((item.representedObject as? EditCommandBox)?.command, .sendToSpace(.id(9)))
        let overview = try XCTUnwrap(menu.items.first {
            ($0.representedObject as? EditCommandBox)?.command == .space(.id(9))
        })
        XCTAssertEqual(try XCTUnwrap(item.attributedTitle).string, try XCTUnwrap(overview.attributedTitle).string)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.keyEquivalent, "3")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .shift])
        // An open menu names the observed Space; reordering must not change its destination.
        listing.order = [7, 9, 8]
        coordinator.spaceListingOverride = listing
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        XCTAssertEqual(sends.map(\.1), [9])
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.focused, WindowID(1))
        XCTAssertFalse(followed)
        XCTAssertTrue(hookCalls.isEmpty)
    }

    func testSpaceOverviewMouseButtonChoosesSendOrSwitch() throws {
        make()
        sender()
        var switches = 0
        coordinator.spaceSwitcherOverride = { _, _, _ in switches += 1; return .failure(.interrupted) }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first {
            ($0.representedObject as? EditCommandBox)?.command == .space(.id(9))
        })
        let current = try XCTUnwrap(menu.items.first {
            $0.action == item.action && $0.state == .on && $0.representedObject == nil
        })
        XCTAssertEqual((item.representedObject as? EditCommandBox)?.menuTarget, coordinator.menuWindowTarget())
        listing.order = [7, 9, 8]
        coordinator.spaceListingOverride = listing
        try click(item, type: .rightMouseDown)
        XCTAssertEqual(sends.map(\.1), [9])
        XCTAssertEqual(sends.map(\.0), [2])
        XCTAssertEqual(switches, 0)
        sends = []
        try click(item, type: .leftMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 1)
        switches = 0
        try click(current, type: .rightMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 0)
        try click(current, type: .leftMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 0)
    }

    func testSpaceOverviewWithoutAPinnedTargetRefusesRatherThanRetargeting() throws {
        make()
        sender()
        system.focused = nil; system.frontPID = nil
        var switches = 0
        coordinator.spaceSwitcherOverride = { _, _, _ in switches += 1; return .failure(.interrupted) }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first {
            ($0.representedObject as? EditCommandBox)?.command == .space(.id(9))
        })
        XCTAssertNil((item.representedObject as? EditCommandBox)?.menuTarget)
        system.focused = WindowID(2); system.frontPID = 102
        try click(item, type: .rightMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 0)
        XCTAssertEqual(coordinator.lastRefusal,
                       "“\(EditCommand.sendToSpace(.id(9)).label)”: Could not find the focused window. Select the window to send, then try again.")
        try click(item, type: .leftMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 1)
    }

    func testSpaceOverviewPinsOnlyTheFirstObservedWindow() throws {
        make()
        sender()
        var switches = 0
        coordinator.spaceSwitcherOverride = { _, _, _ in switches += 1; return .failure(.interrupted) }
        system.focused = nil; system.frontPID = nil
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first {
            ($0.representedObject as? EditCommandBox)?.command == .space(.id(9))
        })
        let box = try XCTUnwrap(item.representedObject as? EditCommandBox)
        XCTAssertNil(box.menuTarget)
        XCTAssertTrue(item.isEnabled)
        delegate.menuWillOpen(menu)
        defer { delegate.menuDidClose(menu) }
        system.focused = WindowID(2); system.frontPID = 102
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(box.menuTarget, coordinator.menuWindowTarget())
        XCTAssertEqual(box.menuTarget?.window, WindowID(2))
        system.focused = WindowID(1); system.frontPID = 101
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(box.menuTarget?.window, WindowID(2))
        XCTAssertTrue(item.isEnabled)
        try click(item, type: .rightMouseDown)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(switches, 0)
        XCTAssertTrue(coordinator.lastRefusal?.contains("The selected window changed. Open the menu again") == true)
        try click(item, type: .leftMouseDown)
        XCTAssertEqual(switches, 1)
        system.focused = WindowID(2); system.frontPID = 102
        try click(item, type: .rightMouseDown)
        XCTAssertEqual(sends.map(\.0), [2])
        XCTAssertEqual(sends.map(\.1), [9])
    }

    func testSpaceMenuUsesTheVisibleFrontWindowWhenAXFocusIsTemporarilyMissing() throws {
        make()
        sender()
        system.focused = nil
        system.frontWindow = WindowID(2)
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let destinations = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu)
        let item = try XCTUnwrap(destinations.items.last)
        XCTAssertTrue(item.isEnabled,
                      "A fresh visible front window must not wait for the asynchronous AX cache")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        XCTAssertEqual(sends.map(\.0), [2])
        XCTAssertEqual(system.space, 7)
    }

    func testSpaceMenuAcceptsAWindowSendDuringAutomaticArrangement() throws {
        make()
        sender()
        coordinator.operationsQueue.suspend()
        var resumed = false
        defer { if !resumed { coordinator.operationsQueue.resume(); drain() } }
        _ = coordinator.runSimple(kind: "auto-reconcile", progress: "", source: "auto") { _ in
            .note(kind: "auto-reconcile", spaceID: 7, message: "test", ok: true)
        }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let destinations = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu)
        let item = try XCTUnwrap(destinations.items.last)
        XCTAssertTrue(item.isEnabled,
                      "User movement can interrupt and queue behind automatic arrangement")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(coordinator.pendingUserWork, 1)
        XCTAssertTrue(sends.isEmpty)
        coordinator.operationsQueue.resume(); resumed = true
        drain(); drain()
        XCTAssertEqual(sends.map(\.0), [2])
        XCTAssertEqual(sends.map(\.1), [9])
        XCTAssertEqual(system.space, 7)
    }

    func testMenuSendUsesTheVisibleWindowWhenAXStillNamesAnotherWindowInTheSameApp() throws {
        make()
        sender()
        system.pids[WindowID(1)] = 102
        system.focused = WindowID(1)
        system.frontWindow = WindowID(2)
        let captured = try XCTUnwrap(coordinator.menuWindowTarget())
        _ = coordinator.edit(.sendToSpace(.index(3)), source: "menu", menuTarget: captured)
        drain()
        XCTAssertEqual(sends.map(\.0), [2], "the same fresh visible target drives eligibility and execution")
    }

    func testMenuTargetIsCheckedAtTheFinalIssueGateButNotAfterItLeaves() throws {
        for changedBeforeIssue in [true, false] {
            make()
            let captured = try XCTUnwrap(coordinator.menuWindowTarget())
            coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
                if changedBeforeIssue { system.pids[WindowID(2)] = 500; system.frontPID = 500 }
                guard gates.beforeIssue() else { return .notIssued(.interrupted) }
                sends.append((wid, dest))
                system.spaceOf[WindowID(wid)] = dest
                XCTAssertTrue(gates.afterIssue(), "a successful departure must not invalidate the observation gate")
                return .confirmed(.init(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
            }
            _ = coordinator.edit(.sendToSpace(.index(3)), source: "menu", menuTarget: captured)
            drain()
            XCTAssertEqual(sends.count, changedBeforeIssue ? 0 : 1)
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The right-click on a top-level row can name a full-screen Space; queued while busy, it is refused like an immediate send.
    func testAQueuedMenuSendNeverTargetsAFullScreenSpace() throws {
        for destination: UInt64 in [9, 10] {
            make()
            sender()
            listing.order = [7, 8, 9, 10]
            listing.uuids[10] = "U10"
            listing.fullScreen = [10]
            coordinator.spaceListingOverride = listing
            system.existingSpaces = [7, 8, 9, 10]
            coordinator.operationsQueue.suspend()
            _ = coordinator.runSimple(kind: "auto-reconcile", progress: "", source: "auto") { _ in
                .note(kind: "auto-reconcile", spaceID: 7, message: "test", ok: true)
            }
            let captured = try XCTUnwrap(coordinator.menuWindowTarget())
            let accept = coordinator.edit(.sendToSpace(.id(destination)), source: "menu", menuTarget: captured)
            coordinator.operationsQueue.resume()
            drain(); drain()
            if destination == 10 {
                XCTAssertTrue(sends.isEmpty, "a full-screen Space is not a send destination")
                if case .started = accept { XCTFail("queued a send to a full-screen Space") }
            } else {
                XCTAssertEqual(sends.map(\.1), [9], "a desktop queued the same way is sent")
            }
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testQueuedMenuSendNeverRetargetsAfterInputFocusIdentityOrSpaceChanges() throws {
        for change in ["input", "cancel", "focus", "same app focus", "pid reuse", "closed", "departure", "space", "permission"] {
            make()
            sender()
            coordinator.operationsQueue.suspend()
            var resumed = false
            defer { if !resumed { coordinator.operationsQueue.resume(); drain() } }
            _ = coordinator.runSimple(kind: "auto-reconcile", progress: "", source: "auto") { _ in
                .note(kind: "auto-reconcile", spaceID: 7, message: "test", ok: true)
            }
            let captured = try XCTUnwrap(coordinator.menuWindowTarget())
            guard case .started(let ticket) = coordinator.edit(.sendToSpace(.index(3)), source: "menu", menuTarget: captured) else {
                return XCTFail("not queued: \(change)")
            }
            switch change {
            case "input": system.inputActivityCount += 1
            case "cancel": coordinator.control.invalidate()
            case "focus": system.focused = WindowID(1); system.frontPID = 101
            case "same app focus": system.pids[WindowID(1)] = 102; system.focused = WindowID(1)
            case "pid reuse": system.pids[WindowID(2)] = 500; system.frontPID = 500
            case "closed": system.frames[WindowID(2)] = nil
            case "departure": system.spaceOf[WindowID(2)] = 8
            case "space": system.space = 8
            case "permission": system.trusted = false
            default: break
            }
            coordinator.operationsQueue.resume(); resumed = true
            drain(); drain()
            XCTAssertTrue(sends.isEmpty, change)
            XCTAssertNotEqual(coordinator.result(id: ticket)?.outcome, .complete, change)
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testMenuSendRevalidatesTheCapturedProcessAfterSlowObservation() throws {
        make()
        sender()
        let captured = try XCTUnwrap(coordinator.menuWindowTarget())
        system.onSnapshot = {
            self.system.pids[WindowID(2)] = 500
            self.system.frontPID = 500
        }
        _ = coordinator.edit(.sendToSpace(.index(3)), source: "menu", menuTarget: captured)
        drain()
        XCTAssertTrue(sends.isEmpty)
        XCTAssertNotEqual(coordinator.lastResult?.outcome, .complete)
    }

    func testAnOpenMenuRecoversWithoutRebuildingOrChangingItsDestination() throws {
        make()
        sender()
        system.focused = nil
        system.frontPID = nil
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let destinations = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu)
        let item = try XCTUnwrap(destinations.items.last)
        XCTAssertFalse(item.isEnabled)
        delegate.menuWillOpen(menu)
        defer { delegate.menuDidClose(menu) }
        system.focused = WindowID(2); system.frontPID = 102
        listing.order = [7, 9, 8]
        coordinator.spaceListingOverride = listing
        let deadline = Date().addingTimeInterval(2)
        while !item.isEnabled, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(item.isEnabled, "the tracking-mode timer refreshes a transiently unavailable window")
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(destinations.items.last === item, "no rebuild under the pointer")
        XCTAssertEqual((item.representedObject as? EditCommandBox)?.command, .sendToSpace(.id(9)))
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        XCTAssertEqual(sends.map(\.1), [9])
    }

    func testAnOpenMenuDoesNotSilentlyAdoptADifferentWindow() throws {
        make()
        sender()
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu?.items.last)
        delegate.menuWillOpen(menu)
        defer { delegate.menuDidClose(menu) }
        system.focused = WindowID(1); system.frontPID = 101
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(item.toolTip?.contains("Open the menu again") == true)
        // Even a late action that was already dispatched cannot move the new front window.
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        XCTAssertTrue(sends.isEmpty)
    }

    func testMenuTargetRequiresACurrentWindowOfTheActualFrontApp() {
        make()
        XCTAssertEqual(coordinator.menuWindowTarget()?.window, WindowID(2))
        system.frontPID = 999
        XCTAssertNil(coordinator.menuWindowTarget(), "another app's visible window is not the target")
        XCTAssertNil(coordinator.frontWindowForEdit(), "stale AX focus in a background app is not the target")
        system.frontPID = 102
        system.spaceOf[WindowID(2)] = 8
        XCTAssertNil(coordinator.menuWindowTarget(), "a departing window is not on the current Space")
        system.spaceOf[WindowID(2)] = 7
        system.onSpaceRead = { self.system.space = 8 }
        XCTAssertNil(coordinator.menuWindowTarget(), "a Space transition during observation is not coherent")
        system.onSpaceRead = nil
    }

    func testMenuWaitsForManualWorkButUpdatesAfterItFinishes() throws {
        make()
        sender()
        coordinator.operationsQueue.suspend()
        var resumed = false
        defer { if !resumed { coordinator.operationsQueue.resume(); drain() } }
        _ = coordinator.runSimple(kind: "space", progress: "", source: "test") { _ in
            .note(kind: "space", spaceID: 7, message: "test", ok: true)
        }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu?.items.last)
        XCTAssertFalse(item.isEnabled)
        delegate.menuWillOpen(menu)
        coordinator.operationsQueue.resume(); resumed = true
        defer { delegate.menuDidClose(menu) }
        drain()
        let deadline = Date().addingTimeInterval(2)
        while !item.isEnabled, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(item.isEnabled)
        coordinator.control.paused = true
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(item.isEnabled, "global pause still prevents sending")
    }

    func testExplicitFollowMovesTheWindowAndRecordsTheSpaceTransition() throws {
        make()
        sender()
        coordinator.spaceMoverOverride = { [unowned self] wid, _, dest, _ in
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let command = try XCTUnwrap(EditCommand.parse("move-to-space-follow-3"))
        guard case .started = coordinator.edit(command, source: "test") else { return XCTFail("follow not started") }
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(system.spaceOf[WindowID(2)], 9)
        XCTAssertEqual(system.space, 9)
        XCTAssertEqual(system.focused, WindowID(2))
        XCTAssertEqual(system.frontPID, 102)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(hookCalls, ["7→9"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
    }

    // MARK: - Reconciling sends with uncertain results (shared by B and C)

    /// A window issued but unconfirmed within 1 s stays out of the layout while its membership is rechecked; arrangements meanwhile (automatic or manual) do not write it.
    /// When the move completes late (membership only the destination), it waits for arrival. While membership is unreadable it stays out regardless of time.
    func testAMoveCompletingAfterTheTimeoutIsNeverWrittenMeanwhile() throws {
        make()
        var clock = Date(timeIntervalSince1970: 5_000)
        coordinator.routingClock = { clock }
        coordinator.limits.settleDelay = 0
        // Space 7 layout: windows 1 and 2. The sent window 2 does not move within 1 s.
        let store = StateStore(root: root)
        var state = store.load()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil }, takeInventory: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.routingClock = { clock }
        coordinator.spaceListingOverride = listing
        coordinator.noteFront(WindowID(1), spaceKey: "7"); coordinator.noteFront(WindowID(2), spaceKey: "7")
        sender { _, _ in .unconfirmed([7]) }
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertNotNil(coordinator.testingRouting().excluded[WindowID(2)], "excluded from placement")
        XCTAssertNotEqual(system.frontPID, 101, "no restoration after an uncertain send")

        // Automatic and manual arrangement meanwhile do not write window 2.
        system.written = []
        // Both windows are off their layout frames (without the exclusion, arranging would write both).
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 700, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 500, y: 100, width: 400, height: 400)
        for _ in 0..<4 { coordinator.operationsQueue.sync { coordinator.tick() }; drain() }
        _ = coordinator.arrange(source: "test")
        drain()
        XCTAssertFalse(system.written.contains { $0.0 == WindowID(2) }, "no write to the window while its Space is uncertain: \(system.written)")
        XCTAssertTrue(system.written.contains { $0.0 == WindowID(1) }, "the other window is still arranged")
        // While membership is unreadable, it stays out even past 3 s.
        system.hiddenSpaces = false
        clock.addTimeInterval(10)
        coordinator.operationsQueue.sync { coordinator.tick() }; drain()
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(2)], "time alone never releases the hold")
        // The move completed late.
        system.hiddenSpaces = true
        system.spaceOf[WindowID(2)] = 9
        coordinator.operationsQueue.sync { coordinator.tick() }; drain()
        let routing = coordinator.testingRouting()
        XCTAssertNil(routing.holds[WindowID(2)])
        XCTAssertNil(routing.excluded[WindowID(2)])
        XCTAssertEqual(routing.pending["U9"]?.keys.map(\.window), [WindowID(2)], "waits to be taken in when Space 3 is shown")
    }

    /// Staying on the source is confirmed only when membership is the source alone for 3 s and the frame is still; a frame move restarts the count.
    func testStayingOnTheSourceIsConfirmedOnlyAfterThreeQuietSeconds() throws {
        make()
        var clock = Date(timeIntervalSince1970: 5_000)
        coordinator.routingClock = { clock }
        sender { _, _ in .interrupted }
        _ = try XCTUnwrap(send())
        func tick(_ seconds: TimeInterval) { clock.addTimeInterval(seconds); coordinator.operationsQueue.sync { coordinator.tick() }; drain() }
        tick(2)
        system.frames[WindowID(2)] = system.frames[WindowID(2)]!.offsetBy(dx: 40, dy: 0) // the frame moved
        tick(2)
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(2)], "a moving frame restarts the count")
        tick(2)
        XCTAssertNotNil(coordinator.testingRouting().holds[WindowID(2)])
        tick(1.5)
        XCTAssertNil(coordinator.testingRouting().holds[WindowID(2)], "3 quiet seconds on the source: ordinary placement again")
        XCTAssertNil(coordinator.testingRouting().excluded[WindowID(2)])
        XCTAssertTrue(coordinator.testingRouting().pending.isEmpty)
    }

    /// Another app came forward after acceptance without input (a notification or self-activation): no restoration; the send stays successful with a note.
    func testRestorationYieldsToAnActivationWithoutInput() throws {
        make()
        sender(during: { self.system.frontPID = 999 })
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertTrue(result.message.contains("The previous window was not brought forward."), result.message)
        XCTAssertEqual(system.frontPID, 999, "the other app stays in front")
        XCTAssertTrue(system.raiseGuards.isEmpty, "nothing was raised")
    }

    /// The restoring activation made the app move its display to another Space: the position note and record come from the last observation after restoring (no tick in between).
    func testASpaceChangeDuringRestorationIsReportedAndRecorded() throws {
        make()
        sender()
        system.onRaiseActivated = { _ in self.system.space = 8 }
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertTrue(result.message.contains("The display then moved to Desktop 2."), result.message)
        XCTAssertEqual(hookCalls, ["7→8"], "recorded before publishing")
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7)
    }

    /// No restoration when the front is unknown, or another activation happened after acceptance (even if the original app came back).
    /// Also none when another window of the same app is in front.
    func testRestorationFailsClosed() throws {
        for mode in ["unknown front", "activation in between", "another window of the app"] {
            make()
            var activations: UInt64 = 0
            coordinator.activationCount = { activations }
            switch mode {
            case "unknown front": sender(during: { self.system.frontPID = nil })
            case "activation in between": sender(during: { activations += 2 }) // another app, then the original app
            default:
                system.frames[WindowID(3)] = CGRect(x: 0, y: 0, width: 300, height: 300)
                system.spaceOf[WindowID(3)] = 7
                system.pids[WindowID(3)] = 102
                sender(during: { self.system.focused = WindowID(3) }) // another window of the sent window's app comes forward
            }
            let result = try XCTUnwrap(send(), mode)
            XCTAssertEqual(result.outcome, .complete, mode)
            XCTAssertTrue(result.message.contains("The previous window was not brought forward."), "\(mode): \(result.message)")
            XCTAssertTrue(system.raiseGuards.isEmpty, "\(mode): nothing raised")
            drain()
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Our own activation notification raising the activation count is not mistaken for an intervening one (the notification is received before the gate check).
    func testOwnActivationDoesNotFailRestoration() throws {
        make()
        var activations: UInt64 = 0
        coordinator.activationCount = { activations }
        system.onRaiseActivated = { _ in activations += 1 } // our own activation
        sender()
        let result = try XCTUnwrap(send())
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.message, "Sent the window to Desktop 3.", "restored")
        XCTAssertEqual(system.frontPID, 101)
        XCTAssertEqual(activations, 1)
    }
}
