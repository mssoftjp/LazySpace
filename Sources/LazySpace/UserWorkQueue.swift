import Foundation
import LayoutCore
import Operations

/// User commands received while another operation runs. Read only under Coordinator's lock.
struct UserWorkQueue {
    struct MenuRequest: Equatable {
        var target: MenuWindowTarget
        var inputCount: UInt64
        var generation: UInt64
    }

    struct Arrange: Equatable {
        var kind: String
        var heldOut: [WindowID: String]
        var ignoreZoom: Bool
    }

    struct Item: Equatable {
        var ticket: String
        var edit: EditCommand?
        var arrange: Arrange?
        var source: String
        var pressedAt: Date
        var repeats: Int
        /// The Space at acceptance. Not run if it differs when dequeued.
        var spaceKey: String
        /// Timeline of a Space switch or move (origin: acceptance of the first `edit`), carried through the wait.
        var timeline: OperationTimeline? = nil
        /// Destination resolved at acceptance (Space switch or move by number or ID). Not resolved again when dequeued.
        var resolved: ResolvedSpace? = nil
        /// Keeps the window chosen in the menu instead of retargeting another front window after the wait.
        var menuRequest: MenuRequest? = nil
    }

    private var items: [Item] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var first: Item? { items.first }
    func contains(ticket: String) -> Bool { items.contains { $0.ticket == ticket } }

    static func queuesWhileBusy(_ source: String) -> Bool {
        source == "menu" || source.hasPrefix("hotkey")
    }

    private static func coalesces(_ current: EditCommand, _ next: EditCommand) -> Bool {
        switch (current, next) {
        case (.focus(let a), .focus(let b)): return a == b
        case (.resize(let axis, let a), .resize(let other, let b)): return axis == other && (a >= 0) == (b >= 0)
        case (.resizeSmart(let a), .resizeSmart(let b)): return (a >= 0) == (b >= 0)
        default: return false
        }
    }

    private static func merged(_ current: EditCommand, _ next: EditCommand) -> EditCommand {
        switch (current, next) {
        case (.resize(let axis, let a), .resize(_, let b)): return .resize(axis, a + b)
        case (.resizeSmart(let a), .resizeSmart(let b)): return .resizeSmart(a + b)
        default: return current
        }
    }

    /// Coalesced commands keep the earlier acceptance ID, source, and time. If the tail is a full arrangement of the same Space, a new one merges into it.
    @discardableResult
    mutating func enqueue(edit: EditCommand?, arrange: Arrange?, source: String, pressedAt: Date, spaceKey: String, ticket: String? = nil,
                          timeline: OperationTimeline? = nil, resolved: ResolvedSpace? = nil, menuRequest: MenuRequest? = nil) -> String {
        if let edit, var last = items.last, last.spaceKey == spaceKey, let previous = last.edit, Self.coalesces(previous, edit) {
            last.repeats += 1
            last.edit = Self.merged(previous, edit)
            items[items.count - 1] = last
            return last.ticket
        }
        if let arrange, arrange.kind == "arrange", items.last?.spaceKey == spaceKey, items.last?.arrange?.kind == "arrange", let last = items.last {
            return last.ticket
        }
        let id = ticket ?? UUID().uuidString
        items.append(Item(ticket: id, edit: edit, arrange: arrange, source: source, pressedAt: pressedAt, repeats: 1, spaceKey: spaceKey, timeline: timeline, resolved: resolved, menuRequest: menuRequest))
        return id
    }

    mutating func popFirst() -> Item? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    mutating func removeAll() -> [Item] {
        let dropped = items
        items.removeAll()
        return dropped
    }
}
