import XCTest
import CoreGraphics
import Copy
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

private struct Listing: SpaceListing {
    var order: [UInt64]
    var active: () -> UInt64?
    func orderedSpaces() -> [(id: UInt64, type: Int32?)] { order.map { ($0, 0) } }
    func neighbor(offset: Int) -> UInt64? {
        guard let active = active(), let i = order.firstIndex(of: active), order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }
}

/// Replaced reader. Spaces 7, 8, 9 are Desktops 1, 2, 3.
private final class FakeDesktopSource: DesktopShortcutSource {
    var reads: [Int: SpaceControl.DesktopShortcutRead] = [:]
    var count: Int? = 3
    func desktopNumber(of target: UInt64) -> Int? { (7...9).contains(target) ? Int(target) - 6 : nil }
    func ordinaryDesktopCount() -> Int? { count }
    func desktopShortcut(_ desktop: Int) -> SpaceControl.DesktopShortcutRead { reads[desktop] ?? .off }
    var arrows: [Bool: SpaceControl.ArrowShortcutRead] = [false: .usable(.init(right: false, keyCode: 123, flags: 0x0084_0000)),
                                                         true: .usable(.init(right: true, keyCode: 124, flags: 0x0084_0000))]
    func arrowShortcut(right: Bool) -> SpaceControl.ArrowShortcutRead { arrows[right] ?? .off }
}

/// Tier 0 (macOS "Switch to Desktop N"): conditions, suppression records, guidance, and the status line.
final class DesktopShortcutTests: XCTestCase {
    private static func hotkey(_ desktop: Int, flags: UInt32 = 0x0004_0000) -> SpaceControl.DesktopHotkey {
        .init(desktop: desktop, id: Int32(117 + desktop), keyCode: UInt32(17 + desktop), flags: flags)
    }

    // MARK: - Conditions

    func testDecisionRequiresEveryCondition() {
        let k = Self.hotkey(2)
        let memory = HotkeyMemory()
        func decide(screens: Int = 1, reorders: Bool = false, desktop: Int? = 2, read: SpaceControl.DesktopShortcutRead? = .usable(k),
                    dock: pid_t? = 7, memory: HotkeyMemory = memory) -> DesktopShortcutDecision {
            DesktopShortcuts.decide(screens: screens, reorders: reorders, desktop: desktop, read: read, dockPID: dock, memory: memory)
        }
        XCTAssertEqual(decide(), .use(k, dockPID: 7))
        XCTAssertEqual(decide(screens: 2), .skip(.multipleDisplays))
        XCTAssertEqual(decide(screens: 0), .skip(.multipleDisplays))
        XCTAssertEqual(decide(reorders: true), .skip(.reordersByRecentUse))
        XCTAssertEqual(decide(desktop: nil, read: nil), .skip(.notOrdinaryDesktop))
        XCTAssertEqual(decide(dock: nil), .skip(.dockUnknown))
        XCTAssertEqual(decide(read: .off), .skip(.off))
        XCTAssertEqual(decide(read: .unread), .skip(.unread))
        XCTAssertEqual(decide(read: .unusable), .skip(.unusable))
        XCTAssertEqual(decide(read: .conflict(k)), .skip(.conflict))
        var suppressed = memory
        suppressed.recordPassThrough(dock: 7, k)
        XCTAssertEqual(decide(memory: suppressed), .skip(.suppressed))
    }

    // MARK: - Record lifetime

