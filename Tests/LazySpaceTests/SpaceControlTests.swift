import XCTest
import CoreGraphics
import Copy
@testable import MacSupport
import Operations

private final class SpacesStub: SpaceObserving {
    var active: UInt64? = 1
    var membership: [UInt64] = [1]
    /// Order of Spaces on the same display. IDs are consecutive (one synthetic key moves by ±1).
    var order: [UInt64] = [1, 2, 3]
    var spaceTypes: [Int32] = [0, 0, 0]
    /// Runs during a membership query (to simulate input or a switch).
    var onMembershipRead: ((CGWindowID) -> Void)?
    private let readLock = NSLock()
    private var activeReadCount = 0
    /// May be read concurrently (activation gates that run later), so only the counting is lock-protected.
    var activeReads: Int { readLock.lock(); defer { readLock.unlock() }; return activeReadCount }
    /// Called right before the n-th read (to simulate the user switching between reads).
    var activeHook: ((Int) -> Void)?
    func activeSpace() -> UInt64? {
        readLock.lock(); activeReadCount += 1; let n = activeReadCount; readLock.unlock()
        activeHook?(n)
        return active
    }
    func spaces(for windowID: CGWindowID) -> [UInt64] { onMembershipRead?(windowID); return membership }
    func isOrderedIn(_ windowID: CGWindowID) -> Bool? { nil }
    /// A second display's desktops (the first one shown there), for moves across displays.
    var secondDisplay: [UInt64] = []
    func managedDisplays() -> [SpaceObserver.ManagedDisplay] {
        let first = SpaceObserver.ManagedDisplay(display: "test", currentSpace: order.contains(active ?? 0) ? active : order.first, spaces: order, spaceTypes: spaceTypes)
        guard !secondDisplay.isEmpty else { return [first] }
        let shown = secondDisplay.contains(active ?? 0) ? active : secondDisplay.first
        return [first, .init(display: "second", currentSpace: shown, spaces: secondDisplay, spaceTypes: secondDisplay.map { _ in 0 })]
    }
}

/// An observer with per-window membership (to test candidate selection). active and order come from the original stub.
private final class SpacesStubByWindow: SpaceObserving {
    let base: SpacesStub
    let membership: (CGWindowID) -> [UInt64]
    /// Whether each window is ordered in (false: kept ordered out, like a closed settings window still listed on a Space; nil: unknown).
    var ordered: (CGWindowID) -> Bool? = { _ in true }
    init(_ base: SpacesStub, membership: @escaping (CGWindowID) -> [UInt64]) { self.base = base; self.membership = membership }
    func activeSpace() -> UInt64? { base.activeSpace() }
    func spaces(for windowID: CGWindowID) -> [UInt64] { membership(windowID) }
    func isOrderedIn(_ windowID: CGWindowID) -> Bool? { ordered(windowID) }
    func managedDisplays() -> [SpaceObserver.ManagedDisplay] { base.managedDisplays() }
}

/// Replacement tap holding only its readiness and enabled state. The real `PassThroughFilter` decides swallowing and evidence.
private final class StubPassThroughTap: PassThroughTap {
    let filter: PassThroughFilter
    var current: PassThroughTapState = .idle
    /// Becomes ready on `start` (false stays `starting`).
    var readyOnStart = true
    var failOnStart = false
    var enabled = true
    var starts = 0
    init(now: @escaping () -> Date) { filter = PassThroughFilter(now: now) }
    var state: PassThroughTapState { current }
    var isEnabled: Bool { enabled && current == .ready }
    func start() {
        starts += 1
        guard current == .idle || current == .failed else { return }
        current = failOnStart ? .failed : readyOnStart ? .ready : .starting
    }
}

private final class SpaceHarness {
    let spaces = SpacesStub()
    var time = Date(timeIntervalSince1970: 0)
    var inputs: UInt64 = 0
    var inputAvailable = true
    var allowed = true
    var events: [CGEvent] = []
    /// Keys at the moment of posting; modifiers become flagsChanged.
    var posted: [(type: UInt32, code: Int64, flags: UInt64)] = []
    var warps: [CGPoint] = []
    var onSleep: ((TimeInterval) -> Void)?
    var onPost: ((CGEvent) -> Void)?
    var switchOnArrow = true
    var rightKey: Int64 = 124
    var leftKey: Int64 = 123
    var hotkeyReads: [Int32] = []
    /// The real Mission Control settings are not read. The default is Control+Fn with left/right arrows, as the probe saw.
    var hotkey: (Int32) -> PrivateSymbols.SymbolicHotKey = { id in
        switch id {
        case 81: return .enabled(keyCode: 124, flags: 0x0084_0000)
        case 79: return .enabled(keyCode: 123, flags: 0x0084_0000)
        default: return .unknown
        }
    }
    var conflicts: (UInt16, CGEventFlags) -> Bool = { _, _ in false }
    /// The front app (hand-off observation).
    var frontmost: pid_t?
    var focused: CGWindowID?
    var onFocusRead: (() -> Void)?
    /// How many times app candidates were collected (to confirm they are collected lazily).
    var appCollections = 0
    /// The pass-through tap, ready by default (every hotkey post goes through it).
    lazy var tap = StubPassThroughTap(now: { self.time })
    let cursor = CGPoint(x: 900, y: 600)
    lazy var control = SpaceControl(spaces: spaces, inputCount: { self.inputs }, inputAvailable: { self.inputAvailable }, now: { self.time },
        sleep: { self.time.addTimeInterval($0); self.onSleep?($0) }, cursorPosition: { self.cursor },
        warpCursor: { self.warps.append($0) }, postEvent: { event in
            self.events.append(event)
            if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
                self.posted.append((event.type.rawValue, event.getIntegerValueField(.keyboardEventKeycode), event.flags.rawValue))
            }
            if self.switchOnArrow, event.type == .keyDown {
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                if key == self.rightKey { self.spaces.active = (self.spaces.active ?? 0) + 1 }
                if key == self.leftKey { self.spaces.active = (self.spaces.active ?? 2) - 1 }
            }
            if event.type == .leftMouseUp { self.spaces.membership = self.spaces.active.map { [$0] } ?? [] }
            self.onPost?(event)
        }, hotkey: { id in
            self.hotkeyReads.append(id)
            return self.hotkey(id)
        }, commandConflicts: { code, flags in self.conflicts(code, flags) }, frontmostPID: { self.frontmost }, passThroughTap: tap)
    /// A control with the same replacements but a different observer.
    func control(with observer: SpaceObserving) -> SpaceControl {
        SpaceControl(spaces: observer, inputCount: { self.inputs }, inputAvailable: { self.inputAvailable }, now: { self.time },
                     sleep: { self.time.addTimeInterval($0); self.onSleep?($0) }, cursorPosition: { self.cursor },
                     warpCursor: { self.warps.append($0) }, postEvent: { self.events.append($0) },
                     hotkey: { id in self.hotkeyReads.append(id); return self.hotkey(id) }, commandConflicts: { _, _ in false }, frontmostPID: { self.frontmost }, passThroughTap: tap)
    }
    /// Passes window candidates as is and app candidates lazily (as Coordinator does). `onCollect` simulates something during collection.
    func switchSpace(_ target: UInt64, _ table: [UInt64: [SpaceControl.Candidate]], hop: Bool = true, source: UInt64? = nil, hotkey: SpaceControl.HotkeyPlan? = nil,
                     arrows: SpaceControl.ArrowPolicy? = nil,
                     onCollect: (() -> Void)? = nil, shouldContinue: @escaping () -> Bool = { true }) -> Result<SpaceControl.Result, SpaceControl.Failure> {
        let windows = table.mapValues { $0.filter { if case .window = $0 { return true } else { return false } } }
        let apps = table.mapValues { $0.filter { if case .app = $0 { return true } else { return false } } }
        let plan = SpaceControl.SwitchPlan(source: source, windows: windows, apps: { self.appCollections += 1; onCollect?(); return apps }, hopAllowed: hop,
                                           hotkey: hotkey, arrows: arrows)
        return control.switchTo(spaceID: target, plan: plan, shouldContinue: shouldContinue)
    }
    func move(to space: UInt64 = 2, follow: SpaceControl.HotkeyPlan? = nil, arrows: SpaceControl.ArrowPolicy? = nil) -> Result<SpaceControl.Result, SpaceControl.Failure> {
        control.moveWindow(10, frame: Self.frame, toSpace: space, follow: follow, arrows: arrows, shouldContinue: { self.allowed })
    }
    static let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
    static var grab: CGPoint { CGPoint(x: frame.midX, y: frame.minY + 6) }
}

final class SpaceControlTests: XCTestCase {
    // MARK: - Direct path (membership change -> activation)

    /// A direct path that counts sends, raises, and reactivations and replaces how they affect the observer.
    private final class DirectStub {
        var moves: [(CGWindowID, UInt64)] = []
        var raises: [CGWindowID] = []
        var reactivates: [CGWindowID] = []
        var activations: [(pid: pid_t, bundleID: String, target: UInt64)] = []
        var lastIsCurrent: (() -> Bool)?
        var lastMayBegin: (() -> Bool)?
        var lastMayFinish: (() -> Bool)?
        var lastReport: ((SpaceControl.ActivationStage) -> Void)?
        var lastRaiseReport: ((SpaceControl.ActivationStage) -> Void)?
        /// raise reports its queued activation as requested at once (false: the test reports later through `lastRaiseReport`). The window's app is 700.
        var raiseReports = true
        var moveIssued = true
        var moveChangesMembership = true
        var raiseSwitches = true
        var raiseOutcome = SpaceControl.RaiseOutcome.issued
        var reactivateSwitches = true
        /// Apps that queue nothing after rechecking (`notIssued`).
        var ineligibleApps: Set<pid_t> = []
        /// Queued, but the main-thread stage does not run (the test drives it later through `lastMayBegin` and the like).
        var holdActivation = false
        var activationSwitches = true
        // Tier 0 (Desktop N shortcuts)
        var tap: StubPassThroughTap!
        /// The requested activation takes effect and the app comes forward.
        var activationTakesEffect = true
        var focusTakesEffect = true
        var reactivateReports = true
        func path(_ h: SpaceHarness) -> SpaceControl.DirectPath {
            tap = h.tap
            return SpaceControl.DirectPath(move: { wid, space in
                self.moves.append((wid, space))
                if self.moveIssued, self.moveChangesMembership { h.spaces.membership = [space] }
                return self.moveIssued
            }, raise: { wid, isCurrent, report in
                self.raises.append(wid)
                self.lastIsCurrent = isCurrent
                self.lastRaiseReport = report
                if self.raiseReports { report(.requested(700)); if self.activationTakesEffect { h.frontmost = 700 } }
                if self.focusTakesEffect { h.focused = wid }
                if self.raiseSwitches { h.spaces.active = h.spaces.membership.first }
                return self.raiseOutcome
            }, reactivate: { wid, mayBegin, mayFinish, report in
                self.reactivates.append(wid)
                self.lastMayBegin = mayBegin
                self.lastMayFinish = mayFinish
                self.lastIsCurrent = mayFinish
                self.lastReport = report
                report(.began)
                if self.reactivateSwitches { h.spaces.active = h.spaces.membership.first }
                if self.reactivateReports { report(.requested(700)) }
                if self.activationTakesEffect { h.frontmost = 700 }
                if self.focusTakesEffect { h.focused = wid }
            }, activateApp: { pid, bundleID, target, mayBegin, mayFinish, report in
                self.activations.append((pid, bundleID, target))
                self.lastMayBegin = mayBegin
                self.lastMayFinish = mayFinish
                self.lastReport = report
                if self.ineligibleApps.contains(pid) { return .notIssued }
                if self.holdActivation { return .unknown }
                guard mayBegin() else { report(.declined); return .unknown }
                report(.began)
                guard mayFinish() else { report(.abandoned); return .unknown }
                if self.activationSwitches { h.spaces.active = target }
                report(.requested(pid))
                if self.activationTakesEffect { h.frontmost = pid }
                return .unknown
            }, focusedWindow: {
                let focused = h.focused
                h.onFocusRead?()
                return focused
            })
        }
    }

    /// If the Space changes without input during the preflight right before mouse-down (reading settings), the window is not grabbed.
    func testSpaceChangeDuringTheFinalMouseDownPreflightPreventsTheGrab() {
        let h = SpaceHarness()
        var flippedAfterMouseMoved = false
        let policy = SpaceControl.ArrowPolicy(stillEligible: {
            // The preflight (prepareArrow) is before mouseMoved; the read after mouseMoved is arrowUnusable right before mouse-down.
            if !flippedAfterMouseMoved, h.events.contains(where: { $0.type == .mouseMoved }) {
                flippedAfterMouseMoved = true
                h.spaces.active = 3 // the user switched while settings were read (not counted as input)
            }
            return true
        })
        XCTAssertEqual(h.move(to: 2, arrows: policy), .failure(.interrupted))
        XCTAssertTrue(flippedAfterMouseMoved, "the change happened during the final preflight, after the cursor was moved")
        XCTAssertFalse(h.events.contains { $0.type == .leftMouseDown }, "no window is grabbed on the wrong Space")
        XCTAssertFalse(h.events.contains { $0.type == .keyDown })
    }

