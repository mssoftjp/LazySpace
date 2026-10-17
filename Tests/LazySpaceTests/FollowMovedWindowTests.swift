import AppKit
import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

private struct Listing: SpaceListing {
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

/// `follow-moved-window`: the `move-to-space-*` shortcuts, the "Move Window to Space" rows, and the right-click on a Space follow the window;
/// the command line does not. Windows 1 (pid 101) and 2 (pid 102) are on Space 7 (Desktop 1), window 2 in front.
final class FollowMovedWindowTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private let hookLock = NSLock()
    private var hookCalls: [String] = []
    private var sends: [(CGWindowID, UInt64)] = []
    private var moves: [(CGWindowID, UInt64)] = []

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make(_ config: String = "follow-moved-window = true\n") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config.toml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 8, 9]
        system.hiddenSpaces = true
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7]
        system.pids = [WindowID(1): 101, WindowID(2): 102]
        system.frontPID = 102
        system.focused = WindowID(2)
        system.raiseActivatesOwner = true
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: configURL,
                                  takeCensus: system.census, takeOverview: { nil }, takeInventory: { nil })
        coordinator.limits.settleDelay = 0
        _ = coordinator.reloadConfig(source: "test")
        coordinator.spaceListingOverride = Listing(order: [7, 8, 9], uuids: [7: "U7", 8: "U8", 9: "U9"], active: { self.system.space })
        coordinator.spaceChangeHookObserver = { [weak self] from, to in
            guard let self else { return }
            hookLock.lock(); hookCalls.append("\(from.map(String.init) ?? "-")→\(to)"); hookLock.unlock()
        }
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, _ in
            sends.append((wid, dest))
            system.spaceOf[WindowID(wid)] = dest
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        coordinator.spaceMoverOverride = { [unowned self] wid, _, dest, gates in
            guard gates.hooks.beforeIssue() else { return .failure(.interrupted) }
            moves.append((wid, dest))
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        hookCalls = []
        sends = []
        moves = []
    }

    private func setConfig(_ text: String) throws {
        try text.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertNil(coordinator.configError)
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Holds the running slot with an automatic operation so user commands queue behind it.
    private func holdBusy() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.runSimple(kind: "auto-reconcile", progress: "", source: "auto") { _ in
            .note(kind: "auto-reconcile", spaceID: 7, message: "test", ok: true)
        }
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
        XCTAssertTrue(app.sendAction(try XCTUnwrap(row.action), to: row.target, from: row))
        drain()
    }

    private func transferRow(_ menu: NSMenu, to destination: UInt64) throws -> NSMenuItem {
        let rows = try XCTUnwrap(menu.items.first { $0.title == "Move Window to Space" }?.submenu)
        return try XCTUnwrap(rows.items.first {
            switch ($0.representedObject as? EditCommandBox)?.command {
            case .sendToSpace(.id(destination))?, .moveToSpace(.id(destination))?: return true
            default: return false
            }
        })
    }

    private func assertFollowed(_ window: CGWindowID = 2, to destination: UInt64 = 9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sends.isEmpty, "never sent without following", file: file, line: line)
        XCTAssertEqual(moves.map(\.0), [window], file: file, line: line)
        XCTAssertEqual(moves.map(\.1), [destination], file: file, line: line)
        XCTAssertEqual(system.space, destination, file: file, line: line)
        XCTAssertEqual(coordinator.lastResult?.kind, "move-to-space", file: file, line: line)
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete, file: file, line: line)
    }

    // MARK: - Resolution

    func testOnlyDefaultSendsBecomeFollows() {
        for target: SpaceTarget in [.index(3), .next, .prev, .id(9), .desktop(2, display: 1)] {
            XCTAssertEqual(EditCommand.sendToSpace(target).following(true), .moveToSpace(target))
            XCTAssertEqual(EditCommand.sendToSpace(target).following(false), .sendToSpace(target))
            XCTAssertEqual(EditCommand.moveToSpace(target).following(true), .moveToSpace(target))
            XCTAssertEqual(EditCommand.moveToSpace(target).following(false), .moveToSpace(target))
        }
        for command: EditCommand in [.space(.index(3)), .space(.back), .focus(.left), .close, .minimize] {
            XCTAssertEqual(command.following(true), command)
        }
    }

    func testShortcutsFollowInEveryModeOnlyWhenTheSettingIsOn() throws {
        let text = """
        [keys]
        move-to-space-follow-4 = "alt-ctrl-4"
        [mode.service.keys]
        mode-main = "esc"
        move-to-space-5 = "5"
        """
        for follow in [false, true] {
            let config = try Config.load(toml: "follow-moved-window = \(follow)\n" + text)
            let main = HotkeyBinding.from(config)
            for n in 1...9 {
                let key = try XCTUnwrap(Config.defaultKeys["move-to-space-\(n)"])
                let binding = try XCTUnwrap(main.first { $0.keyCode == key.keyCode && $0.modifiers == key.carbonModifiers })
                XCTAssertEqual(binding.command, follow ? .moveToSpace(.index(n)) : .sendToSpace(.index(n)))
                XCTAssertEqual(binding.label, follow ? "Move Window to Desktop \(n) and Follow" : "Send Window to Desktop \(n)")
            }
            XCTAssertTrue(main.contains { $0.command == .moveToSpace(.index(4)) }, "explicit follow always follows")
            XCTAssertEqual(main.contains { $0.command == .sendToSpace(.index(4)) }, !follow)
            let service = HotkeyBinding.from(config, mode: "service")
            XCTAssertEqual(service.first { $0.display == "5" }?.command, follow ? .moveToSpace(.index(5)) : .sendToSpace(.index(5)))
        }
    }

    // MARK: - Shortcuts and the command line

    func testAShortcutFollowsTheWindowAndRecordsTheTransition() throws {
        try make()
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let key = try XCTUnwrap(Config.defaultKeys["move-to-space-3"])
        let binding = try XCTUnwrap(HotkeyBinding.from(coordinator.config).first { $0.keyCode == key.keyCode && $0.modifiers == key.carbonModifiers })
        delegate.testingPerformHotkey(binding.action, source: "hotkey ⌥⇧3")
        drain()
        assertFollowed()
        XCTAssertEqual(system.focused, WindowID(2), "the moved window stays in front; the previous one is not brought back")
        XCTAssertEqual(hookCalls, ["7→9"])
        XCTAssertEqual(coordinator.testingSpaceBookkeeping().previous, 7, "⌥⇥ returns to the source")
    }

    func testTheCommandLineIgnoresTheSetting() throws {
        try make()
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator, receipts: MutationReceiptRegistry(now: { 10_000 }))
        let token = try XCTUnwrap(delegate.handle(.init(cmd: "request-token.v3")).requestID)
        let response = delegate.handle(.init(cmd: "edit.v3", arg: "move-to-space-3", requestID: token))
        XCTAssertEqual(response.code, "pending", response.message)
        drain()
        XCTAssertEqual(sends.map(\.1), [9])
        XCTAssertTrue(moves.isEmpty, "move-to-space without --follow always stays")
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(coordinator.lastResult?.kind, "send-to-space")
    }

    // MARK: - Menu

    func testMenuRowsFollowWithTheirShortcutAndPinnedWindow() throws {
        try make()
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try transferRow(menu, to: 9)
        let box = try XCTUnwrap(item.representedObject as? EditCommandBox)
        XCTAssertEqual(box.command, .moveToSpace(.id(9)))
        XCTAssertEqual(box.menuTarget, coordinator.menuWindowTarget())
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.keyEquivalent, "3")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .shift])
        // An open menu keeps refreshing follow rows like send rows.
        delegate.menuWillOpen(menu)
        defer { delegate.menuDidClose(menu) }
        system.focused = WindowID(1); system.frontPID = 101
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(item.isEnabled, "another window came forward; the row does not retarget")
        system.focused = WindowID(2); system.frontPID = 102
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(try transferRow(menu, to: 7).isEnabled, "the window's own Space")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        assertFollowed()
        XCTAssertEqual(hookCalls, ["7→9"])
    }

    /// The rows' commands and shortcuts come from the configuration the menu opened with; a change applies from the next open.
    func testAnOpenMenuKeepsTheSettingItOpenedWith() throws {
        let keys = "[keys]\nmove-to-space-3 = \"none\"\nmove-to-space-follow-3 = \"alt-ctrl-3\"\n"
        try make("follow-moved-window = true\n" + keys)
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        delegate.menuWillOpen(menu)
        let item = try transferRow(menu, to: 9)
        XCTAssertEqual(item.keyEquivalent, "3")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .control])
        try setConfig("follow-moved-window = false\n" + keys)
        XCTAssertFalse(coordinator.config.followMovedWindow)
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .control], "the open menu is not rebuilt")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        drain()
        delegate.menuDidClose(menu)
        assertFollowed()

        system.space = 7; system.spaceOf[WindowID(2)] = 7; moves = []
        let next = NSMenu()
        delegate.menuNeedsUpdate(next)
        let row = try transferRow(next, to: 9)
        XCTAssertEqual((row.representedObject as? EditCommandBox)?.command, .sendToSpace(.id(9)))
        XCTAssertEqual(row.keyEquivalent, "", "the explicit follow key is not a send's shortcut")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(row.action), to: row.target, from: row))
        drain()
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(sends.map(\.1), [9])
    }

    func testRightClickOnASpaceFollowsAndLeftClickStillSwitches() throws {
        try make()
        var switches = 0
        coordinator.spaceSwitcherOverride = { _, _, _ in switches += 1; return .failure(.interrupted) }
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { ($0.representedObject as? EditCommandBox)?.command == .space(.id(9)) })
        try click(item, type: .leftMouseDown)
        XCTAssertEqual(switches, 1)
        XCTAssertTrue(moves.isEmpty && sends.isEmpty)
        try click(item, type: .rightMouseDown)
        XCTAssertEqual(switches, 1)
        assertFollowed()
    }

    func testRightClickWithoutAPinnedWindowNamesTheFollowAction() throws {
        try make()
        system.focused = nil; system.frontPID = nil
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { ($0.representedObject as? EditCommandBox)?.command == .space(.id(9)) })
        system.focused = WindowID(2); system.frontPID = 102
        try click(item, type: .rightMouseDown)
        XCTAssertTrue(moves.isEmpty && sends.isEmpty)
        XCTAssertEqual(coordinator.lastRefusal,
                       "“Move Window to Space and Follow”: Could not find the focused window. Select the window to send, then try again.")
    }

    // MARK: - The pinned window on the follow path

    func testMenuFollowMovesThePinnedWindowWhenAXNamesAnotherWindowOfTheSameApp() throws {
        try make()
        system.pids[WindowID(1)] = 102
        system.focused = WindowID(1)
        system.frontWindow = WindowID(2)
        let captured = try XCTUnwrap(coordinator.menuWindowTarget())
        XCTAssertEqual(captured.window, WindowID(2))
        _ = coordinator.edit(.moveToSpace(.index(3)), source: "menu", menuTarget: captured)
        drain()
        assertFollowed()
    }

    func testMenuFollowChecksThePinnedWindowAtAcceptanceAndRightBeforeIssue() throws {
        try make()
        let captured = try XCTUnwrap(coordinator.menuWindowTarget())
        system.focused = WindowID(1); system.frontPID = 101
        guard case .refused(_, let code) = coordinator.edit(.moveToSpace(.index(3)), source: "menu", menuTarget: captured) else {
            return XCTFail("accepted for another window")
        }
        XCTAssertEqual(code, "targets-changed")

        for changedBeforeIssue in [true, false] {
            try make()
            let pinned = try XCTUnwrap(coordinator.menuWindowTarget())
            let mover = coordinator.spaceMoverOverride
            coordinator.spaceMoverOverride = { [unowned self] wid, frame, dest, gates in
                if changedBeforeIssue { system.pids[WindowID(2)] = 500; system.frontPID = 500 }
                return mover!(wid, frame, dest, gates)
            }
            _ = coordinator.edit(.moveToSpace(.index(3)), source: "menu", menuTarget: pinned)
            drain()
            XCTAssertEqual(moves.count, changedBeforeIssue ? 0 : 1)
            XCTAssertEqual(system.space, changedBeforeIssue ? 7 : 9)
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Queued commands

    func testAQueuedShortcutKeepsTheMeaningItWasPressedWith() throws {
        for follow in [true, false] {
            try make("follow-moved-window = \(follow)\n")
            let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
            let key = try XCTUnwrap(Config.defaultKeys["move-to-space-3"])
            let binding = try XCTUnwrap(HotkeyBinding.from(coordinator.config).first { $0.keyCode == key.keyCode && $0.modifiers == key.carbonModifiers })
            holdBusy()
            delegate.testingPerformHotkey(binding.action, source: "hotkey ⌥⇧3")
            XCTAssertEqual(coordinator.pendingUserWork, 1)
            try setConfig("follow-moved-window = \(!follow)\n")
            coordinator.operationsQueue.resume()
            drain(); drain()
            XCTAssertEqual(moves.count, follow ? 1 : 0, "follow \(follow)")
            XCTAssertEqual(sends.count, follow ? 0 : 1, "follow \(follow)")
            coordinator = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Without the direct move (before macOS 27)

    func testWithoutTheDirectMoveTheSettingMakesShortcutsWork() throws {
        try make()
        coordinator.sendAvailableOverride = false
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let key = try XCTUnwrap(Config.defaultKeys["move-to-space-3"])
        let binding = try XCTUnwrap(HotkeyBinding.from(coordinator.config).first { $0.keyCode == key.keyCode && $0.modifiers == key.carbonModifiers })
        delegate.testingPerformHotkey(binding.action, source: "hotkey ⌥⇧3")
        drain()
        assertFollowed()
    }

    func testTheRefusalWithoutTheDirectMoveNamesWhatTheUserCanDo() throws {
        try make("follow-moved-window = false\n")
        coordinator.sendAvailableOverride = false
        let title = SettingsCopy.followMovedWindowTitle
        for source in ["hotkey ⌥⇧3", "menu"] {
            guard case .refused(let message, let code) = coordinator.edit(.sendToSpace(.index(3)), source: source) else { return XCTFail(source) }
            XCTAssertEqual(code, "send-unavailable")
            XCTAssertTrue(message.contains("turn on “\(title)” in Settings › Shortcuts"), message)
            XCTAssertFalse(message.contains("--follow"), message)
        }
        guard case .refused(let message, _) = coordinator.edit(.sendToSpace(.index(3)), source: "agent") else { return XCTFail("agent") }
        XCTAssertTrue(message.contains("move-to-space --follow"), message)
        XCTAssertFalse(message.contains(title), message)
        XCTAssertTrue(sends.isEmpty && moves.isEmpty)
    }

    /// A send accepted before the setting was turned on is still refused, and the hint does not ask for what is already on.
    func testAQueuedSendAfterTheSettingTurnsOnSuggestsTryingAgain() throws {
        try make("follow-moved-window = false\n")
        coordinator.sendAvailableOverride = false
        holdBusy()
        guard case .started(let ticket) = coordinator.edit(.sendToSpace(.index(3)), source: "hotkey ⌥⇧3") else {
            coordinator.operationsQueue.resume()
            return XCTFail("not queued")
        }
        try setConfig("follow-moved-window = true\n")
        coordinator.operationsQueue.resume()
        drain(); drain()
        let message = try XCTUnwrap(coordinator.result(id: ticket)?.message)
        XCTAssertTrue(message.contains("Try again to move the window and switch to its Space."), message)
        XCTAssertFalse(message.contains("turn on"), message)
        XCTAssertTrue(sends.isEmpty && moves.isEmpty)
    }
}
