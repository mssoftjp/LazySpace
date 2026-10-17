import XCTest
import CoreGraphics
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpace

/// Two displays with their own Spaces: "Built-in" (D1: 7, 8; showing 7) on the left and "LG" (D2: 20, 21; showing 20) on the right.
private final class TwoDisplays: SpaceListing {
    var groups: [DisplayGroup]
    var active: () -> UInt64?
    init(active: @escaping () -> UInt64?) {
        self.active = active
        groups = [
            DisplayGroup(display: "D1", name: "Built-in", index: 1, records: [.init(id: 7, type: 0), .init(id: 8, type: 0)], shown: 7),
            DisplayGroup(display: "D2", name: "LG", index: 2, records: [.init(id: 20, type: 0), .init(id: 21, type: 0)], shown: 20),
        ]
    }
    private var current: DisplayGroup? { active().flatMap { id in groups.first { $0.records.contains { $0.id == id } } } }
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { current?.order ?? [] }
    func neighbor(offset: Int) -> UInt64? {
        guard let order = current?.records.map(\.id), let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
    func spaceSnapshot() -> SpaceSnapshot? {
        guard let current, let active = active() else { return nil }
        let uuids = Dictionary(uniqueKeysWithValues: groups.flatMap(\.records).map { ($0.id, "U\($0.id)") })
        // Like `DisplayGroups.make`: no groups with one display.
        return SpaceSnapshot(order: current.records.map(\.id), desktops: current.desktops, uuids: uuids, display: current.display, active: active,
                             groups: groups.count >= 2 ? groups : [])
    }
}

final class CrossDisplayTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var listing: TwoDisplays!
    private var sends: [(CGWindowID, UInt64)] = []
    private let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Windows 1 and 2 tile Space 7; window 3 fills Space 20, which display D2 is showing.
    private func make(layoutOnTwenty: Bool = true) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts = ["7": Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)]
        if layoutOnTwenty { state.layouts["20"] = Planner.rowLayout([WindowID(3)], rows: 1) }
        store.save(state)
        system = CoordinatorSystem()
        system.existingSpaces = [7, 8, 20, 21]
        system.hiddenSpaces = true
        system.shownSpaces = [20]
        system.censusListsShownSpaces = true
        system.displayOf = [7: "D1", 8: "D1", 20: "D2", 21: "D2"]
        system.areaOfSpace = [7: left, 8: left, 20: right, 21: right]
        system.frames[WindowID(3)] = right
        system.spaceOf = [WindowID(1): 7, WindowID(2): 7, WindowID(3): 20]
        system.pids = [WindowID(1): 101, WindowID(2): 102, WindowID(3): 103]
        system.frontPID = 102
        system.focused = WindowID(2)
        system.raiseActivatesOwner = true
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil }, takeInventory: { nil })
        coordinator.limits.settleDelay = 0
        listing = TwoDisplays(active: { self.system.space })
        coordinator.spaceListingOverride = listing
        tick(); tick(); tick()
        sends = []
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func tick() {
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    /// Confirmed sends move membership only (the frame stays where it was, as on the old display).
    private func sender(during: (() -> Void)? = nil) {
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            during?()
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            sends.append((wid, dest))
            system.spaceOf[WindowID(wid)] = dest
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
    }

    private func send(_ target: SpaceTarget, file: StaticString = #filePath, line: UInt = #line) -> OperationResult? {
        guard case .started = coordinator.edit(.sendToSpace(target), source: "test") else { XCTFail("send not started", file: file, line: line); return nil }
        drain()
        return coordinator.lastResult
    }

    func testTheListGroupsSpacesByDisplay() {
        make()
        let list = coordinator.spaceList()
        XCTAssertEqual(list.map(\.id), [7, 8, 20, 21])
        XCTAssertEqual(list.map(\.index), [1, 2, 1, 2], "desktops are numbered per display")
        XCTAssertEqual(list.map(\.displayName), ["Built-in", "Built-in", "LG", "LG"])
        XCTAssertEqual(list.filter(\.isShown).map(\.id), [7, 20], "each display's shown Space is checked")
        XCTAssertEqual(list.filter(\.isCurrent).map(\.id), [7], "only the current Space is current")
        XCTAssertEqual(list.filter(\.otherDisplay).map(\.id), [20, 21])
    }

    func testOneDisplayKeepsTheFlatList() {
        make()
        listing.groups = [listing.groups[0]]
        XCTAssertEqual(coordinator.spaceList().map(\.displayName), [nil, nil])
        XCTAssertEqual(coordinator.spaceList().map(\.otherDisplay), [false, false])
    }

    func testSendToAnotherDisplayFitsTheWindowOntoItAndRefitsTheSource() throws {
        make(layoutOnTwenty: false)
        sender()
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(result.message, "Sent the window to Desktop 2 on LG.")
        XCTAssertEqual(sends.map(\.1), [21])
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 2400, y: 0, width: 960, height: 1080), "same size, centered on the destination display")
        XCTAssertEqual(system.space, 7, "not followed")
        system.shownSpaces = [21]
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)], "the source closes up as if the window had closed")
        XCTAssertEqual(system.frames[WindowID(1)]?.width, 1920)
    }

    /// The sent window keeps focus, so macOS makes the destination current; the source display still shows the source Space.
    /// Focus went with the window to the other display; the previous window comes back, so focus stays on the source display.
    /// The destination is then shown but not current, so the window joins its layout there.
    func testFocusComesBackToTheSourceDisplayAfterASendThere() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        system.onRaiseActivated = { [unowned self] id in system.space = system.spaceOf[id] ?? system.space }
        followingSender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG.")
        XCTAssertEqual(system.space, 7, "back on the source display")
        XCTAssertEqual(system.frontPID, 101)
        XCTAssertEqual(system.focused, WindowID(1))
        XCTAssertEqual(system.shownSnapshots.first, 7, "the candidate is observed on the source while it is not current")
        for _ in 0..<6 { tick() }
        XCTAssertEqual(Set(coordinator.state.layouts["20"]?.windowIDs ?? []), [WindowID(2), WindowID(3)], "joined the shown destination's layout")
    }

    /// The previous window came forward but the source never became current again: not counted as restored.
    func testRestorationAcrossDisplaysNeedsTheSourceToBeCurrentAgain() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        followingSender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG. The previous window was not brought forward, so focus stays on LG.")
    }

    /// The history also names a window now on the other display (seen in the census there): the candidate is the latest one still only on the source.
    func testTheCandidateIsTheLatestWindowStillOnTheSource() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(3), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        system.onRaiseActivated = { [unowned self] id in system.space = system.spaceOf[id] ?? system.space }
        followingSender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG.")
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.frontPID, 101, "window 1, not window 3 on the other display")
    }

    /// ⌥B skips a window that SkyLight puts on another display's Space, though it is on screen there.
    func testFocusBackSkipsAWindowOnTheOtherDisplay() {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(3), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        guard case .started = coordinator.edit(.focusBack, source: "test") else { return XCTFail("focus back not started") }
        drain()
        XCTAssertEqual(system.focused, WindowID(1), "window 3 is on the other display's Space")
    }

    /// macOS makes the destination current only after restoration started: focus still comes back.
    func testFocusThatMovesLateStillComesBack() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        system.onRaiseActivated = { [unowned self] id in system.space = system.spaceOf[id] ?? system.space }
        system.onSpacesOf = { [unowned self] id in if id == WindowID(1), system.spaceOf[WindowID(2)] == 20 { system.space = 20 } }
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            system.shownSpaces = [7, dest]
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG.")
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.frontPID, 101)
    }

    /// Focus moves to the destination while the candidate is being observed on the source: observed again on the shown source.
    func testFocusMovingDuringTheObservationStillComesBack() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        system.onRaiseActivated = { [unowned self] id in system.space = system.spaceOf[id] ?? system.space }
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            system.shownSpaces = [7, dest]
            system.onSnapshot = { [unowned self] in system.space = dest; system.onSnapshot = nil }
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG.")
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.frontPID, 101)
    }

    /// The source display stops showing the source after the candidate was observed: the raise is not activated.
    func testRestorationStopsWhenTheSourceIsHiddenBeforeTheRaise() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        system.onRaiseActivated = { [unowned self] id in system.space = system.spaceOf[id] ?? system.space }
        system.afterShownSnapshot = { [unowned self] in system.shownSpaces.remove(7) }
        followingSender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(system.frontPID, 102, "the hidden source's window was not activated")
        XCTAssertEqual(system.space, 20)
        XCTAssertTrue(result.message.hasSuffix("The previous window was not brought forward, so focus stays on LG."), result.message)
    }

    /// The source display no longer shows the source: nothing is brought forward there.
    func testNoRestorationWhenTheSourceDisplayMoved() throws {
        make()
        coordinator.noteFront(WindowID(1), spaceKey: "7")
        coordinator.noteFront(WindowID(2), spaceKey: "7")
        followingSender(then: { [unowned self] in listing.groups[0].shown = 8; system.shownSpaces = [8, 20] })
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(system.focusCalls, 0, "nothing raised")
        XCTAssertEqual(result.message, "Sent the window to Desktop 1 on LG. Built-in then moved to Desktop 2.")
    }

    /// Confirmed sends where the window keeps focus: macOS makes the destination current, as on real displays.
    private func followingSender(then: (() -> Void)? = nil) {
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            sends.append((wid, dest))
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            system.shownSpaces = [7, dest]
            then?()
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
    }

    func testFocusFollowingTheWindowToAnotherDisplayIsNotReportedAsADisplayChange() throws {
        make(layoutOnTwenty: false)
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            system.shownSpaces = [7, dest]
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 2 on LG. Focus went with the window to LG.")
    }

    func testTheNoteNamesWhatTheSourceDisplayNowShows() throws {
        make(layoutOnTwenty: false)
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            listing.groups[0].shown = 8
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 2 on LG. Built-in then moved to Desktop 2.")
    }

    func testAnUnreadableSourceDisplayIsNotReportedAsADisplayChange() throws {
        make(layoutOnTwenty: false)
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            system.space = dest
            listing.groups[0].shown = nil
            return .confirmed(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(result.message, "Sent the window to Desktop 2 on LG. Focus went with the window to LG.")
    }

    func testAWindowLandingElsewhereIsNamedFromTheSourceDisplay() throws {
        make(layoutOnTwenty: false)
        coordinator.spaceSenderOverride = { [unowned self] wid, dest, gates in
            guard gates.beforeIssue() else { return .notIssued(.interrupted) }
            system.spaceOf[WindowID(wid)] = 20
            system.space = 20
            system.shownSpaces = [7, 20]
            return .elsewhere(20)
        }
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(result.message, "The window ended up on Desktop 1 on LG instead of Desktop 2 on LG.")
    }

    func testAWindowLargerThanTheDestinationIsShrunk() throws {
        make(layoutOnTwenty: false)
        system.frames[WindowID(2)] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        system.areaOfSpace[21] = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        sender()
        _ = try XCTUnwrap(send(.id(21)))
        XCTAssertEqual(system.frames[WindowID(2)], CGRect(x: 1920, y: 0, width: 1280, height: 800))
    }

    func testFitStopsWhenTheWindowLeavesTheDestination() throws {
        make(layoutOnTwenty: false)
        sender()
        system.onFrameRead = { [unowned self] id in if id == WindowID(2), system.spaceOf[id] == 21 { system.spaceOf[id] = 8 } }
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertTrue(result.message.contains("may not be visible there yet"), result.message)
        XCTAssertEqual(system.frames[WindowID(2)]?.minX, 960, "nothing written once the window is not only on the destination")
    }

    func testADisplaySwappedBeforeIssuingSendsNothing() throws {
        make()
        sender(during: { [unowned self] in listing.groups[1].display = "D3" })
        let result = try XCTUnwrap(send(.id(21)))
        XCTAssertNotEqual(result.outcome, .complete)
        XCTAssertTrue(sends.isEmpty, "the destination's display is checked right before the move is issued")
    }

    func testSendToAShownSpaceJoinsItsLayoutRightAway() throws {
        make()
        sender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.outcome, .complete, result.message)
        for _ in 0..<6 { tick() }
        XCTAssertEqual(Set(coordinator.state.layouts["20"]?.windowIDs ?? []), [WindowID(2), WindowID(3)], "joined without going there")
        XCTAssertEqual(system.frames[WindowID(3)]?.width, 960)
        XCTAssertEqual(system.frames[WindowID(2)]?.minX ?? 0, 1920 + 960, accuracy: 1)
        XCTAssertEqual(system.space, 7)
        XCTAssertEqual(system.focusCalls, 0, "nothing is brought forward on the other display")
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    /// A window that left the shown Space (dragged to the current one) stays in that layout until it is used; the next arrival drops it instead of failing.
    func testAShownArrivalDropsAWindowThatLeftThatSpace() throws {
        make()
        system.spaceOf[WindowID(3)] = 8 // left Space 20 for a hidden Space of the first display
        sender()
        let result = try XCTUnwrap(send(.id(20)))
        XCTAssertEqual(result.outcome, .complete, result.message)
        for _ in 0..<6 { tick() }
        XCTAssertEqual(coordinator.state.layouts["20"]?.windowIDs, [WindowID(2)], "joined; the departed window is no longer in that layout")
        XCTAssertEqual(system.frames[WindowID(2)]?.width, 1920)
    }

    /// A Space list that cannot be read once (waking from sleep, a display change) postpones the arrival instead of dropping it.
    func testAShownArrivalSurvivesAnUnreadableSpaceList() throws {
        make()
        sender()
        _ = try XCTUnwrap(send(.id(20)))
        system.existingSpaces = nil
        for _ in 0..<3 { tick() }
        XCTAssertEqual(coordinator.state.layouts["20"]?.windowIDs, [WindowID(3)])
        system.existingSpaces = [7, 8, 20, 21]
        for _ in 0..<6 { tick() }
        XCTAssertEqual(Set(coordinator.state.layouts["20"]?.windowIDs ?? []), [WindowID(2), WindowID(3)])
    }

    func testAShownArrivalWaitsWhileAMouseButtonIsHeld() throws {
        make()
        sender()
        _ = try XCTUnwrap(send(.id(20)))
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(.leftMouseDown, event: down)
        for _ in 0..<4 { tick() }
        XCTAssertEqual(coordinator.state.layouts["20"]?.windowIDs, [WindowID(3)])
    }

    func testAShownArrivalStopsWhenThatSpaceBecomesCurrent() throws {
        make()
        sender()
        _ = try XCTUnwrap(send(.id(20)))
        system.space = 20
        tick()
        XCTAssertFalse(system.shownSnapshots.contains(20), "the current Space is arranged by the usual arrival, not the other-Space path")
    }

    func testDisplayNumberResolvesAnotherDisplaysDesktop() throws {
        make(layoutOnTwenty: false)
        sender()
        _ = try XCTUnwrap(send(.desktop(2, display: 2)))
        XCTAssertEqual(sends.map(\.1), [21])
        sends = []
        system.spaceOf[WindowID(2)] = 7
        system.frames[WindowID(2)] = CGRect(x: 960, y: 0, width: 960, height: 1080)
        _ = try XCTUnwrap(send(.desktop(2, display: 1)))
        XCTAssertEqual(sends.map(\.1), [8], "the current display resolves like a plain number")
        system.focused = WindowID(1)
        system.frontPID = 101
        guard case .refused(_, let code) = coordinator.edit(.sendToSpace(.desktop(1, display: 3)), source: "test") else { return XCTFail("display 3 accepted") }
        XCTAssertEqual(code, "space-not-found")
        guard case .refused(_, let missing) = coordinator.edit(.sendToSpace(.desktop(5, display: 2)), source: "test") else { return XCTFail("desktop 5 accepted") }
        XCTAssertEqual(missing, "space-not-found")
    }

    /// `--follow` to another display: the direct move keeps the old frame, so the window is fitted onto that display after arriving.
    func testFollowingToAnotherDisplayFitsTheWindowThere() throws {
        make(layoutOnTwenty: false)
        var fittedBeforeRaise: CGRect?
        coordinator.spaceMoverOverride = { [unowned self] wid, _, dest, gates in
            guard gates.hooks.beforeIssue() else { return .failure(.interrupted) }
            system.spaceOf[WindowID(wid)] = dest
            gates.hooks.beforeRaise()
            fittedBeforeRaise = system.frames[WindowID(wid)]
            system.space = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        guard case .started = coordinator.edit(.moveToSpace(.id(21)), source: "test") else { return XCTFail("not started") }
        drain()
        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(fittedBeforeRaise, CGRect(x: 2400, y: 0, width: 960, height: 1080), "fitted before it is brought forward there")
    }

    func testFollowingChecksTheDestinationRightBeforeTheMove() throws {
        make(layoutOnTwenty: false)
        var moved = false
        coordinator.spaceMoverOverride = { [unowned self] wid, _, dest, gates in
            listing.groups[1].display = "D3"
            guard gates.hooks.beforeIssue() else { return .failure(.interrupted) }
            moved = true
            system.spaceOf[WindowID(wid)] = dest
            return .success(SpaceControl.Result(fromSpace: 7, toSpace: dest, steps: 0, wallMs: 1))
        }
        guard case .started = coordinator.edit(.moveToSpace(.id(21)), source: "test") else { return XCTFail("not started") }
        drain()
        XCTAssertFalse(moved)
    }

    /// Membership can lag behind a move to another display; a managed window off this display is asked again every observation.
    func testLateMembershipStillRefitsTheSource() {
        make(layoutOnTwenty: false)
        system.frames[WindowID(2)] = CGRect(x: 2400, y: 0, width: 960, height: 1080)
        system.shownSpaces = [20, 21]
        tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs.count, 2, "still reported on this Space")
        system.spaceOf[WindowID(2)] = 21
        tick(); tick(); tick()
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1)])
    }

    func testAShownArrivalStopsWhenThatDisplayChanges() throws {
        make()
        sender()
        system.onShownSnapshot = { [unowned self] in system.areaOfSpace[20] = CGRect(x: 1920, y: 0, width: 1600, height: 900) }
        _ = try XCTUnwrap(send(.id(20)))
        for _ in 0..<4 { tick() }
        XCTAssertEqual(coordinator.state.layouts["20"]?.windowIDs, [WindowID(3)], "nothing is planned in a work area that changed")
        XCTAssertEqual(system.frames[WindowID(3)], right)
    }

    /// The destination becomes the current Space while a setter's membership is read: that setter is not sent.
    func testAShownWriteRechecksTheSpaceAfterTheMembershipRead() throws {
        make()
        sender()
        _ = try XCTUnwrap(send(.id(20)))
        // The operation's own membership check reads first; the second read is the one inside the other-Space check.
        var reads: Int?
        system.onHiddenWrite = { _ in reads = 0 }
        system.onSpacesOf = { [unowned self] _ in
            guard let n = reads else { return }
            reads = n + 1
            if n + 1 == 2 { system.space = 20 }
        }
        for _ in 0..<4 { tick() }
        XCTAssertTrue(system.hiddenWrites.isEmpty, "nothing written once that Space became current")
        XCTAssertEqual(system.frames[WindowID(3)], right)
    }

    func testSpaceBackReturnsToTheOtherDisplay() {
        make()
        var switched: [UInt64] = []
        coordinator.spaceSwitcherOverride = { [unowned self] dest, _, _ in
            switched.append(dest)
            system.space = dest
            return .success(SpaceControl.Result(fromSpace: 20, toSpace: dest, steps: 0, wallMs: 1))
        }
        system.space = 20
        tick()
        guard case .started = coordinator.edit(.space(.back), source: "test") else { return XCTFail("space back refused across displays") }
        drain()
        XCTAssertEqual(switched, [7])
    }

    func testHookNumbersEachSpaceOnItsOwnDisplay() {
        make()
        let env = Coordinator.windowSentEnvironment(window: WindowID(2), app: "test", from: 7, to: 21, snapshot: listing.spaceSnapshot())
        XCTAssertEqual(env["LAZYSPACE_FROM_SPACE"], "1")
        XCTAssertEqual(env["LAZYSPACE_FROM_DISPLAY"], "1")
        XCTAssertEqual(env["LAZYSPACE_TO_SPACE"], "2")
        XCTAssertEqual(env["LAZYSPACE_TO_DISPLAY"], "2")
    }
}

