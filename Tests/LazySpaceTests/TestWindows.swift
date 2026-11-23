import AppKit
import LayoutCore
import Operations
@testable import LazySpaceApp

/// Real AppKit windows (key window, first responder, event dispatch) that never appear on the user's screen or take their clicks.
enum TestWindows {
    static func conceal(_ window: NSWindow?) {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
    }

    /// Delivers a synthesized click as Settings, which is key, receives it. A test window never becomes key (the test app does
    /// not activate), and since macOS 27.2 a single click on a table in a window that is not key only focuses the table; in
    /// Settings the same click also selects the row. So for a single click on a table
    /// in a window that is not key, the clicked row is selected as the key window would select it.
    static func click(_ down: NSEvent, _ up: NSEvent, in window: NSWindow) {
        let hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(down.locationInWindow, from: nil) ?? down.locationInWindow) }
        window.sendEvent(down)
        window.sendEvent(up)
        guard !window.isKeyWindow, down.clickCount == 1, let table = hit as? NSTableView else { return }
        let row = table.row(at: table.convert(down.locationInWindow, from: nil))
        if row >= 0, table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
    }

    static func settings(coordinator: Coordinator, preferences: UserDefaults) -> SettingsWindowController {
        let controller = SettingsWindowController(coordinator: coordinator, preferences: preferences)
        conceal(controller.window)
        return controller
    }

    static func inspector(loadInspection: @escaping (@escaping (Inspection) -> Void) -> Void,
                          readLive: @escaping () -> WindowInspectLive,
                          markReady: @escaping () -> Void,
                          openGeneralSettings: @escaping () -> Void,
                          openInputMonitoringSettings: @escaping () -> Void = {},
                          outline: @escaping (WindowID?) -> Void = { _ in },
                          rowActions: ReadyWindowController.RowActions = .init(),
                          scrollerStyle: NSScroller.Style = .overlay) -> ReadyWindowController {
        let controller = ReadyWindowController(
            loadInspection: loadInspection, readLive: readLive, markReady: markReady,
            openGeneralSettings: openGeneralSettings, openInputMonitoringSettings: openInputMonitoringSettings,
            outline: outline, rowActions: rowActions, scrollerStyle: scrollerStyle)
        conceal(controller.window)
        return controller
    }
}

/// A preferences suite for one test, kept in its own temporary folder: a suite named by an absolute path is stored at that
/// path, so nothing reaches ~/Library/Preferences (macOS writes an empty plist there even after the domain is removed).
struct TestPreferences {
    let folder: URL
    let suite: String
    let defaults: UserDefaults

    init(_ name: String) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LazySpace.\(name).\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = folder.appendingPathComponent("preferences").path
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}
