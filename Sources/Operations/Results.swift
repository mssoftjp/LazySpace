import CoreGraphics
import Foundation
import LayoutCore

/// A window left out and why.
public struct Exclusion: Equatable, Codable {
    /// Reason identifier for decisions. The display text (reason) varies by language, so it is never compared.
    public enum Code: String, Codable {
        /// Did not fit even at minimum size; floated in place.
        case overflowFloat
    }
    public var window: ObservedWindow
    public var reason: String
    public var code: Code?

    public init(window: ObservedWindow, reason: String, code: Code? = nil) {
        self.window = window; self.reason = reason; self.code = code
    }
}

/// Result of inspecting targets. Writes nothing.
public struct Inspection: Equatable, Codable {
    public var snapshot: Snapshot
    public var targets: [ObservedWindow]
    public var excluded: [Exclusion]
    public var takenAt: Date
}

public struct TargetReport: Equatable, Codable {
    public enum Status: String, Codable {
        /// Plan and actual frame match.
        case verified
        /// Written, but the actual frame does not match.
        case mismatch
        /// Already matched the plan; no write needed.
        case unchanged
        /// Stopped before writing.
        case unapplied
        /// Disappeared during the operation.
        case gone
    }
    public var id: WindowID
    public var app: String
    public var before: CGRect
    public var planned: CGRect?
    public var after: CGRect?
    public var status: Status
    public var issued: Int
    public var note: String?
    /// Kind of the note, used for decisions (the note is display text). nil for notes without a kind.
    public var noteKind: NoteKind?

    public enum NoteKind: String, Codable {
        /// Held at the learned maximum size instead of filling the frame.
        case maximumSizeCap
        /// Minimum size measured; the recalculation matched.
        case minimumSizeMeasured
        /// Actual size larger than requested because of a minimum size.
        case minimumSizePushback
        /// Maximum size measured repeatedly; the position within the frame matched.
        case maximumSizeConfirmed
        /// Not restored to the original position because the operation stopped.
        case notRestoredAfterStop
        /// Restored to the original position because it did not fit.
        case restoredOriginal
        /// Could not be restored to the original position.
        case restoreFailed

        /// A note based on a measured minimum size.
        public var isMinimumSize: Bool { self == .minimumSizePushback || self == .minimumSizeMeasured }
        /// A note about restoring the original position.
        public var isRestore: Bool { self == .notRestoredAfterStop || self == .restoredOriginal || self == .restoreFailed }
    }

}

public enum Outcome: Equatable, Codable {
    case complete
    case partial
    case interrupted
    case notPossible
    case nothingToDo
}

public enum StopReason: String, Codable {
    case paused
    case userInput
    case spaceChanged
    case permissionLost
    case targetsChanged
    case appUnresponsive
    case cancelled
}

/// Durations of one operation, for judging improvements. keyToFirstWriteMs is nil for operations not started by a key.
public struct OperationTiming: Equatable, Codable {
    public var observeMs: Double = 0
    public var planMs: Double = 0
    public var writeMs: Double = 0
    public var settleMs: Double = 0
    public var keyToFirstWriteMs: Double?
    public init(observeMs: Double = 0, planMs: Double = 0, writeMs: Double = 0, settleMs: Double = 0, keyToFirstWriteMs: Double? = nil) {
        self.observeMs = observeMs
        self.planMs = planMs
        self.writeMs = writeMs
        self.settleMs = settleMs
        self.keyToFirstWriteMs = keyToFirstWriteMs
    }
}

/// One timeline event. `at` is ms since the origin (operation acceptance), one decimal, monotonic clock.
/// Stepping adds `step` (from 1); hotkey posts repeated within one operation add `attempt` (from 1).
public struct TimelineEvent: Codable, Equatable {
    public var at: Double
    public var event: String
    public var step: Int?
    public var attempt: Int?

