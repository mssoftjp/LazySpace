import XCTest
import Operations

/// Operation `timeline`: order, ms since acceptance, and storage in results.
final class OperationTimelineTests: XCTestCase {
    func testEventsAreOrderedFromAcceptanceInTenthsOfAMillisecond() {
        let timeline = OperationTimeline()
        timeline.mark("queued")
        timeline.mark("mainKeyPosted", step: 1, attempt: 1)
        Thread.sleep(forTimeInterval: 0.005)
        timeline.mark("arrivalObserved", step: 1, attempt: 1)
        let events = timeline.events
        XCTAssertEqual(events.map(\.event), ["accepted", "queued", "mainKeyPosted", "arrivalObserved"])
        XCTAssertEqual(events.first?.at, 0)
        XCTAssertEqual(events.map(\.at), events.map(\.at).sorted())
        XCTAssertGreaterThanOrEqual(events.last?.at ?? 0, 5)
        for event in events { XCTAssertEqual(event.at, (event.at * 10).rounded() / 10, "one decimal place") }
        XCTAssertEqual(events[2].step, 1)
        XCTAssertEqual(events[2].attempt, 1)
        XCTAssertNil(events[1].step)
    }

    /// Writes from two threads at once keep list order and time order in agreement.
    func testConcurrentMarksStayInTimeOrder() {
        let timeline = OperationTimeline()
        DispatchQueue.concurrentPerform(iterations: 200) { i in timeline.mark("e\(i)") }
        let times = timeline.events.map(\.at)
        XCTAssertEqual(times.count, 201)
        XCTAssertEqual(times, times.sorted())
    }

    /// Stored and read in the shipped format; a result missing the required timeline is rejected.
    func testResultsCarryTheTimelineAndRequireItWhenDecoding() throws {
        var result = OperationResult.note(id: "op", kind: "space", spaceID: 8, message: "Switched.", ok: true)
        // ISO 8601 keeps whole seconds, so use a time that compares equal.
        result.startedAt = Date(timeIntervalSince1970: 1_000_000); result.finishedAt = result.startedAt
        result.timeline = [TimelineEvent(at: 0, event: "accepted"), TimelineEvent(at: 12.3, event: "mainKeyPosted", step: 1, attempt: 2)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(result)
        XCTAssertEqual(try decoder.decode(OperationResult.self, from: data), result)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "timeline")
        XCTAssertThrowsError(try decoder.decode(OperationResult.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
