import AppKit
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

    static func settings(coordinator: Coordinator, preferences: UserDefaults) -> SettingsWindowController {
        let controller = SettingsWindowController(coordinator: coordinator, preferences: preferences)
        conceal(controller.window)
        return controller
    }

    static func inspector(loadInspection: @escaping (@escaping (Inspection) -> Void) -> Void,
                          readLive: @escaping () -> WindowInspectLive,
                          markReady: @escaping () -> Void,
                          openGeneralSettings: @escaping () -> Void,
                          openAccessSettings: @escaping () -> Void) -> ReadyWindowController {
        let controller = ReadyWindowController(
            loadInspection: loadInspection, readLive: readLive, markReady: markReady,
            openGeneralSettings: openGeneralSettings, openAccessSettings: openAccessSettings)
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