    func testDirectPathMovesWithoutSyntheticInputAndFollows() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        let result = try h.move(to: 3).get()
        XCTAssertEqual(result.toSpace, 3)
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(h.spaces.active, 3)
        XCTAssertEqual(h.spaces.membership, [3])
        XCTAssertEqual(d.moves.map { $0.1 }, [3])
        XCTAssertEqual(d.raises, [10])
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertTrue(h.events.isEmpty, "direct path must not post keys or mouse")
        XCTAssertTrue(h.warps.isEmpty)
        XCTAssertTrue(h.hotkeyReads.isEmpty, "direct path does not read Mission Control shortcuts")
    }

    func testMoveFollowRequiresTheMovedWindowAndCompletedActivation() {
        for mode in ["wrong window", "unreadable focus", "wrong app", "app changed during read", "raise pending", "reactivate pending"] {
            let h = SpaceHarness(); let d = DirectStub()
            h.control.direct = d.path(h)
            switch mode {
            case "wrong window": d.focusTakesEffect = false; h.focused = 11
            case "unreadable focus": d.focusTakesEffect = false
            case "wrong app": d.activationTakesEffect = false; h.frontmost = 701
            case "app changed during read": h.onFocusRead = { h.frontmost = 701 }
            case "raise pending": d.raiseReports = false; h.frontmost = 700
            default: d.raiseSwitches = false; d.reactivateReports = false
            }
            XCTAssertEqual(h.move(to: 2), .failure(.frontUnconfirmed), mode)
            XCTAssertEqual(h.spaces.active, 2, mode)
            XCTAssertEqual(h.spaces.membership, [2], mode)
            XCTAssertTrue(h.events.isEmpty, "\(mode): no shortcut retry or drag")
            XCTAssertEqual(d.lastIsCurrent?(), false, "\(mode): queued work expires")
        }
    }

    func testMoveFollowWaitsForDelayedFocusWithoutRaisingAnotherWindow() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseReports = false; d.focusTakesEffect = false
        h.control.direct = d.path(h)
        h.frontmost = 700; h.focused = 11
        h.onSleep = { interval in
            if interval == 0.02, h.time.timeIntervalSince1970 >= 0.12 {
                d.lastRaiseReport?(.requested(700)); h.focused = 10
            }
        }
        XCTAssertEqual(try h.move(to: 2).get().toSpace, 2)
        XCTAssertEqual(d.raises, [10])
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    /// Even after AXRaise times out, if the target window comes forward late, observation confirms completion.
    func testMoveFollowAcceptsDelayedFocusAfterActivationWasAbandoned() throws {
        for terminal in [SpaceControl.ActivationStage.abandoned, .declined] {
            let h = SpaceHarness(); let d = DirectStub()
            var path = d.path(h)
            path.raise = { _, _, report in report(terminal); return .unknown }
            h.control.direct = path
            h.onSleep = { _ in
                if h.time.timeIntervalSince1970 >= 0.12 { h.spaces.active = 2; h.frontmost = 700 }
                if h.time.timeIntervalSince1970 >= 0.20 { h.focused = 10 }
            }
            XCTAssertEqual(try h.move(to: 2).get().toSpace, 2)
            XCTAssertGreaterThanOrEqual(h.time.timeIntervalSince1970, 0.20)
            XCTAssertTrue(d.reactivates.isEmpty)
            XCTAssertTrue(h.events.isEmpty)
        }
    }

    func testMoveFollowObservesLateRaiseWhenReactivationEndsWithoutARequest() throws {
        for terminal in [SpaceControl.ActivationStage.declined, .abandoned] {
            let h = SpaceHarness(); let d = DirectStub()
            var path = d.path(h)
            path.raise = { _, _, report in report(.abandoned); return .unknown }
            path.reactivate = { _, _, _, report in
                // The original AXRaise took effect right before the workaround started, or after we came forward.
                if case .abandoned = terminal { report(.began) }
                h.spaces.active = 2; h.frontmost = 700; h.focused = 10
                report(terminal)
            }
            h.control.direct = path
            XCTAssertEqual(try h.move(to: 2).get().toSpace, 2)
            XCTAssertTrue(h.events.isEmpty)
        }
    }

    func testAbandonedMoveActivationStillRequiresStableFocusAndAuthorization() {
        for mode in ["wrong window", "unreadable", "front changed", "input", "space"] {
            let h = SpaceHarness(); let d = DirectStub()
            var path = d.path(h)
            path.raise = { _, _, report in
                h.spaces.active = 2; h.frontmost = 700
                h.focused = mode == "wrong window" ? 11 : mode == "unreadable" ? nil : 10
                report(.abandoned)
                return .unknown
            }
            h.control.direct = path
            h.onFocusRead = {
                if mode == "front changed" { h.frontmost = h.frontmost == 700 ? 701 : 700 }
                if mode == "input" { h.inputs += 1 }
                if mode == "space" { h.spaces.active = 3 }
            }
            let expected: SpaceControl.Failure = mode == "input" || mode == "space" ? .interrupted : .frontUnconfirmed
            XCTAssertEqual(h.move(to: 2), .failure(expected), mode)
            XCTAssertTrue(h.events.isEmpty)
            XCTAssertTrue(d.reactivates.isEmpty)
        }
    }

    func testMoveReactivationAndFocusShareOneConfirmationDeadline() {
        let h = SpaceHarness(); let d = DirectStub()
        d.raiseSwitches = false; d.reactivateReports = false; d.focusTakesEffect = false
        var path = d.path(h)
        let reactivate = path.reactivate
        var arrivedAt: Date?
        path.reactivate = { wid, mayBegin, mayFinish, report in
            reactivate(wid, mayBegin, mayFinish, report)
            h.frontmost = 999; h.focused = 11
            arrivedAt = h.time
        }
        h.control.direct = path
        h.onSleep = { _ in
            if let arrivedAt, h.time.timeIntervalSince(arrivedAt) >= 1.20 {
                d.lastReport?(.requested(700)); h.frontmost = 700
                // The app came back, but focus stays on another window.
            }
        }
        XCTAssertEqual(h.move(to: 2), .failure(.frontUnconfirmed))
        XCTAssertNotNil(arrivedAt)
        XCTAssertLessThanOrEqual(h.time.timeIntervalSince(arrivedAt ?? h.time), 1.55)
        XCTAssertEqual(d.lastMayFinish?(), false)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testMoveFollowFinishesBeforeTypingAfterConfirmedFocus() throws {
        for reactivate in [false, true] {
            let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = !reactivate
            h.control.direct = d.path(h)
            var focusedAt: Date?
            h.onFocusRead = { if focusedAt == nil { focusedAt = h.time } }
            h.onSleep = { _ in
                if let focusedAt, h.time.timeIntervalSince(focusedAt) >= 0.15 { h.inputs += 1 }
            }
            XCTAssertEqual(try h.move(to: 2).get().toSpace, 2)
            XCTAssertNotNil(focusedAt)
            XCTAssertLessThan(h.time.timeIntervalSince(focusedAt ?? h.time), 0.15)
            XCTAssertTrue(h.events.isEmpty)
        }
    }

    func testMoveFollowDoesNotIgnoreInputOrSpaceChangesDuringFocusRead() {
        for mode in ["input", "space", "final input"] {
            let h = SpaceHarness(); let d = DirectStub()
            h.control.direct = d.path(h)
            var reads = 0
            h.onFocusRead = {
                reads += 1
                if mode == "input" || (mode == "final input" && reads == 2) { h.inputs += 1 }
                if mode == "space" { h.spaces.active = 3 }
            }
            XCTAssertEqual(h.move(to: 2), .failure(.interrupted), mode)
            XCTAssertTrue(h.events.isEmpty, mode)
            XCTAssertTrue(d.reactivates.isEmpty, mode)
        }
    }

    func testMoveFollowRechecksFocusAfterSettling() {
        let h = SpaceHarness(); let d = DirectStub(); h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        h.onSleep = { interval in if interval == 0.3 { h.focused = 11 } }
        XCTAssertEqual(h.move(to: 2), .failure(.frontUnconfirmed))
        XCTAssertTrue(h.events.isEmpty)
    }

    func testMoveFollowRechecksMembershipAfterObservedFocusWithoutASettle() {
        for membership: [UInt64] in [[3], [], [1, 2]] {
            let h = SpaceHarness(); let d = DirectStub(); h.control.direct = d.path(h)
            h.onFocusRead = { h.spaces.membership = membership }
            let expected: SpaceControl.Failure = membership.isEmpty ? .membershipUnreadable :
                membership.count > 1 ? .onSeveralSpaces(membership) : .movedElsewhere(to: 3)
            XCTAssertEqual(h.move(to: 2), .failure(expected))
            XCTAssertEqual(d.lastIsCurrent?(), false)
            XCTAssertTrue(h.events.isEmpty)
        }
    }

    func testMoveFollowCannotActivateAWindowThatLeftTheDestination() {
        let h = SpaceHarness(); let d = DirectStub(); h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        h.onSleep = { interval in
            if interval == 0.3 {
                h.spaces.membership = [3]
                XCTAssertEqual(d.lastIsCurrent?(), false)
            }
        }
        XCTAssertEqual(h.move(to: 2), .failure(.movedElsewhere(to: 3)))
        XCTAssertTrue(h.events.isEmpty)
    }

    func testMoveFollowUsesOriginalRaiseWhenLateArrivalPreventsReactivation() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        var path = d.path(h)
        path.reactivate = { _, mayBegin, _, report in
            h.spaces.active = 2
            XCTAssertFalse(mayBegin())
            report(.declined)
        }
        h.control.direct = path
        XCTAssertEqual(try h.move(to: 2).get().toSpace, 2)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDirectPathFallsBackToSteppingWhenNothingWasSent() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.moveIssued = false
        h.control.direct = d.path(h)
        let result = try h.move(to: 2).get()
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(h.spaces.membership, [2])
        XCTAssertTrue(h.events.contains { $0.type == .leftMouseDown })
        XCTAssertEqual(Set(h.hotkeyReads), [81], "re-read before every key-down, only this direction")
    }

    /// After sending the request, never fall back to dragging, to avoid a late move and the drag grabbing different windows.
    func testDirectPathDoesNotDragAfterAnUnconfirmedRequest() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        let before = h.time
        XCTAssertEqual(h.move(to: 2), .failure(.moveUnconfirmed))
        XCTAssertEqual(d.moves.count, 1)
        XCTAssertTrue(d.raises.isEmpty, "a window that did not move is not raised")
        XCTAssertGreaterThanOrEqual(h.time.timeIntervalSince(before), 1.0, "waits for the asynchronous move before giving up")
        XCTAssertTrue(h.events.isEmpty, "no synthetic input after the request was sent")
        XCTAssertTrue(h.warps.isEmpty)
        XCTAssertEqual(h.spaces.membership, [1])
        let detail = h.control.failureDetail(.moveUnconfirmed) ?? ""
        XCTAssertTrue(detail.contains("Desktop 1"), detail)
    }

    func testDirectPathAcceptsALateMembershipChange() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        var polls = 0
        h.onSleep = { interval in if interval == 0.02 { polls += 1; if polls == 5 { h.spaces.membership = [2] } } }
        XCTAssertEqual(try h.move(to: 2).get().steps, 0)
        XCTAssertEqual(d.raises, [10])
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUserInputWhileWaitingForTheMoveInterruptsBeforeRaising() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.inputs += 1 } }
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUserSwitchingSpacesWhileWaitingForTheMoveInterrupts() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.active = 3 } }
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUserSwitchingToAThirdSpaceWhileFollowingInterrupts() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.active = 3 } }
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertEqual(d.raises, [10])
        XCTAssertTrue(d.reactivates.isEmpty)
    }

    func testReactivationIsNoLongerCurrentOnceTheOperationReturned() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false
        h.control.direct = d.path(h)
        XCTAssertEqual(h.move(to: 3), .failure(.notSwitched))
        let isCurrent = try? XCTUnwrap(d.lastIsCurrent)
        XCTAssertEqual(isCurrent?(), false, "a queued activation must do nothing after the operation ended")
    }

    func testReactivationIsNotCurrentAfterUserInput() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        d.reactivateSwitches = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02, !d.reactivates.isEmpty { h.inputs += 1 } }
        XCTAssertEqual(h.move(to: 3), .failure(.interrupted))
        XCTAssertEqual(d.lastIsCurrent?(), false)
    }

    func testMembershipChangingDuringStabilizationIsReported() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        h.onSleep = { interval in if interval == 0.3 { h.spaces.membership = [2] } }
        XCTAssertEqual(h.move(to: 3), .failure(.movedElsewhere(to: 2)))
        h.spaces.active = 1; h.spaces.membership = [1]
        h.onSleep = { interval in if interval == 0.3 { h.spaces.membership = [] } }
        XCTAssertEqual(h.move(to: 3), .failure(.membershipUnreadable))
        XCTAssertTrue(h.control.failureDetail(.membershipUnreadable)?.contains("Desktop 3") == true, "the readable current Space is kept")
    }

    func testMembershipAndSpaceChangingInTheSamePollingIntervalInterruptsBeforeRaising() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.membership = [2]; h.spaces.active = 3 } }
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertTrue(d.raises.isEmpty, "the user's switch must not be overwritten by a raise")
    }

    /// The user switched between the membership check and sending. Read 1 = operation start, 2 = getting the order, 3 = check right before sending.
    func testSpaceChangeBeforeSendingIsCaught() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.spaces.activeHook = { n in if n == 3 { h.spaces.active = 3 } }
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertTrue(d.moves.isEmpty, "nothing is sent after the user switched Spaces")
    }

    func testRaiseActivationGuardIsClearedWhenTheOperationEnds() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.move(to: 3).get().steps, 0)
        XCTAssertEqual(d.lastIsCurrent?(), false, "activation queued by the raise must not run after the move returned")
    }

    func testMembershipClassificationAfterARequest() {
        typealias F = SpaceControl.Failure
        XCTAssertNil(SpaceControl.membershipFailure([3], source: 1, target: 3, confirmed: false))
        XCTAssertEqual(SpaceControl.membershipFailure([], source: 1, target: 3, confirmed: false), F.membershipUnreadable)
        XCTAssertEqual(SpaceControl.membershipFailure([1], source: 1, target: 3, confirmed: false), F.moveUnconfirmed)
        XCTAssertEqual(SpaceControl.membershipFailure([1], source: 1, target: 3, confirmed: true), F.movedElsewhere(to: 1), "back on the source after confirmation is not 'did not change'")
        XCTAssertEqual(SpaceControl.membershipFailure([2], source: 1, target: 3, confirmed: false), F.movedElsewhere(to: 2))
        XCTAssertEqual(SpaceControl.membershipFailure([3, 2], source: 1, target: 3, confirmed: true), F.onSeveralSpaces([3, 2]), "the target among several is not a wrong destination")
        XCTAssertEqual(SpaceControl.membershipFailure([1, 3], source: 1, target: 3, confirmed: false), F.onSeveralSpaces([1, 3]))
    }

    func testReturningToTheSourceDuringStabilizationIsNotCalledUnconfirmed() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        h.onSleep = { interval in if interval == 0.3 { h.spaces.membership = [1] } }
        XCTAssertEqual(h.move(to: 3), .failure(.movedElsewhere(to: 1)))
    }

    func testUnreadableActiveSpaceAfterConfirmedMembershipKeepsThePlacement() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        h.onSleep = { interval in if interval == 0.3 { h.spaces.active = nil } }
        XCTAssertEqual(h.move(to: 3), .failure(.activeSpaceUnreadable))
        let detail = h.control.failureDetail(.activeSpaceUnreadable) ?? ""
        XCTAssertTrue(detail.contains("Space 3"), "window placement is kept: \(detail)")
        XCTAssertTrue(detail.contains("unknown"), detail)
    }

    /// After a switch not counted as input (another app changed the Space), the queued activation does not run.
    func testQueuedActivationIsRefusedAfterAnUncountedSpaceChange() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        var guardDuringStabilization: Bool?
        h.onSleep = { interval in
            if interval == 0.3 {
                XCTAssertEqual(d.lastIsCurrent?(), true, "while on the target the queued activation may still run")
                h.spaces.active = 2
                guardDuringStabilization = d.lastIsCurrent?()
            }
        }
        XCTAssertEqual(h.move(to: 3), .failure(.drifted(to: 2)))
        XCTAssertEqual(guardDuringStabilization, false)
    }

    /// If the raise took effect late and reached the target, the reactivation workaround does not start; once started, restoring happens even on the target.
    func testReactivationBeginsOnlyOnTheSourceButFinishesOnSourceOrTarget() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        var begin: (() -> Bool)?, finish: (() -> Bool)?
        h.control.direct = SpaceControl.DirectPath(move: { _, space in h.spaces.membership = [space]; return true },
                                                   raise: { _, _, _ in .issued },
                                                   reactivate: { wid, mayBegin, mayFinish, report in
                                                       begin = mayBegin; finish = mayFinish
                                                       XCTAssertEqual(mayBegin(), true)
                                                       XCTAssertEqual(mayFinish(), true)
                                                       report(.began)
                                                       h.spaces.active = 3 // raise took effect right after we came forward
                                                       XCTAssertEqual(mayBegin(), false, "no self-activation after arrival")
                                                       XCTAssertEqual(mayFinish(), true, "the window's app is still handed the focus back")
                                                       report(.requested(700)); h.frontmost = 700; h.focused = wid
                                                   }, focusedWindow: { h.focused })
        XCTAssertEqual(try? h.move(to: 3).get().steps, 0)
        XCTAssertEqual(begin?(), false)
        XCTAssertEqual(finish?(), false, "both gates close when the operation returns")
        _ = d
    }

    func testReactivationFinishIsRefusedOnAnUnexpectedSpace() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in
            if interval == 0.02, let finish = d.lastMayFinish, h.spaces.active == 1 {
                XCTAssertEqual(finish(), true)
                h.spaces.active = 2 // another app changed the Space
                XCTAssertEqual(finish(), false)
            }
        }
        XCTAssertEqual(h.move(to: 3), .failure(.interrupted))
    }

    func testSeveralSpacesAfterTheRequestIsReportedWithoutRaising() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.membership = [1, 3] } }
        XCTAssertEqual(h.move(to: 3), .failure(.onSeveralSpaces([1, 3])))
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUnreadableMembershipDuringTheInitialWaitKeepsTheCurrentSpace() {
        let h = SpaceHarness(); let d = DirectStub(); d.moveChangesMembership = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.membership = [] } }
        XCTAssertEqual(h.move(to: 3), .failure(.membershipUnreadable))
        XCTAssertTrue(h.control.failureDetail(.membershipUnreadable)?.contains("Desktop 1") == true)
        XCTAssertTrue(h.events.isEmpty)
    }

    /// The operations queue drops `Liveness` and the main thread reads it. Reads overlapping the moment the operation ends must not crash (meaningful under TSan).
    /// Readers start during the 0.3 s settle wait; the operation returns only after all have seen the open gate, and they keep reading until they see it closed.
    func testLivenessTokenSurvivesConcurrentReadsWhileTheOperationEnds() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        h.control.settle = .fixedWaits
        let readers = 8
        let group = DispatchGroup()
        let observedOpen = DispatchSemaphore(value: 0)
        let closedSeen = NSLock()
        var closedCount = 0
        h.onSleep = { interval in
            guard interval == 0.3, let isCurrent = d.lastIsCurrent else { return }
            // Dedicated threads: a global dispatch queue runs only about as many busy blocks as there are cores,
            // so on a small machine the later readers would wait for the earlier ones, which wait for the gate to close.
            for _ in 0..<readers {
                group.enter()
                Thread {
                    defer { group.leave() }
                    var signalled = false
                    // Bounded by time, not a read count: with fewer cores than readers, an early reader
                    // could use up a fixed count before the last reader runs and the gate closes.
                    let deadline = DispatchTime.now() + 5
                    while DispatchTime.now() < deadline {
                        let live = isCurrent()
                        if live, !signalled { signalled = true; observedOpen.signal() }
                        if !live, signalled { closedSeen.lock(); closedCount += 1; closedSeen.unlock(); return }
                    }
                    if !signalled { observedOpen.signal() }
                }.start()
            }
            // The operation returns only after every reader saw the open gate (so reads and closing surely overlap).
            for _ in 0..<readers { XCTAssertEqual(observedOpen.wait(timeout: .now() + 5), .success) }
        }
        XCTAssertEqual(try? h.move(to: 3).get().steps, 0)
        // After a timeout, readers may still be counting, so the count is not read.
        guard group.wait(timeout: .now() + 10) == .success else { return XCTFail("readers did not finish") }
        XCTAssertEqual(closedCount, readers, "every reader saw the gate open, then closed")
    }

    func testNotSwitchedIsOnlyReportedWhenTheWindowIsStillOnTheTarget() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02, !d.reactivates.isEmpty { h.spaces.membership = [2] } }
        XCTAssertEqual(h.move(to: 3), .failure(.movedElsewhere(to: 2)))
    }

    func testDirectPathIsNotUsedForFullScreenTargets() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.spaceTypes = [0, 4, 0]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.move(to: 2).get().steps, 1)
        XCTAssertTrue(d.moves.isEmpty)
        XCTAssertTrue(h.events.contains { $0.type == .leftMouseDown })
    }

    func testDirectPathRequiresInputObservationLikeStepping() {
        let h = SpaceHarness(); let d = DirectStub(); h.inputAvailable = false
        h.control.direct = d.path(h)
        guard case .failure(.unavailable) = h.move(to: 2) else { return XCTFail("moved without input observation") }
        XCTAssertTrue(d.moves.isEmpty)
    }

    func testDirectPathReactivatesWhenRaiseDoesNotSwitch() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.move(to: 3).get().steps, 0)
        XCTAssertEqual(d.raises, [10])
        XCTAssertEqual(d.reactivates, [10])
        XCTAssertEqual(h.spaces.active, 3)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDirectPathReportsMovedWindowThatDidNotSwitchWithoutStepping() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false
        h.control.direct = d.path(h)
        XCTAssertEqual(h.move(to: 3), .failure(.notSwitched))
        XCTAssertEqual(h.spaces.membership, [3], "the window stays where it was moved")
        XCTAssertEqual(h.spaces.active, 1)
        XCTAssertTrue(h.events.isEmpty, "no drag after the membership already changed")
        let detail = h.control.failureDetail(.notSwitched) ?? ""
        XCTAssertTrue(detail.contains("Desktop 1"), detail)
        XCTAssertTrue(detail.contains("Desktop 3"), detail)
    }

    func testDirectPathReportsArrivalElsewhere() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = SpaceControl.DirectPath(move: { _, _ in h.spaces.membership = [2]; return true },
                                                   raise: { wid, _, _ in d.raises.append(wid); return .issued }, reactivate: { _, _, _, _ in })
        XCTAssertEqual(h.move(to: 3), .failure(.movedElsewhere(to: 2)))
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDirectPathHonoursCancellationBeforeSending() {
        let h = SpaceHarness(); let d = DirectStub(); h.allowed = false
        h.control.direct = d.path(h)
        XCTAssertEqual(h.move(to: 2), .failure(.interrupted))
        XCTAssertTrue(d.moves.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    /// A window kept ordered out (closed, still listed on the target) is never raised: raising it switches nothing.
    func testDirectSwitchSkipsOrderedOutWindows() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        let stub = SpacesStubByWindow(h.spaces) { _ in [3] }
        stub.ordered = { $0 != 21 }
        let control = h.control(with: stub)
        control.direct = d.path(h)
        XCTAssertEqual(try control.switchTo(spaceID: 3, candidates: [21, 23]).get().steps, 0)
        XCTAssertEqual(d.raises, [23])
    }

    func testSwitchWithoutCandidatesSteps() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().steps, 1)
        XCTAssertTrue(d.moves.isEmpty)
        XCTAssertTrue(d.raises.isEmpty)
    }

    // MARK: - Direct switch (bringing a window on the target Space forward)

    func testDirectSwitchRaisesACandidateOnTheTargetWithoutSyntheticInput() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        let result = try h.control.switchTo(spaceID: 3, candidates: [21]).get()
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.toSpace, 3)
        XCTAssertEqual(h.spaces.active, 3)
        XCTAssertEqual(d.raises, [21])
        XCTAssertTrue(d.moves.isEmpty, "switching never changes a window's Space")
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.hotkeyReads.isEmpty)
        XCTAssertEqual(d.lastIsCurrent?(), false)
    }

    func testDirectSwitchSkipsCandidatesNotOnlyOnTheTarget() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3] // used by the raise replacement to make the target active
        var memberships: [CGWindowID: [UInt64]] = [21: [2], 22: [3, 2], 23: [3]]
        let stub = SpacesStubByWindow(h.spaces) { memberships[$0] ?? [] }
        let control = h.control(with: stub)
        control.direct = d.path(h)
        XCTAssertEqual(try control.switchTo(spaceID: 3, candidates: [21, 22, 23]).get().steps, 0)
        XCTAssertEqual(d.raises, [23])
        memberships = [:]
    }

    /// If the candidate window moves from the target to another Space while being raised, a late activation is not allowed (unknown membership keeps the earlier check).
    func testARaisedCandidateThatLeavesTheTargetIsNoLongerAuthorized() throws {
        let h = SpaceHarness()
        h.spaces.membership = [3]
        var memberships: [CGWindowID: [UInt64]] = [21: [3]]
        let stub = SpacesStubByWindow(h.spaces) { memberships[$0] ?? [] }
        let control = h.control(with: stub)
        var authorizedAfterMove: Bool?
        var authorizedWhileUnknown: Bool?
        control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { wid, isCurrent, report in
            memberships[wid] = []
            authorizedWhileUnknown = isCurrent()
            memberships[wid] = [4] // the app moved the window to another Space
            authorizedAfterMove = isCurrent()
            return .refused
        }, reactivate: { _, _, _, _ in })
        _ = control.switchTo(spaceID: 3, candidates: [21])
        XCTAssertEqual(authorizedWhileUnknown, true, "unknown membership keeps the earlier check")
        XCTAssertEqual(authorizedAfterMove, false)
        memberships = [:]
    }

    /// A candidate closed while being raised (ordered out, still listed on the target) is no longer authorized while its order reads unknown,
    /// and is again once it reads ordered in (a window can read ordered out for a moment).
    func testARaisedCandidateThatIsClosedIsNoLongerAuthorized() throws {
        let h = SpaceHarness()
        h.spaces.membership = [3]
        let stub = SpacesStubByWindow(h.spaces) { _ in [3] }
        var order: Bool? = true
        stub.ordered = { _ in order }
        let control = h.control(with: stub)
        var answers: [Bool] = []
        control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { _, isCurrent, _ in
            answers.append(isCurrent())
            order = false // closed by the app
            answers.append(isCurrent())
            order = nil
            answers.append(isCurrent())
            order = true
            answers.append(isCurrent())
            return .refused
        }, reactivate: { _, _, _, _ in })
        _ = control.switchTo(spaceID: 3, candidates: [21])
        XCTAssertEqual(answers, [true, false, false, true])
    }

    /// Leaving the target while ordered out (moved and minimized) is still recorded, so a later ordered-in read with unknown membership does not authorize it.
    func testACandidateThatLeavesWhileOrderedOutStaysUnauthorized() throws {
        let h = SpaceHarness()
        h.spaces.membership = [3]
        var membership: [UInt64] = [3]
        let stub = SpacesStubByWindow(h.spaces) { _ in membership }
        var order: Bool? = true
        stub.ordered = { _ in order }
        let control = h.control(with: stub)
        var answers: [Bool] = []
        control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { _, isCurrent, _ in
            answers.append(isCurrent())
            membership = [4]
            order = false // moved to Space 4 and minimized
            answers.append(isCurrent())
            membership = []
            order = true // restored on Space 4; membership reads unknown
            answers.append(isCurrent())
            return .refused
        }, reactivate: { _, _, _, _ in })
        _ = control.switchTo(spaceID: 3, candidates: [21])
        XCTAssertEqual(answers, [true, false, false])
    }

    /// Input while answering whether activation is allowed (during the membership read) makes the answer "no".
    func testInputDuringTheCandidateMembershipReadRevokesAuthorization() throws {
        let h = SpaceHarness()
        h.spaces.membership = [3]
        var inputDuringQuery = false
        let stub = SpacesStubByWindow(h.spaces) { wid in
            if inputDuringQuery, wid == 21 { h.inputs += 1 } // the user acted during the read
            return wid == 21 ? [3] : []
        }
        let control = h.control(with: stub)
        var authorized: Bool?
        control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { _, isCurrent, _ in
            inputDuringQuery = true
            authorized = isCurrent()
            inputDuringQuery = false
            return .refused
        }, reactivate: { _, _, _, _ in })
        _ = control.switchTo(spaceID: 3, candidates: [21])
        XCTAssertEqual(authorized, false)
    }

    /// A candidate once seen off the target Space never gets activation allowed again (late or retried), even if its membership later becomes unknown.
    func testADepartedCandidateStaysUnauthorizedWhenMembershipBecomesUnknown() throws {
        let h = SpaceHarness()
        h.spaces.membership = [3]
        var memberships: [CGWindowID: [UInt64]] = [21: [3]]
        let stub = SpacesStubByWindow(h.spaces) { memberships[$0] ?? [] }
        let control = h.control(with: stub)
        var raiseAuthorization: (() -> Bool)?
        var raiseAfterMove: Bool?
        var raiseWhenUnknown: Bool?
        var reactivateBegin: Bool?
        var reactivateFinish: Bool?
        control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { _, isCurrent, report in
            raiseAuthorization = isCurrent
            report(.requested(700))
            return .issued // activation queued, but no switch
        }, reactivate: { _, mayBegin, mayFinish, _ in
            // While waiting for the switch, the app moved the window to another Space, then its membership became unknown.
            memberships[21] = [4]
            raiseAfterMove = raiseAuthorization?()
            memberships[21] = []
            raiseWhenUnknown = raiseAuthorization?()
            reactivateBegin = mayBegin()
            reactivateFinish = mayFinish()
        })
        _ = control.switchTo(spaceID: 3, candidates: [21])
        XCTAssertEqual(raiseAfterMove, false)
        XCTAssertEqual(raiseWhenUnknown, false, "a departure seen once is not forgotten")
        XCTAssertEqual(reactivateBegin, false)
        XCTAssertEqual(reactivateFinish, false)
        memberships = [:]
    }

    func testDirectSwitchTriesTheNextCandidateWhenRaiseIsRejected() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        var rejected: [CGWindowID] = []
        h.control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { wid, _, report in
            if wid == 21 { rejected.append(wid); return .refused }
            h.spaces.active = 3; report(.requested(700)); h.frontmost = 700; return .issued
        }, reactivate: { _, _, _, _ in })
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: [21, 22]).get().steps, 0)
        XCTAssertEqual(rejected, [21])
    }

    /// After an issued raise, never fall back to stepping (a late activation would overshoot).
    func testDirectSwitchDoesNotStepAfterAnIssuedRaiseThatDidNotSwitch() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false
        h.spaces.membership = [2]
        h.control.direct = d.path(h)
        XCTAssertEqual(h.control.switchTo(spaceID: 2, candidates: [21]), .failure(.switchUnconfirmed))
        XCTAssertEqual(d.raises, [21])
        XCTAssertEqual(d.reactivates, [21])
        XCTAssertEqual(d.lastMayBegin?(), false)
        XCTAssertTrue(h.events.isEmpty, "no synthetic keys after a raise was issued")
        XCTAssertTrue(h.hotkeyReads.isEmpty)
        XCTAssertTrue(h.control.failureDetail(.switchUnconfirmed)?.contains("Desktop 1") == true)
    }

    /// An AX timeout means "may have arrived", so it is treated as issued.
    func testDirectSwitchTreatsAnUnknownRaiseOutcomeAsIssued() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false; d.reactivateSwitches = false; d.raiseOutcome = .unknown
        h.spaces.membership = [2]
        h.control.direct = d.path(h)
        XCTAssertEqual(h.control.switchTo(spaceID: 2, candidates: [21, 22]), .failure(.switchUnconfirmed))
        XCTAssertEqual(d.raises, [21], "no second candidate after an outstanding request")
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDirectSwitchStepsOnlyWhenNoRaiseWasIssued() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseOutcome = .refused; d.raiseSwitches = false
        h.spaces.membership = [2]
        h.control.direct = d.path(h)
        let result = try h.control.switchTo(spaceID: 2, candidates: [21, 22]).get()
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(d.raises, [21, 22])
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertTrue(h.events.contains { $0.type == .keyDown })
        XCTAssertFalse(h.events.contains { $0.type == .leftMouseDown }, "switching never drags")
    }

    /// Closed windows and windows on other Spaces do not count toward the 3 attempts.
    func testStaleCandidatesDoNotConsumeTheAttemptBudget() throws {
        let h = SpaceHarness(); let d = DirectStub()
        var memberships: [CGWindowID: [UInt64]] = [1: [], 2: [], 3: [2], 24: [3]]
        let stub = SpacesStubByWindow(h.spaces) { memberships[$0] ?? [] }
        h.spaces.membership = [3]
        let control = h.control(with: stub)
        control.direct = d.path(h)
        XCTAssertEqual(try control.switchTo(spaceID: 3, candidates: [1, 2, 3, 24]).get().steps, 0)
        XCTAssertEqual(d.raises, [24])
        memberships = [:]
    }

    /// If the user switches or acts during the membership query, AXRaise is not sent.
    func testChangeDuringMembershipLookupPreventsTheRaise() {
        for change in ["space", "input"] {
            let h = SpaceHarness(); let d = DirectStub()
            h.spaces.membership = [3]
            h.spaces.onMembershipRead = { _ in if change == "space" { h.spaces.active = 2 } else { h.inputs += 1 } }
            h.control.direct = d.path(h)
            XCTAssertEqual(h.control.switchTo(spaceID: 3, candidates: [21]), .failure(.interrupted), change)
            XCTAssertTrue(d.raises.isEmpty, change)
        }
    }

    func testDirectSwitchUsesReactivationWhenRaiseAloneDoesNotSwitch() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: [21]).get().steps, 0)
        XCTAssertEqual(d.reactivates, [21])
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDirectSwitchIsInterruptedByInputWhileWaiting() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.inputs += 1 } }
        XCTAssertEqual(h.control.switchTo(spaceID: 3, candidates: [21]), .failure(.interrupted))
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    /// Refused candidates (windows only in history, without AX elements) are skipped however many there are, until a usable one. History holds 8, so check the 9th.
    func testRefusedCandidatesNeverExcludeAUsableOne() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { wid, _, report in
            d.raises.append(wid)
            if wid <= 8 { return .refused }
            h.spaces.active = 3; report(.requested(700)); h.frontmost = 700; return .issued
        }, reactivate: { _, _, _, _ in })
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: Array(1...9)).get().steps, 0)
        XCTAssertEqual(d.raises, Array(1...9))
        XCTAssertTrue(h.events.isEmpty)
    }

    /// If every candidate is refused, no activation was issued, so fall back to stepping.
    func testAllRefusedCandidatesFallBackToStepping() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = SpaceControl.DirectPath(move: { _, _ in false }, raise: { wid, _, _ in d.raises.append(wid); return .refused }, reactivate: { _, _, _, _ in })
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: Array(1...10)).get().steps, 2)
        XCTAssertEqual(d.raises, Array(1...10))
    }

    func testDirectSwitchIsNotUsedForFullScreenTargets() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.spaceTypes = [0, 4, 0]; h.spaces.membership = [2]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.control.switchTo(spaceID: 2, candidates: [21]).get().steps, 1)
        XCTAssertTrue(d.raises.isEmpty)
    }

    func testDirectSwitchDriftAfterArrivalIsReported() {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.3 { h.spaces.active = 2 } }
        XCTAssertEqual(h.control.switchTo(spaceID: 3, candidates: [21]), .failure(.drifted(to: 2)))
    }

    func testDirectPathDriftAfterArrivalIsReported() {
        let h = SpaceHarness(); let d = DirectStub()
        h.control.direct = d.path(h)
        var focusReads = 0
        h.onFocusRead = { focusReads += 1; if focusReads == 2 { h.spaces.active = 2 } }
        XCTAssertEqual(h.move(to: 3), .failure(.drifted(to: 2)))
    }

    // MARK: - App activation (tier 2)

    private func app(_ pid: pid_t) -> SpaceControl.Candidate { .app(pid, bundleID: "com.example.\(pid)") }

    func testAppCandidateSwitchesWhenNoWindowCanBeRaised() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseOutcome = .refused; d.raiseSwitches = false
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        let result = try h.switchSpace(3, [3: [.window(21), app(501)]], hop: true).get()
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.fromSpace, 1)
        XCTAssertEqual(h.spaces.active, 3)
        XCTAssertEqual(d.raises, [21], "windows are tried first")
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertEqual(d.activations.first?.bundleID, "com.example.501")
        XCTAssertEqual(d.activations.first?.target, 3)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.hotkeyReads.isEmpty)
    }

    func testAppIsNotActivatedWhenAWindowSwitched() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(3, [3: [.window(21), app(501)]], hop: true).get().steps, 0)
        XCTAssertTrue(d.activations.isEmpty)
    }

    /// Ineligible after rechecking (nothing queued): move on to the next candidate.
    func testIneligibleAppIsSkippedForTheNext() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.ineligibleApps = [501]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501), app(502)]], hop: true).get().steps, 0)
        XCTAssertEqual(d.activations.map(\.pid), [501, 502])
    }

    /// The gate turned false on the main thread and nothing was issued (`declined`): move on to the next candidate.
    func testDeclinedActivationMovesToTheNextCandidate() throws {
        let h = SpaceHarness()
        var activated: [pid_t] = []
        h.control.direct = SpaceControl.DirectPath(move: nil, raise: { _, _, _ in .refused }, reactivate: { _, _, _, _ in },
                                                   activateApp: { pid, _, target, _, _, report in
            activated.append(pid)
            if pid == 501 { report(.declined) } else { report(.began); h.spaces.active = target; report(.requested(pid)); h.frontmost = pid }
            return .unknown
        })
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501), app(502)]], hop: true).get().steps, 0)
        XCTAssertEqual(activated, [501, 502])
        XCTAssertTrue(h.events.isEmpty)
    }

    /// If we came forward (issued) but no switch happened, neither the next candidate nor stepping is tried.
    func testIssuedActivationThatDoesNotSwitchIsUnconfirmedWithoutKeys() {
        let h = SpaceHarness(); let d = DirectStub(); d.activationSwitches = false
        h.spaces.order = [1, 2, 3, 4]; h.spaces.spaceTypes = [0, 0, 0, 0]
        h.control.direct = d.path(h)
        XCTAssertEqual(h.switchSpace(4, [4: [app(501), app(502)], 3: [app(503)]], hop: true), .failure(.switchUnconfirmed))
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertTrue(h.events.isEmpty, "no synthetic keys after an activation was issued")
        XCTAssertTrue(h.hotkeyReads.isEmpty)
        XCTAssertTrue(h.control.failureDetail(.switchUnconfirmed)?.contains("Desktop 1") == true)
    }

    /// No report from the main thread (unknown whether issued) is also `switchUnconfirmed`, like issued. Gates are closed after returning.
    func testActivationWithoutAnyReportIsUnconfirmedAndItsGatesClose() {
        let h = SpaceHarness(); let d = DirectStub(); d.holdActivation = true
        h.control.direct = d.path(h)
        let before = h.time
        XCTAssertEqual(h.switchSpace(3, [3: [app(501), app(502)]], hop: true), .failure(.switchUnconfirmed))
        XCTAssertGreaterThanOrEqual(h.time.timeIntervalSince(before), 2.0)
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertEqual(d.lastMayBegin?(), false, "a callback after the operation returned does nothing")
        XCTAssertEqual(d.lastMayFinish?(), false)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testLateActivationIsAccepted() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.holdActivation = true
        h.control.direct = d.path(h)
        var polls = 0
        h.onSleep = { interval in
            guard interval == 0.02 else { return }
            polls += 1
            if polls == 30, let begin = d.lastMayBegin, let finish = d.lastMayFinish, let report = d.lastReport {
                XCTAssertTrue(begin()); report(.began)
                XCTAssertTrue(finish()); h.spaces.active = 3; report(.requested(501)); h.frontmost = 501
            }
        }
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501)]], hop: true).get().steps, 0)
        XCTAssertEqual(d.lastMayFinish?(), false, "both gates close when the operation returns")
    }

    /// If the user acts after we came forward but before the target's activation, the second stage does not run.
    func testInputBetweenActivationStagesInterrupts() {
        let h = SpaceHarness(); let d = DirectStub(); d.holdActivation = true
        h.control.direct = d.path(h)
        var finishAfterInput: Bool?
        h.onSleep = { interval in
            guard interval == 0.02, finishAfterInput == nil, let begin = d.lastMayBegin, let finish = d.lastMayFinish else { return }
            XCTAssertTrue(begin()); d.lastReport?(.began)
            h.inputs += 1
            finishAfterInput = finish()
        }
        XCTAssertEqual(h.switchSpace(3, [3: [app(501), app(502)]], hop: true), .failure(.interrupted))
        XCTAssertEqual(finishAfterInput, false)
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertTrue(h.events.isEmpty)
    }

    /// Seeing a Space other than the source and target interrupts and puts that place in the result; it does not continue from there.
    func testUnexpectedSpaceDuringActivationInterruptsWithThePlace() {
        let h = SpaceHarness(); let d = DirectStub(); d.holdActivation = true
        h.spaces.order = [1, 2, 3, 4]; h.spaces.spaceTypes = [0, 0, 0, 0]
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.02 { h.spaces.active = 2 } }
        XCTAssertEqual(h.switchSpace(4, [4: [app(501)], 3: [app(503)]], hop: true), .failure(.interrupted))
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.control.failureDetail(.interrupted)?.contains("Desktop 2") == true)
    }

    func testActivationIsNotUsedForFullScreenTargets() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.spaceTypes = [0, 0, 4]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501)], 2: [app(502)]], hop: true).get().steps, 2)
        XCTAssertTrue(d.activations.isEmpty)
    }

    func testAppCandidatesAreSkippedWithoutTheActivationCapability() throws {
        let h = SpaceHarness()
        h.control.direct = SpaceControl.DirectPath(move: nil, raise: { _, _, _ in .refused }, reactivate: { _, _, _, _ in })
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501)]], hop: true).get().steps, 2)
    }

    /// Only moving windows depends on the bridged move. Without it, moves drag and switching paths remain.
    func testMissingBridgedMoveOnlyDisablesTheDirectMove() throws {
        let h = SpaceHarness(); let d = DirectStub()
        var path = d.path(h)
        path.move = nil
        h.control.direct = path
        XCTAssertEqual(try h.move(to: 2).get().steps, 1)
        XCTAssertTrue(h.events.contains { $0.type == .leftMouseDown })
        XCTAssertTrue(d.moves.isEmpty)
    }

    // MARK: - One jump to an intermediate Space plus stepping (tier 3)

    private func fiveSpaces(_ h: SpaceHarness) {
        h.spaces.order = [1, 2, 3, 4, 5]; h.spaces.spaceTypes = [0, 0, 0, 0, 0]
    }

    private var keyDowns: (SpaceHarness) -> Int { { h in h.events.filter { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) >= 123 }.count } }

    func testHopGoesToTheNearestSpaceWithACandidateThenStepsRight() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.control.direct = d.path(h)
        let result = try h.switchSpace(5, [5: [], 2: [app(502)], 4: [app(504)]], hop: true).get()
        XCTAssertEqual(result.fromSpace, 1)
        XCTAssertEqual(result.toSpace, 5)
        XCTAssertEqual(result.steps, 1, "only the keys actually sent")
        XCTAssertEqual(h.spaces.active, 5)
        XCTAssertEqual(d.activations.map(\.pid), [504])
        XCTAssertEqual(d.activations.first?.target, 4)
        XCTAssertEqual(Set(h.hotkeyReads), [81], "re-read before every key-down, only this direction")
        XCTAssertEqual(keyDowns(h), 1)
    }

    func testHopStepsLeftFromTheNearestSpace() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); h.spaces.active = 5
        h.control.direct = d.path(h)
        let result = try h.switchSpace(1, [2: [app(502)], 4: [app(504)]], hop: true).get()
        XCTAssertEqual(result.fromSpace, 5)
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(d.activations.map(\.target), [2])
        XCTAssertEqual(Set(h.hotkeyReads), [79], "re-read before every key-down, only this direction")
        XCTAssertEqual(h.spaces.active, 1)
    }

    /// If the nearest Space's candidates are unusable, the next nearest is tried. Only windows belonging to the target Space alone count.
    func testHopSkipsAnUnusableNearestSpace() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.ineligibleApps = [504]
        h.spaces.membership = [9] // window 41 does not belong to 4
        h.control.direct = d.path(h)
        let result = try h.switchSpace(5, [4: [.window(41), app(504)], 3: [app(503)]], hop: true).get()
        XCTAssertEqual(result.steps, 2)
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertEqual(d.activations.map(\.pid), [504, 503])
        XCTAssertEqual(h.spaces.active, 5)
    }

    func testHopThroughAWindowCandidate() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.spaces.membership = [4]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(5, [4: [.window(41)]], hop: true).get().steps, 1)
        XCTAssertEqual(d.raises, [41])
    }

    /// With no candidate in between (full-screen Spaces' candidates are not used), step from the source.
    func testNoUsableSpaceInBetweenStepsFromTheSource() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); h.spaces.spaceTypes = [0, 0, 4, 0, 0]
        h.control.direct = d.path(h)
        let result = try h.switchSpace(5, [3: [app(503)], 1: [app(501)]], hop: true).get()
        XCTAssertEqual(result.steps, 4)
        XCTAssertTrue(d.activations.isEmpty)
        XCTAssertEqual(Set(h.hotkeyReads), [81], "only the direction in use is read (before every key-down)")
    }

    /// Without a usable stepping shortcut, no jump (never stranding the user on a Space they did not ask for).
    func testShortcutIsCheckedBeforeHopping() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.hotkey = { id in id == 81 ? .disabled : .enabled(keyCode: 123, flags: 0x0084_0000) }
        h.control.direct = d.path(h)
        guard case .failure(.unavailable) = h.switchSpace(5, [4: [app(504)]], hop: true) else { return XCTFail("hopped without a usable shortcut") }
        XCTAssertTrue(d.activations.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertEqual(h.spaces.active, 1)
    }

    func testRegisteredCommandConflictPreventsTheHop() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.conflicts = { _, _ in true }
        h.control.direct = d.path(h)
        guard case .failure(.unavailable) = h.switchSpace(5, [4: [app(504)]], hop: true) else { return XCTFail("hopped with a conflicting shortcut") }
        XCTAssertTrue(d.activations.isEmpty)
    }

    /// With rearranging on (the caller does not allow it), step without jumping.
    func testHopIsNotUsedWhenNotAllowed() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(5, [4: [app(504)]], hop: false).get().steps, 4)
        XCTAssertTrue(d.activations.isEmpty)
    }

    /// If an activation toward an intermediate Space was issued but no switch happened, the next nearest Space is not tried and no keys are sent.
    func testIssuedHopThatDoesNotSwitchSendsNoKeys() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.activationSwitches = false
        h.control.direct = d.path(h)
        XCTAssertEqual(h.switchSpace(5, [4: [app(504)], 3: [app(503)]], hop: true), .failure(.switchUnconfirmed))
        XCTAssertEqual(d.activations.map(\.pid), [504])
        XCTAssertEqual(keyDowns(h), 0)
        XCTAssertTrue(h.control.failureDetail(.switchUnconfirmed)?.contains("Desktop 1") == true)
    }

    /// If the order changes after arriving (direction changes, target gone), the rest is not sent and it fails with the actual place.
    func testOrderChangeAfterTheHopStopsTheRemainder() {
        for change in ["reversed", "removed"] {
            let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
            h.control.direct = d.path(h)
            h.onSleep = { interval in
                guard interval == 0.3 else { return }
                if change == "reversed" { h.spaces.order = [1, 2, 3, 5, 4] } else { h.spaces.order = [1, 2, 3, 4]; h.spaces.spaceTypes = [0, 0, 0, 0] }
            }
            XCTAssertEqual(h.switchSpace(5, [4: [app(504)]], hop: true), .failure(.routeChanged), change)
            XCTAssertEqual(keyDowns(h), 0, change)
            XCTAssertEqual(h.spaces.active, 4, change)
            // The place uses the number in the reread order ("reversed" puts Space 4 fifth).
            XCTAssertTrue(h.control.failureDetail(.routeChanged)?.contains(change == "reversed" ? "Desktop 5" : "Desktop 4") == true, change)
        }
    }

    /// Even after reaching the intermediate Space, the gate stays open and no keys are sent until the target app is observed in front (a request alone is not the end).
    /// Once observed, the gate closes and stepping follows the settle wait.
    func testHopWaitsUntilTheTargetAppIsFrontmostBeforeStepping() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.holdActivation = true
        h.frontmost = 1 // the source app
        h.control.direct = d.path(h)
        var polls = 0
        var gateBeforeEffect: Bool?
        var gateDuringStabilization: Bool?
        var frontAtFirstKey: pid_t??
        h.onPost = { event in if event.type == .keyDown, frontAtFirstKey == nil { frontAtFirstKey = .some(h.frontmost) } }
        h.onSleep = { interval in
            if interval == 0.3 { gateDuringStabilization = d.lastMayFinish?(); return }
            guard interval == 0.02, let begin = d.lastMayBegin, let finish = d.lastMayFinish, let report = d.lastReport else { return }
            polls += 1
            // Right after we come forward, it looks like we arrived on X.
            if polls == 1 { XCTAssertTrue(begin()); report(.began); h.frontmost = 99; h.spaces.active = 4 }
            if polls == 3 { XCTAssertTrue(finish()); report(.requested(504)) } // requested, but not in front yet
            if polls == 10 { gateBeforeEffect = finish(); h.frontmost = 504 }
        }
        XCTAssertEqual(try h.switchSpace(5, [4: [app(504)]]).get().steps, 1)
        XCTAssertGreaterThanOrEqual(polls, 10, "kept waiting after the request until the app was frontmost")
        XCTAssertEqual(gateBeforeEffect, true, "gates stay open until the activation is observed")
        XCTAssertEqual(gateDuringStabilization, false, "gates close before stepping")
        XCTAssertEqual(frontAtFirstKey, .some(504), "no key while the target activation had not taken effect")
    }

    /// Reached the intermediate Space, but if the deadline passes without seeing the target app in front, stop without sending keys and report the place.
    func testHopWhoseActivationIsNeverObservedSendsNoKeys() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.activationTakesEffect = false
        h.control.direct = d.path(h)
        XCTAssertEqual(h.switchSpace(5, [4: [app(504)], 3: [app(503)]]), .failure(.activationUnconfirmed))
        XCTAssertEqual(d.activations.map(\.pid), [504], "no other route after arriving")
        XCTAssertEqual(keyDowns(h), 0)
        XCTAssertTrue(h.control.failureDetail(.activationUnconfirmed)?.contains("Desktop 4") == true)
    }

    /// Even reaching the intermediate Space by raise alone, no keys are sent until the raise's queued activation takes effect and the window's app is seen in front.
    func testRaiseOnlyHopWaitsForTheRaisedWindowsAppBeforeStepping() throws {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.raiseReports = false
        h.spaces.membership = [4]; h.frontmost = 1
        h.control.direct = d.path(h)
        var polls = 0
        var frontAtFirstKey: pid_t??
        h.onPost = { event in if event.type == .keyDown, frontAtFirstKey == nil { frontAtFirstKey = .some(h.frontmost) } }
        h.onSleep = { interval in
            guard interval == 0.02 else { return }
            polls += 1
            if polls == 3 { d.lastRaiseReport?(.requested(800)) } // activation requested (not in effect yet)
            if polls == 8 { h.frontmost = 800 }
        }
        XCTAssertEqual(try h.switchSpace(5, [4: [.window(41)]]).get().steps, 1)
        XCTAssertEqual(d.raises, [41])
        XCTAssertGreaterThanOrEqual(polls, 8)
        XCTAssertEqual(frontAtFirstKey, .some(800), "no key until the raised window's app is frontmost")
    }

    /// Whether the raise's activation is not requested, abandoned, or never observed in effect, it stops on the intermediate Space without sending keys.
    func testRaiseOnlyHopWithoutConfirmedActivationSendsNoKeys() {
        for mode in ["never-effective", "silent", "abandoned"] {
            let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); d.raiseReports = false
            h.spaces.membership = [4]
            h.control.direct = d.path(h)
            if mode == "never-effective" { h.onSleep = { interval in if interval == 0.02 { d.lastRaiseReport?(.requested(800)) } } }
            if mode == "abandoned" { h.onSleep = { interval in if interval == 0.02 { d.lastRaiseReport?(.abandoned) } } }
            XCTAssertEqual(h.switchSpace(5, [4: [.window(41)], 3: [app(503)]]), .failure(.activationUnconfirmed), mode)
            XCTAssertEqual(keyDowns(h), 0, mode)
            XCTAssertTrue(d.activations.isEmpty, "\(mode): no other route after arriving")
            XCTAssertTrue(h.control.failureDetail(.activationUnconfirmed)?.contains("Desktop 4") == true, mode)
        }
    }

    /// Reaching the target by raise alone is also not success until the raise's queued activation takes effect and the window's app is seen in front.
    func testDirectRaiseWaitsForTheRaisedWindowsApp() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseReports = false
        h.spaces.membership = [3]; h.frontmost = 1
        h.control.direct = d.path(h)
        var polls = 0
        var stabilizedBeforeEffect = false
        h.onSleep = { interval in
            if interval == 0.3, h.frontmost != 800 { stabilizedBeforeEffect = true }
            guard interval == 0.02 else { return }
            polls += 1
            if polls == 3 { d.lastRaiseReport?(.requested(800)) }
            if polls == 8 { h.frontmost = 800 }
        }
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: [21]).get().steps, 0)
        XCTAssertGreaterThanOrEqual(polls, 8)
        XCTAssertFalse(stabilizedBeforeEffect, "success is reported only after the app is frontmost")
    }

    /// Reached the target by raise, but without confirmed activation it is not success (the actual place is added).
    func testDirectRaiseWithoutConfirmedActivationIsNotSuccess() {
        for mode in ["never-effective", "silent", "abandoned"] {
            let h = SpaceHarness(); let d = DirectStub(); d.raiseReports = false
            h.spaces.membership = [3]
            h.control.direct = d.path(h)
            if mode == "never-effective" { h.onSleep = { interval in if interval == 0.02 { d.lastRaiseReport?(.requested(800)) } } }
            if mode == "abandoned" { h.onSleep = { interval in if interval == 0.02 { d.lastRaiseReport?(.abandoned) } } }
            XCTAssertEqual(h.control.switchTo(spaceID: 3, candidates: [21, 22]), .failure(.activationUnconfirmed), mode)
            XCTAssertEqual(d.raises, [21], "\(mode): no other candidate after arriving")
            XCTAssertTrue(h.events.isEmpty, mode)
            XCTAssertTrue(h.control.failureDetail(.activationUnconfirmed)?.contains("Desktop 3") == true, mode)
        }
    }

    /// If the activation of a 1 -> 3 raise is late and takes effect during the next 3 -> 2, pulling back to 3, neither command reports success.
    /// The first hits the deadline without confirmed activation (`activationUnconfirmed`); the second is interrupted because the Space changes after arriving.
    func testLateRaiseActivationAcrossTwoCommandsIsNeverReportedAsSuccess() {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseReports = false
        var memberships: [CGWindowID: [UInt64]] = [21: [3], 22: [2]]
        let control = h.control(with: SpacesStubByWindow(h.spaces) { memberships[$0] ?? [] })
        control.direct = SpaceControl.DirectPath(move: nil, raise: { wid, _, report in
            d.raises.append(wid)
            h.spaces.active = memberships[wid]?.first
            if wid == 21 { report(.requested(700)) } else { d.lastRaiseReport = report; report(.requested(800)) }
            return .issued
        }, reactivate: { _, _, _, _ in })
        // First: requested, but app 700 is not in front yet.
        XCTAssertEqual(control.switchTo(spaceID: 3, candidates: [21]), .failure(.activationUnconfirmed))
        // Second: a 3 -> 2 raise. While waiting for activation, the first activation takes effect and pulls back to 3.
        h.onSleep = { interval in if interval == 0.02, h.spaces.active == 2 { h.frontmost = 700; h.spaces.active = 3 } }
        XCTAssertEqual(control.switchTo(spaceID: 2, candidates: [22]), .failure(.interrupted))
        XCTAssertEqual(d.raises, [21, 22])
        XCTAssertTrue(control.failureDetail(.interrupted)?.contains("Desktop 3") == true)
        memberships = [:]
    }

    // MARK: - Hand-off confirmation (direct destination)

    /// Arriving directly on the target is also not success until the target app is seen in front.
    func testDirectArrivalWaitsForTheActivationToTakeEffect() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.holdActivation = true
        h.control.direct = d.path(h)
        var polls = 0
        var finishedEarly = false
        h.onSleep = { interval in
            if interval == 0.3, h.frontmost != 501 { finishedEarly = true }
            guard interval == 0.02, let begin = d.lastMayBegin, let finish = d.lastMayFinish, let report = d.lastReport else { return }
            polls += 1
            if polls == 1 { XCTAssertTrue(begin()); report(.began); h.frontmost = 99; h.spaces.active = 3 }
            if polls == 3 { XCTAssertTrue(finish()); report(.requested(501)) }
            if polls == 8 { h.frontmost = 501 }
        }
        XCTAssertEqual(try h.switchSpace(3, [3: [app(501)]]).get().steps, 0)
        XCTAssertFalse(finishedEarly, "stabilization starts only after the app is frontmost")
    }

    /// Arrived but activation not confirmed: not success, and neither the next candidate nor stepping runs. The same for raise + reactivate.
    func testDirectArrivalWithoutObservedActivationFails() {
        let apps = SpaceHarness(); let d = DirectStub(); d.activationTakesEffect = false
        apps.control.direct = d.path(apps)
        XCTAssertEqual(apps.switchSpace(3, [3: [app(501), app(502)]]), .failure(.activationUnconfirmed))
        XCTAssertEqual(d.activations.map(\.pid), [501])
        XCTAssertTrue(apps.events.isEmpty)
        XCTAssertTrue(apps.control.failureDetail(.activationUnconfirmed)?.contains("Desktop 3") == true)

        let windows = SpaceHarness(); let w = DirectStub(); w.raiseSwitches = false; w.activationTakesEffect = false
        windows.spaces.membership = [3]
        windows.control.direct = w.path(windows)
        XCTAssertEqual(windows.control.switchTo(spaceID: 3, candidates: [21, 22]), .failure(.activationUnconfirmed))
        XCTAssertEqual(w.raises, [21])
        XCTAssertEqual(w.reactivates, [21])
        XCTAssertTrue(windows.events.isEmpty)
    }

    func testRaiseThenReactivateSucceedsOnceTheAppIsFrontmost() throws {
        let h = SpaceHarness(); let d = DirectStub(); d.raiseSwitches = false
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.control.switchTo(spaceID: 3, candidates: [21]).get().steps, 0)
        XCTAssertEqual(h.frontmost, 700)
    }

    /// Giving up after we came forward (gate false or ineligible) stops as issued: `switchUnconfirmed` if not arrived, `activationUnconfirmed` if arrived.
    func testAbandonedHandoffStopsWithoutAnotherRoute() {
        for arrived in [false, true] {
            let h = SpaceHarness(); fiveSpaces(h)
            var activated: [pid_t] = []
            h.control.direct = SpaceControl.DirectPath(move: nil, raise: { _, _, _ in .refused }, reactivate: { _, _, _, _ in },
                                                       activateApp: { pid, _, target, _, _, report in
                activated.append(pid)
                report(.began)
                if arrived { h.spaces.active = target }
                report(.abandoned)
                return .unknown
            })
            XCTAssertEqual(h.switchSpace(5, [5: [app(501), app(502)], 4: [app(504)]]), .failure(arrived ? .activationUnconfirmed : .switchUnconfirmed), "\(arrived)")
            XCTAssertEqual(activated, [501], "\(arrived)")
            XCTAssertEqual(keyDowns(h), 0, "\(arrived)")
        }
    }

    // MARK: - Rechecking (each main-thread stage)

    private func runHandOff(eligible: [Bool], mayBegin: Bool = true, mayFinish: Bool = true) -> (stages: [SpaceControl.ActivationStage], actions: [String]) {
        var answers = eligible
        var stages: [SpaceControl.ActivationStage] = []
        var actions: [String] = []
        SpaceControl.handOff(pid: 42, eligible: { answers.isEmpty ? true : answers.removeFirst() }, mayBegin: { mayBegin }, mayFinish: { mayFinish },
                             activateSelf: { actions.append("self") }, activateTarget: { actions.append("target") }, report: { stages.append($0) },
                             onMain: { $0() }, after: { _, body in body() })
        return (stages, actions)
    }

    func testHandOffRevalidatesBeforeEachStage() {
        let ok = runHandOff(eligible: [true, true])
        XCTAssertEqual(ok.stages, [.began, .requested(42)])
        XCTAssertEqual(ok.actions, ["self", "target"])
        // Became ineligible after queuing, before we came forward (hidden, a window opened on another Space, and so on): nothing is issued.
        let beforeBegin = runHandOff(eligible: [false])
        XCTAssertEqual(beforeBegin.stages, [.declined])
        XCTAssertEqual(beforeBegin.actions, [])
        // Became ineligible after we came forward, before the target's activation: the target is not activated, and it gives up as issued.
        let beforeFinish = runHandOff(eligible: [true, false])
        XCTAssertEqual(beforeFinish.stages, [.began, .abandoned])
        XCTAssertEqual(beforeFinish.actions, ["self"])
        XCTAssertEqual(runHandOff(eligible: [true], mayBegin: false).stages, [.declined])
        XCTAssertEqual(runHandOff(eligible: [true, true], mayFinish: false).stages, [.began, .abandoned])
    }

    /// If the gate turns false during the eligibility read (reading the full window list), the target is not activated even if eligible.
    func testHandOffChecksTheGateAgainAfterTheEligibilityRead() {
        var gate = true
        var stages: [SpaceControl.ActivationStage] = []
        var actions: [String] = []
        var reads = 0
        SpaceControl.handOff(pid: 42, eligible: { reads += 1; if reads == 2 { gate = false }; return true }, mayBegin: { true }, mayFinish: { gate },
                             activateSelf: { actions.append("self") }, activateTarget: { actions.append("target") }, report: { stages.append($0) },
                             onMain: { $0() }, after: { _, body in body() })
        XCTAssertEqual(stages, [.began, .abandoned])
        XCTAssertEqual(actions, ["self"])
    }

    // MARK: - Tier 0 (macOS "Switch to Desktop N")

    /// The default ⌃2 (Desktop 2, symbolic hotkey 119).
    private static let ctrl2 = SpaceControl.DesktopHotkey(desktop: 2, id: 119, keyCode: 19, flags: 0x0004_0000)

    /// A harness with ⌃2 enabled. `dock` decides WindowServer's behavior; modifier flagsChanged always reach the tap.
    /// `switches`: consumes the main key and switches to Space 2 (the main key never reaches the tap). `passes`: the main key reaches the tap (pass-through).
    /// `nothing`: consumes the main key but does not switch (the Dock is behind). `late`: nothing reaches the tap (arrives late; the test delivers it afterward).
    private func desktopHarness(dock: String) -> (SpaceHarness, DirectStub) {
        let h = SpaceHarness(); let d = DirectStub()
        h.frontmost = 500
        h.hotkey = { id in
            switch id {
            case 81: return .enabled(keyCode: 124, flags: 0x0084_0000)
            case 79: return .enabled(keyCode: 123, flags: 0x0084_0000)
            case 119: return .enabled(keyCode: 19, flags: 0x0004_0000)
            default: return .disabled
            }
        }
        h.onPost = { event in Self.windowServer(dock, h, d, event) }
        h.control.direct = d.path(h)
        return (h, d)
    }

    private static func windowServer(_ dock: String, _ h: SpaceHarness, _ d: DirectStub, _ event: CGEvent) {
        guard dock != "late" else { return }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if event.type == .flagsChanged || dock == "passes" {
            _ = deliver(event, to: d)
        } else if dock == "switches", event.type == .keyDown, key == 19 {
            h.spaces.active = 2
        }
    }

    /// Delivers to the same entry as the tap callback (`PassThroughFilter.intercept`); true if swallowed.
    @discardableResult
    private static func deliver(_ event: CGEvent, to d: DirectStub) -> Bool {
        d.tap.filter.intercept(type: event.type, userData: event.getIntegerValueField(.eventSourceUserData),
                               keyCode: event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func hotkeyPlan(_ events: @escaping (SpaceControl.HotkeyEvent) -> Void = { _ in }, eligible: @escaping () -> Bool = { true },
                            shortcut: SpaceControl.DesktopHotkey = SpaceControlTests.ctrl2) -> SpaceControl.HotkeyPlan {
        SpaceControl.HotkeyPlan(shortcut: shortcut, dockPID: 7, stillEligible: eligible, report: events)
    }

    private func desktopKeyDowns(_ h: SpaceHarness) -> Int {
        h.events.filter { $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 19 }.count
    }

    func testDesktopNumberCountsOnlyOrdinaryDesktops() {
        func display(_ spaces: [UInt64], _ types: [Int32]) -> [SpaceObserver.ManagedDisplay] { [.init(display: "d", currentSpace: 1, spaces: spaces, spaceTypes: types)] }
        // An order with full screen (4) in between: Space 3 is the second Desktop. Full screen itself is excluded.
        XCTAssertEqual(SpaceControl.desktopNumber(of: 3, active: 1, displays: display([1, 2, 3, 4], [0, 4, 0, 0])), 2)
        XCTAssertEqual(SpaceControl.desktopNumber(of: 4, active: 1, displays: display([1, 2, 3, 4], [0, 4, 0, 0])), 3)
        XCTAssertNil(SpaceControl.desktopNumber(of: 2, active: 1, displays: display([1, 2, 3, 4], [0, 4, 0, 0])))
        // If any type is unreadable, it is not used (unknown is not counted as full screen).
        XCTAssertNil(SpaceControl.desktopNumber(of: 3, active: 1, displays: display([1, 2, 3], [0, 0])))
        // Several managed displays, the current Space in another order, the 17th.
        XCTAssertNil(SpaceControl.desktopNumber(of: 2, active: 1, displays: display([1, 2], [0, 0]) + display([5, 6], [0, 0])))
        XCTAssertNil(SpaceControl.desktopNumber(of: 2, active: 9, displays: display([1, 2], [0, 0])))
        let seventeen = Array(UInt64(1)...17)
        XCTAssertEqual(SpaceControl.desktopNumber(of: 16, active: 1, displays: display(seventeen, Array(repeating: 0, count: 17))), 16)
        XCTAssertNil(SpaceControl.desktopNumber(of: 17, active: 1, displays: display(seventeen, Array(repeating: 0, count: 17))))
    }

    func testDesktopShortcutReadClassifiesAndChecksConflicts() {
        let (h, _) = desktopHarness(dock: "switches")
        XCTAssertEqual(h.control.desktopShortcut(2), .usable(Self.ctrl2))
        XCTAssertEqual(h.control.desktopShortcut(1), .off)
        XCTAssertEqual(h.control.desktopShortcut(17), .unusable)
        // A remapping (⌥⌘2) can be sent too; no modifiers or unassigned are not sent.
        h.hotkey = { id in id == 119 ? .enabled(keyCode: 19, flags: 0x0018_0000) : .unknown }
        XCTAssertEqual(h.control.desktopShortcut(2), .usable(.init(desktop: 2, id: 119, keyCode: 19, flags: 0x0018_0000)))
        XCTAssertEqual(h.control.desktopShortcut(3), .unread)
        h.hotkey = { _ in .enabled(keyCode: 19, flags: 0) }
        XCTAssertEqual(h.control.desktopShortcut(2), .unusable)
        h.hotkey = { _ in .enabled(keyCode: 0xFFFF, flags: 0x0004_0000) }
        XCTAssertEqual(h.control.desktopShortcut(2), .unusable)
        h.hotkey = { _ in .enabled(keyCode: 19, flags: 0x0004_0000) }
        h.conflicts = { code, _ in code == 19 }
        XCTAssertEqual(h.control.desktopShortcut(2), .conflict(Self.ctrl2))
    }

    /// Tap decisions: every tier-0 attempt tag is swallowed, of any type, even after the attempt ends. Only the main keyDown of the active attempt is evidence.
    /// User input and stepping's own `syntheticTag` pass through.
    func testPassThroughFilterSwallowsEveryAttemptTagButCountsOnlyTheActiveMainKey() {
        let filter = PassThroughFilter(owner: 0x123)
        let first = PassThroughFilter.Attempt(tag: filter.tag(attempt: 7), mainKey: 19)
        let second = PassThroughFilter.Attempt(tag: filter.tag(attempt: 8), mainKey: 19)
        XCTAssertFalse(filter.intercept(type: .keyDown, userData: SpaceControl.syntheticTag, keyCode: 124), "stepping keys pass")
        XCTAssertFalse(filter.intercept(type: .keyDown, userData: 0, keyCode: 19), "user input passes")
        filter.begin(first)
        XCTAssertTrue(filter.intercept(type: .flagsChanged, userData: first.tag, keyCode: 59))
        XCTAssertTrue(filter.intercept(type: .keyDown, userData: first.tag, keyCode: 18))
        XCTAssertTrue(filter.intercept(type: .keyUp, userData: first.tag, keyCode: 19))
        XCTAssertFalse(filter.mainKeyDownObserved(first), "modifiers, other keys and key-ups are not evidence")
        XCTAssertTrue(filter.intercept(type: .keyDown, userData: first.tag, keyCode: 19))
        XCTAssertTrue(filter.mainKeyDownObserved(first))
        filter.retire(first)
        filter.begin(second)
        XCTAssertFalse(filter.mainKeyDownObserved(second), "no evidence carried over")
        XCTAssertTrue(filter.intercept(type: .keyDown, userData: first.tag, keyCode: 19), "a retired attempt is still swallowed")
        XCTAssertFalse(filter.mainKeyDownObserved(second), "and is not evidence for the active one")
        XCTAssertTrue(filter.intercept(type: .keyDown, userData: filter.tag(attempt: 0xFFFF), keyCode: 19), "any attempt tag of this owner")
        XCTAssertFalse(filter.intercept(type: .keyDown, userData: filter.tag(attempt: 1), keyCode: 19), "attempt 1 is the stepping tag family slot")
    }

    /// A namespace per owner (pid, all 32 bits): even with overlapping attempt numbers, another owner's attempts (LazySpace vs. lzprobe, for example) are
    /// neither swallowed nor counted. Pids 2048 apart (same low bits) do not collide. InputMonitor ignores both tags.
    func testFiltersOfDifferentOwnersNeverTouchEachOthersEvents() {
        for (appPID, probePID) in [(Int64(100), Int64(2148)), (Int64(100), Int64(100 + 0x10000)), (Int64(7), Int64(8))] {
            let app = PassThroughFilter(owner: appPID), probe = PassThroughFilter(owner: probePID)
            let appAttempt = PassThroughFilter.Attempt(tag: app.tag(attempt: 2), mainKey: 19)
            let probeAttempt = PassThroughFilter.Attempt(tag: probe.tag(attempt: 2), mainKey: 19)
            let pair = "\(appPID)/\(probePID)"
            XCTAssertNotEqual(appAttempt.tag, probeAttempt.tag, pair)
            XCTAssertFalse(app.owns(probeAttempt.tag), pair)
            XCTAssertFalse(probe.owns(appAttempt.tag), pair)
            XCTAssertTrue(SpaceControl.isSynthetic(appAttempt.tag) && SpaceControl.isSynthetic(probeAttempt.tag), "\(pair): both are ignored as user input")
            app.begin(appAttempt); probe.begin(probeAttempt)
            XCTAssertFalse(app.intercept(type: .keyDown, userData: probeAttempt.tag, keyCode: 19), "\(pair): the probe's key passes the app's tap")
            XCTAssertFalse(app.mainKeyDownObserved(appAttempt), pair)
            XCTAssertTrue(probe.intercept(type: .keyDown, userData: probeAttempt.tag, keyCode: 19), pair)
            XCTAssertTrue(probe.mainKeyDownObserved(probeAttempt), pair)
            app.retire(appAttempt)
            XCTAssertFalse(probe.intercept(type: .keyUp, userData: appAttempt.tag, keyCode: 19), "\(pair): the app's retired key passes the probe's tap")
            XCTAssertTrue(app.intercept(type: .keyUp, userData: appAttempt.tag, keyCode: 19), "\(pair): and is still swallowed by its own")
        }
        // The pid keeps all 32 bits. The marker is in the upper 16 bits and does not use the sign bit.
        let large = PassThroughFilter(owner: 0x7FFF_FFFF)
        XCTAssertEqual(large.owner, 0x7FFF_FFFF)
        XCTAssertGreaterThan(large.tag(attempt: 0xFFFF), 0)
        XCTAssertEqual(PassThroughFilter(owner: 42).tag(attempt: 3), 0x4C5A_0000_002A_0003)
    }

    /// SpaceControls in one process share attempt numbers and never use the same tag (until the counter wraps).
    func testTwoSpaceControlsInOneProcessNeverShareAnAttemptTag() throws {
        let (first, _) = desktopHarness(dock: "switches")
        let (second, _) = desktopHarness(dock: "switches")
        var tags: [Int64] = []
        for h in [first, second, first, second] {
            h.events = []; h.spaces.active = 1
            _ = try h.switchSpace(2, [:], hotkey: hotkeyPlan()).get()
            tags.append(h.events.first?.getIntegerValueField(.eventSourceUserData) ?? 0)
        }
        XCTAssertEqual(Set(tags).count, 4, "\(tags.map { String($0, radix: 16) })")
        XCTAssertTrue(tags.allSatisfy { ($0 >> 16) & 0xFFFF_FFFF == Int64(ProcessInfo.processInfo.processIdentifier) }, "owner is this process")
        let a = PassThroughFilter.nextAttempt(), b = PassThroughFilter.nextAttempt()
        XCTAssertTrue((2...0xFFFF).contains(a) && (2...0xFFFF).contains(b))
        XCTAssertNotEqual(a, b)
    }

    /// InputMonitor counts neither stepping's older tag (whatever the low 16 bits) nor attempt tags as user input, but does count user input.
    func testInputMonitorIgnoresBothTagFormsButCountsUserInput() throws {
        let monitor = InputMonitor()
        func key(_ userData: Int64) throws -> CGEvent {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            event.setIntegerValueField(.eventSourceUserData, value: userData)
            return event
        }
        let before = monitor.count
        monitor.record(.keyDown, event: try key(SpaceControl.syntheticTag))
        monitor.record(.keyDown, event: try key((SpaceControl.syntheticTag & ~0xFFFF) | 7))
        monitor.record(.keyDown, event: try key(PassThroughFilter(owner: 4242).tag(attempt: 9)))
        XCTAssertEqual(monitor.count, before, "LazySpace's own keys are not user input")
        XCTAssertTrue(SpaceControl.isSynthetic(SpaceControl.syntheticTag))
        XCTAssertFalse(SpaceControl.isSynthetic(0))
        XCTAssertFalse(SpaceControl.isSynthetic(0x4E52_0000_0000_0002), "another marker")
        monitor.record(.keyDown, event: try key(0))
        XCTAssertEqual(monitor.count, before + 1, "user input is counted")
    }

    /// When the system disables the tap, the active attempt stays damaged and is no evidence; the next attempt does not inherit that.
    func testDisabledTapCompromisesOnlyTheActiveAttempt() {
        let filter = PassThroughFilter()
        let attempt = PassThroughFilter.Attempt(tag: filter.tag(attempt: 7), mainKey: 19)
        filter.noteTapDisabled()
        filter.begin(attempt)
        XCTAssertFalse(filter.isCompromised(attempt), "a disable with no attempt does not carry over")
        filter.noteTapDisabled()
        XCTAssertTrue(filter.isCompromised(attempt))
        XCTAssertTrue(filter.intercept(type: .keyDown, userData: attempt.tag, keyCode: 19), "still swallowed after re-enabling")
        XCTAssertFalse(filter.mainKeyDownObserved(attempt), "not evidence")
        filter.retire(attempt)
        let next = PassThroughFilter.Attempt(tag: attempt.tag + 1, mainKey: 19)
        filter.begin(next)
        XCTAssertFalse(filter.isCompromised(next))
    }

    /// If the Dock accepts, one post and arrival make success (`steps` 0). The front app does not change, and every pressed key is released.
    func testDesktopShortcutArrivalSucceedsWithoutOtherTiers() throws {
        let (h, d) = desktopHarness(dock: "switches")
        h.spaces.membership = [2]
        var events: [SpaceControl.HotkeyEvent] = []
        let result = try h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan { events.append($0) }).get()
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.fromSpace, 1)
        XCTAssertEqual(events, [.arrived])
        XCTAssertTrue(d.raises.isEmpty, "no other tier after arriving")
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertEqual(h.frontmost, 500, "the front app does not change")
        XCTAssertEqual(desktopKeyDowns(h), 1, "posted once")
        XCTAssertEqual(h.events.filter { $0.type == .keyUp && $0.getIntegerValueField(.keyboardEventKeycode) == 19 }.count, 1)
        XCTAssertEqual((h.posted.last?.flags ?? 1) & 0x0004_0000, 0, "Control is released last")
        let tag = h.events.first?.getIntegerValueField(.eventSourceUserData) ?? 0
        XCTAssertTrue(d.tap.filter.owns(tag), "each attempt has its own tag in this owner's swallowed range")
        XCTAssertTrue(SpaceControl.isSynthetic(tag), "still recognized as LazySpace's own input")
        XCTAssertTrue(h.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == tag })
        XCTAssertEqual(d.tap.starts, 1)
        XCTAssertEqual(d.tap.state, .ready, "the tap is kept for later attempts")
    }

    /// If the main keyDown reaches the tap, it passed through: without waiting for arrival, check the fingerprint and gates, record it, and continue to tier 1.
    func testPassThroughIsRecordedAndContinues() throws {
        let (h, d) = desktopHarness(dock: "passes")
        h.spaces.membership = [2]
        var order: [String] = []
        let plan = hotkeyPlan { order.append("\($0)") }
        h.control.direct?.raise = { _, _, report in order.append("raise"); h.spaces.active = 2; report(.requested(700)); h.frontmost = 700; return .issued }
        let before = h.time
        XCTAssertEqual(try h.switchSpace(2, [2: [.window(21)]], hotkey: plan).get().steps, 0)
        XCTAssertEqual(order, ["passedThrough", "raise"])
        XCTAssertLessThan(h.time.timeIntervalSince(before), 0.8, "the evidence is decisive; no full wait")
        XCTAssertEqual(desktopKeyDowns(h), 1)
        _ = d
    }

    /// When arrival and pass-through are seen in the same check, arrival wins (nothing recorded).
    func testArrivalWinsOverASimultaneousPassThrough() throws {
        let (h, _) = desktopHarness(dock: "passes")
        let deliver = h.onPost
        h.onPost = { event in deliver?(event); if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 19 { h.spaces.active = 2 } }
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(try h.switchSpace(2, [:], hotkey: hotkeyPlan { events.append($0) }).get().steps, 0)
        XCTAssertEqual(events, [.arrived])
    }

    /// Posted but neither arrival nor pass-through confirmed: stop without starting another path, and record nothing.
    func testUnconfirmedDesktopShortcutStopsWithoutRecording() {
        let (h, d) = desktopHarness(dock: "nothing")
        h.spaces.membership = [2]
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan { events.append($0) }), .failure(.hotkeyUnconfirmed))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(d.raises.isEmpty)
        XCTAssertEqual(desktopKeyDowns(h), 1)
        XCTAssertTrue(h.control.failureDetail(.hotkeyUnconfirmed)?.contains("Desktop 1") == true)
    }

    /// Nothing issued (no tap, not ready within 1 s, plan and setting differ, conditions unmet): go to tier 1.
    func testNothingIssuedInTierZeroFallsThroughToWindows() throws {
        for mode in ["tap-failed", "tap-never-ready", "plan-mismatch", "ineligible-at-start"] {
            let (h, d) = desktopHarness(dock: "switches")
            h.spaces.membership = [2]
            if mode == "tap-failed" { d.tap.failOnStart = true }
            if mode == "tap-never-ready" { d.tap.readyOnStart = false }
            let plan = mode == "plan-mismatch" ? hotkeyPlan(shortcut: .init(desktop: 3, id: 120, keyCode: 20, flags: 0x0004_0000))
                : hotkeyPlan(eligible: { mode != "ineligible-at-start" })
            XCTAssertEqual(try h.switchSpace(2, [2: [.window(21)]], hotkey: plan).get().steps, 0, mode)
            XCTAssertEqual(d.raises, [21], mode)
            XCTAssertEqual(desktopKeyDowns(h), 0, mode)
        }
    }

    /// If, after pressing the modifiers and right before the main keyDown, the setting, Dock, Carbon overlap, tap, authorization, or Space changed,
    /// the main key is not sent and only the pressed modifiers are released (the last check is the full pre-send check).
    func testChangeAfterTheModifierStopsBeforeTheMainKey() {
        for mode in ["config", "dock", "conflict", "tap", "tap-disabled-and-reenabled", "input", "space"] {
            let (h, d) = desktopHarness(dock: "switches")
            var eligible = true
            var changed = false
            let server = h.onPost
            h.onPost = { event in
                server?(event)
                guard !changed, event.type == .flagsChanged, event.flags.contains(.maskControl) else { return }
                changed = true
                switch mode {
                case "config": h.hotkey = { id in id == 119 ? .enabled(keyCode: 19, flags: 0x0018_0000) : id == 81 ? .enabled(keyCode: 124, flags: 0x0084_0000) : .disabled }
                case "dock": eligible = false
                case "conflict": h.conflicts = { code, _ in code == 19 }
                case "tap": d.tap.enabled = false
                case "tap-disabled-and-reenabled": d.tap.filter.noteTapDisabled()
                case "input": h.inputs += 1
                default: h.spaces.active = 3
                }
            }
            var events: [SpaceControl.HotkeyEvent] = []
            let result = h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan({ events.append($0) }, eligible: { eligible }))
            XCTAssertEqual(desktopKeyDowns(h), 0, "\(mode): the main key is not sent")
            XCTAssertEqual(h.events.prefix(2).map(\.type), [.flagsChanged, .flagsChanged], "\(mode): Control down and up")
            XCTAssertEqual(h.events.dropFirst().first?.flags.contains(.maskControl), false, mode)
            XCTAssertTrue(events.isEmpty, "\(mode): nothing recorded")
            if ["config", "dock", "conflict"].contains(mode) {
                // Setting or eligibility changed: the main key was not sent yet, so "not sent", and it moves to the next tier (here one stepping step).
                XCTAssertEqual(try? result.get().steps, 1, mode)
            } else {
                // A gate (tap, authorization, Space) failed: stop.
                XCTAssertEqual(result, .failure(.interrupted), mode)
                XCTAssertEqual(h.events.count, 2, "\(mode): nothing else sent")
                XCTAssertTrue(d.raises.isEmpty, mode)
            }
        }
    }

    /// The heavy read (settings fingerprint) is checked first, the cheap gate (authorization) after.
    func testFingerprintIsReadBeforeTheCheapGates() throws {
        let (h, _) = desktopHarness(dock: "switches")
        var log: [String] = []
        var posting = false
        h.onPost = { [onPost = h.onPost] event in posting = true; onPost?(event) }
        _ = try h.switchSpace(2, [:], hotkey: hotkeyPlan(eligible: { if !posting { log.append("fingerprint") }; return true }),
                              shouldContinue: { if !posting { log.append("authorization") }; return true }).get()
        // Check right before the modifier keyDown: fingerprint -> authorization.
        XCTAssertEqual(log.suffix(2), ["fingerprint", "authorization"])
    }

    /// Input or an unexpected Space after posting interrupts (with the place). Keys are released; nothing is recorded.
    func testInputOrUnexpectedSpaceAfterPostingInterrupts() {
        for mode in ["input", "space"] {
            let (h, d) = desktopHarness(dock: "nothing")
            let server = h.onPost
            h.onPost = { event in
                server?(event)
                guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 19 else { return }
                if mode == "input" { h.inputs += 1 } else { h.spaces.active = 3 }
            }
            var events: [SpaceControl.HotkeyEvent] = []
            XCTAssertEqual(h.switchSpace(2, [:], hotkey: hotkeyPlan { events.append($0) }), .failure(.interrupted), mode)
            XCTAssertTrue(events.isEmpty, mode)
            XCTAssertEqual(h.events.filter { $0.type == .keyUp }.count, 1, "\(mode): the key is released")
        }
    }

    /// If the setting or Dock changed after seeing pass-through but before recording, go to tier 1 without recording or guidance; lost authorization interrupts.
    func testPassThroughIsNotRecordedWhenTheFingerprintChanged() throws {
        for mode in ["config", "dock"] {
            let (h, d) = desktopHarness(dock: "passes")
            h.spaces.membership = [2]
            var eligible = true
            let server = h.onPost
            h.onPost = { event in
                server?(event)
                guard event.type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 19 else { return }
                if mode == "config" { h.hotkey = { _ in .disabled } } else { eligible = false }
            }
            var events: [SpaceControl.HotkeyEvent] = []
            XCTAssertEqual(try h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan({ events.append($0) }, eligible: { eligible })).get().steps, 0, mode)
            XCTAssertTrue(events.isEmpty, "\(mode): not recorded")
            XCTAssertEqual(d.raises, [21], mode)
        }
        let (h, _) = desktopHarness(dock: "passes")
        let server = h.onPost
        h.onPost = { event in server?(event); if event.type == .keyUp { h.inputs += 1 } }
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(h.switchSpace(2, [:], hotkey: hotkeyPlan { events.append($0) }), .failure(.interrupted))
        XCTAssertTrue(events.isEmpty)
    }

    /// Our own events arriving late after an interruption or timeout are still swallowed by the same tap (even after the attempt ends) and are no evidence for the next attempt.
    func testLateEventsAfterTheOperationAreStillSwallowed() throws {
        for mode in ["interrupted", "timeout"] {
            let (h, d) = desktopHarness(dock: "late")
            if mode == "interrupted" {
                h.onPost = { event in if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 19 { h.inputs += 1 } }
            }
            XCTAssertEqual(h.switchSpace(2, [:], hotkey: hotkeyPlan()), .failure(mode == "interrupted" ? .interrupted : .hotkeyUnconfirmed), mode)
            let late = h.events
            // During the next operation (the Dock accepts), the previous attempt's events arrive late.
            h.events = []; h.inputs = 0
            h.onPost = { event in
                if event.type == .flagsChanged, event.flags.contains(.maskControl) {
                    for old in late { XCTAssertTrue(Self.deliver(old, to: d), "\(mode): a late event of the earlier attempt is swallowed") }
                }
                Self.windowServer("switches", h, d, event)
            }
            var events: [SpaceControl.HotkeyEvent] = []
            XCTAssertEqual(try h.switchSpace(2, [:], hotkey: hotkeyPlan { events.append($0) }).get().steps, 0, mode)
            XCTAssertEqual(events, [.arrived], "\(mode): the earlier attempt's key is not evidence for this one")
            h.spaces.active = 1
            // Swallowed even after the operations end.
            for old in late + h.events { XCTAssertTrue(Self.deliver(old, to: d), "\(mode): swallowed after both operations returned") }
        }
    }

    /// An attempt whose tap was disabled after posting (then re-enabled) never records or continues on pass-through. Arrival is still success.
    func testCompromisedAttemptNeverFallsBackOnPassThrough() throws {
        for mode in ["after-posting", "after-main-key"] {
            let (h, d) = desktopHarness(dock: "passes")
            h.spaces.membership = [2]
            let server = h.onPost
            h.onPost = { event in
                if mode == "after-posting", event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 19 { d.tap.filter.noteTapDisabled() }
                server?(event)
                if mode == "after-main-key", event.type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 19 { d.tap.filter.noteTapDisabled() }
            }
            var events: [SpaceControl.HotkeyEvent] = []
            XCTAssertEqual(h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan { events.append($0) }), .failure(.hotkeyUnconfirmed), mode)
            XCTAssertTrue(events.isEmpty, "\(mode): no suppression record")
            XCTAssertTrue(d.raises.isEmpty, "\(mode): no fallback")
        }
        let (h, d) = desktopHarness(dock: "switches")
        let server = h.onPost
        h.onPost = { event in server?(event); if event.type == .keyDown { d.tap.filter.noteTapDisabled() } }
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(try h.switchSpace(2, [:], hotkey: hotkeyPlan { events.append($0) }).get().steps, 0, "an arrival is still a switch")
        XCTAssertEqual(events, [.arrived])
    }

    /// After pass-through, the tap was disabled during the final fingerprint reread and the fingerprint also changed: the attempt is damaged,
    /// so it neither records nor moves on to tier 1 (`hotkeyUnconfirmed`).
    func testCompromiseDuringTheFinalReadWinsOverAConfigurationChange() {
        let (h, d) = desktopHarness(dock: "passes")
        h.spaces.membership = [2]
        var posted = false
        let server = h.onPost
        h.onPost = { event in server?(event); if event.type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 19 { posted = true } }
        let eligible = { () -> Bool in
            guard posted else { return true }
            d.tap.filter.noteTapDisabled()
            return false
        }
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan({ events.append($0) }, eligible: eligible)), .failure(.hotkeyUnconfirmed))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(d.raises.isEmpty, "no fallback")
    }

    /// The wait before exiting (lzprobe): ends after a quiet stretch since the last post or arrival; otherwise false at the deadline.
    func testDrainWaitsForQuietTraffic() throws {
        let (h, d) = desktopHarness(dock: "switches")
        _ = try h.switchSpace(2, [:], hotkey: hotkeyPlan()).get()
        let start = h.time
        XCTAssertTrue(h.control.drainPassThrough(quiet: 1.0, timeout: 5))
        XCTAssertLessThan(h.time.timeIntervalSince(start), 1.1)
        d.tap.filter.notePosted()
        h.onSleep = { _ in d.tap.filter.notePosted() }
        XCTAssertFalse(h.control.drainPassThrough(quiet: 1.0, timeout: 2), "never quiet")
    }

    /// The tier-0-only entry (for lzprobe).
    func testDesktopShortcutOnlyEntry() {
        let (h, _) = desktopHarness(dock: "passes")
        XCTAssertEqual(h.control.switchViaDesktopShortcut(spaceID: 2, plan: hotkeyPlan(), source: 1), .passedThrough)
        let (other, _) = desktopHarness(dock: "switches")
        guard case .switched(let result) = other.control.switchViaDesktopShortcut(spaceID: 2, plan: hotkeyPlan()) else { return XCTFail("not switched") }
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(other.control.switchViaDesktopShortcut(spaceID: 3, plan: hotkeyPlan(), source: 2), .notUsed, "another source")
    }

    // MARK: - Hotkey parts: left/right stepping, dragging, following

    /// Replaces left/right key suppression and recording. Recording a pass-through suppresses that setting from then on (as in Coordinator).
    private final class ArrowRecorder {
        var suppressed: Set<SpaceControl.ArrowHotkey> = []
        var reports: [String] = []
        var policy: SpaceControl.ArrowPolicy {
            SpaceControl.ArrowPolicy(isSuppressed: { self.suppressed.contains($0) }, stillEligible: { true }, report: { arrow, event in
                self.reports.append("\(arrow.right ? "right" : "left") \(event)")
                if event == .passedThrough { self.suppressed.insert(arrow) }
            })
        }
    }

    private static let right = SpaceControl.ArrowHotkey(right: true, keyCode: 124, flags: 0x0084_0000)

    /// A harness where WindowServer does not take the right arrow (pass-through): the main keyDown reaches the tap and the Space does not change.
    private func arrowPassesThrough(_ h: SpaceHarness) {
        h.switchOnArrow = false
        h.onPost = { [weak h] event in
            guard let h, event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return }
            _ = h.tap.filter.intercept(type: event.type, userData: event.getIntegerValueField(.eventSourceUserData),
                                       keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        }
    }

    private func arrowKeyDowns(_ h: SpaceHarness) -> Int {
        h.events.filter { $0.type == .keyDown && [123, 124].contains($0.getIntegerValueField(.keyboardEventKeycode)) }.count
    }

    /// Detecting pass-through while stepping stops right there with guidance (no fallback to another path). It is a switch, so it is recorded; the next operation stops in the preflight.
    func testSteppingPassThroughStopsImmediatelyAndIsRecorded() {
        let h = SpaceHarness(); arrowPassesThrough(h)
        let recorder = ArrowRecorder()
        let before = h.time
        XCTAssertEqual(h.switchSpace(3, [:], arrows: recorder.policy), .failure(.steppingUnavailable(.notHonored(right: true))))
        XCTAssertLessThan(h.time.timeIntervalSince(before), 0.5, "no 2 s timeout")
        XCTAssertEqual(arrowKeyDowns(h), 1, "only the first step was sent")
        XCTAssertEqual(recorder.reports, ["right passedThrough"])
        XCTAssertTrue(h.control.failureDetail(.steppingUnavailable(.notHonored(right: true)))?.contains("Desktop 1") == true)
        // Second operation: hits the suppression in the preflight and sends nothing.
        h.events = []
        XCTAssertEqual(h.switchSpace(3, [:], arrows: recorder.policy), .failure(.steppingUnavailable(.suppressed(right: true))))
        XCTAssertTrue(h.events.isEmpty)
        // Suppression is per direction: left still works.
        h.spaces.active = 3; h.switchOnArrow = true; h.onPost = nil
        XCTAssertEqual(try? h.switchSpace(2, [:], arrows: recorder.policy).get().steps, 1)
    }

    /// If the preflight (tap, suppression) fails, no jump to an intermediate Space (the rest could not be stepped).
    func testHopNeedsAPreparedArrowFirst() {
        for mode in ["no-tap", "suppressed"] {
            let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
            h.control.direct = d.path(h)
            let recorder = ArrowRecorder()
            if mode == "no-tap" { h.tap.failOnStart = true } else { recorder.suppressed = [Self.right] }
            let result = h.switchSpace(5, [4: [app(504)]], arrows: recorder.policy)
            XCTAssertEqual(result, .failure(.steppingUnavailable(mode == "no-tap" ? .noTap : .suppressed(right: true))), mode)
            XCTAssertTrue(d.activations.isEmpty, "\(mode): no hop")
            XCTAssertTrue(h.events.isEmpty, mode)
        }
    }

    /// Left/right are not limited like Desktops (display count, rearranging). Adjacency is reread right before posting, and a changed order replans once.
    func testArrowAdjacencyIsRecheckedAndReplannedOnce() throws {
        let h = SpaceHarness(); fiveSpaces(h)
        h.switchOnArrow = false
        var reorders = 1
        h.onPost = { event in
            guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124,
                  let active = h.spaces.active, let i = h.spaces.order.firstIndex(of: active), i + 1 < h.spaces.order.count else { return }
            h.spaces.active = h.spaces.order[i + 1]
            // The order changes after the first step (3 and 4 swap).
            if reorders > 0 { reorders -= 1; h.spaces.order = [1, 2, 4, 3, 5] }
        }
        let result = try h.switchSpace(5, [:]).get()
        XCTAssertEqual(result.steps, 4, "1 → 2, then re-planned along 4, 3, 5")
        XCTAssertEqual(h.spaces.active, 5)

        // A second change stops without replanning (3 and 4 swap after step 1, 5 and 3 after step 2).
        let other = SpaceHarness(); fiveSpaces(other)
        other.switchOnArrow = false
        var orders: [[UInt64]] = [[1, 2, 4, 3, 5], [1, 2, 4, 5, 3]]
        other.onPost = { event in
            guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124,
                  let active = other.spaces.active, let i = other.spaces.order.firstIndex(of: active), i + 1 < other.spaces.order.count else { return }
            other.spaces.active = other.spaces.order[i + 1]
            if !orders.isEmpty { other.spaces.order = orders.removeFirst() }
        }
        XCTAssertEqual(other.switchSpace(3, [:]), .failure(.routeChanged))
        XCTAssertEqual(arrowKeyDowns(other), 2, "re-planned once, then stopped")
    }

    /// An interruption during slow validation means "stop", not "not sent, so another path". The same for tier 0 and stepping.
    func testInterruptionDuringSlowValidationStops() {
        let (h, d) = desktopHarness(dock: "switches")
        h.spaces.membership = [2]
        var reads = 0
        let base = h.hotkey
        h.hotkey = { id in
            if id == 119 { reads += 1; if reads == 2 { h.inputs += 1 } } // input during the reread right before posting
            return base(id)
        }
        XCTAssertEqual(h.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan()), .failure(.interrupted))
        XCTAssertTrue(d.raises.isEmpty, "no other tier after an interruption")
        XCTAssertTrue(h.events.isEmpty)

        let stepping = SpaceHarness()
        var arrowReads = 0
        stepping.hotkey = { id in
            arrowReads += 1
            if arrowReads == 3 { stepping.inputs += 1 }
            return .enabled(keyCode: 124, flags: 0x0084_0000)
        }
        XCTAssertEqual(stepping.switchSpace(3, [:]), .failure(.interrupted))
        XCTAssertEqual(arrowKeyDowns(stepping), 0)
    }

    /// Observation after posting: an unexpected Space interrupts, damage counts as a timeout (no pass-through evidence), and active may be unreadable.
    func testArrowObservationOutcomes() {
        for mode in ["unexpected", "compromised", "unreadable"] {
            let h = SpaceHarness(); fiveSpaces(h)
            h.switchOnArrow = false
            h.onPost = { event in
                guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124 else { return }
                switch mode {
                case "unexpected": h.spaces.active = 4
                case "compromised":
                    h.tap.filter.noteTapDisabled()
                    _ = h.tap.filter.intercept(type: .keyDown, userData: event.getIntegerValueField(.eventSourceUserData), keyCode: 124)
                default: h.spaces.active = nil
                }
            }
            let result = h.switchSpace(3, [:])
            switch mode {
            case "unexpected": XCTAssertEqual(result, .failure(.interrupted), mode)
            case "compromised": guard case .failure(.timedOut) = result else { return XCTFail("\(mode): \(result)") }
            default: guard case .failure(.unavailable) = result else { return XCTFail("\(mode): \(result)") }
            }
            XCTAssertEqual(arrowKeyDowns(h), 1, mode)
        }
    }

    /// Even without `direct` (pure stepping), SpaceControl owns the tap, so pass-through is detected.
    func testPassThroughDetectionWorksWithoutTheDirectPath() {
        let h = SpaceHarness(); arrowPassesThrough(h)
        XCTAssertNil(h.control.direct)
        XCTAssertEqual(h.control.switchTo(spaceID: 2), .failure(.steppingUnavailable(.notHonored(right: true))))
    }

    /// Drag stepping runs the preflight before the mouse goes down; on failure nothing is grabbed.
    func testDragSteppingIsPreparedBeforeTheMouseGoesDown() {
        for mode in ["no-tap", "suppressed"] {
            let h = SpaceHarness()
            let recorder = ArrowRecorder()
            if mode == "no-tap" { h.tap.failOnStart = true } else { recorder.suppressed = [Self.right] }
            XCTAssertEqual(h.move(to: 2, arrows: recorder.policy), .failure(.steppingUnavailable(mode == "no-tap" ? .noTap : .suppressed(right: true))), mode)
            XCTAssertFalse(h.events.contains { $0.type == .leftMouseDown }, mode)
            XCTAssertTrue(h.warps.isEmpty, mode)
        }
    }

    /// Pass-through while dragging: release the mouse and stop. Not recorded (behavior during drags is unverified). The place is noted after release.
    func testDragPassThroughReleasesTheMouseWithoutRecording() {
        let h = SpaceHarness(); arrowPassesThrough(h)
        let recorder = ArrowRecorder()
        XCTAssertEqual(h.move(to: 2, arrows: recorder.policy), .failure(.steppingUnavailable(.notHonored(right: true))))
        XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1, "the mouse is released")
        XCTAssertTrue(recorder.reports.isEmpty, "no suppression is recorded during a drag")
        XCTAssertNotNil(h.control.failureDetail(.steppingUnavailable(.notHonored(right: true))), "the place is noted")
    }

    /// Every drag exit (interruption, timeout, pass-through) releases the mouse before noting the place.
    func testEveryDragExitReleasesTheMouseBeforeNotingThePlace() {
        for mode in ["interrupted", "timeout", "passThrough"] {
            let h = SpaceHarness()
            var releasedBeforeNote = false
            if mode == "passThrough" { arrowPassesThrough(h) }
            if mode == "timeout" { h.switchOnArrow = false }
            let base = h.onPost
            h.onPost = { event in
                base?(event)
                if mode == "interrupted", event.type == .keyDown, [123, 124].contains(event.getIntegerValueField(.keyboardEventKeycode)) { h.inputs += 1 }
                if event.type == .leftMouseUp { releasedBeforeNote = h.control.placeNote == nil }
            }
            let result = h.move(to: 2)
            if case .success = result { XCTFail("\(mode) succeeded") }
            XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1, mode)
            XCTAssertTrue(releasedBeforeNote, "\(mode): released before the place was noted")
            if case .failure(let failure) = result { XCTAssertNotNil(h.control.failureDetail(failure), mode) }
        }
    }

    /// Follow: after the membership change, switch with the Desktop shortcut, bring the carried window forward, and succeed once its app is seen in front.
    func testMoveFollowUsesTheDesktopShortcutThenConfirmsTheFront() throws {
        let (h, d) = desktopHarness(dock: "switches")
        var events: [SpaceControl.HotkeyEvent] = []
        let result = try h.move(to: 2, follow: hotkeyPlan { events.append($0) }).get()
        XCTAssertEqual(result.steps, 0)
        XCTAssertEqual(result.fromSpace, 1)
        XCTAssertEqual(d.moves.map(\.1), [2])
        XCTAssertEqual(desktopKeyDowns(h), 1)
        XCTAssertEqual(d.raises, [10], "the carried window is raised after arriving")
        XCTAssertTrue(d.reactivates.isEmpty)
        XCTAssertEqual(h.frontmost, 700)
        XCTAssertEqual(events, [.arrived])
    }

    /// If follow's activation is refused or unconfirmed, `frontUnconfirmed` (with the place, no other moves). Confirmed late, it succeeds.
    func testMoveFollowFrontConfirmation() throws {
        for mode in ["refused", "never", "late"] {
            let (h, d) = desktopHarness(dock: "switches")
            if mode == "refused" { d.raiseOutcome = .refused; d.raiseReports = false }
            if mode == "never" { d.activationTakesEffect = false }
            if mode == "late" {
                d.raiseReports = false
                var polls = 0
                h.onSleep = { interval in
                    guard interval == 0.02, d.lastRaiseReport != nil else { return }
                    polls += 1
                    if polls == 3 { d.lastRaiseReport?(.requested(800)) }
                    if polls == 6 { h.frontmost = 800 }
                }
            }
            let result = h.move(to: 2, follow: hotkeyPlan())
            if mode == "late" { XCTAssertEqual(try result.get().steps, 0, mode); continue }
            XCTAssertEqual(result, .failure(.frontUnconfirmed), mode)
            XCTAssertEqual(d.raises, [10], "\(mode): no other move")
            XCTAssertEqual(d.moves.count, 1, mode)
            XCTAssertTrue(h.control.failureDetail(.frontUnconfirmed)?.contains("Window: Desktop 2") == true, "\(mode): \(h.control.failureDetail(.frontUnconfirmed) ?? "")")
        }
    }

    /// Confirming follow's activation needs the report that this raise requested activation (`requested(owner)`). Even if the owner app is in front from the start,
    /// a raise that timed out (no activation queued, `abandoned`) is not success.
    func testMoveFollowNeedsThisRaisesOwnActivation() {
        let (h, d) = desktopHarness(dock: "switches")
        h.frontmost = 700 // the carried window's app is in front from the start
        d.raiseOutcome = .unknown; d.raiseReports = false
        h.control.direct?.raise = { wid, _, report in d.raises.append(wid); report(.abandoned); return .unknown }
        XCTAssertEqual(h.move(to: 2, follow: hotkeyPlan()), .failure(.frontUnconfirmed))
        XCTAssertEqual(d.raises, [10])
    }

    /// The setting changed after the preflight (overlapping a LazySpace shortcut between steps): a "not sent" that cannot be replanned stops.
    /// The text keeps the setting name and reason and says "the rest of the moves were not sent" (not "nothing was sent"), with the place. Drags release first.
    func testNotIssuedBetweenStepsStops() {
        for drag in [false, true] {
            let h = SpaceHarness()
            var releasedBeforeNote = false
            let base = h.onPost
            h.onPost = { event in
                base?(event)
                if event.type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == 124 { h.conflicts = { code, _ in code == 124 } }
                if event.type == .leftMouseUp { releasedBeforeNote = h.control.placeNote == nil }
            }
            let result = drag ? h.move(to: 3) : h.control.switchTo(spaceID: 3)
            guard case .failure(let failure) = result, case .steppingUnavailable(.configuration(let why)) = failure else { return XCTFail("\(drag): \(result)") }
            XCTAssertTrue(why.contains("matches a LazySpace shortcut"), why)
            XCTAssertTrue(why.contains("The remaining steps were not sent."), why)
            XCTAssertFalse(why.contains("Nothing was sent"), why)
            XCTAssertTrue(why.contains("System Settings › Keyboard › Keyboard Shortcuts… › Mission Control"), why)
            XCTAssertEqual(arrowKeyDowns(h), 1, "\(drag): stopped after the first step")
            let place = h.control.failureDetail(failure) ?? ""
            XCTAssertTrue(place.contains("Desktop 2"), "\(drag): \(place)")
            if drag {
                XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1, "released")
                XCTAssertTrue(releasedBeforeNote, "released before the place was noted")
                XCTAssertTrue(place.contains("Window:"), place)
            }
        }
    }

    /// Validation failed while an interruption or damage also happened: stop conditions are checked first (no moving on to the next tier as "not sent").
    func testTerminalConditionsWinOverAFailedValidation() {
        // Tier 0's first validation: conditions fail and input arrives at the same time.
        let (first, fd) = desktopHarness(dock: "switches")
        first.spaces.membership = [2]
        XCTAssertEqual(first.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan(eligible: { first.inputs += 1; return false })), .failure(.interrupted))
        XCTAssertTrue(fd.raises.isEmpty, "no other tier")
        XCTAssertTrue(first.events.isEmpty)

        // Right before tier 0's main key: the setting changes and the tap is disabled at the same time (damage).
        let (second, sd) = desktopHarness(dock: "switches")
        second.spaces.membership = [2]
        let server = second.onPost
        second.onPost = { event in
            server?(event)
            guard event.type == .flagsChanged, event.flags.contains(.maskControl) else { return }
            second.hotkey = { id in id == 119 ? .enabled(keyCode: 19, flags: 0x0018_0000) : id == 81 ? .enabled(keyCode: 124, flags: 0x0084_0000) : .disabled }
            sd.tap.filter.noteTapDisabled()
        }
        XCTAssertEqual(second.switchSpace(2, [2: [.window(21)]], hotkey: hotkeyPlan()), .failure(.interrupted))
        XCTAssertTrue(sd.raises.isEmpty, "no other tier")
        XCTAssertEqual(arrowKeyDowns(second), 0, "no stepping")

        // Stepping's first validation: the shortcut turns off and input arrives at the same time.
        let stepping = SpaceHarness()
        var reads = 0
        stepping.hotkey = { _ in
            reads += 1
            if reads == 3 { stepping.inputs += 1; return .disabled }
            return .enabled(keyCode: 124, flags: 0x0084_0000)
        }
        XCTAssertEqual(stepping.control.switchTo(spaceID: 3), .failure(.interrupted))
        XCTAssertTrue(stepping.events.isEmpty)
    }

    /// While dragging, a changed order is never replanned: release, stop, and add the place (a switch replans once).
    func testDragNeverReplans() {
        let h = SpaceHarness(); fiveSpaces(h)
        h.switchOnArrow = false
        var reordered = false
        h.onPost = { event in
            guard event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124,
                  let active = h.spaces.active, let i = h.spaces.order.firstIndex(of: active), i + 1 < h.spaces.order.count else { return }
            h.spaces.active = h.spaces.order[i + 1]
            if !reordered { reordered = true; h.spaces.order = [1, 2, 4, 3, 5] }
        }
        let result = h.move(to: 5)
        XCTAssertEqual(result, .failure(.routeChanged))
        XCTAssertEqual(arrowKeyDowns(h), 1, "no further arrow after the order changed")
        XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1)
        XCTAssertTrue(h.control.failureDetail(.routeChanged)?.contains("Current Space: Desktop 2") == true, h.control.failureDetail(.routeChanged) ?? "")
    }

    /// A ready tap that the system disabled is not a receiver; neither stepping nor dragging sends anything.
    func testReadyButDisabledTapIsNotAReceiver() {
        let switching = SpaceHarness()
        switching.tap.start(); switching.tap.enabled = false
        XCTAssertEqual(switching.control.switchTo(spaceID: 2), .failure(.steppingUnavailable(.noTap)))
        XCTAssertTrue(switching.events.isEmpty)
        let drag = SpaceHarness()
        drag.tap.start(); drag.tap.enabled = false
        XCTAssertEqual(drag.move(to: 2), .failure(.steppingUnavailable(.noTap)))
        XCTAssertFalse(drag.events.contains { $0.type == .leftMouseDown })
    }

    /// If the setting changes or outside conditions fail while waiting for the tap, the reread after readiness stops it: no jump to an intermediate Space, no mouse-down.
    func testConfigurationChangeDuringTapStartupStopsBeforeAnything() {
        for mode in ["switch", "hop", "drag"] {
            let h = SpaceHarness(); let d = DirectStub()
            if mode == "hop" { fiveSpaces(h); h.control.direct = d.path(h) }
            h.tap.readyOnStart = false
            var waits = 0
            h.onSleep = { interval in
                guard interval == 0.02, h.tap.current == .starting else { return }
                waits += 1
                if waits == 3 { h.tap.current = .ready; h.hotkey = { _ in .disabled } }
            }
            let result = mode == "drag" ? h.move(to: 2) : mode == "hop" ? h.switchSpace(5, [4: [app(504)]]) : h.control.switchTo(spaceID: 2)
            guard case .failure(.unavailable(let why)) = result else { return XCTFail("\(mode): \(result)") }
            XCTAssertTrue(why.contains("is off"), "\(mode): \(why)")
            XCTAssertTrue(h.events.isEmpty, "\(mode): nothing sent, no mouse")
            XCTAssertTrue(d.activations.isEmpty, "\(mode): no hop")
        }
        // Outside conditions (the Dock changed): stop, separately from suppression.
        let h = SpaceHarness(); fiveSpaces(h)
        let d = DirectStub(); h.control.direct = d.path(h)
        let policy = SpaceControl.ArrowPolicy(stillEligible: { false })
        guard case .failure(.steppingUnavailable(.configuration(let why))) = h.switchSpace(5, [4: [app(504)]], arrows: policy) else { return XCTFail("hopped with an ineligible arrow") }
        XCTAssertTrue(why.contains("Nothing was sent"), why)
        XCTAssertTrue(d.activations.isEmpty)
    }

    /// If follow's shortcut passes through or is not sent, the older follow (raise) is used; if it stopped, no other path starts.
    func testMoveFollowFallsBackOrStops() throws {
        let (passes, pd) = desktopHarness(dock: "passes")
        var events: [SpaceControl.HotkeyEvent] = []
        XCTAssertEqual(try passes.move(to: 2, follow: hotkeyPlan { events.append($0) }).get().steps, 0)
        XCTAssertEqual(events, [.passedThrough])
        XCTAssertEqual(pd.raises, [10], "the usual follow by raising the window")

        let (off, od) = desktopHarness(dock: "switches")
        off.hotkey = { _ in .disabled }
        XCTAssertEqual(try off.move(to: 2, follow: hotkeyPlan()).get().steps, 0)
        XCTAssertEqual(od.raises, [10])
        XCTAssertEqual(desktopKeyDowns(off), 0)

        let (nothing, nd) = desktopHarness(dock: "nothing")
        XCTAssertEqual(nothing.move(to: 2, follow: hotkeyPlan()), .failure(.hotkeyUnconfirmed))
        XCTAssertTrue(nd.raises.isEmpty, "no raise after an unconfirmed shortcut")
        XCTAssertTrue(nothing.control.failureDetail(.hotkeyUnconfirmed)?.contains("Window: Desktop 2") == true, "the window is on the target")
    }

    // MARK: - Authorized source, and collecting app candidates lazily

    func testSwitchStartingFromAnotherSpaceThanAuthorizedDoesNothing() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h); h.spaces.active = 2
        h.control.direct = d.path(h)
        XCTAssertEqual(h.switchSpace(5, [5: [app(505)], 4: [app(504)]], source: 1), .failure(.interrupted))
        XCTAssertTrue(d.activations.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertEqual(h.appCollections, 0)
    }

    /// If the Space changes (not counted as input) or input arrives while collecting candidates, neither activation nor keys are issued.
    func testChangeWhileCollectingAppCandidatesStopsBeforeAnyAction() {
        for change in ["space", "input"] {
            let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
            h.control.direct = d.path(h)
            let result = h.switchSpace(5, [5: [app(505)], 4: [app(504)]], source: 1, onCollect: {
                if change == "space" { h.spaces.active = 2 } else { h.inputs += 1 }
            })
            XCTAssertEqual(result, .failure(.interrupted), change)
            XCTAssertTrue(d.activations.isEmpty, change)
            XCTAssertTrue(h.events.isEmpty, change)
        }
    }

    func testAppCandidatesAreCollectedOnlyAfterEveryWindowWasRefused() throws {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.membership = [3]
        h.control.direct = d.path(h)
        XCTAssertEqual(try h.switchSpace(3, [3: [.window(21), app(501)]]).get().steps, 0)
        XCTAssertEqual(h.appCollections, 0, "a raised window needs no app inventory")

        let refused = SpaceHarness(); let r = DirectStub(); r.raiseOutcome = .refused; r.raiseSwitches = false; fiveSpaces(refused)
        refused.control.direct = r.path(refused)
        XCTAssertEqual(try refused.switchSpace(5, [5: [.window(51)], 4: [app(504)]]).get().steps, 1)
        XCTAssertEqual(refused.appCollections, 1, "collected once for the target and the Spaces in between")
    }

    /// One interruption baseline covers the whole trip. Input during the settle wait after arriving or mid-stepping also stops it, with the actual place.
    func testOneInputBaselineCoversBothLegs() {
        for when in ["stabilization", "stepping"] {
            let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
            h.control.direct = d.path(h)
            if when == "stabilization" { h.onSleep = { interval in if interval == 0.3 { h.inputs += 1 } } }
            else { h.onPost = { event in if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124 { h.inputs += 1 } } }
            XCTAssertEqual(h.switchSpace(5, [3: [app(503)]], hop: true), .failure(.interrupted), when)
            XCTAssertEqual(keyDowns(h), when == "stabilization" ? 0 : 1, when)
            let place = when == "stabilization" ? "Desktop 3" : "Desktop 4"
            XCTAssertTrue(h.control.failureDetail(.interrupted)?.contains(place) == true, "\(when): \(h.control.failureDetail(.interrupted) ?? "")")
        }
    }

    func testCancellationDuringTheHopStopsBeforeStepping() {
        let h = SpaceHarness(); let d = DirectStub(); fiveSpaces(h)
        h.control.direct = d.path(h)
        h.onSleep = { interval in if interval == 0.3 { h.allowed = false } }
        XCTAssertEqual(h.switchSpace(5, [4: [app(504)]], hop: true, shouldContinue: { h.allowed }), .failure(.interrupted))
        XCTAssertEqual(keyDowns(h), 0)
    }

    func testUnavailableInputMonitoringPreventsAllSyntheticInput() {
        let h = SpaceHarness(); h.inputAvailable = false
        guard case .failure(.unavailable) = h.move() else { return XCTFail("Move proceeded without input monitoring") }
        guard case .failure(.unavailable) = h.control.switchTo(spaceID: 2) else { return XCTFail("Switch proceeded without input monitoring") }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.warps.isEmpty)
    }

    func testMonitoringLossDuringDragReleasesMouse() {
        let h = SpaceHarness()
        h.onPost = { event in if event.type == .leftMouseDown { h.inputAvailable = false } }
        XCTAssertEqual(h.move(), .failure(.interrupted))
        XCTAssertEqual(h.events.last?.type, .leftMouseUp)
        XCTAssertEqual(h.warps.count, 1)
    }

    func testSwitchVerifiesEveryStepAndTagsSyntheticEvents() throws {
        let h = SpaceHarness()
        let result = try h.control.switchTo(spaceID: 3).get()
        XCTAssertEqual(result.steps, 2)
        XCTAssertEqual(h.spaces.active, 3)
        // Left/right keys also carry attempt tags (the tap swallows only its own events and InputMonitor does not count them).
        XCTAssertTrue(h.events.allSatisfy { h.tap.filter.owns($0.getIntegerValueField(.eventSourceUserData)) })
        XCTAssertTrue(h.events.allSatisfy { SpaceControl.isSynthetic($0.getIntegerValueField(.eventSourceUserData)) })
    }

    func testPreCancelledMoveEmitsNoEventsOrCursorWarp() {
        let h = SpaceHarness(); h.allowed = false
        XCTAssertEqual(h.move(), .failure(.interrupted))
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.warps.isEmpty)
    }

    func testInputDuringInitialDragReleasesMouseWithoutRestoringCursor() {
        let h = SpaceHarness()
        h.onPost = { event in if event.type == .leftMouseDragged { h.inputs += 1 } }
        XCTAssertEqual(h.move(), .failure(.interrupted))
        XCTAssertEqual(h.events.last?.type, .leftMouseUp)
        XCTAssertEqual(h.events.last?.location, h.cursor)
        XCTAssertEqual(h.warps.count, 1)
        XCTAssertFalse(h.events.contains { $0.type == .keyDown })
    }

    func testPauseDuringControlPressReleasesKeysAndMouse() {
        let h = SpaceHarness()
        h.onPost = { event in if event.getIntegerValueField(.keyboardEventKeycode) == 59, event.flags.contains(.maskControl) { h.allowed = false } }
        XCTAssertEqual(h.move(), .failure(.interrupted))
        let keys = h.events.filter { $0.type == .keyDown || $0.type == .keyUp || $0.type == .flagsChanged }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.last?.flags.contains(.maskControl), false)
        XCTAssertEqual(keys.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [59, 59])
        XCTAssertEqual(h.events.last?.type, .leftMouseUp)
        XCTAssertEqual(h.warps.count, 1)
    }

    func testInputDuringWaitStopsBeforeTimeout() {
        let h = SpaceHarness(); h.switchOnArrow = false
        h.onSleep = { interval in if interval == 0.05 { h.inputs += 1 } }
        XCTAssertEqual(h.control.switchTo(spaceID: 2), .failure(.interrupted))
        XCTAssertLessThan(h.time.timeIntervalSince1970, 0.3)
    }

    func testInputBeforeFinalReleaseDoesNotFinishMove() {
        let h = SpaceHarness()
        h.onSleep = { interval in if interval == 0.2 { h.inputs += 1 } }
        XCTAssertEqual(h.move(), .failure(.interrupted))
        XCTAssertEqual(h.events.last?.type, .leftMouseUp)
        XCTAssertEqual(h.warps.count, 1)
    }

    func testMissingFinalSpaceIsNotSuccessfulSwitch() {
        let h = SpaceHarness()
        // The Space is unreadable on the final read right after arrival is observed.
        _ = watchArrival(h, at: 2) { h.spaces.active = nil }
        guard case .failure(.unavailable) = h.control.switchTo(spaceID: 2) else { return XCTFail("Unobserved Space reported success") }
    }

    func testSuccessfulMoveVerifiesMembershipAndRestoresCursor() throws {
        let h = SpaceHarness()
        XCTAssertEqual(try h.move().get().toSpace, 2)
        XCTAssertEqual(h.spaces.membership, [2])
        XCTAssertEqual(h.warps.last, h.cursor)
        XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1)
    }

    func testOtherSpaceAndStickyWindowsAreNeverDragged() {
        for membership: [UInt64] in [[2], [1, 2], []] {
            let h = SpaceHarness(); h.spaces.membership = membership
            guard case .failure = h.move() else { return XCTFail("Excluded window was moved") }
            XCTAssertTrue(h.events.isEmpty)
            XCTAssertTrue(h.warps.isEmpty)
        }
    }

    func testRejectsUnusableShortcutsBeforeAnyInput() {
        let control: UInt32 = 0x0004_0000
        let shift: UInt32 = 0x0002_0000
        let fn: UInt32 = 0x0080_0000
        let pad: UInt32 = 0x0020_0000
        let caps: UInt32 = 0x0001_0000
        let help: UInt32 = 0x0040_0000
        let samples: [(PrivateSymbols.SymbolicHotKey, String)] = [
            (.unknown, "Could not read"),
            (.disabled, "is off"),
            (.enabled(keyCode: 65535, flags: control), "no key assigned"),
            (.enabled(keyCode: 65536, flags: control), "cannot be sent"),
            (.enabled(keyCode: 200, flags: control), "cannot be sent"),
            (.enabled(keyCode: 59, flags: control), "modifier key alone"),
            (.enabled(keyCode: 38, flags: shift), "uses Shift without"),
            (.enabled(keyCode: 38, flags: 0), "does not include Control, Option, or Command"),
            (.enabled(keyCode: 38, flags: control | caps), "Caps Lock"),
            (.enabled(keyCode: 38, flags: control | pad), "does not recognize"),
            (.enabled(keyCode: 38, flags: control | help), "does not recognize"),
            (.enabled(keyCode: 38, flags: control | 1), "does not recognize"),
            (.enabled(keyCode: 38, flags: control | fn), "key other than an arrow"),
            (.enabled(keyCode: 0x7A, flags: control), "function key"),
            (.enabled(keyCode: 0x48, flags: control), "media key"),
            (.enabled(keyCode: 0x24, flags: control), "extended key"),
            (.enabled(keyCode: 0x52, flags: control), "extended key"),
        ]
        for (hotkey, needle) in samples {
            for useMove in [false, true] {
                let h = SpaceHarness()
                h.hotkey = { _ in hotkey }
                let result = useMove ? h.move() : h.control.switchTo(spaceID: 2)
                guard case .failure(.unavailable(let why)) = result else {
                    return XCTFail("\(needle) move=\(useMove) sent input")
                }
                XCTAssertTrue(why.contains(needle), why)
                XCTAssertTrue(why.contains("Nothing was sent"), why)
                XCTAssertTrue(why.contains("Move right a Space"), why)
                XCTAssertTrue(why.contains("System Settings › Keyboard › Keyboard Shortcuts… › Mission Control"), why)
                XCTAssertFalse(why.contains("⌃"), why)
                XCTAssertTrue(h.events.isEmpty)
                XCTAssertTrue(h.warps.isEmpty)
                XCTAssertNil(h.control.placeNote)
                XCTAssertNil(h.control.failureDetail(.unavailable(why)))
            }
        }
    }

    func testJapaneseRefusalNamesTheMissionControlShortcut() {
        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        let h = SpaceHarness()
        h.hotkey = { _ in .disabled }
        guard case .failure(.unavailable(let why)) = h.control.switchTo(spaceID: 2) else {
            return XCTFail("disabled shortcut was sent")
        }
        XCTAssertTrue(why.contains("右の操作スペースに移動"), why)
        XCTAssertTrue(why.contains("オフです"), why)
        XCTAssertTrue(why.contains("何も送信していません"), why)
        XCTAssertTrue(why.contains("システム設定 › キーボード › キーボードショートカット… › Mission Control"), why)
        XCTAssertFalse(why.contains("⌃"), why)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.warps.isEmpty)
    }

    func testRegisteredCommandBlocksBeforeSending() {
        let monitor = InputMonitor()
        monitor.setCommandKeys([InputMonitor.CommandKey(keyCode: 124, carbonModifiers: 0x1000)])
        XCTAssertTrue(monitor.matchesCommand(keyCode: 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]))
        XCTAssertFalse(monitor.matchesCommand(keyCode: 38, flags: [.maskControl, .maskAlternate, .maskSecondaryFn]))
        let blocked = SpaceHarness()
        blocked.conflicts = { monitor.matchesCommand(keyCode: Int64($0), flags: $1) }
        for useMove in [false, true] {
            blocked.events.removeAll()
            blocked.warps.removeAll()
            let result = useMove ? blocked.move() : blocked.control.switchTo(spaceID: 2)
            guard case .failure(.unavailable(let why)) = result else { return XCTFail("registered shortcut was sent") }
            XCTAssertTrue(why.contains("matches a LazySpace shortcut"), why)
            XCTAssertTrue(blocked.events.isEmpty)
            XCTAssertTrue(blocked.warps.isEmpty)
        }
        let other = SpaceHarness()
        other.conflicts = { monitor.matchesCommand(keyCode: Int64($0), flags: $1) }
        monitor.setCommandKeys([InputMonitor.CommandKey(keyCode: 38, carbonModifiers: 0x1000)])
        XCTAssertEqual(try other.control.switchTo(spaceID: 2).get().toSpace, 2)
    }

    func testDisabledOppositeDirectionDoesNotBlockTheDirectionInUse() throws {
        let h = SpaceHarness()
        h.hotkey = { id in id == 79 ? .disabled : .enabled(keyCode: 124, flags: 0x0084_0000) }
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().toSpace, 2)
        XCTAssertEqual(Set(h.hotkeyReads), [81], "re-read before every key-down, only this direction")
        h.events.removeAll(); h.warps.removeAll(); h.hotkeyReads.removeAll()
        h.spaces.active = 1
        XCTAssertEqual(try h.move().get().toSpace, 2)
        XCTAssertEqual(Set(h.hotkeyReads), [81], "re-read before every key-down, only this direction")
        h.events.removeAll(); h.warps.removeAll(); h.hotkeyReads.removeAll()
        h.spaces.active = 2
        h.spaces.membership = [2]
        guard case .failure(.unavailable(let why)) = h.control.switchTo(spaceID: 1) else { return XCTFail("disabled left shortcut was sent") }
        XCTAssertTrue(why.contains("Move left a Space"), why)
        XCTAssertTrue(why.contains("is off"), why)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.warps.isEmpty)
        h.hotkeyReads.removeAll()
        guard case .failure = h.move(to: 1) else { return XCTFail("disabled left move was sent") }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.warps.isEmpty)
        XCTAssertEqual(Set(h.hotkeyReads), [79], "re-read before every key-down, only this direction")
    }

    func testLaterOperationReadsTheUpdatedHotkey() throws {
        let h = SpaceHarness()
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().steps, 1)
        XCTAssertEqual(h.posted.map { $0.code }, [59, 124, 124, 59])
        h.events.removeAll()
        h.posted.removeAll()
        h.hotkeyReads.removeAll()
        h.spaces.active = 1
        h.rightKey = 38
        h.hotkey = { id in
            XCTAssertEqual(id, 81)
            return .enabled(keyCode: 38, flags: 0x000C_0000)
        }
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().toSpace, 2)
        XCTAssertEqual(Set(h.hotkeyReads), [81], "re-read before every key-down, only this direction")
        XCTAssertEqual(h.posted.map { $0.code }, [59, 58, 38, 38, 58, 59])
        XCTAssertFalse(h.posted.contains { $0.code == 124 })
    }

    /// Left/right keys fingerprint the setting read in the preflight and reread it before each keyDown. If it changes midway (turned off), nothing more is sent and it stops with the setting name.
    func testEveryKeyDownRereadsTheShortcutAndStopsWhenItChanges() throws {
        let h = SpaceHarness()
        var calls = 0
        h.hotkey = { id in
            calls += 1
            XCTAssertEqual(id, 81)
            if calls > 1 { return .disabled }
            return .enabled(keyCode: 124, flags: 0x0084_0000)
        }
        guard case .failure(.unavailable(let why)) = h.control.switchTo(spaceID: 3) else { return XCTFail("a changed shortcut was sent") }
        XCTAssertTrue(why.contains("Move right a Space"), why)
        XCTAssertEqual(h.posted.filter { $0.type == CGEventType.keyDown.rawValue }.count, 0, "nothing sent after the shortcut was turned off")
        XCTAssertEqual(h.spaces.active, 1)
        h.events.removeAll()
        h.hotkeyReads.removeAll()
        h.spaces.active = 3
        h.hotkey = { id in
            XCTAssertEqual(id, 79)
            return .enabled(keyCode: 123, flags: 0x0004_0000)
        }
        XCTAssertEqual(try h.control.switchTo(spaceID: 1).get().steps, 2)
        XCTAssertEqual(Set(h.hotkeyReads), [79], "re-read before every key-down, only this direction")
        let arrow = h.events.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 123 }
        XCTAssertEqual(arrow.count, 4)
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        XCTAssertTrue(arrow.allSatisfy { $0.flags == arrowFlags })
    }

    func testDefaultChordAndPlainKeyWithSeveralModifiers() throws {
        let h = SpaceHarness()
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().steps, 1)
        let control = CGEventFlags.maskControl
        let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        assertKeys(h, [
            (59, CGEventType.flagsChanged.rawValue, control.rawValue),
            (124, CGEventType.keyDown.rawValue, arrow.rawValue),
            (124, CGEventType.keyUp.rawValue, arrow.rawValue),
            (59, CGEventType.flagsChanged.rawValue, 0),
        ])
        XCTAssertTrue(h.events.allSatisfy { h.tap.filter.owns($0.getIntegerValueField(.eventSourceUserData)) })

        h.events.removeAll()
        h.posted.removeAll()
        h.spaces.active = 1
        h.rightKey = 38
        h.hotkey = { _ in .enabled(keyCode: 38, flags: 0x000C_0000) }
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().toSpace, 2)
        let both: CGEventFlags = [.maskControl, .maskAlternate]
        assertKeys(h, [
            (59, CGEventType.flagsChanged.rawValue, control.rawValue),
            (58, CGEventType.flagsChanged.rawValue, both.rawValue),
            (38, CGEventType.keyDown.rawValue, both.rawValue),
            (38, CGEventType.keyUp.rawValue, both.rawValue),
            (58, CGEventType.flagsChanged.rawValue, control.rawValue),
            (59, CGEventType.flagsChanged.rawValue, 0),
        ])
        XCTAssertTrue(h.events.allSatisfy { $0.flags.intersection([.maskSecondaryFn, .maskNumericPad]).isEmpty })

        h.events.removeAll()
        h.posted.removeAll()
        h.spaces.active = 1
        h.rightKey = 49
        h.hotkey = { _ in .enabled(keyCode: 49, flags: UInt32(control.rawValue)) }
        XCTAssertEqual(try h.control.switchTo(spaceID: 2).get().toSpace, 2)
        let spaceKey = h.events.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 49 }
        XCTAssertEqual(spaceKey.count, 2)
        XCTAssertTrue(spaceKey.allSatisfy { $0.flags == control })
    }

    func testInterruptAfterEachPressReleasesOnlyThoseKeys() {
        for stopAfter in 1...3 {
            for useMove in [false, true] {
                let h = SpaceHarness()
                h.rightKey = 38
                h.hotkey = { _ in .enabled(keyCode: 38, flags: 0x000C_0000) }
                var downs = 0
                var held = Set<Int64>()
                h.onPost = { event in
                    let code = event.getIntegerValueField(.keyboardEventKeycode)
                    let press = event.type == .keyDown || (event.type == .flagsChanged && !held.contains(code))
                    guard press else { return }
                    held.insert(code)
                    downs += 1
                    if downs == stopAfter { h.allowed = false }
                }
                let result = useMove ? h.move() : h.control.switchTo(spaceID: 2, shouldContinue: { h.allowed })
                XCTAssertEqual(result, .failure(.interrupted), "stop \(stopAfter) move \(useMove)")
                var stack: [Int64] = []
                for event in h.posted {
                    let flagsChanged = event.type == CGEventType.flagsChanged.rawValue
                    if event.type == CGEventType.keyDown.rawValue || (flagsChanged && !stack.contains(event.code)) {
                        stack.append(event.code)
                    } else if event.type == CGEventType.keyUp.rawValue || flagsChanged {
                        XCTAssertEqual(stack.popLast(), event.code, "stop \(stopAfter) move \(useMove) \(h.posted)")
                    }
                }
                XCTAssertTrue(stack.isEmpty, "stop \(stopAfter) move \(useMove) \(h.posted)")
                XCTAssertEqual(downs, stopAfter, "stop \(stopAfter) move \(useMove)")
                XCTAssertEqual(h.posted.last?.flags, 0, "stop \(stopAfter) move \(useMove) \(h.posted)")
                // Keys carry attempt tags; drag mouse events carry the older `syntheticTag`. InputMonitor counts neither.
                XCTAssertTrue(h.events.allSatisfy { SpaceControl.isSynthetic($0.getIntegerValueField(.eventSourceUserData)) })
                XCTAssertTrue(h.events.filter { $0.type == .keyDown || $0.type == .keyUp || $0.type == .flagsChanged }
                    .allSatisfy { h.tap.filter.owns($0.getIntegerValueField(.eventSourceUserData)) })
                if useMove {
                    XCTAssertEqual(h.events.filter { $0.type == .leftMouseUp }.count, 1)
                    XCTAssertEqual(h.warps, [SpaceHarness.grab])
                } else {
                    XCTAssertTrue(h.warps.isEmpty)
                    XCTAssertFalse(h.events.contains { $0.type == .leftMouseUp })
                }
            }
        }
    }

    func testNativeShortcutReadsWithoutCreatingOrPostingEvents() {
        let disabled = SpaceHarness()
        disabled.hotkey = { id in id == 81 ? .disabled : .enabled(keyCode: 123, flags: 0x0084_0000) }
        XCTAssertEqual(disabled.control.nativeShortcut(right: true), .disabled)
        XCTAssertEqual(disabled.events.count, 0)
        XCTAssertEqual(disabled.posted.count, 0)
        guard case .failure(.unavailable(let why)) = disabled.move() else { return XCTFail("disabled shortcut was sent") }
        XCTAssertTrue(why.contains("is off"), why)
        XCTAssertTrue(disabled.events.isEmpty)
        XCTAssertTrue(disabled.warps.isEmpty)

        let usable = SpaceHarness()
        usable.events.removeAll()
        usable.posted.removeAll()
        XCTAssertEqual(usable.control.nativeShortcut(right: true), .usable(keyCode: 124, modifiers: ["ctrl"]))
        XCTAssertEqual(usable.control.nativeShortcut(right: false), .usable(keyCode: 123, modifiers: ["ctrl"]))
        XCTAssertEqual(usable.events.count, 0)
        XCTAssertEqual(usable.posted.count, 0)
        usable.conflicts = { _, _ in true }
        guard case .failure(.unavailable(let conflict)) = usable.move() else { return XCTFail("conflicting shortcut was sent") }
        XCTAssertTrue(conflict.contains("matches a LazySpace shortcut"), conflict)
        XCTAssertTrue(usable.events.isEmpty, "conflict is decided before any event is created")

        let function = SpaceHarness()
        function.hotkey = { _ in .enabled(keyCode: 0x7A, flags: 0x0004_0000) }
        XCTAssertEqual(function.control.nativeShortcut(right: true), .unusable(.functionKey))
        guard case .failure(.unavailable(let refused)) = function.move() else { return XCTFail("function key was sent") }
        XCTAssertTrue(refused.contains("function key"), refused)
        XCTAssertEqual(SpaceControl.refusalLead(.functionKey, right: true).contains("function key"), true)
        XCTAssertTrue(function.events.isEmpty)
    }

    func testFailureReportsThePlaceReadAfterRelease() {
        let moved = SpaceHarness()
        moved.onPost = { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124 { moved.allowed = false }
        }
        XCTAssertEqual(moved.move(), .failure(.interrupted))
        XCTAssertEqual(moved.control.placeNote, SpaceControl.PlaceNote(active: 2, window: [2]))
        XCTAssertEqual(moved.control.failureDetail(.interrupted), " Current Space: Desktop 2. Window: Desktop 2.")
        XCTAssertNil(moved.control.failureDetail(.unavailable("no")))

        let switched = SpaceHarness()
        switched.onPost = { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124 { switched.allowed = false }
        }
        XCTAssertEqual(switched.control.switchTo(spaceID: 2, shouldContinue: { switched.allowed }), .failure(.interrupted))
        XCTAssertEqual(switched.control.placeNote, SpaceControl.PlaceNote(active: 2, window: nil))
        XCTAssertEqual(switched.control.failureDetail(.interrupted), " Current Space: Desktop 2.")

        let unknown = SpaceHarness()
        unknown.onPost = { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 124 {
                unknown.allowed = false
                unknown.spaces.active = nil
            }
        }
        XCTAssertEqual(unknown.move(), .failure(.interrupted))
        XCTAssertEqual(unknown.control.placeNote, SpaceControl.PlaceNote(active: nil, window: []))
        let unknownText = unknown.control.failureDetail(.interrupted)
        XCTAssertEqual(unknownText, " Current Space: unknown. Window: unknown.")
        XCTAssertFalse(unknownText?.contains("Desktop 1") == true)
        XCTAssertFalse(unknownText?.localizedCaseInsensitiveContains("return") == true)
        XCTAssertFalse(unknownText?.contains("戻") == true)

        let timedOut = SpaceHarness()
        timedOut.switchOnArrow = false
        guard case .failure(.timedOut) = timedOut.control.switchTo(spaceID: 2) else { return XCTFail("switch timed out without a place") }
        XCTAssertEqual(timedOut.control.placeNote, SpaceControl.PlaceNote(active: 1, window: nil))
        XCTAssertEqual(timedOut.control.failureDetail(.timedOut("x")), " Current Space: Desktop 1.")

        let stayed = SpaceHarness()
        stayed.onPost = { event in
            if event.type == .leftMouseUp { stayed.spaces.membership = [1] }
        }
        XCTAssertEqual(stayed.move(), .failure(.notMoved))
        XCTAssertEqual(stayed.control.placeNote, SpaceControl.PlaceNote(active: 2, window: [1]))
        XCTAssertEqual(stayed.control.failureDetail(.notMoved), " Current Space: Desktop 2. Window: Desktop 1.")

        let saved = Copy.language
        Copy.language = .japanese
        defer { Copy.language = saved }
        XCTAssertEqual(SpaceControl.formatPlace(active: nil, window: nil), "現在の操作スペースは不明。")
        XCTAssertEqual(SpaceControl.formatPlace(active: nil, window: []), "現在の操作スペースは不明。ウインドウの所属は不明。")
        XCTAssertFalse(SpaceControl.formatPlace(active: nil, window: []).contains("戻"))
    }
}

