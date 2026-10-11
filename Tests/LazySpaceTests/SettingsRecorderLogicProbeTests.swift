import AppKit
import Copy
import Settings
import XCTest
@testable import LazySpace

@MainActor
final class SettingsRecorderLogicProbeTests: XCTestCase {
    func testRecorderTransfersKeyboardFocusFromSearch() throws {
        try withFixture { controller, table, views, coordinator in
            let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
            XCTAssertTrue(controller.window!.makeFirstResponder(search))
            var events: [Bool] = []
            controller.onRecording = { events.append($0) }
            let cell = try findCell("arrange", table: table)
            cell.onChange?()
            XCTAssertEqual(events, [true], "Moving focus off search must not cancel the recording that just started")
            XCTAssertTrue(controller.window!.firstResponder === table,
                          "Inline recorder must return keyboard focus to its table; actual: \(String(describing: controller.window!.firstResponder))")
            try findCell("arrange", table: table).onChange?()
            XCTAssertEqual(events, [true], "Changing the same shortcut again does not stop capture")
            XCTAssertEqual(coordinator.config.keys["arrange"]?.key, "a")
            try findCell("arrange", table: table).onCancel?()
            XCTAssertEqual(events, [true, false])
        }
    }

    func testClearingAnotherRowEndsOldRecordingTarget() throws {
        try withFixture { controller, table, _, coordinator in
            var events: [Bool] = []
            controller.onRecording = { events.append($0) }
            try findCell("arrange", table: table).onChange?()
            try findCell("integrate", table: table).onRemove?()
            XCTAssertEqual(events.last, false,
                           "After clearing a different selected row, the old command should not still capture the next key")
            XCTAssertEqual(events, [true, false])
            XCTAssertNil(coordinator.config.keys["integrate"])
            XCTAssertEqual(coordinator.config.keys["arrange"]?.key, "a")
            sendKey(25, modifiers: .option, window: controller.window)
            XCTAssertEqual(coordinator.config.keys["arrange"]?.key, "a", "A key after clear must not bind the command that was recording")
            try findCell("arrange", table: table).onChange?()
            XCTAssertEqual(events, [true, false, true])
            XCTAssertTrue(controller.window!.firstResponder === table)
            try findCell("arrange", table: table).onCancel?()
            XCTAssertEqual(events, [true, false, true, false])
        }
    }

    private func findCell(_ command: String, table: NSTableView) throws -> ShortcutValueCell {
        try XCTUnwrap((0..<table.numberOfRows).compactMap {
            table.view(atColumn: 1, row: $0, makeIfNecessary: true) as? ShortcutValueCell
        }.first { $0.commandName == command })
    }

    private func sendKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow?) {
        let number = window?.windowNumber ?? 0
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)
        if let down { NSApp.sendEvent(down) }
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)
        if let up { NSApp.sendEvent(up) }
    }

    private func withFixture(_ check: (SettingsWindowController, NSTableView, [NSView], Coordinator) throws -> Void) throws {
        _ = NSApplication.shared
        let oldLanguage = Copy.language
        Copy.language = .english
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "LazySpace.RecorderLogicProbe.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(SettingsPane.keys.rawValue, forKey: "settings.selectedPane")
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            Copy.language = oldLanguage
        }
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        try Config().render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        defer { controller.window?.orderOut(nil) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.window!.contentView!)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        try check(controller, table, views, coordinator)
    }
}