/// The command line, the menu rows, and `list-spaces` with more than one display.
final class CrossDisplaySurfaceTests: XCTestCase {
    private func invocation(_ args: [String]) -> CLI.Invocation? {
        guard case .invocation(let inv)? = CLI.parse(args) else { return nil }
        return inv
    }

    private func isError(_ args: [String]) -> Bool {
        if case .error = CLI.parse(args) { return true }
        return false
    }

    func testDisplayOptionNamesADesktopOfAnotherDisplay() {
        XCTAssertEqual(invocation(["move-to-space", "2", "--display", "2"])?.arg, "move-to-space-2@2")
        XCTAssertEqual(invocation(["move-to-space", "2", "--display", "2", "--follow"])?.arg, "move-to-space-follow-2@2")
        XCTAssertEqual(invocation(["space", "1", "--display", "3"])?.arg, "space-1@3")
        XCTAssertEqual(EditCommand.parse("move-to-space-2@2"), .sendToSpace(.desktop(2, display: 2)))
        XCTAssertEqual(EditCommand.parse("space-1@3"), .space(.desktop(1, display: 3)))
        XCTAssertNil(EditCommand.parse("space-next@2"))
        XCTAssertTrue(isError(["space", "next", "--display", "2"]), "--display takes a desktop number only")
        XCTAssertTrue(isError(["focus", "left", "--display", "2"]))
        XCTAssertTrue(isError(["space", "1", "--display", "0"]))
        XCTAssertTrue(isError(["space", "1", "--display"]))
    }

