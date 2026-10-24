import AppKit
import Copy
import LayoutCore
@testable import Operations
import Settings
import XCTest
@testable import LazySpaceApp

/// Interface text fits in every shipped language: nothing in Settings or the window list is cut off or pushed out of its
/// view. The windows are built offscreen (`TestWindows`), filled with short user data, so any text that does not fit is
/// LazySpace's own.
@MainActor
final class TextFitTests: XCTestCase {
    private var root: URL!
    private var coordinator: Coordinator!
    private var preferences: UserDefaults!
    private var testPreferences: TestPreferences!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testPreferences = TestPreferences("TextFitTests")
        preferences = testPreferences.defaults
        let system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil })
    }

    override func tearDownWithError() throws {
        testPreferences.remove()
        try FileManager.default.removeItem(at: root)
        Copy.language = .english
    }

    // MARK: - The check

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func lineHeight(_ font: NSFont?) -> CGFloat { NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) }

    /// Text that does not fit under `root`:
    /// - a single-line label or a button title wider than its frame (a pop-up button by its selected item)
    /// - wrapping text that needs more lines than it may show, or more height than it has
    /// - a table column heading wider than its column
    /// - text (not its frame) running past the right edge of the window, or of the scroll view it sits in
    static func clippedText(in root: NSView) -> [String] {
        var found: [String] = []
        for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor {
            let bounds = view.bounds
            var text: String?
            var textWidth = bounds.width
            if let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty, let cell = field.cell {
                text = field.stringValue
                textWidth = min(bounds.width, cell.cellSize.width)
                let wraps = cell.wraps && field.maximumNumberOfLines != 1
                if !wraps, cell.cellSize.width > bounds.width + 0.5 {
                    found.append("cut: “\(field.stringValue)” needs \(Int(cell.cellSize.width)) of \(Int(bounds.width)) pt")
                } else if wraps, let measure = cell.copy() as? NSTextFieldCell {
                    measure.wraps = true
                    measure.truncatesLastVisibleLine = false
                    measure.lineBreakMode = .byWordWrapping
                    let height = measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: 100_000)).height
                    let lines = Int((height / lineHeight(field.font)).rounded())
                    if field.maximumNumberOfLines > 0, lines > field.maximumNumberOfLines {
                        found.append("cut: “\(field.stringValue)” needs \(lines) lines, shows \(field.maximumNumberOfLines)")
                    } else if height > bounds.height + 1 {
                        found.append("cut: “\(field.stringValue)” needs \(Int(height)) of \(Int(bounds.height)) pt high")
                    }
                }
            } else if let popup = view as? NSPopUpButton, let title = popup.titleOfSelectedItem, !title.isEmpty {
                text = title
                let needed = (title as NSString).size(withAttributes: [.font: popup.font ?? .systemFont(ofSize: 13)]).width
                let room = popup.cell?.titleRect(forBounds: bounds).width ?? bounds.width
                if needed > room + 0.5 {
                    found.append("cut: pop-up “\(title)” needs \(Int(needed)) of \(Int(room)) pt")
                }
            } else if let button = view as? NSButton, !button.title.isEmpty, let cell = button.cell {
                text = button.title
                textWidth = min(bounds.width, cell.cellSize.width)
                if cell.cellSize.width > bounds.width + 0.5 {
                    found.append("cut: button “\(button.title)” needs \(Int(cell.cellSize.width)) of \(Int(bounds.width)) pt")
                }
            }
            if let table = view as? NSTableView {
                for column in table.tableColumns where !column.isHidden && column.headerCell.cellSize.width > column.width + 0.5 {
                    found.append("cut: column “\(column.title)” needs \(Int(column.headerCell.cellSize.width)) of \(Int(column.width)) pt")
                }
            }
            // Past the right edge of what can be seen: the window, or the scroll view the text is in.
            if let text, let window = view.window, let content = window.contentView {
                let frame = view.convert(NSRect(x: bounds.minX, y: bounds.minY, width: textWidth, height: bounds.height), to: nil)
                var limit = content.convert(content.bounds, to: nil).maxX
                var ancestor = view.superview
                while let current = ancestor {
                    if let clip = current as? NSClipView { limit = min(limit, clip.convert(clip.bounds, to: nil).maxX) }
                    ancestor = current.superview
                }
                if frame.maxX > limit + 0.5 { found.append("past the edge by \(Int(frame.maxX - limit)) pt: “\(text)”") }
            }
        }
        return found
    }

    /// The check itself finds a label that is too long, a button that is too narrow, and wrapping text with too few lines.
    func testTheCheckFindsClippedText() {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let label = NSTextField(labelWithString: "A label far longer than the eighty points it is given")
        label.frame = NSRect(x: 0, y: 0, width: 80, height: 20)
        let fits = NSTextField(labelWithString: "OK")
        fits.frame = NSRect(x: 0, y: 30, width: 80, height: 20)
        let button = NSButton(title: "A long button title", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 60, width: 60, height: 24)
        let wrapping = NSTextField(wrappingLabelWithString: String(repeating: "Several words that wrap. ", count: 8))
        wrapping.maximumNumberOfLines = 2
        wrapping.frame = NSRect(x: 0, y: 100, width: 120, height: 40)
        [label, fits, button, wrapping].forEach(box.addSubview)
        let found = Self.clippedText(in: box)
        XCTAssertEqual(found.count, 3, found.joined(separator: "\n"))
        XCTAssertFalse(found.contains { $0.contains("“OK”") })
    }

    // MARK: - Settings and the window list

    /// Settings in a state that shows its conditional lines: a configuration error, the notification line, and an update.
    private func settings() throws -> SettingsWindowController {
        var config = Config()
        config.language = Copy.language.rawValue
        config.notifications.needsAttention = true
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        let controller = TestWindows.settings(coordinator: coordinator, preferences: preferences)
        let fake = FakeNotifier()
        fake.stored = .denied
        let attention = AttentionNotifier(notifier: fake)
        controller.attention = attention
        attention.refreshPermission()
        let updates = FakeUpdates()
        updates.offer = UpdateOffer(version: "9.9.9", build: "999")
        controller.updates = updates
        controller.showWindow(nil)
        try "language = \"\(Copy.language.rawValue)\"\ngap = \"wide\"".write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        // The app passes the configuration's status to Settings this way (AppDelegate wires onConfigStatus).
        controller.applyConfigStatus(coordinator.configError, isError: true)
        return controller
    }

    func testSettingsTextFitsInEveryLanguage() throws {
        var found: [String] = []
        for language in Language.allCases {
            Copy.language = language
            let controller = try settings()
            defer { controller.window?.orderOut(nil) }
            var shown: Set<String> = []
            for pane in SettingsPane.allCases {
                controller.show(pane: pane)
                let content = try XCTUnwrap(controller.window?.contentView)
                content.layoutSubtreeIfNeeded()
                found += Self.clippedText(in: content).map { "\(language.rawValue) \(pane.rawValue): \($0)" }
                shown.formUnion(Self.descendants(content).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? NSTextField)?.stringValue })
            }
            // The conditional lines were on screen, so they were measured too.
            for line in [SettingsCopy.configBannerMessage, L(.settingsWindowNotificationsDenied), UpdateCopy.notice(UpdateOffer(version: "9.9.9", build: "999"))] {
                XCTAssertTrue(shown.contains(line), "\(language.rawValue): “\(line)” was not shown")
            }
        }
        XCTAssertEqual(found, [], "text that does not fit:\n" + found.joined(separator: "\n"))
    }

    /// Opt-in: LAZYSPACE_SNAPSHOTS=<folder> renders every Settings pane and the window list in every language to PNG files there,
    /// for a person to look at. Nothing appears on screen.
    func testSnapshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["LAZYSPACE_SNAPSHOTS"] else { throw XCTSkip("set LAZYSPACE_SNAPSHOTS to a folder") }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        for language in Language.allCases {
            Copy.language = language
            let controller = try settings()
            defer { controller.window?.orderOut(nil) }
            for pane in SettingsPane.allCases {
                controller.show(pane: pane)
                try save(try XCTUnwrap(controller.window?.contentView), "\(language.rawValue)-settings-\(pane.rawValue)")
            }
            let inspection = CLILayoutTests.inspection()
            let list = TestWindows.inspector(loadInspection: { $0(inspection) }, readLive: { WindowInspectLive(
                spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [], status: self.coordinator.status(), firstLaunchDone: true) },
                markReady: {}, openGeneralSettings: {}, openAccessSettings: {})
            defer { list.close() }
            list.showWindow(nil)
            try save(try XCTUnwrap(list.window?.contentView), "\(language.rawValue)-window-list")
        }
    }

    func testWindowListTextFitsInEveryLanguage() throws {
        var found: [String] = []
        for language in Language.allCases {
            Copy.language = language
            let inspection = CLILayoutTests.inspection()
            let controller = TestWindows.inspector(loadInspection: { $0(inspection) }, readLive: { WindowInspectLive(
                spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [], status: self.coordinator.status(), firstLaunchDone: true) },
                markReady: {}, openGeneralSettings: {}, openAccessSettings: {})
            defer { controller.close() }
            controller.showWindow(nil)
            let content = try XCTUnwrap(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            found += Self.clippedText(in: content).map { "\(language.rawValue): \($0)" }
        }
        XCTAssertEqual(found, [], "text that does not fit:\n" + found.joined(separator: "\n"))
    }

    /// Every reason TargetSelection gives for leaving a window out, one row each. The longer reasons an arrangement
    /// adds (already longer than the column in English) are cut with the full text in the tooltip.
    static func everyExclusion() -> Inspection {
        func window(_ id: UInt32, _ membership: ObservedWindow.Membership, _ kind: ObservedWindow.Kind) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: "com.apple.finder", frame: CGRect(x: 0, y: 25, width: 800, height: 600), membership: membership, kind: kind, detail: "")
        }
        let memberships: [ObservedWindow.Membership] = [.unknown, .other, .otherDisplay, .allSpaces]
        let kinds: [ObservedWindow.Kind] = [.dialog, .sheet, .palette, .minimized, .hiddenApp, .fullscreen, .nonNormalLayer, .unknownRole]
        let excluded = (memberships.map { (membership: $0, kind: ObservedWindow.Kind.standard) } + kinds.map { (membership: .current, kind: $0) })
            .enumerated().map { index, item in
                let w = window(UInt32(index + 2), item.membership, item.kind)
                return Exclusion(window: w, reason: TargetSelection.exclusionReason(w) ?? "")
            }
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: CGRect(x: 0, y: 25, width: 1440, height: 875), windows: [],
                            spaceObservationAvailable: true, unobservedApps: ["com.example.slow"])
        return Inspection(snapshot: snap, targets: [window(1, .current, .standard)], excluded: excluded, takenAt: Date(timeIntervalSince1970: 0))
    }

    func testEveryExclusionReasonFitsTheWindowListInEveryLanguage() throws {
        var found: [String] = []
        // Scroll bars that are always shown take width from the table; overlay ones do not.
        for scrollerStyle in [NSScroller.Style.overlay, .legacy] {
            for language in Language.allCases {
                Copy.language = language
                let inspection = Self.everyExclusion()
                XCTAssertFalse(inspection.excluded.contains { $0.reason.isEmpty })
                let controller = TestWindows.inspector(loadInspection: { $0(inspection) }, readLive: { WindowInspectLive(
                    spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [], status: self.coordinator.status(), firstLaunchDone: true) },
                    markReady: {}, openGeneralSettings: {}, openAccessSettings: {}, scrollerStyle: scrollerStyle)
                defer { controller.close() }
                controller.showWindow(nil)
                // At the default width, tall enough that every row has a view.
                let window = try XCTUnwrap(controller.window)
                window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: 900))
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.visibleRows().count, inspection.excluded.count + 2)
                let style = scrollerStyle == .legacy ? "legacy" : "overlay"
                found += Self.clippedText(in: content).map { "\(language.rawValue), \(style) scroll bars: \($0)" }
            }
        }
        XCTAssertEqual(found, [], "text that does not fit:\n" + found.joined(separator: "\n"))
    }

    /// While recording a shortcut that has no keys yet, the cell shows its prompt in the field-like box: at the default
    /// width, and with the Action column dragged wide so the Shortcut column is at its minimum.
    func testRecordingPromptFitsInEveryLanguage() throws {
        var found: [String] = []
        for language in Language.allCases {
            for narrowest in [false, true] {
                Copy.language = language
                let controller = try settings()
                defer { controller.window?.orderOut(nil) }
                controller.show(pane: .keys)
                let content = try XCTUnwrap(controller.window?.contentView)
                content.layoutSubtreeIfNeeded()
                let table = try XCTUnwrap(Self.descendants(content).compactMap { $0 as? NSTableView }
                    .first { $0.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("key")) != nil })
                let keyColumn = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("key")))
                if narrowest {
                    let label = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")))
                    let visible = try XCTUnwrap(table.enclosingScrollView?.contentView.bounds.width)
                    label.width = visible - keyColumn.minWidth - 2 * table.intercellSpacing.width
                    table.sizeLastColumnToFit()
                    content.layoutSubtreeIfNeeded()
                    XCTAssertEqual(keyColumn.width, keyColumn.minWidth, accuracy: 1, language.rawValue)
                }
                let where_ = "\(language.rawValue)\(narrowest ? " narrowest" : "")"
                let cell = try XCTUnwrap(Self.descendants(content).compactMap { $0 as? ShortcutValueCell }.first { $0.valueLabel.stringValue.isEmpty },
                                         "\(where_): no unassigned shortcut on screen")
                cell.onChange?()
                content.layoutSubtreeIfNeeded()
                XCTAssertTrue(cell.recording, where_)
                XCTAssertEqual(cell.valueLabel.stringValue, L(.settingsControlsTypeShortcut), where_)
                found += Self.clippedText(in: cell).map { "\(where_): \($0)" }
            }
        }
        XCTAssertEqual(found, [], "text that does not fit:\n" + found.joined(separator: "\n"))
    }
}