    /// Suppression is set only on pass-through and vanishes when the Dock pid or hotkey setting changes. A confirmed arrival lifts it.
    func testSuppressionLivesForThisDockAndThisConfiguration() {
        let k = Self.hotkey(2)
        var memory = HotkeyMemory()
        memory.recordPassThrough(dock: 7, k)
        XCTAssertTrue(memory.isSuppressed(dock: 7, k))
        XCTAssertFalse(memory.isSuppressed(dock: 7, Self.hotkey(3)), "per shortcut")
        // Setting changed (remapped to ⌥⌘2): the new setting is not suppressed and the old record is gone.
        let remapped = Self.hotkey(2, flags: 0x0018_0000)
        XCTAssertFalse(memory.isSuppressed(dock: 7, remapped))
        memory.forget(id: 119, unless: remapped)
        XCTAssertTrue(memory.suppressed.isEmpty)
        // The Dock restarted (pid changed).
        memory.recordPassThrough(dock: 7, k)
        memory.forget(exceptDock: 8)
        XCTAssertFalse(memory.isSuppressed(dock: 8, k))
        XCTAssertTrue(memory.suppressed.isEmpty)
        // The Dock is unknown.
        memory.recordArrival(dock: 7, k)
        memory.forget(exceptDock: nil)
        XCTAssertTrue(memory.confirmed.isEmpty)
        // Confirmed arrival and pass-through replace each other.
        memory.recordArrival(dock: 7, k)
        XCTAssertTrue(memory.isConfirmed(dock: 7, k))
        memory.recordPassThrough(dock: 7, k)
        XCTAssertFalse(memory.isConfirmed(dock: 7, k))
        memory.recordArrival(dock: 7, k)
        XCTAssertFalse(memory.isSuppressed(dock: 7, k))
    }

    /// Planning and status expire records the same way. Off or a different assignment is a settings change (records dropped); an overlap with a LazySpace shortcut or an unreadable read keeps them.
    func testObservingAReadAppliesTheSameInvalidation() {
        let k = Self.hotkey(2)
        var memory = HotkeyMemory()
        memory.recordPassThrough(dock: 7, k)
        memory.observe(desktop: 2, .conflict(k))
        memory.observe(desktop: 2, .unread)
        memory.observe(desktop: 3, .off)
        XCTAssertTrue(memory.isSuppressed(dock: 7, k), "a conflict, an unreadable value, or another Desktop is not a change of this shortcut")
        memory.observe(desktop: 2, .usable(Self.hotkey(2, flags: 0x0018_0000)))
        XCTAssertFalse(memory.isSuppressed(dock: 7, k))
        memory.recordPassThrough(dock: 7, k)
        memory.observe(desktop: 2, .off)
        XCTAssertTrue(memory.suppressed.isEmpty)
        memory.recordPassThrough(dock: 7, k)
        memory.observe(desktop: 2, .unusable)
        XCTAssertTrue(memory.suppressed.isEmpty)
    }

    /// Left and right records are separate and expire like Desktops (Dock or setting changes; conflicts and unreadable reads keep them).
    func testArrowRecordsAreSeparateAndExpireLikeDesktops() {
        let left = SpaceControl.ArrowHotkey(right: false, keyCode: 123, flags: 0x0084_0000)
        let right = SpaceControl.ArrowHotkey(right: true, keyCode: 124, flags: 0x0084_0000)
        var memory = HotkeyMemory()
        memory.recordPassThrough(dock: 7, right)
        XCTAssertTrue(memory.isSuppressed(dock: 7, right))
        XCTAssertFalse(memory.isSuppressed(dock: 7, left), "per direction")
        memory.observe(right: true, .conflict(right))
        memory.observe(right: true, .unread)
        memory.observe(right: false, .off)
        XCTAssertTrue(memory.isSuppressed(dock: 7, right))
        memory.observe(right: true, .off)
        XCTAssertFalse(memory.isSuppressed(dock: 7, right))
        memory.recordPassThrough(dock: 7, right)
        memory.observe(right: true, .usable(.init(right: true, keyCode: 124, flags: 0x0018_0000)))
        XCTAssertFalse(memory.isSuppressed(dock: 7, right), "another binding")
        memory.recordPassThrough(dock: 7, right)
        memory.forget(exceptDock: 8)
        XCTAssertTrue(memory.arrowSuppressed.isEmpty)
        memory.recordArrival(dock: 7, left)
        XCTAssertTrue(memory.isConfirmed(dock: 7, left))
    }

