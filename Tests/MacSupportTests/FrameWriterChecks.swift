import Foundation
import Operations
@testable import MacSupport

// OS doubles model the effects of separate AX position/size requests, not the writer's sequence.
func frameWriterChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let target = CGRect(x: 756, y: 33, width: 756, height: 949)
    var actual = CGRect(x: 0, y: 33, width: 1512, height: 500)
    let result = AXFrameWriter.write(current: actual, target: target,
        enhancedUI: { false }, setEnhancedUI: { _ in nil },
        setPosition: { p in
            actual.origin = CGPoint(x: min(p.x, 1512 - actual.width), y: p.y)
            return nil
        }, setSize: { size in actual.size = size; return nil }, isGone: { false })
    checks.append(("mixed shrink/grow reaches the right-hand tile", result == .issued && actual == target))

    actual = CGRect(x: 152, y: 73, width: 586, height: 488)
    let fullHeight = CGRect(x: 0, y: 33, width: 756, height: 949)
    _ = AXFrameWriter.write(current: actual, target: fullHeight,
        enhancedUI: { nil }, setEnhancedUI: { _ in fatalError("unsupported attribute must not be written") },
        setPosition: { actual.origin = $0; return nil },
        setSize: { s in actual.size = CGSize(width: s.width, height: min(s.height, 982 - actual.minY)); return nil },
        isGone: { false })
    checks.append(("size clipped at old position is corrected after moving", actual == fullHeight))

    var enabled = true
    var writes = 0
    actual = CGRect(x: 152, y: 73, width: 586, height: 488)
    let animated = AXFrameWriter.write(current: actual, target: fullHeight,
        enhancedUI: { enabled }, setEnhancedUI: { enabled = $0; return nil },
        setPosition: { if !enabled { actual.origin = $0 }; return nil },
        setSize: { actual.size = $0; return nil }, isGone: { false })
    checks.append(("enhanced UI is restored after a successful frame write", animated == .issued && actual == fullHeight && enabled))

    for failure in [AXFailure.cannotComplete, .invalidElement] {
        enabled = true; writes = 0
        let stopped = AXFrameWriter.write(current: .zero, target: fullHeight,
            enhancedUI: { enabled }, setEnhancedUI: { enabled = $0; return nil },
            setPosition: { _ in writes += 1; return nil },
            setSize: { _ in writes += 1; return failure }, isGone: { false })
        let expected: WriteResult = failure == .cannotComplete ? .timedOut : .gone
        checks.append(("terminal AX failure stops subsequent writes and restores UI: \(failure)", stopped == expected && writes == 1 && enabled))
    }

    actual = CGRect(x: 0, y: 33, width: 230, height: 408)
    let fixed = AXFrameWriter.write(current: actual, target: target,
        enhancedUI: { false }, setEnhancedUI: { _ in fatalError("false attribute must remain untouched") },
        setPosition: { actual.origin = $0; return nil },
        setSize: { _ in .other(-25200) }, isGone: { false })
    if case .rejected = fixed {
        checks.append(("size rejection still permits moving a fixed-size window", actual == CGRect(x: 756, y: 33, width: 230, height: 408)))
    } else { checks.append(("size rejection still permits moving a fixed-size window", false)) }

    writes = 0
    _ = AXFrameWriter.write(current: fullHeight, target: fullHeight,
        enhancedUI: { writes += 1; return true }, setEnhancedUI: { _ in writes += 1; return nil },
        setPosition: { _ in writes += 1; return nil }, setSize: { _ in writes += 1; return nil }, isGone: { false })
    checks.append(("unchanged frame does not touch AX attributes", writes == 0))
    for unsupported in [AXFailure.notImplemented, .attributeUnsupported] {
        actual = .zero
        var restored = false
        let fallback = AXFrameWriter.write(current: actual, target: fullHeight,
            enhancedUI: { true },
            setEnhancedUI: { if $0 { restored = true }; return unsupported },
            setPosition: { actual.origin = $0; return nil },
            setSize: { actual.size = $0; return nil }, isGone: { false })
        checks.append(("unsupported optional animation attribute does not block placement: \(unsupported)",
                       fallback == .issued && actual == fullHeight && !restored))
    }
    // A failed restoration must not disguise a timeout as a resize rejection:
    // Operations uses the terminal result to stop writing to that app.
    for (frameFailure, restoreFailure, expected) in [
        (AXFailure.cannotComplete, AXFailure.other(-25200), WriteResult.timedOut),
        (.invalidElement, .other(-25200), .gone),
        (.other(-25200), .cannotComplete, .timedOut),
        (.other(-25200), .invalidElement, .gone)
    ] {
        let stopped = AXFrameWriter.write(current: .zero, target: fullHeight,
            enhancedUI: { true }, setEnhancedUI: { $0 ? restoreFailure : nil },
            setPosition: { _ in nil }, setSize: { _ in frameFailure }, isGone: { false })
        checks.append(("restoration preserves terminal result: \(frameFailure), \(restoreFailure)", stopped == expected))
    }
    return checks
}
