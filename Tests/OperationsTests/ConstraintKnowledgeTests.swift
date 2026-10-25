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

    private let area = CGRect(x: 0, y: 30, width: 1920, height: 1050)
    private let kind = "com.apple.finder\nAXStandardWindow\nInfo"

    private func target(_ id: UInt32, _ width: CGFloat, _ height: CGFloat, kind: String? = nil, fullScreen: Bool = false) -> ConstraintKnowledge.KindTarget {
        ConstraintKnowledge.KindTarget(id: WindowID(id), kind: kind ?? self.kind, size: CGSize(width: width, height: height), fullScreenButtonEnabled: fullScreen)
    }

    /// Window 1 confirms a 400 x 700 maximum for the kind.
    private func learnKind(_ knowledge: ConstraintKnowledge) {
        knowledge.recordPullback(id: WindowID(1), requested: CGRect(x: 0, y: 30, width: 960, height: 1050),
                                 actual: CGRect(x: 0, y: 30, width: 400, height: 700), spaceID: 7, workArea: area, tolerance: 1, kind: kind)
    }

    private func reconcile(_ knowledge: ConstraintKnowledge, _ targets: [ConstraintKnowledge.KindTarget], adopt: Bool = true, workArea: CGRect? = nil) {
        knowledge.reconcileKinds(targets, adopt: adopt, spaceID: 7, workArea: workArea ?? area, tolerance: 1)
    }

    private func cap(_ knowledge: ConstraintKnowledge, _ id: UInt32, workArea: CGRect? = nil) -> CGSize? {
        knowledge.maximums(for: [WindowID(id)], workArea: workArea ?? area)[WindowID(id)]
    }

    func testANewWindowOfTheKindBorrowsOnlyTheMatchingMaximumAxes() {
        let knowledge = ConstraintKnowledge()
        learnKind(knowledge)
        reconcile(knowledge, [
            target(2, 400, 700),
            target(3, 380, 700),
            target(4, 400, 700, fullScreen: true),
            target(5, 400, 650),
        ])
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 400, height: 700))
        XCTAssertEqual(knowledge.constraints(for: [WindowID(2)], spaceID: 7, workArea: area)[WindowID(2)], .unknown, "minimums are not shared")
        XCTAssertEqual(cap(knowledge, 3), CGSize(width: 0, height: 700), "only the axis at the kind's size")
        XCTAssertNil(cap(knowledge, 4), "a window that can fill the screen does not borrow")
        XCTAssertEqual(cap(knowledge, 5), CGSize(width: 400, height: 0))
        let other = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        reconcile(knowledge, [target(6, 400, 700), target(7, 900, 900, kind: "other")], workArea: other)
        XCTAssertNil(cap(knowledge, 6, workArea: other), "learned in another work area")
        reconcile(knowledge, [target(8, 400, 700)], adopt: false)
        XCTAssertNil(cap(knowledge, 8), "a single target does not borrow")
    }

    func testABorrowedAxisExpiresWithTheKindsConfirmation() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let knowledge = ConstraintKnowledge(ttl: 15 * 60, now: { now })
        learnKind(knowledge)
        now = now.addingTimeInterval(14 * 60)
        reconcile(knowledge, [target(2, 400, 900), target(9, 900, 900, kind: "other")])
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 400, height: 0))
        // The window confirms its own height later; that does not extend the width it borrowed.
        knowledge.recordPullback(id: WindowID(2), requested: CGRect(x: 0, y: 30, width: 400, height: 1050),
                                 actual: CGRect(x: 0, y: 30, width: 400, height: 900), spaceID: 7, workArea: area, tolerance: 1, kind: kind)
        now = now.addingTimeInterval(2 * 60)
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 0, height: 900))
        // An expired kind axis is not borrowed; the fresh one is.
        reconcile(knowledge, [target(3, 400, 900), target(9, 900, 900, kind: "other")])
        XCTAssertEqual(cap(knowledge, 3), CGSize(width: 0, height: 900))
    }

    /// Two borrowed axes confirmed at different times each keep their own expiry: the older one going does not take the newer one with it.
    func testBorrowedAxesConfirmedAtDifferentTimesExpireSeparately() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let knowledge = ConstraintKnowledge(ttl: 15 * 60, now: { now })
        knowledge.recordPullback(id: WindowID(1), requested: CGRect(x: 0, y: 30, width: 960, height: 700),
                                 actual: CGRect(x: 0, y: 30, width: 400, height: 700), spaceID: 7, workArea: area, tolerance: 1, kind: kind)
        now = now.addingTimeInterval(10 * 60)
        knowledge.recordPullback(id: WindowID(9), requested: CGRect(x: 0, y: 30, width: 400, height: 1050),
                                 actual: CGRect(x: 0, y: 30, width: 400, height: 700), spaceID: 7, workArea: area, tolerance: 1, kind: kind)
        now = now.addingTimeInterval(4 * 60)
        reconcile(knowledge, [target(2, 400, 700), target(8, 900, 900, kind: "other")])
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 400, height: 700))
        now = now.addingTimeInterval(2 * 60)
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 0, height: 700), "the width confirmed 16 minutes ago expired; the height confirmed 6 minutes ago did not")
    }

    /// A maximum learned in another work area replaces the whole maximum: an axis learned on the first display, borrowed or the window's own,
    /// is not carried to the second.
    func testAMaximumLearnedInAnotherWorkAreaDoesNotCarryTheOtherAxis() {
        let other = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        let knowledge = ConstraintKnowledge()
        learnKind(knowledge)
        reconcile(knowledge, [target(2, 400, 900), target(8, 900, 900, kind: "other")])
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 400, height: 0))
        knowledge.recordPullback(id: WindowID(2), requested: CGRect(x: 0, y: 30, width: 300, height: 1410),
                                 actual: CGRect(x: 0, y: 30, width: 300, height: 900), spaceID: 7, workArea: other, tolerance: 1, kind: kind)
        XCTAssertEqual(cap(knowledge, 2, workArea: other), CGSize(width: 0, height: 900), "the borrowed width from the first display")
        knowledge.recordPullback(id: WindowID(3), requested: CGRect(x: 0, y: 30, width: 960, height: 1050),
                                 actual: CGRect(x: 0, y: 30, width: 500, height: 1050), spaceID: 7, workArea: area, tolerance: 1)
        knowledge.recordPullback(id: WindowID(3), requested: CGRect(x: 0, y: 30, width: 500, height: 1410),
                                 actual: CGRect(x: 0, y: 30, width: 500, height: 800), spaceID: 7, workArea: other, tolerance: 1)
        XCTAssertEqual(cap(knowledge, 3, workArea: other), CGSize(width: 0, height: 800), "the window's own width from the first display")
    }

    func testAWindowLargerThanTheKindsMaximumDropsItWhateverTheOrder() {
        for order: [UInt32] in [[2, 3], [3, 2]] {
            let knowledge = ConstraintKnowledge()
            learnKind(knowledge)
            let widths: [UInt32: CGFloat] = [2: 400, 3: 700]
            reconcile(knowledge, order.map { target($0, widths[$0]!, 700) })
            XCTAssertEqual(cap(knowledge, 2), CGSize(width: 0, height: 700), "order \(order)")
            XCTAssertEqual(cap(knowledge, 1), CGSize(width: 400, height: 700), "a window's own confirmation stays")
        }
    }

    func testAWindowWidenedLaterRetractsTheCopiesOthersBorrowed() {
        let knowledge = ConstraintKnowledge()
        learnKind(knowledge)
        reconcile(knowledge, [target(2, 400, 700), target(3, 400, 700)])
        knowledge.recordObservedSize(id: WindowID(2), actual: CGSize(width: 800, height: 700))
        XCTAssertEqual(cap(knowledge, 2), CGSize(width: 0, height: 700))
        XCTAssertEqual(cap(knowledge, 3), CGSize(width: 0, height: 700), "the copy another window borrowed goes too")
        XCTAssertEqual(cap(knowledge, 1), CGSize(width: 400, height: 700))
        reconcile(knowledge, [target(4, 400, 700), target(9, 900, 900, kind: "other")])
        XCTAssertEqual(cap(knowledge, 4), CGSize(width: 0, height: 700))
    }

    func testBorrowedAxesAreNotPersisted() {
        let knowledge = ConstraintKnowledge()
        learnKind(knowledge)
        reconcile(knowledge, [target(2, 400, 900), target(3, 400, 700)])
        knowledge.recordPullback(id: WindowID(2), requested: CGRect(x: 0, y: 30, width: 400, height: 1050),
                                 actual: CGRect(x: 0, y: 30, width: 400, height: 900), spaceID: 7, workArea: area, tolerance: 1, kind: kind)
        let saved = knowledge.snapshot
        XCTAssertEqual(saved[WindowID(1)]?.maximum, CGSize(width: 400, height: 700))
        XCTAssertEqual(saved[WindowID(2)]?.maximum, CGSize(width: 0, height: 900))
        XCTAssertEqual(saved[WindowID(3)]?.maximum ?? .zero, .zero)
        XCTAssertNil(saved[WindowID(3)]?.maximumLearnedAt)
        knowledge.forgetAll()
        reconcile(knowledge, [target(4, 400, 700), target(9, 900, 900, kind: "other")])
        XCTAssertNil(cap(knowledge, 4), "forgetting everything forgets the kinds too")
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