    /// `lazyspace status` lines: separate left/right states, and Desktop numbers within the existing range. Not shown in Settings.
    func testStatusLinesKeepEachDirectionAndTheDesktopStates() {
        XCTAssertEqual(DesktopShortcuts.arrowStatusText(.working), "in use")
        XCTAssertEqual(DesktopShortcuts.arrowStatusText(.unverified), "on but not yet confirmed")
        XCTAssertEqual(DesktopShortcuts.arrowStatusText(.paused), "paused (macOS did not respond; logging out of your Mac and back in may help)")
        XCTAssertEqual(DesktopShortcuts.arrowStatusText(.ineligible(.off)), "not used (shortcut off)")
        let states: [(desktop: Int, state: DesktopShortcuts.State)] = [
            (1, .working), (2, .unverified), (3, .unverified), (4, .ineligible(.conflict)), (5, .ineligible(.off)), (6, .ineligible(.off)),
        ]
        XCTAssertEqual(DesktopShortcuts.statusLine(global: nil, states: states),
                       "In use for Desktop 1; on but not yet confirmed for 2, 3; not used for 4 (same as a LazySpace shortcut); not used for 5, 6 (shortcut off)")
        XCTAssertEqual(DesktopShortcuts.statusLine(global: nil, states: [(3, .paused)]),
                       "Paused for 3 (macOS did not respond; logging out of your Mac and back in may help)")
        inJapanese {
            XCTAssertEqual(DesktopShortcuts.arrowStatusText(.paused), "一時停止中（応答なし。Macからログアウトしてログインし直すと、使えるようになることがあります）")
            XCTAssertEqual(DesktopShortcuts.statusLine(global: nil, states: [(3, .paused)]),
                           "一時停止中: 3（応答なし。Macからログアウトしてログインし直すと、使えるようになることがあります）")
        }
    }

    // MARK: - Text

    private func inJapanese(_ body: () throws -> Void) rethrows {
        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        try body()
    }

    /// No response for left/right suggests logging out. The English text for "could not prepare" stays unchanged.
    func testSteppingTextSuggestsLoggingOutInsteadOfTheDock() {
        XCTAssertEqual(DesktopShortcuts.steppingText(.notHonored(right: true)),
                       "macOS did not respond to “Move right a Space”. Logging out of your Mac and back in may resolve this.")
        XCTAssertEqual(DesktopShortcuts.steppingText(.suppressed(right: false)),
                       "LazySpace is not using “Move left a Space” for now because macOS did not respond to it earlier. Logging out of your Mac and back in may resolve this.")
        XCTAssertEqual(DesktopShortcuts.steppingText(.noTap),
                       "LazySpace could not prepare to check whether macOS responds to its Space shortcuts, so it did not send them.")
        inJapanese {
            XCTAssertEqual(DesktopShortcuts.steppingText(.notHonored(right: true)),
                           "macOSが「右の操作スペースに移動」に応答しませんでした。Macからログアウトしてログインし直すと、解決することがあります。")
            XCTAssertEqual(DesktopShortcuts.steppingText(.suppressed(right: false)),
                           "以前macOSが「左の操作スペースに移動」に応答しなかったため、いまは使っていません。Macからログアウトしてログインし直すと、解決することがあります。")
            XCTAssertEqual(DesktopShortcuts.steppingText(.noTap),
                           "macOSが操作スペースのショートカットに応答するかを確かめる準備ができなかったため、送っていません。")
        }
    }

    /// Results and paused status lines suggest logging out; only the preferences-file note in `lazyspace status` mentions the Dock.
    func testOnlyTheFreshnessNoteMentionsTheDock() {
        for language in Language.allCases {
            let saved = Copy.language
            Copy.language = language
            defer { Copy.language = saved }
            let results = [SpaceControl.SteppingIssue.notHonored(right: false), .notHonored(right: true), .suppressed(right: false), .suppressed(right: true), .noTap]
                .map(DesktopShortcuts.steppingText)
            for text in results { XCTAssertFalse(text.contains("Dock"), text) }
            for text in [DesktopShortcuts.arrowStatusText(.paused), DesktopShortcuts.statusLine(global: nil, states: [(3, .paused)])] {
                XCTAssertFalse(text.contains("Dock"), text)
            }
            XCTAssertTrue(DockShortcutFreshness.message.contains("Dock"))
        }
    }

    func testStatusLineGroupsDesktopsByState() {
        XCTAssertEqual(DesktopShortcuts.statusLine(global: .multipleDisplays, states: []), "Not used — more than one display")
        XCTAssertEqual(DesktopShortcuts.statusLine(global: .reordersByRecentUse, states: []), "Not used — Spaces are rearranged by most recent use")
        let line = DesktopShortcuts.statusLine(global: nil, states: [
            (1, .working), (2, .working), (3, .unverified), (4, .unverified), (5, .unverified), (6, .paused),
            (7, .ineligible(.off)), (8, .ineligible(.conflict)), (9, .ineligible(.off)),
        ])
        XCTAssertEqual(line, "In use for Desktop 1, 2; on but not yet confirmed for 3–5; paused for 6 (macOS did not respond; logging out of your Mac and back in may help); "
                       + "not used for 7, 9 (shortcut off); not used for 8 (same as a LazySpace shortcut)")
        XCTAssertEqual(DesktopShortcuts.ranges([1, 2, 3, 5, 7, 8]), "1–3, 5, 7, 8")
    }

