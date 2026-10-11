import ApplicationServices
import Foundation
import XCTest
@testable import MacSupport

final class AXReadBudgetTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    /// Like AX, an element override takes precedence over the global timeout until reset to zero.
    private final class Element: AXFrameReading {
        let clock: Clock
        var timeout: TimeInterval = 0
        var globalTimeout: TimeInterval = 1
        var positionDelay: TimeInterval = 0
        var sizeDelay: TimeInterval = 0
        var requests: [(String, TimeInterval)] = []
        var timeoutChanges: [TimeInterval] = []

        init(_ clock: Clock) { self.clock = clock }

        func setMessagingTimeout(_ seconds: TimeInterval) {
            timeout = seconds
            timeoutChanges.append(seconds)
        }

        private func request(_ name: String, delay: TimeInterval) -> Bool {
            let effectiveTimeout = timeout == 0 ? globalTimeout : timeout
            requests.append((name, effectiveTimeout))
            clock.now.addTimeInterval(min(delay, effectiveTimeout))
            return delay <= effectiveTimeout
        }

        func point(_ name: String) -> Result<CGPoint, AXFailure> {
            request(name, delay: positionDelay) ? .success(CGPoint(x: 10, y: 20)) : .failure(.cannotComplete)
        }

        func size(_ name: String) -> Result<CGSize, AXFailure> {
            request(name, delay: sizeDelay) ? .success(CGSize(width: 640, height: 480)) : .failure(.cannotComplete)
        }
    }

    func testFrameRecomputesTimeoutAfterPositionConsumesMostOfBudget() {
        let clock = Clock()
        let started = clock.now
        let element = Element(clock)
        element.positionDelay = 0.23
        element.sizeDelay = 0.1
        let budget = AXReadBudget(timeout: 1, deadline: started.addingTimeInterval(0.25), now: { clock.now })

        XCTAssertEqual(budget.frame(element), .failure(.cannotComplete))
        XCTAssertEqual(element.requests.map(\.0), [kAXPositionAttribute, kAXSizeAttribute])
        XCTAssertEqual(element.requests[0].1, 0.25, accuracy: 0.000001)
        XCTAssertEqual(element.requests[1].1, 0.02, accuracy: 0.000001)
        XCTAssertEqual(clock.now.timeIntervalSince(started), 0.25, accuracy: 0.000001)
    }

    func testExpiredDeadlineDoesNotIssueSizeRequest() {
        let clock = Clock()
        let started = clock.now
        let element = Element(clock)
        element.positionDelay = 0.25
        let budget = AXReadBudget(timeout: 1, deadline: started.addingTimeInterval(0.25), now: { clock.now })

        XCTAssertEqual(budget.frame(element), .failure(.cannotComplete))
        XCTAssertEqual(element.requests.map(\.0), [kAXPositionAttribute])
    }

    func testCachedElementUsesGlobalTimeoutAfterOverrideIsCleared() {
        let clock = Clock()
        let element = Element(clock)
        let budget = AXReadBudget(timeout: 1, deadline: clock.now.addingTimeInterval(0.25), now: { clock.now })
        clock.now.addTimeInterval(0.249)
        XCTAssertTrue(budget.prepare(element))
        XCTAssertLessThan(element.timeout, 0.002)

        let cached = budget.prepareForCaching(element)
        XCTAssertTrue(cached === element)
        XCTAssertEqual(cached.timeout, 0)
        cached.globalTimeout = 0.5
        cached.positionDelay = 0.05
        XCTAssertEqual(cached.point(kAXPositionAttribute), .success(CGPoint(x: 10, y: 20)))
        XCTAssertEqual(cached.requests.last?.1, 0.5)
    }

    func testUnboundedFramePreservesGlobalTimeoutAndGeometry() {
        let clock = Clock()
        let element = Element(clock)
        element.globalTimeout = 0.75
        let budget = AXReadBudget(timeout: 1, deadline: nil, now: { clock.now })

        XCTAssertEqual(budget.frame(element), .success(CGRect(x: 10, y: 20, width: 640, height: 480)))
        XCTAssertTrue(element.timeoutChanges.isEmpty)
        XCTAssertEqual(element.requests.map(\.1), [0.75, 0.75])
    }
}
