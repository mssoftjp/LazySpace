import AppKit
import Copy
import Settings
import XCTest
@testable import LazySpace

@MainActor
final class SettingsWindowTests: XCTestCase {
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
        suite = "LazySpace.SettingsTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        let system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
    }

    /// Test windows stay real for AppKit but never show on the user's screen or take their clicks, even after the product shows them.
    func testTestWindowsStayOffTheUsersScreen() {
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        controller.showWindow(nil)
        let inspector = TestWindows.inspector(loadInspection: { _ in }, readLive: { WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [], status: self.coordinator.status(), firstLaunchDone: true) },
            markReady: {}, openGeneralSettings: {}, openAccessSettings: {})
        defer { inspector.close() }
        inspector.showWindow(nil)
        for window in [controller.window, inspector.window].compactMap({ $0 }) {
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.alphaValue, 0)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertEqual(window.animationBehavior, .none)
        }
    }

    override func tearDownWithError() throws {
        controller?.window?.orderOut(nil)
        controller = nil
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
        Copy.language = .english
    }

    private func load(_ config: Config) throws {
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func views() -> [NSView] { descendants(controller.window!.contentView!) }

    private func dialogsBesideButton() throws -> NSButton {
        if controller.window?.toolbar?.selectedItemIdentifier?.rawValue != SettingsPane.layout.rawValue {
            try select(.layout)
        }
        let title = Copy.language == .japanese ? "大きさが固定のウインドウを整列したウインドウと並べて表示" : "Keep fixed-size windows next to arranged windows"
        return try button(title)
    }

    private func shortcutActionItem(_ tag: Int) throws -> NSMenuItem {
        try XCTUnwrap(controller.contextMenuItem(tag: tag, clickedRow: try shortcutTable().selectedRow))
    }

    private func shortcutActionEnabled(_ tag: Int) throws -> Bool {
        try shortcutActionItem(tag).isEnabled
    }

    private func performShortcutAction(_ tag: Int) throws {
        let item = try shortcutActionItem(tag)
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
    }

    private func valueCell(at row: Int, in table: NSTableView) -> ShortcutValueCell? {
        guard row >= 0 else { return nil }
        return table.view(atColumn: 1, row: row, makeIfNecessary: true) as? ShortcutValueCell
    }

    private func beginSelectedRecording() throws {
        let table = try shortcutTable()
        try XCTUnwrap(valueCell(at: table.selectedRow, in: table)).onChange?()
    }

    private func cancelSelectedRecording() throws {
        let table = try shortcutTable()
        try XCTUnwrap(valueCell(at: table.selectedRow, in: table)).onCancel?()
    }

    private func selectedCellIsRecording() throws -> Bool {
        let table = try shortcutTable()
        return valueCell(at: table.selectedRow, in: table)?.recording == true
    }

    private func addListedApp() throws {
        let item = try XCTUnwrap(controller.preparedAddRuleMenu().items.first { $0.representedObject is String })
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
    }

    private func addAppButton() throws -> NSButton {
        try XCTUnwrap(views().compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Add App" || $0.accessibilityLabel() == "アプリを追加"
        })
    }

    private func button(_ title: String) throws -> NSButton {
        try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { button in
            if button.title == title { return true }
            let label = button.accessibilityLabel() ?? ""
            if title == "−" || title == "-" {
                return label == "Remove Selected Rule" || label == "選択したルールを削除"
            }
            if title == "+" {
                return label == "Add App" || label == "アプリを追加"
            }
            return false
        })
    }

    private func select(_ pane: SettingsPane) throws {
        let item = try XCTUnwrap(controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == pane.rawValue })
        _ = controller.perform(try XCTUnwrap(item.action), with: item)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    func testSavingVisiblePreferencePreservesAdvancedValuesAndNilLogin() throws {
        var config = Config()
        config.quietInterval = 2.3
        config.perAppTimeout = 7.4
        config.focusAfterClose = false
        config.gapVertical = 17
        config.outerLeft = 23
        config.execOnSpaceChange = ["/usr/bin/true"]
        config.rules = [.init(app: "com.example.*", action: .float, title: "Inspector")]
        try load(config)
        let original = try String(contentsOf: coordinator.configURL)
        let automatic = try dialogsBesideButton()
        automatic.performClick(nil)
        config.placeDialogsBeside = true
        XCTAssertEqual(coordinator.config, config, "A completed choice is saved without touching hidden or file-only preferences")
        XCTAssertNil(coordinator.config.startAtLogin)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL.appendingPathExtension("bak")), original)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("place-dialogs-beside = true"), saved)
        XCTAssertTrue(saved.contains("quiet-interval = 2.3"), saved)
        try select(.general)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), saved)
        assertNoGlobalSaveControls()
    }

    func testDisplayDetailsPreserveStyleWhenDisabledAndDiscarded() throws {
        var config = Config()
        config.focusBorder = .init(enabled: true, width: 7, color: "#12345678")
        config.accordionPadding = 44
        try load(config)
        try select(.layout)
        let border = try button("Show around the focused window")
        let width = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Border width in points" })
        let spacing = try numberField("Window spacing in points")
        let spacingBefore = spacing.convert(spacing.bounds, to: controller.window?.contentView).minY
        let stack = try XCTUnwrap(border.enclosingScrollView?.documentView?.subviews.first)
        let stackBefore = stack.fittingSize.height
        let window = try XCTUnwrap(controller.window)
        let before = window.frame.height
        let top = window.frame.maxY
        XCTAssertFalse(width.isHiddenOrHasHiddenAncestor)
        border.performClick(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(width.isHiddenOrHasHiddenAncestor)
        XCTAssertLessThan(window.frame.height, before - 8)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        XCTAssertGreaterThan(spacing.convert(spacing.bounds, to: window.contentView).minY, spacingBefore - 80)
        XCTAssertLessThan(stack.fittingSize.height, stackBefore - 8)
        config.focusBorder.enabled = false
        XCTAssertEqual(coordinator.config, config)
        XCTAssertEqual(coordinator.config.preferredMinimum, CGSize(width: 400, height: 300))
        XCTAssertEqual(coordinator.config.accordionPadding, 44)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("width = 7"), saved)
        XCTAssertTrue(saved.contains("#12345678"), saved)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
    }

    /// About shows which version runs and links to the source; the link opens in the browser.
    func testAboutShowsTheVersionAndLinksToTheSource() throws {
        try load(Config())
        var opened: [URL] = []
        controller.openURL = { opened.append($0) }
        controller.bundleInfo = ["CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "202610111200", "NSHumanReadableCopyright": "© 2026 Musashino Software"]
        try select(.about)
        XCTAssertEqual(controller.window?.title, "About")
        // A borderless button draws its title with a text field of its own.
        let texts = views().compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && !($0.superview is NSButton) }.map(\.stringValue).filter { !$0.isEmpty }
        XCTAssertEqual(texts, ["LazySpace", "Version 0.5.0 (202610111200)", "© 2026 Musashino Software"])
        let buttons = views().compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
        XCTAssertEqual(buttons, ["github.com/mssoftjp/LazySpace"], "one link, and without an updater no update section")
        try button("github.com/mssoftjp/LazySpace").performClick(nil)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/mssoftjp/LazySpace"])
        Copy.language = .japanese
        controller.refresh()
        try select(.about)
        XCTAssertEqual(controller.window?.title, "情報")
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "バージョン0.5.0（202610111200）" })
    }

    /// The one notification is chosen in General and saved at once; a line and a button appear only while it is on and macOS does not allow it.
    func testNotificationCheckboxAndPermissionLine() throws {
        try load(Config())
        try select(.general)
        let box = try button("Notify when LazySpace needs your attention")
        XCTAssertEqual(box.state, .off)
        func visibleTexts() -> [String] {
            views().compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
        }
        func visibleButtons() -> [String] {
            views().compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
        }
        // The access row has a button with the same title; this is the one under the notification row.
        func notificationButton() throws -> NSButton {
            try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("notificationButtonClicked") })
        }
        let denied = "Notifications for LazySpace are turned off in System Settings."
        let notYet = "LazySpace is not allowed to send notifications yet."

        let fake = FakeNotifier()
        fake.stored = .denied
        let attention = AttentionNotifier(notifier: fake)
        controller.attention = attention
        attention.refreshPermission()
        XCTAssertFalse(visibleTexts().contains(denied), "nothing while the box is off")

        box.performClick(nil)
        XCTAssertTrue(coordinator.config.notifications.needsAttention)
        XCTAssertTrue(try String(contentsOf: coordinator.configURL).contains("needs-attention = true"))
        XCTAssertTrue(visibleTexts().contains(denied))
        XCTAssertEqual(try notificationButton().title, "Open System Settings…")
        try notificationButton().performClick(nil)
        XCTAssertEqual(fake.settingsOpened, 1)

        fake.stored = .notDetermined
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(visibleTexts().contains(notYet))
        fake.answer = .allowed
        XCTAssertEqual(try notificationButton().title, "Allow Notifications…")
        try notificationButton().performClick(nil)
        XCTAssertEqual(fake.requests, 1)
        XCTAssertFalse(visibleTexts().contains(notYet))
        XCTAssertFalse(visibleButtons().contains("Allow Notifications…"))

        box.performClick(nil)
        XCTAssertFalse(coordinator.config.notifications.needsAttention)
        fake.stored = .denied
        attention.refreshPermission()
        XCTAssertFalse(visibleTexts().contains(denied), "nothing once the box is off again")
    }

    /// A found update waits quietly in About; one button checks or updates, and the pane follows the updater while open.
    func testAboutShowsAnAvailableUpdateAndStartsItOnlyWhenChosen() throws {
        try load(Config())
        let updates = FakeUpdates()
        controller.updates = updates
        try select(.about)
        try button("Check for Updates…").performClick(nil)
        XCTAssertEqual(updates.checks, 1)
        updates.offer = UpdateOffer(version: "0.5.1", build: "202611010000")
        updates.onChange?()
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "LazySpace 0.5.1 is available." })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Check for Updates…" })
        try button("Update…").performClick(nil)
        XCTAssertEqual(updates.checks, 2)
        updates.offer = nil
        updates.onChange?()
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "LazySpace 0.5.1 is available." })
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "Check for Updates…" })
    }

    /// The daily check can be turned off in About; checking by hand still works.
    func testAboutTurnsTheDailyCheckOffAndOn() throws {
        try load(Config())
        let updates = FakeUpdates()
        controller.updates = updates
        try select(.about)
        let box = try button("Automatically check for updates")
        XCTAssertEqual(box.state, .on)
        box.performClick(nil)
        XCTAssertFalse(updates.checksAutomatically)
        try button("Check for Updates…").performClick(nil)
        XCTAssertEqual(updates.checks, 1)
        updates.checksAutomatically = true
        updates.onChange?()
        XCTAssertEqual(box.state, .on)
        box.performClick(nil)
        XCTAssertFalse(updates.checksAutomatically)
        // Changed outside Settings, then About is shown again.
        updates.checksAutomatically = true
        try select(.general)
        try select(.about)
        XCTAssertEqual(box.state, .on)
        Copy.language = .japanese
        controller.refresh()
        try select(.about)
        XCTAssertNoThrow(try button("アップデートを自動的に確認"))
    }

    /// Installing quits LazySpace, so a pending Settings edit is settled first; cancelling starts nothing.
    func testUpdatingSettlesAPendingEditFirst() throws {
        try load(Config())
        let updates = FakeUpdates()
        updates.offer = UpdateOffer(version: "0.5.1", build: "202611010000")
        controller.updates = updates
        try select(.layout)
        try button("Show around the focused window").performClick(nil)
        try setNumberField("Border width in points", "20")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: try numberField("Border width in points")))
        try select(.about)
        controller.leavePrompt = { .cancel }
        try button("Update…").performClick(nil)
        XCTAssertEqual(updates.checks, 0)
        controller.leavePrompt = { .discard }
        try button("Update…").performClick(nil)
        XCTAssertEqual(updates.checks, 1)
    }

    func testPanesPlaceDisplayAndGuideWithoutPresetOrPreferredSize() throws {
        preferences.set("appearance", forKey: "settings.selectedPane")
        try load(Config())
        XCTAssertEqual(SettingsPane.allCases.map(\.rawValue), ["general", "layout", "keys", "apps", "advanced", "about"])
        XCTAssertEqual(controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue), SettingsPane.allCases.map(\.rawValue))
        XCTAssertEqual(controller.window?.title, "General")
        try select(.keys)
        let shortcutsText = views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "Show shortcuts when holding modifier keys" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Show around the focused window" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Show brief status messages" })
        XCTAssertFalse(shortcutsText.contains("Focused Window"))
        XCTAssertFalse(shortcutsText.contains("Border width"))
        XCTAssertFalse(shortcutsText.contains("Preferred size"))
        XCTAssertFalse(shortcutsText.contains("Initial Window Size"))
        try select(.layout)
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "Show around the focused window" })
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Border:" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Show shortcuts when holding modifier keys" })
        try select(.general)
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Show brief status messages" })
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "Display:" })
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "Focused Window" })
        try select(.keys)
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "Show shortcuts when holding modifier keys" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Use Preset" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Add Mode…" })
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "Spaces and Modes" })
        assertNoGlobalSaveControls()
        XCTAssertNil(controller.window?.defaultButtonCell)
    }

    func testRecoveryBannerTakesNoHeightUntilASaveFails() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        let content = try XCTUnwrap(controller.window?.contentView)
        assertNoGlobalSaveControls()
        XCTAssertNil(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings Status" || $0.accessibilityLabel() == "設定の状態" })
        XCTAssertNil(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings Recovery" })
        var tall: [SettingsPane: CGFloat] = [:]
        for pane in SettingsPane.allCases {
            try select(pane)
            tall[pane] = content.bounds.height
            XCTAssertLessThanOrEqual(content.bounds.height, SettingsWindowController.shortcutContentHeight + 1)
        }
        XCTAssertEqual(tall[.keys]!, SettingsWindowController.shortcutContentHeight, accuracy: 1)
        XCTAssertEqual(tall[.apps]!, SettingsWindowController.contentHeightCap, accuracy: 1)
        XCTAssertLessThan(tall[.advanced]!, tall[.apps]! - 8)
        XCTAssertLessThan(tall[.general]!, tall[.apps]! - 8)
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try dialogsBesideButton().performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.bounds.height, SettingsWindowController.contentHeightCap + 1)
        let recovery = try recoveryLabel()
        try assertReadable(recovery)
        try assertRecoveryAttached(recovery)
        XCTAssertEqual(recovery.stringValue, "The file changed. Choose Reload to load it. Nothing was saved.")
        for pane in [SettingsPane.general, .keys, .apps, .advanced, .layout] {
            try select(pane)
            let again = try recoveryLabel()
            try assertRecoveryAttached(again)
            XCTAssertEqual(again.stringValue, recovery.stringValue)
        }
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gap = 9\n")
        XCTAssertNotEqual(coordinator.config.gap, 9)
        let retry = try button("Try Again")
        let reload = try button("Reload")
        XCTAssertEqual(retry.frame.width, retry.intrinsicContentSize.width, accuracy: 1)
        XCTAssertEqual(reload.frame.width, reload.intrinsicContentSize.width, accuracy: 1)
        let retryFrame = retry.convert(retry.bounds, to: content)
        let reloadFrame = reload.convert(reload.bounds, to: content)
        XCTAssertLessThanOrEqual(retryFrame.maxX, reloadFrame.minX + 0.5)
        XCTAssertGreaterThanOrEqual(retryFrame.minY, -1)
        XCTAssertLessThanOrEqual(reloadFrame.maxY, content.bounds.height + 1)
        Copy.language = .japanese
        controller.refresh()
        try button("再試行").performClick(nil)
        let japanese = try recoveryLabel()
        try assertReadable(japanese)
        XCTAssertEqual(japanese.stringValue, "ファイルが変更されています。「再読み込み」で読み込み直してください。保存していません。")
        XCTAssertLessThanOrEqual(content.bounds.height, SettingsWindowController.contentHeightCap + 1)
        XCTAssertGreaterThan(content.bounds.height, 120)
        try button("再読み込み").performClick(nil)
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertNil(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "設定の復旧" })
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
    }

    func testCommentOnlyExternalEditIsKeptAndSemanticEditIsRefused() throws {
        let source = "gap = 0 # 隙間\nplace-dialogs-beside = false\npreferred-minimum = [500, 320] # 希望\n"
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        let commented = source.replacingOccurrences(of: "# 隙間", with: "# 余白")
        try commented.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try dialogsBesideButton().performClick(nil)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("# 余白"), saved)
        XCTAssertTrue(saved.contains("preferred-minimum = [500, 320] # 希望\n"), saved)
        XCTAssertTrue(saved.contains("place-dialogs-beside = true"), saved)
        XCTAssertEqual(coordinator.config.preferredMinimum, CGSize(width: 500, height: 320))

        try select(.layout)
        try setNumberField("Window spacing in points", "nope")
        let external = saved.replacingOccurrences(of: "gap = 0", with: "gap = 9")
        try external.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller.refresh()
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "nope")
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        try dialogsBesideButton().performClick(nil)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), external)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "nope")
        let recovery = try recoveryLabel()
        XCTAssertTrue(recovery.stringValue.contains("Nothing was saved"), recovery.stringValue)
        try button("Reload").performClick(nil)
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "9")
        try dialogsBesideButton().performClick(nil)
        let recovered = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(recovered.contains("gap = 9"), recovered)
        XCTAssertTrue(recovered.contains("# 余白"), recovered)
        XCTAssertTrue(recovered.contains("place-dialogs-beside = false"), recovered)
    }

    func testReloadKeepsADirtyDraftAndInvalidFileIsNotReplaced() throws {
        try load(Config())
        let broken = "this is [ not\n"
        try broken.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try dialogsBesideButton().performClick(nil)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), broken)
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        XCTAssertFalse(coordinator.config.placeDialogsBeside)
        let failure = try recoveryLabel().stringValue
        XCTAssertTrue(failure.contains("Nothing was saved") || failure.contains("not replaced"), failure)
        try button("Reload").performClick(nil)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), broken)
        XCTAssertFalse(coordinator.config.placeDialogsBeside)
        XCTAssertEqual(try dialogsBesideButton().state, .off)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
    }

    func testNoOpDoesNotBackupAndSymlinkRemainsALink() throws {
        let text = "gap = 0 # 隙間\n"
        try text.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        XCTAssertNil(coordinator.saveConfig(coordinator.config, baseline: coordinator.config, source: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.configURL.appendingPathExtension("bak").path))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), text)

        let real = root.appendingPathComponent("real.toml")
        try text.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: coordinator.configURL)
        try FileManager.default.createSymbolicLink(at: coordinator.configURL, withDestinationURL: real)
        _ = coordinator.reloadConfig(source: "test")
        var draft = coordinator.config
        draft.gap = 4
        XCTAssertNil(coordinator.saveConfig(draft, baseline: coordinator.config, source: "test"))
        _ = try FileManager.default.destinationOfSymbolicLink(atPath: coordinator.configURL.path)
        let written = try String(contentsOf: real)
        XCTAssertTrue(written.contains("gap = 4 # 隙間"), written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.configURL.appendingPathExtension("bak").path))
    }

    func testEqualHorizontalGapKeepsTheVerticalLine() throws {
        let source = """
        place-dialogs-beside = false
        [gaps]
        inner-horizontal = 8 # wide
        inner-vertical = 3 # tall

        """
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        XCTAssertEqual(coordinator.config.gap, 8)
        XCTAssertEqual(coordinator.config.gapVertical, 3)
        try select(.layout)
        try setNumberField("Window spacing in points", "3")
        var saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("inner-horizontal = 3 # wide\n"), saved)
        XCTAssertTrue(saved.contains("inner-vertical = 3 # tall\n"), saved)
        XCTAssertEqual(coordinator.config.gap, 3)
        XCTAssertNil(coordinator.config.gapVertical)
        try dialogsBesideButton().performClick(nil)
        saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("inner-vertical = 3 # tall\n"), saved)
        XCTAssertTrue(saved.contains("place-dialogs-beside = true"), saved)
    }

    func testGapTypingDoesNotWriteUntilEditingEnds() throws {
        let source = """
        place-dialogs-beside = false
        [gaps]
        inner-horizontal = 8 # wide
        inner-vertical = 3 # tall

        """
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        try select(.layout)
        let field = try numberField("Window spacing in points")
        field.stringValue = "3"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), source)
        XCTAssertEqual(coordinator.config.gapVertical, 3)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        field.stringValue = "9"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try dialogsBesideButton().performClick(nil)
        var saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("inner-horizontal = 8 # wide\n"), saved)
        XCTAssertTrue(saved.contains("inner-vertical = 3 # tall\n"), saved)
        XCTAssertTrue(saved.contains("place-dialogs-beside = true"), saved)
        XCTAssertEqual(field.stringValue, "9")
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("inner-horizontal = 9 # wide\n"), saved)
        XCTAssertTrue(saved.contains("inner-vertical = 3 # tall\n"), saved)
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertEqual(coordinator.config.gapVertical, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.configURL.appendingPathExtension("bak").path) && saved == source)

        field.stringValue = "9"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), saved)
    }

    func testSaveErrorsStayReadableInEnglishAndJapanese() throws {
        let source = "gap = 1 # keep\n"
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        try "gap = 9 # keep\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try dialogsBesideButton().performClick(nil)
        var error = try recoveryLabel()
        try assertReadable(error)
        XCTAssertEqual(error.stringValue, "The file changed. Choose Reload to load it. Nothing was saved.")
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gap = 9 # keep\n")
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        XCTAssertNotEqual(coordinator.config.placeDialogsBeside, true)
        try button("Try Again").performClick(nil)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gap = 9 # keep\n")

        Copy.language = .japanese
        controller.refresh()
        try button("再試行").performClick(nil)
        error = try recoveryLabel()
        try assertReadable(error)
        XCTAssertEqual(error.stringValue, "ファイルが変更されています。「再読み込み」で読み込み直してください。保存していません。")
        XCTAssertEqual(try button("再試行").frame.width, try button("再試行").intrinsicContentSize.width, accuracy: 1)
        XCTAssertEqual(try button("再読み込み").frame.width, try button("再読み込み").intrinsicContentSize.width, accuracy: 1)

        Copy.language = .english
        try "gaps = { inner-horizontal = 4 }\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        try select(.layout)
        XCTAssertEqual(coordinator.config.gap, 4)
        try setNumberField("Window spacing in points", "1")
        error = try recoveryLabel()
        try assertReadable(error)
        XCTAssertTrue(error.stringValue.contains("Reload"), error.stringValue)
        XCTAssertTrue(error.stringValue.contains("Nothing was saved"), error.stringValue)
        XCTAssertTrue(error.stringValue.contains("[gaps]"), error.stringValue)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "1")
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gaps = { inner-horizontal = 4 }\n")
        try button("Try Again").performClick(nil)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gaps = { inner-horizontal = 4 }\n")

        Copy.language = .japanese
        controller.refresh()
        try button("再試行").performClick(nil)
        error = try recoveryLabel()
        try assertReadable(error)
        XCTAssertTrue(error.stringValue.contains("再読み込み"), error.stringValue)
        XCTAssertTrue(error.stringValue.contains("保存していません"), error.stringValue)
        XCTAssertTrue(error.stringValue.contains("[gaps]"), error.stringValue)
        XCTAssertEqual(try numberField("ウインドウの間隔（ポイント）").stringValue, "1")
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gaps = { inner-horizontal = 4 }\n")
    }

    private func setNumberField(_ label: String, _ value: String) throws {
        let field = try numberField(label)
        field.stringValue = value
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    private func commitNumberField(_ label: String, _ value: String) throws {
        let field = try numberField(label)
        field.stringValue = value
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    private func numberField(_ label: String) throws -> NSTextField {
        try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
    }

    private func assertReadable(_ error: NSTextField) throws {
        XCTAssertFalse(error.isHidden)
        XCTAssertTrue(error.cell?.wraps == true)
        XCTAssertEqual(error.maximumNumberOfLines, 0)
        XCTAssertGreaterThan(error.frame.width, 400)
        let needed = error.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: error.bounds.width, height: 10_000)).height ?? 0
        XCTAssertGreaterThanOrEqual(error.frame.height, needed - 1)
    }

    func testLanguageRebuildRetainsDraftPaneAndNavigation() throws {
        try load(Config())
        try dialogsBesideButton().performClick(nil)
        Copy.language = .japanese
        controller.refresh()
        XCTAssertEqual(controller.window?.title, "整列")
        XCTAssertEqual(controller.window?.toolbar?.selectedItemIdentifier?.rawValue, "layout")
        XCTAssertEqual(preferences.string(forKey: "settings.selectedPane"), "layout")
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        Copy.language = .japanese
        controller.refresh()
        try select(.layout)
        XCTAssertEqual(try dialogsBesideButton().state, .on)
        XCTAssertTrue(coordinator.config.placeDialogsBeside)
        try select(.apps)
        let reopened = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        XCTAssertEqual(reopened.window?.title, "アプリ")
        XCTAssertEqual(reopened.window?.toolbar?.selectedItemIdentifier?.rawValue, "apps")
        reopened.window?.orderOut(nil)
    }

    /// showWindow would order a real window forward. This checks the retained policy only, not Space switching.
    func testMoveToActiveSpaceStaysOnTheSameWindowThroughRefreshAndCleanClose() throws {
        try load(Config())
        let window = try XCTUnwrap(controller.window)
        func assertPolicy() {
            let behavior = window.collectionBehavior
            XCTAssertTrue(behavior.contains(.moveToActiveSpace))
            XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(behavior.contains(.fullScreenAuxiliary))
        }
        assertPolicy()
        XCTAssertFalse(window.isReleasedWhenClosed)
        controller.refresh()
        XCTAssertTrue(controller.window === window)
        assertPolicy()
        XCTAssertFalse(window.isDocumentEdited)
        XCTAssertTrue(controller.windowShouldClose(window))
        window.close()
        XCTAssertTrue(controller.window === window)
        assertPolicy()
    }

    func testShortcutSectionsKeepAssignedAdjacentKeysAndFilterWhileSearching() throws {
        var config = Config()
        config.keys["space-3"] = .init(modifiers: [], key: "f3")
        config.keys["space-next"] = .init(modifiers: ["alt", "shift"], key: "tab")
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        assertRow("Switch to Last Used Space", in: table)
        assertRow("Numbered Desktop Switching", in: table)
        assertRow("Next/Previous Space in LazySpace", in: table)
        let space3 = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        XCTAssertEqual(shortcutText(in: table, row: space3), "F3")
        keySearch().stringValue = "focus"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: keySearch()))
        XCTAssertNil(row(labeled: "Switch to Desktop 1", in: table))
        let selectedDuringSearch = table.selectedRow
        if selectedDuringSearch >= 0 {
            XCTAssertEqual(rowLabel(in: table, row: selectedDuringSearch), "Switch to Desktop 3")
        }
        keySearch().stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: keySearch()))
        let restored = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        table.selectRowIndexes(IndexSet(integer: restored), byExtendingSelection: false)
        keySearch().stringValue = "window"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: keySearch()))
        if table.selectedRow >= 0 {
            XCTAssertEqual(rowLabel(in: table, row: table.selectedRow), "Switch to Desktop 3")
        }
        keySearch().stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: keySearch()))
        XCTAssertEqual(rowLabel(in: table, row: table.selectedRow), "Switch to Desktop 3")
    }

    func testRemovingShortcutsSavesAndHidesOnlyTheEmptyAdjacentSection() throws {
        let source = """
        gap = 0
        [keys]
        focus-left = "alt-h"
        space-3 = "f3"
        space-next = "alt-shift-tab"
        space-prev = "alt-ctrl-tab"

        """
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        try select(.keys)
        let table = try shortcutTable()
        let space3 = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        table.selectRowIndexes(IndexSet(integer: space3), byExtendingSelection: false)
        try performShortcutAction(2)
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "")
        var saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("space-3 = \"none\""), saved)
        XCTAssertTrue(saved.contains("space-next = \"alt-shift-tab\""), saved)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)

        let next = try XCTUnwrap(row(labeled: "Switch to Next Space", in: table))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        try performShortcutAction(2)
        saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("space-next = \"none\""), saved)
        XCTAssertTrue(saved.contains("space-3 = \"none\""), saved)
        XCTAssertTrue(saved.contains("focus-left = \"alt-h\""), saved)
        XCTAssertNotNil(row(labeled: "Next/Previous Space in LazySpace", in: table))
        XCTAssertNil(row(labeled: "Switch to Next Space", in: table))
        let previous = try XCTUnwrap(row(labeled: "Switch to Previous Space", in: table))
        selectShortcutRow(previous, in: table)
        try performShortcutAction(2)
        XCTAssertNil(coordinator.config.keys["space-prev"])
        XCTAssertNil(row(labeled: "Next/Previous Space in LazySpace", in: table))
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "")
    }

    func testDiscardingFailedAdjacentRemovalRestoresItsAssignment() throws {
        var config = Config()
        config.keys["space-next"] = .init(modifiers: ["alt", "shift"], key: "tab")
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        var external = config
        external.gap = 9
        try external.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        selectShortcutRow(try XCTUnwrap(row(labeled: "Switch to Next Space", in: table)), in: table)
        try performShortcutAction(2)
        XCTAssertTrue(controller.window?.isDocumentEdited == true)
        XCTAssertEqual(coordinator.config.keys["space-next"], config.keys["space-next"])
        XCTAssertNotNil(row(labeled: "Next/Previous Space in LazySpace", in: table))
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Next Space", in: table))), "")
        controller.leavePrompt = { .discard }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        XCTAssertEqual(coordinator.config.gap, 9)
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Next Space", in: table))), "⌥⇧⇥")
        XCTAssertNotNil(row(labeled: "Next/Previous Space in LazySpace", in: table))
    }

    func testDirectionGroupOffersNoUnmodifiedKeys() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let before = coordinator.config.keys["focus-left"]
        let focusCell = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
        XCTAssertFalse(popups(in: focusCell).contains { popup in
            popup.itemArray.contains { ($0.representedObject as? String) == "none" }
        })
        XCTAssertEqual(coordinator.config.keys["focus-left"], before)
        XCTAssertEqual(directionSelection(in: table, row: 0, tag: 1), "alt")
    }

    func testInvalidNumberSurvivesPaneChangesAndDoesNotSave() throws {
        try load(Config())
        try select(.layout)
        try button("Show around the focused window").performClick(nil)
        try setNumberField("Border width in points", "20")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: try numberField("Border width in points")))
        try select(.general)
        try select(.keys)
        try select(.layout)
        let field = try numberField("Border width in points")
        XCTAssertEqual(field.stringValue, "20")
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Enter a number from 1 to 12." })
        XCTAssertTrue(controller.window?.isDocumentEdited == true)
        let original = try String(contentsOf: coordinator.configURL)
        XCTAssertFalse(original.contains("width = 20"))
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "Settings saved." })
        controller.leavePrompt = { .retry }
        XCTAssertFalse(controller.resolveLeave())
        XCTAssertEqual(field.stringValue, "20")
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), original)
        controller.leavePrompt = { .cancel }
        XCTAssertFalse(controller.resolveLeave())
        controller.leavePrompt = { .discard }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertEqual(try numberField("Border width in points").stringValue, "3")
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), original)
    }

    func testExternalFileChangePreservesTheDraftAndABrokenFileShowsOnEveryPane() throws {
        try load(Config())
        try select(.layout)
        try setNumberField("Window spacing in points", "nope")
        let edited = try String(contentsOf: coordinator.configURL).replacingOccurrences(of: "gap = 0", with: "gap = 12")
        try edited.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller.refresh()
        let notice = try recoveryLabel()
        XCTAssertFalse(notice.isHidden)
        XCTAssertEqual(notice.stringValue, "The file changed. Choose Reload to load it. Nothing was saved.")
        XCTAssertTrue(notice.cell?.wraps == true)
        let needed = notice.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: notice.bounds.width, height: 10_000)).height ?? 0
        XCTAssertGreaterThanOrEqual(notice.frame.height, needed - 1)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "nope")
        XCTAssertEqual(coordinator.config.gap, 12)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), edited)
        try button("Reload").performClick(nil)
        XCTAssertEqual(coordinator.config.gap, 12)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "12")

        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        try "gap = 4\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller.refresh()
        XCTAssertEqual(coordinator.config.gap, 4)
        XCTAssertNil(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings Recovery" })

        let broken = "this is [ not\n"
        try broken.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller.refresh()
        try select(.general)
        let banner = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "The configuration file could not be applied." })
        XCTAssertFalse(banner.isHiddenOrHasHiddenAncestor)
        try button("Show Details").performClick(nil)
        XCTAssertEqual(controller.window?.title, "Advanced")
        XCTAssertTrue(views().compactMap { $0 as? NSTextField }.contains { $0.textColor == .systemRed && !$0.stringValue.isEmpty })
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), broken)
    }

    func testAppsEmptyStateMinusButtonAndFloatingRules() throws {
        try load(Config())
        try select(.apps)
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Windows of these apps aren't arranged." })
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "No apps are excluded." })
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "Add an app to keep its windows out of the arrangement." })
        let table = try appsTable()
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertLessThan(table.selectedRow, 0)
        XCTAssertFalse(try button("−").isEnabled)
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "No apps\nClick + to add one." })
        XCTAssertNil(table.headerView)
        XCTAssertTrue(controller.preparedAddRuleMenu().items.contains { $0.title == "Enter Bundle Identifier…" })
        try addListedApp()
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "No apps are excluded." })
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(try button("−").isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertTrue(try button("−").isEnabled)

        Copy.language = .japanese
        controller.refresh()
        try select(.apps)
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "アプリはありません\n＋ で追加します。" })
        XCTAssertNil(try appsTable().headerView)
        Copy.language = .english
        controller.refresh()

        var floating = Config()
        floating.rules = [
            .init(app: "us.zoom.xos", action: .float),
            .init(app: "com.apple.Safari", action: .ignore, title: "Copy"),
        ]
        try load(floating)
        try select(.apps)
        let labels = views().compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("Floating"))
        XCTAssertTrue(labels.contains("Title condition"))
        XCTAssertEqual(labels.filter { $0 == "Floating" }.count, 1)
    }

    func testSavingKeepsFileOnlyDurationModesAndDoesNotInventKeys() throws {
        var config = Config()
        config.accordionPadding = 44
        config.modes["resize"] = .init(keys: ["focus-left": .init(modifiers: [], key: "h")], returnToMain: true)
        config.gapsOuterForTest()
        try load(config)
        try select(.keys)
        XCTAssertTrue(views().compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("resize") && $0.stringValue.contains("aren't shown here") })
        try dialogsBesideButton().performClick(nil)
        XCTAssertEqual(coordinator.config.accordionPadding, 44)
        XCTAssertEqual(coordinator.config.modes["resize"]?.keys["focus-left"]?.key, "h")
        XCTAssertEqual(coordinator.config.placeDialogsBeside, true)
        let rendered = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(rendered.contains("accordion-padding = 44"), rendered)
        XCTAssertTrue(rendered.contains("[mode.resize]"), rendered)
        XCTAssertFalse(rendered.contains("space-next ="))
    }

    func testShortcutOwnershipCopyInEnglishAndJapanese() throws {
        try load(Config())
        controller.nativeShortcutReader = { right in
            right ? .disabled : .usable(keyCode: 123, modifiers: ["ctrl"])
        }
        try select(.keys)
        controller.refresh()
        let table = try shortcutTable()
        let numbered = try XCTUnwrap(row(labeled: "Numbered Desktop Switching", in: table))
        XCTAssertEqual(rowLabel(in: table, row: numbered), "Numbered Desktop Switching", "the section shows its title without a description")
        let english = try switchingStatus()
        XCTAssertTrue(english.contains("“Move right a Space” is off in macOS."), english)
        XCTAssertTrue(english.contains("turn on “Move left a Space” and “Move right a Space” and assign keys to them"), english)
        XCTAssertFalse(english.contains("Sending only a window"), english)
        XCTAssertFalse(english.contains("After you save"), english)
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "Open Keyboard Settings…" })
        XCTAssertTrue(try switchingStatus().contains("Keyboard Shortcuts… › Mission Control") || views().contains { ($0 as? NSTextField)?.stringValue == "Keyboard Shortcuts… › Mission Control" })
        XCTAssertFalse(try shortcutActionEnabled(2))
        XCTAssertFalse(try shortcutActionEnabled(3))
        XCTAssertFalse(try shortcutActionEnabled(1))
        Copy.language = .japanese
        controller.refresh()
        try select(.layout)
        XCTAssertEqual(controller.window?.title, "整列")
        try select(.keys)
        let japaneseTable = try shortcutTable()
        let japaneseNumbered = try XCTUnwrap(row(labeled: "番号でデスクトップを切り替える", in: japaneseTable))
        XCTAssertEqual(rowLabel(in: japaneseTable, row: japaneseNumbered), "番号でデスクトップを切り替える")
        let japanese = try switchingStatus()
        XCTAssertTrue(japanese.contains("macOSの「右の操作スペースに移動」がオフです。"), japanese)
        XCTAssertTrue(japanese.contains("「左の操作スペースに移動」と「右の操作スペースに移動」をオンにしてキーを割り当ててください。"), japanese)
        XCTAssertFalse(japanese.contains("だけを送る"), japanese)
        XCTAssertFalse(japanese.contains("保存すると"), japanese)
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "キーボード設定を開く…" })
    }

    func testPendingAndConfiguredNativeConflictsStayDistinct() throws {
        try load(Config())
        controller.nativeShortcutReader = { right in
            right ? .usable(keyCode: 124, modifiers: ["alt", "cmd"]) : .usable(keyCode: 123, modifiers: ["ctrl"])
        }
        try select(.keys)
        controller.refresh()
        XCTAssertNil(shownSwitchingStatus(), "no conflict, nothing to show")
        let table = try shortcutTable()
        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        let configured = try switchingStatus()
        XCTAssertTrue(configured.contains("With these settings"), configured)
        XCTAssertFalse(configured.contains("After you save"), configured)
        let configuredFile = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(configuredFile.contains("ctrl-left"), configuredFile)
        XCTAssertTrue(configured.contains("left"), configured)
        XCTAssertFalse(configured.contains("to the right won't work"))
        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        selectShortcutRow(focus, in: table)
        try performShortcutAction(2)
        XCTAssertNil(shownSwitchingStatus(), "removing the conflicting key empties the area")
        let removedFile = try String(contentsOf: coordinator.configURL)
        XCTAssertFalse(removedFile.contains("ctrl-left"), removedFile)
    }

    func testSpaceShortcutAreaShowsAWarningOnlyWhenTheUserMustAct() throws {
        try load(Config())
        var announced: [String] = []
        controller.announcementObserver = { announced.append($0) }
        controller.nativeShortcutReader = { right in .usable(keyCode: right ? 124 : 123, modifiers: ["ctrl"]) }
        var arrows: (left: DesktopShortcuts.State, right: DesktopShortcuts.State)? = (.unverified, .working)
        controller.arrowStateReader = { arrows }
        try select(.keys)
        controller.refresh()
        XCTAssertNil(shownSwitchingStatus(), "usable shortcuts without a conflict show nothing")
        XCTAssertFalse(keyboardSettingsShown())
        XCTAssertFalse(detailedStatusExists())
        XCTAssertEqual(announced, [], "the empty state is not announced")

        controller.nativeShortcutReader = { right in right ? .disabled : .usable(keyCode: 123, modifiers: ["ctrl"]) }
        controller.refresh()
        let off = try XCTUnwrap(shownSwitchingStatus())
        XCTAssertTrue(off.hasPrefix("“Move right a Space” is off in macOS."), off)
        let label = try XCTUnwrap(switchingStatusLabel())
        let icon = try XCTUnwrap(label.superview?.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertEqual(label.textColor, .labelColor, "The full explanation is readable text, with color confined to the warning icon")
        XCTAssertFalse(icon.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(keyboardSettingsShown())
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Keyboard Shortcuts… › Mission Control" && !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(detailedStatusExists())
        XCTAssertEqual(announced, [off], "a warning that appears is announced")

        controller.nativeShortcutReader = { right in .usable(keyCode: right ? 124 : 123, modifiers: ["ctrl"]) }
        arrows = (.working, .paused)
        controller.refresh()
        let paused = try XCTUnwrap(shownSwitchingStatus())
        XCTAssertEqual(paused, "macOS is not responding to “Move right a Space”, so stepwise Space switching to the right won't work.\nLogging out of your Mac and back in may resolve this.")
        XCTAssertFalse(paused.contains("Dock"), paused)
        XCTAssertFalse(keyboardSettingsShown(), "no Keyboard Settings button for a shortcut macOS does not respond to")
        XCTAssertFalse(detailedStatusExists())
        XCTAssertEqual(announced, [off, paused], "a changed warning is announced")

        arrows = (.working, .working)
        controller.refresh()
        XCTAssertNil(shownSwitchingStatus(), "removing the cause empties the area")
        XCTAssertFalse(keyboardSettingsShown())
        XCTAssertFalse(detailedStatusExists())
        XCTAssertEqual(announced, [off, paused], "returning to the empty state is not announced")

        arrows = nil
        controller.nativeShortcutReader = { _ in .unread }
        controller.refresh()
        XCTAssertNil(shownSwitchingStatus(), "unreadable shortcuts and missing Space detection show nothing")
        XCTAssertFalse(keyboardSettingsShown())
    }

    func testSearchRestoresTheSelectedDirectionAndLeavesHiddenGroups() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        selectShortcutRow(focus, in: table)
        searchShortcuts("swap")
        XCTAssertNil(row(labeled: "Focus", in: table))
        XCTAssertEqual(table.selectedRow, -1)
        searchShortcuts("")
        let restored = try XCTUnwrap(row(labeled: "Focus", in: table))
        XCTAssertEqual(table.selectedRow, restored)
        XCTAssertEqual(rowLabel(in: table, row: restored), "Focus")
        XCTAssertEqual(directionSelection(in: table, row: restored, tag: 1), "alt")
        searchShortcuts("swap")
        let swap = try XCTUnwrap(row(labeled: "Swap", in: table))
        selectShortcutRow(swap, in: table)
        try performShortcutAction(2)
        searchShortcuts("")
        XCTAssertEqual(directionSelection(in: table, row: try XCTUnwrap(row(labeled: "Focus", in: table)), tag: 1), "alt")
        XCTAssertEqual(directionSelection(in: table, row: try XCTUnwrap(row(labeled: "Swap", in: table)), tag: 1), "custom")
    }

    func testRemovingAVisibleShortcutWhileSearchingLeavesHiddenAssignments() throws {
        var config = Config()
        config.keys["space-1"] = .init(modifiers: [], key: "f1")
        config.keys["space-3"] = .init(modifiers: [], key: "f3")
        config.keys["space-next"] = .init(modifiers: ["alt", "shift"], key: "tab")
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        searchShortcuts("Desktop 3")
        XCTAssertNil(row(labeled: "Switch to Desktop 1", in: table))
        XCTAssertNil(row(labeled: "Switch to Next Space", in: table))
        let visible = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        selectShortcutRow(visible, in: table)
        try performShortcutAction(2)
        searchShortcuts("")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 1", in: table))), "F1")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Next Space", in: table))), "⌥⇧⇥")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "")
        XCTAssertEqual(directionSelection(in: table, row: try XCTUnwrap(row(labeled: "Focus", in: table)), tag: 1), "alt")
    }

    func testFlexibleTablesUseLeftoverHeightAtANormalWindow() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let keysTable = try shortcutTable()
        let keysViewport = try XCTUnwrap(keysTable.enclosingScrollView)
        let keysOuter = try XCTUnwrap(keysViewport.enclosingScrollView)
        let keysClip = keysOuter.contentView.bounds.height
        let keysDocument = keysOuter.documentView?.frame.height ?? 0
        XCTAssertGreaterThanOrEqual(keysTable.numberOfRows, 20)
        XCTAssertGreaterThanOrEqual(fullyVisibleRowCount(keysTable), 6, "keys viewport \(keysViewport.frame.height) clip \(keysClip) document \(keysDocument)")
        XCTAssertLessThanOrEqual(keysDocument, keysClip + 1, "keys document \(keysDocument) overflows clip \(keysClip)")
        XCTAssertGreaterThanOrEqual(keysDocument, keysClip - 2, "keys document \(keysDocument) left unused space in clip \(keysClip)")
        XCTAssertGreaterThan(keysTable.headerView?.bounds.height ?? 0, 1)

        try select(.advanced)
        let fileHeading = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "Configuration File" })
        try assertFileActionsFit(in: try XCTUnwrap(fileHeading.enclosingScrollView).contentView)
    }

    func testShortcutSectionsAreTextOnlyAndNotSelectable() throws {
        var config = Config()
        config.keys["space-3"] = .init(modifiers: [], key: "f3")
        config.keys["space-next"] = .init(modifiers: ["alt", "shift"], key: "tab")
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        XCTAssertEqual(table.style, .inset)
        XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
        for section in ShortcutSection.allCases {
            let title = section.title
            let index = try XCTUnwrap(groupRow(titled: title, in: table), title)
            XCTAssertTrue(controller.tableView(table, isGroupRow: index), title)
            XCTAssertFalse(controller.tableView(table, shouldSelectRow: index), title)
            XCTAssertNil(controller.tableView(table, viewFor: table.tableColumns[0], row: index), title)
            let span = try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true), title)
            XCTAssertTrue(descendants(span).contains { ($0 as? NSTextField)?.stringValue == title }, title)
            XCTAssertFalse(descendants(span).contains { $0 is NSButton }, title)
            if !section.detail.isEmpty {
                XCTAssertTrue(descendants(span).contains { ($0 as? NSTextField)?.stringValue == section.detail }, title)
            }
        }
        let command = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        XCTAssertTrue(controller.tableView(table, shouldSelectRow: command))
        XCTAssertFalse(controller.tableView(table, isGroupRow: command))
        selectShortcutRow(command, in: table)
        try performShortcutAction(2)
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "")
    }

    func testShortcutStatusHeightStaysFixedAcrossPromptResultAndWarning() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let content = try XCTUnwrap(controller.window?.contentView)
        let height = content.bounds.height
        XCTAssertEqual(height, SettingsWindowController.shortcutContentHeight, accuracy: 1)
        let message = try XCTUnwrap(shortcutMessageLabel())
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(message.isHidden)
        XCTAssertEqual(message.stringValue, "")
        XCTAssertEqual(message.maximumNumberOfLines, 1)
        let reserved = message.frame.height
        let restore = try button("Restore Defaults")
        XCTAssertGreaterThan(reserved, 8, "the message has no line: \(reserved)")
        XCTAssertLessThanOrEqual(reserved, restore.frame.height + 1, "the message is taller than the button row: \(reserved)")
        let restoreMinY = restore.convert(restore.bounds, to: content).minY
        let tableHeight = try XCTUnwrap(try shortcutTable().enclosingScrollView).frame.height

        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        content.layoutSubtreeIfNeeded()
        let prompt = try XCTUnwrap(shortcutMessageLabel())
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertEqual(prompt.frame.height, reserved, accuracy: 1)
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertEqual(restore.convert(restore.bounds, to: content).minY, restoreMinY, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(try shortcutTable().enclosingScrollView).frame.height, tableHeight, accuracy: 1)
        XCTAssertEqual(content.bounds.height, height, accuracy: 1)

        try cancelSelectedRecording()
        content.layoutSubtreeIfNeeded()
        let canceled = try XCTUnwrap(shortcutMessageLabel())
        XCTAssertEqual(canceled.stringValue, "")
        XCTAssertEqual(canceled.frame.height, reserved, accuracy: 1)
        XCTAssertEqual(restore.convert(restore.bounds, to: content).minY, restoreMinY, accuracy: 1)

        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let warnedContent = try XCTUnwrap(controller.window?.contentView)
        warnedContent.layoutSubtreeIfNeeded()
        let again = try XCTUnwrap(shortcutMessageLabel())
        let againHeight = again.frame.height
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        try beginSelectedRecording()
        sendKey(0) // A without a modifier is not allowed. Recording continues and shows why.
        warnedContent.layoutSubtreeIfNeeded()
        let warning = try XCTUnwrap(shortcutMessageLabel())
        XCTAssertTrue(warning.stringValue.contains("modifier key"), warning.stringValue)
        XCTAssertEqual(warning.frame.height, againHeight, accuracy: 1)
        XCTAssertEqual(warning.toolTip, warning.stringValue)
        XCTAssertEqual(warning.accessibilityHelp(), warning.stringValue)
        XCTAssertEqual(warnedContent.bounds.height, SettingsWindowController.shortcutContentHeight, accuracy: 1)
        XCTAssertTrue(try selectedCellIsRecording())

        Copy.language = .japanese
        controller.refresh()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.height, SettingsWindowController.shortcutContentHeight, accuracy: 1)
        let rebuilt = try XCTUnwrap(shortcutMessageLabel())
        XCTAssertFalse(rebuilt.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(rebuilt.maximumNumberOfLines, 1)
        XCTAssertGreaterThan(rebuilt.frame.height, 8)
        XCTAssertLessThanOrEqual(rebuilt.frame.height, try button("デフォルトに戻す").frame.height + 1)
    }

    /// The Advanced pane has only the configuration file section (no external commands).
    func testAdvancedPaneHasNoExternalCommands() throws {
        try load(Config())
        try select(.advanced)
        let texts = views().compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertFalse(texts.contains { $0.contains("External Command") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Configuration File") }, "\(texts)")
    }

    func testEmptyAppsPaneKeepsTheTable() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.apps)
        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try appsTable()
        let emptyHeight = content.bounds.height
        let tableHeight = try XCTUnwrap(table.enclosingScrollView).frame.height
        let remove = try button("−")
        let removeBefore = remove.convert(remove.bounds, to: content)
        XCTAssertEqual(emptyHeight, SettingsWindowController.contentHeightCap, accuracy: 1)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertLessThan(table.selectedRow, 0)
        XCTAssertFalse(remove.isEnabled)
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "No apps are excluded." })
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Windows of these apps aren't arranged." })

        let add = try addAppButton()
        let addBefore = add.convert(add.bounds, to: content)
        try addListedApp()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.height, emptyHeight, accuracy: 1)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(try XCTUnwrap(table.enclosingScrollView).frame.height, tableHeight, accuracy: 1)
        XCTAssertEqual(remove.convert(remove.bounds, to: content).minY, removeBefore.minY, accuracy: 1)
        XCTAssertEqual(add.convert(add.bounds, to: content).minY, addBefore.minY, accuracy: 1)
        XCTAssertTrue(remove.isEnabled)
        try button("−").performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.height, emptyHeight, accuracy: 1)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertLessThan(table.selectedRow, 0)
        XCTAssertFalse(try button("−").isEnabled)
        XCTAssertEqual(try XCTUnwrap(table.enclosingScrollView).frame.height, tableHeight, accuracy: 1)
        XCTAssertEqual(remove.convert(remove.bounds, to: content).minY, removeBefore.minY, accuracy: 1)
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testRetiredSpaceNameRuleShowsConfigurationError() throws {
        try load(Config())
        pumpMain()
        let settings = controller
        let owner = coordinator
        coordinator.onConfigStatus = { [weak settings, weak owner] message in
            settings?.applyConfigStatus(message, isError: owner?.configError != nil)
        }
        try "[[rule]]\napp = \"com.example.app\"\naction = \"space\"\nspace = \"7\"\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "file")
        pumpMain()
        XCTAssertNotNil(coordinator.configError)
        let banner = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first {
            $0.stringValue == SettingsCopy.configBannerMessage
        })
        XCTAssertFalse(banner.isHiddenOrHasHiddenAncestor)
        try select(.advanced)
        XCTAssertTrue(views().compactMap { $0 as? NSTextField }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("rule[0]")
        })
        XCTAssertFalse(views().compactMap { $0 as? NSTextField }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == SettingsCopy.configNotesMessage
        })
    }

    func testConfigStatusUpdatesTheBannerWithoutRefreshingOrStoppingRecording() throws {
        try load(Config())
        pumpMain()
        try select(.keys)
        try button("Show shortcuts when holding modifier keys").performClick(nil)
        pumpMain()
        let table = try shortcutTable()
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        selectShortcutRow(arrange, in: table)
        var recordingStates: [Bool] = []
        controller.onRecording = { recordingStates.append($0) }
        try beginSelectedRecording()
        defer { try? select(.general) }
        XCTAssertEqual(recordingStates, [true])
        var configChanges = 0
        coordinator.onConfigChange = { _ in configChanges += 1 }
        let settings = controller
        coordinator.onConfigStatus = { [weak settings] error in
            settings?.applyConfigStatus(error)
        }
        // AppDelegate runs this update only while the Settings window is visible. This window stays offscreen, so the test installs that update directly.
        func banner() -> NSTextField? {
            views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "The configuration file could not be applied." }
        }
        XCTAssertTrue(banner()?.isHiddenOrHasHiddenAncestor == true)

        try "this is [ not\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "file")
        pumpMain()
        XCTAssertEqual(configChanges, 0)
        XCTAssertEqual(recordingStates, [true])
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertEqual(try button("Show shortcuts when holding modifier keys").state, .off)
        XCTAssertFalse(try XCTUnwrap(banner()).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(controller.window?.title, "Shortcuts")

        try select(.general)
        XCTAssertFalse(try XCTUnwrap(banner()).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(recordingStates, [true, false])

        try select(.keys)
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        try beginSelectedRecording()
        XCTAssertEqual(recordingStates, [true, false, true])
        try FileManager.default.removeItem(at: coordinator.configURL)
        try FileManager.default.createDirectory(at: coordinator.configURL, withIntermediateDirectories: true)
        let unreadable = coordinator.reloadConfig(source: "file")
        pumpMain()
        XCTAssertEqual(configChanges, 0)
        XCTAssertTrue(unreadable.contains("Could not read the configuration file"))
        XCTAssertEqual(recordingStates, [true, false, true])
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertFalse(try XCTUnwrap(banner()).isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(try button("Show shortcuts when holding modifier keys").state, .off)
        try select(.advanced)
        XCTAssertTrue(views().compactMap { $0 as? NSTextField }.contains { $0.textColor == .systemRed && $0.stringValue.contains("Could not read the configuration file") })
        XCTAssertFalse(controller.window?.isDocumentEdited == true)

        let restored = Config().render()
        try FileManager.default.removeItem(at: coordinator.configURL)
        try restored.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "file")
        pumpMain()
        XCTAssertEqual(configChanges, 1)
        XCTAssertEqual(banner()?.isHiddenOrHasHiddenAncestor, true)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
    }

    func testRecordingANumberedShortcutUpdatesRowActionsWithoutRefresh() throws {
        var config = Config()
        config.keys["space-3"] = nil
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        let space3 = try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))
        selectShortcutRow(space3, in: table)
        XCTAssertFalse(try shortcutActionEnabled(2))
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        try beginSelectedRecording()
        sendKey(99)
        XCTAssertEqual(recording, [true, false])
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "F3")
        XCTAssertEqual(rowLabel(in: table, row: table.selectedRow), "Switch to Desktop 3")
        XCTAssertTrue(try shortcutActionEnabled(2))
        XCTAssertTrue(try shortcutActionEnabled(3))
        let message = try messageText()
        XCTAssertEqual(message, "")
        XCTAssertFalse(message.contains("Press a key"))

        let zoom = try XCTUnwrap(row(labeled: "Fill Work Area", in: table))
        selectShortcutRow(zoom, in: table)
        try beginSelectedRecording()
        sendKey(3, modifiers: .option)
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Fill Work Area", in: table))), "⌥F")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: table))), "")
        XCTAssertTrue(try messageText().contains("Toggle Tiling for Window"))
    }

    func testEndingRecordingClearsThePromptAndShowDetailsStopsIt() throws {
        try load(Config())
        try select(.layout)
        try button("Show around the focused window").performClick(nil)
        try setNumberField("Border width in points", "20")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: try numberField("Border width in points")))
        try select(.keys)
        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        try beginSelectedRecording()
        XCTAssertFalse(try messageText().contains("Press a key"))
        try select(.layout)
        try select(.keys)
        XCTAssertEqual(recording, [true, false])
        XCTAssertFalse(try messageText().contains("Press a key"))
        XCTAssertFalse(try selectedCellIsRecording())

        try button("Show shortcuts when holding modifier keys").performClick(nil)
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        try beginSelectedRecording()
        controller.leavePrompt = { .cancel }
        XCTAssertFalse(controller.resolveLeave())
        XCTAssertEqual(recording, [true, false, true, false])
        XCTAssertFalse(try messageText().contains("Press a key"))
        XCTAssertEqual(try button("Show shortcuts when holding modifier keys").state, .off)
        XCTAssertTrue(controller.window?.isDocumentEdited == true)

        let keys = try shortcutTable()
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: keys))
        selectShortcutRow(arrange, in: keys)
        let arrangeBefore = shortcutText(in: keys, row: arrange)
        try beginSelectedRecording()
        try "this is [ not\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        coordinator.onConfigStatus = { [weak controller] error in controller?.applyConfigStatus(error) }
        _ = coordinator.reloadConfig(source: "file")
        pumpMain()
        try button("Show Details").performClick(nil)
        XCTAssertEqual(controller.window?.title, "Advanced")
        XCTAssertEqual(recording.last, false)
        let visibleText = views().compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        XCTAssertFalse(visibleText.contains("Press a key"))
        sendKey(99)
        XCTAssertEqual(shortcutText(in: keys, row: arrange), arrangeBefore)
        try select(.layout)
        XCTAssertEqual(try numberField("Border width in points").stringValue, "20")
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Enter a number from 1 to 12." })
        XCTAssertTrue(controller.window?.isDocumentEdited == true)
    }

    func testLowercaseAndOpaqueBorderColorStayCleanUntilTheColorChanges() throws {
        var lowercase = Config()
        lowercase.focusBorder.enabled = true
        lowercase.focusBorder.color = "#4c8dff"
        try load(lowercase)
        try exerciseBorderColorWithoutEditingIt()
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        XCTAssertTrue(try String(contentsOf: coordinator.configURL).contains("#4c8dff"))

        var opaque = Config()
        opaque.focusBorder.enabled = true
        opaque.focusBorder.color = "#4C8DFFFF"
        try load(opaque)
        try exerciseBorderColorWithoutEditingIt()
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        XCTAssertTrue(try String(contentsOf: coordinator.configURL).contains("#4C8DFFFF"))

        try select(.layout)
        let well = try XCTUnwrap(views().compactMap { $0 as? NSColorWell }.first)
        well.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        _ = controller.perform(try XCTUnwrap(well.action), with: well)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("#0000FF"), saved)
        XCTAssertFalse(saved.contains("#4C8DFFFF"))
    }

    func testRestoreDefaultDisplacesTheOtherCommand() throws {
        try load(Config())
        try select(.keys)
        let fresh = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Fill Work Area", in: fresh)), in: fresh)
        try beginSelectedRecording()
        sendKey(3, modifiers: .option)
        try beginSelectedRecording()
        let restore = try XCTUnwrap(controller.contextMenuItem(tag: 3, clickedRow: try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: fresh))))
        XCTAssertTrue(restore.isEnabled)
        XCTAssertEqual(restore.title, "Restore Default")
        _ = controller.perform(try XCTUnwrap(restore.action), with: restore)
        XCTAssertFalse(try selectedCellIsRecording(), "Restoring the clicked row ends capture on the selected row")
        XCTAssertEqual(shortcutText(in: fresh, row: try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: fresh))), "⌥F")
        XCTAssertEqual(shortcutText(in: fresh, row: try XCTUnwrap(row(labeled: "Fill Work Area", in: fresh))), "")
        XCTAssertTrue(try messageText().contains("Fill Work Area"))
        XCTAssertEqual(coordinator.config.keys["float"], Config.Key(modifiers: ["alt"], key: "f"))
        XCTAssertNil(coordinator.config.keys["zoom"])
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertEqual(saved.components(separatedBy: "alt-f").count - 1, 1, saved)
        XCTAssertFalse(saved.contains("could not keep"))
    }

    func testRestoreMainShortcutsKeepsModes() throws {
        try load(Config())
        try select(.keys)
        let builtIn = views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
        XCTAssertFalse(builtIn.contains("Service mode is built in"), builtIn)
        XCTAssertFalse(builtIn.contains("aren't shown here"))
        XCTAssertNil(row(labeled: "Enter Service Mode", in: try shortcutTable()))
        XCTAssertFalse(try button("Restore Defaults").isEnabled)

        let source = """
        gap = 8 # keep
        [mode.resize]
        return-to-main = true
        [mode.resize.keys]
        focus-left = "h" # mode key
        [mode.service]
        return-to-main = false
        [mode.service.keys]
        mode-main = "esc" # stay
        arrange = "r"
        [keys]
        focus-left = "alt-left" # moved
        zoom = "none"

        """
        try source.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let reloaded = coordinator.reloadConfig(source: "test")
        XCTAssertNil(coordinator.configError, reloaded)
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        var confirmed = 0
        controller.confirmMainShortcutReset = { confirmed += 1; return true }
        try select(.keys)
        XCTAssertNil(row(labeled: "Enter Service Mode", in: try shortcutTable()))
        let fileNote = views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(fileNote.contains("resize") && fileNote.contains("aren't shown here"), fileNote)
        XCTAssertTrue(fileNote.contains("service"), fileNote)
        try button("Restore Defaults").performClick(nil)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(coordinator.config.keys, Config.defaultKeys)
        XCTAssertEqual(coordinator.config.modes["resize"]?.keys["focus-left"]?.key, "h")
        XCTAssertEqual(coordinator.config.modes["service"]?.returnToMain, false)
        XCTAssertEqual(coordinator.config.modes["service"]?.keys["mode-main"]?.key, "esc")
        XCTAssertNil(coordinator.config.modes["service"]?.keys["join-left"])
        XCTAssertEqual(coordinator.config.gap, 8)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("gap = 8 # keep"), saved)
        XCTAssertTrue(saved.contains("focus-left = \"h\" # mode key"), saved)
        XCTAssertTrue(saved.contains("mode-main = \"esc\" # stay"), saved)
        XCTAssertTrue(saved.contains("return-to-main = false"), saved)
        XCTAssertTrue(saved.contains("focus-left = \"alt-h\""), saved)
        XCTAssertFalse(saved.contains("alt-left"), saved)
        XCTAssertEqual(try messageText(), "")
        XCTAssertFalse(try button("Restore Defaults").isEnabled)

        var changed = Config()
        changed.keys["zoom"] = nil
        try load(changed)
        let beforeCancel = try String(contentsOf: coordinator.configURL)
        confirmed = 0
        controller.confirmMainShortcutReset = { confirmed += 1; return false }
        try select(.keys)
        try button("Restore Defaults").performClick(nil)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), beforeCancel)
        XCTAssertNil(coordinator.config.keys["zoom"])

        Copy.language = .japanese
        controller.refresh()
        try select(.keys)
        _ = try button("デフォルトに戻す")
    }

    func testRestoreMainShortcutsKeepsUserModeEntriesAndRefusesADefaultCollision() throws {
        var onlyEntry = Config()
        onlyEntry.modes["review"] = .init(keys: ["mode-main": .init(modifiers: [], key: "esc")], returnToMain: true)
        onlyEntry.keys["mode-review"] = .init(modifiers: ["alt"], key: "g")
        try load(onlyEntry)
        try select(.keys)
        XCTAssertFalse(try button("Restore Defaults").isEnabled)

        var changed = onlyEntry
        changed.keys["zoom"] = nil
        changed.keys["mode-service"] = .init(modifiers: ["alt"], key: "o")
        var service = Config.Mode(keys: ["reload": .init(modifiers: [], key: "esc")])
        service.returnToMain = false
        changed.modes["service"] = service
        try load(changed)
        try select(.keys)
        XCTAssertNil(row(labeled: "Enter Mode service", in: try shortcutTable()))
        XCTAssertNil(row(labeled: "Enter Mode review", in: try shortcutTable()))
        XCTAssertTrue(try button("Restore Defaults").isEnabled)
        var confirmed = 0
        controller.confirmMainShortcutReset = { confirmed += 1; return true }
        try button("Restore Defaults").performClick(nil)
        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(coordinator.config.keys["mode-review"], Config.Key(modifiers: ["alt"], key: "g"))
        XCTAssertEqual(coordinator.config.keys["mode-service"]?.configText, "alt-o")
        XCTAssertEqual(coordinator.config.keys["zoom"], Config.defaultKeys["zoom"])
        XCTAssertEqual(coordinator.config.modes["review"]?.keys["mode-main"]?.key, "esc")
        XCTAssertEqual(coordinator.config.modes["service"]?.returnToMain, false)
        XCTAssertEqual(coordinator.config.modes["service"]?.keys["reload"]?.key, "esc")
        XCTAssertFalse(try button("Restore Defaults").isEnabled)
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(saved.contains("mode-review = \"alt-g\""), saved)
        XCTAssertTrue(saved.contains("mode-service = \"alt-o\""), saved)
        XCTAssertTrue(saved.contains("[mode.review]"), saved)
        XCTAssertTrue(saved.contains("return-to-main = false"), saved)

        var blocked = Config()
        blocked.modes["review"] = onlyEntry.modes["review"]
        blocked.keys["mode-review"] = .init(modifiers: ["alt"], key: "h")
        // On load, a default that collides with a user-written mode entry is unassigned. Restoring it would collide with the entry.
        blocked.keys["focus-left"] = nil
        blocked.keys["zoom"] = nil
        try load(blocked)
        try select(.keys)
        XCTAssertNil(coordinator.config.keys["focus-left"])
        XCTAssertTrue(try button("Restore Defaults").isEnabled)
        let before = try String(contentsOf: coordinator.configURL)
        confirmed = 0
        controller.confirmMainShortcutReset = { confirmed += 1; return true }
        try button("Restore Defaults").performClick(nil)
        XCTAssertEqual(confirmed, 0)
        let message = try messageText()
        XCTAssertTrue(message.contains("Enter Mode review"), message)
        XCTAssertTrue(message.contains("Focus Left"), message)
        XCTAssertFalse(message.contains("Restored default shortcuts"), message)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), before)
        XCTAssertNil(coordinator.config.keys["focus-left"])
        XCTAssertNil(coordinator.config.keys["zoom"])
        XCTAssertEqual(coordinator.config.keys["mode-review"]?.configText, "alt-h")
        XCTAssertEqual(coordinator.config.modes["review"]?.returnToMain, true)
    }

    func testFailedShortcutSaveDoesNotClaimSuccess() throws {
        try load(Config())
        let recordedActive = coordinator.config
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try select(.keys)
        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Fill Work Area", in: table)), in: table)
        try beginSelectedRecording()
        sendKey(3, modifiers: .option)
        try assertShortcutNotApplied(active: recordedActive, file: "gap = 9\n")

        try load(Config())
        let groupedActive = coordinator.config
        try "gap = 4\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try select(.keys)
        let keys = try shortcutTable()
        try chooseDirection(in: keys, row: try XCTUnwrap(row(labeled: "Focus", in: keys)), modifier: "alt-shift")
        try assertShortcutNotApplied(active: groupedActive, file: "gap = 4\n")
        XCTAssertEqual(coordinator.config.keys["focus-left"]?.key, "h")
        XCTAssertEqual(coordinator.config.keys["swap-left"]?.key, "h")

        var config = Config()
        config.keys["zoom"] = .init(modifiers: ["alt"], key: "f")
        config.keys["float"] = nil
        try load(config)
        let restoredActive = coordinator.config
        try "gap = 1\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try select(.keys)
        let restoreTable = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: restoreTable)), in: restoreTable)
        try performShortcutAction(3)
        try assertShortcutNotApplied(active: restoredActive, file: "gap = 1\n")
        XCTAssertNil(coordinator.config.keys["float"])
        XCTAssertEqual(coordinator.config.keys["zoom"], Config.Key(modifiers: ["alt"], key: "f"))
    }

    func testQuitPromptIsSkippedUnlessSettingsMustAsk() throws {
        try load(Config())
        var asked = false
        controller.leavePrompt = { asked = true; return .cancel }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertFalse(asked)
        XCTAssertEqual(controller.leavePresentationCount, 0)
        try dialogsBesideButton().performClick(nil)
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertFalse(asked)
        try select(.layout)
        try setNumberField("Window spacing in points", "nope")
        XCTAssertFalse(controller.resolveLeave())
        XCTAssertTrue(asked)
        XCTAssertEqual(controller.leavePresentationCount, 0)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "nope")
        controller.leavePrompt = { .discard }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "0")
        let response = AppDelegate.makeQuitResponse(terminate: {})
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.message.contains("Quit requested"), response.message)
        XCTAssertFalse(response.message.contains("Quitting LazySpace."))
    }


    func testDiscardClearsAConflictMessageAndResigningKeyStopsRecording() throws {
        try load(Config())
        controller.nativeShortcutReader = { right in
            right ? .usable(keyCode: 124, modifiers: ["alt"]) : .usable(keyCode: 123, modifiers: ["ctrl"])
        }
        try select(.keys)
        let table = try shortcutTable()
        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        XCTAssertFalse(try messageText().contains("After you save"))
        XCTAssertTrue(try switchingStatus().contains("With these settings"))
        selectShortcutRow(0, in: table)
        try performShortcutAction(3)
        XCTAssertFalse(try messageText().contains("After you save"))
        XCTAssertFalse(try switchingStatus().contains("After you save"))

        try button("Show shortcuts when holding modifier keys").performClick(nil)
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: try shortcutTable())), in: try shortcutTable())
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        try beginSelectedRecording()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertEqual(recording, [true, false])
        XCTAssertFalse(try messageText().contains("Press a key"))
        XCTAssertEqual(try button("Show shortcuts when holding modifier keys").state, .off)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        XCTAssertFalse(try selectedCellIsRecording())
    }

    func testLanguagePopupStaysPutWhenTheBorderErrorAppears() throws {
        try load(Config())
        try assertLanguagePopupStable()
        Copy.language = .japanese
        controller.refresh()
        try select(.general)
        try assertLanguagePopupStable()
    }

    /// With a mouse attached, macOS shows scroll bars that take width; the error row makes the pane scroll.
    func testFormsStayPutWhenAScrollBarThatTakesWidthAppears() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try assertLanguagePopupStable(scrollers: .legacy)
    }

    func testConfigBannerGrowsAShortPaneWithoutClippingIt() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.general)
        let content = try XCTUnwrap(controller.window?.contentView)
        let before = content.bounds.height
        controller.applyConfigStatus("The configuration file could not be applied.")
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.bounds.height, before + 8)
        XCTAssertLessThanOrEqual(content.bounds.height, SettingsWindowController.contentHeightCap + 1)
        let banner = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "The configuration file could not be applied." })
        XCTAssertFalse(banner.isHiddenOrHasHiddenAncestor)
        let bannerFrame = banner.convert(banner.bounds, to: content)
        XCTAssertGreaterThanOrEqual(bannerFrame.minY, -1)
        XCTAssertLessThanOrEqual(bannerFrame.maxY, content.bounds.height + 1)
        let popup = try languagePopup()
        let clip = try XCTUnwrap(popup.enclosingScrollView?.contentView)
        let popupFrame = popup.convert(popup.bounds, to: clip)
        XCTAssertGreaterThanOrEqual(popupFrame.minY, -1)
        XCTAssertLessThanOrEqual(popupFrame.maxY, clip.bounds.height + 1)

        controller.visibleHeightForLayout = 320
        try select(.layout)
        try select(.general)
        XCTAssertLessThanOrEqual(content.bounds.height, 190)
        XCTAssertEqual(content.bounds.height, min(SettingsWindowController.contentHeightCap, 190), accuracy: 1)
        let document = try XCTUnwrap(popup.enclosingScrollView?.documentView)
        XCTAssertGreaterThanOrEqual(document.frame.height, clip.bounds.height - 1)
        popup.scrollToVisible(popup.bounds)
        assertFullyVisible(popup, in: clip)
    }

    func testSuccessfulShortcutEditsReplaceThePreviousWarning() throws {
        var config = Config()
        config.keys["space-3"] = .init(modifiers: [], key: "f3")
        try load(config)
        controller.nativeShortcutReader = { right in
            right ? .usable(keyCode: 124, modifiers: ["cmd"]) : .usable(keyCode: 123, modifiers: ["ctrl"])
        }
        try select(.keys)
        let table = try shortcutTable()
        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        XCTAssertFalse(try messageText().contains("After you save"))
        XCTAssertTrue(try switchingStatus().contains("With these settings"))
        let arrowFile = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(arrowFile.contains("ctrl-left"), arrowFile)

        try chooseDirection(in: table, row: 0, modifier: "alt")
        let cleaned = try messageText()
        XCTAssertFalse(cleaned.contains("After you save"), cleaned)
        XCTAssertFalse(try switchingStatus().contains("After you save"))

        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        XCTAssertTrue(try switchingStatus().contains("With these settings"))
        selectShortcutRow(0, in: table)
        try performShortcutAction(3)
        let restored = try messageText()
        XCTAssertFalse(restored.contains("After you save"), restored)
        XCTAssertFalse(try switchingStatus().contains("won't work"))

        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        selectShortcutRow(0, in: table)
        try performShortcutAction(2)
        XCTAssertEqual(try messageText(), "")
        XCTAssertFalse(try switchingStatus().contains("After you save"))
        XCTAssertFalse(try String(contentsOf: coordinator.configURL).contains("ctrl-left"))

        try chooseDirection(in: table, row: 0, modifier: "ctrl")
        try chooseDirection(in: table, row: 0, pattern: "arrows")
        XCTAssertTrue(try switchingStatus().contains("With these settings"))
        selectShortcutRow(try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table)), in: table)
        try performShortcutAction(2)
        XCTAssertEqual(try messageText(), "")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "")
        XCTAssertTrue(try switchingStatus().contains("With these settings"))
        XCTAssertTrue(try String(contentsOf: coordinator.configURL).contains("space-3 = \"none\""))
    }

    func testInvalidNumberDoesNotChangeWindowHeight() throws {
        preferences.set(SettingsPane.layout.rawValue, forKey: "settings.selectedPane")
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.layout)
        XCTAssertEqual(controller.window?.title, "Arrangement")
        let content = try XCTUnwrap(controller.window?.contentView)
        let before = content.bounds.height
        assertNoGlobalSaveControls()
        let field = try numberField("Window spacing in points")
        let responderBefore = controller.window?.firstResponder
        let original = try String(contentsOf: coordinator.configURL)
        field.stringValue = "999"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.height, before, accuracy: 1)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), original)
        let scroll = try XCTUnwrap(field.enclosingScrollView)
        try assertPaneIsTopAligned()
        let error = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("Enter a number from 0 to 200") })
        let errorFrame = error.convert(error.bounds, to: scroll.contentView)
        XCTAssertGreaterThanOrEqual(errorFrame.minY, -1)
        XCTAssertLessThanOrEqual(errorFrame.maxY, scroll.contentView.bounds.height + 1)
        XCTAssertFalse(controller.window?.firstResponder === error)
        if responderBefore == nil {
            XCTAssertNil(controller.window?.firstResponder)
        }

        controller.visibleHeightForLayout = 320
        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: controller.window))
        field.stringValue = "1000"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(content.bounds.height, 190)
        assertFullyVisible(error, in: scroll.contentView, label: "gap error")
        XCTAssertFalse(controller.window?.firstResponder === error)

        preferences.set(SettingsPane.general.rawValue, forKey: "settings.selectedPane")
        try load(Config())
        controller.visibleHeightForLayout = 800
        XCTAssertEqual(controller.window?.title, "General")
        let general = try XCTUnwrap(controller.window?.contentView)
        let clean = general.bounds.height
        let login = try button("Open at Login")
        login.isEnabled = true
        login.performClick(nil)
        general.layoutSubtreeIfNeeded()
        XCTAssertEqual(general.bounds.height, clean, accuracy: 1)
        let generalScroll = try XCTUnwrap(login.enclosingScrollView)
        XCTAssertLessThanOrEqual((generalScroll.documentView?.frame.height ?? 0), generalScroll.contentView.bounds.height + 1)
        XCTAssertEqual(coordinator.config.startAtLogin, true)
        XCTAssertFalse(controller.window?.isDocumentEdited == true)
        assertNoGlobalSaveControls()
    }


    func testClosingCommitsAValidNumberAndKeepsAnInvalidOne() throws {
        try load(Config())
        try select(.layout)
        let field = try numberField("Window spacing in points")
        let original = try String(contentsOf: coordinator.configURL)
        field.stringValue = "12"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), original)
        var asked = false
        controller.leavePrompt = { asked = true; return .cancel }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertFalse(asked)
        XCTAssertEqual(coordinator.config.gap, 12)
        XCTAssertNotEqual(try String(contentsOf: coordinator.configURL), original)

        field.stringValue = "15"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try select(.general)
        try select(.layout)
        XCTAssertEqual(coordinator.config.gap, 15)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "15")

        try setNumberField("Border width in points", "20")
        try select(.advanced)
        controller.leavePrompt = { .cancel }
        XCTAssertFalse(controller.resolveLeave())
        XCTAssertNil(controller.window?.attachedSheet)
        try select(.layout)
        XCTAssertEqual(try numberField("Border width in points").stringValue, "20")
    }

    func testAppsListShowsNameAndIdentifierColumns() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.apple.calculator", action: .ignore),
            .init(app: "com.example.*", action: .float),
            .init(app: "com.example.missing", action: .ignore),
        ]
        try load(config)
        controller.appName = { $0 == "com.apple.calculator" ? "Calculator" : ($0.contains("*") ? "unexpected" : nil) }
        controller.refresh()
        let table = try appsTable()
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue), ["name", "app"])
        XCTAssertEqual(try appNameLabel(row: 0).stringValue, "Calculator")
        XCTAssertEqual(try appNameLabel(row: 1).stringValue, "")
        XCTAssertEqual(try appNameLabel(row: 2).stringValue, "")
        XCTAssertEqual(try appIdentifierField(row: 0).stringValue, "com.apple.calculator")
        XCTAssertEqual(try appIdentifierField(row: 1).stringValue, "com.example.*")
        XCTAssertFalse(descendants(try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))).contains { ($0 as? NSTextField)?.isEditable == true })
        let field = try appIdentifierField(row: 2)
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "com.apple.calculator2"
        controller.appName = { $0 == "com.apple.calculator2" ? "Calculator 2" : nil }
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(try appNameLabel(row: 2).stringValue, "Calculator 2")
        XCTAssertEqual(try appNameLabel(row: 0).stringValue, "")
    }

    func testInProgressAppIdentifierSurvivesExternalReorder() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.apple.Safari", action: .ignore),
            .init(app: "com.apple.calculator", action: .ignore),
        ]
        try load(config)
        try select(.apps)
        let field = try appIdentifierField(containing: "com.apple.calculator")
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "com.example.mail"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue.contains("bundle identifier") == true })
        var external = coordinator.config
        external.rules = [
            .init(app: "com.example.new", action: .ignore),
            .init(app: "com.apple.calculator", action: .ignore),
            .init(app: "com.apple.Safari", action: .ignore),
        ]
        let externalText = external.render()
        try externalText.write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller.refresh()
        XCTAssertEqual(field.stringValue, "com.example.mail")
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), externalText)
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.new", "com.apple.calculator", "com.apple.Safari"])
        XCTAssertEqual(try appIdentifierField(containing: "com.example.mail").stringValue, "com.example.mail")
        XCTAssertEqual(try appIdentifierField(containing: "com.apple.Safari").stringValue, "com.apple.Safari")
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue == "com.example.new" })
    }

    func testDeletingAnotherAppDoesNotRetargetAnInvalidIdentifier() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.apple.Safari", action: .ignore),
            .init(app: "com.apple.calculator", action: .ignore),
        ]
        try load(config)
        try select(.apps)
        let field = try appIdentifierField(containing: "com.apple.calculator")
        field.stringValue = "not an id"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        let table = try appsTable()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        try button("−").performClick(nil)
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.apple.calculator"])
        XCTAssertEqual(try appIdentifierField(containing: "not an id").stringValue, "not an id")
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertFalse(saved.contains("not an id"), saved)
        XCTAssertFalse(saved.contains("com.apple.Safari"), saved)
        XCTAssertTrue(saved.contains("com.apple.calculator"), saved)
    }

    func testSameBundleRulesEditTheRowBeingTyped() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.example.one", action: .ignore, title: "One"),
            .init(app: "com.example.one", action: .float, title: "Two"),
        ]
        try load(config)
        try select(.apps)
        let second = try appIdentifierField(row: 1)
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: second))
        second.stringValue = "com.example.changed"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: second))
        XCTAssertEqual(try appIdentifierField(row: 0).stringValue, "com.example.one")
        XCTAssertFalse(views().contains { ($0 as? NSTextField)?.stringValue.contains("bundle identifier") == true })
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: second))
        XCTAssertEqual(coordinator.config.rules.map(\.title), ["One", "Two"])
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.one", "com.example.changed"])
        XCTAssertEqual(coordinator.config.rules.map(\.action), [.ignore, .float])
        let saved = try String(contentsOf: coordinator.configURL)
        let firstApp = try XCTUnwrap(saved.range(of: "app = \"com.example.one\""))
        let changedApp = try XCTUnwrap(saved.range(of: "app = \"com.example.changed\""))
        XCTAssertLessThan(firstApp.lowerBound, changedApp.lowerBound)
        XCTAssertTrue(saved.contains("title = \"Two\""), saved)

        try load(config)
        try select(.apps)
        let editing = try appIdentifierField(row: 1)
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: editing))
        editing.stringValue = "com.example.changed"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editing))
        let table = try appsTable()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        try button("−").performClick(nil)
        XCTAssertEqual(coordinator.config.rules.map(\.title), ["Two"])
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.one"])
        let remaining = try appIdentifierField(row: 0)
        XCTAssertEqual(remaining.stringValue, "com.example.changed")
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: remaining))
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.changed"])
        XCTAssertEqual(coordinator.config.rules.map(\.title), ["Two"])
        XCTAssertEqual(coordinator.config.rules.map(\.action), [.float])
        let afterDelete = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(afterDelete.contains("com.example.changed"), afterDelete)
        XCTAssertFalse(afterDelete.contains("title = \"One\""), afterDelete)
        XCTAssertTrue(afterDelete.contains("title = \"Two\""), afterDelete)

        var duplicates = Config()
        duplicates.rules = [
            .init(app: "com.example.same", action: .ignore),
            .init(app: "com.example.same", action: .ignore),
        ]
        try load(duplicates)
        try select(.apps)
        let duplicate = try appIdentifierField(row: 1)
        duplicate.stringValue = "com.example.other"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: duplicate))
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.same", "com.example.other"])
        XCTAssertEqual(coordinator.config.rules.map(\.action), [.ignore, .ignore])
    }

    func testUnresolvedIdentifierDoesNotTakeAnotherRowsText() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.example.one", action: .ignore, title: "One"),
            .init(app: "com.example.two", action: .float, title: "Two"),
        ]
        try load(config)
        try select(.apps)
        let first = try appIdentifierField(row: 0)
        first.stringValue = "not an id"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: first))
        let second = try appIdentifierField(row: 1)
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: second))
        second.stringValue = "com.example.changed"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: second))
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: second))
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.one", "com.example.two"])
        XCTAssertEqual(coordinator.config.rules.map(\.title), ["One", "Two"])
        XCTAssertEqual(coordinator.config.rules.map(\.action), [.ignore, .float])
        let saved = try String(contentsOf: coordinator.configURL)
        XCTAssertFalse(saved.contains("com.example.changed"), saved)
        XCTAssertFalse(saved.contains("not an id"), saved)
        XCTAssertEqual(try appIdentifierField(row: 0).stringValue, "not an id")
        XCTAssertEqual(try appIdentifierField(row: 1).stringValue, "com.example.two")
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue.contains("bundle identifier") == true })
    }

    func testAppIdentifierCommitsWhenEditingEndsAndRejectsInvalidText() throws {
        var config = Config()
        config.rules = [
            .init(app: "com.apple.Safari", action: .ignore),
            .init(app: "com.apple.calculator", action: .ignore),
        ]
        try load(config)
        try select(.apps)
        let field = try appIdentifierField(containing: "com.apple.Safari")
        field.stringValue = "com.example.mail"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.mail", "com.apple.calculator"])
        let written = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(written.contains("com.example.mail"), written)
        XCTAssertFalse(written.contains("com.apple.Safari"), written)

        let renamed = try appIdentifierField(containing: "com.example.mail")
        renamed.stringValue = "com.apple.calculator"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: renamed))
        XCTAssertEqual(coordinator.config.rules.map(\.app), ["com.example.mail", "com.apple.calculator"])
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "That app is already listed." })
        XCTAssertTrue(controller.window?.isDocumentEdited == true)

        renamed.stringValue = "not an id"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: renamed))
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), written)
        try select(.general)
        try select(.apps)
        XCTAssertEqual(try appIdentifierField(containing: "not an id").stringValue, "not an id")
        controller.leavePrompt = { .discard }
        XCTAssertTrue(controller.resolveLeave())
        XCTAssertEqual(try appIdentifierField(containing: "com.example.mail").stringValue, "com.example.mail")
    }

    func testUnassignedDirectionUsesADashAndHasNoNoneModifier() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        let join = try XCTUnwrap(row(labeled: "Join", in: table))
        let cell = try XCTUnwrap(table.view(atColumn: 1, row: join, makeIfNecessary: true))
        let menus = popups(in: cell)
        XCTAssertEqual(menus.count, 1, "an unassigned direction group shows one pop-up")
        XCTAssertEqual(menus[0].titleOfSelectedItem, "—")
        XCTAssertFalse(menus.contains { popup in
            popup.itemArray.contains { ($0.representedObject as? String) == "none" || $0.title == "None" }
        })
    }

    func testListHeightIgnoresMessagesAndSelection() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try shortcutTable()
        let list = try XCTUnwrap(table.enclosingScrollView)
        let listHeight = list.frame.height
        let contentHeight = content.bounds.height
        XCTAssertGreaterThanOrEqual(listHeight, 160)
        XCTAssertEqual(contentHeight, SettingsWindowController.shortcutContentHeight, accuracy: 1)

        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        selectShortcutRow(focus, in: table)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.frame.height, listHeight, accuracy: 1)
        XCTAssertEqual(content.bounds.height, contentHeight, accuracy: 1)

        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        selectShortcutRow(arrange, in: table)
        try beginSelectedRecording()
        sendKey(0) // A without a modifier is not allowed; shows why.
        content.layoutSubtreeIfNeeded()
        let warning = try messageText()
        XCTAssertTrue(warning.contains("modifier key"), warning)
        XCTAssertEqual(try XCTUnwrap(shortcutMessageLabel()).maximumNumberOfLines, 1)
        XCTAssertEqual(list.frame.height, listHeight, accuracy: 1)
        XCTAssertEqual(content.bounds.height, contentHeight, accuracy: 1)

        selectShortcutRow(focus, in: table)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(try messageText(), "")
        XCTAssertTrue(try button("Details…").isHidden)
        XCTAssertEqual(list.frame.height, listHeight, accuracy: 1)
        XCTAssertEqual(content.bounds.height, contentHeight, accuracy: 1)

        try select(.apps)
        let apps = try appsTable()
        let appsAdd = try addAppButton()
        assertSymbolButton(appsAdd, symbol: NSImage.addTemplateName)
        assertSymbolButton(try button("−"), symbol: NSImage.removeTemplateName)
        let appsList = try XCTUnwrap(apps.enclosingScrollView).frame.height
        let appsContent = content.bounds.height
        try addListedApp()
        content.layoutSubtreeIfNeeded()
        apps.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: apps))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(apps.enclosingScrollView).frame.height, appsList, accuracy: 1)
        XCTAssertEqual(content.bounds.height, appsContent, accuracy: 1)

    }

    func testOptionDeleteRestoresSelectedCommandAndDirectionRowsAndSaves() throws {
        for code in [UInt16(51), 117] {
            var config = Config()
            config.keys["arrange"] = nil
            for name in DirectionGroup.focus.commands { config.keys[name] = nil }
            try load(config)
            try select(.keys)
            let table = try shortcutTable()
            let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
            selectShortcutRow(arrange, in: table)
            table.keyDown(with: try keyEvent(code, modifiers: .option))
            XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
            XCTAssertNil(coordinator.config.keys["focus-left"], "Only the selected row is restored")
            XCTAssertTrue(controller.window?.firstResponder === table)
            selectShortcutRow(try XCTUnwrap(row(labeled: "Focus", in: table)), in: table)
            table.keyDown(with: try keyEvent(code, modifiers: [.option, .function]))
            for name in DirectionGroup.focus.commands {
                XCTAssertEqual(coordinator.config.keys[name], Config.defaultKeys[name])
            }
            let saved = try String(contentsOf: coordinator.configURL)
            XCTAssertEqual(try Config.load(toml: saved).keys, coordinator.config.keys)
            XCTAssertFalse(saved.isEmpty)
            selectShortcutRow(arrange, in: table)
            table.keyDown(with: try keyEvent(code))
            XCTAssertNil(coordinator.config.keys["arrange"], "Bare Delete still removes")
        }
    }

    func testOptionDeleteDoesNotRestoreUnavailableRowsOrRepeat() throws {
        var config = Config()
        config.keys["float"] = nil
        try load(config)
        try select(.keys)
        let table = try shortcutTable()
        let before = try String(contentsOf: coordinator.configURL)
        for label in ["Windows", "Arrange This Space", "Close Window", "Focus"] {
            selectShortcutRow(try XCTUnwrap(row(labeled: label, in: table)), in: table)
            XCTAssertFalse(try shortcutActionEnabled(3))
            for code in [UInt16(51), 117] {
                table.keyDown(with: try keyEvent(code, modifiers: .option))
                XCTAssertEqual(coordinator.config.keys, config.keys)
                XCTAssertEqual(try String(contentsOf: coordinator.configURL), before)
            }
        }
        selectShortcutRow(try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: table)), in: table)
        XCTAssertTrue(try shortcutActionEnabled(3))
        for code in [UInt16(51), 117] {
            table.keyDown(with: try keyEvent(code, modifiers: .option, repeatDown: true))
            XCTAssertEqual(coordinator.config.keys, config.keys)
            XCTAssertEqual(try String(contentsOf: coordinator.configURL), before)
        }
    }

    func testJapaneseRowRestoreCopyUsesDefault() throws {
        var config = Config()
        config.keys["arrange"] = nil
        config.keys["focus-left"] = nil
        try load(config)
        Copy.language = .japanese
        controller.refresh()
        try select(.keys)
        let table = try shortcutTable()
        let command = try XCTUnwrap((0..<table.numberOfRows).first { valueCell(at: $0, in: table)?.canRestore == true })
        let cell = try XCTUnwrap(valueCell(at: command, in: table))
        XCTAssertTrue(cell.accessibilityCustomActions().map(\.name).contains("デフォルトに戻す"))
        XCTAssertEqual(controller.contextMenuItem(tag: 3, clickedRow: command)?.title, "デフォルトに戻す")
        let direction = try XCTUnwrap((0..<table.numberOfRows).first {
            controller.contextMenuItem(tag: 3, clickedRow: $0)?.title == "\(DirectionGroup.focus.title)をデフォルトに戻す"
        })
        XCTAssertTrue(try XCTUnwrap(controller.contextMenuItem(tag: 3, clickedRow: direction)).isEnabled)
    }

    func testShortcutPaneHasRestoreDefaultsWithoutAnActionsPopup() throws {
        for language in [Language.english, .japanese] {
            try load(Config())
            Copy.language = language
            controller.refresh()
            try select(.keys)
            XCTAssertFalse(views().compactMap { $0 as? NSPopUpButton }.contains {
                $0.pullsDown || $0.accessibilityLabel() == "Actions" || $0.accessibilityLabel() == "操作"
            })
            let restore = try button(language == .english ? "Restore Defaults" : "デフォルトに戻す")
            XCTAssertEqual(restore.toolTip, language == .english
                ? "Restore every shortcut in this list to its default."
                : "この一覧のショートカットをすべてデフォルトに戻します。")
            let instruction = views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
            XCTAssertTrue(instruction.contains(language == .english ? "Option-Delete restores its default" : "⌥Deleteでデフォルトに戻し"))
        }
    }

    func testInsetSelectionIsRoundedAndTheLastColumnFills() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let table = try shortcutTable()
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.effectiveStyle, .inset)
        XCTAssertEqual(table.columnAutoresizingStyle, .lastColumnOnlyAutoresizingStyle)
        let label = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")))
        let key = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("key")))
        XCTAssertEqual(label.resizingMask, .userResizingMask)
        XCTAssertEqual(key.resizingMask, .autoresizingMask)
        let labelRect = table.rect(ofColumn: 0)
        let keyRect = table.rect(ofColumn: 1)
        XCTAssertEqual(labelRect.maxX, keyRect.minX, accuracy: 1)
        XCTAssertGreaterThan(keyRect.width, key.minWidth)
        XCTAssertLessThanOrEqual(table.bounds.width - keyRect.maxX, 72, "shortcut column left a \(table.bounds.width - keyRect.maxX) gap")

        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        selectShortcutRow(focus, in: table)
        let selected = try XCTUnwrap(table.rowView(atRow: focus, makeIfNecessary: true))
        let inset = try XCTUnwrap(selected as? InsetSelectionRowView)
        XCTAssertEqual(inset.selectionRect.minX, InsetSelectionRowView.horizontalInset, accuracy: 0.5)
        XCTAssertEqual(inset.bounds.width - inset.selectionRect.maxX, InsetSelectionRowView.horizontalInset, accuracy: 0.5)
        XCTAssertEqual(inset.selectionRect.height, inset.bounds.height, accuracy: 0.5)
        try assertRoundedSelection(inset)

        let windows = try XCTUnwrap(groupRow(titled: "Windows", in: table))
        let group = try XCTUnwrap(table.rowView(atRow: windows, makeIfNecessary: true))
        XCTAssertFalse(group is InsetSelectionRowView)
        XCTAssertTrue(controller.tableView(table, isGroupRow: windows))

        try select(.apps)
        try addListedApp()
        let apps = try appsTable()
        let appRow = try XCTUnwrap(apps.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertTrue(appRow is InsetSelectionRowView)
    }

    func testDirectionPopupsUseTheValueTrailingInsetAndSelectedTextColor() throws {
        // The mode note appears only when the file declares a mode; declare one to check the baseline.
        var config = Config()
        config.modes["resize"] = .init(keys: ["focus-left": .init(modifiers: [], key: "h")], returnToMain: true)
        try load(config)
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try shortcutTable()
        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        let direction = try XCTUnwrap(table.view(atColumn: 1, row: focus, makeIfNecessary: true) as? DirectionShortcutCell)
        direction.layoutSubtreeIfNeeded()
        let menus = popups(in: direction)
        XCTAssertEqual(menus.count, 2)
        let stack = try XCTUnwrap(menus[0].superview)
        XCTAssertEqual(direction.bounds.width - stack.frame.maxX, ShortcutColumnMetrics.trailingInset, accuracy: 1)
        XCTAssertEqual(menus[0].font?.pointSize ?? 0, 13, accuracy: 0.1)
        XCTAssertEqual(menus[1].font?.pointSize ?? 0, 13, accuracy: 0.1)

        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        let value = try XCTUnwrap(valueCell(at: arrange, in: table))
        value.layoutSubtreeIfNeeded()
        XCTAssertEqual(value.valueLabel.font?.pointSize ?? 0, 13, accuracy: 0.1)
        XCTAssertEqual(value.bounds.width - value.valueLabel.frame.maxX, ShortcutColumnMetrics.trailingInset, accuracy: 1)
        XCTAssertEqual(direction.bounds.width - stack.frame.maxX, value.bounds.width - value.valueLabel.frame.maxX, accuracy: 1)

        direction.backgroundStyle = .emphasized
        let emphasized = menus[0].attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(isReadableSelectedText(emphasized), "\(String(describing: emphasized))")
        direction.backgroundStyle = .normal
        let resting = menus[0].attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(resting, NSColor.labelColor)

        let join = try XCTUnwrap(row(labeled: "Join", in: table))
        let unassigned = try XCTUnwrap(table.view(atColumn: 1, row: join, makeIfNecessary: true))
        unassigned.layoutSubtreeIfNeeded()
        let single = popups(in: unassigned)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].titleOfSelectedItem, "—")
        let singleStack = try XCTUnwrap(single[0].superview)
        XCTAssertEqual(unassigned.bounds.width - singleStack.frame.maxX, ShortcutColumnMetrics.trailingInset, accuracy: 1)

        let recorder = ShortcutValueCell(frame: NSRect(x: 0, y: 0, width: 216, height: 26))
        recorder.setAssignment(display: "⌥⇧⌘F12", recording: true)
        recorder.layoutSubtreeIfNeeded()
        XCTAssertEqual(recorder.recorderBox.width, ShortcutColumnMetrics.recorderWidth, accuracy: 0.5)
        XCTAssertEqual(recorder.bounds.width - recorder.recorderBox.maxX, ShortcutColumnMetrics.trailingInset, accuracy: 0.5)
        XCTAssertLessThanOrEqual(recorder.valueLabel.frame.maxX, recorder.recorderBox.maxX + 0.5)

        let file = try button("Open File")
        let modes = try XCTUnwrap(file.superview as? NSStackView)
        XCTAssertEqual(modes.alignment, .firstBaseline)
        let note = try XCTUnwrap(modes.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertFalse(note.stringValue.isEmpty)
        content.layoutSubtreeIfNeeded()
        let noteLine = note.frame.maxY - note.firstBaselineOffsetFromTop
        let fileLine = file.frame.maxY - file.firstBaselineOffsetFromTop
        XCTAssertEqual(noteLine, fileLine, accuracy: 1)
    }

    func testFormsKeepEqualMarginsRegularLabelsAndARightMargin() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.general)
        try assertFormMargins()
        try assertLabelColumnIsRegular()
        try select(.layout)
        try assertFormMargins()
        try assertLabelColumnIsRegular()
        let form = try XCTUnwrap(views().compactMap { $0 as? SettingsForm }.first)
        XCTAssertEqual(form.grid.column(at: 1).width, form.controlColumnWidth, accuracy: 0.5)
        let document = try XCTUnwrap(try paneScroll().documentView)
        let formFrame = form.convert(form.bounds, to: document)
        let caption = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first {
            $0.stringValue.contains("Calculator")
        })
        document.layoutSubtreeIfNeeded()
        // Text fields have 2 pt side insets; compare right edges by alignment rect.
        let captionFrame = try XCTUnwrap(caption.superview).convert(caption.alignmentRect(forFrame: caption.frame), to: document)
        XCTAssertLessThanOrEqual(captionFrame.maxX, document.bounds.width - formFrame.minX + 1, "caption \(captionFrame) form \(formFrame)")
        XCTAssertEqual(formFrame.minX, document.bounds.width - formFrame.maxX, accuracy: 2)

        Copy.language = .japanese
        controller.refresh()
        try select(.layout)
        XCTAssertTrue(views().contains { ($0 as? NSButton)?.title == "フォーカス中のウインドウに表示" })
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "枠線：" })
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "フォーカス中のウインドウに枠線を表示" })
        try assertLabelColumnIsRegular()
    }

    private func exerciseBorderColorWithoutEditingIt() throws {
        try select(.keys)
        let field = keySearch()
        field.stringValue = "focus"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        try button("Show shortcuts when holding modifier keys").performClick(nil)
        try button("Show shortcuts when holding modifier keys").performClick(nil)
        try select(.layout)
        try select(.advanced)
        try select(.keys)
        field.stringValue = ""
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// `scrollers` replaces the Mac's scroll bar style, which otherwise depends on the attached pointing devices.
    private func assertLanguagePopupStable(scrollers: NSScroller.Style? = nil) throws {
        let applyScrollers = {
            guard let scrollers else { return }
            self.views().compactMap { $0 as? NSScrollView }.forEach { $0.scrollerStyle = scrollers }
            self.controller.window?.contentView?.layoutSubtreeIfNeeded()
        }
        try select(.general)
        applyScrollers()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let before = try languagePopup().convert(try languagePopup().bounds, to: controller.window?.contentView).minX
        try select(.layout)
        applyScrollers()
        try button(Copy.language == .japanese ? "フォーカス中のウインドウに表示" : "Show around the focused window").performClick(nil)
        let placementTitle = Copy.language == .japanese ? "末尾" : "At the end"
        let placement = try XCTUnwrap(views().compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains(placementTitle) })
        let placementBefore = placement.convert(placement.bounds, to: controller.window?.contentView).minX
        let scrollerShown = { self.views().contains { ($0 as? NSScrollView)?.verticalScroller?.isHidden == false && ($0 as? NSScrollView)?.scrollerStyle == .legacy } }
        if scrollers == .legacy { XCTAssertFalse(scrollerShown(), "the pane fits before the error row appears") }
        let label = Copy.language == .japanese ? "枠線の太さ（ポイント）" : "Border width in points"
        try setNumberField(label, "20")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: try numberField(label)))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(placement.convert(placement.bounds, to: controller.window?.contentView).minX, placementBefore, accuracy: 1)
        if scrollers == .legacy { XCTAssertTrue(scrollerShown(), "the error row makes the pane scroll") }
        let error = Copy.language == .japanese ? "1〜12の数値を入力してください。" : "Enter a number from 1 to 12."
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == error })
        try select(.general)
        applyScrollers()
        let after = try languagePopup().convert(try languagePopup().bounds, to: controller.window?.contentView).minX
        XCTAssertEqual(before, after, accuracy: 1, "language popup moved from \(before) to \(after)")
        try select(.layout)
        XCTAssertEqual(try numberField(label).stringValue, "20")
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == error })
    }

    func testPanesShareOneContentHeightAcrossEditsAndShortScreens() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        var tall: [SettingsPane: CGFloat] = [:]
        for pane in SettingsPane.allCases {
            try select(pane)
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.bounds.width, 720, accuracy: 1)
            tall[pane] = content.bounds.height
            try assertPaneIsTopAligned()
        }
        let keysHeight = try XCTUnwrap(tall[.keys])
        XCTAssertEqual(keysHeight, SettingsWindowController.shortcutContentHeight, accuracy: 1)
        XCTAssertEqual(tall[.apps]!, SettingsWindowController.contentHeightCap, accuracy: 1)
        XCTAssertLessThan(tall[.advanced]!, tall[.apps]! - 8, "the Advanced pane fits its contents like General and Arrangement")
        XCTAssertLessThan(tall[.general]!, tall[.apps]! - 8)
        XCTAssertLessThan(tall[.layout]!, tall[.apps]! - 8)
        XCTAssertNotEqual(tall[.general]!.rounded(), tall[.layout]!.rounded())

        let top = window.frame.maxY
        try select(.layout)
        try dialogsBesideButton().performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.height, tall[.layout]!, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)
        assertNoGlobalSaveControls()

        try select(.layout)
        let gap = try numberField("Window spacing in points")
        gap.stringValue = "nope"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: gap))
        XCTAssertTrue(views().contains { ($0 as? NSTextField)?.stringValue == "Enter a number from 0 to 200." })
        XCTAssertEqual(content.bounds.height, tall[.layout]!, accuracy: 1)
        try select(.keys)
        XCTAssertEqual(content.bounds.height, keysHeight, accuracy: 1)
        try select(.layout)
        XCTAssertEqual(try numberField("Window spacing in points").stringValue, "nope")

        controller.applyConfigStatus("The configuration file could not be applied.")
        for pane in [SettingsPane.keys, .apps, .advanced] {
            try select(pane)
            content.layoutSubtreeIfNeeded()
            // Table panes take the banner from inside; Advanced grows by the banner like General and Arrangement.
            if pane == .advanced { XCTAssertGreaterThan(content.bounds.height, tall[pane]! + 8) }
            else { XCTAssertEqual(content.bounds.height, tall[pane]!, accuracy: 1) }
            let banner = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "The configuration file could not be applied." })
            XCTAssertFalse(banner.isHiddenOrHasHiddenAncestor)
        }
        try select(.general)
        XCTAssertGreaterThan(content.bounds.height, tall[.general]!)
        XCTAssertLessThanOrEqual(content.bounds.height, SettingsWindowController.contentHeightCap + 1)

        try select(.apps)
        let apps = try appsTable()
        let appsHeight = content.bounds.height
        XCTAssertEqual(apps.numberOfRows, 0)
        XCTAssertFalse(try button("−").isEnabled)
        try addListedApp()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(apps.numberOfRows, 1)
        XCTAssertEqual(content.bounds.height, appsHeight, accuracy: 1)
        try button("−").performClick(nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(apps.numberOfRows, 0)
        XCTAssertLessThan(apps.selectedRow, 0)
        XCTAssertFalse(try button("−").isEnabled)
        XCTAssertEqual(content.bounds.height, appsHeight, accuracy: 1)

        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: window))
        XCTAssertEqual(content.bounds.height, SettingsWindowController.contentHeightCap, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        controller.visibleHeightForLayout = 320
        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: window))
        var listShort: CGFloat?
        for pane in SettingsPane.allCases {
            try select(pane)
            content.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(content.bounds.height, 190)
            if pane == .keys || pane == .apps || pane == .advanced {
                if let listShort {
                    XCTAssertEqual(content.bounds.height, listShort, accuracy: 1)
                } else {
                    listShort = content.bounds.height
                }
            }
        }
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        try select(.keys)
        let keysScroll = try paneScroll()
        XCTAssertGreaterThan(keysScroll.documentView?.frame.height ?? 0, keysScroll.contentView.bounds.height + 1)
        try select(.advanced)
        let advancedScroll = try paneScroll()
        XCTAssertGreaterThan(advancedScroll.documentView?.frame.height ?? 0, advancedScroll.contentView.bounds.height + 1)
        for title in ["Open File", "Show in Finder", "Command-Line Setup…"] {
            let control = try button(title)
            control.scrollToVisible(control.bounds)
            assertFullyVisible(control, in: advancedScroll.contentView, label: title)
        }

        try select(.layout)
        try button("Show around the focused window").performClick(nil)
        try setNumberField("Border width in points", "20")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: try numberField("Border width in points")))
        let borderError = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "Enter a number from 1 to 12." })
        let borderClip = try paneScroll().contentView
        assertFullyVisible(borderError, in: borderClip, label: "border error")
        XCTAssertFalse(window.firstResponder === borderError)
        XCTAssertLessThanOrEqual(content.bounds.height, 190)

        // Both values are invalid: editing the gap must reveal its error, not scroll back to the border.
        let editingGap = try numberField("Window spacing in points")
        editingGap.stringValue = "999"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editingGap))
        let gapError = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "Enter a number from 0 to 200." })
        assertFullyVisible(gapError, in: try paneScroll().contentView, label: "edited gap error")

        controller.visibleHeightForLayout = 800
        Copy.language = .japanese
        controller.refresh()
        try select(.advanced)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThan(content.bounds.height, SettingsWindowController.contentHeightCap - 8)
        try assertFileActionsFit(in: try paneScroll().contentView)
    }

    func testContextActionsReflectRowsAndSelectionCancelsRecording() throws {
        try load(Config())
        try select(.keys)
        let table = try shortcutTable()
        XCTAssertLessThan(table.selectedRow, 0)
        XCTAssertFalse(try shortcutActionEnabled(1))
        XCTAssertFalse(try shortcutActionEnabled(2))
        XCTAssertFalse(try shortcutActionEnabled(3))
        let focus = try XCTUnwrap(row(labeled: "Focus", in: table))
        selectShortcutRow(focus, in: table)
        XCTAssertTrue(try shortcutActionEnabled(1), "A direction row can open its pop-up")
        XCTAssertTrue(try shortcutActionItem(1).title.contains("Focus"))
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        selectShortcutRow(arrange, in: table)
        XCTAssertTrue(try shortcutActionEnabled(1))
        XCTAssertEqual(try shortcutActionItem(1).title, "Change Shortcut…")
        try beginSelectedRecording()
        XCTAssertTrue(try selectedCellIsRecording())
        XCTAssertEqual(table.selectedRow, arrange)
        selectShortcutRow(focus, in: table)
        XCTAssertFalse(try selectedCellIsRecording())
        XCTAssertEqual(try messageText(), "")
        XCTAssertEqual(table.selectedRow, focus)
        selectShortcutRow(arrange, in: table)
        XCTAssertEqual(try messageText(), "")
        XCTAssertTrue(try shortcutActionEnabled(1))
        let windows = try XCTUnwrap(row(labeled: "Windows", in: table))
        selectShortcutRow(windows, in: table)
        XCTAssertFalse(try shortcutActionEnabled(1))
        XCTAssertFalse(try shortcutActionEnabled(2))
        XCTAssertFalse(try shortcutActionEnabled(3))
    }

    func testNativeShortcutEntryUsesOneRecordingPath() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let window = try XCTUnwrap(controller.window)
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(NSPoint(x: maxX + 80, y: 80))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        let table = try shortcutTable()
        XCTAssertEqual(table.style, .inset)
        XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
        let instruction = views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(instruction.contains("double-click it or press Return"), instruction)
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }

        try clickShortcutRow(arrange, in: table, clickCount: 1)
        XCTAssertEqual(table.selectedRow, arrange)
        XCTAssertEqual(recording, [])
        XCTAssertNotEqual(valueCell(at: arrange, in: table)?.recording, true)

        try clickShortcutRow(arrange, in: table, clickCount: 2)
        XCTAssertEqual(recording, [true])
        XCTAssertEqual(valueCell(at: arrange, in: table)?.recording, true)
        XCTAssertFalse(valueCell(at: arrange, in: table)?.valueLabel.stringValue.isEmpty == true)
        XCTAssertTrue(window.firstResponder === table)
        let recordingCells = (0..<table.numberOfRows).compactMap { valueCell(at: $0, in: table) }.filter(\.recording)
        XCTAssertEqual(recordingCells.count, 1)
        try clickShortcutRow(arrange, in: table, clickCount: 2)
        XCTAssertEqual(recording, [true], "a second double-click does not toggle capture")

        sendKey(53)
        XCTAssertEqual(recording, [true, false])
        XCTAssertEqual(try messageText(), "")
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertEqual(table.selectedRow, arrange)
        table.keyDown(with: try keyEvent(125, characters: "\u{f701}"))
        XCTAssertGreaterThan(table.selectedRow, arrange)

        selectShortcutRow(arrange, in: table)
        table.keyDown(with: try keyEvent(36))
        XCTAssertEqual(recording, [true, false, true])
        XCTAssertTrue(window.firstResponder === table)
        sendKey(51)
        XCTAssertNil(coordinator.config.keys["arrange"])
        XCTAssertEqual(try messageText(), "")
        XCTAssertTrue(window.firstResponder === table)
        table.keyDown(with: try keyEvent(125, characters: "\u{f701}"))
        XCTAssertNotEqual(table.selectedRow, arrange)

        let integrate = try XCTUnwrap(row(labeled: "Add One Waiting Window", in: table))
        selectShortcutRow(arrange, in: table)
        let removeIntegrate = try XCTUnwrap(controller.contextMenuItem(tag: 2, clickedRow: integrate))
        XCTAssertTrue(removeIntegrate.isEnabled)
        _ = controller.perform(try XCTUnwrap(removeIntegrate.action), with: removeIntegrate)
        XCTAssertNil(coordinator.config.keys["integrate"])
        XCTAssertNil(coordinator.config.keys["arrange"])
        XCTAssertEqual(try messageText(), "")

        var filtered = Config()
        filtered.keys["close"] = .init(modifiers: [], key: "f1")
        try load(filtered)
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let filteredTable = try shortcutTable()
        searchShortcuts("F1")
        let close = try XCTUnwrap(row(labeled: "Close Window", in: filteredTable))
        selectShortcutRow(close, in: filteredTable)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        XCTAssertNil(row(labeled: "Close Window", in: filteredTable))
        let selectable = (0..<filteredTable.numberOfRows).contains { controller.tableView(filteredTable, shouldSelectRow: $0) }
        if selectable {
            XCTAssertGreaterThanOrEqual(filteredTable.selectedRow, 0)
        }
        XCTAssertTrue(controller.window?.firstResponder === filteredTable)
        XCTAssertEqual(coordinator.config.keys["close"], Config.Key(modifiers: ["alt"], key: "g"))
    }

    func testShortcutMenusStayDisabledAfterUpdateAndContextClicksKeepTheirRow() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let window = try XCTUnwrap(controller.window)
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(NSPoint(x: maxX + 80, y: 80))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        let table = try shortcutTable()
        table.layoutSubtreeIfNeeded()
        let arrange = try XCTUnwrap(row(labeled: "Arrange This Space", in: table))
        let arrangeKey = coordinator.config.keys["arrange"]
        XCTAssertNotNil(arrangeKey)
        let integrateKey = coordinator.config.keys["integrate"]
        XCTAssertNotNil(integrateKey)

        let close = try XCTUnwrap(row(labeled: "Close Window", in: table))
        selectShortcutRow(close, in: table)
        let context = try XCTUnwrap(table.menu)
        try openContextMenu(on: table, at: try rowPoint(close, in: table))
        controller.menuNeedsUpdate(context)
        context.update()
        XCTAssertFalse(context.autoenablesItems)
        XCTAssertTrue(try XCTUnwrap(context.items.first { $0.tag == 1 }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(context.items.first { $0.tag == 2 }).isEnabled, "Remove stays off when the row has no shortcut")
        XCTAssertFalse(try XCTUnwrap(context.items.first { $0.tag == 3 }).isEnabled, "Restore stays off when the row has no default")

        selectShortcutRow(arrange, in: table)
        try openContextMenu(on: table, at: try rowPoint(arrange, in: table))
        controller.menuNeedsUpdate(context)
        context.update()
        XCTAssertTrue(try XCTUnwrap(context.items.first { $0.tag == 2 }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(context.items.first { $0.tag == 3 }).isEnabled, "Restore stays off when the shortcut is already the default")

        let integrate = try XCTUnwrap(row(labeled: "Add One Waiting Window", in: table))
        try openContextMenu(on: table, at: try rowPoint(integrate, in: table))
        XCTAssertEqual(table.clickedRow, integrate)
        // update() validates items already in the menu. The clicked row is applied in menuNeedsUpdate.
        controller.menuNeedsUpdate(context)
        context.update()
        XCTAssertFalse(context.autoenablesItems)
        let removeIntegrate = try XCTUnwrap(context.items.first { $0.tag == 2 })
        XCTAssertTrue(removeIntegrate.isEnabled)
        XCTAssertNotNil(removeIntegrate.representedObject)

        let below = try rowPoint(table.numberOfRows - 1, in: table)
        let empty = NSPoint(x: below.x, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 8)
        XCTAssertLessThan(table.row(at: empty), 0)
        try openContextMenu(on: table, at: empty)
        XCTAssertLessThan(table.clickedRow, 0)
        controller.menuNeedsUpdate(context)
        context.update()
        XCTAssertFalse(context.autoenablesItems)
        let actionable = context.items.filter { $0.tag > 0 }
        XCTAssertEqual(actionable.count, 3)
        for item in actionable {
            XCTAssertFalse(item.isEnabled, item.title)
            XCTAssertNil(item.representedObject, item.title)
        }
        selectShortcutRow(arrange, in: table)
        let tokenless = try XCTUnwrap(actionable.first { $0.tag == 2 })
        _ = controller.perform(try XCTUnwrap(tokenless.action), with: tokenless)
        XCTAssertEqual(coordinator.config.keys["arrange"], arrangeKey)
        XCTAssertEqual(coordinator.config.keys["integrate"], integrateKey)

        selectShortcutRow(arrange, in: table)
        _ = controller.perform(try XCTUnwrap(removeIntegrate.action), with: removeIntegrate)
        XCTAssertNil(coordinator.config.keys["integrate"])
        XCTAssertEqual(coordinator.config.keys["arrange"], arrangeKey)
    }

    func testShortcutFrameNearTheBottomOfAShortScreenStaysVisible() throws {
        try load(Config())
        let window = try XCTUnwrap(controller.window)
        let content = NSRect(x: 0, y: 0, width: 720, height: SettingsWindowController.shortcutContentHeight)
        let size = window.frameRect(forContentRect: content).size
        XCTAssertGreaterThanOrEqual(size.height, SettingsWindowController.shortcutContentHeight)
        let visible = NSRect(x: 80, y: 40, width: 1400, height: 320)
        XCTAssertGreaterThan(size.height, visible.height)
        let top = visible.minY + 36
        let proposed = NSRect(x: visible.minX + 40, y: top - size.height, width: size.width, height: size.height)
        XCTAssertEqual(proposed.maxY, top, accuracy: 0.5)
        XCTAssertLessThan(proposed.minY, visible.minY)
        let clamped = SettingsWindowController.clampedFrame(proposed, within: visible)
        XCTAssertEqual(clamped.height, visible.height, accuracy: 0.5)
        XCTAssertEqual(clamped.minY, visible.minY, accuracy: 0.5)
        XCTAssertEqual(clamped.maxY, visible.maxY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(clamped.minX, visible.minX - 0.5)
        XCTAssertLessThanOrEqual(clamped.maxX, visible.maxX + 0.5)
        XCTAssertGreaterThan(clamped.maxY, top)

        let placed = NSRect(x: visible.minX + 24, y: visible.maxY - 210, width: 720, height: 180)
        let kept = SettingsWindowController.clampedFrame(placed, within: visible)
        XCTAssertEqual(kept.minX, placed.minX, accuracy: 0.5)
        XCTAssertEqual(kept.minY, placed.minY, accuracy: 0.5)
        XCTAssertEqual(kept.width, placed.width, accuracy: 0.5)
        XCTAssertEqual(kept.height, placed.height, accuracy: 0.5)
    }

    func testStickyDiagnosticLineShowsDetailsWhenEachLineFits() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let window = try XCTUnwrap(controller.window)
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(NSPoint(x: maxX + 80, y: 80))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let table = try shortcutTable()
        selectShortcutRow(try XCTUnwrap(row(labeled: "Arrange This Space", in: table)), in: table)
        try beginSelectedRecording()
        sendKey(5, modifiers: .option)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(try messageText(), "Not applied.")
        XCTAssertTrue(try button("Details…").isHidden)
        let label = try XCTUnwrap(shortcutMessageLabel())
        let row = try XCTUnwrap(label.superview as? NSStackView)
        row.layoutSubtreeIfNeeded()
        let gap = try XCTUnwrap(row.arrangedSubviews.first { $0 !== label && !($0 is NSControl) && !$0.isHidden })
        XCTAssertGreaterThan(gap.bounds.width, row.spacing)
        // The spacer is an arranged view, so the label's usable width is the label plus that spacer.
        let slot = label.bounds.width + gap.bounds.width
        XCTAssertEqual(label.maximumNumberOfLines, 1)

        try beginSelectedRecording()
        sendKey(52)
        window.contentView?.layoutSubtreeIfNeeded()
        let message = try messageText()
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 2, message)
        let font = try XCTUnwrap(label.font)
        for line in lines {
            let width = ceil((line as NSString).size(withAttributes: [.font: font]).width)
            XCTAssertLessThanOrEqual(width, slot + 0.5, "\(line) is \(width) pt in a \(slot) pt slot")
        }
        XCTAssertFalse(try button("Details…").isHidden, message)
        XCTAssertEqual(label.toolTip, message)
        XCTAssertEqual(label.accessibilityValue(), message)
    }

    /// Right-click dispatch without menu tracking. `menu(for:)` is the table's context-menu event path and records the clicked row.
    private func openContextMenu(on table: NSTableView, at local: NSPoint) throws {
        let event = try mouseEvent(.rightMouseDown, in: table, at: local)
        _ = table.menu(for: event)
    }

    private func rowPoint(_ row: Int, in table: NSTableView) throws -> NSPoint {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: row)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func mouseEvent(_ type: NSEvent.EventType, in view: NSView, at local: NSPoint) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(local, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func clickShortcutRow(_ row: Int, in table: NSTableView, clickCount: Int) throws {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let window = try XCTUnwrap(table.window)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("key"))
        let cell = column >= 0 ? table.view(atColumn: column, row: row, makeIfNecessary: true) as? ShortcutValueCell : nil
        cell?.layoutSubtreeIfNeeded()
        let localInTable: NSPoint
        if let cell {
            let inside = cell.recording ? NSPoint(x: cell.recorderBox.midX, y: cell.recorderBox.midY) : NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)
            localInTable = cell.convert(inside, to: table)
        } else {
            let rect = table.rect(ofRow: row)
            localInTable = NSPoint(x: rect.maxX - 24, y: rect.midY)
        }
        let point = table.convert(localInTable, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: clickCount, clickCount: clickCount, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: clickCount, clickCount: clickCount, pressure: 1))
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func keyEvent(_ code: UInt16, characters: String = "\r", modifiers: NSEvent.ModifierFlags = [], repeatDown: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatDown, keyCode: code))
    }

    private func languagePopup() throws -> NSPopUpButton {
        try XCTUnwrap(views().compactMap { $0 as? NSPopUpButton }.first { button in
            button.itemArray.contains { ($0.representedObject as? String) == "en" || ($0.representedObject as? String) == "ja" }
        })
    }

    private func directionTitle(in table: NSTableView, row: Int, tag: Int) -> String? {
        guard let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) else { return nil }
        return popups(in: cell).first { $0.tag == tag }?.selectedItem?.title
    }

    private func sendKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeat repeatDown: Bool = false, release: Bool = true, window: NSWindow? = nil) {
        let target = window ?? controller.window
        let number = target?.windowNumber ?? 0
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatDown, keyCode: code)
        if let down { NSApp.sendEvent(down) }
        guard release, !repeatDown else { return }
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)
        if let up { NSApp.sendEvent(up) }
    }

    private func searchShortcuts(_ text: String) {
        let field = keySearch()
        field.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func selectShortcutRow(_ row: Int, in table: NSTableView) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    }

    private func pumpMain() {
        let pumped = expectation(description: "main queue")
        DispatchQueue.main.async { pumped.fulfill() }
        wait(for: [pumped], timeout: 2)
    }

    private func keySearch() -> NSSearchField {
        views().compactMap { $0 as? NSSearchField }.first!
    }

    private func shortcutTable() throws -> NSTableView {
        if controller.window?.title == "Shortcuts" || controller.window?.title == "ショートカット" {
            return try XCTUnwrap(views().compactMap { $0 as? NSTableView }.first)
        }
        try select(.keys)
        return try XCTUnwrap(views().compactMap { $0 as? NSTableView }.first)
    }

    /// The heading row. Looks only at group-row titles, even if an action name contains the same word.
    private func groupRow(titled title: String, in table: NSTableView) -> Int? {
        for row in 0..<table.numberOfRows {
            guard controller.tableView(table, isGroupRow: row) else { continue }
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else { continue }
            let lines = descendants(rowView).compactMap { $0 as? NSTextField }.map(\.stringValue)
            if lines.contains(title) { return row }
        }
        return nil
    }

    private func row(labeled text: String, in table: NSTableView) -> Int? {
        for row in 0..<table.numberOfRows {
            if rowLabel(in: table, row: row).contains(text) { return row }
        }
        return nil
    }

    private func assertRow(_ text: String, in table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
        let labels = (0..<table.numberOfRows).map { rowLabel(in: table, row: $0) }
        XCTAssertTrue(labels.contains { $0.contains(text) }, "rows=\(table.numberOfRows) \(labels.prefix(12))", file: file, line: line)
    }

    private func assertRecordingMessageCollapsed(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try messageText(), "", file: file, line: line)
        guard let label = shortcutMessageLabel() else { return }
        XCTAssertFalse(label.isHidden, file: file, line: line)
        XCTAssertEqual(label.stringValue, "", file: file, line: line)
    }

    private func shortcutMessageLabel() -> NSTextField? {
        views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Shortcut Message" || $0.accessibilityLabel() == "ショートカットの案内" }
    }

    private func messageText() throws -> String {
        shortcutMessageLabel()?.stringValue ?? ""
    }

    private func switchingStatusLabel() -> NSTextField? {
        views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Space Switching Status" || $0.accessibilityLabel() == "操作スペース切り替えの状態" }
    }

    /// The warning text if shown; nil when its row is hidden (out of the arrangement).
    private func shownSwitchingStatus() -> String? {
        guard let label = switchingStatusLabel(), !label.isHiddenOrHasHiddenAncestor else { return nil }
        return label.stringValue
    }

    private func keyboardSettingsShown() -> Bool {
        views().contains { ($0 as? NSButton)?.title == "Open Keyboard Settings…" && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func detailedStatusExists() -> Bool {
        views().contains { ($0 as? NSButton)?.title == "Detailed Status…" || $0.accessibilityLabel() == "Space Switching Details" }
    }

    private func verticalGap(from upper: NSView, to lower: NSView) throws -> CGFloat {
        let content = try XCTUnwrap(controller.window?.contentView)
        let top = upper.convert(upper.bounds, to: content)
        let bottom = lower.convert(lower.bounds, to: content)
        return top.minY - bottom.maxY
    }

    private func assertNaturalHeight(_ label: NSTextField, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(label.bounds.width, 80, file: file, line: line)
        let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)).height ?? 0
        XCTAssertGreaterThan(needed, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.frame.height, needed - 1, "height \(label.frame.height) needed \(needed)", file: file, line: line)
        XCTAssertLessThan(label.frame.height, needed + 4, "height \(label.frame.height) needed \(needed)", file: file, line: line)
    }

    /// The shown warning text, or empty.
    private func switchingStatus() throws -> String {
        shownSwitchingStatus() ?? ""
    }

    private func rowLabel(in table: NSTableView, row: Int) -> String {
        if let column = table.view(atColumn: 0, row: row, makeIfNecessary: true) {
            let text = descendants(column).compactMap { $0 as? NSTextField }.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else { return "" }
        return descendants(rowView).compactMap { $0 as? NSTextField }.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func shortcutText(in table: NSTableView, row: Int) -> String {
        guard let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) else { return "" }
        return descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue ?? ""
    }

    private func statusText() throws -> String {
        views().compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
    }

    private func directionSelection(in table: NSTableView, row: Int, tag: Int) -> String? {
        guard let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) else { return nil }
        return popups(in: cell).first { $0.tag == tag }?.selectedItem?.representedObject as? String
    }

    private func chooseDirection(in table: NSTableView, row: Int, modifier: String? = nil, pattern: String? = nil) throws {
        let cell = try XCTUnwrap(table.view(atColumn: 1, row: row, makeIfNecessary: true))
        if let modifier {
            let popup = try XCTUnwrap(popups(in: cell).first { $0.tag == 1 })
            popup.selectItem(at: popup.indexOfItem(withRepresentedObject: modifier))
            _ = controller.perform(try XCTUnwrap(popup.action), with: popup)
        }
        if let pattern {
            let refreshed = try XCTUnwrap(table.view(atColumn: 1, row: row, makeIfNecessary: true))
            let popup = try XCTUnwrap(popups(in: refreshed).first { $0.tag == 2 })
            popup.selectItem(at: popup.indexOfItem(withRepresentedObject: pattern))
            _ = controller.perform(try XCTUnwrap(popup.action), with: popup)
        }
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        let own = (view as? NSPopUpButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(popups)
    }

    private func recoveryLabel() throws -> NSTextField {
        try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings Recovery" || $0.accessibilityLabel() == "設定の復旧" })
    }

    private func assertRecoveryAttached(_ recovery: NSTextField, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(controller.window?.contentView, file: file, line: line)
        XCTAssertFalse(recovery.isHidden, file: file, line: line)
        XCTAssertNotNil(recovery.window, file: file, line: line)
        XCTAssertGreaterThan(recovery.bounds.height, 8, file: file, line: line)
        var ancestor: NSView? = recovery
        var attached = false
        while let view = ancestor {
            if view === content { attached = true; break }
            ancestor = view.superview
        }
        XCTAssertTrue(attached, "recovery label is not in the window", file: file, line: line)
        let frame = recovery.convert(recovery.bounds, to: content)
        XCTAssertTrue(content.bounds.intersects(frame), "recovery \(frame) outside \(content.bounds)", file: file, line: line)
    }

    private func assertSheetButtonsTrailing(_ sheet: NSWindow, primary: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(sheet.contentView, file: file, line: line)
        content.layoutSubtreeIfNeeded()
        let cancel = try sheetButton("Cancel", in: sheet)
        let done = try sheetButton(primary, in: sheet)
        let cancelFrame = cancel.convert(cancel.bounds, to: content)
        let doneFrame = done.convert(done.bounds, to: content)
        XCTAssertLessThanOrEqual(cancelFrame.maxX, doneFrame.minX + 0.5, file: file, line: line)
        XCTAssertEqual(doneFrame.maxX, content.bounds.width - 20, accuracy: 2, file: file, line: line)
        XCTAssertEqual(doneFrame.minY, 16, accuracy: 2, "primary button is not on the bottom edge", file: file, line: line)
    }

    private func assertNoGlobalSaveControls(file: StaticString = #filePath, line: UInt = #line) {
        let titles = Set(views().compactMap { $0 as? NSButton }.map(\.title))
        for title in ["Save and Apply", "Discard Changes", "保存して適用", "変更を破棄", "Discard and Load", "破棄して読み込む"] {
            XCTAssertFalse(titles.contains(title), title, file: file, line: line)
        }
    }

    private func execTable() throws -> NSTableView {
        if controller.window?.toolbar?.selectedItemIdentifier?.rawValue != SettingsPane.advanced.rawValue {
            try select(.advanced)
        }
        return try XCTUnwrap(views().compactMap { $0 as? NSTableView }.first)
    }

    private func sheetButton(_ title: String, in sheet: NSWindow) throws -> NSButton {
        try XCTUnwrap(sheet.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.title == title } })
    }

    private func sheetCommand(in sheet: NSWindow) throws -> NSTextField {
        try XCTUnwrap(sheet.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextField }.first { $0.isEditable } })
    }

    private func sheetText(_ sheet: NSWindow) -> String {
        sheet.contentView.flatMap { descendants($0).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n") } ?? ""
    }

    private func assertShortcutNotApplied(active: Config, file: String) throws {
        let message = try messageText()
        XCTAssertEqual(message, "Not applied.", message)
        XCTAssertFalse(message.contains("Assigned"), message)
        XCTAssertFalse(message.contains("Removed"), message)
        XCTAssertEqual(coordinator.config, active)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), file)
        let recovery = try recoveryLabel()
        XCTAssertTrue(recovery.stringValue.contains("Nothing was saved"), recovery.stringValue)
        try assertRecoveryAttached(recovery)
    }

    private func appIdentifierField(row: Int) throws -> NSTextField {
        let table = try appsTable()
        let cell = try XCTUnwrap(table.view(atColumn: 1, row: row, makeIfNecessary: true))
        return try XCTUnwrap(descendants(cell).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    private func appNameLabel(row: Int) throws -> NSTextField {
        let table = try appsTable()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        return try XCTUnwrap(cell as? NSTextField ?? descendants(cell).compactMap { $0 as? NSTextField }.first)
    }

    private func appIdentifierField(containing text: String) throws -> NSTextField {
        let table = try appsTable()
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) else { continue }
            if let field = descendants(cell).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.stringValue.contains(text) }) {
                return field
            }
        }
        XCTFail("missing app field \(text)")
        return NSTextField()
    }

    private func appsTable() throws -> NSTableView {
        if controller.window?.toolbar?.selectedItemIdentifier?.rawValue != SettingsPane.apps.rawValue {
            try select(.apps)
        }
        return try XCTUnwrap(views().compactMap { $0 as? NSTableView }.first)
    }

    private func paneScroll(file: StaticString = #filePath, line: UInt = #line) throws -> NSScrollView {
        try XCTUnwrap(views().compactMap { $0 as? NSScrollView }.first { $0.enclosingScrollView == nil && !$0.isHiddenOrHasHiddenAncestor }, file: file, line: line)
    }

    private func assertFullyVisible(_ view: NSView, in clip: NSView, label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let frame = view.convert(view.bounds, to: clip)
        let visible = clip.bounds.insetBy(dx: 0, dy: -1)
        XCTAssertTrue(visible.contains(frame), "\(label) \(frame) outside \(clip.bounds)", file: file, line: line)
    }

    private func assertPaneIsTopAligned(file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = try paneScroll(file: file, line: line)
        scroll.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(scroll.documentView?.subviews.first, file: file, line: line)
        let frame = content.convert(content.bounds, to: scroll.contentView)
        XCTAssertGreaterThan(frame.minY, -1, file: file, line: line)
        XCTAssertLessThan(frame.minY, 32, "content minY \(frame.minY)", file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1, file: file, line: line)
    }

    /// Leading rows that fit entirely in the table clip. An empty table uses its row height. The column header is not counted.
    private func fullyVisibleRowCount(_ table: NSTableView) -> Int {
        guard let viewport = table.enclosingScrollView else { return 0 }
        viewport.layoutSubtreeIfNeeded()
        let clipHeight = viewport.contentView.bounds.height
        guard clipHeight > 1 else { return 0 }
        if table.numberOfRows == 0 {
            guard table.rowHeight > 1 else { return 0 }
            return Int(floor((clipHeight + 0.5) / table.rowHeight))
        }
        var used: CGFloat = 0
        var full = 0
        for row in 0..<table.numberOfRows {
            let height = table.rect(ofRow: row).height
            guard height > 1 else { continue }
            if used + height <= clipHeight + 0.5 {
                used += height
                full += 1
            } else {
                break
            }
        }
        return full
    }

    private func assertFileActionsFit(in clip: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let titles = Copy.language == .japanese
            ? ["ファイルを開く", "Finderで表示", "コマンドラインの設定…"]
            : ["Open File", "Show in Finder", "Command-Line Setup…"]
        var frames: [NSRect] = []
        for title in titles {
            let control = try button(title)
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, title, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width + 0.5, control.intrinsicContentSize.width, title, file: file, line: line)
            let frame = control.convert(control.bounds, to: clip)
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(title) \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, clip.bounds.width + 1, "\(title) \(frame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -1, "\(title) \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, clip.bounds.height + 1, "\(title) \(frame)", file: file, line: line)
            frames.append(frame)
        }
        let ordered = frames.sorted { $0.minX < $1.minX }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX + 0.5, file: file, line: line)
        }
        if let minX = ordered.map(\.minX).min(), let maxX = ordered.map(\.maxX).max() {
            XCTAssertLessThanOrEqual(maxX - minX, 664, "file actions span \(maxX - minX)", file: file, line: line)
        }
    }

    private func assertSymbolButton(_ button: NSButton, symbol: NSImage.Name, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(button.title, "", file: file, line: line)
        XCTAssertEqual(button.imagePosition, .imageOnly, file: file, line: line)
        XCTAssertEqual(button.bezelStyle, .rounded, file: file, line: line)
        XCTAssertEqual(button.controlSize, .regular, file: file, line: line)
        XCTAssertEqual(button.frame.width, 28, accuracy: 1, file: file, line: line)
        XCTAssertEqual(button.image?.name(), Optional(symbol), file: file, line: line)
    }

    private func assertFormMargins(file: StaticString = #filePath, line: UInt = #line) throws {
        let scroll = try paneScroll(file: file, line: line)
        scroll.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let content = try XCTUnwrap(document.subviews.first, file: file, line: line)
        XCTAssertEqual(content.frame.minY, 24, accuracy: 1, file: file, line: line)
        XCTAssertEqual(document.frame.height - content.frame.maxY, 24, accuracy: 1, file: file, line: line)
        XCTAssertEqual(document.frame.height, scroll.contentView.bounds.height, accuracy: 2, file: file, line: line)
    }

    private func assertLabelColumnIsRegular(file: StaticString = #filePath, line: UInt = #line) throws {
        let form = try XCTUnwrap(views().compactMap { $0 as? SettingsForm }.first, file: file, line: line)
        var labels = 0
        for row in 0..<form.grid.numberOfRows {
            guard let label = form.grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField else { continue }
            labels += 1
            XCTAssertEqual(label.font?.pointSize ?? 0, 13, accuracy: 0.1, label.stringValue, file: file, line: line)
            let traits = label.font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 1
            XCTAssertLessThan(weight, 0.15, label.stringValue, file: file, line: line)
        }
        XCTAssertGreaterThan(labels, 0, file: file, line: line)
    }

    private func isReadableSelectedText(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        if color == .alternateSelectedControlTextColor { return true }
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.9 && rgb.greenComponent > 0.9 && rgb.blueComponent > 0.9
    }

    private func assertRoundedSelection(_ row: InsetSelectionRowView, file: StaticString = #filePath, line: UInt = #line) throws {
        let width = 220
        let height = 26
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        row.isEmphasized = true
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), file: file, line: line)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        row.bounds.fill()
        row.drawSelection(in: row.bounds)
        NSGraphicsContext.restoreGraphicsState()
        // colorAt uses a lower-left origin. The vertical middle is the same either way.
        let outside = rep.colorAt(x: 0, y: height / 2)?.alphaComponent ?? 0
        let inside = rep.colorAt(x: Int(InsetSelectionRowView.horizontalInset + InsetSelectionRowView.cornerRadius) + 4, y: height / 2)?.alphaComponent ?? 0
        let corner = rep.colorAt(x: Int(InsetSelectionRowView.horizontalInset), y: 0)?.alphaComponent ?? 0
        XCTAssertLessThan(outside, 0.2, "selection reached the row edge", file: file, line: line)
        XCTAssertGreaterThan(inside, 0.4, "selection was not drawn inside the inset", file: file, line: line)
        XCTAssertLessThan(corner, 0.2, "selection corner stayed square", file: file, line: line)
    }
}

private extension Config {
    mutating func gapsOuterForTest() {
        outerLeft = 4
    }
}
