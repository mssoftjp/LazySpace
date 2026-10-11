import XCTest
import LayoutCore
@testable import Operations

final class ConstraintKnowledgeTests: XCTestCase {
    func testMaximumExpiresWithoutExtendingOnObservation() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let knowledge = ConstraintKnowledge(ttl: 15 * 60, now: { now })
        let area = CGRect(x: 0, y: 33, width: 1920, height: 1050)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 1920, height: 1050),
            actual: CGRect(x: 0, y: 33, width: 1000, height: 700),
            spaceID: 7, workArea: area, tolerance: 1)
        now = now.addingTimeInterval(10 * 60)
        knowledge.recordObservedSize(id: WindowID(1), actual: CGSize(width: 1000, height: 700))
        XCTAssertEqual(knowledge.maximums(for: [WindowID(1)], workArea: area)[WindowID(1)], CGSize(width: 1000, height: 700))
        now = now.addingTimeInterval(5 * 60 + 1)
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: area)[WindowID(1)])
    }

    func testMaximumDoesNotApplyToAnotherWorkArea() {
        let knowledge = ConstraintKnowledge()
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: area,
            actual: CGRect(x: 0, y: 0, width: 800, height: 600),
            spaceID: 7, workArea: area, tolerance: 1)
        let other = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: other)[WindowID(1)])
        XCTAssertEqual(knowledge.maximums(for: [WindowID(1)], workArea: area)[WindowID(1)]?.width, 800)
    }

    func testOldFactDropsTheMaximumAndKeepsTheMinimum() throws {
        let area = CGRect(x: 0, y: 25, width: 1440, height: 900)
        let learned = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = ConstraintKnowledge.Entry(
            minimum: CGSize(width: 120, height: 80),
            maximum: CGSize(width: 640, height: 480),
            observedAt: learned,
            spaceID: 7,
            workArea: area,
            maximumLearnedAt: learned,
            maximumWorkArea: area)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "maximumLearnedAt")
        object.removeValue(forKey: "maximumWorkArea")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ConstraintKnowledge.Entry.self, from: old)
        XCTAssertEqual(restored.minimum, CGSize(width: 120, height: 80))
        XCTAssertNil(restored.maximumLearnedAt)
        let knowledge = ConstraintKnowledge()
        knowledge.restore([WindowID(4): restored], observedAt: Date())
        XCTAssertNil(knowledge.maximums(for: [WindowID(4)], workArea: area)[WindowID(4)])
        XCTAssertEqual(knowledge.constraints(for: [WindowID(4)], spaceID: 7, workArea: area)[WindowID(4)], .estimated(CGSize(width: 120, height: 80)))
    }
}