private func assertKeys(_ harness: SpaceHarness, _ expected: [(Int64, UInt32, UInt64)], file: StaticString = #filePath, line: UInt = #line) {
    let actual = harness.posted
    XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
    for (got, want) in zip(actual, expected) {
        XCTAssertEqual(got.code, want.0, "\(actual)", file: file, line: line)
        XCTAssertEqual(got.type, want.1, "\(actual)", file: file, line: line)
        XCTAssertEqual(got.flags, want.2, "\(actual)", file: file, line: line)
    }
}


// MARK: - Waits after arrival (per route) and the timeline

extension SpaceControlTests {
    /// Records the virtual time of the first read of the target Space and runs `after` on later reads (something right before the final read).
    private func watchArrival(_ h: SpaceHarness, at target: UInt64, after: (() -> Void)? = nil) -> () -> Date? {
        var arrivedAt: Date?
        h.spaces.activeHook = { _ in
            if arrivedAt != nil { after?(); return }
            if h.spaces.active == target { arrivedAt = h.time }
        }
        return { arrivedAt }
    }

    private func released(_ h: SpaceHarness, key: Int64, modifier: UInt64, file: StaticString = #filePath, line: UInt = #line) {
        let downs = h.posted.filter { $0.type == CGEventType.keyDown.rawValue && $0.code == key }.count
        let ups = h.posted.filter { $0.type == CGEventType.keyUp.rawValue && $0.code == key }.count
        XCTAssertEqual(downs, ups, "every key that went down came up", file: file, line: line)
        XCTAssertEqual((h.posted.last?.flags ?? modifier) & modifier, 0, "the modifier is released last", file: file, line: line)
    }