    public init(at: Double, event: String, step: Int? = nil, attempt: Int? = nil) {
        self.at = at; self.event = event; self.step = step; self.attempt = attempt
    }
}

/// Ordered timeline of one operation (`accepted` -> `queued` -> `prepared` -> `mainKeyPosted` -> `arrivalObserved` -> `activationConfirmed` -> `published`).
/// The clock is `ContinuousClock`; the origin is acceptance (when ControlPort accepted the request, or when Coordinator accepted a key action).
/// Written from both the main thread and the operations queue, so lock-protected. Kept up to the failure point on failure.
public final class OperationTimeline {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let lock = NSLock()
    private var recorded: [TimelineEvent] = []

    /// Sets the origin to now and records `accepted`.
    public init() {
        origin = clock.now
        mark("accepted")
    }

    public func mark(_ event: String, step: Int? = nil, attempt: Int? = nil) {
        // Read the time and append under the same lock so list order matches time order.
        lock.lock(); defer { lock.unlock() }
        let elapsed = clock.now - origin
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        recorded.append(TimelineEvent(at: (ms * 10).rounded() / 10, event: event, step: step, attempt: attempt))
    }

    public var events: [TimelineEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// Same timeline (same operation); used to compare queue entries.
extension OperationTimeline: Equatable {
    public static func == (lhs: OperationTimeline, rhs: OperationTimeline) -> Bool { lhs === rhs }
}

/// The final result of one operation. The UI and CLI show the same thing.
public struct OperationResult: Equatable, Codable {
    public var id: String
    public var kind: String
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: Outcome
    public var stopReason: StopReason?
    public var spaceID: UInt64?
    public var workArea: CGRect
    public var targets: [TargetReport]
    public var excluded: [Exclusion]
    public var issued: Int
    public var retries: Int
    /// Whether every target's actual frame was read back.
    public var verified: Bool
    public var maxWriteMs: Double
    public var wallMs: Double
    /// For the user: why it could not be done, and one remedy.
    public var message: String
    public var tolerance: Double
    public var rows: Int
    /// Apps that returned no window list; their presence rules out overall success.
    public var unobservedApps: [String]
    /// Breakdown of observing, planning, writing, and settling; nil for operations not measured.
    public var timing: OperationTiming?
    /// Ordered timeline since acceptance (`OperationTimeline`). Recorded for Space switches and moves, empty otherwise.
    public var timeline: [TimelineEvent] = []

    public init(id: String, kind: String, startedAt: Date, finishedAt: Date, outcome: Outcome, stopReason: StopReason?, spaceID: UInt64?, workArea: CGRect,
                targets: [TargetReport], excluded: [Exclusion], issued: Int, retries: Int, verified: Bool, maxWriteMs: Double, wallMs: Double,
                message: String, tolerance: Double, rows: Int, unobservedApps: [String], timing: OperationTiming? = nil) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.finishedAt = finishedAt; self.outcome = outcome; self.stopReason = stopReason
        self.spaceID = spaceID; self.workArea = workArea; self.targets = targets; self.excluded = excluded; self.issued = issued; self.retries = retries
        self.verified = verified; self.maxWriteMs = maxWriteMs; self.wallMs = wallMs; self.message = message; self.tolerance = tolerance; self.rows = rows
        self.unobservedApps = unobservedApps
        self.timing = timing
    }

    /// Record of an operation that writes no geometry (close and the like). Holds no target frames.
    public static func note(id: String = UUID().uuidString, kind: String, spaceID: UInt64?, message: String, ok: Bool, at now: Date = Date()) -> OperationResult {
        OperationResult(id: id, kind: kind, startedAt: now, finishedAt: now, outcome: ok ? .complete : .notPossible, stopReason: nil,
                        spaceID: spaceID, workArea: .zero, targets: [], excluded: [], issued: ok ? 1 : 0, retries: 0, verified: false, maxWriteMs: 0, wallMs: 0,
                        message: message, tolerance: 0, rows: 0, unobservedApps: [])
    }
}
