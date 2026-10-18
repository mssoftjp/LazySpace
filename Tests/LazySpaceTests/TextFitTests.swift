import AppKit
import Copy
import Operations
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
    private var suite: String!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "LazySpace.TextFitTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
        let system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil })
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
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
}