    /// Shortcut arrivals and follows confirmed down to the target window wait no longer; activation and hop Space switches wait 0.3 s. Old values are in `fixedWaits`.
    func testSettleDefaultsPerRoute() {
        let settle = SpaceControl.Settle()
        XCTAssertEqual([settle.desktopHotkey, settle.arrowFinal, settle.hotkeyFollow], [0, 0, 0])
        XCTAssertEqual([settle.directArrival, settle.hop, settle.raiseFollow], [0.3, 0.3, 0])
        XCTAssertEqual(SpaceControl.Settle.observedArrival, settle)
        let fixed = SpaceControl.Settle.fixedWaits
        XCTAssertEqual([fixed.desktopHotkey, fixed.arrowFinal, fixed.hotkeyFollow], [0.3, 0.4, 0.3])
        XCTAssertEqual([fixed.directArrival, fixed.hop, fixed.raiseFollow], [0.3, 0.3, 0.3])
        XCTAssertEqual(SpaceHarness().control.settle, settle, "the product default")
    }

    /// Tier 0: by default returns on observed arrival; the final authorization, input, and arrival checks and key release remain. The old 0.3 s comes back with `fixedWaits`.
    func testDesktopShortcutWithoutSettleReturnsOnArrivalAndKeepsTheFinalGuards() throws {
        let (fast, _) = desktopHarness(dock: "switches")
        let arrival = watchArrival(fast, at: 2)
        XCTAssertEqual(try fast.switchSpace(2, [:], hotkey: hotkeyPlan()).get().steps, 0)
        XCTAssertEqual(fast.time, try XCTUnwrap(arrival()), "returned on the observed arrival")
        released(fast, key: 19, modifier: 0x0004_0000)

        // The old fixed wait can be restored per route.
        let (fixed, _) = desktopHarness(dock: "switches")
        fixed.control.settle = .fixedWaits
        let fixedArrival = watchArrival(fixed, at: 2)
        XCTAssertEqual(try fixed.switchSpace(2, [:], hotkey: hotkeyPlan()).get().steps, 0)
        XCTAssertGreaterThanOrEqual(fixed.time.timeIntervalSince(try XCTUnwrap(fixedArrival())), 0.3 - 1e-3, "the fixed wait can be restored")

        // Drifted, input arrived, or interrupted right after arrival was observed -> not success.
        let (drift, _) = desktopHarness(dock: "switches")
        _ = watchArrival(drift, at: 2) { drift.spaces.active = 3 }
        XCTAssertEqual(drift.switchSpace(2, [:], hotkey: hotkeyPlan()), .failure(.drifted(to: 3)))
        released(drift, key: 19, modifier: 0x0004_0000)

        let (input, _) = desktopHarness(dock: "switches")
        var inputs = 0
        input.spaces.activeHook = { _ in if input.spaces.active == 2, inputs == 0 { inputs += 1; input.inputs += 1 } }
        XCTAssertEqual(input.switchSpace(2, [:], hotkey: hotkeyPlan()), .failure(.interrupted))

        let (cancelled, _) = desktopHarness(dock: "switches")
        var allowed = true
        cancelled.spaces.activeHook = { _ in if cancelled.spaces.active == 2 { allowed = false } }
        XCTAssertEqual(cancelled.switchSpace(2, [:], hotkey: hotkeyPlan(), shouldContinue: { allowed }), .failure(.interrupted))
        released(cancelled, key: 19, modifier: 0x0004_0000)

        let (unread, _) = desktopHarness(dock: "switches")
        _ = watchArrival(unread, at: 2) { unread.spaces.active = nil }
        guard case .failure(.unavailable) = unread.switchSpace(2, [:], hotkey: hotkeyPlan()) else { return XCTFail("an unreadable final Space succeeded") }
    }