    // MARK: - Coordinator

    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var source: FakeDesktopSource!
    private var plans: [SpaceControl.SwitchPlan] = []

    override func tearDownWithError() throws {
        if coordinator != nil { drain() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func make() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil }, takeInventory: { nil })
        coordinator.spaceListingOverride = Listing(order: [7, 8, 9], active: { self.system.space })
        source = FakeDesktopSource()
        source.reads = [1: .usable(Self.hotkey(1)), 2: .usable(Self.hotkey(2)), 3: .usable(Self.hotkey(3))]
        coordinator.desktopShortcutSourceOverride = source
        coordinator.screenCount = { 1 }
        coordinator.dockProcessID = { 7 }
        coordinator.reordersByRecentUse = { false }
    }

    private func drain() {
        let done = expectation(description: "drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Replaces the switch. With `event`, reports it as the tier-0 result, then pretends to arrive (or returns `failure`).
    private func switcher(event: SpaceControl.HotkeyEvent? = nil, failure: SpaceControl.Failure? = nil) {
        coordinator.spaceSwitcherOverride = { dest, plan, _ in
            self.plans.append(plan)
            if let event { plan.hotkey?.report(event) }
            if let failure { return .failure(failure) }
            let from = self.system.space ?? 0
            self.system.space = dest
            return .success(SpaceControl.Result(fromSpace: from, toSpace: dest, steps: 0, wallMs: 1))
        }
    }

    private func switchTo(_ index: Int) {
        _ = coordinator.edit(.space(.index(index)), source: "test")
        drain()
    }

    func testPlanCarriesTheDesktopShortcutWhenEligible() {
        make(); switcher()
        switchTo(2)
        XCTAssertEqual(plans.last?.hotkey?.shortcut, Self.hotkey(2))
        XCTAssertEqual(plans.last?.hotkey?.dockPID, 7)
        XCTAssertEqual(plans.last?.hotkey?.stillEligible(), true)
    }

    func testIneligibleConditionsLeaveTheShortcutOut() {
        make(); switcher()
        for change in ["screens", "reorders", "dock", "off", "conflict"] {
            coordinator.screenCount = { change == "screens" ? 2 : 1 }
            coordinator.reordersByRecentUse = { change == "reorders" }
            coordinator.dockProcessID = { change == "dock" ? nil : 7 }
            let target = system.space == 8 ? 3 : 2
            source.reads[target] = change == "off" ? .off : change == "conflict" ? .conflict(Self.hotkey(target)) : .usable(Self.hotkey(target))
            switchTo(target)
            XCTAssertNil(plans.last?.hotkey, change)
        }
    }

    /// Reread right before posting: false if the Dock changed, a display was added, or rearranging turned on.
    func testStillEligibleReReadsTheOutsideConditions() {
        make(); switcher()
        switchTo(2)
        guard let hotkey = plans.last?.hotkey else { return XCTFail("no plan") }
        coordinator.reordersByRecentUse = { true }
        XCTAssertFalse(hotkey.stillEligible())
        coordinator.reordersByRecentUse = { false }
        coordinator.dockProcessID = { 8 }
        XCTAssertFalse(hotkey.stillEligible())
        coordinator.dockProcessID = { 7 }
        coordinator.screenCount = { 2 }
        XCTAssertFalse(hotkey.stillEligible())
    }

    /// Pass-through is recorded without a word in the result, and tier 0 is unused for that Dock and setting; a new Dock uses it again.
    func testPassThroughIsRecordedSilentlyAndExpiresWithTheDock() {
        make(); switcher(event: .passedThrough)
        switchTo(2)
        XCTAssertEqual(coordinator.lastResult?.message, "Switched to Desktop 2.", "the switch still happened, so there is nothing to do")
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.contains("paused for 2") == true)
        switcher()
        switchTo(1)
        XCTAssertNotNil(plans.last?.hotkey, "other Desktops are not affected")
        switchTo(2)
        XCTAssertNil(plans.last?.hotkey, "suppressed for this Dock and configuration")
        switchTo(1)
        coordinator.dockProcessID = { 8 }
        switchTo(2)
        XCTAssertNotNil(plans.last?.hotkey, "a new Dock is tried again")
    }

    func testChangedShortcutIsTriedAgain() {
        make(); switcher(event: .passedThrough)
        switchTo(2)
        switcher()
        switchTo(1)
        source.reads[2] = .usable(Self.hotkey(2, flags: 0x0018_0000))
        switchTo(2)
        XCTAssertEqual(plans.last?.hotkey?.shortcut, Self.hotkey(2, flags: 0x0018_0000))
    }

    /// After pass-through, a failure of the other route reports only that failure.
    func testPassThroughFollowedByAFailureReportsOnlyTheFailure() {
        make(); switcher(event: .passedThrough, failure: .switchUnconfirmed)
        switchTo(2)
        let message = coordinator.lastResult?.message ?? ""
        XCTAssertTrue(message.hasSuffix("may still happen."), message)
        XCTAssertFalse(message.contains("Switch to Desktop"), message)
        inJapanese {
            switcher(event: .passedThrough, failure: .switchUnconfirmed)
            switchTo(3)
            let japanese = coordinator.lastResult?.message ?? ""
            XCTAssertTrue(japanese.hasSuffix("1つずつの移動は行っていません。"), japanese)
            XCTAssertFalse(japanese.contains("へ切り替え」"), japanese)
        }
    }

    /// A switch that fell back after pass-through reads like any other switch in each language.
    func testSwitchAfterPassThroughReadsLikeAnyOtherSwitch() {
        make(); switcher()
        switchTo(3)
        let plainEnglish = coordinator.lastResult?.message ?? ""
        switchTo(1)
        switcher(event: .passedThrough)
        switchTo(3)
        XCTAssertEqual(plainEnglish, "Switched to Desktop 3.")
        XCTAssertEqual(coordinator.lastResult?.message, plainEnglish)
        inJapanese {
            // A different Dock tries the suppressed "Switch to Desktop 3" again.
            coordinator.dockProcessID = { 8 }
            switcher()
            switchTo(1)
            switchTo(3)
            XCTAssertEqual(coordinator.lastResult?.message, "デスクトップ3へ切り替えました。")
            switchTo(1)
            switcher(event: .passedThrough)
            switchTo(3)
            XCTAssertEqual(coordinator.lastResult?.message, "デスクトップ3へ切り替えました。")
        }
    }

    /// A suppressed A that is turned off (observed by status) and back to A is tried again.
    func testStatusObservingAChangedShortcutDropsItsSuppression() {
        make(); switcher(event: .passedThrough)
        switchTo(2)
        switcher()
        switchTo(1)
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.contains("paused for 2") == true)
        source.reads[2] = .off
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.contains("not used for 2 (shortcut off)") == true)
        source.reads[2] = .usable(Self.hotkey(2))
        XCTAssertEqual(coordinator.desktopShortcutStatus(), "On but not yet confirmed for 1–3", "the old suppression was dropped")
        switchTo(2)
        XCTAssertEqual(plans.last?.hotkey?.shortcut, Self.hotkey(2), "tried again")
    }

    /// While it overlaps a LazySpace shortcut it shows as a conflict; once resolved, the earlier suppression returns (not a settings change).
    func testConflictIsNotAConfigurationChange() {
        make(); switcher(event: .passedThrough)
        switchTo(2)
        switcher()
        switchTo(1)
        source.reads[2] = .conflict(Self.hotkey(2))
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.contains("not used for 2 (same as a LazySpace shortcut)") == true)
        switchTo(2)
        XCTAssertNil(plans.last?.hotkey)
        switchTo(1)
        source.reads[2] = .usable(Self.hotkey(2))
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.contains("paused for 2") == true)
        switchTo(2)
        XCTAssertNil(plans.last?.hotkey, "still suppressed")
    }

    /// Recording pass-through during stepping pauses only that direction, cleared by a new Dock. Desktop numbers come from existing Desktops.
    func testArrowPolicyRecordsPerDirectionAndStatusShowsBoth() {
        make()
        source.count = 3
        let right = SpaceControl.ArrowHotkey(right: true, keyCode: 124, flags: 0x0084_0000)
        coordinator.spaceSwitcherOverride = { dest, plan, _ in
            self.plans.append(plan)
            plan.arrows?.report(right, .passedThrough)
            return .failure(.steppingUnavailable(.notHonored(right: true)))
        }
        switchTo(2)
        XCTAssertEqual(plans.last?.arrows?.isSuppressed(right), true)
        XCTAssertEqual(plans.last?.arrows?.isSuppressed(.init(right: false, keyCode: 123, flags: 0x0084_0000)), false)
        let stepped = coordinator.lastResult?.message ?? ""
        XCTAssertTrue(stepped.contains("macOS did not respond to “Move right a Space”. Logging out of your Mac and back in may resolve this."), stepped)
        XCTAssertFalse(stepped.contains("Dock"), stepped)
        let states = coordinator.arrowShortcutStates()
        XCTAssertEqual(states?.left, .unverified)
        XCTAssertEqual(states?.right, .paused)
        XCTAssertEqual(coordinator.status().rightShortcut, "paused (macOS did not respond; logging out of your Mac and back in may help)")
        XCTAssertEqual(coordinator.desktopShortcutStates()?.states.map(\.desktop), [1, 2, 3])
        coordinator.dockProcessID = { 8 }
        XCTAssertEqual(coordinator.arrowShortcutStates()?.right, .unverified)
    }

    func testStatusLineReflectsArrivalsAndIneligibility() {
        make(); switcher(event: .arrived)
        source.reads[3] = .conflict(Self.hotkey(3))
        switchTo(2)
        XCTAssertEqual(coordinator.desktopShortcutStatus(), "In use for Desktop 2; on but not yet confirmed for 1; not used for 3 (same as a LazySpace shortcut)")
        coordinator.screenCount = { 2 }
        XCTAssertEqual(coordinator.desktopShortcutStatus(), "Not used — more than one display")
        coordinator.screenCount = { 1 }
        coordinator.dockProcessID = { 9 }
        XCTAssertTrue(coordinator.desktopShortcutStatus()?.hasPrefix("On but not yet confirmed for 1, 2") == true, "a new Dock forgets the confirmation")
    }
}

