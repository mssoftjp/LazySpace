import XCTest
import LayoutCore
@testable import LazySpace

final class UserWorkQueueTests: XCTestCase {
    func testSameFocusDirectionKeepsTheFirstTicketSourceAndTime() {
        var queue = UserWorkQueue()
        let firstAt = Date(timeIntervalSince1970: 10)
        let secondAt = Date(timeIntervalSince1970: 11)
        let first = queue.enqueue(edit: .focus(.left), arrange: nil, source: "hotkey", pressedAt: firstAt, spaceKey: "1", ticket: "first")
        let second = queue.enqueue(edit: .focus(.left), arrange: nil, source: "menu", pressedAt: secondAt, spaceKey: "1", ticket: "second")
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "first")
        XCTAssertEqual(queue.count, 1)
        let item = queue.popFirst()
        XCTAssertEqual(item?.ticket, "first")
        XCTAssertEqual(item?.source, "hotkey")
        XCTAssertEqual(item?.pressedAt, firstAt)
        XCTAssertEqual(item?.repeats, 2)
        XCTAssertEqual(item?.edit, .focus(.left))
        XCTAssertNil(queue.popFirst())
    }

    func testDifferentFocusDirectionsAndSpacesDoNotCoalesce() {
        var queue = UserWorkQueue()
        XCTAssertEqual(queue.enqueue(edit: .focus(.left), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "1", ticket: "a"), "a")
        XCTAssertEqual(queue.enqueue(edit: .focus(.right), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "1", ticket: "b"), "b")
        XCTAssertEqual(queue.enqueue(edit: .focus(.right), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "2", ticket: "c"), "c")
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.popFirst()?.spaceKey, "1")
        XCTAssertEqual(queue.popFirst()?.edit, .focus(.right))
        XCTAssertEqual(queue.popFirst()?.spaceKey, "2")
    }

    func testResizeSignFlipDoesNotMergeAndSameSignSums() {
        var queue = UserWorkQueue()
        _ = queue.enqueue(edit: .resize(.horizontal, 0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "1", ticket: "grow")
        XCTAssertEqual(queue.enqueue(edit: .resize(.horizontal, -0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "1", ticket: "shrink"), "shrink")
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.popFirst()?.edit, .resize(.horizontal, 0.25))
        XCTAssertEqual(queue.popFirst()?.edit, .resize(.horizontal, -0.25))

        _ = queue.enqueue(edit: .resize(.horizontal, 0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "1", ticket: "first")
        XCTAssertEqual(queue.enqueue(edit: .resize(.horizontal, 0.5), arrange: nil, source: "menu", pressedAt: Date(), spaceKey: "1", ticket: "second"), "first")
        XCTAssertEqual(queue.first?.edit, .resize(.horizontal, 0.75))
        XCTAssertEqual(queue.first?.repeats, 2)
        XCTAssertEqual(queue.first?.source, "hotkey")
    }

    func testResizeSmartSumsDeltasWithTheSameSign() {
        var queue = UserWorkQueue()
        _ = queue.enqueue(edit: .resizeSmart(-0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "7", ticket: "first")
        XCTAssertEqual(queue.enqueue(edit: .resizeSmart(-0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "7", ticket: "second"), "first")
        XCTAssertEqual(queue.first?.edit, .resizeSmart(-0.5))
        XCTAssertEqual(queue.enqueue(edit: .resizeSmart(0.25), arrange: nil, source: "hotkey", pressedAt: Date(), spaceKey: "7", ticket: "flip"), "flip")
        XCTAssertEqual(queue.count, 2)
    }

    func testASecondArrangeForTheSameSpaceReturnsTheFirstTicket() {
        var queue = UserWorkQueue()
        let arrange = UserWorkQueue.Arrange(kind: "arrange", heldOut: [:], ignoreZoom: false)
        let other = UserWorkQueue.Arrange(kind: "integrate-waiting", heldOut: [:], ignoreZoom: true)
        XCTAssertEqual(queue.enqueue(edit: nil, arrange: arrange, source: "menu", pressedAt: Date(), spaceKey: "1", ticket: "first"), "first")
        XCTAssertEqual(queue.enqueue(edit: nil, arrange: arrange, source: "cli", pressedAt: Date(), spaceKey: "1", ticket: "second"), "first")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.enqueue(edit: nil, arrange: other, source: "menu", pressedAt: Date(), spaceKey: "1", ticket: "integrate"), "integrate")
        XCTAssertEqual(queue.enqueue(edit: nil, arrange: arrange, source: "menu", pressedAt: Date(), spaceKey: "2", ticket: "other-space"), "other-space")
        XCTAssertEqual(queue.count, 3)
        let dropped = queue.removeAll()
        XCTAssertEqual(dropped.map(\.ticket), ["first", "integrate", "other-space"])
        XCTAssertTrue(queue.isEmpty)
    }

    func testQueuesWhileBusyMatchesTheCommandSources() {
        XCTAssertTrue(UserWorkQueue.queuesWhileBusy("menu"))
        XCTAssertFalse(UserWorkQueue.queuesWhileBusy("agent"), "the CLI is refused as busy")
        XCTAssertTrue(UserWorkQueue.queuesWhileBusy("hotkey"))
        XCTAssertTrue(UserWorkQueue.queuesWhileBusy("hotkey-repeat"))
        XCTAssertFalse(UserWorkQueue.queuesWhileBusy("auto"))
        XCTAssertFalse(UserWorkQueue.queuesWhileBusy("mouse"))
    }
}