    /// Left/right stepping: by default returns on the final step's observed arrival; later drift or an unreadable Space fails. The old 0.4 s comes back with `fixedWaits`.
    func testArrowStepsWithoutSettleReturnOnTheFinalArrivalAndKeepTheFinalGuards() throws {
        let fast = SpaceHarness()
        let arrival = watchArrival(fast, at: 3)
        XCTAssertEqual(try fast.control.switchTo(spaceID: 3).get().steps, 2)
        XCTAssertEqual(fast.time, try XCTUnwrap(arrival()))
        released(fast, key: 124, modifier: 0x0004_0000)

        let fixed = SpaceHarness()
        fixed.control.settle = .fixedWaits
        let fixedArrival = watchArrival(fixed, at: 3)
        XCTAssertEqual(try fixed.control.switchTo(spaceID: 3).get().steps, 2)
        XCTAssertGreaterThanOrEqual(fixed.time.timeIntervalSince(try XCTUnwrap(fixedArrival())), 0.4 - 1e-3, "the fixed wait can be restored")

        let drift = SpaceHarness()
        _ = watchArrival(drift, at: 3) { drift.spaces.active = 2 }
        XCTAssertEqual(drift.control.switchTo(spaceID: 3), .failure(.drifted(to: 2)))
        released(drift, key: 124, modifier: 0x0004_0000)

        let unread = SpaceHarness()
        _ = watchArrival(unread, at: 2) { unread.spaces.active = nil }
        guard case .failure(.unavailable) = unread.control.switchTo(spaceID: 2) else { return XCTFail("an unreadable final Space succeeded") }
    }

