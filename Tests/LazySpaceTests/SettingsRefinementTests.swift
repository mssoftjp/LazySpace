import AppKit
import Copy
import Settings
import XCTest
@testable import LazySpace

@MainActor
final class SettingsRefinementTests: XCTestCase {
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
        suite = "LazySpace.SettingsRefinement.\(UUID().uuidString)"
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

    func testShortcutRowsShowOnePictogramAndTheExistingLabels() throws {
        var config = Config()
        config.keys["space-3"] = .init(modifiers: [], key: "f3")
        try load(config)
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let table = try shortcutTable()
        XCTAssertEqual(table.columnAutoresizingStyle, .lastColumnOnlyAutoresizingStyle)
        let labelColumn = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")))
        let keyColumn = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("key")))
        XCTAssertEqual(labelColumn.minWidth, 240, accuracy: 1)
        XCTAssertEqual(labelColumn.resizingMask, .userResizingMask)
        XCTAssertEqual(keyColumn.minWidth, 120, accuracy: 1)
        XCTAssertEqual(keyColumn.resizingMask, .autoresizingMask)
        table.layoutSubtreeIfNeeded()
        let labelRect = table.rect(ofColumn: 0)
        let keyRect = table.rect(ofColumn: 1)
        XCTAssertEqual(labelRect.maxX, keyRect.minX, accuracy: 1)
        XCTAssertGreaterThan(keyRect.width, keyColumn.minWidth)
        XCTAssertLessThanOrEqual(table.bounds.width - keyRect.maxX, 72)
        XCTAssertEqual(keySearch().frame.width, 240, accuracy: 1)
        let content = try XCTUnwrap(controller.window?.contentView)
        let searchFrame = keySearch().convert(keySearch().bounds, to: content)
        let guide = try button("Show shortcuts when holding modifier keys")
        let guideFrame = guide.convert(guide.bounds, to: content)
        XCTAssertLessThan(abs(searchFrame.midY - guideFrame.midY), 8)
        XCTAssertLessThan(searchFrame.maxX, guideFrame.minX)

        var sawDirection = false
        var sawCommand = false
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            if cell is ShortcutActionCell {
                let pictograms = descendants(cell).compactMap { $0 as? ActionPictogramView }
                let fields = descendants(cell).compactMap { $0 as? NSTextField }
                XCTAssertEqual(pictograms.count, 1, "row \(row)")
                XCTAssertEqual(fields.count, 1, "row \(row) \(fields.map(\.stringValue))")
                XCTAssertEqual(fields[0].font?.pointSize ?? 0, 13, accuracy: 0.1)
                let label = fields[0].stringValue
                if label == "Focus" {
                    sawDirection = true
                    XCTAssertEqual(pictograms[0].pictogram, .focus)
                    XCTAssertEqual(fields[0].accessibilityHelp(), ActionPictogram.focus.help)
                }
                if label == "Arrange This Space" {
                    sawCommand = true
                    XCTAssertEqual(pictograms[0].pictogram, .arrange)
                    XCTAssertEqual(SettingsCopy.commandLabel("arrange"), label)
                }
            } else {
                XCTAssertTrue(descendants(cell).compactMap { $0 as? ActionPictogramView }.isEmpty, "heading row \(row)")
            }
        }
        XCTAssertTrue(sawDirection)
        XCTAssertTrue(sawCommand)
        XCTAssertEqual(rowLabel(in: table, row: try XCTUnwrap(row(labeled: "Focus", in: table))), "Focus")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Switch to Desktop 3", in: table))), "F3")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Toggle Tiling for Window", in: table))), "⌥F")
        XCTAssertEqual(shortcutText(in: table, row: try XCTUnwrap(row(labeled: "Close Window", in: table))), "")

        let focusCell = try XCTUnwrap(table.view(atColumn: 0, row: try XCTUnwrap(row(labeled: "Focus", in: table)), makeIfNecessary: true) as? ShortcutActionCell)
        focusCell.backgroundStyle = .emphasized
        XCTAssertTrue(focusCell.pictogramView.emphasized)
        focusCell.backgroundStyle = .normal
        XCTAssertFalse(focusCell.pictogramView.emphasized)
    }

    func testValueCellRecordsClearsAndResolvesTheCommandAfterFiltering() throws {
        try load(Config())
        try select(.keys)
        let arrange = SettingsCopy.commandLabel("arrange")
        var recording: [Bool] = []
        controller.onRecording = { recording.append($0) }
        var cell = try self.valueCell(command: "arrange")
        XCTAssertEqual(cell.accessibilityLabel(), arrange)
        XCTAssertTrue(cell.accessibilityHelp()?.contains("Return") == true)
        let names = cell.accessibilityCustomActions().map(\.name)
        XCTAssertTrue(names.contains("Change Shortcut"))
        XCTAssertTrue(names.contains("Remove Shortcut"))
        cell.onChange?()
        XCTAssertEqual(recording, [true])
        XCTAssertEqual(try messageText(), "")
        cell = try self.valueCell(command: "arrange")
        cell.onChange?()
        XCTAssertEqual(recording, [true])
        cell.onCancel?()
        XCTAssertEqual(recording, [true, false])
        XCTAssertEqual(try messageText(), "")

        let before = try String(contentsOf: coordinator.configURL)
        cell = try self.valueCell(command: "arrange")
        cell.onChange?()
        sendKey(53)
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), before)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.defaultKeys["arrange"])
        XCTAssertEqual(try messageText(), "")

        cell = try self.valueCell(command: "arrange")
        cell.onChange?()
        sendKey(51)
        XCTAssertNil(coordinator.config.keys["arrange"])
        let removed = try String(contentsOf: coordinator.configURL)
        XCTAssertTrue(removed.contains("arrange = \"none\""), removed)
        XCTAssertEqual(try messageText(), "")
        XCTAssertFalse(try messageText().contains("Not applied."))

        try load(Config())
        try select(.keys)
        cell = try self.valueCell(command: "arrange")
        XCTAssertTrue(cell.canRemove)
        cell.onRemove?()
        XCTAssertNil(coordinator.config.keys["arrange"])
        XCTAssertEqual(try messageText(), "")

        try load(Config())
        try select(.keys)
        search("Arrange")
        cell = try self.valueCell(command: "arrange")
        XCTAssertEqual(cell.commandName, "arrange")
        cell.onChange?()
        sendKey(25, modifiers: .option)
        XCTAssertEqual(coordinator.config.keys["arrange"], Config.Key(modifiers: ["alt"], key: "9"))
        XCTAssertEqual(coordinator.config.keys["zoom"], Config.defaultKeys["zoom"])
        let note = try messageText()
        XCTAssertTrue(note.contains("Switch to Desktop 9"), note)
        XCTAssertTrue(note.contains("⌥9"), note)
    }

    func testClearAndDeleteDoNotClaimSuccessWhenTheSaveFails() throws {
        try load(Config())
        try select(.keys)
        let active = coordinator.config
        try "gap = 9\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        let cell = try self.valueCell(command: "arrange")
        cell.onRemove?()
        XCTAssertFalse(try messageText().contains("Removed the shortcut"))
        XCTAssertEqual(coordinator.config.keys["arrange"], active.keys["arrange"])
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gap = 9\n")
        let recovery = try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Settings Recovery" })
        XCTAssertFalse(recovery.stringValue.isEmpty)

        try load(Config())
        try select(.keys)
        let recorded = coordinator.config
        try "gap = 4\n".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        try self.valueCell(command: "integrate").onChange?()
        sendKey(117)
        XCTAssertFalse(try messageText().contains("Removed the shortcut"))
        XCTAssertEqual(coordinator.config.keys["integrate"], recorded.keys["integrate"])
        XCTAssertEqual(try String(contentsOf: coordinator.configURL), "gap = 4\n")
    }

    func testClickingTheShortcutTextReachesTheCell() throws {
        let cell = ShortcutValueCell(frame: NSRect(x: 0, y: 0, width: 216, height: 26))
        cell.actionLabel = "Arrange This Space"
        cell.setAssignment(display: "⌥⇧A", recording: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 216, height: 26))
        host.addSubview(cell)
        cell.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let text = NSPoint(x: cell.valueLabel.frame.midX, y: cell.valueLabel.frame.midY)
        let hit = host.hitTest(cell.convert(text, to: host))
        XCTAssertFalse(hit is NSTextField, "hit \(String(describing: hit))")
        XCTAssertFalse(hit is NSButton, "hit \(String(describing: hit))")
        XCTAssertFalse(cell.subviews.contains { $0 is NSButton })
        XCTAssertFalse(cell.accessibilityCustomActions().contains { $0.name == "Cancel Recording" })
        cell.setAssignment(display: "⌥⇧A", recording: true)
        XCTAssertTrue(cell.accessibilityCustomActions().contains { $0.name == "Cancel Recording" })
    }

    func testKeyboardRowAppearsOnlyForAWarningAndTheTableKeepsItsRows() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.keys)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertEqual(content.bounds.width, 720, accuracy: 1)
        XCTAssertEqual(content.bounds.height, SettingsWindowController.shortcutContentHeight, accuracy: 1)

        controller.nativeShortcutReader = { right in
            .usable(keyCode: right ? 124 : 123, modifiers: ["ctrl"])
        }
        controller.refresh()
        content.layoutSubtreeIfNeeded()
        let quiet = try shortcutTable()
        XCTAssertGreaterThanOrEqual(fullyVisibleRowCount(quiet), 8, "viewport \(quiet.enclosingScrollView?.frame.height ?? 0)")
        XCTAssertFalse(views().contains { ($0 as? NSButton)?.title == "Open Keyboard Settings…" && !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(views().contains { $0.accessibilityLabel() == "Space Switching Status" && !$0.isHiddenOrHasHiddenAncestor },
                       "no warning, so the status row is not shown")

        controller.nativeShortcutReader = { _ in .disabled }
        controller.refresh()
        content.layoutSubtreeIfNeeded()
        let warned = try shortcutTable()
        XCTAssertGreaterThanOrEqual(fullyVisibleRowCount(warned), 6, "viewport \(warned.enclosingScrollView?.frame.height ?? 0)")
        XCTAssertFalse(try button("Open Keyboard Settings…").isHiddenOrHasHiddenAncestor)
        let warnedStatus = try spaceStatus()
        XCTAssertFalse(warnedStatus.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(warnedStatus.stringValue.contains("off in macOS"), warnedStatus.stringValue)
        XCTAssertFalse(try button("Open Keyboard Settings…").title.isEmpty)

        let top = try XCTUnwrap(controller.window).frame.maxY
        controller.visibleHeightForLayout = 320
        controller.windowDidChangeScreen(Notification(name: NSWindow.didChangeScreenNotification, object: controller.window))
        var heights: [SettingsPane: CGFloat] = [:]
        for pane in SettingsPane.allCases {
            try select(pane)
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.bounds.width, 720, accuracy: 1)
            heights[pane] = content.bounds.height
        }
        XCTAssertEqual(heights[.keys]?.rounded(), heights[.apps]?.rounded(), "\(heights)")
        XCTAssertLessThanOrEqual(heights[.advanced]?.rounded() ?? 0, heights[.keys]?.rounded() ?? 0, "\(heights)")
        XCTAssertLessThanOrEqual(heights.values.max() ?? 0, 190)
        XCTAssertEqual(try XCTUnwrap(controller.window).frame.maxY, top, accuracy: 1)
    }

    func testExplanationsCannotBeSelected() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.layout)
        let labels = views().compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.stringValue.isEmpty }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Calculator") }, "the explanation is on this pane")
        for label in labels { XCTAssertFalse(label.isSelectable, label.stringValue) }
    }

    /// Checkbox and explanation pairs use the full control column, so a label that fits never wraps because of a long explanation (both languages).
    func testCheckboxColumnUsesTheControlColumnWidth() throws {
        for (language, code, title) in [(Language.english, "en", "Keep fixed-size windows next to arranged windows"),
                                        (.japanese, "ja", "大きさが固定のウインドウを整列したウインドウと並べて表示")] {
            var config = Config()
            config.language = code
            try load(config)
            Copy.language = language
            controller.refresh()
            controller.visibleHeightForLayout = 800
            try select(.layout)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let form = try XCTUnwrap(views().compactMap { $0 as? SettingsForm }.first)
            let box = try XCTUnwrap(views().compactMap { $0 as? NSButton }.first { $0.title == title }, code)
            let column = try XCTUnwrap(box.superview, code)
            XCTAssertEqual(column.frame.width, form.controlColumnWidth, accuracy: 0.5, code)
            XCTAssertEqual(box.frame.height, box.intrinsicContentSize.height, accuracy: 0.5, "\(code): the title fits on one line")
        }
        Copy.language = .english
    }

    func testPlacementPreviewFollowsThePopup() throws {
        try load(Config())
        controller.visibleHeightForLayout = 800
        try select(.layout)
        let preview = try XCTUnwrap(views().compactMap { $0 as? ActionPictogramView }.first)
        XCTAssertEqual(preview.frame.width, 42, accuracy: 1)
        XCTAssertEqual(preview.frame.height, 27, accuracy: 1)
        XCTAssertEqual(preview.pictogram, .placementBeside)
        let popup = try XCTUnwrap(views().compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("At the end") })
        XCTAssertEqual(popup.accessibilityHelp(), ActionPictogram.placementBeside.help)
        popup.selectItem(at: 1)
        _ = controller.perform(try XCTUnwrap(popup.action), with: popup)
        XCTAssertEqual(preview.pictogram, .placementEnd)
        XCTAssertEqual(popup.accessibilityHelp(), ActionPictogram.placementEnd.help)
        XCTAssertEqual(coordinator.config.newWindowPlacement, .end)
        popup.selectItem(at: 0)
        _ = controller.perform(try XCTUnwrap(popup.action), with: popup)
        XCTAssertEqual(preview.pictogram, .placementBeside)
    }

    func testOptInSettingsWindowContactSheet() throws {
        guard let raw = ProcessInfo.processInfo.environment["LAZYSPACE_SETTINGS_CONTACT_SHEET"], !raw.isEmpty else { return }
        let directory = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousKey = NSApp.keyWindow
        defer {
            if let again = try? valueCell(command: "arrange"), again.recording {
                again.onCancel?()
            }
            controller?.window?.orderOut(nil)
            if let previousKey, previousKey !== controller?.window { previousKey.makeKey() }
            Copy.language = .english
        }
        var names: [String] = []
        for (language, code) in [(Language.english, "en"), (.japanese, "ja")] {
            controller?.window?.orderOut(nil)
            var config = Config()
            config.language = code
            try load(config)
            controller.visibleHeightForLayout = 800
            controller.nativeShortcutReader = { _ in .disabled }
            Copy.language = language
            controller.refresh()
            try showCaptureWindow()
            for (appearance, theme) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                Copy.language = language
                controller.refresh()
                try applyAppearance(appearance)
                try select(.keys)
                clearShortcutStatus()
                try scrollShortcutsToTop()
                names.append(try captureContent(named: "shortcuts-\(code)-\(theme)-top", to: directory))
                try scrollSpaceCommandsIntoView()
                names.append(try captureContent(named: "shortcuts-\(code)-\(theme)-spaces", to: directory))
                names.append(try captureSpaceRows(named: "shortcuts-\(code)-\(theme)-spaces-rows", to: directory))
                names.append(try captureRecording(named: "shortcuts-\(code)-\(theme)-recording", to: directory))
                clearShortcutStatus()
                names.append(try capturePlacement(0, named: "arrangement-\(code)-\(theme)-beside", to: directory))
                names.append(try capturePlacement(1, named: "arrangement-\(code)-\(theme)-end", to: directory))
                let content = try XCTUnwrap(controller.window?.contentView)
                XCTAssertEqual(content.bounds.width, 720, accuracy: 1)
                XCTAssertGreaterThan(content.bounds.height, SettingsWindowController.formHeightFloor)
                XCTAssertLessThan(content.bounds.height, SettingsWindowController.shortcutContentHeight)
            }
        }
        names.append(contentsOf: try captureOneXPictogramRows(to: directory))
        let written = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        for name in names {
            XCTAssertTrue(written.contains(name), "missing \(name)")
        }
        for theme in ["light", "dark"] {
            for state in ["top", "spaces", "spaces-rows", "recording"] {
                try assertDifferentLanguages("shortcuts", state: state, theme: theme, in: directory)
            }
            for state in ["beside", "end"] {
                try assertDifferentLanguages("arrangement", state: state, theme: theme, in: directory)
            }
        }
    }

    private func assertDifferentLanguages(_ prefix: String, state: String, theme: String, in directory: URL) throws {
        let english = try Data(contentsOf: directory.appendingPathComponent("\(prefix)-en-\(theme)-\(state).png"))
        let japanese = try Data(contentsOf: directory.appendingPathComponent("\(prefix)-ja-\(theme)-\(state).png"))
        XCTAssertNotEqual(english, japanese, "\(prefix) \(theme) \(state) is the same image in English and Japanese")
    }

    private func clearShortcutStatus() {
        for label in views().compactMap({ $0 as? NSTextField }) {
            let accessible = label.accessibilityLabel() == "Shortcut Message" || label.accessibilityLabel() == "ショートカットの案内"
            if accessible {
                label.stringValue = ""
            }
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func showCaptureWindow() throws {
        let window = try XCTUnwrap(controller.window)
        window.collectionBehavior = []
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(NSPoint(x: maxX + 80, y: 120))
        window.orderFrontRegardless()
        window.makeKey()
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    private func applyAppearance(_ appearance: NSAppearance.Name) throws {
        let window = try XCTUnwrap(controller.window)
        let resolved = NSAppearance(named: appearance)
        window.appearance = resolved
        window.contentView?.appearance = resolved
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func scrollShortcutsToTop() throws {
        let table = try shortcutTable()
        table.scrollRowToVisible(0)
        if let clip = table.enclosingScrollView?.contentView {
            let inset = clip.contentInsets
            let origin = NSPoint(x: -inset.left, y: clip.isFlipped ? -inset.top : inset.bottom)
            clip.scroll(to: origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        if let outer = paneScrollView(), let document = outer.documentView {
            let top = NSPoint(x: 0, y: outer.contentView.isFlipped ? 0 : max(0, document.bounds.height - outer.contentView.bounds.height))
            outer.contentView.scroll(to: top)
            outer.reflectScrolledClipView(outer.contentView)
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
    }

    private func scrollSpaceCommandsIntoView() throws {
        let table = try shortcutTable()
        let heading = try XCTUnwrap(row(labeled: ShortcutSection.spaces.detail, in: table))
        let further = min(heading + 4, table.numberOfRows - 1)
        table.scrollRowToVisible(further)
        table.scrollRowToVisible(min(heading + 1, table.numberOfRows - 1))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let visible = visibleRowLabels(table)
        let marker = Copy.language == .japanese ? "ウィンドウを Space" : "Move Window to Space"
        XCTAssertTrue(visible.contains { $0.contains(marker) }, "Spaces rows are not in view: \(visible)")
    }

    private func visibleRowLabels(_ table: NSTableView) -> [String] {
        guard let clip = table.enclosingScrollView?.contentView else { return [] }
        let rect = table.convert(clip.bounds, from: clip).insetBy(dx: 0, dy: -1)
        return (0..<table.numberOfRows).compactMap { row in
            table.rect(ofRow: row).intersects(rect) ? rowLabel(in: table, row: row) : nil
        }
    }

    private func paneScrollView() -> NSScrollView? {
        views().compactMap { $0 as? NSScrollView }.first { $0.enclosingScrollView == nil && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func captureContent(named name: String, to directory: URL) throws -> String {
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let image = try XCTUnwrap(rasterize(content, scale: 2), "cacheDisplay returned nil for \(name)")
        XCTAssertGreaterThanOrEqual(image.pixelsWide, Int(content.bounds.width * 2) - 1, "\(name) is not a 2x capture")
        let filename = "\(name).png"
        try write(image, to: directory.appendingPathComponent(filename))
        return filename
    }

    private func captureSpaceRows(named name: String, to directory: URL) throws -> String {
        try scrollSpaceCommandsIntoView()
        let table = try shortcutTable()
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        scroll.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let image = try XCTUnwrap(rasterize(scroll, scale: 2), "cacheDisplay returned nil for \(name)")
        let filename = "\(name).png"
        try write(image, to: directory.appendingPathComponent(filename))
        return filename
    }

    private func captureRecording(named name: String, to directory: URL) throws -> String {
        try select(.keys)
        let table = try shortcutTable()
        let arrange = try XCTUnwrap(row(labeled: SettingsCopy.commandLabel("arrange"), in: table))
        table.scrollRowToVisible(arrange)
        try valueCell(command: "arrange").onChange?()
        defer {
            if let again = try? valueCell(command: "arrange"), again.recording {
                again.onCancel?()
            }
        }
        table.scrollRowToVisible(arrange)
        controller.window?.makeKey()
        controller.window?.displayIfNeeded()
        return try captureContent(named: name, to: directory)
    }

    private func capturePlacement(_ index: Int, named name: String, to directory: URL) throws -> String {
        try select(.layout)
        let popup = try placementPopup(index: index)
        popup.selectItem(at: index)
        _ = controller.perform(try XCTUnwrap(popup.action), with: popup)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        return try captureContent(named: name, to: directory)
    }

    private func placementPopup(index: Int) throws -> NSPopUpButton {
        let beside = Copy.language == .japanese ? "フォーカス中のウィンドウの隣" : "Beside the focused window"
        return try XCTUnwrap(views().compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains(beside) && $0.itemTitles.count > index })
    }

    private func captureOneXPictogramRows(to directory: URL) throws -> [String] {
        let kinds: [ActionPictogram] = [
            .focus, .swap, .move, .join, .resize, .smartGrow, .smartShrink, .balance, .undo,
            .toggleSplit, .accordion, .arrange, .integrate, .pause, .reload, .close, .focusBack,
            .float, .zoom, .fullscreen, .minimize, .switchSpace(3), .spaceNext, .spacePrev, .spaceBack,
            .moveToSpace(3), .moveToSpaceNext, .moveToSpacePrev, .placementBeside, .placementEnd,
        ]
        let slot: CGFloat = 32
        let width = CGFloat(kinds.count) * slot
        let rowHeight: CGFloat = 36
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * 3))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icons"))
        column.width = width
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        let source = OneXPictogramTable(kinds: kinds, slot: slot, rowHeight: rowHeight)
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        TestWindows.conceal(window)
        window.contentView = scroll
        window.appearance = NSAppearance(named: .aqua)
        defer { window.orderOut(nil) }
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(NSPoint(x: maxX + 80, y: 40))
        window.orderFrontRegardless()
        window.makeKey()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        if let cell = table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? OneXPictogramCell {
            cell.backgroundStyle = .emphasized
        }
        window.displayIfNeeded()
        table.layoutSubtreeIfNeeded()
        var names: [String] = []
        for (index, background) in ["normal", "alternate", "selected"].enumerated() {
            let rect = table.rect(ofRow: index)
            let image = try XCTUnwrap(rasterize(table, scale: 1, rect: rect), "1x \(background) row did not cache")
            XCTAssertEqual(image.pixelsHigh, Int(rowHeight.rounded()), "\(background) strip is not 1x")
            let filename = "pictograms-1x-\(background).png"
            try write(image, to: directory.appendingPathComponent(filename))
            names.append(filename)
        }
        _ = source
        return names
    }

    private func load(_ config: Config) throws {
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
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

    private func keySearch() -> NSSearchField { views().compactMap { $0 as? NSSearchField }.first! }

    private func valueCell(command: String) throws -> ShortcutValueCell {
        let table = try shortcutTable()
        for row in 0..<table.numberOfRows {
            if let cell = table.view(atColumn: 1, row: row, makeIfNecessary: true) as? ShortcutValueCell, cell.commandName == command {
                return cell
            }
        }
        throw ShortcutValueCellMissing(command: command)
    }

    private func row(labeled text: String, in table: NSTableView) -> Int? {
        for row in 0..<table.numberOfRows where rowLabel(in: table, row: row).contains(text) { return row }
        return nil
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

    private func messageText() throws -> String {
        views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Shortcut Message" || $0.accessibilityLabel() == "ショートカットの案内" }?.stringValue ?? ""
    }

    private func spaceStatus() throws -> NSTextField {
        try XCTUnwrap(views().compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Space Switching Status" || $0.accessibilityLabel() == "操作スペース切り替えの状態" })
    }

    private func search(_ text: String) {
        let field = keySearch()
        field.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func sendKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) {
        let number = (window ?? controller.window)?.windowNumber ?? 0
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)
        if let down { NSApp.sendEvent(down) }
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)
        if let up { NSApp.sendEvent(up) }
    }

    private func fullyVisibleRowCount(_ table: NSTableView) -> Int {
        guard let viewport = table.enclosingScrollView else { return 0 }
        viewport.layoutSubtreeIfNeeded()
        let clipHeight = viewport.contentView.bounds.height
        guard clipHeight > 1 else { return 0 }
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

    private func rasterize(_ view: NSView, scale: CGFloat, rect: NSRect? = nil) -> NSBitmapImageRep? {
        let bounds = rect ?? view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        view.layoutSubtreeIfNeeded()
        let pixelsWide = max(1, Int((bounds.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((bounds.height * scale).rounded(.up)))
        let cached = view.bitmapImageRepForCachingDisplay(in: bounds)
        let rep: NSBitmapImageRep
        if let cached, cached.pixelsWide >= pixelsWide - 1, cached.pixelsHigh >= pixelsHigh - 1 {
            rep = cached
        } else {
            guard let created = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            created.size = bounds.size
            rep = created
        }
        view.cacheDisplay(in: bounds, to: rep)
        paintWindowBackground(behind: rep, matching: view)
        return rep
    }

    /// cacheDisplay leaves the window backdrop transparent. Paint it behind the captured pixels.
    private func paintWindowBackground(behind rep: NSBitmapImageRep, matching view: NSView) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.compositingOperation = .destinationOver
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

private struct ShortcutValueCellMissing: Error, CustomStringConvertible {
    var command: String
    var description: String { "missing shortcut cell \(command)" }
}

private final class OneXPictogramCell: NSTableCellView {
    let icons: [ActionPictogramView]
    init(kinds: [ActionPictogram], slot: CGFloat, rowHeight: CGFloat) {
        icons = kinds.map { kind in
            let icon = ActionPictogramView(frame: .zero)
            icon.pictogram = kind
            return icon
        }
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(kinds.count) * slot, height: rowHeight))
        for (index, icon) in icons.enumerated() {
            icon.frame = NSRect(x: CGFloat(index) * slot + 2, y: ((rowHeight - 18) / 2).rounded(), width: 28, height: 18)
            addSubview(icon)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            for icon in icons { icon.emphasized = emphasized }
        }
    }
}

private final class OneXPictogramTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let kinds: [ActionPictogram]
    let slot: CGFloat
    let rowHeight: CGFloat
    init(kinds: [ActionPictogram], slot: CGFloat, rowHeight: CGFloat) {
        self.kinds = kinds
        self.slot = slot
        self.rowHeight = rowHeight
    }
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        OneXPictogramCell(kinds: kinds, slot: slot, rowHeight: rowHeight)
    }
}
