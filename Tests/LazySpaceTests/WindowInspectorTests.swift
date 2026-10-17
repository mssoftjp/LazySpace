import AppKit
import XCTest
import Copy
import LayoutCore
@testable import Operations
@testable import LazySpaceApp

final class WindowInspectorTests: XCTestCase {
    func testRemediationIgnoresPauseAndLocalOff() {
        XCTAssertFalse(ReadyWindowController.showsRemediation(inspectorStatus()))
        XCTAssertNil(ReadyWindowController.remediationReason(inspectorStatus()))

        var paused = inspectorStatus(paused: true)
        paused.availability = .paused
        paused.availabilityReason = "Paused in all Spaces"
        XCTAssertFalse(ReadyWindowController.showsRemediation(paused))
        XCTAssertNil(ReadyWindowController.remediationReason(paused))
        XCTAssertNotEqual(StatusMenuCopy.availabilityTitle(paused), paused.manualReason)

        var off = inspectorStatus(currentSpaceAutoPaused: true)
        off.availability = .automatic
        XCTAssertFalse(ReadyWindowController.showsRemediation(off))
        XCTAssertNil(ReadyWindowController.remediationReason(off))

    }

    /// When the configuration file, Stage Manager, or the display setup stops automatic arrangement, the remediation sheet says why.
    func testRemediationExplainsTheOtherAutomaticArrangementReasons() {
        var off = inspectorStatus(autoAvailable: false)
        off.autoReason = "Automatic arrangement is off while Stage Manager is on. Turn off Stage Manager to use it."
        XCTAssertTrue(ReadyWindowController.showsRemediation(off))
        XCTAssertEqual(ReadyWindowController.remediationReason(off), off.autoReason)
        XCTAssertEqual(ReadyWindowController.remediationDetail(off), off.autoReason)
        XCTAssertEqual(ReadyWindowController.remediationChoices(off).map(\.kind), [.close])
        off.configError = "The configuration has errors"
        XCTAssertEqual(ReadyWindowController.remediationChoices(off).map(\.kind), [.close, .openGeneralSettings])
    }

    func testRemediationCoversPermissionAndCapability() {
        var missing = inspectorStatus(
            trusted: false, manualAvailable: false, autoAvailable: false,
            manualReason: "A long accessibility essay that must stay off the main line.")
        missing.availability = .needsSetup
        XCTAssertTrue(ReadyWindowController.showsRemediation(missing))
        XCTAssertEqual(ReadyWindowController.remediationReason(missing), "The \(AccessPane.name()) permission is required.")
        XCTAssertFalse(ReadyWindowController.remediationReason(missing)!.contains("essay"))
        XCTAssertEqual(ReadyWindowController.remediationChoices(missing).map(\.kind), [.close, .openGeneralSettings])
        XCTAssertFalse(ReadyWindowController.remediationDetail(missing).contains("can continue"))

        let space = inspectorStatus(
            manualAvailable: false, autoAvailable: false, spaceObservation: false,
            manualReason: "This version of macOS does not report which Space a window is on, and the paragraph keeps going.")
        XCTAssertEqual(ReadyWindowController.remediationReason(space), "The current Space can't be detected.")
        XCTAssertFalse(ReadyWindowController.remediationReason(space)!.contains("paragraph"))
        XCTAssertEqual(ReadyWindowController.remediationChoices(space).map(\.kind), [.close])

        let input = inspectorStatus(
            autoAvailable: false,
            inputObservation: "unavailable",
            autoReason: "Automatic arrangement is off because input cannot be observed, so windows could move while you use them.")
        XCTAssertEqual(ReadyWindowController.remediationReason(input), "Input observation is unavailable.")
        XCTAssertFalse(ReadyWindowController.remediationReason(input)!.contains("could move"))
        XCTAssertEqual(ReadyWindowController.remediationChoices(input).map(\.kind), [.close, .openSettings])
        XCTAssertTrue(ReadyWindowController.remediationDetail(input).contains("Input observation is unavailable"))
        XCTAssertFalse(ReadyWindowController.remediationDetail(input).localizedCaseInsensitiveContains("check"))
    }