    /// Consecutive commands: a second operation sent without waiting starts from the first one's arrival and lands correctly (Desktop -> left/right, left/right -> Desktop).
    func testBackToBackShortcutOperationsWithoutSettle() throws {
        let (h, _) = desktopHarness(dock: "switches")
        h.switchOnArrow = true
        XCTAssertEqual(try h.switchSpace(2, [:], hotkey: hotkeyPlan()).get().toSpace, 2)
        XCTAssertEqual(try h.control.switchTo(spaceID: 3).get().fromSpace, 2)
        XCTAssertEqual(h.spaces.active, 3)
        h.spaces.active = 1
        XCTAssertEqual(try h.switchSpace(2, [:], hotkey: hotkeyPlan()).get().fromSpace, 1)
        XCTAssertEqual(h.spaces.active, 2)
        released(h, key: 19, modifier: 0x0004_0000)
    }

    /// Follow with Desktop N: no wait by default, but membership and front checks remain (this raise's `requested(owner)`, owner app in front, staying on the target).
    func testHotkeyFollowWithoutSettleKeepsTheMembershipAndFrontChecks() throws {
        let (fast, d) = desktopHarness(dock: "switches")
        XCTAssertEqual(try fast.move(to: 2, follow: hotkeyPlan()).get().steps, 0)
        XCTAssertEqual(d.raises, [10])
        XCTAssertEqual(fast.frontmost, 700)

        let (moved, _) = desktopHarness(dock: "switches")
        _ = watchArrival(moved, at: 2) { moved.spaces.membership = [1, 2] }
        guard case .failure = moved.move(to: 2, follow: hotkeyPlan()) else { return XCTFail("a window on two Spaces after the follow succeeded") }

        let (late, lateDirect) = desktopHarness(dock: "switches")
        lateDirect.activationTakesEffect = false
        XCTAssertEqual(late.move(to: 2, follow: hotkeyPlan()), .failure(.frontUnconfirmed), "the front is still confirmed")
    }

