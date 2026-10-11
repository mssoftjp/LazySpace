import AppKit
import Copy
import Settings
import XCTest
@testable import LazySpace

@MainActor
final class ShortcutEditingFeelTests: XCTestCase {
    private var root: URL!
    private var coordinator: Coordinator!
    private var preferences: UserDefaults!
    private var suite: String!
    private var controller: SettingsWindowController!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        Copy.language = .english
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "LazySpace.ShortcutFeel.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        let system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
    }

    override func tearDownWithError() throws {
        controller?.window?.orderOut(nil)
        controller = nil
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
        Copy.language = .english
    }

    func testModeEntriesHaveNoShortcutRowOrPictogram() throws {
        try load(Config())
        try select(.keys)
        XCTAssertNil(row(labeled: "Enter Service Mode", in: try shortcutTable()))
        XCTAssertNil(ActionPictogram.forCommand("mode-service"))
        XCTAssertNil(ActionPictogram.forCommand("mode-review"))
        Copy.language = .japanese
        controller.refresh()
        XCTAssertNil(row(labeled: "service モードに入る", in: try shortcutTable()))
    }

    func testShortcutValueStaysReadableInLightDarkAndContrast() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        for appearance in appearances {
            let resolved = try XCTUnwrap(NSAppearance(named: appearance))
            resolved.performAsCurrentDrawingAppearance {
                let idle = ShortcutValueCell(frame: NSRect(x: 0, y: 0, width: 216, height: 26))
                idle.actionLabel = "Arrange This Space"
                idle.backgroundStyle = .emphasized
                idle.setAssignment(display: "⌥⇧W", recording: false)
                XCTAssertEqual(idle.backgroundStyle, .emphasized, appearance.rawValue)
                XCTAssertNotEqual(idle.valueLabel.stringValue, "—")

                let recording = ShortcutValueCell(frame: idle.frame)
                recording.actionLabel = idle.actionLabel
                recording.backgroundStyle = .emphasized
                recording.setAssignment(display: "⌥⇧W", recording: true)
                XCTAssertEqual(recording.valueLabel.textColor, .labelColor, appearance.rawValue)
                XCTAssertEqual(recording.valueLabel.cell?.backgroundStyle, .normal, appearance.rawValue)
                let text = recording.valueLabel.textColor?.usingColorSpace(.sRGB)
                let paper = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                XCTAssertNotNil(text, appearance.rawValue)
                XCTAssertNotNil(paper, appearance.rawValue)
                if let text, let paper {
                    XCTAssertGreaterThan(self.contrast(text, paper), 3, appearance.rawValue)
                }

                recording.setAssignment(display: nil, recording: true)
                XCTAssertEqual(recording.valueLabel.stringValue, "Type Shortcut")
                XCTAssertEqual(recording.valueLabel.textColor, .placeholderTextColor)
                let placeholder = recording.valueLabel.textColor?.usingColorSpace(.sRGB)
                XCTAssertNotNil(placeholder, appearance.rawValue)
                if let placeholder, let paper {
                    XCTAssertGreaterThan(self.contrast(placeholder, paper), 1.4, appearance.rawValue)
                }
            }
        }
    }

    func testRecordingKeepsTheSelectionFocusAndScroll() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let space = try XCTUnwrap(row(labeled: "Switch to Desktop 8", in: table))
        table.scrollRowToVisible(space)
        let origin = try scrollOrigin(table)
        XCTAssertGreaterThan(abs(origin.y), 10, "row was not scrolled: \(origin)")
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        selectShortcutRow(space, in: table)
        try valueCell(command: "space-8", in: table).onChange?()
        XCTAssertEqual(recording, [true])
        XCTAssertEqual(table.selectedRow, space)
        XCTAssertTrue(table.rowView(atRow: space, makeIfNecessary: false)?.isSelected == true)
        if NSApp.isActive {
            XCTAssertTrue(controller.window?.isKeyWindow == true)
        }
        XCTAssertTrue(controller.window?.firstResponder === table)
        XCTAssertEqual(try scrollOrigin(table).y, origin.y, accuracy: 2)

        sendKey(96, release: false)
        XCTAssertEqual(recording, [true], "hotkeys resume before the recorded key is released")
        XCTAssertEqual(coordinator.config.keys["space-8"], Config.Key(modifiers: [], key: "f5"))
        sendKey(96, release: true, down: false)
        XCTAssertEqual(recording, [true, false])
        XCTAssertEqual(table.selectedRow, space)
        XCTAssertTrue(controller.window?.firstResponder === table)
        XCTAssertEqual(try scrollOrigin(table).y, origin.y, accuracy: 2)
        table.keyDown(with: try key(125, characters: "\u{f701}"))
        XCTAssertGreaterThan(table.selectedRow, space)
        XCTAssertNotEqual(rowLabel(in: table, row: table.selectedRow), "Focus")
    }

    func testEscapeDeleteAndReturnStayOnTheEditedRow() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        table.scrollRowToVisible(arrange)
        let origin = try scrollOrigin(table)
        selectShortcutRow(arrange, in: table)
        table.keyDown(with: try key(36))
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertTrue(controller.window?.firstResponder === table)
        sendKey(53)
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(table.selectedRow, arrange)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
        XCTAssertEqual(try scrollOrigin(table).y, origin.y, accuracy: 2)
        table.keyDown(with: try key(125, characters: "\u{f701}"))
        XCTAssertGreaterThan(table.selectedRow, arrange)
        XCTAssertNotEqual(rowLabel(in: table, row: table.selectedRow), rowLabel(in: table, row: arrange))

        selectShortcutRow(arrange, in: table)
        try beginSelectedRecording()
        sendKey(51)
        XCTAssertNil(coordinator.config.keys["arrange"])
        XCTAssertEqual(table.selectedRow, arrange)
        XCTAssertTrue(controller.window?.firstResponder === table)
        XCTAssertEqual(try messageText(), "")
    }

    func testClicksSelectWithoutCaptureAndOutsideClicksCancel() throws {
        try load(Config())
        try select(.keys)
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        let table = try shortcutTable()
        let arrangeRow = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        let focusRow = try XCTUnwrap(row(labeled: "Focus", in: table))
        let arrange = try valueCell(command: "arrange", in: table)
        try dispatchClick(on: arrange)
        XCTAssertEqual(table.selectedRow, arrangeRow)
        XCTAssertFalse(try valueCell(command: "arrange", in: table).recording)

        selectShortcutRow(arrangeRow, in: table)
        try valueCell(command: "arrange", in: table).onChange?()
        XCTAssertTrue(try valueCell(command: "arrange", in: table).recording)
        try dispatchClick(on: try valueCell(command: "arrange", in: table))
        XCTAssertTrue(try valueCell(command: "arrange", in: table).recording, "a click on the recording cell keeps capture")

        selectShortcutRow(focusRow, in: table)
        XCTAssertFalse(try valueCell(command: "arrange", in: table).recording)
        XCTAssertEqual(table.selectedRow, focusRow)
        XCTAssertEqual(try messageText(), "")
    }

    func testRemoveActionClearsAndTabIsNotRecorded() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let arrange = try valueCell(command: "arrange", in: table)
        XCTAssertEqual(arrange.accessibilityLabel(), "Arrange This Space")
        XCTAssertTrue(arrange.accessibilityHelp()?.contains("Return") == true)
        XCTAssertEqual(arrange.accessibilityValue() as? String, "⌥⇧A")
        let actions = arrange.accessibilityCustomActions().map(\.name)
        XCTAssertTrue(actions.contains("Change Shortcut"), actions.joined(separator: ", "))
        XCTAssertTrue(actions.contains("Remove Shortcut"), actions.joined(separator: ", "))
        XCTAssertFalse(actions.contains("Restore Default"), actions.joined(separator: ", "))
        arrange.onRemove?()
        XCTAssertNil(coordinator.config.keys["arrange"])
        XCTAssertEqual(try messageText(), "")

        try load(Config())
        try select(.keys)
        let fresh = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: fresh)), in: fresh)
        try beginSelectedRecording()
        let recordingHelp = try valueCell(command: "arrange", in: fresh).accessibilityHelp() ?? ""
        XCTAssertTrue(recordingHelp.contains("Recording"))
        XCTAssertEqual(try valueCell(command: "arrange", in: fresh).accessibilityValue() as? String, "⌥⇧A")
        let before = coordinator.config.keys["arrange"]
        sendKey(48)
        XCTAssertEqual(coordinator.config.keys["arrange"], before)
        XCTAssertFalse(try selectedCellIsRecording())
        try beginSelectedRecording()
        sendKey(48, modifiers: .shift)
        XCTAssertEqual(coordinator.config.keys["arrange"], before)
        XCTAssertFalse(try messageText().contains("⇥"))
    }

    func testRepeatsAreIgnoredAndModifiedDeleteIsRecorded() throws {
        try load(Config())
        try select(.keys)
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        try beginSelectedRecording()
        sendKey(0, release: false)
        XCTAssertEqual(recording, [true])
        XCTAssertTrue(try selectedCellIsRecording())
        sendKey(0, repeatDown: true, release: false)
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
        sendKey(51, modifiers: .option, release: false)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "backspace"))
        XCTAssertEqual(recording, [true])
        sendKey(51, modifiers: .option, repeatDown: true, release: false)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "backspace"))
        sendKey(51, down: false)
        XCTAssertEqual(recording, [true, false])
    }

    func testOptionDeleteDuringCaptureBelongsToTheRecorder() throws {
        let keys: [(UInt16, String)] = [(51, "backspace"), (117, "forwarddelete")]
        for (code, name) in keys {
            var config = Config()
            config.keys["arrange"] = nil
            try load(config)
            try select(.keys)
            let table = try shortcutTable()
            selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
            try beginSelectedRecording()
            // Even when the event reaches the table directly, recording does not reset to the default.
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            table.keyDown(with: event)
            XCTAssertNil(coordinator.config.keys["arrange"])
            XCTAssertTrue(try selectedCellIsRecording())
            sendKey(code, modifiers: .option, repeatDown: true, release: false)
            XCTAssertNil(coordinator.config.keys["arrange"])
            XCTAssertTrue(try selectedCellIsRecording())
            sendKey(code, modifiers: .option)
            XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: name))
            XCTAssertFalse(try selectedCellIsRecording())
        }
    }

    func testOptionDeleteDispatchRestoresTheSelectedRow() throws {
        var config = Config()
        config.keys["arrange"] = nil
        try load(config)
        try select(.keys)
        let window = try XCTUnwrap(controller.window)
        let table = try shortcutTable()
        window.makeKey()
        window.makeFirstResponder(table)
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        sendKey(51, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
        XCTAssertTrue(window.firstResponder === table)
    }

    func testKeysForAnotherWindowAreNotCaptured() throws {
        try load(Config())
        try select(.keys)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        TestWindows.conceal(other)
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        other.setFrameOrigin(NSPoint(x: maxX + 40, y: 40))
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }
        controller.window?.makeKey()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        try beginSelectedRecording()
        sendKey(5, modifiers: .option, window: other)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
        XCTAssertTrue(try selectedCellIsRecording())
        sendKey(5, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "g"))
    }

    func testDirectionMenuSelectsItsRowAndCancelsRecording() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        let cell = try XCTUnwrap(table.view(atColumn: 1, row: focus, makeIfNecessary: true))
        let popup = try XCTUnwrap(popups(in: cell).first { $0.tag == 1 })
        controller.menuWillOpen(try XCTUnwrap(popup.menu))
        XCTAssertEqual(table.selectedRow, focus)
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(try messageText(), "")
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
    }

    func testFilteredCommitSelectsTheNeighborAndKeepsScroll() throws {
        var config = Config()
        config.keys["close"] = .init(modifiers: [], key: "f1")
        config.keys["minimize"] = .init(modifiers: [], key: "f10")
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        search("F1")
        let close = try XCTUnwrap(row(labeled: "Close Window", in: table))
        selectShortcutRow(close, in: table)
        table.scrollRowToVisible(close)
        let origin = try scrollOrigin(table)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["close"], Config.Key(modifiers: ["alt"], key: "g"))
        XCTAssertNil(row(labeled: "Close Window", in: table))
        let selected = rowLabel(in: table, row: table.selectedRow)
        XCTAssertTrue(selected.contains("Minimize"), selected)
        XCTAssertEqual(try scrollOrigin(table).y, origin.y, accuracy: 2)
        XCTAssertTrue(controller.window?.firstResponder === table)
    }

    func testHotkeysResumeOnKeyUpDeactivationAndTimeout() throws {
        try load(Config())
        try select(.keys)
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        controller.hotkeyResumeGrace = 5
        let table = try shortcutTable()

        controller.recordedKeyStillDown = { _ in true }
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        recording.removeAll()
        sendKey(96, release: false)
        XCTAssertEqual(coordinator.config.keys["arrange"]?.key, "f5")
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(recording, [], "hotkeys resumed before key-up")
        sendKey(96, down: false)
        XCTAssertEqual(recording, [false], "key-up did not resume hotkeys")

        controller.recordedKeyStillDown = { _ in false }
        try beginSelectedRecording()
        recording.removeAll()
        sendKey(96, release: false)
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(recording, [])
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        XCTAssertEqual(recording, [false], "owner deactivation left hotkeys suspended while the key was up")

        controller.recordedKeyStillDown = { _ in false }
        try beginSelectedRecording()
        recording.removeAll()
        sendKey(96, release: false)
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(recording, [])
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(recording, [false], "app deactivation left hotkeys suspended while the key was up")

        controller.recordedKeyStillDown = { _ in true }
        controller.hotkeyResumeGrace = 0.15
        try beginSelectedRecording()
        recording.removeAll()
        sendKey(96, release: false)
        XCTAssertFalse(try selectedCellIsRecording())
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        XCTAssertEqual(recording, [], "owner deactivation resumed hotkeys while the key was still down")
        let deadline = Date().addingTimeInterval(0.45)
        while Date() < deadline, recording.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(recording, [false], "the safety timeout did not resume hotkeys")
    }

    func testWindowClicksOutsideTheRecordingCellCancel() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let arrangeRow = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        let heading = try XCTUnwrap(row(labeled: "Windows", in: table))
        table.scrollRowToVisible(arrangeRow)
        selectShortcutRow(arrangeRow, in: table)

        try valueCell(command: "arrange", in: table).onChange?()
        try dispatchClick(on: try valueCell(command: "arrange", in: table))
        XCTAssertTrue(try valueCell(command: "arrange", in: table).recording)
        XCTAssertEqual(table.selectedRow, arrangeRow)

        let label = try XCTUnwrap(table.view(atColumn: 0, row: arrangeRow, makeIfNecessary: true))
        try dispatchClick(on: label)
        XCTAssertFalse(try valueCell(command: "arrange", in: table).recording)
        XCTAssertEqual(try messageText(), "")
        XCTAssertEqual(table.selectedRow, arrangeRow)

        try valueCell(command: "arrange", in: table).onChange?()
        table.scrollRowToVisible(heading)
        let headingView = try XCTUnwrap(table.rowView(atRow: heading, makeIfNecessary: true))
        try dispatchClick(on: headingView)
        XCTAssertFalse(try valueCell(command: "arrange", in: table).recording, "a section heading click left recording active")
        XCTAssertEqual(try messageText(), "")

        table.scrollRowToVisible(arrangeRow)
        selectShortcutRow(arrangeRow, in: table)
        try valueCell(command: "arrange", in: table).onChange?()
        let background = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Shortcut Message" })
        try dispatchClick(on: background)
        XCTAssertFalse(try valueCell(command: "arrange", in: table).recording, "a pane background click left recording active")
        XCTAssertEqual(try messageText(), "")

        selectShortcutRow(arrangeRow, in: table)
        try valueCell(command: "arrange", in: table).onChange?()
        if let header = table.headerView {
            try dispatchClick(on: header)
            XCTAssertFalse(try valueCell(command: "arrange", in: table).recording, "an empty table-header click left recording active")
            XCTAssertEqual(try messageText(), "")
        }
    }

    func testRecordingAcceptsOnlyFocusedOwnerKeys() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        if NSApp.isActive {
            XCTAssertTrue(controller.window?.isKeyWindow == true)
        }
        XCTAssertTrue(controller.window?.firstResponder === table)
        let before = coordinator.config.keys["arrange"]
        sendKey(36)
        XCTAssertTrue(try selectedCellIsRecording())
        let returnMessage = try messageText()
        XCTAssertTrue(returnMessage.contains("modifier"), returnMessage)
        XCTAssertEqual(coordinator.config.keys["arrange"], before)

        XCTAssertTrue(controller.window?.makeFirstResponder(nil) == true)
        sendKey(5, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["arrange"], before)
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertTrue(controller.window?.makeFirstResponder(table) == true)
        sendKey(5, modifiers: .option, windowNumber: 0)
        XCTAssertEqual(coordinator.config.keys["arrange"], before, "an event with no window was recorded")
        XCTAssertTrue(try selectedCellIsRecording())
        sendKey(5, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "g"))
    }

    func testUnresolvedShortcutFailureStaysUntilRecovery() throws {
        try load(Config())
        try select(.keys)
        let original = try String(contentsOf: coordinator.configURL)
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        var table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        XCTAssertEqual(try messageText(), "Not applied.")
        selectShortcutRow(try XCTUnwrap(row(labeled: "Focus", in: table)), in: table)
        XCTAssertEqual(try messageText(), "Not applied.")
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        let during = try messageText()
        XCTAssertTrue(during.hasPrefix("Not applied."), during)
        XCTAssertFalse(during.contains("Press a key"), during)
        XCTAssertEqual(try valueCell(command: "arrange", in: table).valueLabel.stringValue, "⌥G")
        sendKey(53)
        let afterEscape = try messageText()
        XCTAssertTrue(afterEscape.contains("Not applied."), afterEscape)
        try button("Try Again").performClick(nil)
        let afterFailedRetry = try messageText()
        XCTAssertTrue(afterFailedRetry.contains("Not applied."), afterFailedRetry)
        try original.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try button("Try Again").performClick(nil)
        let afterRetry = try messageText()
        XCTAssertFalse(afterRetry.contains("Not applied."), afterRetry)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "g"))

        try load(Config())
        try select(.keys)
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        XCTAssertEqual(try messageText(), "Not applied.")
        try button("Reload").performClick(nil)
        let afterReload = try messageText()
        XCTAssertFalse(afterReload.contains("Not applied."), afterReload)
        XCTAssertEqual(coordinator.config.gap, 9)

        try load(Config())
        try select(.keys)
        try "gap = 4\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        XCTAssertEqual(try messageText(), "Not applied.")
        controller.leavePrompt = { .discard }
        XCTAssertTrue(controller.resolveLeave())
        let afterDiscard = try messageText()
        XCTAssertFalse(afterDiscard.contains("Not applied."), afterDiscard)
    }

    func testDiagnosticMessagesKeepTheirFullText() throws {
        var config = Config()
        config.rules = [.init(app: "com.apple.Safari", action: .ignore)]
        try load(config)
        try select(.keys)
        controller.nativeShortcutReader = { _ in .disabled }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let status = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Space Switching Status" })
        XCTAssertEqual(status.maximumNumberOfLines, 0)
        XCTAssertNotEqual(status.lineBreakMode, .byTruncatingTail)
        XCTAssertTrue(status.stringValue.contains("Move left a Space"), status.stringValue)
        XCTAssertTrue(status.stringValue.contains("Move right a Space"), status.stringValue)
        let statusNeeded = status.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(status.bounds.width, 200), height: 10_000)).height ?? 0
        XCTAssertGreaterThan(statusNeeded, 24)
        XCTAssertGreaterThanOrEqual(status.frame.height, statusNeeded - 1, "native status \(status.frame.height) clipped \(statusNeeded)")
        let shortcutMessage = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Shortcut Message" })
        XCTAssertEqual(shortcutMessage.maximumNumberOfLines, 1)

        try select(.apps)
        let field = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "not an id"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        let expected = "Enter a bundle identifier. A trailing * matches a prefix."
        let error = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == expected })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(error.maximumNumberOfLines, 0)
        XCTAssertNotEqual(error.lineBreakMode, .byTruncatingTail)
        let errorNeeded = error.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(error.bounds.width, 200), height: 10_000)).height ?? 0
        XCTAssertGreaterThanOrEqual(error.frame.height, errorNeeded - 1, "rule error \(error.frame.height) clipped \(errorNeeded)")
    }

    private func load(_ config: Config) throws {
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        controller.visibleHeightForLayout = 800
        if let window = controller.window {
            let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
            window.setFrameOrigin(NSPoint(x: maxX + 80, y: 80))
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func views() -> [NSView] { descendants(controller.window!.contentView!) }

    private func select(_ pane: SettingsPane) throws {
        let item = try XCTUnwrap(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == pane.rawValue })
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func button(_ title: String) throws -> NSButton {
        try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func shortcutTable() throws -> NSTableView {
        if controller.window?.title != "Shortcuts" && controller.window?.title != "ショートカット" { try select(.keys) }
        return try XCTUnwrap(views().compactMap { $0 as? NSTableView }.first)
    }

    private func row(labeled text: String, in table: NSTableView) -> Int? {
        for row in 0..<table.numberOfRows where rowLabel(in: table, row: row).contains(text) { return row }
        return nil
    }

    private func rowLabel(in table: NSTableView, row: Int) -> String {
        guard table.numberOfRows > row, row >= 0 else { return "" }
        if let column = table.view(atColumn: 0, row: row, makeIfNecessary: true) {
            let text = descendants(column).compactMap { $0 as? NSTextField }.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else { return "" }
        return descendants(rowView).compactMap { $0 as? NSTextField }.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func valueCell(command: String, in table: NSTableView) throws -> ShortcutValueCell {
        for row in 0..<table.numberOfRows {
            if let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) as? ShortcutValueCell, cell.commandName == command {
                return cell
            }
        }
        throw ShortcutFeelError(command: command)
    }

    private func beginSelectedRecording() throws {
        let table = try shortcutTable()
        try XCTUnwrap(valueCell(at: table.selectedRow, in: table)).onChange?()
    }

    private func selectedCellIsRecording() throws -> Bool {
        let table = try shortcutTable()
        return valueCell(at: table.selectedRow, in: table)?.recording == true
    }

    private func valueCell(at row: Int, in table: NSTableView) -> ShortcutValueCell? {
        guard row >= 0 else { return nil }
        return table.view(atColumn: 1, row: row, makeIfNecessary: true) as? ShortcutValueCell
    }

    private func selectShortcutRow(_ row: Int, in table: NSTableView) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    }

    private func search(_ text: String) {
        let field = views().compactMap { $0 as? NSSearchField }.first!
        field.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func messageText() throws -> String {
        views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Shortcut Message" }?.stringValue ?? ""
    }

    private func scrollOrigin(_ table: NSTableView) throws -> NSPoint {
        try XCTUnwrap(table.enclosingScrollView).contentView.bounds.origin
    }

    private func sendKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatDown: Bool = false, release: Bool = true, down: Bool = true, window: NSWindow? = nil, windowNumber: Int? = nil) {
        let text = keyText(code)
        let number = windowNumber ?? (window ?? controller.window)?.windowNumber ?? 0
        if down {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatDown, keyCode: code)
            if let event { NSApp.sendEvent(event) }
        }
        guard release else { return }
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
        if let up { NSApp.sendEvent(up) }
    }

    private func keyText(_ code: UInt16) -> String {
        switch code {
        case 36: return "\r"
        case 48: return "\t"
        case 53: return "\u{1b}"
        case 51: return "\u{7f}"
        case 117: return "\u{f728}"
        default: return " "
        }
    }

    private struct ClickProbe {
        var point: NSPoint
        var hit: String
    }

    @discardableResult
    private func dispatchClick(on view: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> ClickProbe {
        let window = try XCTUnwrap(view.window, file: file, line: line)
        var cursor: NSView? = view
        while let current = cursor {
            if let table = current as? NSTableView {
                let row = table.row(for: view)
                if row >= 0 { table.scrollRowToVisible(row) }
                break
            }
            cursor = current.superview
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let local: NSPoint
        if let cell = view as? ShortcutValueCell, cell.recording {
            let box = cell.recorderBox
            local = NSPoint(x: box.midX, y: box.midY)
        } else {
            local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        let point = view.convert(local, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1), file: file, line: line)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1), file: file, line: line)
        window.sendEvent(down)
        window.sendEvent(up)
        return ClickProbe(point: point, hit: "")
    }

    private func key(_ code: UInt16, characters: String = " ") throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        let own = (view as? NSPopUpButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(popups)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let left = luminance(a)
        let right = luminance(b)
        return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }
}

private struct ShortcutFeelError: Error { var command: String }
