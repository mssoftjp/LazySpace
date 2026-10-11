import XCTest
import Operations
@testable import MacSupport

final class FrameWriterTests: XCTestCase {
    func testFrameWriteEffects() {
        for (name, passed) in frameWriterChecks() { XCTAssertTrue(passed, name) }
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
