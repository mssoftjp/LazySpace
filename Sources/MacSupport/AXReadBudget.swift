import ApplicationServices
import Foundation

/// The requests used to read a frame. A test element can model how each request consumes its timeout.
protocol AXFrameReading {
    func setMessagingTimeout(_ seconds: TimeInterval)
    func point(_ name: String) -> Result<CGPoint, AXFailure>
    func size(_ name: String) -> Result<CGSize, AXFailure>
}

extension AXElement: AXFrameReading {}

/// One deadline shared by every AX request in a snapshot, including the two requests for a frame.
struct AXReadBudget {
    let timeout: TimeInterval
    let deadline: Date?
    var now: () -> Date = { Date() }

    func prepare(_ element: some AXFrameReading) -> Bool {
        guard let deadline else { return true }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { return false }
        element.setMessagingTimeout(min(timeout, remaining))
        return true
    }

    func frame(_ element: some AXFrameReading) -> Result<CGRect, AXFailure> {
        guard prepare(element) else { return .failure(.cannotComplete) }
        let origin: CGPoint
        switch element.point(kAXPositionAttribute) {
        case .success(let point): origin = point
        case .failure(let failure): return .failure(failure)
        }
        guard prepare(element) else { return .failure(.cannotComplete) }
        switch element.size(kAXSizeAttribute) {
        case .success(let size): return .success(CGRect(origin: origin, size: size))
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Clear the per-window override before caching, restoring the current global AX timeout.
    func prepareForCaching<Element: AXFrameReading>(_ element: Element) -> Element {
        element.setMessagingTimeout(0)
        return element
    }
}
