import Foundation
import LayoutCore
import MacSupport
import Operations

/// Saved state. Layout intent is kept apart from observations and results.
struct PersistedState: Codable {
    var paused: Bool = false
    /// Layout intent per Space, saved only from completed operations.
    /// The exception is mouse edits (dragging a divider, dropping a window): the user's intent is settled then, so it is saved before arranging,
    /// and the next correction does not revert to the old layout even if arranging stops.
    var layouts: [String: Layout] = [:]
    /// Floating windows per Space: kept out of the layout, positions preserved.
    var floating: [String: [WindowID]] = [:]
    /// Zoomed window per Space.
    var zoomed: [String: WindowID] = [:]
    var firstLaunchDone: Bool = false
    /// Launch time and user name. If they differ, window IDs are not trusted.
    var sessionKey: String = ""
    /// Measured sizes within the login session. Window IDs are invalid after logging in again.
    var sizeFacts: [PersistedSizeFact] = []
    /// Returns a floated window to its layout from before it floated.
    var floatHomes: [String: [FloatHome]] = [:]
    /// Spaces with automatic arrangement turned off. Manual commands still work; other Spaces continue.
    var pausedSpaces: Set<String> = []
    /// Dialog region per Space (`place-dialogs-beside`), committed only by completed operations like layout intent.
    var dialogRegions: [String: DialogRegion]? = nil
}

/// The layout right before floating removed the window. Restoring returns it into this tree instead of appending.
struct FloatHome: Codable, Equatable {
    var id: WindowID
    var layout: Layout
}

/// One window's measured size. Holds WindowID as a value because it cannot be a JSON object key.
struct PersistedSizeFact: Codable, Equatable {
    var id: WindowID
    var entry: ConstraintKnowledge.Entry
}

final class StateStore {
    let root: URL
    private let stateURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Where state lives. No history of operations is kept here or anywhere else. `LAZYSPACE_SUPPORT` overrides it, leaving the usual support directory untouched.
    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LAZYSPACE_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LazySpace", isDirectory: true)
    }

    init(root: URL? = nil) {
        let base = root ?? Self.defaultRoot
        self.root = base
        self.stateURL = base.appendingPathComponent("state.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL), let s = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return s
    }

    func save(_ state: PersistedState) {
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