    private func entry(_ index: Int, _ id: UInt64, display: String, current: Bool = false, shown: Bool = false, other: Bool = false) -> SpaceMenuEntry {
        SpaceMenuEntry(index: index, id: id, isCurrent: current, windows: 0, apps: [], fullScreen: false, isShown: shown, displayName: display, otherDisplay: other)
    }

    func testTheMenuBarShowsEachDisplaysDesktopInListOrder() {
        func item(_ index: Int?, _ id: UInt64, _ display: String?, current: Bool = false, shown: Bool = false) -> SpaceListItem {
            SpaceListItem(index: index, id: id, isCurrent: current, isShown: shown, displayName: display, otherDisplay: false)
        }
        XCTAssertEqual(StatusMenuCopy.barNumber([item(1, 7, nil), item(2, 8, nil, current: true, shown: true)]), "2", "one display: the current desktop")
        XCTAssertNil(StatusMenuCopy.barNumber([item(1, 7, nil), item(nil, 9, nil, current: true, shown: true)]), "one display on a full-screen Space: no number")
        let two = [item(1, 3, "DELL"), item(4, 5, "DELL", current: true, shown: true), item(1, 20, "EX", shown: true)]
        XCTAssertEqual(StatusMenuCopy.barNumber(two), "4|1")
        let fullScreen = [item(1, 3, "DELL", shown: true), item(1, 20, "EX"), item(nil, 21, "EX", current: true, shown: true)]
        XCTAssertEqual(StatusMenuCopy.barNumber(fullScreen), "1|–", "a Space without a number")
        XCTAssertEqual(StatusMenuCopy.barTitle(mode: "service", space: "4|1"), "4|1 · service")
    }

