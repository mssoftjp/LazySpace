import XCTest
import CoreGraphics
import Copy
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

private final class MixedSpaceListing: SpaceListing {
    var order: [(id: UInt64, type: Int32?)] = [(7, 0), (70, 4), (8, 0), (80, 4), (9, 0)]
    var uuids: [UInt64: String] = [7: "U7", 70: "UF1", 8: "U8", 80: "UF2", 9: "U9"]
    var active: UInt64 = 7
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order }
    func neighbor(offset: Int) -> UInt64? {
        guard let i = order.firstIndex(where: { $0.id == active }), order.indices.contains(i + offset) else { return nil }
        return order[i + offset].id
    }
    func currentDisplayUUIDs() -> [UInt64: String]? { uuids }
    func spaceSnapshot() -> SpaceSnapshot? {
        let numbers = SpaceObserver.desktopNumbers(order)
        return SpaceSnapshot(order: order.map(\.id), desktops: order.compactMap { numbers[$0.id] == nil ? nil : $0.id },
                             uuids: uuids, display: "Main", active: active)
    }
}

final class DesktopSpaceTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var listing: MixedSpaceListing!
    private var destinations: [UInt64] = []
    private var reorders = false

    override func setUp() {
        Copy.language = .english
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 70, 8, 80, 9]
        listing = MixedSpaceListing()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { [unowned self, listing] in
            SpaceOverview(spaces: listing!.order.map { .init(spaceID: $0.id, type: $0.type, isCurrent: $0.id == listing!.active, windowIDs: [], apps: []) },
                          unknown: [], reordersByRecentUse: reorders)
        }, takeInventory: { nil })
        coordinator.spaceListingOverride = listing
        coordinator.spaceSwitcherOverride = { [unowned self] dest, _, _ in
            destinations.append(dest)
            let from = system.space ?? 0
            system.space = dest
            listing.active = dest
            return .success(SpaceControl.Result(fromSpace: from, toSpace: dest, steps: 0, wallMs: 1))
        }
    }

    private func drain() {
        let done = expectation(description: "operation finished")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    override func tearDown() {
        drain()
        try? FileManager.default.removeItem(at: root)
        Copy.language = .english
    }

    private func switchTo(_ target: SpaceTarget) {
        guard case .started = coordinator.edit(.space(target), source: "test") else { return XCTFail("not accepted: \(target)") }
        drain()
    }

    func testNumbersExcludeFullScreenAndStayStableOnEnterExit() {
        XCTAssertEqual(SpaceObserver.desktopNumbers(listing.order), [7: 1, 8: 2, 9: 3])
        XCTAssertEqual(coordinator.spaceList().map(\.index), [1, nil, 2, nil, 3])
        listing.order.removeAll { $0.type == 4 }
        XCTAssertEqual(SpaceObserver.desktopNumbers(listing.order), [7: 1, 8: 2, 9: 3])
        XCTAssertEqual(coordinator.spaceList().map(\.index), [1, 2, 3])
    }

    func testIncompleteOrDuplicateInventoryHasNoNumbers() {
        listing.order[1].type = nil
        XCTAssertTrue(SpaceObserver.desktopNumbers(listing.order).isEmpty)
        if case .started = coordinator.edit(.space(.index(2)), source: "test") { XCTFail("guessed a desktop number") }
        listing.order = [(7, 0), (7, 0)]
        XCTAssertTrue(SpaceObserver.desktopNumbers(listing.order).isEmpty)
    }

    func testNumberedSwitchSelectsDesktopBeyondFullScreen() {
        switchTo(.index(2))
        XCTAssertEqual(destinations, [8])
        XCTAssertEqual(coordinator.spaceList().first(where: \.isCurrent)?.index, 2)
    }

    func testRelativeSwitchAndBackIncludeNativeFullScreenSpace() {
        switchTo(.next)
        XCTAssertEqual(destinations, [70])
        XCTAssertNil(coordinator.spaceList().first(where: \.isCurrent)?.index)
        switchTo(.next)
        XCTAssertEqual(destinations, [70, 8])
        switchTo(.back)
        XCTAssertEqual(destinations, [70, 8, 70])
        switchTo(.prev)
        XCTAssertEqual(destinations.last, 7)
    }

    func testMenuTargetKeepsObservedIDWhenOrderChanges() {
        listing.order = [(9, 0), (7, 0), (70, 4), (8, 0)]
        switchTo(.id(8))
        XCTAssertEqual(destinations, [8])
    }

    func testRemovedFullScreenMenuTargetDoesNotGoToReplacement() {
        listing.order.removeAll { $0.id == 70 }
        guard case .refused = coordinator.edit(.space(.id(70)), source: "test") else { return XCTFail("accepted a removed full-screen Space") }
        XCTAssertTrue(destinations.isEmpty)
    }

    func testDestinationUUIDIsRevalidatedBeforeSwitch() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.operationsQueue.async { gate.wait() }
        guard case .started = coordinator.edit(.space(.index(2)), source: "test") else { gate.signal(); return XCTFail("not accepted") }
        listing.uuids[8] = "replacement"
        gate.signal()
        drain()
        XCTAssertTrue(destinations.isEmpty)
        XCTAssertEqual(coordinator.lastResult?.outcome, .notPossible)
    }

    func testWindowSendSkipsInterveningFullScreenSpaces() {
        var sent: [UInt64] = []
        coordinator.spaceSenderOverride = { _, destination, _ in
            sent.append(destination)
            return .notIssued(.noSuchSpace)
        }
        guard case .started = coordinator.edit(.sendToSpace(.next), source: "test") else { return XCTFail("not accepted") }
        drain()
        XCTAssertEqual(sent, [8])
        XCTAssertTrue(destinations.isEmpty)
    }

    func testOverviewExcludesOrderedOutHelpersButKeepsOffSpaceWindows() {
        // The same app may own both a full-screen window and a real ordinary
        // window. Decide per window, without filtering the app or using onScreen.
        XCTAssertFalse(SpaceOverview.includesWindow(appHidden: false, alpha: 1, orderedIn: false))
        XCTAssertTrue(SpaceOverview.includesWindow(appHidden: false, alpha: 1, orderedIn: true))
        XCTAssertTrue(SpaceOverview.includesWindow(appHidden: false, alpha: 1, orderedIn: nil))
        XCTAssertFalse(SpaceOverview.includesWindow(appHidden: true, alpha: 1, orderedIn: true))
        XCTAssertFalse(SpaceOverview.includesWindow(appHidden: false, alpha: 0, orderedIn: true))
    }

    func testNativeFullScreenSpaceExcludesSplitViewAndTransitionWindowsFromTiling() {
        for axFullscreen in [false, true] {
            XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: axFullscreen,
                            layer: 0, role: "AXWindow", subrole: "AXStandardWindow", dialogHasZoomButton: false,
                            onFullscreenSpace: true), .fullscreen)
        }
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false,
                        layer: 0, role: "AXWindow", subrole: "AXStandardWindow", dialogHasZoomButton: false,
                        onFullscreenSpace: false), .standard)
    }

    func testFullscreenMenuDoesNotOfferDesktopArrangementOrWindowSend() {
        system.space = 70
        listing.active = 70
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains(StatusMenuCopy.automaticSpaceTitle))
        XCTAssertFalse(titles.contains("Arrange Now"))
        XCTAssertFalse(titles.contains("Move Window to Space"))
        XCTAssertFalse(titles.contains { $0.contains("Rename") })
        XCTAssertTrue(titles.contains { $0.contains("Full Screen") })
    }

    func testMenuFullScreenRowHasNoNumberOrWindowCount() {
        let app = SpaceOverview.App(name: "Photos", bundleID: "com.apple.Photos", pid: 1)
        let overview = SpaceOverview(spaces: [
            .init(spaceID: 7, type: 0, isCurrent: false, windowIDs: []),
            .init(spaceID: 70, type: 4, isCurrent: true, windowIDs: [WindowID(10), WindowID(11)], apps: [app]),
            .init(spaceID: 8, type: 0, isCurrent: false, windowIDs: [], apps: []),
        ], unknown: [])
        let entries = Coordinator.spaceMenu(list: [item(1, 7, false), item(nil, 70, true), item(2, 8, false)], overview: overview).entries
        XCTAssertEqual(entries.map(\.index), [1, nil, 2])
        XCTAssertNil(entries[1].windows)
        let item = SpaceOverviewMenu.item(entries[1], action: #selector(NSObject.description), target: NSObject())
        // Row icons are attachments (U+FFFC) inside the string, so compare without them.
        XCTAssertEqual(item.title.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces), "Photos (Full Screen)")
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(item.keyEquivalent, "")
        let text = CLI.spacesText(overview)
        XCTAssertTrue(text.contains("2. 8"), text)
        XCTAssertFalse(text.contains("2. 70"), text)
        XCTAssertFalse(text.contains("3. 8"), text)
    }

    private func overview(reorders: Bool, _ spaces: [(id: UInt64, type: Int32?, display: String?)]) -> SpaceOverview {
        SpaceOverview(spaces: spaces.map { .init(spaceID: $0.id, type: $0.type, isCurrent: false, windowIDs: [], display: $0.display) },
                      unknown: [], reordersByRecentUse: reorders)
    }

    /// Rearranging can change a number only when one display has two standard desktops to swap.
    func testDesktopNumbersCanChangeOnlyWithTwoDesktopsOnOneDisplay() {
        XCTAssertFalse(overview(reorders: false, [(1, 0, "A"), (2, 0, "A")]).desktopNumbersCanChange, "the setting is off")
        XCTAssertFalse(overview(reorders: true, []).desktopNumbersCanChange)
        XCTAssertFalse(overview(reorders: true, [(1, 0, "A")]).desktopNumbersCanChange, "one desktop")
        XCTAssertFalse(overview(reorders: true, [(1, 0, "A"), (2, 4, "A")]).desktopNumbersCanChange, "full screen has no number")
        XCTAssertFalse(overview(reorders: true, [(1, 0, "A"), (2, nil, "A")]).desktopNumbersCanChange, "an unknown type has no number")
        XCTAssertFalse(overview(reorders: true, [(1, 0, "A"), (2, 0, "B")]).desktopNumbersCanChange, "each display counts its own")
        XCTAssertTrue(overview(reorders: true, [(1, 0, "A"), (2, 0, "A")]).desktopNumbersCanChange)
        XCTAssertTrue(overview(reorders: true, [(1, 0, "A"), (2, 0, "B"), (3, 0, "B")]).desktopNumbersCanChange, "one of the displays is enough")
        XCTAssertTrue(overview(reorders: true, [(1, 0, nil), (2, 0, nil)]).desktopNumbersCanChange, "an unread display is still one group")
    }

    /// The row under the list says what is happening and opens the setting. It stays away when numbers cannot change.
    func testMenuOffersTheSettingOnlyWhileNumbersCanChange() throws {
        func menu() -> NSMenu {
            let menu = NSMenu()
            AppDelegate(showReadyAtLaunch: false, coordinator: coordinator).menuNeedsUpdate(menu)
            return menu
        }
        let title = "Keep Desktop Numbers Fixed…"
        XCTAssertFalse(menu().items.contains { $0.title == title }, "the setting is off")

        reorders = true
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let shown = NSMenu()
        delegate.menuNeedsUpdate(shown)
        let row = try XCTUnwrap(shown.items.first { $0.title == title })
        XCTAssertEqual(row.subtitle, "Desktop numbers follow recent use.")
        XCTAssertTrue(row.isEnabled)
        XCTAssertNotNil(row.action)
        XCTAssertTrue(row.target === delegate)
        XCTAssertEqual(row.keyEquivalent, "")
        XCTAssertNil(row.image, "no warning icon: someone may keep the setting on")
        let position = shown.index(of: row)
        XCTAssertNotNil(shown.items[position - 1].representedObject as? EditCommandBox, "right under the Space list")
        XCTAssertTrue(shown.items[position + 1].isSeparatorItem)

        // The list still shows one desktop and a full-screen Space, but no number can change.
        listing.order = [(7, 0), (70, 4)]
        let single = menu()
        XCTAssertTrue(single.items.contains { ($0.representedObject as? EditCommandBox)?.command == .space(.id(70)) }, "the list is shown")
        XCTAssertFalse(single.items.contains { $0.title == title })
    }

    /// Two lines at most, and no wider than the one-line note it replaced, in every language.
    func testKeepNumbersFixedRowStaysSmallInEveryLanguage() {
        func size(_ item: NSMenuItem) -> NSSize {
            let menu = NSMenu()
            menu.addItem(item)
            return menu.size
        }
        let oneLine = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        oneLine.subtitle = "x"
        for language in Language.allCases {
            Copy.language = language
            let row = SpaceOverviewMenu.keepNumbersFixedItem(action: #selector(NSObject.description), target: NSObject())
            XCTAssertFalse(row.title.isEmpty, language.rawValue)
            XCTAssertFalse(row.subtitle?.isEmpty ?? true, language.rawValue)
            XCTAssertLessThanOrEqual(size(row).width, 350, language.rawValue)
            XCTAssertEqual(size(row).height, size(oneLine.copy() as! NSMenuItem).height, "\(language.rawValue): the subtitle stays on one line")
        }
    }

    func testRearrangingSettingsOpenAtMissionControl() throws {
        XCTAssertEqual(SpaceOverview.rearrangingSettingsURL.absoluteString, "x-apple.systempreferences:com.apple.Desktop-Settings.extension?MissionControl")
        let pane = "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex"
        guard let bundle = Bundle(path: pane) else { throw XCTSkip("no \(pane) on this macOS") }
        XCTAssertEqual(bundle.bundleIdentifier, "com.apple.Desktop-Settings.extension", "the pane's identifier in the URL")
    }

    /// `list-spaces` states the fact and the way to fix the numbers, without telling anyone what they should prefer.
    func testListSpacesNamesTheSettingOnlyWhileNumbersCanChange() {
        let name = "Automatically rearrange Spaces based on most recent use"
        let text = CLI.spacesText(overview(reorders: true, [(1, 0, nil), (2, 0, nil)]))
        XCTAssertTrue(text.contains(name), text)
        XCTAssertTrue(text.contains("System Settings › Desktop & Dock"), text)
        XCTAssertFalse(text.lowercased().contains("recommend"), text)
        XCTAssertFalse(CLI.spacesText(overview(reorders: true, [(1, 0, nil)])).contains(name))
        XCTAssertFalse(CLI.spacesText(overview(reorders: true, [(1, 0, nil), (2, 4, nil)])).contains(name))
        XCTAssertFalse(CLI.spacesText(overview(reorders: false, [(1, 0, nil), (2, 0, nil)])).contains(name))
    }

    /// A Space menu row is number, app icons, then app names. Icons sit between the number and the names, not as the row image.
    func testSpaceMenuRowShowsNumberThenIconsThenNames() throws {
        let app = SpaceOverview.App(name: "Terminal", bundleID: "com.example.terminal", pid: ProcessInfo.processInfo.processIdentifier)
        let entry = SpaceMenuEntry(index: 3, id: 30, isCurrent: true, windows: 1, apps: [app], fullScreen: false)
        let item = SpaceOverviewMenu.item(entry, action: #selector(NSObject.description), target: NSObject())
        XCTAssertNil(item.image, "no leading image before the number")
        let title = try XCTUnwrap(item.attributedTitle)
        let string = title.string
        XCTAssertTrue(string.hasPrefix("3"), string)
        var attachmentAt: Int?
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, range, _ in
            if value != nil, attachmentAt == nil { attachmentAt = range.location }
        }
        let iconPosition = try XCTUnwrap(attachmentAt, "the icons are part of the title")
        let namePosition = (string as NSString).range(of: "Terminal").location
        XCTAssertGreaterThan(iconPosition, 0, "icons come after the number")
        XCTAssertLessThan(iconPosition, namePosition, "icons come before the app names")
        // An empty Space reserves the same width so names line up.
        let empty = SpaceOverviewMenu.item(SpaceMenuEntry(index: 1, id: 10, isCurrent: false, windows: 0, apps: [], fullScreen: false),
                                           action: #selector(NSObject.description), target: NSObject())
        XCTAssertNil(empty.image)
        XCTAssertTrue(empty.attributedTitle!.string.hasSuffix("\t—"))
        var emptyHasAttachment = false
        empty.attributedTitle!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: empty.attributedTitle!.length)) { value, _, _ in
            if value != nil { emptyHasAttachment = true }
        }
        XCTAssertTrue(emptyHasAttachment)
    }
}

private func item(_ index: Int?, _ id: UInt64, _ current: Bool) -> SpaceListItem {
    SpaceListItem(index: index, id: id, isCurrent: current, isShown: current)
}
