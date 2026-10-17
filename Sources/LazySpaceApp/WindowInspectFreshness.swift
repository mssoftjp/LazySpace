import Foundation
import LayoutCore

/// Accepts a window-list read by the Space and permission generation it belongs to.
struct WindowInspectContext: Equatable {
    var spaceID: UInt64?
    var trusted: Bool
    var spaceObservationAvailable: Bool
}

enum WindowInspectFreshness {
    enum Decision: Equatable {
        /// Matches the current Space and permission: show it as the current list.
        case accept
        /// A newer read exists: drop this one.
        case ignore
        /// Does not match: clear the rows and read again for the current state.
        case rerequest
        /// Still does not match in the same state: stop retrying while the Space is unknown.
        case hold
    }

    /// `stableRetries`: retries already made while the requested and current states agree but the snapshot differs.
    static func decide(
        requestedGeneration: UInt64,
        latestGeneration: UInt64,
        requested: WindowInspectContext,
        snapshot: WindowInspectContext,
        current: WindowInspectContext,
        stableRetries: Int
    ) -> Decision {
        guard requestedGeneration == latestGeneration else { return .ignore }
        if requested != current { return .rerequest }
        if snapshot == current { return .accept }
        if stableRetries >= 1 { return .hold }
        return .rerequest
    }
}

struct WindowInspectLive {
    var spaceID: UInt64?
    var trusted: Bool
    var spaceObservationAvailable: Bool
    var waiting: Set<WindowID>
    var status: AppStatus
    var firstLaunchDone: Bool

    var context: WindowInspectContext {
        WindowInspectContext(spaceID: spaceID, trusted: trusted, spaceObservationAvailable: spaceObservationAvailable)
    }
}