// MARK: - State file and the Dock freshness line

extension DesktopShortcutTests {
    /// An old state file's "don't show again" key is skipped, other state is kept, and nothing is written back.
    func testStateWithTheRetiredHintKeyStillLoads() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.firstLaunchDone = true
        store.save(state)
        let url = root.appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["desktopShortcutHintDismissed"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let loaded = store.load()
        XCTAssertTrue(loaded.firstLaunchDone, "the rest of the state is kept")
        store.save(loaded)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("desktopShortcutHintDismissed"))
    }

    /// State files missing a required key are not loaded.
    func testIncompleteStateFilesAreRejected() throws {
        let data = Data(#"{"paused":false,"firstLaunchDone":true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedState.self, from: data))
    }

    /// Dock freshness: the line appears in status only when the preferences file is newer. No behavior change; not shown in Settings.
    func testDockFreshnessLineAppearsOnlyWhenPreferencesAreNewer() {
        make()
        let english = "Keyboard shortcut preferences were saved after the Dock started. If a Mission Control shortcut does not respond, restarting the Dock (Terminal: killall Dock) or logging out and in may help."
        for (freshness, shown) in [(DockShortcutFreshness.preferencesNewer, true), (.current, false), (.unknown, false)] {
            coordinator.dockShortcutFreshness = { freshness }
            XCTAssertEqual(coordinator.status().dockShortcutFreshness, shown ? english : nil, "\(freshness)")
            XCTAssertEqual(DockShortcutFreshness.message, english)
            XCTAssertEqual(CLI.statusText(coordinator.status()).contains(english), shown, "\(freshness)")
        }
        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        XCTAssertEqual(DockShortcutFreshness.message, "Dockの起動後にキーボードショートカットの設定が保存されています。Mission Controlのショートカットが応答しないときは、Dockの再起動（ターミナルで`killall Dock`）かログアウトで直ることがあります。")
    }
}