    /// Activation, app, and hop Space switches watch for 0.3 s by default. Window follow does the final check even with the fixed comparison wait.
    func testRaiseActivateAndHopRoutesKeepTheDriftWatch() {
        let raise = SpaceHarness(); let d = DirectStub()
        raise.spaces.membership = [3]
        raise.control.direct = d.path(raise)
        raise.onSleep = { interval in if interval == 0.3 { raise.spaces.active = 2 } }
        XCTAssertEqual(raise.control.switchTo(spaceID: 3, candidates: [21]), .failure(.drifted(to: 2)))

        let follow = SpaceHarness(); let f = DirectStub()
        follow.control.direct = f.path(follow)
        follow.control.settle = .fixedWaits
        follow.onSleep = { interval in if interval == 0.3 { follow.spaces.active = 2 } }
        XCTAssertEqual(follow.move(to: 3), .failure(.drifted(to: 2)))

        let hop = SpaceHarness(); let p = DirectStub(); fiveSpaces(hop)
        hop.control.direct = p.path(hop)
        var allowed = true
        hop.onSleep = { interval in if interval == 0.3 { allowed = false } }
        XCTAssertEqual(hop.switchSpace(5, [4: [app(504)]], hop: true, shouldContinue: { allowed }), .failure(.interrupted))
        XCTAssertEqual(keyDowns(hop), 0, "nothing is stepped after a drift during the hop's watch")
    }

