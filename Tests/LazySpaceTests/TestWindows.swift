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
