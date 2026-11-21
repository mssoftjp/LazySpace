import XCTest
@testable import MacSupport

final class InputMonitorTests: XCTestCase {
    func testCompletedDragSurvivesUntilTheNextObservation() {
        let monitor = InputMonitor()
        func record(_ type: CGEventType, synthetic: Bool = false) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
            if synthetic { event.setIntegerValueField(.eventSourceUserData, value: SpaceControl.syntheticTag) }
            monitor.record(type, event: event)
        }
        for _ in 0..<2 {
            record(.leftMouseDown)
            record(.leftMouseDragged)
            record(.leftMouseDragged)
            record(.leftMouseUp)
        }
        XCTAssertFalse(monitor.leftMouseDown)
        XCTAssertEqual(monitor.completedMouseDrags, 2)
        record(.leftMouseUp) // A duplicate release is not another drag.
        record(.leftMouseDown)
        record(.leftMouseUp) // A click is not a drag.
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            record(type, synthetic: true) // LazySpace' own Space movement is not a manual edit.
        }
        XCTAssertEqual(monitor.completedMouseDrags, 2)
    }

    /// A completed drag keeps where the button was released, read with its count; a click afterwards does not replace it.
    func testACompletedDragKeepsItsReleasePoint() {
        let monitor = InputMonitor()
        func record(_ type: CGEventType, at point: CGPoint) {
            monitor.record(type, event: CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!)
        }
        XCTAssertNil(monitor.completedDrag.release)
        record(.leftMouseDown, at: CGPoint(x: 10, y: 20))
        record(.leftMouseDragged, at: CGPoint(x: 150, y: 220))
        record(.leftMouseUp, at: CGPoint(x: 300, y: 400))
        XCTAssertEqual(monitor.completedDrag.count, 1)
        XCTAssertEqual(monitor.completedDrag.release, CGPoint(x: 300, y: 400))
        record(.leftMouseDown, at: CGPoint(x: 900, y: 900))
        record(.leftMouseUp, at: CGPoint(x: 900, y: 900))
        XCTAssertEqual(monitor.completedDrag.count, 1)
        XCTAssertEqual(monitor.completedDrag.release, CGPoint(x: 300, y: 400), "a click is not a drag")
        record(.leftMouseDown, at: CGPoint(x: 300, y: 400))
        record(.leftMouseDragged, at: CGPoint(x: 400, y: 500))
        record(.leftMouseUp, at: CGPoint(x: 500, y: 600))
        XCTAssertEqual(monitor.completedDrag.count, 2)
        XCTAssertEqual(monitor.completedDrag.release, CGPoint(x: 500, y: 600), "the next drag replaces it")
    }

    /// Releasing a running monitor without stopping it, or starting and stopping it repeatedly, never lets the tap thread touch a freed monitor.
    func testReleasingOrRestartingARunningMonitorIsSafe() throws {
        for _ in 0..<20 {
            var monitor: InputMonitor? = InputMonitor()
            guard monitor?.start() != .unavailable else {
                throw XCTSkip("input observation cannot start in this test process")
            }
            monitor?.stop()
            _ = monitor?.start()
            monitor = nil
        }
    }
}

/// A button released while the tap was stopped is not assumed held. The unobserved gap counts as input.
final class InputGapTests: XCTestCase {
    func testObservationGapReconcilesTheLeftButtonAndCountsAsInput() {
        let monitor = InputMonitor()
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        monitor.record(.leftMouseDown, event: event)
        XCTAssertTrue(monitor.leftMouseDown)
        let count = monitor.count
        monitor.noteObservationGap { false }
        XCTAssertFalse(monitor.leftMouseDown)
        XCTAssertGreaterThan(monitor.count, count)
    }