    func testMenuRowsGetADisplayHeadingAndEachShownSpaceIsChecked() {
        let entries = [entry(1, 7, display: "Built-in", current: true, shown: true), entry(2, 8, display: "Built-in"),
                       entry(1, 20, display: "LG", shown: true, other: true)]
        XCTAssertEqual((0..<3).map { SpaceOverviewMenu.header(before: $0, in: entries)?.title }, ["Built-in", nil, "LG"])
        let shown = SpaceOverviewMenu.item(entries[2], action: #selector(NSObject.description), target: NSObject())
        XCTAssertEqual(shown.state, .on, "the Space the other display shows is checked")
        let flat = SpaceMenuEntry(index: 1, id: 7, isCurrent: true, windows: 0, apps: [], fullScreen: false)
        XCTAssertNil(SpaceOverviewMenu.header(before: 0, in: [flat]), "no heading with one display")
    }

    func testListSpacesShowsAHeadingPerDisplay() {
        func space(_ id: UInt64, _ n: Int, _ display: String, _ name: String, _ index: Int) -> SpaceOverview.Entry {
            SpaceOverview.Entry(spaceID: id, type: 0, isCurrent: id == 7, windowIDs: [], desktopIndex: n, display: display, displayName: name, displayIndex: index)
        }
        let overview = SpaceOverview(spaces: [space(7, 1, "D1", "Built-in", 1), space(20, 1, "D2", "LG", 2)], unknown: [])
        let text = CLI.spacesText(overview)
        XCTAssertTrue(text.contains("Display 1: Built-in"), text)
        XCTAssertTrue(text.contains("Display 2: LG"), text)
        XCTAssertTrue(text.contains("--display"), text)
        let single = CLI.spacesText(SpaceOverview(spaces: [space(7, 1, "D1", "Built-in", 1)], unknown: []))
        XCTAssertFalse(single.contains("Display 1"), single)
    }
}
