import XCTest
import Copy
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpace

final class CoordinatorTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var store: StateStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
    }

    override func tearDownWithError() throws {
        drain()
        try FileManager.default.removeItem(at: root)
    }

    private func drain() {
        let done = expectation(description: "Operations drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func tick() {
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    func testTrustChangeIsReportedOnceEachWayAndFromTheSystemNotification() {
        var changes: [Bool] = []
        coordinator.onTrustChange = { changes.append($0) }
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(changes, [], "The trust read at launch is the baseline, not a change")
        system.trusted = false
        tick()
        tick()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(changes, [false])
        system.trusted = true
        coordinator.checkTrust()
        drain()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(changes, [false, true])
    }

    func testAgentResizeAndUndoRestoreGeometryWithoutChangingFocus() throws {
        system.focused = WindowID(2)
        guard case .started(let resize) = coordinator.agentEdit(.resize(.horizontal, -0.1), windowID: WindowID(1), expectedSpaceID: 7, expectedPID: 1) else { return XCTFail("Not accepted") }
        drain()
        XCTAssertEqual(coordinator.result(id: resize)?.outcome, .complete)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 768)
        XCTAssertEqual(system.focused, WindowID(2))
        guard case .started(let undo) = coordinator.agentEdit(.undo, windowID: nil, expectedSpaceID: 7) else { return XCTFail("Undo not accepted") }
        drain()
        XCTAssertEqual(coordinator.result(id: undo)?.outcome, .complete)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 960)
        XCTAssertEqual(coordinator.result(id: undo)?.issued, 2)
        if case .refused = coordinator.agentEdit(.undo, windowID: nil, expectedSpaceID: 7) {} else { XCTFail("History should be exhausted") }
    }

    func testAgentRejectsWrongSpaceMissingWindowAndWrongProcess() {
        for (id, space, pid) in [(UInt32(1), UInt64(8), Int32(1)), (99, 7, 1), (1, 7, 999)] {
            if case .refused = coordinator.agentEdit(.close, windowID: WindowID(id), expectedSpaceID: space, expectedPID: pid) {} else { XCTFail("Must refuse") }
        }
        drain()
        XCTAssertEqual(system.closeCalls, 0)
        XCTAssertEqual(system.writes, 0)
    }

    func testAgentRechecksSpaceAfterObservationAndBeforeExecution() {
        system.onSnapshot = { self.system.space = 8 }
        if case .refused = coordinator.agentEdit(.resize(.horizontal, 0.1), windowID: WindowID(1), expectedSpaceID: 7) {} else { XCTFail("Changed during observation") }
        system.onSnapshot = nil
        system.space = 7
        coordinator.operationsQueue.suspend()
        let accepted = coordinator.agentEdit(.resize(.horizontal, 0.1), windowID: WindowID(1), expectedSpaceID: 7)
        XCTAssertEqual(coordinator.agentEdit(.close, windowID: WindowID(2), expectedSpaceID: 7), .busy)
        system.space = 8
        coordinator.operationsQueue.resume()
        drain()
        guard case .started(let id) = accepted else { return XCTFail("Not accepted") }
        XCTAssertEqual(coordinator.result(id: id)?.stopReason, .spaceChanged)
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.closeCalls, 0)
    }

    func testAgentCloseUsesExplicitTargetWithoutFocusingIt() {
        system.focused = WindowID(2)
        _ = coordinator.agentEdit(.close, windowID: WindowID(1), expectedSpaceID: 7)
        drain()
        XCTAssertNil(system.frames[WindowID(1)])
        XCTAssertNotNil(system.frames[WindowID(2)])
        XCTAssertEqual(system.focused, WindowID(2))
        XCTAssertEqual(system.focusCalls, 0)
    }

    func testAgentInputOrTargetLossAfterAcceptancePreventsWrites() {
        for removeTarget in [false, true] {
            coordinator.operationsQueue.suspend()
            let accepted = coordinator.agentEdit(.resize(.horizontal, 0.1), windowID: WindowID(1), expectedSpaceID: 7)
            if removeTarget { system.frames[WindowID(1)] = nil } else { system.inputActivityCount += 1 }
            coordinator.operationsQueue.resume()
            drain()
            guard case .started(let id) = accepted else { XCTFail("Not accepted"); continue }
            XCTAssertEqual(coordinator.result(id: id)?.stopReason, removeTarget ? .targetsChanged : .userInput)
            XCTAssertEqual(system.writes, 0)
        }
    }

    func testRawAgentRequestsRejectUnsupportedFieldsBeforeActing() {
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let bad: [ControlPort.Request] = [
            .init(cmd: "edit.v3", arg: "close", desiredState: true),
            .init(cmd: "edit.v3", arg: "float"),
            .init(cmd: "edit.v3", arg: "close extra"),
            .init(cmd: "focus-window.v3"),
            .init(cmd: "status", expectedSpaceID: 7)
        ]
        for request in bad {
            XCTAssertFalse(delegate.handle(request).ok)
            XCTAssertEqual(delegate.handle(request).code, "usage")
        }
        drain()
        XCTAssertEqual(system.writes + system.closeCalls + system.stateCalls + system.focusCalls, 0)
        XCTAssertNil(ControlPort.decodeRequest(Data("{\"cmd\":\"status\",\"unknown\":true}".utf8)))
        XCTAssertNil(ControlPort.decodeRequest(Data("not json".utf8)))
    }

    func testAgentDesiredStatesAreIdempotent() {
        for command in [EditCommand.toggleFloat, .toggleZoom, .fullscreen, .minimize] {
            for desired in [true, false] {
                _ = coordinator.agentEdit(command, windowID: WindowID(1), expectedSpaceID: 7, desiredState: desired)
                drain()
                let writes = system.writes + system.stateCalls
                guard case .started(let id) = coordinator.agentEdit(command, windowID: WindowID(1), expectedSpaceID: 7, desiredState: desired) else { XCTFail("Not accepted"); continue }
                drain()
                XCTAssertEqual(coordinator.result(id: id)?.outcome, .complete, "\(command) \(desired)")
                XCTAssertEqual(coordinator.result(id: id)?.issued, 0)
                XCTAssertEqual(system.writes + system.stateCalls, writes)
            }
        }
    }

    func testFloatingLastWindowReportsCompletedLogicalChange() {
        _ = coordinator.agentEdit(.toggleFloat, windowID: WindowID(1), expectedSpaceID: 7, desiredState: true)
        drain()
        guard case .started(let id) = coordinator.agentEdit(.toggleFloat, windowID: WindowID(2), expectedSpaceID: 7, desiredState: true) else { return XCTFail("Not accepted") }
        drain()
        XCTAssertEqual(coordinator.result(id: id)?.outcome, .complete)
        XCTAssertEqual(coordinator.result(id: id)?.issued, 0)
        XCTAssertEqual(coordinator.result(id: id)?.verified, true)
        XCTAssertEqual(Set(coordinator.status().floating), [WindowID(1), WindowID(2)])
    }

    func testAgentResultDistinguishesPendingFinishedAndUnknown() {
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        coordinator.operationsQueue.suspend()
        let token = delegate.handle(.init(cmd: "request-token.v3")).requestID
        let accepted = delegate.handle(.init(cmd: "focus-window.v3", windowID: WindowID(2), expectedSpaceID: 7, requestID: token))
        XCTAssertEqual(delegate.handle(.init(cmd: "result", arg: accepted.operationID)).code, "pending")
        coordinator.operationsQueue.resume()
        drain()
        let finished = delegate.handle(.init(cmd: "result", arg: accepted.operationID))
        XCTAssertEqual(finished.code, "finished")
        XCTAssertEqual(finished.result?.id, accepted.operationID)
        XCTAssertNotEqual(finished.operationID, token)
        XCTAssertEqual(delegate.handle(.init(cmd: "result", arg: UUID().uuidString)).code, "unknown-operation")
    }

    func testSettlementRequiresFreshStableObservation() {
        func observe() -> ControlPort.Settlement? {
            let done = expectation(description: "Observed")
            var value: ControlPort.Settlement?
            coordinator.observeSettlement { value = $0; done.fulfill() }
            wait(for: [done], timeout: 3)
            return value
        }
        coordinator.pause()
        XCTAssertFalse(observe()?.settled ?? true)
        Thread.sleep(forTimeInterval: 1.1)
        _ = observe() // arrival is first noticed by the observation pass
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(observe()?.settled ?? false)
        system.frames[WindowID(1)]?.size.width = 800
        XCTAssertFalse(observe()?.settled ?? true)
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    private func prepareMouseLayout() {
        _ = coordinator.arrange(source: "test")
        drain()
        tick()
        tick()
        tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
    }

    func testUnchangedSaveDoesNotReload() throws {
        _ = coordinator.reloadConfig(source: "test")
        let settled = expectation(description: "initial reload callbacks")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertNil(coordinator.configError)
        var changes = 0
        var statuses = 0
        coordinator.onConfigChange = { _ in changes += 1 }
        coordinator.onConfigStatus = { _ in statuses += 1 }
        XCTAssertNil(coordinator.saveConfig(coordinator.config, baseline: coordinator.config, source: "test"))
        let after = expectation(description: "unchanged save schedules nothing")
        DispatchQueue.main.async { after.fulfill() }
        wait(for: [after], timeout: 2)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(statuses, 0)
    }

    func testMenuCheckboxAndGlobalResumePreserveSpacePreference() throws {
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let automaticTitle = "Automatically Arrange This Space"
        XCTAssertEqual(menu.items.prefix(3).map(\.title), ["Edit Layout", "", automaticTitle], "the window actions come first, then a separator")
        let automatic = try XCTUnwrap(menu.items.first { $0.title == automaticTitle })
        XCTAssertEqual(automatic.state, .on)
        _ = delegate.perform(try XCTUnwrap(automatic.action))
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first { $0.title == automaticTitle }?.state, .off)
        XCTAssertTrue(coordinator.status().currentSpaceAutoPaused)
        let arrange = try XCTUnwrap(menu.items.first { $0.title == "Arrange Now" })
        XCTAssertTrue(arrange.isEnabled)
        XCTAssertEqual(arrange.keyEquivalent, "a")
        XCTAssertEqual(arrange.keyEquivalentModifierMask, [.option, .shift])

        coordinator.pause()
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Resume LazySpace", "Settings…", "Check Windows…", "Quit LazySpace"])
        _ = delegate.perform(try XCTUnwrap(menu.items.first?.action))
        drain()
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(coordinator.status().paused)
        XCTAssertEqual(menu.items.first { $0.title == automaticTitle }?.state, .off, "Resuming the app preserves this Space's opt-out")
        XCTAssertEqual(system.writes, 0)
    }

    func testDefaultConfigHasNoModeMenuAndRefusesUndeclaredService() throws {
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertNil(coordinator.configError)
        XCTAssertEqual(coordinator.status().modes, [Config.mainModeName])
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items.contains { $0.title == StatusMenuCopy.modeTitle(Config.mainModeName) })
        XCTAssertFalse(HotkeyBinding.from(coordinator.config).contains { $0.action == .mode("service") })
        let response = delegate.handle(.init(cmd: "mode", arg: "service"))
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message.contains("service"), response.message)
        XCTAssertTrue(response.message.contains("main"), response.message)
        XCTAssertEqual(coordinator.mode, Config.mainModeName)
        XCTAssertEqual(system.writes, 0)
    }

    func testRetiredSpaceNameRuleReportsErrorAndKeepsActiveConfiguration() throws {
        let priorGap = coordinator.config.gap
        try """
        gap = 9
        [[rule]]
        app = "com.example.app"
        action = "space"
        space = "7"
        """.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let message = coordinator.reloadConfig(source: "test")
        XCTAssertNotNil(coordinator.configError, message)
        XCTAssertEqual(coordinator.config.gap, priorGap)
        XCTAssertTrue(coordinator.configNotes.isEmpty)
        XCTAssertEqual(coordinator.status().configNotes, coordinator.configNotes)
        XCTAssertTrue(message.contains("rule[0]"), message)
        XCTAssertTrue(CLI.statusText(coordinator.status()).contains("rule[0]"))
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertNil(coordinator.configError)
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertTrue(coordinator.configNotes.isEmpty)
    }

    func testDeclaredServiceIsNotPersistedAndDisappearingStickyModeReturnsToMain() throws {
        try """
        [mode.service]
        return-to-main = false
        [mode.service.keys]
        mode-main = "esc"
        """.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        XCTAssertTrue(delegate.handle(.init(cmd: "mode", arg: "service")).ok)
        XCTAssertEqual(coordinator.mode, "service")
        XCTAssertFalse(coordinator.shouldReturnToMainAfterCommand)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        XCTAssertNotNil(menu.items.first { $0.title == StatusMenuCopy.modeTitle("service") }?.submenu)
        let restarted = Coordinator(system: system, store: store, configURL: coordinator.configURL,
                                    takeCensus: system.census, takeOverview: { nil })
        _ = restarted.reloadConfig(source: "test")
        XCTAssertNotNil(restarted.config.modes["service"])
        XCTAssertEqual(restarted.mode, Config.mainModeName)
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertEqual(coordinator.mode, Config.mainModeName)
        XCTAssertNil(coordinator.config.modes["service"])
        XCTAssertEqual(system.writes, 0)
    }

    func testDeclaredServiceCommandDispatchesThenReturnsToMain() throws {
        try """
        gap = 5
        [keys]
        mode-service = "alt-shift-semicolon"
        [mode.service]
        return-to-main = true
        [mode.service.keys]
        reload = "esc"
        float = "f"
        """.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let loaded = coordinator.reloadConfig(source: "test")
        XCTAssertEqual(coordinator.config.gap, 5, loaded)
        XCTAssertNotNil(coordinator.config.modes["service"])
        XCTAssertEqual(coordinator.mode, Config.mainModeName)
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        coordinator.completeSynchronouslyForTesting = true

        let enter = try XCTUnwrap(HotkeyBinding.from(coordinator.config).first { $0.action == .mode("service") })
        XCTAssertEqual(enter.keyCode, Config.Key.parse("alt-shift-semicolon")?.keyCode)
        delegate.testingPerformHotkey(enter.action, source: "hotkey \(enter.display)")
        XCTAssertEqual(coordinator.mode, "service")
        XCTAssertTrue(coordinator.shouldReturnToMainAfterCommand)

        let service = HotkeyBinding.from(coordinator.config, mode: "service")
        let float = try XCTUnwrap(service.first { $0.action == .edit(.toggleFloat) })
        delegate.testingPerformHotkey(float.action, source: "hotkey \(float.display)")
        drain()
        XCTAssertEqual(coordinator.mode, Config.mainModeName)
        XCTAssertEqual(coordinator.state.floating["7"], [WindowID(1)])
        XCTAssertEqual(coordinator.lastResult?.kind, "edit:float")
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)

        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        delegate.testingPerformHotkey(enter.action, source: "hotkey \(enter.display)")
        XCTAssertEqual(coordinator.mode, "service")
        let reload = try XCTUnwrap(service.first { $0.action == .reload })
        delegate.testingPerformHotkey(reload.action, source: "hotkey \(reload.display)")
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertNil(coordinator.configError)
        XCTAssertEqual(coordinator.mode, Config.mainModeName)
        XCTAssertNil(coordinator.config.modes["service"])
    }

    func testDragCompletedBetweenTicksKeepsTheNewSplit() {
        prepareMouseLayout()
        let writes = system.writes
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        mouse(.leftMouseUp)
        XCTAssertFalse(coordinator.status().idle, "A drag is pending even before the next tick")
        tick()
        XCTAssertEqual(system.writes, writes, "Wait for drag geometry to settle before writing")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 1200, height: 1080))
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 1200, y: 0, width: 720, height: 1080))
        let completed = system.writes
        tick()
        XCTAssertEqual(system.writes, completed, "A completed drag must be consumed once")
    }

    func testDragWaitsForBoundsDeliveredAfterMouseUp() {
        prepareMouseLayout()
        let writes = system.writes
        mouse(.leftMouseDown)
        tick()
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        tick() // The window server still reports the old bounds.
        XCTAssertFalse(coordinator.status().idle)
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        tick()
        XCTAssertEqual(system.writes, writes)
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1200)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 720)
    }

    func testDragDoesNotWriteWhileHeldOrPaused() {
        prepareMouseLayout()
        let writes = system.writes
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(2)] = CGRect(x: 1200, y: 0, width: 720, height: 1080)
        tick()
        XCTAssertFalse(coordinator.status().idle)
        XCTAssertEqual(system.writes, writes)
        coordinator.pause()
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        tick()
        XCTAssertEqual(system.writes, writes)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 720)
    }

    /// The wobble of a close-button click counts as a drag, but if no managed window moved it does not delay refilling.
    func testClickThatMovedNoWindowDoesNotDelayRefitAfterClose() {
        prepareMouseLayout()
        system.focused = WindowID(1)
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        mouse(.leftMouseUp)
        system.frames.removeValue(forKey: WindowID(2))
        tick()
        tick()
        XCTAssertEqual(system.frames[WindowID(1)], CGRect(x: 0, y: 0, width: 1920, height: 1080), "Refit must not wait for the post-drag quiet interval")
    }

    /// After windows vanish, refit normally waits for two identical observations; windows of an app that quit are refit after one.
    func testWindowsOfExitedAppAreRefitWithoutSecondObservation() {
        prepareMouseLayout()
        system.focused = WindowID(1)
        system.frames.removeValue(forKey: WindowID(2))
        tick()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960, "An ordinary disappearance waits for a second observation")
        tick()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920)

        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 500, height: 500)
        for _ in 0..<4 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960)
        system.exitedPIDs = [1]
        system.frames.removeValue(forKey: WindowID(2))
        tick()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920, "A window whose process exited cannot come back")
    }

    /// A window that closed while automatic arrangement was unavailable, or off for this Space, leaves the layout once it is back:
    /// the observation restarts without a difference, so the departure is owed as a pending refit.
    func testWindowClosedWhileAutomaticArrangementWasOffIsRefitWhenItReturns() {
        for reason in ["stage-manager", "space-off"] {
            setUpWithErrorOrFail()
            prepareMouseLayout()
            system.focused = WindowID(1)
            if reason == "stage-manager" { system.stageManagerOn = true } else { coordinator.setCurrentSpaceAutoPaused(true) }
            system.frames.removeValue(forKey: WindowID(2))
            tick()
            tick()
            XCTAssertEqual(system.frames[WindowID(1)]?.width, 960, "\(reason): nothing is written while off")
            if reason == "stage-manager" { system.stageManagerOn = false } else { coordinator.setCurrentSpaceAutoPaused(false) }
            for _ in 0..<4 { tick() }
            XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)], reason)
            XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920, "\(reason): the gap is filled")
        }
    }

    private func setUpWithErrorOrFail() {
        drain()
        do { try tearDownWithError(); try setUpWithError() } catch { XCTFail("\(error)") }
    }

    /// Changes after dragging a managed window still wait for stillness (the drag result is adopted first).
    func testDragThatMovedAWindowStillDefersRefit() {
        prepareMouseLayout()
        system.focused = WindowID(1)
        let writes = system.writes
        mouse(.leftMouseDown)
        mouse(.leftMouseDragged)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1200, height: 1080)
        mouse(.leftMouseUp)
        system.frames[WindowID(2)] = nil
        tick()
        tick()
        XCTAssertEqual(system.writes, writes, "Wait for the drag to settle before refitting")
    }

    func testAnyWindowMovedIgnoresArrivalsAndDepartures() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(Coordinator.anyWindowMoved(from: [WindowID(1): a], to: [WindowID(1): a.offsetBy(dx: 0.5, dy: 0)], tolerance: 1))
        XCTAssertTrue(Coordinator.anyWindowMoved(from: [WindowID(1): a], to: [WindowID(1): a.insetBy(dx: 4, dy: 4)], tolerance: 1))
        XCTAssertFalse(Coordinator.anyWindowMoved(from: [WindowID(1): a], to: [WindowID(2): a.insetBy(dx: 4, dy: 4)], tolerance: 1))
        XCTAssertFalse(Coordinator.anyWindowMoved(from: [:], to: [WindowID(1): a], tolerance: 1))
    }

    /// Frames mid closing or opening animation are not rewritten; they are fixed on the next observation after they stop.
    func testDriftIsReconciledOnlyAfterFramesStopMoving() {
        prepareMouseLayout()
        let planned = system.frames[WindowID(2)]!
        let writes = system.writes
        system.frames[WindowID(2)] = planned.insetBy(dx: 4, dy: 4)
        tick()
        XCTAssertEqual(system.writes, writes, "A frame still changing between observations is not drift yet")
        system.frames[WindowID(2)] = planned.insetBy(dx: 8, dy: 8)
        tick()
        XCTAssertEqual(system.writes, writes)
        tick()
        XCTAssertGreaterThan(system.writes, writes, "A frame that stopped away from the plan is reconciled")
        XCTAssertEqual(system.frames[WindowID(2)], planned)
    }

    func testPreviewAndArrangeHonorIgnoreAndFloatRules() throws {
        for action in ["ignore", "float"] {
            try "[[rule]]\napp = \"test\"\naction = \"\(action)\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
            _ = coordinator.reloadConfig(source: "test")
            let done = expectation(description: "preview")
            coordinator.inspect { inspection in
                XCTAssertTrue(inspection.targets.isEmpty)
                XCTAssertEqual(inspection.excluded.count, 2)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            guard case .started(let id) = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
            drain()
            XCTAssertEqual(coordinator.result(id: id)?.outcome, .nothingToDo)
            XCTAssertEqual(coordinator.result(id: id)?.excluded.count, 2)
            XCTAssertEqual(system.writes, 0)
        }
    }

    func testHotkeyWhileBusyIsQueuedAndCoalescedUntilPause() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.runFocus(WindowID(2), source: "test")
        guard case .started(let first) = coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h") else {
            return XCTFail("resize was not queued")
        }
        guard case .started(let second) = coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h") else {
            return XCTFail("second resize was not queued")
        }
        XCTAssertEqual(first, second, "resizes in the same direction merge into one acceptance")
        XCTAssertEqual(coordinator.pendingUserWork, 1, "resizes in the same direction merge into one")
        coordinator.pause()
        XCTAssertEqual(coordinator.pendingUserWork, 0)
        XCTAssertEqual(coordinator.result(id: first)?.message, "Not run because all Spaces were paused.")
        coordinator.resume()
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(system.focusCalls, 0)
    }

    func testHotkeyDuringPauseIsNotQueued() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.runFocus(WindowID(2), source: "test")
        coordinator.pause()
        XCTAssertEqual(
            coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h"),
            .refused("All Spaces are paused, so the layout was not changed. Resume LazySpace, then try again.", code: "paused")
        )
        XCTAssertEqual(coordinator.pendingUserWork, 0)
        coordinator.resume()
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(system.focusCalls, 0)
    }

    func testPauseRefusalAndReloadNoticeInJapanese() throws {
        Copy.language = .japanese
        defer { Copy.language = .english }
        try "language = \"ja\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        coordinator.pause()
        let expected = "すべての操作スペースが一時停止中のため編集しません。再開してから操作してください。"
        XCTAssertEqual(coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h"), .refused(expected, code: "paused"))
        XCTAssertEqual(coordinator.pendingUserWork, 0)
        coordinator.resume()
        XCTAssertEqual(coordinator.reportReload(source: "menu"), "設定を読み込みました。ウインドウは動かしていません。")
        coordinator.noteRefusal(expected)
        XCTAssertEqual(coordinator.status().lastRefusal, expected)
        XCTAssertEqual(system.writes, 0)
    }

    func testCoalescedResizeAppliesTheSummedDelta() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.runFocus(WindowID(2), source: "test")
        guard case .started(let ticket) = coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h") else {
            return XCTFail("resize was not queued")
        }
        guard case .started(let again) = coordinator.edit(.resize(.horizontal, 0.05), source: "hotkey h") else {
            return XCTFail("second resize was not queued")
        }
        XCTAssertEqual(ticket, again)
        coordinator.operationsQueue.resume()
        var result: OperationResult?
        for _ in 0..<6 {
            drain()
            result = coordinator.result(id: ticket)
            if result?.kind == "edit:resize" { break }
        }
        XCTAssertEqual(result?.kind, "edit:resize")
        XCTAssertEqual(result?.outcome, .complete, result?.message ?? "")
        // Adding 0.05 to 0.5 twice gives 0.6; once gives 0.55 (width 1056), which stays under 1100.
        XCTAssertGreaterThan(system.frames[WindowID(2)]?.width ?? 0, 1100)
    }

    func testQueuedIntegrateKeepsItsKind() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.runFocus(WindowID(2), source: "test")
        guard case .started(let ticket) = coordinator.integrateWaiting(source: "menu") else {
            return XCTFail("integrate was not queued")
        }
        coordinator.operationsQueue.resume()
        var result: OperationResult?
        for _ in 0..<6 {
            drain()
            result = coordinator.result(id: ticket)
            if result != nil { break }
        }
        XCTAssertEqual(result?.kind, "integrate-waiting")
    }

    func testFocusReservesOperationSlotAndPauseCancelsQueuedWork() {
        coordinator.operationsQueue.suspend()
        let accept = coordinator.runFocus(WindowID(2), source: "test")
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.arrange(source: "test"), .busy)
        XCTAssertEqual(coordinator.edit(.close, source: "test"), .busy)
        coordinator.pause()
        coordinator.resume()
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(system.focusCalls, 0)
        XCTAssertFalse(coordinator.isBusy)
        guard case .started(let id) = accept else { return XCTFail("Focus refused") }
        XCTAssertEqual(coordinator.result(id: id)?.stopReason, .paused)
    }

    func testCloseReservesOperationSlotAndPauseCancelsQueuedWork() {
        coordinator.operationsQueue.suspend()
        _ = coordinator.edit(.close, source: "test")
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.runFocus(WindowID(2), source: "test"), .busy)
        XCTAssertEqual(coordinator.arrange(source: "test"), .busy)
        coordinator.pause()
        coordinator.resume()
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(system.closeCalls, 0)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testFailedFloatAndZoomDoNotPersistProposedState() {
        let initial = coordinator.state.layouts["7"]
        system.trusted = false
        for command in [EditCommand.toggleFloat, .toggleZoom] {
            _ = coordinator.edit(command, source: "test")
            drain()
            XCTAssertEqual(coordinator.state.layouts["7"], initial)
            XCTAssertNil(coordinator.state.floating["7"])
            XCTAssertNil(coordinator.state.zoomed["7"])
            XCTAssertNil(store.load().zoomed["7"])
            XCTAssertNil(store.load().floating["7"])
        }
        XCTAssertEqual(system.writes, 0)
    }

    func testSuccessfulZoomTogglePersistsAndRestoresLayout() {
        let layout = coordinator.state.layouts["7"]
        _ = coordinator.edit(.toggleZoom, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.zoomed["7"], WindowID(1))
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920)
        _ = coordinator.edit(.toggleZoom, source: "test")
        drain()
        XCTAssertNil(coordinator.state.zoomed["7"])
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(coordinator.state.layouts["7"], layout)
    }

    func testResumeCannotRestoreQueuedLayoutOrZoom() {
        let prior = coordinator.state.layouts["7"]
        coordinator.operationsQueue.suspend()
        _ = coordinator.edit(.toggleZoom, source: "test")
        coordinator.pause()
        coordinator.resume()
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"], prior)
        XCTAssertNil(coordinator.state.zoomed["7"])
        XCTAssertEqual(store.load().layouts["7"], prior)
        XCTAssertEqual(system.writes, 0)
    }

    func testResumeKeepsManagedLayoutAndDoesNotMoveWindows() {
        let prior = coordinator.state.layouts["7"]
        let before = system.frames
        coordinator.pause()
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 640, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 640, y: 0, width: 1280, height: 1080)
        coordinator.resume()
        drain()
        XCTAssertFalse(coordinator.status().paused)
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.frames, [
            WindowID(1): CGRect(x: 0, y: 0, width: 640, height: 1080),
            WindowID(2): CGRect(x: 640, y: 0, width: 1280, height: 1080),
        ])
        XCTAssertNotEqual(before, system.frames)
        guard case .split(.horizontal, _, let ratios)? = coordinator.state.layouts["7"]?.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 640 / 1920, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 1280 / 1920, accuracy: 1e-9)
        XCTAssertNotEqual(coordinator.state.layouts["7"], prior)
        XCTAssertTrue(coordinator.status().currentSpaceManaged)
    }

    func testResumePrunesGoneWindowsAndWaitsForArrivals() {
        system.frames[WindowID(2)] = nil
        system.frames[WindowID(3)] = CGRect(x: 200, y: 200, width: 400, height: 400)
        coordinator.pause()
        coordinator.resume()
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertFalse(coordinator.waiting.contains(WindowID(3)))
        XCTAssertEqual(system.writes, 0)
    }

    func testResumeKeepsPauseAndLayoutWhenObservationIsUncertain() {
        let prior = coordinator.state.layouts["7"]
        for failure in ["permission", "space", "input", "unknown-kind"] {
            coordinator.pause()
            system.trusted = true
            system.space = 7
            system.kind = .standard
            system.onSnapshot = {
                switch failure {
                case "permission": self.system.trusted = false
                case "space": self.system.space = 8
                case "input": self.system.inputActivityCount += 1
                default: self.system.kind = .unknownRole
                }
            }
            XCTAssertNotNil(coordinator.resume(), failure)
            system.onSnapshot = nil
            drain()
            XCTAssertTrue(coordinator.control.paused, failure)
            XCTAssertTrue(store.load().paused, failure)
            XCTAssertEqual(coordinator.state.layouts["7"], prior, failure)
            XCTAssertEqual(store.load().layouts["7"], prior, failure)
            XCTAssertEqual(system.writes, 0)
            XCTAssertEqual(system.focusCalls, 0)
        }
    }

    func testResumeDoesNotPruneWindowsMissingOnlyFromAX() {
        let prior = coordinator.state.layouts["7"]
        for listUnavailable in [false, true] {
            coordinator.pause()
            system.hiddenFromScopedSnapshots = [WindowID(2)]
            system.windowListUnavailable = listUnavailable
            XCTAssertNotNil(coordinator.resume())
            XCTAssertTrue(coordinator.control.paused)
            XCTAssertEqual(coordinator.state.layouts["7"], prior)
        }
    }

    /// A window confirmed to have moved to one other Space while paused (including entering full screen) does not block resuming.
    /// It no longer appears in the app's AX list but stays in the full window list.
    func testResumePrunesWindowsConfirmedOnAnotherSpace() {
        coordinator.pause()
        system.hiddenSpaces = true
        system.spaceOf = [WindowID(1): 7, WindowID(2): 8]
        XCTAssertNil(coordinator.resume())
        drain()
        XCTAssertFalse(coordinator.control.paused)
        XCTAssertFalse(store.load().paused)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertEqual(system.writes, 0)
        XCTAssertEqual(system.focusCalls, 0)
    }

    /// A window with undecided membership (also on this Space, several Spaces, unreadable) is not treated as moved.
    func testResumeKeepsPauseWhenAMissingWindowIsNotConfirmedElsewhere() {
        let prior = coordinator.state.layouts["7"]
        system.hiddenSpaces = true
        system.hiddenFromScopedSnapshots = [WindowID(2)]
        for reported in [[7], [7, 8], []] as [[UInt64]] {
            coordinator.pause()
            system.reportedSpaces[WindowID(2)] = reported
            XCTAssertNotNil(coordinator.resume(), "\(reported)")
            XCTAssertTrue(coordinator.control.paused, "\(reported)")
            XCTAssertEqual(coordinator.state.layouts["7"], prior, "\(reported)")
        }
    }

    /// Waiting windows belong to their Space; after moving to another Space they are not kept in the menu or status.
    func testWaitingWindowsAreNotCarriedToAnotherSpace() {
        tick()
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        coordinator.parkWaiting([WindowID(3)])
        XCTAssertEqual(coordinator.status().waiting, [WindowID(3)])
        system.space = 8
        tick()
        XCTAssertEqual(coordinator.status().waiting, [])
    }

    /// Returning to a Space with automatic arrangement off, its waiting windows are still there (manual "add one" works).
    func testWaitingWindowsComeBackWithTheirSpace() {
        tick()
        coordinator.setCurrentSpaceAutoPaused(true)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        coordinator.parkWaiting([WindowID(3)])
        system.space = 8
        tick()
        XCTAssertEqual(coordinator.status().waiting, [])
        system.space = 7
        tick()
        XCTAssertEqual(coordinator.status().waiting, [WindowID(3)])
    }

    /// A waiting window confirmed to have moved to one other Space leaves the waiting list, even from a source Space with automatic arrangement off; so does a placed one.
    func testWaitingWindowsLeaveTheListWhenMovedOrPlaced() {
        tick()
        coordinator.setCurrentSpaceAutoPaused(true)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 200, y: 200, width: 400, height: 300)
        coordinator.parkWaiting([WindowID(3), WindowID(4)])
        system.hiddenSpaces = true
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 8, WindowID(4): 7]
        for _ in 0..<3 { tick() }
        XCTAssertEqual(coordinator.status().waiting, [WindowID(4)], "the window confirmed on Space 8 no longer waits on Space 7")
        drain()
        var saved = store.load()
        saved.layouts["7"] = Planner.rowLayout([WindowID(1), WindowID(2), WindowID(4)], rows: 1)
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.parkWaiting([WindowID(4)])
        XCTAssertEqual(coordinator.status().waiting, [WindowID(4)])
        for _ in 0..<3 { tick() }
        XCTAssertEqual(coordinator.status().waiting, [], "a window already in the layout no longer waits")
    }

    func testResumeWithoutAccessSaysToAllowAccess() {
        coordinator.pause()
        system.trusted = false
        XCTAssertTrue(coordinator.resume()?.contains("not allowed in") == true)
        XCTAssertTrue(coordinator.control.paused)
    }

    func testResumeBoundsUnresponsiveAppObservationAndKeepsPause() {
        coordinator.pause()
        let prior = coordinator.state.layouts["7"]
        system.pids[WindowID(2)] = 42
        system.blockingPIDs[42] = 3
        let started = Date()
        let refusal = coordinator.resume()
        XCTAssertTrue(refusal?.contains("did not respond") == true, "names the app instead of only asking to try again: \(refusal ?? "")")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertLessThanOrEqual(system.boundedReadBudgets.last ?? 99, 0.5)
        XCTAssertTrue(coordinator.control.paused)
        XCTAssertEqual(coordinator.state.layouts["7"], prior)
        XCTAssertEqual(system.writes, 0)
    }

    func testUndoFailurePreservesLayoutAndHistoryForRetry() {
        let initial = coordinator.state.layouts["7"]
        _ = coordinator.edit(.swap(.right), source: "test")
        drain()
        let swapped = coordinator.state.layouts["7"]
        XCTAssertNotEqual(swapped, initial)
        system.trusted = false
        _ = coordinator.edit(.undo, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"], swapped)
        system.trusted = true
        _ = coordinator.edit(.undo, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"], initial)
    }

    func testFloatKeepsLeftoverHeightAndUnfloatUsesIt() {
        let a = WindowID(1)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
            leftoverHeights: [a: 440]
        )
        var saved = store.load()
        saved.layouts["7"] = prior
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames[a] = CGRect(x: 0, y: 0, width: 960, height: 440)
        system.frames[WindowID(2)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.floating["7"], [a])
        XCTAssertEqual(coordinator.state.layouts["7"]?.leftoverHeights[a], 440)
        XCTAssertFalse(coordinator.state.layouts["7"]?.windowIDs.contains(a) ?? true)
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        XCTAssertNil(coordinator.state.floating["7"])
        XCTAssertNil(coordinator.state.floatHomes["7"])
        XCTAssertEqual(coordinator.state.layouts["7"]?.leftoverHeights[a], 440)
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(WindowID(2))])
        XCTAssertEqual(system.frames[a]?.minX, 0)
        XCTAssertEqual(system.frames[a]?.height, 440)
        XCTAssertEqual(system.frames[WindowID(2)]?.minX, 960)
    }

    func testNewWindowWhileFloatingFillsTheGapTheFloatedWindowLeft() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames = [
            a: CGRect(x: 0, y: 0, width: 640, height: 1080),
            b: CGRect(x: 640, y: 0, width: 640, height: 1080),
            c: CGRect(x: 1280, y: 0, width: 640, height: 1080),
        ]
        system.focused = b
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        system.frames[d] = CGRect(x: 200, y: 200, width: 400, height: 400)
        _ = coordinator.integrateForeground([d], beside: nil, inPlaceOf: b)
        drain()
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(a), .leaf(d), .leaf(c)])
        XCTAssertEqual(coordinator.state.floating["7"], [b])
    }

    func testUnfloatKeepsASwapMadeWhileFloating() {
        let a = WindowID(1), b = WindowID(2), c = WindowID(3)
        let prior = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b), .leaf(c)], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        var saved = store.load()
        saved.layouts["7"] = prior
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames = [
            a: CGRect(x: 0, y: 0, width: 640, height: 1080),
            b: CGRect(x: 640, y: 0, width: 640, height: 1080),
            c: CGRect(x: 1280, y: 0, width: 640, height: 1080),
        ]
        system.focused = b
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        system.focused = a
        _ = coordinator.edit(.swap(.right), source: "test")
        drain()
        system.focused = b
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return XCTFail() }
        XCTAssertEqual(children, [.leaf(c), .leaf(a), .leaf(b)])
    }

    func testVerticalResizeGrowsPastTheLeftoverHeight() {
        let b = WindowID(2)
        let prior = Layout(
            root: .split(.vertical, children: [.leaf(WindowID(1)), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [b: 400]
        )
        var saved = store.load()
        saved.layouts["7"] = prior
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1920, height: 680)
        system.frames[b] = CGRect(x: 0, y: 680, width: 1920, height: 400)
        system.focused = b
        _ = coordinator.edit(.resize(.vertical, 0.1), source: "test")
        drain()
        XCTAssertEqual(system.frames[b]?.height, 648)
        XCTAssertNotEqual(coordinator.state.layouts["7"]?.leftoverHeights[b], 400)
    }

    func testUndoAfterJoinRestoresLeftoverHeight() {
        let a = WindowID(1)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(WindowID(2))], ratios: [0.5, 0.5]),
            leftoverHeights: [a: 440]
        )
        var saved = store.load()
        saved.layouts["7"] = prior
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames[a] = CGRect(x: 0, y: 0, width: 960, height: 440)
        system.frames[WindowID(2)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        _ = coordinator.edit(.join(.right), source: "test")
        drain()
        XCTAssertNotEqual(coordinator.state.layouts["7"]?.leftoverHeights[a], 440)
        _ = coordinator.edit(.undo, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.leftoverHeights[a], 440)
        XCTAssertEqual(system.frames[a]?.height, 440)
    }

    func testFloatingLastWindowCanBeReversed() {
        system.frames[WindowID(2)] = nil
        _ = coordinator.arrange(source: "test")
        drain()
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        XCTAssertEqual(coordinator.state.floating["7"], [WindowID(1)])
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [])
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        XCTAssertNil(coordinator.state.floating["7"])
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    func testWindowStateQueuedBeforePauseResumeDoesNotExecute() {
        for command in [EditCommand.fullscreen, .minimize] {
            coordinator.operationsQueue.suspend()
            _ = coordinator.edit(command, source: "test")
            coordinator.pause()
            coordinator.resume()
            coordinator.operationsQueue.resume()
            drain()
        }
        XCTAssertEqual(system.stateCalls, 0)
    }

    func testWindowStateQueuedBeforeSpaceChangeOrInputDoesNotExecute() {
        for input in [false, true] {
            coordinator.operationsQueue.suspend()
            _ = coordinator.edit(.minimize, source: "test")
            if input { system.inputActivityCount += 1 } else { system.space = 8 }
            coordinator.operationsQueue.resume()
            drain()
        }
        XCTAssertEqual(system.stateCalls, 0)
    }

    func testWindowStateRejectsUntrustedOrExcludedTargets() {
        system.trusted = false
        _ = coordinator.edit(.fullscreen, source: "test")
        drain()
        system.trusted = true
        system.kind = .dialog
        _ = coordinator.edit(.minimize, source: "test")
        drain()
        system.kind = .standard
        system.membership = .other
        _ = coordinator.edit(.fullscreen, source: "test")
        drain()
        XCTAssertEqual(system.stateCalls, 0)
    }

    /// On a full-screen Space, the app's AX focused window may point at a window left on the original Space (seen with TextEdit).
    /// Then the front window by CGWindowList order is the target, and the window on the other Space is not touched.
    func testWindowStateTargetsVisibleFrontWindowWhenAXFocusIsOnAnotherSpace() {
        system.focused = WindowID(9) // not visible on this Space
        system.frontWindow = WindowID(1)
        system.kind = .fullscreen
        guard case .started(let id) = coordinator.edit(.fullscreen, source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(system.stateCalls, 1)
        XCTAssertEqual(coordinator.result(id: id)?.outcome, .complete)
    }

    func testWindowStateRequestWithoutReadbackIsNotComplete() {
        system.changesState = false
        guard case .started(let id) = coordinator.edit(.fullscreen, source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertNotEqual(coordinator.result(id: id)?.outcome, .complete)
    }
    func testWindowStateRequiresInitialReadAndVerifiesChangedState() {
        system.windowState = nil
        _ = coordinator.edit(.minimize, source: "test")
        drain()
        XCTAssertEqual(system.stateCalls, 0)
        system.windowState = false
        guard case .started(let id) = coordinator.edit(.minimize, source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(system.stateCalls, 1)
        XCTAssertEqual(coordinator.result(id: id)?.outcome, .complete)
        XCTAssertEqual(coordinator.result(id: id)?.verified, true)
    }

    private func dropLayout() {
        var saved = store.load()
        saved.layouts = [:]
        saved.zoomed = [:]
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
    }

    private func prepareAutoStart() throws -> Census {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let current = system.census(7)
        var previous = current; previous.windows[WindowID(1)] = nil
        coordinator.armAutomaticStart(previous: previous, current: current, spaceKey: "7")
        return current
    }

    /// Input that outlasts the automatic start's deadline only postpones it: the next observation prepares it again with the same front window.
    func testAutomaticStartIsPreparedAgainAfterItsDeadline() throws {
        let current = try prepareAutoStart()
        // Prepared again with a short deadline (turning the Space off and on forgets the earlier preparation).
        coordinator.setCurrentSpaceAutoPaused(true)
        coordinator.setCurrentSpaceAutoPaused(false)
        coordinator.autoStartWindow = 0.05
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true), "expired")
        coordinator.autoStartWindow = 10
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true), "prepared again")
        drain()
        XCTAssertNotNil(coordinator.state.layouts["7"])
    }

    func testAutomaticStartIncludesAcceptedWindowsButNotLaterArrivals() throws {
        let current = try prepareAutoStart()
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: false))
        coordinator.operationsQueue.suspend()
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        system.frames[WindowID(3)] = CGRect(x: 400, y: 400, width: 600, height: 400)
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)])
        XCTAssertEqual(system.frames[WindowID(3)], CGRect(x: 400, y: 400, width: 600, height: 400))
    }

    func testAutomaticStartIsCancelledByFocusPauseOrOptOut() throws {
        for reason in ["focus", "pause", "opt-out", "space"] {
            var current = try prepareAutoStart()
            switch reason {
            case "focus": current.frontWindow = WindowID(2)
            case "pause": coordinator.pause(); coordinator.resume(); drain()
            case "space": system.space = 8
            default: coordinator.setCurrentSpaceAutoPaused(true) // automatic arrangement turned off for this Space
            }
            XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true), reason)
            drain()
            XCTAssertEqual(system.writes, 0, reason)
            system.space = 7
            coordinator.setCurrentSpaceAutoPaused(false)
        }
    }

    /// A window appearing with an app launch (Dock, Spotlight, `open`) is the typical way to open a second window on a new Space,
    /// so even if the front app changed, a window it just opened qualifies for the automatic start.
    /// Once the front window is confirmed not to qualify, it is not reread while the front and window stay the same; a failed read is retried next time.
    func testAutomaticStartRemembersOnlyAConfirmedDecline() throws {
        dropLayout()
        let current = system.census(7)
        system.kindOf[WindowID(1)] = .unknownRole
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        system.kindOf[WindowID(1)] = nil
        let reads = system.snapshotCount
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertEqual(system.snapshotCount, reads + 1, "an unreadable front window is read again")

        dropLayout()
        system.kindOf[WindowID(1)] = .dialog
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        let afterDecline = system.snapshotCount
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertEqual(system.snapshotCount, afterDecline, "a confirmed fixed-size front window is not read again")
        system.kindOf[WindowID(1)] = nil
    }

    func testAutomaticStartAcceptsWindowShownTogetherWithAppLaunch() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let current = system.census(7)
        var previous = current; previous.windows[WindowID(1)] = nil; previous.frontmostPID = 2
        coordinator.armAutomaticStart(previous: previous, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)])
    }

    /// The launch observation has no difference; two existing windows can still start automatically.
    func testLaunchCensusStartsAnOccupiedSpace() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(2)] = CGRect(x: 400, y: 200, width: 500, height: 400)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)])
        XCTAssertGreaterThan(system.writes, 0)
        XCTAssertEqual(system.frames[WindowID(2)]?.minX, 960)
    }

    /// The automatic start tiles every visible standard window.
    func testAutomaticStartTilesEveryVisibleWindow() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 400, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 800, y: 500, width: 420, height: 320)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [])
    }

    /// The automatic start tiles every visible standard window, not just the front two.
    func testAutomaticStartTilesEveryStandardWindow() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 400, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 800, y: 500, width: 420, height: 320)
        coordinator.noteFront(WindowID(4), spaceKey: "7")
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [])
    }

    /// Arranging from the menu targets every current standard window.
    func testExplicitArrangeStillTilesEveryStandardWindow() throws {
        dropLayout()
        system.frames[WindowID(3)] = CGRect(x: 100, y: 400, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 800, y: 500, width: 420, height: 320)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3), WindowID(4)])
    }

    /// A first arrangement that does not fit one row still includes every visible standard window.
    func testCrowdedFirstArrangeTilesEveryWindow() throws {
        dropLayout()
        system.area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 1512, height: 949)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 33, width: 1512, height: 949)
        var kept: [WindowID: CGRect] = [:]
        for n in 3...8 {
            let id = WindowID(UInt32(n))
            let frame = CGRect(x: 40 * n, y: 80 * n, width: 420, height: 320)
            system.frames[id] = frame
            kept[id] = frame
        }
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), Set((1...8).map { WindowID(UInt32($0)) }))
        XCTAssertEqual(coordinator.waiting, [])
        XCTAssertFalse(coordinator.lastResult?.message.lowercased().contains("rebuil") == true)
    }

    /// One window per integration. Even below the preferred width, the current row is not rebuilt.
    func testIntegrateWaitingKeepsTheRowWhenTheShareDropsBelowThePreferredWidth() throws {
        dropLayout()
        system.area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let third = 1512.0 / 3
        for (n, x) in [(1, 0.0), (2, third), (3, third * 2)] {
            system.frames[WindowID(UInt32(n))] = CGRect(x: x, y: 33, width: third, height: 949)
        }
        let parked = CGRect(x: 40, y: 80, width: 420, height: 320)
        system.frames[WindowID(4)] = parked
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.parkWaiting([WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [WindowID(4)])
        guard case .started = coordinator.integrateWaiting(source: "test") else { return XCTFail("integrate refused") }
        drain()
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return XCTFail("row was rebuilt") }
        XCTAssertEqual(children.count, 4)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 378)
        XCTAssertEqual(system.frames[WindowID(4)]?.width, 378)
        XCTAssertEqual(system.frames[WindowID(1)]?.height, 949)
        XCTAssertEqual(coordinator.waiting, [])
        XCTAssertEqual(coordinator.lastResult?.message.contains("Added 1 window to the layout."), true)
        XCTAssertFalse(coordinator.lastResult?.message.lowercased().contains("rebuil") == true)
    }

    /// A window opened in front does not discard the tree when insertion beside drops below the preferred width.
    func testForegroundArrivalKeepsTheRowBelowThePreferredWidth() throws {
        dropLayout()
        system.area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let third = 1512.0 / 3
        for (n, x) in [(1, 0.0), (2, third), (3, third * 2)] {
            system.frames[WindowID(UInt32(n))] = CGRect(x: x, y: 33, width: third, height: 949)
        }
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3))], ratios: [1.0 / 3, 1.0 / 3, 1.0 / 3]))
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.frames[WindowID(4)] = CGRect(x: 40, y: 80, width: 420, height: 320)
        guard case .started = coordinator.integrateForeground([WindowID(4)], beside: WindowID(1)) else { return XCTFail("foreground integrate refused") }
        drain()
        guard case .split(.horizontal, let children, _)? = coordinator.state.layouts["7"]?.root else { return XCTFail("row was rebuilt") }
        XCTAssertEqual(children, [.leaf(WindowID(1)), .leaf(WindowID(4)), .leaf(WindowID(2)), .leaf(WindowID(3))])
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 378)
        XCTAssertEqual(system.frames[WindowID(1)]?.height, 949)
        XCTAssertFalse(coordinator.lastResult?.message.lowercased().contains("rebuil") == true)
    }

    /// Background windows join beside the focused window by the same rule.
    func testBackgroundWindowJoinsBesideTheFocusedWindow() throws {
        dropLayout()
        system.area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 756, height: 949)
        system.frames[WindowID(2)] = CGRect(x: 756, y: 33, width: 756, height: 949)
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        system.focused = WindowID(1)
        let arrived = CGRect(x: 80, y: 200, width: 420, height: 320)
        system.frames[WindowID(5)] = arrived
        coordinator.integrateProtected([WindowID(5)])
        drain()
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 504)
        XCTAssertEqual(system.frames[WindowID(5)]?.width, 504)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 504)
        XCTAssertEqual(system.frames[WindowID(1)]?.height, 949)
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(5)) == true)
        XCTAssertFalse(coordinator.waiting.contains(WindowID(5)))
    }

    /// A background window below the preferred width still joins beside the focused row.
    func testBackgroundWindowTilesEvenWhenTheShareMissesThePreferredMinimum() throws {
        let height = 949.0 / 2
        system.area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let frames: [WindowID: CGRect] = [
            WindowID(1): CGRect(x: 0, y: 33, width: 756, height: height),
            WindowID(2): CGRect(x: 756, y: 33, width: 756, height: height),
            WindowID(3): CGRect(x: 0, y: 33 + height, width: 756, height: height),
            WindowID(4): CGRect(x: 756, y: 33 + height, width: 756, height: height),
        ]
        system.frames = frames
        let row: (WindowID, WindowID) -> LayoutNode = { a, b in
            .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5])
        }
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.vertical, children: [row(WindowID(1), WindowID(2)), row(WindowID(3), WindowID(4))], ratios: [0.5, 0.5]))
        store.save(saved)
        let loaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        loaded.limits.settleDelay = 0
        system.focused = WindowID(1)
        let arrived = CGRect(x: 80, y: 200, width: 420, height: 320)
        system.frames[WindowID(5)] = arrived
        loaded.integrateProtected([WindowID(5)])
        let done = expectation(description: "background integrate drained")
        loaded.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(loaded.waiting.contains(WindowID(5)))
        XCTAssertTrue(loaded.state.layouts["7"]?.windowIDs.contains(WindowID(5)) == true)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 504)
        XCTAssertEqual(system.frames[WindowID(3)], frames[WindowID(3)])
        XCTAssertEqual(system.frames[WindowID(4)], frames[WindowID(4)])
    }

    /// A focused waiting window is added before the head of the list.
    func testIntegrateWaitingPrefersTheFocusedWaitingWindow() {
        let kept = CGRect(x: 100, y: 100, width: 400, height: 300)
        system.frames[WindowID(3)] = kept
        system.frames[WindowID(4)] = CGRect(x: 200, y: 200, width: 400, height: 300)
        coordinator.parkWaiting([WindowID(3), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [WindowID(3), WindowID(4)])
        system.focused = WindowID(4)
        guard case .started = coordinator.integrateWaiting(source: "test") else { return XCTFail("integrate refused") }
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [WindowID(3)])
        XCTAssertEqual(system.frames[WindowID(3)], kept)
    }

    /// An already narrow column is not rebuilt if the added window fits the preferred width.
    func testIntegrateWaitingKeepsANarrowColumnWhenTheNewWindowFits() throws {
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [230.0 / 1920.0, 1690.0 / 1920.0]))
        saved.sizeFacts = []
        store.save(saved)
        let loaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        loaded.limits.settleDelay = 0
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 230, height: 408)
        system.frames[WindowID(2)] = CGRect(x: 230, y: 0, width: 1690, height: 1080)
        let parked = CGRect(x: 400, y: 40, width: 400, height: 400)
        system.frames[WindowID(4)] = parked
        loaded.parkWaiting([WindowID(4)])
        XCTAssertEqual(loaded.waiting, [WindowID(4)])
        guard case .started = loaded.integrateWaiting(source: "test") else { return XCTFail("integrate refused") }
        let done = expectation(description: "narrow integrate drained")
        loaded.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(Double(system.frames[WindowID(1)]?.width ?? 0), 230.0 * 2.0 / 3.0, accuracy: 1)
        XCTAssertEqual(loaded.waiting, [])
        XCTAssertTrue(loaded.state.layouts["7"]?.windowIDs.contains(WindowID(4)) == true)
        guard case .split(.horizontal, _, _)? = loaded.state.layouts["7"]?.root else { return XCTFail("row was rebuilt") }
    }

    /// With automatic start on, an unstarted Space starts with one standard window, which fills the work area.
    func testAutoStartBeginsWithOneWindowAndFills() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames = [WindowID(1): CGRect(x: 80, y: 60, width: 640, height: 440)]
        system.focused = WindowID(1)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        guard case .leaf(WindowID(1))? = coordinator.state.layouts["7"]?.root else {
            return XCTFail("one window should be a single leaf")
        }
        XCTAssertEqual(system.frames[WindowID(1)], system.area.integralInset)
        XCTAssertEqual(coordinator.lastResult?.kind, "auto-start")
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
    }

    /// A Space just arrived on, or passed through by key, does not start arranging its existing windows.
    func testAutoStartWaitsUntilTheSpaceHasBeenCurrentForAWhile() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames = [WindowID(1): CGRect(x: 80, y: 60, width: 640, height: 440)]
        system.focused = WindowID(1)
        let current = system.census(7)
        coordinator.noteSpaceArrival(at: Date())
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(system.writes, 0)
        XCTAssertNil(coordinator.state.layouts["7"])
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-coordinator.arrivalDwell - 0.1))
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    /// Even if observed bounds differ from AX frames, a correction that wrote nothing is not repeated.
    func testNoopReconcileIsNotRepeatedWhileBoundsStayTheSame() {
        guard case .started = coordinator.arrange(source: "cli") else { return XCTFail("arrange should start") }
        drain()
        let layout = coordinator.state.layouts["7"]!
        system.censusBounds[WindowID(1)] = system.frames[WindowID(1)]!.offsetBy(dx: 0, dy: 3)
        let writes = system.writes
        var starts = 0
        for _ in 0..<10 {
            if coordinator.reconcileDrift(current: system.census(7), spaceKey: "7", layout: layout, managed: Set(layout.windowIDs)) { starts += 1 }
            drain()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(system.writes, writes)
        // Once the window actually moves, correction can run again.
        system.frames[WindowID(1)] = CGRect(x: 100, y: 100, width: 500, height: 500)
        system.censusBounds = [:]
        XCTAssertTrue(coordinator.reconcileDrift(current: system.census(7), spaceKey: "7", layout: layout, managed: Set(layout.windowIDs)))
        drain()
    }

    /// A single dialog-like window does not start, even with automatic start on.
    func testAutoStartIgnoresNonStandardSoloWindow() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames = [WindowID(1): CGRect(x: 80, y: 60, width: 640, height: 440)]
        system.focused = WindowID(1)
        system.kind = .dialog
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        XCTAssertNil(coordinator.state.layouts["7"])
        XCTAssertEqual(system.writes, 0)
    }

    /// A single window matching an exclusion rule does not start, even with automatic start on.
    func testAutoStartIgnoresRuledSoloWindow() throws {
        dropLayout()
        try "[[rule]]\napp = \"test\"\naction = \"ignore\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames = [WindowID(1): CGRect(x: 80, y: 60, width: 640, height: 440)]
        system.focused = WindowID(1)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        XCTAssertNil(coordinator.state.layouts["7"])
        XCTAssertEqual(system.writes, 0)
    }

    /// An arrival where the automatic start could not write is not retried with the same observation.
    func testRefusedAutomaticStartDoesNotRearm() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(2)] = CGRect(x: 400, y: 200, width: 500, height: 400)
        system.refusedWrites = [WindowID(1), WindowID(2)]
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        let writesAfter = system.writes
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: false))
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(system.writes, writesAfter)
        XCTAssertNil(coordinator.state.layouts["7"])
    }

    /// When the partner window leaves, the rest are rearranged even with the same front window.
    func testAutomaticStartRetriesAfterThePartnerLeaves() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 400, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 800, y: 500, width: 420, height: 320)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        system.frames[WindowID(2)] = nil
        let next = system.census(7)
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: next, spaceKey: "7", quiet: true))
        coordinator.armAutomaticStart(previous: next, current: next, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: next, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(3), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [])
    }

    /// When the front moves to another window, the automatic start is retried with it.
    func testAutomaticStartRetriesWhenFocusMoves() throws {
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 400, width: 400, height: 300)
        system.frames[WindowID(4)] = CGRect(x: 800, y: 500, width: 420, height: 320)
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        system.focused = WindowID(3)
        let moved = system.census(7)
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: moved, spaceKey: "7", quiet: true))
        coordinator.armAutomaticStart(previous: moved, current: moved, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: moved, spaceKey: "7", quiet: true))
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3), WindowID(4)])
    }

    /// Standard windows arriving from leaving full screen or from another display join the arrived Space's layout; floating windows stay floating.
    func testArrivalOnAManagedSpaceTilesTheIncomingWindows() {
        let kept = CGRect(x: 80, y: 120, width: 420, height: 320)
        system.frames[WindowID(3)] = CGRect(x: 40, y: 80, width: 500, height: 400)
        system.frames[WindowID(4)] = kept
        var saved = store.load()
        saved.floating["7"] = [WindowID(4)]
        store.save(saved)
        coordinator = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        coordinator.parkWaiting([WindowID(3)])
        coordinator.arrivedOnRebase(current: system.census(7), spaceKey: "7")
        drain()
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
        XCTAssertFalse(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(4)) == true)
        XCTAssertEqual(coordinator.waiting, [])
        XCTAssertEqual(system.frames[WindowID(4)], kept)
    }

    /// A user-requested arrangement includes waiting windows.
    func testExplicitArrangeIncludesWaitingWindows() {
        system.frames[WindowID(3)] = CGRect(x: 40, y: 80, width: 500, height: 400)
        coordinator.parkWaiting([WindowID(3)])
        guard case .started = coordinator.arrange(source: "menu") else { return XCTFail("arrange refused") }
        drain()
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
        XCTAssertEqual(coordinator.waiting, [])
    }

    /// Pausing one Space keeps automatic arrangement on other Spaces and manual arrangement on the paused one.
    func testPausingOneSpaceLeavesTheOthersAndManualArrange() {
        system.frames[WindowID(3)] = CGRect(x: 40, y: 80, width: 500, height: 400)
        coordinator.setCurrentSpaceAutoPaused(true)
        XCTAssertTrue(coordinator.status().currentSpaceAutoPaused)
        coordinator.arrivedOnRebase(current: system.census(7), spaceKey: "7")
        drain()
        XCTAssertEqual(system.writes, 0)
        XCTAssertFalse(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)
        guard case .started = coordinator.arrange(source: "menu") else { return XCTFail("manual arrange refused") }
        drain()
        XCTAssertTrue(coordinator.state.layouts["7"]?.windowIDs.contains(WindowID(3)) == true)

        system.space = 8
        coordinator.setCurrentSpaceAutoPaused(true)
        system.space = 7
        coordinator.setCurrentSpaceAutoPaused(false)
        XCTAssertFalse(coordinator.status().currentSpaceAutoPaused)
        XCTAssertEqual(coordinator.state.pausedSpaces, ["8"])
        let reloaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        XCTAssertEqual(reloaded.state.pausedSpaces, ["8"])
    }

    /// Turning automatic arrangement off and on again allows the automatic start to retry with the same windows (also when a pending start was cancelled).
    func testReenablingASpaceRetriesTheAutomaticStart() throws {
        let current = try prepareAutoStart()
        coordinator.setCurrentSpaceAutoPaused(true)
        coordinator.setCurrentSpaceAutoPaused(false)
        drain()
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        coordinator.operationsQueue.suspend()
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true), "armed again after re-enabling")
        coordinator.setCurrentSpaceAutoPaused(true) // cancel the pending start
        coordinator.operationsQueue.resume()
        drain()
        XCTAssertNil(coordinator.state.layouts["7"])
        coordinator.setCurrentSpaceAutoPaused(false)
        drain()
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true), "armed again after a canceled start")
        drain()
        XCTAssertNotNil(coordinator.state.layouts["7"])
    }

    /// The automatic start also checks at acceptance that automatic arrangement is on for that Space. Manual arrangement works even when off.
    func testAutomaticStartIsRefusedInADisabledSpaceAtAcceptance() throws {
        dropLayout()
        coordinator.setCurrentSpaceAutoPaused(true)
        XCTAssertEqual(coordinator.arrange(source: "auto", kind: "auto-start", adding: [WindowID(1), WindowID(2)], automaticFront: WindowID(1)), .notApplicable)
        drain()
        XCTAssertNil(coordinator.state.layouts["7"])
        XCTAssertEqual(system.writes, 0)
        guard case .started = coordinator.arrange(source: "cli") else { return XCTFail("Arrange Now still works") }
        drain()
        XCTAssertNotNil(coordinator.state.layouts["7"])
    }

    func testPausedSpaceDoesNotAutoStart() throws {
        coordinator.setCurrentSpaceAutoPaused(true)
        dropLayout()
        let config = Config()
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let current = system.census(7)
        coordinator.armAutomaticStart(previous: current, current: current, spaceKey: "7")
        XCTAssertFalse(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
        XCTAssertNil(coordinator.state.layouts["7"])
    }

    func testForegroundIntegrationIncludesRequestedWaitingWindowOnly() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        system.frames[WindowID(4)] = CGRect(x: 200, y: 200, width: 600, height: 400)
        coordinator.parkWaiting([WindowID(3), WindowID(4)])
        XCTAssertEqual(coordinator.waiting, [WindowID(3), WindowID(4)])
        // A failed attempt must keep the requested window waiting.
        system.trusted = false
        _ = coordinator.integrateForeground([WindowID(3)], beside: nil)
        drain()
        XCTAssertTrue(coordinator.waiting.contains(WindowID(3)))
        system.trusted = true
        _ = coordinator.integrateForeground([WindowID(3)], beside: nil)
        drain()
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2), WindowID(3)])
        XCTAssertEqual(coordinator.waiting, [WindowID(4)])
        XCTAssertEqual(system.frames[WindowID(4)], CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    func testForegroundIntegrateBesideFlexibleWindowKeepsPackedWidthWithoutFacts() {
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [230.0 / 1920.0, 1690.0 / 1920.0]))
        saved.sizeFacts = []
        store.save(saved)
        let loaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        loaded.limits.settleDelay = 0
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 230, height: 408)
        system.frames[WindowID(2)] = CGRect(x: 230, y: 0, width: 1690, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 400, y: 40, width: 400, height: 400)
        _ = loaded.integrateForeground([WindowID(3)], beside: WindowID(2))
        let done = expectation(description: "integrate drained")
        loaded.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 153)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1126)
        XCTAssertEqual(system.frames[WindowID(3)]?.width, 641)
    }

    func testForegroundIntegrateStacksUnderAShortWideLeaf() {
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [700.0 / 1920.0, 1220.0 / 1920.0]))
        saved.sizeFacts = []
        store.save(saved)
        let loaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        loaded.limits.settleDelay = 0
        loaded.knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 0, width: 960, height: 1080),
            actual: CGRect(x: 0, y: 0, width: 700, height: 440),
            spaceID: 7, workArea: system.area, tolerance: 1)
        system.fixed[WindowID(1)] = CGSize(width: 700, height: 440)
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 700, height: 440)
        system.frames[WindowID(2)] = CGRect(x: 700, y: 0, width: 1220, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 80, y: 500, width: 400, height: 300)
        _ = loaded.integrateForeground([WindowID(3)], beside: WindowID(2))
        let done = expectation(description: "stack integrate drained")
        loaded.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 700)
        XCTAssertEqual(system.frames[WindowID(1)]?.height, 440)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1220)
        XCTAssertEqual(system.frames[WindowID(3)]?.width, 700)
        XCTAssertEqual(system.frames[WindowID(3)]?.minX, 0)
        XCTAssertGreaterThan(system.frames[WindowID(3)]!.minY, system.frames[WindowID(1)]!.maxY - 2)
        guard case .split(.horizontal, let children, _)? = loaded.state.layouts["7"]?.root else { return XCTFail() }
        guard case .split(.vertical, _, _) = children[0] else { return XCTFail("C stacks below the short leaf") }
    }

    func testForegroundIntegrateAtEndKeepsPackedWidthWithoutFacts() {
        var saved = store.load()
        saved.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [230.0 / 1920.0, 1690.0 / 1920.0]))
        saved.sizeFacts = []
        store.save(saved)
        let loaded = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        loaded.limits.settleDelay = 0
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 230, height: 408)
        system.frames[WindowID(2)] = CGRect(x: 230, y: 0, width: 1690, height: 1080)
        system.frames[WindowID(3)] = CGRect(x: 400, y: 40, width: 400, height: 400)
        _ = loaded.integrateForeground([WindowID(3)], beside: nil)
        let done = expectation(description: "end integrate drained")
        loaded.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 153)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1126)
        XCTAssertEqual(system.frames[WindowID(3)]?.width, 641)
    }

    func testQueuedAutomaticStartRechecksOptOutAndFocus() throws {
        for optOut in [true, false] {
            system.focused = WindowID(1)
            let current = try prepareAutoStart()
            coordinator.operationsQueue.suspend()
            XCTAssertTrue(coordinator.startPendingAutomaticSpace(current: current, spaceKey: "7", quiet: true))
            // Turning automatic arrangement off for this Space takes effect before the pending write.
            if optOut { coordinator.setCurrentSpaceAutoPaused(true) } else { system.focused = WindowID(2) }
            coordinator.operationsQueue.resume()
            drain()
            XCTAssertEqual(system.writes, 0)
            XCTAssertNil(coordinator.state.layouts["7"])
            coordinator.setCurrentSpaceAutoPaused(false)
        }
    }

    func testUnstartedHintUsesTheAutomaticArrangeTitle() {
        XCTAssertEqual(coordinator.status().autoAvailable, true)
        XCTAssertTrue(coordinator.notStartedMessage.contains("Arrange Now"))
        XCTAssertTrue(coordinator.notStartedMessage.contains("Arrange Now"))
    }

    func testAutoIntegrationThatCannotFitFloatsTheWindow() {
        system.minimums[WindowID(1)] = CGSize(width: 800, height: 700)
        system.minimums[WindowID(2)] = CGSize(width: 800, height: 700)
        system.minimums[WindowID(3)] = CGSize(width: 800, height: 700)
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 800, height: 700)
        _ = coordinator.integrateForeground([WindowID(3)], beside: nil)
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(coordinator.state.floating["7"], [WindowID(3)])
        XCTAssertEqual(Set(coordinator.state.layouts["7"]?.windowIDs ?? []), [WindowID(1), WindowID(2)])
        XCTAssertTrue(coordinator.lastResult?.message.contains("kept in place as floating") == true)
        XCTAssertFalse(coordinator.lastResult?.message.contains("returned to where they were before") == true)
    }

    func testBeforeWriteIntegrateFallbackCompletes() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 960, height: 400)
        for id in [WindowID(1), WindowID(2), WindowID(3)] {
            coordinator.knowledge.recordPushback(
                id: id, requested: CGRect(x: 0, y: 0, width: 600, height: 100),
                actual: CGRect(x: 0, y: 0, width: 800, height: 100),
                spaceID: 7, workArea: system.currentWorkArea(), tolerance: 1)
        }
        _ = coordinator.integrateForeground([WindowID(3)], beside: WindowID(1))
        drain()
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
    }

    func testLearnedUnfitRollsBackAndRelaunchRefusesBeforeWrite() {
        system.area = CGRect(x: 0, y: 33, width: 800, height: 400)
        let original1 = CGRect(x: 0, y: 33, width: 500, height: 300)
        let original2 = CGRect(x: 300, y: 33, width: 500, height: 300)
        system.frames[WindowID(1)] = original1
        system.frames[WindowID(2)] = original2
        system.minimums[WindowID(1)] = CGSize(width: 500, height: 300)
        system.minimums[WindowID(2)] = CGSize(width: 500, height: 300)
        guard case .started(let first) = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
        drain()
        let firstResult = coordinator.result(id: first)
        XCTAssertEqual(firstResult?.outcome, .complete, firstResult?.message ?? "")
        XCTAssertTrue(firstResult?.message.contains("kept in place as floating") == true)
        XCTAssertFalse(firstResult?.message.contains("returned to where they were before") == true)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertEqual(coordinator.state.floating["7"], [WindowID(2)])
        XCTAssertNotEqual(system.frames[WindowID(2)], original2)
        XCTAssertFalse(store.load().sizeFacts.isEmpty)
        let floated = system.frames[WindowID(2)]

        system.writes = 0
        guard case .started(let second) = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
        drain()
        XCTAssertEqual(coordinator.result(id: second)?.outcome, .complete)
        XCTAssertEqual(system.frames[WindowID(2)], floated)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
        let widths = store.load().sizeFacts.map(\.entry.minimum.width)
        XCTAssertGreaterThan(widths.max() ?? 0, 0, "width facts \(store.load().sizeFacts.map(\.entry.minimum))")

        let relaunched = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        relaunched.limits.settleDelay = 0
        system.writes = 0
        let kept = system.frames[WindowID(2)]
        guard case .started(let third) = relaunched.arrange(source: "test") else { return XCTFail("Arrange refused") }
        let packed = expectation(description: "relaunch drained")
        relaunched.operationsQueue.async { packed.fulfill() }
        wait(for: [packed], timeout: 10)
        XCTAssertEqual(relaunched.result(id: third)?.outcome, .complete)
        XCTAssertEqual(system.frames[WindowID(2)], kept)
        XCTAssertEqual(relaunched.state.layouts["7"]?.windowIDs, [WindowID(1)])
        XCTAssertEqual(relaunched.state.floating["7"], [WindowID(2)])
    }

    func testSavedMaximumPacksAgainAfterRelaunchUntilTheWindowIsLarger() {
        system.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        system.frames[WindowID(1)] = CGRect(x: 40, y: 40, width: 500, height: 400)
        system.frames[WindowID(2)] = CGRect(x: 600, y: 40, width: 500, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
        drain()
        let saved = store.load().sizeFacts.first { $0.id == WindowID(1) }
        XCTAssertEqual(saved?.entry.maximum, CGSize(width: 230, height: 408))
        XCTAssertEqual(system.frames[WindowID(1)]?.size, CGSize(width: 230, height: 408))

        let relaunched = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        relaunched.limits.settleDelay = 0
        system.written.removeAll()
        guard case .started = relaunched.arrange(source: "test") else { return XCTFail("Arrange refused") }
        let packed = expectation(description: "relaunch drained")
        relaunched.operationsQueue.async { packed.fulfill() }
        wait(for: [packed], timeout: 10)
        XCTAssertFalse(system.written.contains { $0.0 == WindowID(1) && $0.1.width > 230 })
        XCTAssertEqual(system.frames[WindowID(1)]?.size, CGSize(width: 230, height: 408))

        system.fixed[WindowID(1)] = nil
        system.frames[WindowID(1)] = CGRect(x: 0, y: 0, width: 960, height: 1080)
        system.frames[WindowID(2)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let grown = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        grown.limits.settleDelay = 0
        system.written.removeAll()
        guard case .started = grown.arrange(source: "test") else { return XCTFail("Arrange refused") }
        let enlarged = expectation(description: "grown drained")
        grown.operationsQueue.async { enlarged.fulfill() }
        wait(for: [enlarged], timeout: 10)
        XCTAssertFalse(system.written.contains { $0.0 == WindowID(1) && $0.1.width < 960 })
        XCTAssertEqual(system.frames[WindowID(1)]?.size, CGSize(width: 960, height: 1080))
        XCTAssertEqual(store.load().sizeFacts.first { $0.id == WindowID(1) }?.entry.maximum.width, 0)
    }

    func testSavedPackedRatiosKeepWidthAfterSizeFactsAreDropped() {
        system.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        system.frames[WindowID(1)] = CGRect(x: 40, y: 40, width: 500, height: 400)
        system.frames[WindowID(2)] = CGRect(x: 600, y: 40, width: 500, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
        drain()
        guard case .split(.horizontal, _, let ratios)? = coordinator.state.layouts["7"]?.root else {
            return XCTFail("expected a horizontal split layout intent")
        }
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 230)
        XCTAssertEqual(ratios[0], 230.0 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 1690.0 / 1920.0, accuracy: 1e-9)

        var saved = store.load()
        saved.sizeFacts = []
        store.save(saved)
        system.fixed.removeAll()
        system.writes = 0
        system.written.removeAll()

        let relaunched = Coordinator(system: system, store: store, configURL: coordinator.configURL, takeCensus: system.census, takeOverview: { nil })
        relaunched.limits.settleDelay = 0
        guard case .started = relaunched.arrange(source: "test") else { return XCTFail("Arrange refused") }
        let done = expectation(description: "facts dropped drained")
        relaunched.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 230)
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1690)
    }

    func testMenuEnablementFollowsTheCurrentLayout() {
        let left = WindowID(1)
        XCTAssertTrue(coordinator.canApplyEdit(.focus(.right), focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.focus(.left), focused: left))
        XCTAssertTrue(coordinator.canApplyEdit(.resize(.horizontal, 0.05), focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.resize(.vertical, 0.05), focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.balance, focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.fullscreen, focused: nil))
        XCTAssertTrue(coordinator.canApplyEdit(.fullscreen, focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.moveToSpace(.next), focused: nil))
        XCTAssertTrue(coordinator.canApplyEdit(.moveToSpace(.next), focused: left))
        XCTAssertFalse(coordinator.canApplyEdit(.undo, focused: left))
    }

    func testFloatingRefusalNamesTheConfiguredKey() throws {
        system.focused = WindowID(1)
        _ = coordinator.edit(.toggleFloat, source: "test")
        drain()
        guard case .refused(let standard, _) = coordinator.edit(.swap(.right), source: "test") else { return XCTFail("swap should refuse a floating window") }
        XCTAssertTrue(standard.contains("⌥F"))
        XCTAssertFalse(standard.contains("Return Window to Tiling"))

        try "[keys]\nfloat = \"alt-shift-x\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        guard case .refused(let rebound, _) = coordinator.edit(.swap(.right), source: "test") else { return XCTFail("swap should still refuse") }
        XCTAssertTrue(rebound.contains("⌥⇧X"))
        XCTAssertFalse(rebound.contains("⌥F"))

        try "[keys]\nfloat = \"none\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        guard case .refused(let unbound, _) = coordinator.edit(.swap(.right), source: "test") else { return XCTFail("swap should still refuse") }
        // The item name matches the one in the Edit Layout menu.
        XCTAssertTrue(unbound.contains("“Return Window to Tiling”"))
        XCTAssertFalse(unbound.contains("⌥"))
    }

    func testPauseAndACompletedArrangeClearTheMenuRefusal() {
        coordinator.noteRefusal("There is no window to the left.")
        coordinator.pause()
        XCTAssertNil(coordinator.lastRefusal)
        coordinator.noteRefusal("There is no window to the left.")
        coordinator.resume()
        drain()
        XCTAssertNil(coordinator.lastRefusal)

        coordinator.noteRefusal("There is no window to the left.")
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("Arrange refused") }
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertNil(coordinator.lastRefusal)
    }

    func testReloadSuccessClearsTheMenuRefusalAndHidesTheSource() throws {
        coordinator.noteRefusal("There is no window to the left.")
        let message = coordinator.reportReload(source: "menu")
        XCTAssertEqual(message, "Configuration loaded. No windows were moved.")
        XCTAssertFalse(message.contains("menu"))
        XCTAssertNil(coordinator.lastRefusal)
        XCTAssertNil(coordinator.configError)

        try "bogus = 1\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let failed = coordinator.reportReload(source: "menu")
        XCTAssertTrue(failed.contains("Unknown setting: bogus."))
        XCTAssertFalse(failed.contains("menu"))
        XCTAssertEqual(coordinator.lastRefusal, failed)
        XCTAssertNotNil(coordinator.configError)
    }

    /// Change notifications never write the template: if the file is briefly missing mid-save, the current settings stay instead of being overwritten.
    /// A reload on a change notification does not reapply settings when the bytes are unchanged.
    func testFileReloadNeverWritesTheTemplateAndSkipsUnchangedBytes() throws {
        try "language = \"en\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let generation = coordinator.configGeneration
        _ = coordinator.reloadConfig(source: "file")
        XCTAssertEqual(coordinator.configGeneration, generation, "same bytes are not applied again")

        try FileManager.default.removeItem(at: coordinator.configURL)
        _ = coordinator.reloadConfig(source: "file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.configURL.path), "no template while an editor is saving")
        XCTAssertNil(coordinator.configError)
        XCTAssertEqual(coordinator.configGeneration, generation)

        _ = coordinator.reloadConfig(source: "launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.configURL.path))
    }
    /// Even on a Space with automatic arrangement off, moving focus by keyboard reflows the accordion strips (continuing the user's action).
    func testFocusInAccordionReflowsInASpaceSetToManual() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange refused") }
        drain()
        system.focused = WindowID(1)
        guard case .started = coordinator.edit(.toggleAccordion, source: "test") else { return XCTFail("accordion refused") }
        drain()
        coordinator.setCurrentSpaceAutoPaused(true)
        let before = system.frames
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        XCTAssertNotEqual(system.frames, before, "the strip follows the focused window")
    }
    /// The reflow after a focus command writes nothing while a mouse button is held (the user may be dragging).
    func testFocusInAccordionDoesNotReflowWhileAMouseButtonIsHeld() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange refused") }
        drain()
        system.focused = WindowID(1)
        guard case .started = coordinator.edit(.toggleAccordion, source: "test") else { return XCTFail("accordion refused") }
        drain()
        let before = system.frames
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(.leftMouseDown, event: down)
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        XCTAssertEqual(system.focused, WindowID(3), "the focus command itself runs")
        XCTAssertEqual(system.frames, before)
    }
    /// A focus reflow stopped by a held button is not retried; once the button is released and input is quiet, drift reconciliation realigns the strips.
    func testAccordionStripsRealignOnceQuietAfterTheButtonIsReleased() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange refused") }
        drain()
        system.focused = WindowID(1)
        guard case .started = coordinator.edit(.toggleAccordion, source: "test") else { return XCTFail("accordion refused") }
        drain()
        tick()
        let before = system.frames
        mouse(.leftMouseDown)
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        tick()
        XCTAssertEqual(system.frames, before)
        mouse(.leftMouseUp)
        tick()
        XCTAssertEqual(system.frames, before, "the release starts the quiet wait")
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        // Also waits out the one-second arrival dwell of the first observation, so allow a few ticks (bounded).
        for _ in 0..<10 where system.frames == before { tick(); Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertNotEqual(system.frames, before, "the strips follow the focused window after release")
        let realigned = system.frames
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        XCTAssertEqual(system.frames, realigned, "already aligned to the focused window")
    }
    /// On a Space with automatic arrangement off, a reflow stopped by a held button stays undone until the next focus command.
    func testAccordionStripsStayUntilTheNextFocusCommandInASpaceSetToManual() {
        system.frames[WindowID(3)] = CGRect(x: 100, y: 100, width: 600, height: 400)
        guard case .started = coordinator.arrange(source: "test") else { return XCTFail("arrange refused") }
        drain()
        system.focused = WindowID(1)
        guard case .started = coordinator.edit(.toggleAccordion, source: "test") else { return XCTFail("accordion refused") }
        drain()
        coordinator.setCurrentSpaceAutoPaused(true)
        tick()
        let before = system.frames
        mouse(.leftMouseDown)
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        tick()
        mouse(.leftMouseUp)
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        for _ in 0..<5 { tick(); Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(system.frames, before, "nothing moves on its own")
        guard case .started = coordinator.runFocus(WindowID(3), source: "test") else { return XCTFail("focus refused") }
        drain(); drain()
        XCTAssertNotEqual(system.frames, before, "the next focus command realigns the strips")
    }
    /// When every window of a Space has closed, a complete observation removes them from the saved layout,
    /// so later arrivals do not refit an empty Space again and again.
    func testRefitOfASpaceWhoseWindowsAllClosedClearsTheLayout() {
        system.frames = [:]
        guard case .started = coordinator.arrange(source: "auto", kind: "auto-refit") else { return XCTFail("refit refused") }
        drain()
        XCTAssertEqual(coordinator.lastResult?.outcome, .complete)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs ?? [], [])
    }
}