    /// LazySpace's own shortcuts are not input to automatic arrangement, but they do end a wait for the shortcut list,
    /// and the value passed with a modifier change is the same one.
    func testARegisteredShortcutAdvancesOnlyTheShortcutListCount() {
        let monitor = InputMonitor()
        monitor.setCommandKeys([InputMonitor.CommandKey(keyCode: 4, carbonModifiers: 0x0800)]) // ⌥H
        let count = monitor.count, guide = monitor.guideInputCount
        let press = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: true)!
        press.flags = .maskAlternate
        monitor.record(.keyDown, event: press)
        XCTAssertEqual(monitor.count, count, "not input to automatic arrangement")
        XCTAssertEqual(monitor.guideInputCount, guide + 1)
        let delivered = expectation(description: "modifier change delivered")
        monitor.onFlagsChanged = { _, value in
            XCTAssertEqual(value, guide + 1)
            delivered.fulfill()
        }
        let flags = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true)!
        flags.flags = .maskAlternate
        monitor.record(.flagsChanged, event: flags)
        wait(for: [delivered], timeout: 2)
    }

    /// Input during an unobserved gap may include a press or a drag: the last release point no longer describes the windows.
    func testAnObservationGapForgetsTheReleasePoint() {
        let monitor = InputMonitor()
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            monitor.record(type, event: CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 300, y: 400), mouseButton: .left)!)
        }
        XCTAssertEqual(monitor.completedDrag.release, CGPoint(x: 300, y: 400))
        monitor.noteObservationGap { false }
        XCTAssertEqual(monitor.completedDrag.count, 1)
        XCTAssertNil(monitor.completedDrag.release)
    }

    /// A release delivered while the gap samples the button is recorded after the sample, so it stands.
    func testAReleaseDuringTheSampleIsNotOverwritten() {
        let monitor = InputMonitor()
        let press = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
        monitor.record(.leftMouseDown, event: press)
        let releasing = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        monitor.noteObservationGap {
            // The button is still down at the sample; the release arrives on the tap thread meanwhile.
            DispatchQueue.global().async {
                releasing.signal()
                monitor.record(.leftMouseUp, event: release)
                released.signal()
            }
            releasing.wait()
            usleep(20_000)
            return true
        }
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(monitor.leftMouseDown, "the release recorded after the sample wins")
    }
}

/// Recovering a disabled tap: the gap counts as input and the left button is matched before the tap is enabled again,
/// under the lock that recording takes, so a later release is never overwritten and a finished recovery is not redone.
final class InputTapRecoveryTests: XCTestCase {
    private var ports: [CFMachPort] = []

    private func port() -> CFMachPort {
        var context = CFMachPortContext()
        let p = CFMachPortCreate(nil, { _, _, _, _ in }, &context, nil)!
        ports.append(p)
        return p
    }

    override func tearDown() {
        ports.forEach { CFMachPortInvalidate($0) }
        ports = []
        super.tearDown()
    }

    private func pressLeft(_ monitor: InputMonitor) {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        monitor.record(.leftMouseDown, event: event)
    }

    /// A monitor whose tap is disabled; `enabled` flips when the monitor enables it.
    private func disabledMonitor(buttonDown: Bool = false) -> (InputMonitor, CFMachPort, () -> UInt64?) {
        let monitor = InputMonitor()
        let tap = port()
        monitor.installForTesting(tap, mode: .mouseAndKeyboard)
        var enabled = false
        var countWhenEnabled: UInt64?
        monitor.tapControl.isEnabled = { _ in enabled }
        monitor.tapControl.enable = { _ in countWhenEnabled = monitor.count; enabled = true }
        monitor.tapControl.leftButtonDown = { buttonDown }
        return (monitor, tap, { countWhenEnabled })
    }

    func testTheDisableNoticeCountsTheGapBeforeEnabling() {
        let (monitor, _, countWhenEnabled) = disabledMonitor()
        pressLeft(monitor)
        let before = monitor.count
        let notice = CGEvent(source: nil)!
        monitor.handleTapEvent(.tapDisabledByTimeout, event: notice)
        XCTAssertEqual(countWhenEnabled(), before + 1, "counted, and the tap enabled afterward")
        XCTAssertFalse(monitor.leftMouseDown, "the button is matched to its state now")
        XCTAssertEqual(monitor.mode, .mouseAndKeyboard)
    }

