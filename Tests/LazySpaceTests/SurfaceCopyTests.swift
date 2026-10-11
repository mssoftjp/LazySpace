import AppKit
import XCTest
import Copy
import LayoutCore
import Settings
@testable import MacSupport
@testable import Operations
@testable import LazySpace

final class SurfaceCopyTests: XCTestCase {
    func testReadyResultHidesIssueCounts() {
        let result = OperationResult.note(kind: "arrange", spaceID: 1, message: "Arranged 2 windows.", ok: true)
        let everyday = ReadyWindowController.resultBody(result)
        XCTAssertEqual(everyday, "Arranged 2 windows.")
        XCTAssertFalse(everyday.contains("Requests"))
    }

    func testMenuShortcutsUseNativeColumnsAndFollowTheActiveMode() throws {
        let main = HotkeyBinding.from(Config())
        let item = NSMenuItem(title: "Arrange Now", action: nil, keyEquivalent: "")
        HotkeyBinding.applyMenuShortcut(main.first { $0.action == .arrange }, to: item)
        XCTAssertEqual(item.title, "Arrange Now")
        XCTAssertEqual(item.keyEquivalent, "a")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .shift])

        var config = Config()
        config.modes["service"] = Config.Mode(keys: [
            "arrange": Config.Key(modifiers: [], key: "r"),
            "mode-main": Config.Key(modifiers: [], key: "esc"),
        ])
        let service = HotkeyBinding.from(config, mode: "service")
        HotkeyBinding.applyMenuShortcut(service.first { $0.action == .arrange }, to: item)
        XCTAssertEqual(item.keyEquivalent, "r")
        XCTAssertEqual(item.keyEquivalentModifierMask, [], "Unmodified mode keys must not inherit Command")
        HotkeyBinding.applyMenuShortcut(service.first { $0.action == .mode("main") }, to: item)
        XCTAssertEqual(item.keyEquivalent, "\u{1b}")
        HotkeyBinding.applyMenuShortcut(service.first { $0.action == .edit(.focus(.right)) }, to: item)
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])
    }

    func testNativeMenuShortcutSpecialKeys() throws {
        let cases: [(String, String, NSEvent.ModifierFlags)] = [
            ("ctrl-alt-left", "\u{f702}", [.control, .option]),
            ("shift-f12", "\u{f70f}", [.shift]),
            ("cmd-comma", ",", [.command]),
            ("alt-keypad2", "2", [.option, .numericPad]),
        ]
        let item = NSMenuItem(title: "Action", action: nil, keyEquivalent: "")
        for (text, character, modifiers) in cases {
            let key = try XCTUnwrap(Config.Key.parse(text))
            let binding = HotkeyBinding(keyCode: key.keyCode, modifiers: key.carbonModifiers, action: .arrange, display: key.display)
            HotkeyBinding.applyMenuShortcut(binding, to: item)
            XCTAssertEqual(item.keyEquivalent, character, text)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, text)
            XCTAssertEqual(item.title, "Action")
        }
    }

    func testStatusMenuGroupsEditingAndDropsTheAbbreviation() {
        XCTAssertEqual(StatusMenuCopy.editSections.map(\.title), ["Focus Window", "Swap Positions", "Reorder", "Share Neighbor's Area", "Size and Layout", "Window"])
        let commands = StatusMenuCopy.editSections.flatMap(\.commands)
        let names = commands.map { String(describing: $0) }
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(commands.count, 32)
        XCTAssertEqual(EditCommand.fullscreen.label, "Toggle Full Screen")
        XCTAssertEqual(EditCommand.toggleZoom.label, "Fill Work Area / Restore Layout")
        XCTAssertEqual(EditCommand.toggleAccordion.label, "Switch Overlapping / Tiled")
        XCTAssertTrue(commands.contains(.toggleAccordion))
        XCTAssertTrue(commands.contains(.fullscreen))
        XCTAssertTrue(commands.contains(.focusBack))
        XCTAssertTrue(commands.contains(.balance))
    }

    func testReadyTextUsesProvidedAppNames() {
        let now = Date()
        let finder = TargetReport(id: WindowID(1), app: "com.apple.finder", before: .zero, planned: nil, after: nil, status: .mismatch, issued: 1, note: nil)
        let big = TargetReport(id: WindowID(2), app: "com.example.big", before: .zero, planned: nil, after: nil, status: .mismatch, issued: 1, note: nil)
        let result = OperationResult(
            id: "1", kind: "arrange", startedAt: now, finishedAt: now, outcome: .partial, stopReason: nil,
            spaceID: 1, workArea: .zero, targets: [finder, big], excluded: [], issued: 2, retries: 0,
            verified: true, maxWriteMs: 0, wallMs: 10,
            message: "Windows: com.apple.finder, com.apple, com.example.big", tolerance: 1, rows: 0,
            unobservedApps: ["com.apple"])
        let name: (String) -> String = {
            switch $0 {
            case "com.apple.finder": return "Finder"
            case "com.example.big": return "Big App"
            case "com.apple": return "Apple"
            default: return $0
            }
        }
        let body = ReadyWindowController.resultBody(result, name: name)
        XCTAssertEqual(body, "Windows: Finder, Apple, Big App")
        XCTAssertFalse(body.contains("com."))
        XCTAssertFalse(body.contains("Requests"))
        XCTAssertEqual(ReadyWindowController.shownApp("com.apple.finder", name: name), "Finder")
        XCTAssertEqual(ReadyWindowController.shownApp("com.example.other", name: { _ in "" }), "com.example.other")
    }

    func testSettingsShowsAppNamesAndHidesCommandKeys() {
        XCTAssertEqual(SettingsCopy.keyColumns, ["Action", "Shortcut"])
        XCTAssertEqual(SettingsCopy.ruleAppColumn, "App")
        XCTAssertEqual(SettingsCopy.manualRuleTitle, "Enter Bundle Identifier…")
        XCTAssertFalse(SettingsCopy.fileCaption().contains("TOML"))
        XCTAssertFalse(SettingsCopy.fileCaption().contains(".bak"))
        let name: (String) -> String? = { $0 == "com.apple.finder" ? "Finder" : nil }
        XCTAssertEqual(SettingsCopy.knownAppName("com.apple.finder", name: name), "Finder")
        XCTAssertNil(SettingsCopy.knownAppName("com.apple.*", name: { _ in "never" }))
        XCTAssertNil(SettingsCopy.knownAppName("", name: { _ in "never" }))
        XCTAssertNil(SettingsCopy.knownAppName("com.example.missing", name: name))
        XCTAssertEqual(SettingsCopy.commandLabel("focus-left"), "Focus Left")
        XCTAssertFalse(SettingsCopy.commandLabel("focus-left").contains("focus-left"))
    }

    func testMenuCopyUsesArrangeNow() {
        XCTAssertEqual(StatusMenuCopy.arrangeTitle, "Arrange Now")
        XCTAssertEqual(StatusMenuCopy.startHint(arrangeKey: nil), "the menu item “Arrange Now”")
        XCTAssertEqual(StatusMenuCopy.startHint(arrangeKey: "⌥A"), "⌥A (or the menu item “Arrange Now”)")
        XCTAssertTrue(StatusMenuCopy.notStartedMessage(arrangeKey: nil).contains("Arrange Now"))
        XCTAssertFalse(StatusMenuCopy.notStartedMessage(arrangeKey: nil).contains("Start Tiling"))
        XCTAssertEqual(ReadyWindowController.verdictColumnTitle, "Eligibility")
        let old = OperationResult.note(kind: "arrange", spaceID: 1, message: "Old", ok: false, at: Date().addingTimeInterval(-3 * 60 * 60))
        XCTAssertFalse(StatusMenuCopy.showsRecent(result: old, managed: false))
        XCTAssertEqual(StatusMenuCopy.resumeNotice(), "Resumed LazySpace.")
        XCTAssertFalse(StatusMenuCopy.resumeNotice().lowercased().contains("arrange"))
        XCTAssertEqual(StatusMenuCopy.occupancyLine(waiting: 0, floatingCount: 0, zoomed: false), "Waiting windows: 0")
        XCTAssertEqual(StatusMenuCopy.occupancyLine(waiting: 2, floatingCount: 1, zoomed: true), "Waiting windows: 2  Floating: 1  Zoomed")
        XCTAssertFalse(StatusMenuCopy.occupancyLine(waiting: 0, floatingCount: 0, zoomed: true).contains("Zoom:"))
        XCTAssertNil(StatusMenuCopy.occupancyLine(waiting: 0, floatingCount: 0, zoomed: true).range(of: #"\bw\d"#, options: .regularExpression))
        var zoomedStatus = sampleStatus()
        zoomedStatus.zoomed = WindowID(4094)
        let zoomedText = CLI.statusText(zoomedStatus)
        XCTAssertTrue(zoomedText.contains("Zoomed"))
        XCTAssertFalse(zoomedText.contains("Zoom:"))
        XCTAssertFalse(zoomedText.contains("w4094"))
        XCTAssertFalse(zoomedText.contains("4094"))
        XCTAssertFalse(StatusMenuCopy.offersIntegrate(waiting: 0))
        XCTAssertTrue(StatusMenuCopy.offersIntegrate(waiting: 2))
        XCTAssertEqual(StatusMenuCopy.integrateTitle(waiting: 1), "Add One Waiting Window")
        XCTAssertEqual(StatusMenuCopy.integrateTitle(waiting: 6), "Add One Waiting Window (6 Waiting)")
        var crowded = sampleStatus(availability: .automatic, autoAvailable: true)
        crowded.currentSpaceManaged = true
        crowded.waiting = [WindowID(1), WindowID(2)]
        crowded.modes = ["main", "service"]
        let entries = StatusMenuCopy.topEntries(status: crowded, spaceCount: 3, modeCount: 2)
        XCTAssertLessThanOrEqual(entries.count, 12)
        XCTAssertEqual(entries.map(\.kind), [.spaces, .space, .edit, .spacePause, .arrange, .integrate, .mode, .globalPause, .settings, .status, .quit])
        XCTAssertEqual(entries[0].title, "", "the Space list has no heading")
        XCTAssertEqual(entries[1].title, "Move Window to Space", "the most used window actions come right after the Space list")
        XCTAssertEqual(entries.first { $0.kind == .status }?.title, "Check Windows…")
        let sparse = StatusMenuCopy.topEntries(status: sampleStatus(), spaceCount: 1, modeCount: 1)
        XCTAssertEqual(sparse.map(\.kind), [.edit, .spacePause, .arrange, .globalPause, .settings, .status, .quit])
        XCTAssertEqual(StatusMenuCopy.globalPauseTitle(paused: false), "Pause LazySpace")
        XCTAssertEqual(StatusMenuCopy.globalPauseTitle(paused: true), "Resume LazySpace")
        var paused = crowded
        paused.paused = true
        XCTAssertEqual(StatusMenuCopy.topEntries(status: paused, spaceCount: 3, modeCount: 2).map(\.kind), [.globalPause, .settings, .status, .quit])
        XCTAssertEqual(AccessPane.name(osMajor: 26), "Accessibility")
        XCTAssertEqual(AccessPane.name(osMajor: 27), "Device Control and Data Access")
        XCTAssertEqual(MacItem.openAtLogin, "Open at Login")
        XCTAssertEqual(MacItem.loginItems(osMajor: 14), "Login Items")
        XCTAssertEqual(MacItem.loginItems(osMajor: 27), "Login Items & Extensions")
        var untrusted = sampleStatus()
        untrusted.trusted = false
        let blocked = StatusMenuCopy.topEntries(status: untrusted, spaceCount: 1, modeCount: 1)
        XCTAssertEqual(blocked.first?.kind, .accessibility)
        XCTAssertEqual(blocked.first?.title, "Allow LazySpace in \(AccessPane.name())…")
        paused.trusted = false
        XCTAssertEqual(StatusMenuCopy.topEntries(status: paused, spaceCount: 3, modeCount: 2).map(\.kind), [.accessibility, .globalPause, .settings, .status, .quit])
        // While the configuration file cannot be applied, its entry comes right after the permission entry (even while paused).
        paused.configError = "The configuration has errors"
        XCTAssertEqual(StatusMenuCopy.topEntries(status: paused, spaceCount: 3, modeCount: 2).map(\.kind), [.accessibility, .configError, .globalPause, .settings, .status, .quit])
        var broken = sampleStatus()
        broken.configError = "The configuration has errors"
        let brokenEntries = StatusMenuCopy.topEntries(status: broken, spaceCount: 1, modeCount: 1)
        XCTAssertEqual(brokenEntries.first?.kind, .configError)
        XCTAssertEqual(brokenEntries.first?.title, "The Configuration File Could Not Be Applied…")
        XCTAssertTrue(CLI.usage.contains("Add one waiting window"))
        XCTAssertEqual(StatusMenuCopy.availabilityTitle(sampleStatus()), "Manual Arrangement Only")
        var automatic = sampleStatus(availability: .automatic, autoAvailable: true)
        XCTAssertEqual(StatusMenuCopy.availabilityTitle(automatic), "Automatic Arrangement Available (This Space Not Started)")
        automatic.currentSpaceManaged = true
        XCTAssertEqual(StatusMenuCopy.availabilityTitle(automatic), "Automatic Arrangement Active")
        XCTAssertEqual(ReadyWindowController.windowTitle, "LazySpace — Windows")
        XCTAssertEqual(ReadyWindowController.menuTitle, "Check Windows…")
        XCTAssertTrue(CLI.usage.contains("Open the window list"))
        XCTAssertFalse(CLI.usage.contains("Show Setup"))
        XCTAssertFalse(CLI.usage.lowercased().contains("click and drag"))
        let now = Date()
        let finder = TargetReport(id: WindowID(1), app: "com.apple.finder", before: .zero, planned: nil, after: nil, status: .mismatch, issued: 1, note: nil)
        let result = OperationResult(
            id: "1", kind: "arrange", startedAt: now, finishedAt: now, outcome: .partial, stopReason: nil,
            spaceID: 1, workArea: .zero, targets: [finder], excluded: [], issued: 1, retries: 0,
            verified: true, maxWriteMs: 0, wallMs: 10,
            message: "Windows: com.apple.finder", tolerance: 1, rows: 0, unobservedApps: [])
        let named = CLI.resultText(result, name: { $0 == "com.apple.finder" ? "Finder" : $0 })
        XCTAssertTrue(named.contains("Finder"))
        XCTAssertFalse(named.contains("com.apple.finder"))
        XCTAssertFalse(named.contains("Requests"))
        XCTAssertFalse(named.contains("arrange"))
        XCTAssertTrue(named.hasPrefix("Partially Applied"))
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: [], spaceObservationAvailable: true, unobservedApps: ["com.apple.finder"])
        let listed = CLI.windowsText(Inspection(snapshot: snap, targets: [], excluded: [], takenAt: now), name: { $0 == "com.apple.finder" ? "Finder" : $0 })
        XCTAssertTrue(listed.contains("Finder"))
        XCTAssertFalse(listed.contains("com.apple.finder"))
        func row(_ label: String) -> String { CLI.padded(label + ":", to: 24) }
        var status = sampleStatus()
        let leftover = OperationResult.note(
            kind: "arrange", spaceID: 1, message: "5 of 7 windows did not end up as requested.", ok: false,
            at: Date().addingTimeInterval(-3 * 60 * 60))
        status.lastResult = leftover
        let leftoverText = CLI.statusText(status)
        XCTAssertTrue(leftoverText.contains(row("Status") + "Manual Arrangement Only\n"))
        XCTAssertFalse(leftoverText.contains(row("Status") + "Manual Arrangement Only —"))
        XCTAssertFalse(leftoverText.contains("Latest operation"))
        XCTAssertFalse(leftoverText.contains("5 of 7"))
        XCTAssertFalse(leftoverText.contains("Requests"))
        status.lastResult = OperationResult.note(kind: "arrange", spaceID: 1, message: "Arranged 2 windows.", ok: true)
        let recent = CLI.statusText(status)
        XCTAssertTrue(recent.contains(row("Latest operation") + "Completed"))
        XCTAssertTrue(recent.contains("Arranged 2 windows."))
        XCTAssertFalse(recent.contains("Requests"))
        let spaceSwitch = OperationResult.note(kind: "space", spaceID: 1, message: "Switched to Space 1", ok: true)
        XCTAssertFalse(StatusMenuCopy.showsRecent(result: spaceSwitch, managed: false))
        XCTAssertFalse(StatusMenuCopy.showsRecent(result: spaceSwitch, managed: true))
        status.lastResult = spaceSwitch
        let spaceText = CLI.statusText(status)
        XCTAssertFalse(spaceText.contains("Latest operation"))
        XCTAssertFalse(spaceText.contains("Switched to Space 1"))
        status.lastResult = nil
        status.autoAvailable = true
        let availableOnly = CLI.statusText(status)
        XCTAssertTrue(availableOnly.contains(row("Automatic arrangement") + "Available\n"))
        XCTAssertFalse(availableOnly.contains("Check passed"))
        XCTAssertFalse(availableOnly.lowercased().contains("verified"))
        XCTAssertFalse(CLI.statusText(status).contains("Check passed"))
    }

    func testEverydayListsHideDebugTerms() {
        func window(_ kind: ObservedWindow.Kind, membership: ObservedWindow.Membership = .current, detail: String = "AXWindow/AXStandardWindow layer=0") -> ObservedWindow {
            ObservedWindow(id: WindowID(1), pid: 1, app: "com.apple.finder", frame: .zero, membership: membership, kind: kind, detail: detail)
        }
        XCTAssertEqual(TargetSelection.exclusionReason(window(.unknownRole)), "Window type can't be determined")
        XCTAssertFalse(TargetSelection.exclusionReason(window(.unknownRole))!.contains("AX"))
        XCTAssertFalse(TargetSelection.exclusionReason(window(.unknownRole))!.contains("layer"))
        XCTAssertEqual(TargetSelection.exclusionReason(window(.standard, membership: .unknown)), "Space can't be determined")
        XCTAssertEqual(TargetSelection.exclusionReason(window(.standard, membership: .other)), "On another Space")
        XCTAssertEqual(TargetSelection.exclusionReason(window(.standard, membership: .allSpaces)), "Appears on all Spaces")
        XCTAssertEqual(TargetSelection.exclusionReason(window(.nonNormalLayer)), "Not a standard window")
        XCTAssertNil(TargetSelection.exclusionReason(window(.standard, detail: "")))

        let now = Date()
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: [], spaceObservationAvailable: true)
        let listed = CLI.windowsText(Inspection(snapshot: snap, targets: [], excluded: [], takenAt: now))
        XCTAssertTrue(listed.contains("Eligibility"))
        XCTAssertFalse(listed.contains("Verdict"))

        let overview = SpaceOverview(spaces: [
            .init(spaceID: 1, type: 0, isCurrent: true, windowIDs: []),
            .init(spaceID: 117, type: 4, isCurrent: false, windowIDs: []),
            .init(spaceID: 9, type: 2, isCurrent: false, windowIDs: []),
        ], unknown: [])
        let spaces = CLI.spacesText(overview)
        XCTAssertTrue(spaces.contains("Standard"))
        XCTAssertTrue(spaces.contains("Full Screen"))
        XCTAssertTrue(spaces.contains("Other"))
        XCTAssertFalse(spaces.contains("user"))
        XCTAssertFalse(spaces.contains("full"))
        XCTAssertEqual(CLI.spaceKindLabel(nil), "Other")
        let rows = spaces.split(separator: "\n")
        func countColumn(_ line: Substring) -> Int {
            let text = String(line)
            guard let range = text.range(of: #"\d+$"#, options: .regularExpression) else { return -1 }
            return CLI.displayWidth(String(text[..<range.lowerBound]))
        }
        let normal = try? XCTUnwrap(rows.first { $0.contains("Standard") })
        let full = try? XCTUnwrap(rows.first { $0.contains("Full Screen") })
        if let normal, let full {
            XCTAssertGreaterThan(countColumn(normal), 0)
            XCTAssertTrue(full.hasSuffix("—"), "Full screen has no ordinary window count")
        }

        func window(_ id: UInt32, _ app: String) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: app, frame: CGRect(x: 0, y: 0, width: 100, height: 100), membership: .current, kind: .standard, detail: "")
        }
        let named = CLI.windowsText(Inspection(snapshot: snap, targets: [
            window(1, "com.apple.finder"),
            window(2, "com.apple.Passwords"),
        ], excluded: [], takenAt: now), name: { $0 == "com.apple.finder" ? "Finder" : "パスワード" })
        let sized = named.split(separator: "\n").filter { $0.contains("100×100") }
        func sizeColumn(_ line: Substring) -> Int {
            let text = String(line)
            guard let at = text.range(of: "100×100") else { return -1 }
            return CLI.displayWidth(String(text[..<at.lowerBound]))
        }
        XCTAssertEqual(sized.count, 2)
        if sized.count == 2 { XCTAssertEqual(sizeColumn(sized[0]), sizeColumn(sized[1])) }
        XCTAssertEqual(CLI.displayWidth("パスワード"), 10)
        XCTAssertEqual(CLI.padded("フルスクリーン", to: 14), "フルスクリーン")
    }

    func testSpaceOverviewCopy() {
        XCTAssertEqual(StatusMenuCopy.appList(["Finder", "Safari"]), "Finder, Safari")
        let many = ["Activity Monitor", "Calendar", "Finder", "Google Chrome", "Safari", "Xcode"]
        let trimmed = StatusMenuCopy.appList(many)
        XCTAssertTrue(trimmed.hasPrefix("Activity Monitor, Calendar"))
        XCTAssertTrue(trimmed.hasSuffix(" more"))
        XCTAssertLessThanOrEqual(CLI.displayWidth(trimmed), StatusMenuCopy.appListWidth + " +9 more".count)
        XCTAssertEqual(StatusMenuCopy.appList(["A Very Long Application Name That Exceeds The Width"]), "A Very Long Application Name That Exceeds The Width")
        XCTAssertEqual(StatusMenuCopy.spaceContents([], fullScreen: false), "—")
        XCTAssertEqual(StatusMenuCopy.spaceContents(["Keynote"], fullScreen: true), "Keynote (Full Screen)")

        func app(_ name: String, _ pid: Int32) -> SpaceOverview.App { .init(name: name, bundleID: nil, pid: pid) }
        let entry = SpaceMenuEntry(index: 2, id: 22, isCurrent: false, windows: 3, apps: [app("Finder", 1), app("Safari", 2)], fullScreen: false)
        XCTAssertNil(StatusMenuCopy.spaceToolTip(entry))
        var crowded = entry
        crowded.apps = many.enumerated().map { app($0.element, Int32($0.offset)) }
        XCTAssertEqual(StatusMenuCopy.spaceToolTip(crowded), many.joined(separator: ", "))

        XCTAssertEqual(StatusMenuCopy.barTitle(mode: "main", space: "3"), "3")
        XCTAssertEqual(StatusMenuCopy.barTitle(mode: "service", space: "3"), "3 · service")
        XCTAssertEqual(StatusMenuCopy.barTitle(mode: "service", space: nil), "service")
        XCTAssertEqual(StatusMenuCopy.barTitle(mode: "main", space: nil), "")

        let overview = SpaceOverview(spaces: [
            .init(spaceID: 11, type: 0, isCurrent: true, windowIDs: [WindowID(1)], apps: [app("Finder", 1)]),
            .init(spaceID: 12, type: 4, isCurrent: false, windowIDs: [WindowID(2)], apps: [app("Keynote", 2)]),
        ], unknown: [], reordersByRecentUse: true)
        let menu = Coordinator.spaceMenu(list: [item(1, 11, true), item(nil, 12, false), item(2, 13, false)], overview: overview)
        XCTAssertTrue(menu.reordersByRecentUse)
        XCTAssertEqual(menu.entries.map(\.apps?.first?.name), ["Finder", "Keynote", nil])
        XCTAssertEqual(menu.entries.map(\.fullScreen), [false, true, false])
        XCTAssertNil(menu.entries[2].apps, "An unread Space is not reported as empty")
        XCTAssertEqual(Coordinator.spaceMenu(list: [item(1, 11, true)], overview: nil).entries.first?.apps, nil)
    }

    func testSpaceOverviewOrdersAppsInReadingOrder() {
        func app(_ name: String, _ pid: Int32) -> SpaceOverview.App { .init(name: name, bundleID: nil, pid: pid) }
        func names(_ windows: [(app: SpaceOverview.App, bounds: CGRect)]) -> [String] { SpaceOverview.ordered(windows.map { ($0.app, $0.bounds, true) }).map(\.name) }
        let tl = app("Editor", 1), tr = app("Chat", 2), bl = app("Devices", 3), br = app("Browser", 4)

        // A 2x2 grid reads top-left, top-right, bottom-left, bottom-right, regardless of input order.
        let grid = [(br, CGRect(x: 960, y: 545, width: 950, height: 500)), (tl, CGRect(x: 10, y: 35, width: 940, height: 500)),
                    (bl, CGRect(x: 10, y: 545, width: 940, height: 500)), (tr, CGRect(x: 960, y: 35, width: 950, height: 500))]
        XCTAssertEqual(names(grid), ["Editor", "Chat", "Devices", "Browser"])
        XCTAssertEqual(names(grid.reversed()), ["Editor", "Chat", "Devices", "Browser"])

        // Top edges within the tolerance share a row, read left to right even if the right window is slightly higher.
        XCTAssertEqual(names([(tl, CGRect(x: 10, y: 38, width: 940, height: 500)), (tr, CGRect(x: 960, y: 35, width: 950, height: 500)),
                              (bl, CGRect(x: 10, y: 545, width: 940, height: 500)), (br, CGRect(x: 960, y: 545 + SpaceOverview.rowTolerance, width: 950, height: 480))]),
                       ["Editor", "Chat", "Devices", "Browser"])
        // Rows split on the difference from the previous top, so a staircase of steps within tolerance chains into one row, read left to right (an accepted trade-off).
        XCTAssertEqual(names([(tl, CGRect(x: 900, y: 0, width: 100, height: 100)), (tr, CGRect(x: 600, y: 15, width: 100, height: 100)),
                              (bl, CGRect(x: 300, y: 30, width: 100, height: 100)), (br, CGRect(x: 0, y: 45, width: 100, height: 100))]),
                       ["Browser", "Devices", "Chat", "Editor"])
        // A difference beyond the tolerance starts a new row.
        XCTAssertEqual(names([(tl, CGRect(x: 900, y: 0, width: 100, height: 100)), (tr, CGRect(x: 0, y: 21, width: 100, height: 100))]),
                       ["Editor", "Chat"])

        // Another window floating slightly higher does not split or swap the tiles of a row, even when moved by 1 pt.
        let left = app("Left", 5), right = app("Right", 6), float = app("Float", 7)
        for y: CGFloat in [34, 35] {
            XCTAssertEqual(names([(left, CGRect(x: 0, y: 55, width: 790, height: 500)), (right, CGRect(x: 800, y: 54, width: 790, height: 500)),
                                  (float, CGRect(x: 400, y: y, width: 300, height: 200))]),
                           ["Left", "Float", "Right"])
        }
        // Beyond the tolerance the floating window gets its own row, but the tiles keep their left-right order.
        XCTAssertEqual(names([(left, CGRect(x: 0, y: 55, width: 790, height: 500)), (right, CGRect(x: 800, y: 54, width: 790, height: 500)),
                              (float, CGRect(x: 400, y: 33, width: 300, height: 200))]),
                       ["Float", "Left", "Right"])

        // Left column split top and bottom, right at full height -> top-left, right, bottom-left.
        XCTAssertEqual(names([(bl, CGRect(x: 10, y: 545, width: 940, height: 500)), (tr, CGRect(x: 960, y: 35, width: 950, height: 1010)),
                              (tl, CGRect(x: 10, y: 35, width: 940, height: 500))]),
                       ["Editor", "Chat", "Devices"])

        // An app with several windows appears once, at the position of its earliest window.
        XCTAssertEqual(names([(tl, CGRect(x: 10, y: 545, width: 940, height: 500)), (tr, CGRect(x: 960, y: 35, width: 950, height: 500)),
                              (tl, CGRect(x: 10, y: 35, width: 940, height: 500)), (tr, CGRect(x: 960, y: 545, width: 950, height: 500))]),
                       ["Editor", "Chat"])

        // Same position: by name (the Finder comparison), then pid.
        let same = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(SpaceOverview.ordered([(app("safari", 3), same, true), (app("Finder", 2), same, true), (app("Finder", 1), same, true)]).map(\.pid), [1, 2, 3])

        // Invisible windows (hidden apps, minimized) do not count for position; ordering uses visible windows even if an invisible one is top-left.
        XCTAssertEqual(SpaceOverview.ordered([(tl, CGRect(x: 0, y: 0, width: 800, height: 600), false), (tr, CGRect(x: 960, y: 35, width: 950, height: 500), true),
                                              (tl, CGRect(x: 10, y: 545, width: 940, height: 500), true)]).map(\.name),
                       ["Chat", "Editor"])
        // Apps with only invisible windows come last by name, then pid. Their windows still count, so the app stays.
        XCTAssertEqual(SpaceOverview.ordered([(app("Zed", 8), CGRect(x: 0, y: 0, width: 800, height: 600), false), (br, CGRect(x: 960, y: 545, width: 950, height: 500), true),
                                              (app("Mail", 10), CGRect(x: 0, y: 0, width: 800, height: 600), false), (app("Mail", 9), CGRect(x: 5, y: 5, width: 800, height: 600), false)]).map(\.pid),
                       [4, 9, 10, 8])
        XCTAssertEqual(SpaceOverview.ordered([(tr, CGRect(x: 0, y: 0, width: 800, height: 600), false), (tl, CGRect(x: 900, y: 0, width: 800, height: 600), false),
                                              (tr, CGRect(x: 0, y: 700, width: 800, height: 600), false)]).map(\.name),
                       ["Chat", "Editor"])

        // Windows not used for position are not used for row splitting either, so one in between does not chain tile rows.
        XCTAssertEqual(SpaceOverview.ordered([(tr, CGRect(x: 900, y: 0, width: 800, height: 600), true), (tl, CGRect(x: 0, y: 20, width: 800, height: 600), false),
                                              (bl, CGRect(x: 0, y: 40, width: 800, height: 600), true)]).map(\.name),
                       ["Chat", "Devices", "Editor"])

        XCTAssertEqual(SpaceOverview.ordered([]), [])
    }

    func testSpaceOverviewRanksOnlyVisibleWindows() {
        func rankable(hidden: Bool = false, alpha: Double = 1, onScreen: Bool, space: UInt64 = 2, visible: Set<UInt64> = [1, 2]) -> Bool {
            SpaceOverview.rankable(appHidden: hidden, alpha: alpha, onScreen: onScreen, space: space, visibleSpaces: visible)
        }
        XCTAssertFalse(rankable(hidden: true, onScreen: true))
        XCTAssertFalse(rankable(alpha: 0, onScreen: true))
        // Space 2 is shown on the second display. Windows not on screen (minimized, for example) are not used.
        XCTAssertFalse(rankable(onScreen: false))
        XCTAssertTrue(rankable(onScreen: true))
        // Windows of a Space not shown are usually not on screen.
        XCTAssertTrue(rankable(onScreen: false, space: 3))
        // When the shown Spaces are unknown, order by position.
        XCTAssertTrue(rankable(onScreen: false, visible: []))
    }

    func testSpaceOverviewCopyInJapanese() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        XCTAssertEqual(StatusMenuCopy.spaceContents([], fullScreen: false), "—")
        XCTAssertEqual(StatusMenuCopy.spaceContents(["Keynote"], fullScreen: true), "Keynote（フルスクリーン）")
        XCTAssertTrue(StatusMenuCopy.appList(["アクティビティモニタ", "カレンダー", "ファインダー", "メール", "メッセージ"]).contains("ほか"))
    }

    func testEverydayListsHideDebugTermsInJapanese() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        let unknown = ObservedWindow(id: WindowID(1), pid: 1, app: "com.apple.finder", frame: .zero, membership: .current, kind: .unknownRole, detail: "AXWindow/AXStandardWindow layer=0")
        let reason = TargetSelection.exclusionReason(unknown)
        XCTAssertEqual(reason, "ウインドウの種類を判定できない")
        XCTAssertFalse(reason?.contains("AX") ?? true)
        XCTAssertFalse(reason?.contains("窓") ?? true)
        let overview = SpaceOverview(spaces: [
            .init(spaceID: 1, type: 0, isCurrent: true, windowIDs: []),
            .init(spaceID: 117, type: 4, isCurrent: false, windowIDs: []),
        ], unknown: [])
        let spaces = CLI.spacesText(overview)
        XCTAssertTrue(spaces.contains("通常"))
        XCTAssertTrue(spaces.contains("ウインドウ数"), "the last header is not cut")
        XCTAssertTrue(spaces.contains("フルスクリーン"))
        XCTAssertFalse(spaces.contains("Standard"))
    }

    func testMenuTopEntriesInJapanese() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        var status = sampleStatus(availability: .automatic, autoAvailable: true)
        status.waiting = [WindowID(1), WindowID(2)]
        let entries = StatusMenuCopy.topEntries(status: status, spaceCount: 1, modeCount: 1)
        XCTAssertEqual(entries.map(\.kind), [.edit, .spacePause, .arrange, .integrate, .globalPause, .settings, .status, .quit])
        let titles = Dictionary(entries.map { ($0.kind, $0.title) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(titles[.status], "ウインドウを確認…")
        XCTAssertEqual(titles[.arrange], "今すぐ整列")
        XCTAssertEqual(titles[.integrate], "待機中のウインドウを1つ追加（2つ待機中）")
        XCTAssertEqual(titles[.spacePause], "この操作スペースを自動整列")
        XCTAssertEqual(titles[.globalPause], "LazySpaceを一時停止")
        XCTAssertEqual(titles[.settings], "設定…")
        XCTAssertEqual(titles[.quit], "LazySpaceを終了")
        for entry in entries {
            XCTAssertFalse(entry.title.contains("窓"), entry.title)
            let withoutNames = entry.title.replacingOccurrences(of: "LazySpace", with: "").replacingOccurrences(of: "Space", with: "")
            XCTAssertNil(withoutNames.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression), entry.title)
        }
    }

    func testCLIStatusTextInJapanese() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        var status = sampleStatus(availability: .automatic, autoAvailable: true)
        status.zoomed = WindowID(4094)
        let text = CLI.statusText(status)
        XCTAssertTrue(text.contains(CLI.padded("状態:", to: 24) + "自動整列を利用可能（この操作スペースは未開始）"))
        XCTAssertTrue(text.contains(CLI.padded("この操作スペース:", to: 24) + "開始待ち"))
        XCTAssertTrue(text.contains(CLI.padded("自動整列:", to: 24) + "利用可能\n"))
        status.desktopShortcuts = "使用中: デスクトップ1"
        XCTAssertTrue(CLI.statusText(status).contains("\nデスクトップのショートカット: 使用中: デスクトップ1"), "a label wider than the column is not cut")
        XCTAssertFalse(text.contains("確認済み"))
        XCTAssertTrue(text.contains("ズーム中"))
        XCTAssertFalse(text.contains("4094"))
        XCTAssertFalse(text.contains("Automatic"))
        XCTAssertTrue(CLI.usage.hasPrefix("使い方: lazyspace"))
        XCTAssertTrue(CLI.usage.contains("待機中のウインドウを1つレイアウトに追加"))
    }

    func testNoticesInJapanese() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        XCTAssertEqual(StatusMenuCopy.resumeNotice(), "LazySpaceを再開しました。")
        XCTAssertEqual(StatusMenuCopy.pauseNotice(), "LazySpaceを一時停止しました。")
        XCTAssertEqual(StatusMenuCopy.notStartedMessage(arrangeKey: "⌥A"),
                       "この操作スペースはまだ整列していません。⌥A（またはメニュー「今すぐ整列」）で始めてください。")
    }
}

private func sampleStatus(
    availability: AppStatus.Availability = .manualOnly,
    autoAvailable: Bool = false
) -> AppStatus {
    AppStatus(
        availability: availability, availabilityReason: "Manual arrangement only. Automatic arrangement has not been checked.", manualAvailable: true, manualReason: "Available",
        autoAvailable: autoAvailable, autoReason: autoAvailable ? "Available" : "Not checked", currentSpaceManaged: false, trusted: true,
        spaceObservation: true, inputObservation: "none", paused: false, progress: .idle, progressText: "",
        waiting: [], floating: [], zoomed: nil, lastRefusal: nil,
        configPath: "/tmp/config.toml", configError: nil, focusedWindow: nil, lastResult: nil, version: "0.4.0",
        mode: "main", modes: ["main"], loginItem: "Off", loginItemEnabled: false)
}

private func item(_ index: Int?, _ id: UInt64, _ current: Bool) -> SpaceListItem {
    SpaceListItem(index: index, id: id, isCurrent: current, isShown: current)
}