    func testPreviousOperationIsRecentAndIncompleteOnly() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(nil, now: now))
        XCTAssertTrue(ReadyWindowController.showsPreviousOperation(operation(outcome: .partial, kind: "arrange", finished: now), now: now))
        XCTAssertTrue(ReadyWindowController.showsPreviousOperation(operation(outcome: .interrupted, kind: "arrange", finished: now.addingTimeInterval(-1800)), now: now))
        XCTAssertTrue(ReadyWindowController.showsPreviousOperation(operation(outcome: .notPossible, kind: "edit:resize", finished: now.addingTimeInterval(-1799)), now: now))
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(operation(outcome: .partial, kind: "arrange", finished: now.addingTimeInterval(-1801)), now: now))
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(operation(outcome: .notPossible, kind: "arrange", finished: now.addingTimeInterval(1)), now: now))
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(operation(outcome: .complete, kind: "arrange", finished: now), now: now))
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(operation(outcome: .nothingToDo, kind: "arrange", finished: now), now: now))
        for kind in ["space", "move-to-space"] {
            XCTAssertFalse(ReadyWindowController.showsPreviousOperation(operation(outcome: .partial, kind: kind, finished: now), now: now), kind)
        }
        XCTAssertTrue(ReadyWindowController.showsPreviousOperation(operation(outcome: .partial, kind: "edit:move", finished: now), now: now))

        let stale = operation(outcome: .partial, kind: "arrange", finished: now.addingTimeInterval(-3 * 60 * 60))
        XCTAssertFalse(ReadyWindowController.showsPreviousOperation(stale, now: now))
        XCTAssertTrue(StatusMenuCopy.showsRecent(result: stale, managed: true, now: now))
    }

    func testPreviousOperationUsesRecordedFieldsOnly() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = operation(outcome: .partial, kind: "arrange", finished: now, spaceID: 99, message: "Stopped halfway")
        let text = ReadyWindowController.previousOperationText(empty, name: { _ in "Finder" }, time: { _ in "TIME" })
        XCTAssertTrue(text.contains("Finished: TIME"))
        XCTAssertTrue(text.contains("Recorded Space ID: 99"))
        XCTAssertFalse(text.contains("Desktop 1"))
        XCTAssertTrue(text.contains("Partially Applied"))
        XCTAssertTrue(text.contains("Stopped halfway"))
        XCTAssertTrue(text.contains("Targets: not recorded"))
        XCTAssertFalse(text.contains("Finder"))
        XCTAssertFalse(text.contains("complete history"))

        let missingSpace = operation(outcome: .interrupted, kind: "arrange", finished: now, spaceID: nil, message: "Interrupted")
        XCTAssertTrue(ReadyWindowController.previousOperationText(missingSpace, time: { _ in "TIME" }).contains("Recorded Space ID: not recorded"))

        let finder = TargetReport(id: WindowID(7), app: "com.apple.finder", before: .zero, planned: nil, after: nil, status: .unapplied, issued: 1, note: nil)
        let recorded = operation(outcome: .notPossible, kind: "arrange", finished: now, spaceID: 4, message: "Could not finish", targets: [finder])
        let named = ReadyWindowController.previousOperationText(recorded, name: { $0 == "com.apple.finder" ? "Finder" : $0 }, time: { _ in "TIME" })
        XCTAssertTrue(named.contains("Finder — Not Applied"))
        XCTAssertTrue(named.contains("Recorded targets"))
        XCTAssertFalse(named.contains("Targets: not recorded"))
        XCTAssertFalse(named.contains("Eligible"))
        XCTAssertFalse(named.contains("Secret"))
    }

    func testFreshnessDropsStaleResultsAndRefreshesTheLatestSpace() {
        let space1 = WindowInspectContext(spaceID: 1, trusted: true, spaceObservationAvailable: true)
        let space2 = WindowInspectContext(spaceID: 2, trusted: true, spaceObservationAvailable: true)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 2, requested: space1,
            snapshot: space1, current: space1, stableRetries: 0), .ignore)

        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 1, requested: space1,
            snapshot: space1, current: space2, stableRetries: 0), .rerequest)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 2, latestGeneration: 2, requested: space2,
            snapshot: space2, current: space2, stableRetries: 0), .accept)

        let untrusted = WindowInspectContext(spaceID: 2, trusted: false, spaceObservationAvailable: true)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 3, latestGeneration: 3, requested: space2,
            snapshot: space2, current: untrusted, stableRetries: 0), .rerequest)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 4, latestGeneration: 4, requested: untrusted,
            snapshot: untrusted, current: untrusted, stableRetries: 0), .accept)

        let unavailable = WindowInspectContext(spaceID: nil, trusted: true, spaceObservationAvailable: false)
        let recovered = WindowInspectContext(spaceID: 3, trusted: true, spaceObservationAvailable: true)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 5, latestGeneration: 5, requested: unavailable,
            snapshot: unavailable, current: recovered, stableRetries: 0), .rerequest)
        XCTAssertNotEqual(WindowInspectFreshness.decide(
            requestedGeneration: 6, latestGeneration: 6, requested: recovered,
            snapshot: unavailable, current: recovered, stableRetries: 0), .accept)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 7, latestGeneration: 7, requested: recovered,
            snapshot: recovered, current: recovered, stableRetries: 0), .accept)
    }

    func testFreshnessDoesNotSpinWhenSpaceIsUnknown() {
        let unknown = WindowInspectContext(spaceID: nil, trusted: true, spaceObservationAvailable: false)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 1, requested: unknown,
            snapshot: unknown, current: unknown, stableRetries: 0), .accept)
        let numbered = WindowInspectContext(spaceID: 7, trusted: true, spaceObservationAvailable: false)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 1, requested: unknown,
            snapshot: numbered, current: unknown, stableRetries: 0), .rerequest)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 1, requested: unknown,
            snapshot: numbered, current: unknown, stableRetries: 1), .hold)

        let stable = WindowInspectContext(spaceID: 5, trusted: true, spaceObservationAvailable: true)
        let other = WindowInspectContext(spaceID: 8, trusted: true, spaceObservationAvailable: true)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 1, latestGeneration: 1, requested: stable,
            snapshot: other, current: stable, stableRetries: 0), .rerequest)
        XCTAssertEqual(WindowInspectFreshness.decide(
            requestedGeneration: 2, latestGeneration: 2, requested: stable,
            snapshot: other, current: stable, stableRetries: 1), .hold)
    }

    func testRowsDistinguishEligibleWaitingDialogUnresponsiveAndEmpty() {
        let eligible = window(id: 1, app: "com.apple.finder", kind: .standard, title: "Secret Page")
        let waiting = window(id: 2, app: "com.apple.TextEdit", kind: .standard)
        let dialog = window(id: 3, app: "com.apple.finder", kind: .dialog)
        let otherDialog = window(id: 5, app: "com.apple.finder", kind: .dialog, membership: .other)
        let unknownDialog = window(id: 6, app: "com.apple.finder", kind: .dialog, membership: .unknown)
        let palette = window(id: 4, app: "com.apple.ActivityMonitor", kind: .palette)
        let stickyDialog = window(id: 7, app: "com.apple.finder", kind: .dialog, membership: .allSpaces)
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: [], spaceObservationAvailable: true, unobservedApps: ["com.example.hung"])
        let inspection = Inspection(snapshot: snap, targets: [eligible, waiting], excluded: [
            Exclusion(window: dialog, reason: "Dialog", code: nil),
            Exclusion(window: otherDialog, reason: "On another Space", code: nil),
            Exclusion(window: unknownDialog, reason: "Space can't be determined", code: nil),
            Exclusion(window: palette, reason: "Tool palette or floating panel", code: nil),
            Exclusion(window: stickyDialog, reason: "Appears on all Spaces", code: nil),
        ], takenAt: Date())
        let rows = ReadyWindowController.listRows(inspection, waiting: [WindowID(2)], waitingApplies: true, name: { $0 })
        XCTAssertEqual(rows.map(\.eligibility), [
            "Eligible",
            "Waiting to Join",
            "Excluded: fixed-size window",
            "Excluded: On another Space",
            "Excluded: Space can't be determined",
            "Excluded: Tool palette or floating panel",
            "Excluded: on all Spaces",
            "No Response",
        ])
        XCTAssertFalse(rows.contains { $0.eligibility.contains("Appears on all Spaces") })
        XCTAssertEqual(rows.last?.toolTip, ReadyWindowController.noResponseVerdict)
        XCTAssertFalse(rows.contains { $0.app.contains("Secret") || $0.eligibility.contains("Secret") || $0.eligibility == "Applied" || $0.eligibility == "Included" })

        let ignoredWaiting = ReadyWindowController.listRows(inspection, waiting: [WindowID(1)], waitingApplies: false, name: { $0 })
        XCTAssertEqual(ignoredWaiting[0].eligibility, "Eligible")

        let empty = Inspection(snapshot: Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: [], spaceObservationAvailable: true), targets: [], excluded: [], takenAt: Date())
        XCTAssertEqual(ReadyWindowController.listRows(empty, waiting: [], waitingApplies: true, name: { $0 }), [])
        if case .message(let text) = ReadyWindowController.presentation(empty, waiting: [], waitingApplies: true, name: { $0 }) {
            XCTAssertEqual(text, ReadyWindowController.noWindowsText)
            XCTAssertFalse(text.contains("can't be determined"))
        } else { XCTFail("known empty Space") }

        let unknown = Inspection(snapshot: Snapshot(trusted: true, spaceID: nil, workArea: .zero, windows: [], spaceObservationAvailable: false), targets: [], excluded: [], takenAt: Date())
        if case .message(let text) = ReadyWindowController.presentation(unknown, waiting: [], waitingApplies: true, name: { $0 }) {
            XCTAssertEqual(text, ReadyWindowController.unknownSpaceText)
            XCTAssertFalse(text.contains("No windows"))
        } else { XCTFail("unknown Space") }

        let retained = window(id: 9, app: "com.apple.finder", kind: .standard)
        let blockedSnap = Snapshot(trusted: false, spaceID: 1, workArea: .zero, windows: [retained], spaceObservationAvailable: true)
        let blocked = Inspection(snapshot: blockedSnap, targets: [retained], excluded: [], takenAt: Date())
        XCTAssertEqual(ReadyWindowController.listRows(blocked, waiting: [], waitingApplies: true, name: { $0 }), [])
        if case .message(let text) = ReadyWindowController.presentation(blocked, waiting: [], waitingApplies: true, name: { $0 }) {
            XCTAssertEqual(text, ReadyWindowController.windowsUnavailableText)
            XCTAssertFalse(text.contains("Eligible"))
            XCTAssertFalse(text.contains("No windows"))
        } else { XCTFail("untrusted list") }
    }

    func testRowsUseJapaneseCopy() {
        Copy.language = .japanese
        defer { Copy.language = .english }
        XCTAssertEqual(ReadyWindowController.windowTitle, "LazySpace — ウインドウの確認")
        XCTAssertEqual(ReadyWindowController.menuTitle, "ウインドウを確認…")
        XCTAssertEqual(ReadyWindowController.eligibleVerdict, "整列対象")
        XCTAssertEqual(ReadyWindowController.fixTitle, "対処を確認…")
        XCTAssertEqual(ReadyWindowController.previousTitle, "前回の操作…")
        XCTAssertEqual(ReadyWindowController.updatedLabel(checking: true, date: Date()), "確認中…")
        let dialog = window(id: 1, app: "com.apple.finder", kind: .dialog)
        XCTAssertEqual(ReadyWindowController.exclusionText(Exclusion(window: dialog, reason: "大きさが固定のウインドウ", code: nil)), "対象外：大きさが固定のウインドウ")
        let elsewhere = window(id: 2, app: "com.apple.finder", kind: .dialog, membership: .other)
        XCTAssertEqual(ReadyWindowController.exclusionText(Exclusion(window: elsewhere, reason: "別の操作スペースにある", code: nil)), "対象外：別の操作スペースにある")
        let sticky = window(id: 3, app: "com.apple.finder", kind: .dialog, membership: .allSpaces)
        XCTAssertEqual(
            ReadyWindowController.exclusionText(Exclusion(window: sticky, reason: "すべての操作スペースに表示されるウインドウ", code: nil)),
            "対象外：すべての操作スペースに表示")
        XCTAssertEqual(ReadyWindowController.noResponseShort, "応答なし")
    }

    func testAllSpacesColumnFitsTheMinimumViewport() {
        let sticky = window(id: 1, app: "com.apple.finder", kind: .dialog, membership: .allSpaces)
        let ruled = window(id: 2, app: "com.example.rules", kind: .standard)
        let longReason = String(repeating: "A very long window rule ", count: 8)
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: [], spaceObservationAvailable: true)
        let inspection = Inspection(snapshot: snap, targets: [], excluded: [
            Exclusion(window: sticky, reason: "Appears on all Spaces", code: nil),
            Exclusion(window: ruled, reason: longReason, code: nil),
        ], takenAt: Date())
        let live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        let controller = TestWindows.inspector(
            loadInspection: { $0(inspection) },
            readLive: { live },
            markReady: {},
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        controller.showWindow(nil)
        let fit = controller.testingFitAtMinimumContentWidth()
        XCTAssertGreaterThan(fit.clipWidth, 0)
        XCTAssertGreaterThan(fit.cellWidth, 0)
        XCTAssertLessThanOrEqual(fit.columnMaxX, fit.clipWidth + 0.5)
        XCTAssertLessThanOrEqual(fit.cellMaxX, fit.clipWidth + 0.5)
        XCTAssertEqual(fit.lineBreak, .byTruncatingTail)
        XCTAssertTrue(fit.texts.contains("Excluded: on all Spaces"))
        XCTAssertFalse(fit.texts.contains { $0.contains("Appears on all Spaces") })
        XCTAssertTrue(fit.texts.contains("Excluded: \(longReason)"))
        XCTAssertEqual(controller.surface().minWidth, 520)
    }

    func testWindowShowsTwoColumnsAndConditionalActions() {
        var live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var loads = 0
        var marks = 0
        let controller = TestWindows.inspector(
            loadInspection: { _ in loads += 1 },
            readLive: { live },
            markReady: { marks += 1 },
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        let surface = controller.surface()
        XCTAssertEqual(surface.title, "LazySpace — Windows")
        XCTAssertEqual(surface.header, "This Space")
        XCTAssertEqual(surface.refresh, "Refresh")
        XCTAssertEqual(surface.columnIdentifiers, ["app", "eligibility"])
        XCTAssertEqual(surface.columns, ["App", "Eligibility"])
        XCTAssertEqual(surface.contentWidth, 560)
        XCTAssertEqual(surface.contentHeight, 340)
        XCTAssertGreaterThanOrEqual(surface.minWidth, 520)
        let behavior = controller.window?.collectionBehavior ?? []
        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(surface.buttonTitles.contains("Arrange Now"))
        XCTAssertFalse(surface.buttonTitles.contains(StatusMenuCopy.globalPauseTitle(paused: false)))
        XCTAssertTrue(surface.previousHidden)
        XCTAssertTrue(surface.fixHidden)
        XCTAssertEqual(surface.reason, "")
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(marks, 0)

        live.status = inspectorStatus(autoAvailable: false, inputObservation: "unavailable")
        controller.refreshLabels()
        XCTAssertFalse(controller.surface().fixHidden)
        XCTAssertEqual(controller.surface().reason, "Input observation is unavailable.")
        XCTAssertEqual(loads, 0, "A label refresh must not read windows when the Space is unchanged and none is displayed yet")

        live.status = inspectorStatus(lastResult: operation(outcome: .partial, kind: "arrange", finished: Date()))
        controller.refreshLabels()
        XCTAssertFalse(controller.surface().previousHidden)
    }

    func testControllerDropsOutOfOrderResultsAndRetriesAMovedSpace() {
        var live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [WindowID(1)],
            status: inspectorStatus(), firstLaunchDone: false)
        var completions: [((Inspection) -> Void)] = []
        var marks = 0
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0) },
            readLive: { live },
            markReady: { marks += 1; live.firstLaunchDone = true },
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        controller.refreshTargets()
        controller.refreshTargets()
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(controller.visibleRows().map(\.app), [])
        XCTAssertEqual(controller.surface().updated, "Checking…")

        completions[0](inspection(space: 1, trusted: true, apps: ["OldApp"]))
        XCTAssertEqual(controller.visibleRows().map(\.app), [])

        completions[1](inspection(space: 1, trusted: true, apps: ["NewApp"], waitingID: 1))
        XCTAssertEqual(controller.visibleRows().map(\.eligibility), ["Waiting to Join"])
        XCTAssertEqual(controller.visibleRows().map(\.app), ["NewApp"])
        XCTAssertEqual(marks, 1)
        let cell = controller.testingCell(column: "eligibility", row: 0)
        XCTAssertEqual(cell?.textColor, .labelColor)
        XCTAssertEqual(cell?.stringValue, "Waiting to Join")

        controller.refreshTargets()
        XCTAssertEqual(completions.count, 3)
        completions[2](inspection(space: 1, trusted: true, apps: ["Again"]))
        XCTAssertEqual(marks, 1, "A later refresh must not save first-launch state again")

        live.spaceID = 2
        live.waiting = [WindowID(9)]
        controller.refreshTargets()
        XCTAssertEqual(completions.count, 4)
        completions[3](inspection(space: 1, trusted: true, apps: ["StaleSpace"]))
        XCTAssertEqual(controller.visibleRows().map(\.app), [])
        XCTAssertEqual(completions.count, 5)
        completions[4](inspection(space: 2, trusted: true, apps: ["CurrentSpace"]))
        XCTAssertEqual(controller.visibleRows().map(\.app), ["CurrentSpace"])
        XCTAssertEqual(controller.visibleRows().map(\.eligibility), ["Eligible"])
        XCTAssertFalse(controller.visibleRows().contains { $0.eligibility == "Waiting to Join" })
    }

    func testControllerHoldsAStableMismatchInsteadOfSpinning() {
        let live = WindowInspectLive(
            spaceID: nil, trusted: true, spaceObservationAvailable: false, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var completions: [((Inspection) -> Void)] = []
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0) },
            readLive: { live },
            markReady: {},
            openGeneralSettings: {},
            openAccessSettings: {})
        controller.refreshTargets()
        completions[0](inspection(space: 4, trusted: true, apps: ["Unexpected"]))
        XCTAssertEqual(completions.count, 2)
        completions[1](inspection(space: 4, trusted: true, apps: ["Unexpected"]))
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(controller.visibleRows().map(\.app), [])
        XCTAssertEqual(controller.surface().emptyMessage, ReadyWindowController.mismatchText)
        XCTAssertFalse(controller.surface().emptyMessage.contains("Unexpected"))
        controller.close()
    }

    func testShownLabelsReloadOnlyWhenSpaceOrTrustChanges() {
        var live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var loads = 0
        var access = 0
        var completions: [(Inspection) -> Void] = []
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0); loads += 1 },
            readLive: { live },
            markReady: {},
            openGeneralSettings: { access += 1 },
            openAccessSettings: {})
        defer { controller.close() }
        controller.testingTimerFired()
        XCTAssertEqual(loads, 0, "A hidden inspector must not read status on the timer")
        controller.showWindow(nil)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(access, 0)
        completions[0](inspection(space: 1, trusted: true, apps: ["Finder"]))
        controller.refreshLabels()
        controller.testingSpaceChanged()
        XCTAssertEqual(loads, 1, "The same Space and permission must not start another read")
        live.spaceID = 8
        controller.refreshLabels()
        XCTAssertEqual(loads, 2)
        completions[1](inspection(space: 8, trusted: true, apps: ["Moved"]))
        XCTAssertEqual(controller.visibleRows().map(\.app), ["Moved"])
        live.trusted = false
        live.status = inspectorStatus(trusted: false, manualAvailable: false, autoAvailable: false)
        controller.testingSpaceChanged()
        XCTAssertEqual(loads, 3)
        completions[2](inspection(space: 8, trusted: false, apps: ["HiddenEligible"]))
        XCTAssertTrue(controller.visibleRows().isEmpty)
        XCTAssertEqual(controller.surface().emptyMessage, ReadyWindowController.windowsUnavailableText)
        XCTAssertFalse(controller.surface().emptyMessage.contains("Eligible"))
        controller.refreshTargets()
        XCTAssertEqual(access, 0)
    }

    func testRecoveredSpaceObservationReplacesAnUnavailableResult() {
        var live = WindowInspectLive(
            spaceID: nil, trusted: true, spaceObservationAvailable: false, waiting: [],
            status: inspectorStatus(spaceObservation: false), firstLaunchDone: false)
        var completions: [(Inspection) -> Void] = []
        var marks = 0
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0) },
            readLive: { live },
            markReady: { marks += 1; live.firstLaunchDone = true },
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        controller.refreshTargets()
        completions[0](inspection(space: nil, trusted: true, apps: [], spaceObservation: false))
        XCTAssertEqual(marks, 0)
        XCTAssertEqual(controller.surface().emptyMessage, ReadyWindowController.unknownSpaceText)
        XCTAssertFalse(controller.surface().emptyMessage.contains("No windows"))

        controller.refreshTargets()
        live.spaceID = 3
        live.spaceObservationAvailable = true
        live.status = inspectorStatus()
        completions[1](inspection(space: nil, trusted: true, apps: ["Stale"], spaceObservation: false))
        XCTAssertTrue(controller.visibleRows().isEmpty)
        XCTAssertFalse(controller.visibleRows().contains { $0.eligibility == "Eligible" })
        XCTAssertEqual(completions.count, 3)
        completions[2](inspection(space: 3, trusted: true, apps: ["Now"], spaceObservation: true))
        XCTAssertEqual(controller.visibleRows().map(\.app), ["Now"])
        XCTAssertEqual(marks, 1)
    }

    func testDetailSheetKeepsLongTextSelectableAndCloseIsDefault() {
        let failed = inspectorStatus(autoAvailable: false, inputObservation: "unavailable")
        let body = String(repeating: "Recorded target note.\n", count: 40)
        let sheet = DetailSheet.assemble(
            title: ReadyWindowController.remediationSheetTitle,
            body: body,
            choices: ReadyWindowController.remediationChoices(failed))
        XCTAssertEqual(sheet.alert.messageText, "Resolve Arrangement Issue")
        XCTAssertEqual(sheet.alert.buttons.first?.title, "Close")
        XCTAssertEqual(sheet.actions[.alertFirstButtonReturn], .close)
        XCTAssertEqual(sheet.actions[.alertSecondButtonReturn], .openSettings)
        XCTAssertEqual(sheet.alert.buttons.first?.keyEquivalent, "\r")
        XCTAssertEqual(sheet.alert.buttons.dropFirst().first?.keyEquivalent, "")
        XCTAssertNotEqual(sheet.alert.buttons.first?.keyEquivalent, "\u{1b}")
        XCTAssertTrue(sheet.alert.window.defaultButtonCell === (sheet.alert.buttons.first?.cell as? NSButtonCell))
        guard let close = sheet.actions.first(where: { $0.value == .close })?.key else {
            XCTFail("missing Close response")
            return
        }
        let sheetWindow = sheet.alert.window
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        TestWindows.conceal(other)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertEqual(DetailSheet.escapeResponse(
            keyCode: 53, characters: "\u{1b}", modifiers: [], eventWindow: sheetWindow, keyWindow: other, sheet: sheetWindow, close: close), close)
        XCTAssertEqual(DetailSheet.escapeResponse(
            keyCode: 53, characters: "\u{1b}", modifiers: [], eventWindow: nil, keyWindow: sheetWindow, sheet: sheetWindow, close: close), close)
        XCTAssertNil(DetailSheet.escapeResponse(
            keyCode: 53, characters: "\u{1b}", modifiers: [], eventWindow: other, keyWindow: sheetWindow, sheet: sheetWindow, close: close))
        XCTAssertNil(DetailSheet.escapeResponse(
            keyCode: 53, characters: "\u{1b}", modifiers: [], eventWindow: nil, keyWindow: other, sheet: sheetWindow, close: close))
        XCTAssertNil(DetailSheet.escapeResponse(
            keyCode: 53, characters: "\u{1b}", modifiers: .command, eventWindow: sheetWindow, keyWindow: sheetWindow, sheet: sheetWindow, close: close))
        XCTAssertNil(DetailSheet.escapeResponse(
            keyCode: 0, characters: "a", modifiers: [], eventWindow: sheetWindow, keyWindow: sheetWindow, sheet: sheetWindow, close: close))
        let scroll = sheet.alert.accessoryView as? NSScrollView
        XCTAssertEqual(scroll?.frame.width, 480)
        XCTAssertEqual(scroll?.frame.height, 240)
        let text = scroll?.documentView as? NSTextView
        XCTAssertEqual(text?.string, body)
        XCTAssertEqual(text?.isSelectable, true)
        XCTAssertEqual(text?.isEditable, false)
        XCTAssertEqual(text?.font, .systemFont(ofSize: NSFont.systemFontSize))
        XCTAssertEqual(text?.textColor, .labelColor)
        XCTAssertTrue(text?.autoresizingMask.contains(.width) == true)
        XCTAssertEqual(text?.frame.width ?? -1, scroll?.contentSize.width ?? -2)
        XCTAssertFalse(ReadyWindowController.remediationChoices(failed).contains { $0.kind == .openGeneralSettings })
    }

    func testClosingDropsALateMismatchWithoutAnotherRead() {
        let live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var completions: [(Inspection) -> Void] = []
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0) },
            readLive: { live },
            markReady: {},
            openGeneralSettings: {},
            openAccessSettings: {})
        let window = controller.window
        controller.showWindow(nil)
        XCTAssertEqual(completions.count, 1)
        controller.close()
        completions[0](inspection(space: 9, trusted: true, apps: ["Late"]))
        XCTAssertEqual(completions.count, 1)
        XCTAssertTrue(controller.visibleRows().isEmpty)
        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(completions.count, 2)
        controller.close()
    }

    /// The 1 s check runs only while the window is shown: no timer before showing or after closing. Reopening starts exactly one and reads the list at once.
    func testPollTimerRunsOnlyBetweenShowAndClose() {
        let live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var loads = 0
        let controller = TestWindows.inspector(
            loadInspection: { _ in loads += 1 },
            readLive: { live },
            markReady: {},
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        XCTAssertNil(controller.testingPollTimer)
        controller.showWindow(nil)
        let first = controller.testingPollTimer
        XCTAssertEqual(first?.isValid, true)
        controller.showWindow(nil)
        XCTAssertTrue(controller.testingPollTimer === first, "showing again keeps the one timer")
        controller.close()
        XCTAssertNil(controller.testingPollTimer)
        XCTAssertEqual(first?.isValid, false)
        let before = loads
        controller.showWindow(nil)
        XCTAssertEqual(controller.testingPollTimer?.isValid, true)
        XCTAssertFalse(controller.testingPollTimer === first)
        XCTAssertEqual(loads, before + 1, "reopening reads the list at once, as on first show")
    }

    /// A list requested before closing is neither used nor re-read when it arrives after reopening; a list requested after reopening is used.
    func testAResultRequestedBeforeCloseIsDroppedAfterReopening() {
        let live = WindowInspectLive(
            spaceID: 1, trusted: true, spaceObservationAvailable: true, waiting: [],
            status: inspectorStatus(), firstLaunchDone: true)
        var completions: [(Inspection) -> Void] = []
        let controller = TestWindows.inspector(
            loadInspection: { completions.append($0) },
            readLive: { live },
            markReady: {},
            openGeneralSettings: {},
            openAccessSettings: {})
        defer { controller.close() }
        controller.showWindow(nil)
        controller.close()
        controller.showWindow(nil)
        XCTAssertEqual(completions.count, 2)
        completions[0](inspection(space: 1, trusted: true, apps: ["Late"]))
        XCTAssertEqual(completions.count, 2)
        XCTAssertTrue(controller.visibleRows().isEmpty)
        completions[1](inspection(space: 1, trusted: true, apps: ["Current"]))
        XCTAssertEqual(completions.count, 2)
        XCTAssertFalse(controller.visibleRows().isEmpty)
    }
}

