import XCTest

final class AutomaticIntegrationTests: XCTestCase {
    func testAutomaticIntegrationLifecycle() throws {
        for (name, passed) in try automaticIntegrationChecks() { XCTAssertTrue(passed, name) }
    }
}