    func testReviveCountsTheGapBeforeEnabling() {
        let (monitor, _, countWhenEnabled) = disabledMonitor(buttonDown: true)
        let before = monitor.count
        XCTAssertTrue(monitor.reviveIfDisabled())
        XCTAssertEqual(countWhenEnabled(), before + 1)
        XCTAssertTrue(monitor.leftMouseDown)
    }

    /// The other path already enabled the tap and a release arrived: nothing is redone, so the release stands.
    func testARecoveryThatFindsTheTapEnabledChangesNothing() {
        let (monitor, tap, _) = disabledMonitor(buttonDown: true)
        monitor.tapControl.isEnabled = { _ in true }
        pressLeft(monitor)
        let release = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left)!
        monitor.record(.leftMouseUp, event: release)
        let before = monitor.count
        XCTAssertTrue(monitor.recoverDisabled(tap))
        XCTAssertEqual(monitor.count, before)
        XCTAssertFalse(monitor.leftMouseDown, "an older sample does not overwrite the release")
    }

    func testARecoveryForATapThatWasReplacedChangesNothing() {
        let (monitor, _, countWhenEnabled) = disabledMonitor(buttonDown: true)
        let before = monitor.count
        XCTAssertFalse(monitor.recoverDisabled(port()))
        XCTAssertEqual(monitor.count, before)
        XCTAssertNil(countWhenEnabled(), "a tap that is no longer current is not enabled")
    }

    func testAFailedEnableStopsAndReportsUnobservable() {
        let (monitor, _, _) = disabledMonitor()
        monitor.tapControl.enable = { _ in }
        XCTAssertFalse(monitor.reviveIfDisabled())
        XCTAssertEqual(monitor.mode, .unavailable)
    }
}

/// Keys count as observed only when macOS reports exactly one listen-only session tap of this process whose mask includes keyDown.
final class EffectiveMaskTests: XCTestCase {
    let pid: pid_t = 4242
    let full: CGEventMask = 0xA40_14CE
    let withoutKeys: CGEventMask = 0xA40_10CE

    private func tap(pid: pid_t? = nil, options: CGEventTapOptions = .listenOnly, point: CGEventTapLocation = .cgSessionEventTap,
                     mask: CGEventMask) -> CGEventTapInformation {
        CGEventTapInformation(eventTapID: 1, tapPoint: point, options: options, eventsOfInterest: mask,
                              tappingProcess: pid ?? self.pid, processBeingTapped: 0, enabled: true,
                              minUsecLatency: 0, avgUsecLatency: 0, maxUsecLatency: 0)
    }

    func testKeysAreObservedWhenOurTapKeepsKeyDown() {
        XCTAssertTrue(InputMonitor.keysDelivered(in: [tap(mask: full)], pid: pid))
    }

    func testThePassThroughTapAndOtherProcessesAreIgnored() {
        let passThrough = tap(options: .defaultTap, point: .cgAnnotatedSessionEventTap, mask: withoutKeys)
        let other = tap(pid: 1, mask: withoutKeys)
        XCTAssertTrue(InputMonitor.keysDelivered(in: [passThrough, other, tap(mask: full)], pid: pid))
    }

    func testAnythingInconclusiveCountsAsNoKeys() {
        XCTAssertFalse(InputMonitor.keysDelivered(in: [tap(mask: withoutKeys)], pid: pid), "keys removed by macOS")
        XCTAssertFalse(InputMonitor.keysDelivered(in: nil, pid: pid), "the list could not be read")
        XCTAssertFalse(InputMonitor.keysDelivered(in: [tap(pid: 1, mask: full)], pid: pid), "no tap of ours")
        XCTAssertFalse(InputMonitor.keysDelivered(in: [tap(mask: full), tap(mask: full)], pid: pid), "two candidates")
    }
}
