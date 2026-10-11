import XCTest
import LayoutCore
import Operations

final class FocusLifetimeTests: XCTestCase {
    func testFocusActivationExpiresWhenOperationReturns() {
        for light in [false, true] {
            let system = FakeSystem(windows: [window(1)])
            system.delayedFocus = true
            if light { system.membershipOverride[WindowID(1)] = .current }
            let result = FocusOperation(system: system, control: OperationControl(), limits: OperationLimits(settleDelay: 0), target: WindowID(1)).run()
            XCTAssertEqual(result.outcome, .partial)
            XCTAssertEqual(system.pendingActivations.count, 1)
            system.pendingActivations.forEach { $0() }
            XCTAssertTrue(system.focusCalls.isEmpty, "a delayed main-thread callback must not steal focus after completion")
        }
    }

    func testFocusRechecksAuthorizationAfterResolvingTheAXElement() {
        for change in ["pause", "input", "space"] {
            let system = FakeSystem(windows: [window(1)])
            let control = OperationControl()
            system.beforeRaise = {
                switch change {
                case "pause": control.paused = true; control.paused = false
                case "input": system.inputActivityCount += 1
                default: system.space = 8
                }
            }
            _ = FocusOperation(system: system, control: control, limits: OperationLimits(settleDelay: 0), target: WindowID(1)).run()
            XCTAssertTrue(system.focusCalls.isEmpty, change)
        }
    }

    func testFocusActivationRunsWhileAuthorizedAndStopsOnInterruption() {
        for change in ["none", "pause", "input", "space"] {
            let system = FakeSystem(windows: [window(1)])
            let control = OperationControl()
            system.delayedFocus = true
            let result = FocusOperation(system: system, control: control, target: WindowID(1), sleep: { _ in
                switch change {
                case "pause": control.paused = true
                case "input": system.inputActivityCount += 1
                case "space": system.space = 8
                default: break
                }
                system.pendingActivations.forEach { $0() }
                system.pendingActivations.removeAll()
            }).run()
            XCTAssertEqual(result.outcome == .complete, change == "none", change)
            XCTAssertEqual(system.focusCalls.count, change == "none" ? 1 : 0, change)
        }
    }

    func testAccordionActivationExpiresWhenArrangementReturns() {
        let system = FakeSystem(windows: [window(1), window(2, x: 600)])
        system.focused = WindowID(1)
        system.delayedFocus = true
        let layout = Layout(root: .accordion(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        _ = ArrangeOperation(system: system, control: OperationControl(), knowledge: ConstraintKnowledge(), limits: OperationLimits(settleDelay: 0), priorLayout: layout).run()
        XCTAssertFalse(system.pendingActivations.isEmpty)
        system.pendingActivations.forEach { $0() }
        XCTAssertTrue(system.focusCalls.isEmpty, "an old accordion reflow must not bring its app forward after it ends")
    }
}