private func inspectorStatus(
    trusted: Bool = true,
    manualAvailable: Bool = true,
    autoAvailable: Bool = true,
    paused: Bool = false,
    currentSpaceAutoPaused: Bool = false,
    spaceObservation: Bool? = nil,
    inputObservation: String = "mouseAndKeyboard",
    lastResult: OperationResult? = nil,
    manualReason: String = "Available",
    autoReason: String = "Available"
) -> AppStatus {
    AppStatus(
        availability: autoAvailable ? .automatic : .manualOnly,
        availabilityReason: autoReason,
        manualAvailable: manualAvailable,
        manualReason: manualReason,
        autoAvailable: autoAvailable,
        autoReason: autoReason,
        currentSpaceManaged: false,
        trusted: trusted,
        spaceObservation: spaceObservation ?? manualAvailable,
        inputObservation: inputObservation,
        paused: paused,
        progress: .idle,
        progressText: "",
        waiting: [],
        floating: [],
        zoomed: nil,
        lastRefusal: nil,
        configPath: "/tmp/config.toml",
        configError: nil,
        focusedWindow: nil,
        lastResult: lastResult,
        version: "0.4.0",
        mode: "main",
        modes: ["main"],
        loginItem: "Off",
        loginItemEnabled: false,
        currentSpaceAutoPaused: currentSpaceAutoPaused)
}

