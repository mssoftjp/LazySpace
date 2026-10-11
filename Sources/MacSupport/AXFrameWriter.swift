import Foundation
import Operations
import OSLog

/// Order and error handling of AX writes. The caller supplies the actual attribute operations.
enum AXFrameWriter {
    private static let logger = Logger(subsystem: "jp.lazyspace.app", category: "AXFrameWriter")
    static func write(current: CGRect, target: CGRect,
                      enhancedUI: () -> Bool?, setEnhancedUI: (Bool) -> AXFailure?,
                      setPosition: @escaping (CGPoint) -> AXFailure?,
                      setSize: @escaping (CGSize) -> AXFailure?,
                      isGone: () -> Bool, shouldContinue: () -> Bool = { true }) -> WriteResult {
        // Position and size are sent independently. Fixed-size windows (Calculator, for example) return kAXErrorFailure
        // from setSize even for the same value, so a refused size never skips the position (measured).
        let needPosition = abs(target.minX - current.minX) > 0.5 || abs(target.minY - current.minY) > 0.5
        let needSize = abs(target.width - current.width) > 0.5 || abs(target.height - current.height) > 0.5
        guard needPosition || needSize else { return .issued }
        guard shouldContinue() else { return .interrupted }
        // size -> position -> size, as AeroSpace does: the size clipped at the screen edge before moving is
        // requested again after moving. The order stays the same for mixed growing and shrinking.
        var steps: [(String, () -> AXFailure?)] = []
        let pos = ("position", { setPosition(target.origin) })
        let siz = ("size", { setSize(target.size) })
        if needSize { steps.append(siz) }
        if needPosition { steps.append(pos) }
        if needSize && needPosition { steps.append(siz) }

        func failure(_ e: AXFailure, label: String) -> WriteResult {
            if e == .invalidElement || isGone() { return .gone }
            if e == .cannotComplete { return .timedOut }
            return .rejected("\(label): \(e.label)")
        }
        let wasEnhanced = enhancedUI() == true
        // Even reading this optional attribute can block while the user pauses or starts a drag.
        guard shouldContinue() else { return .interrupted }
        let disableFailure = wasEnhanced ? setEnhancedUI(false) : nil
        // Some apps can read this auxiliary attribute but do not implement writing it.
        // An explicit unsupported error falls back to a plain frame request.
        let unsupported = disableFailure == .notImplemented || disableFailure == .attributeUnsupported
        // Early returns in this closure still reach the restore below.
        let result: WriteResult = {
            if let e = disableFailure, !unsupported { return failure(e, label: "AXEnhancedUserInterface disable") }
            var rejected: [String: String] = [:]
            for (label, step) in steps {
                guard shouldContinue() else { return .interrupted }
                if let e = step() {
                    let outcome = failure(e, label: label)
                    if outcome == .gone || outcome == .timedOut { return outcome }
                    rejected[label] = e.label
                } else {
                    rejected[label] = nil
                }
            }
            return rejected.isEmpty ? .issued : .rejected(rejected.keys.sorted().map { "\($0): \(rejected[$0]!)" }.joined(separator: ", "))
        }()
        // Restore even after a timeout, since the app may still apply the change.
        let restoreFailure = wasEnhanced && !unsupported ? setEnhancedUI(true) : nil
        logger.debug("frame write enhanced=\(wasEnhanced, privacy: .public) disable=\(String(describing: disableFailure), privacy: .public) frame=\(String(describing: result), privacy: .public) restore=\(String(describing: restoreFailure), privacy: .public)")
        if let e = restoreFailure {
            let restoreResult = failure(e, label: "AXEnhancedUserInterface restore")
            if result == .gone || restoreResult == .gone { return .gone }
            if result == .timedOut || restoreResult == .timedOut { return .timedOut }
            return .rejected("AXEnhancedUserInterface restore: \(e.label); frame: \(result)")
        }
        return result
    }
}