    /// Input or an interruption during follow's final membership read is not success even if membership and Space are right (raise follow, Desktop N follow).
    /// An uninterrupted run counts membership reads from reaching the target to success, and the input or interruption happens in the last one.
    func testInterruptionDuringTheFinalMembershipReadIsNotSuccess() throws {
        for follow in [false, true] {
            let (clean, _) = desktopHarness(dock: "switches")
            var cleanReads = 0
            clean.spaces.onMembershipRead = { _ in if clean.spaces.active == 2 { cleanReads += 1 } }
            XCTAssertEqual(try clean.move(to: 2, follow: follow ? hotkeyPlan() : nil).get().toSpace, 2)
            XCTAssertGreaterThan(cleanReads, 0)
            for interruption in ["input", "cancel"] {
                let label = "\(follow ? "hotkey" : "raise") follow, \(interruption)"
                let (h, _) = desktopHarness(dock: "switches")
                var readsOnTarget = 0
                h.spaces.onMembershipRead = { _ in
                    guard h.spaces.active == 2 else { return }
                    readsOnTarget += 1
                    guard readsOnTarget == cleanReads else { return }
                    if interruption == "input" { h.inputs += 1 } else { h.allowed = false }
                }
                XCTAssertEqual(h.move(to: 2, follow: follow ? hotkeyPlan() : nil), .failure(.interrupted), label)
                XCTAssertEqual(h.spaces.membership, [2], "\(label): the window is on the target")
                XCTAssertEqual(h.spaces.active, 2, label)
            }
        }
    }

    // MARK: Timeline

    func testTimelineRecordsEachMainKeyAndArrivalWithStepsAndAttempts() throws {
        let h = SpaceHarness()
        let timeline = OperationTimeline()
        _ = try h.control.switchTo(spaceID: 3, plan: SpaceControl.SwitchPlan(windows: [:], hopAllowed: false, timeline: timeline)).get()
        let events = timeline.events
        XCTAssertEqual(events.map(\.event), ["accepted", "mainKeyPosted", "arrivalObserved", "mainKeyPosted", "arrivalObserved"])
        XCTAssertEqual(events.map(\.step), [nil, 1, 1, 2, 2])
        XCTAssertEqual(events.map(\.attempt), [nil, 1, 1, 2, 2])
        XCTAssertEqual(events.map(\.at), events.map(\.at).sorted())

        let (desk, _) = desktopHarness(dock: "switches")
        let deskTimeline = OperationTimeline()
        _ = try desk.control.switchTo(spaceID: 2, plan: SpaceControl.SwitchPlan(windows: [:], hopAllowed: false, hotkey: hotkeyPlan(), timeline: deskTimeline)).get()
        XCTAssertEqual(deskTimeline.events.map(\.event), ["accepted", "mainKeyPosted", "arrivalObserved"])
        XCTAssertEqual(deskTimeline.events.map(\.step), [nil, nil, nil], "tier 0 has no steps")

        let (follow, _) = desktopHarness(dock: "switches")
        let followTimeline = OperationTimeline()
        _ = try follow.control.moveWindow(10, frame: SpaceHarness.frame, toSpace: 2, follow: hotkeyPlan(), timeline: followTimeline).get()
        XCTAssertEqual(followTimeline.events.map(\.event), ["accepted", "mainKeyPosted", "arrivalObserved", "activationConfirmed", "focusConfirmed"])
    }

    /// Failures keep the timeline so far. After the operation ends, later operations do not write to it.
    func testTimelineKeepsThePartialRecordOnFailureAndStopsAfterTheOperation() {
        let h = SpaceHarness()
        _ = watchArrival(h, at: 3) { h.spaces.active = 2 }
        let timeline = OperationTimeline()
        XCTAssertEqual(h.control.switchTo(spaceID: 3, plan: SpaceControl.SwitchPlan(windows: [:], hopAllowed: false, timeline: timeline)), .failure(.drifted(to: 2)))
        let recorded = timeline.events
        XCTAssertEqual(recorded.map(\.event).last, "arrivalObserved")
        h.spaces.activeHook = nil
        _ = h.control.switchTo(spaceID: 1)
        XCTAssertEqual(timeline.events, recorded, "a later operation without a timeline does not write into this one")
    }
}

// MARK: - Sending (without switching)

extension SpaceControlTests {
    /// `sendWindow`: changes membership only, without switching, activation, or keys. Five outcomes.
    func testSendWindowOutcomes() {
        // Without the direct move, nothing is issued (dragging switches Spaces, so it is no substitute).
        let none = SpaceHarness()
        guard case .notIssued(.unavailable) = none.control.sendWindow(10, toSpace: 3) else { return XCTFail("issued without the direct move") }
        XCTAssertTrue(none.events.isEmpty)

        let ok = SpaceHarness(); let d = DirectStub()
        ok.control.direct = d.path(ok)
        guard case .confirmed(let result) = ok.control.sendWindow(10, toSpace: 3) else { return XCTFail("not confirmed") }
        XCTAssertEqual(result.fromSpace, 1)
        XCTAssertEqual(ok.spaces.active, 1, "not followed")
        XCTAssertEqual(ok.spaces.membership, [3])
        XCTAssertTrue(d.raises.isEmpty && d.reactivates.isEmpty, "nothing is brought forward")
        XCTAssertTrue(ok.events.isEmpty, "no keys or mouse")

        // Membership does not change: after 1 s, "issued but unconfirmed" (not "stayed on the source").
        let late = SpaceHarness(); let l = DirectStub(); l.moveChangesMembership = false
        late.control.direct = l.path(late)
        XCTAssertEqual(late.control.sendWindow(10, toSpace: 3), .unconfirmed([1]))
        XCTAssertGreaterThanOrEqual(late.time.timeIntervalSince1970, 1.0)

        // Arrived on another Space.
        let other = SpaceHarness(); let o = DirectStub()
        other.control.direct = o.path(other)
        other.control.direct?.move = { _, _ in other.spaces.membership = [2]; return true }
        XCTAssertEqual(other.control.sendWindow(10, toSpace: 3), .elsewhere(2))

        // Input after issuing: stop waiting (issued).
        let input = SpaceHarness(); let i = DirectStub(); i.moveChangesMembership = false
        input.control.direct = i.path(input)
        input.onSleep = { interval in if interval == 0.02 { input.inputs += 1 } }
        XCTAssertEqual(input.control.sendWindow(10, toSpace: 3), .interrupted)

        // Input right before issuing: nothing is issued.
        let before = SpaceHarness(); let b = DirectStub()
        before.control.direct = b.path(before)
        var reads = 0
        before.spaces.onMembershipRead = { _ in reads += 1; before.inputs += 1 }
        guard case .notIssued(.interrupted) = before.control.sendWindow(10, toSpace: 3) else { return XCTFail("issued after input") }
        XCTAssertTrue(b.moves.isEmpty)
        XCTAssertEqual(reads, 1)

        // If macOS changes the current Space while waiting, it is not an interruption (the caller observes and reports it).
        let moved = SpaceHarness(); let m = DirectStub()
        moved.control.direct = m.path(moved)
        moved.control.direct?.move = { _, space in moved.spaces.active = space; moved.spaces.membership = [space]; return true }
        guard case .confirmed = moved.control.sendWindow(10, toSpace: 3) else { return XCTFail("a Space change by macOS is not an interruption") }
        XCTAssertEqual(moved.spaces.active, 3)

        // Never sent to a full-screen Space.
        let full = SpaceHarness(); let f = DirectStub()
        full.spaces.spaceTypes = [0, 0, 4]
        full.control.direct = f.path(full)
        guard case .notIssued = full.control.sendWindow(10, toSpace: 3) else { return XCTFail("sent to a full-screen Space") }
        XCTAssertTrue(f.moves.isEmpty)
    }
}

// MARK: - Another display

extension SpaceControlTests {
    func testSendWindowReachesADesktopOfAnotherDisplay() {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.secondDisplay = [20, 21]
        h.control.direct = d.path(h)
        guard case .confirmed = h.control.sendWindow(10, toSpace: 21) else { return XCTFail("not sent to the other display") }
        XCTAssertEqual(h.spaces.membership, [21])
        XCTAssertTrue(h.events.isEmpty, "no keys or mouse")
    }

    /// The Desktop N shortcut, the Space in between, and stepping act on the current display, so only a window or app there can be used.
    func testSwitchingToAnotherDisplayUsesOnlyTheDirectRoutes() {
        let h = SpaceHarness(); let d = DirectStub()
        h.spaces.secondDisplay = [20, 21]
        h.control.direct = d.path(h)
        XCTAssertEqual(h.switchSpace(21, [:]), .failure(.otherDisplayNoRoute))
        XCTAssertTrue(h.posted.isEmpty, "no stepping keys")

        let w = SpaceHarness(); let e = DirectStub()
        w.spaces.secondDisplay = [20, 21]
        w.spaces.membership = [21]
        w.control.direct = e.path(w)
        guard case .success = w.switchSpace(21, [21: [.window(40)]]) else { return XCTFail("a window on that display was not used") }
        XCTAssertEqual(w.spaces.active, 21)
        XCTAssertEqual(e.raises, [40])
    }

    func testFollowingToAnotherDisplayNeedsTheDirectMove() {
        let h = SpaceHarness()
        h.spaces.secondDisplay = [20, 21]
        XCTAssertEqual(h.move(to: 21), .failure(.otherDisplayNeedsDirectMove))
        XCTAssertTrue(h.events.isEmpty, "no drag")

        let ok = SpaceHarness(); let d = DirectStub()
        ok.spaces.secondDisplay = [20, 21]
        ok.control.direct = d.path(ok)
        guard case .success = ok.move(to: 21) else { return XCTFail("the direct move was not used") }
        XCTAssertEqual(ok.spaces.membership, [21])
        XCTAssertEqual(ok.spaces.active, 21)
    }
}

extension SpaceControlTests {
    /// A Space change during the caller's check (without input) issues nothing on either path.
    func testSpaceChangeDuringTheCallersCheckIssuesNothing() {
        let direct = SpaceHarness(); let d = DirectStub()
        direct.control.direct = d.path(direct)
        let directHooks = SpaceControl.MoveHooks(beforeIssue: { direct.spaces.active = 3; return true })
        XCTAssertEqual(direct.control.moveWindow(10, frame: SpaceHarness.frame, toSpace: 2, hooks: directHooks), .failure(.interrupted))
        XCTAssertTrue(d.moves.isEmpty, "no direct move")

        let drag = SpaceHarness()
        let dragHooks = SpaceControl.MoveHooks(beforeIssue: { drag.spaces.active = 3; return true })
        XCTAssertEqual(drag.control.moveWindow(10, frame: SpaceHarness.frame, toSpace: 2, hooks: dragHooks), .failure(.interrupted))
        XCTAssertFalse(drag.events.contains { $0.type == .leftMouseDown }, "the window is not grabbed")
    }
}
