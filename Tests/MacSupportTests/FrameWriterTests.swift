import XCTest
import Operations
@testable import MacSupport

final class FrameWriterTests: XCTestCase {
    func testFrameWriteEffects() {
        for (name, passed) in frameWriterChecks() { XCTAssertTrue(passed, name) }
    }

    /// The order follows what fits on the display: a new size that fits where the window is goes first (no clipped size, no third request);
    /// otherwise a move that keeps the current size on the display goes first; only when neither fits is it size, position, and size again.
    func testWriteOrderFollowsWhatFitsOnTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        func order(_ current: CGRect, _ target: CGRect, bounds: CGRect?) -> [String] {
            var steps: [String] = []
            _ = AXFrameWriter.write(current: current, target: target, bounds: bounds, enhancedUI: { nil }, setEnhancedUI: { _ in nil },
                                    setPosition: { _ in steps.append("position"); return nil },
                                    setSize: { _ in steps.append("size"); return nil }, isGone: { false })
            return steps
        }
        XCTAssertEqual(order(CGRect(x: 100, y: 100, width: 600, height: 400), CGRect(x: 1280, y: 40, width: 800, height: 900), bounds: display),
                       ["size", "position"], "the new size fits at the current origin")
        XCTAssertEqual(order(CGRect(x: 819, y: 259, width: 922, height: 493), CGRect(x: 0, y: 30, width: 2560, height: 1410), bounds: display),
                       ["position", "size"], "growing in place would be clipped; the current size fits at the target")
        XCTAssertEqual(order(CGRect(x: 1500, y: 30, width: 1060, height: 1410), CGRect(x: 0, y: 100, width: 2560, height: 1340), bounds: display),
                       ["size", "position", "size"], "neither fits")
        XCTAssertEqual(order(CGRect(x: 819, y: 259, width: 922, height: 493), CGRect(x: 0, y: 30, width: 2560, height: 1410), bounds: nil),
                       ["size", "position", "size"], "an unknown display keeps the old order")
        XCTAssertEqual(order(CGRect(x: 0, y: 30, width: 600, height: 400), CGRect(x: 0, y: 30, width: 900, height: 400), bounds: display), ["size"])
        XCTAssertEqual(order(CGRect(x: 0, y: 30, width: 600, height: 400), CGRect(x: 900, y: 30, width: 600, height: 400), bounds: display), ["position"])
    }

    func testInterruptionStopsIndividualAXWritesAndRestoresEnhancedUI() {
        for interruptAt in ["before", "read", "disable", "size", "position", "none"] {
            var authorized = interruptAt != "before"
            var enhanced = true
            var geometry: [String] = []
            var enhancedWrites: [Bool] = []
            let result = AXFrameWriter.write(current: CGRect(x: 0, y: 0, width: 100, height: 100),
                target: CGRect(x: 200, y: 100, width: 300, height: 400),
                enhancedUI: { if interruptAt == "read" { authorized = false }; return enhanced },
                setEnhancedUI: {
                    enhanced = $0; enhancedWrites.append($0)
                    if !$0 && interruptAt == "disable" { authorized = false }
                    return nil
                },
                setPosition: { _ in geometry.append("position"); if interruptAt == "position" { authorized = false }; return nil },
                setSize: { _ in geometry.append("size"); if interruptAt == "size" { authorized = false }; return nil },
                isGone: { false }, shouldContinue: { authorized })
            let expected: [String]
            switch interruptAt {
            case "size": expected = ["size"]
            case "position": expected = ["size", "position"]
            case "none": expected = ["size", "position", "size"]
            default: expected = []
            }
            XCTAssertEqual(geometry, expected, interruptAt)
            XCTAssertEqual(result, interruptAt == "none" ? .issued : .interrupted, interruptAt)
            XCTAssertTrue(enhanced, "cleanup still runs after interruption: \(interruptAt)")
            XCTAssertEqual(enhancedWrites, ["before", "read"].contains(interruptAt) ? [] : [false, true], interruptAt)
        }
    }
}