private func operation(
    outcome: Outcome,
    kind: String,
    finished: Date,
    spaceID: UInt64? = 1,
    message: String = "Recorded",
    targets: [TargetReport] = []
) -> OperationResult {
    OperationResult(
        id: kind + outcomeTitle(outcome), kind: kind, startedAt: finished, finishedAt: finished,
        outcome: outcome, stopReason: nil, spaceID: spaceID, workArea: .zero,
        targets: targets, excluded: [], issued: targets.count, retries: 0, verified: false,
        maxWriteMs: 0, wallMs: 0, message: message, tolerance: 1, rows: 0, unobservedApps: [])
}

private func outcomeTitle(_ outcome: Outcome) -> String {
    switch outcome {
    case .complete: return "complete"
    case .partial: return "partial"
    case .interrupted: return "interrupted"
    case .notPossible: return "not-possible"
    case .nothingToDo: return "nothing"
    }
}

private func window(id: UInt32, app: String, kind: ObservedWindow.Kind, membership: ObservedWindow.Membership = .current, title: String = "") -> ObservedWindow {
    ObservedWindow(id: WindowID(id), pid: 1, app: app, frame: .zero, membership: membership, kind: kind, detail: "", title: title)
}

private func inspection(space: UInt64?, trusted: Bool, apps: [String], waitingID: UInt32? = nil, spaceObservation: Bool? = nil) -> Inspection {
    let targets = apps.enumerated().map { index, app in
        window(id: waitingID ?? UInt32(index + 1), app: app, kind: .standard)
    }
    let snap = Snapshot(
        trusted: trusted, spaceID: space, workArea: .zero, windows: targets,
        spaceObservationAvailable: spaceObservation ?? (space != nil))
    return Inspection(snapshot: snap, targets: targets, excluded: [], takenAt: Date())
}
