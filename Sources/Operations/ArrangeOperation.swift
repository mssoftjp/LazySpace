import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// One arrangement of the current Space.
public final class ArrangeOperation {
    /// Reason given when a window that does not fit even at minimum size is taken out of the tree in place.
    public static var overflowFloatReason: String {
        L(.arrangeOperationOverflowFloatReason)
    }
    /// Identifier for the overflowFloatReason exclusion; compared instead of the display text.
    public static let overflowFloatCode = Exclusion.Code.overflowFloat
    public let id: String
    private let system: WindowSystem
    private let control: OperationControl
    private let authorization: OperationAuthorization
    private let knowledge: ConstraintKnowledge
    private let limits: OperationLimits
    private var options: PlannerOptions
    private let priorLayout: Layout?
    /// Reconcile observed growth only for retained layouts, never for an explicit restored intent.
    private let adoptObservedProportions: Bool
    /// Windows left out of the operation and why (waiting windows, for example).
    private let heldOut: [WindowID: String]
    /// Windows to leave out found right before running, and why (excluded after acceptance; the caller sets this before run).
    public var heldOutAtExecution: [WindowID: String] = [:]
    /// Automatic operations handle only windows authorized at decision time; nil means every target of an explicit operation.
    private let allowedWindows: Set<WindowID>?
    /// Windows that triggered automatic integration. If none is an arrangement target (a transient window during a full-screen transition, for example), nothing is written.
    private let adding: Set<WindowID>
    private let kind: String
    /// What to do when an app that owns one of the windows does not answer.
    public enum UnansweredPolicy: Sendable {
        /// Arrange the windows that answered, without committing (the app's windows keep their place).
        case arrangeAround
        /// Write nothing, so the caller can try again once the app answers.
        case wait
        /// Arrange the windows that answered and commit that layout without the app's windows.
        case reclaim
    }
    private let unanswered: UnansweredPolicy
    /// Edit of layout intent: takes the current intent and frames computed from it, returns the new intent; nil means "cannot be done".
    public typealias Transform = (Layout, [WindowID: CGRect]) -> Layout?
    private let transform: Transform?
    private let transformFailure: String
    /// The temporarily zoomed window. If among the targets, only it fills the work area and the others stay put.
    private let zoomed: WindowID?
    /// Per-app rules: given the window, returns why it is excluded (nil means included).
    private let appRule: ((ObservedWindow) -> String?)?
    /// Protected windows. If the plan would change their current frames, it stops with "cannot be done" before writing.
    private let protected: Set<WindowID>
    /// App names shown in result text; bundle IDs by default.
    private let displayName: (String) -> String
    /// Edits observe only this window's app; nil observes every standard window on the Space.
    private let observedWindows: Set<WindowID>?
    /// The first layout calculation ignores learned maximums; recalculations after reading actual sizes use them as before.
    private let probeMaximums: Bool
    /// When accepted from a key or the menu; absent for automatic operations.
    private let pressedAt: Date?
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    /// Layout intent that may be saved afterward (only when complete).
    public private(set) var resultingLayout: Layout?

    // MARK: Dialog region (`place-dialogs-beside`)

    /// Options without the region reservation. When tiles do not fit, this is tried before floating tiles; nil means not tried.
    public var regionFallback: PlannerOptions?
    /// Gate for region operations (settings generation, feature active, the Space's automatic arrangement, mouse button). Checked after reads, before each write, and before completing.
    public var extraGate: (() -> Bool)?
    /// Whether this operation commits the region (it may complete on a region change alone, with no tiles or dialogs to place).
    public var appliesRegion = false
    /// Arranged after dropping the region reservation (the caller removes the saved region in the same commit).
    public private(set) var regionDropped = false
    /// Windows whose maximum this operation confirmed while each was the only window in the plan and requested without a cap,
    /// that is, from a request for the whole tiling area; the value is that tiling area (after any dropped strip).
    public private(set) var maximumsLearnedAlone: [WindowID: CGRect] = [:]

    /// One dialog to place in the region. `check` is the slow check right before writing (kind, identity, membership, not in front, size and work area as planned).
    public struct DialogPlacement {
        public var id: WindowID
        public var origin: CGPoint
        public var size: CGSize
        public var check: () -> Bool
        public init(id: WindowID, origin: CGPoint, size: CGSize, check: @escaping () -> Bool) {
            self.id = id; self.origin = origin; self.size = size; self.check = check
        }
    }

    public enum PlacementOutcome: Equatable {
        /// Written and read back at the planned position and size.
        case verified
        /// Failed the check and was not written (came forward, resized, and so on). The plan is stale, so the operation stops.
        case skipped
        /// Written and read back, but differs from the plan.
        case mismatch
        /// Written but could not be read back.
        case unreadable
        /// Could not be written.
        case failed
    }

    /// Result of placing dialogs.
    private enum PlacementRun { case done, stopped, aborted }

    /// Dialogs to place before writing tiles (written in the same operation under the same authorization).
    public var dialogPlacements: [DialogPlacement] = []
    public private(set) var placementOutcomes: [WindowID: PlacementOutcome] = [:]
    /// Sizes seen by this operation's observation before placing (for the record).
    public private(set) var placementObservedSizes: [WindowID: CGSize] = [:]

    /// Drops the region (when things do not fit); true if dropped.
    private func dropRegion() -> Bool {
        guard let fallback = regionFallback, !regionDropped else { return false }
        options = fallback
        regionDropped = true
        dialogPlacements = []
        return true
    }

    /// Writes only dialog positions and confirms by reading back. Lost authorization -> stopped; a failed check or placement -> aborted (nothing committed).
    private func placeDialogs(snapshot: Snapshot) -> PlacementRun {
        // If any size in this operation's observation differs from the plan, the plan is stale (the app reopened or resized the window).
        // Stop without writing any (so windows placed first are not undone by the next decision).
        var stale = false
        for placement in dialogPlacements {
            let observed = snapshot.windows.first(where: { $0.id == placement.id })
            placementObservedSizes[placement.id] = observed?.frame.size
            guard let observed, abs(observed.frame.width - placement.size.width) <= limits.tolerance,
                  abs(observed.frame.height - placement.size.height) <= limits.tolerance else { stale = true; continue }
        }
        if stale {
            for placement in dialogPlacements { placementOutcomes[placement.id] = .skipped }
            return .aborted
        }
        for placement in dialogPlacements {
            guard gate(snapshot: snapshot) == nil else { return .stopped }
            // Slow check (kind, identity, front, size, work area) right before the position setter, then the gate again.
            // On failure the plan is stale, so stop without writing the rest.
            var stalePlacement = false
            let result = system.writePosition(placement.id, origin: placement.origin, timeout: limits.perAppTimeout) { [self] in
                guard placement.check() else { stalePlacement = true; return false }
                return gate(snapshot: snapshot) == nil
            }
            if stalePlacement { placementOutcomes[placement.id] = .skipped; return .aborted }
            switch result {
            case .issued:
                // Read back. It differs from the plan only when the last two reads agree on a different frame (not while moving or when the last read failed).
                let target = CGRect(origin: placement.origin, size: placement.size)
                var outcome: PlacementOutcome = .unreadable
                var previous: CGRect?
                for attempt in 0..<6 {
                    if attempt > 0 { sleep(0.05) }
                    guard case .frame(let actual) = system.readFrame(placement.id) else { previous = nil; outcome = .unreadable; continue }
                    if actual.matches(target, tolerance: limits.tolerance) { outcome = .verified; break }
                    outcome = previous.map { $0.matches(actual, tolerance: limits.tolerance) } == true ? .mismatch : .unreadable
                    previous = actual
                }
                placementOutcomes[placement.id] = outcome
                if outcome != .verified { return .aborted }
            case .interrupted:
                return .stopped
            default:
                placementOutcomes[placement.id] = .failed
                return .aborted
            }
        }
        return gate(snapshot: snapshot) == nil ? .done : .stopped
    }

    /// Result when placement failed (nothing committed). If nothing was written, it is treated as nothing to do (not highlighted as the latest operation).
    private func placementAbortedResult(_ builder: inout ResultBuilder, started: () -> Double) -> OperationResult {
        let wroteNothing = placementOutcomes.values.allSatisfy { $0 == .skipped }
        return builder.finish(outcome: wroteNothing ? .nothingToDo : .partial, stopReason: nil,
                       message: L(.arrangeOperationTheFixedSizeWindowsCould),
                       finishedAt: now(), wallMs: started())
    }

    /// Number of strip dialogs that could not be confirmed (written but different, or not written).
    private var unplacedDialogs: Int { placementOutcomes.values.filter { $0 == .mismatch || $0 == .failed || $0 == .unreadable }.count }

    public init(
        system: WindowSystem,
        control: OperationControl,
        knowledge: ConstraintKnowledge,
        limits: OperationLimits = OperationLimits(),
        options: PlannerOptions = PlannerOptions(),
        priorLayout: Layout? = nil,
        adoptObservedProportions: Bool = true,
        heldOut: [WindowID: String] = [:],
        allowedWindows: Set<WindowID>? = nil,
        adding: Set<WindowID> = [],
        kind: String = "arrange",
        unanswered: UnansweredPolicy = .arrangeAround,
        transform: Transform? = nil,
        transformFailure: String? = nil,
        zoomed: WindowID? = nil,
        appRule: ((ObservedWindow) -> String?)? = nil,
        protected: Set<WindowID> = [],
        displayName: @escaping (String) -> String = { $0 },
        authorization: OperationAuthorization? = nil,
        observedWindows: Set<WindowID>? = nil,
        probeMaximums: Bool = false,
        pressedAt: Date? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.id = UUID().uuidString
        self.system = system
        self.control = control
        self.authorization = authorization ?? OperationAuthorization(system: system, control: control)
        self.knowledge = knowledge
        self.limits = limits
        self.options = options
        self.priorLayout = priorLayout
        self.adoptObservedProportions = adoptObservedProportions
        self.heldOut = heldOut
        self.allowedWindows = allowedWindows
        self.adding = adding
        self.kind = kind
        self.unanswered = unanswered
        self.transform = transform
        self.transformFailure = transformFailure ?? L(.arrangeOperationThisEditCantBePerformed)
        self.zoomed = zoomed
        self.appRule = appRule
        self.protected = protected
        self.displayName = displayName
        self.observedWindows = observedWindows
        self.probeMaximums = probeMaximums
        self.pressedAt = pressedAt
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Run

    public func run(progress: ((String) -> Void)? = nil) -> OperationResult {
        let lifetime = OperationLifetime()
        defer { lifetime.finish() }
        let startedAt = now()
        let clock = ContinuousClock()
        let t0 = clock.now
        func elapsedMs() -> Double { (clock.now - t0).milliseconds }

        progress?(L(.arrangeOperationCheckingWindows))
        let observeStart = clock.now
        let snapshot = system.snapshot(limitingTo: observedWindows)
        var inspection = TargetSelection.inspect(snapshot, now: startedAt, appRule: appRule, heldOut: heldOut.merging(heldOutAtExecution) { first, _ in first })
        if let allowedWindows {
            let deferred = inspection.targets.filter { !allowedWindows.contains($0.id) }
            inspection.targets.removeAll { !allowedWindows.contains($0.id) }
            let reason = L(.arrangeOperationNotPartOfThisAutomatic)
            inspection.excluded.append(contentsOf: deferred.map { Exclusion(window: $0, reason: reason) })
        }
        var builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: kind)
        builder.timing.observeMs = (clock.now - observeStart).milliseconds
        let planStart = clock.now

        guard snapshot.trusted else {
            return builder.finish(
                outcome: .notPossible, stopReason: .permissionLost,
                message: L(.arrangeOperationLazySpaceCantArrangeWindowsWithout(AccessPane.name(), AccessPane.name())),
                finishedAt: now(), wallMs: elapsedMs())
        }
        guard snapshot.spaceObservationAvailable, snapshot.spaceID != nil else {
            return builder.finish(
                outcome: .notPossible, stopReason: nil,
                message: L(.arrangeOperationWindowsWereNotArrangedBecause),
                finishedAt: now(), wallMs: elapsedMs())
        }
        if let reason = gate(snapshot: snapshot) {
            return builder.finish(
                outcome: .notPossible, stopReason: reason,
                message: Self.changedAfterRequestMessage,
                finishedAt: now(), wallMs: elapsedMs())
        }
        // A fit waiting for an app that did not answer writes nothing instead of placing the other windows over that app's windows.
        if unanswered == .wait, !snapshot.unobservedApps.isEmpty {
            let apps = snapshot.unobservedApps.map(displayName).joined(separator: Copy.listSeparator)
            return builder.finish(
                outcome: .nothingToDo, stopReason: .appUnresponsive,
                message: L(.arrangeOperationNotArrangedDidntReturnA(apps)),
                finishedAt: now(), wallMs: elapsedMs())
        }
        guard !inspection.targets.isEmpty else {
            // Even with no tiles, region changes are committed (operations that only place strip dialogs or only remove the strip),
            // and saved windows missing from a complete observation are removed (closed, or confirmed minimized or on another Space).
            // When the full window list could not be read, invisible windows are not treated as closed (an emptied layout is not committed).
            let prior = priorLayout ?? Layout(root: nil)
            let seen = Set(snapshot.windows.filter { $0.kind != .minimized && $0.membership != .other }.map(\.id))
            let gone = Set(prior.windowIDs).subtracting(seen)
            // A reclaim commits even when no window answered (the caller remembers the apps' windows to return).
            let reclaiming = unanswered == .reclaim && !snapshot.unobservedApps.isEmpty
            if appliesRegion || !gone.isEmpty, snapshot.unobservedApps.isEmpty || reclaiming, snapshot.windowListAvailable {
                if appliesRegion {
                    switch placeDialogs(snapshot: snapshot) {
                    case .stopped:
                        return builder.finish(outcome: .interrupted, stopReason: gate(snapshot: snapshot) ?? .userInput,
                                              message: Self.changedAfterRequestMessage, finishedAt: now(), wallMs: elapsedMs())
                    case .aborted:
                        return placementAbortedResult(&builder, started: elapsedMs)
                    case .done: break
                    }
                }
                resultingLayout = prior.removing(gone).normalized()
                let note = dialogPlacementMessage()
                let apps = snapshot.unobservedApps.map(displayName).joined(separator: Copy.listSeparator)
                let none = reclaiming
                    ? L(.arrangeOperationDidntReturnAWindowList(apps))
                    : L(.arrangeOperationNoWindowsToArrange)
                return builder.finish(outcome: .complete, stopReason: nil,
                                      message: note.isEmpty ? none : note,
                                      finishedAt: now(), wallMs: elapsedMs())
            }
            let apps = snapshot.unobservedApps.map(displayName).joined(separator: Copy.listSeparator)
            return builder.finish(
                outcome: .nothingToDo, stopReason: snapshot.unobservedApps.isEmpty ? nil : .appUnresponsive,
                message: snapshot.unobservedApps.isEmpty
                    ? L(.arrangeOperationNoWindowsToArrangeSee) : L(.arrangeOperationNoWindowsToArrangeUnobserved(apps)),
                finishedAt: now(), wallMs: elapsedMs())
        }
        // If none of the integration triggers (layer-0 windows seen in CGWindowList) is a standard window, this operation has no basis.
        // Transient windows apps show during full-screen transitions land here. Redistributing existing windows is left to refit for vanished windows.
        // If an app did not respond, its window may simply have been unobservable; automatic retries count this as a failure.
        if !adding.isEmpty, !inspection.targets.contains(where: { adding.contains($0.id) }) {
            return builder.finish(
                outcome: .nothingToDo, stopReason: snapshot.unobservedApps.isEmpty ? nil : .appUnresponsive,
                message: L(.arrangeOperationTheWindowToAddIsnt),
                finishedAt: now(), wallMs: elapsedMs())
        }

        progress?(L(.arrangeOperationCalculatingLayout))
        // The reservation does not fit the current work area (moved to a smaller screen, larger gaps): drop the region instead of silently ignoring it.
        if options.reservationIgnored(in: snapshot.workArea) { _ = dropRegion() }
        let focused = system.focusedWindowID()
        var ids = inspection.targets.map(\.id)
        for target in inspection.targets {
            knowledge.recordObservedSize(id: target.id, actual: target.frame.size)
        }
        var constraints = knowledge.constraints(for: ids, spaceID: snapshot.spaceID, workArea: snapshot.workArea)
        // With existing layout intent, remove vanished windows and add new ones at the siblings' average weight before distributing.
        var baseLayout: Layout
        if let prior = priorLayout, prior.root != nil {
            var layout = prior.removing(Set(prior.windowIDs).subtracting(ids))
            // With an edit (transform), how new windows are inserted is also up to the edit.
            if transform == nil {
                let existing = inspection.targets.filter { layout.windowIDs.contains($0.id) }
                let frames = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.frame) })
                let tiled = Self.covers(existing.map(\.frame), along: .horizontal, area: options.tilingArea(snapshot.workArea), tolerance: limits.tolerance)
                    || Self.covers(existing.map(\.frame), along: .vertical, area: options.tilingArea(snapshot.workArea), tolerance: limits.tolerance)
                for id in ids where !layout.windowIDs.contains(id) {
                    // Stack below a short fixed window only when the free space fits the preferred size; the tree is not rebuilt.
                    let known = constraints[id]?.size
                    let need = CGSize(
                        width: max(known?.width ?? 0, options.preferredMinimum.width),
                        height: max(known?.height ?? 0, options.preferredMinimum.height))
                    if tiled, let host = layout.unusedStackHost(rects: frames, area: options.tilingArea(snapshot.workArea), need: need) {
                        layout = layout.inserting(id, stackingBelow: host.id, hostHeight: host.usedHeight, unusedHeight: host.unusedHeight)
                    } else {
                        layout = layout.inserting(id)
                    }
                }
            }
            baseLayout = layout
        } else {
            var initial = Planner.initial(for: ids, in: snapshot.workArea, constraints: constraints, options: options, maximums: initialMaximums(ids, workArea: snapshot.workArea))
            if case .unfit = initial, dropRegion() {
                initial = Planner.initial(for: ids, in: snapshot.workArea, constraints: constraints, options: options, maximums: initialMaximums(ids, workArea: snapshot.workArea))
            }
            switch initial {
            case .fits(let p): baseLayout = p.layout
            case .unfit:
                // Build the tree even if no row count meets the preferred size; windows that do not fit are floated later.
                let rows = max(1, min(options.maxRows, max(ids.count, 1)))
                baseLayout = Planner.rowLayout(ids, rows: rows)
            }
        }
        // The edit (transforming layout intent).
        if let transform {
            let baseRects: [WindowID: CGRect]
            if case .fits(let p) = Planner.fit(baseLayout, in: snapshot.workArea, constraints: constraints, options: options, maximums: initialMaximums(ids, workArea: snapshot.workArea), focused: focused) { baseRects = p.rects } else { baseRects = [:] }
            guard let edited = transform(baseLayout, baseRects) else {
                builder.markAllUnapplied(note: L(.arrangeOperationEditNotPossible))
                return builder.finish(outcome: .notPossible, stopReason: nil, message: transformFailure, finishedAt: now(), wallMs: elapsedMs())
            }
            // Do not let the edit revive IDs that closed, moved to another Space, or became rule-excluded between acceptance and observation.
            baseLayout = edited.removing(Set(edited.windowIDs).subtracting(ids))
            for id in ids where !baseLayout.windowIDs.contains(id) { baseLayout = baseLayout.inserting(id) }
        }
        if adoptObservedProportions, priorLayout != nil, transform == nil, case .split(let axis, _, _)? = baseLayout.root {
            let caps = initialMaximums(ids, workArea: snapshot.workArea)
            if case .fits(let preview) = Planner.fit(baseLayout, in: snapshot.workArea, constraints: constraints, options: options, maximums: caps, focused: focused) {
                let grew = inspection.targets.contains { target in
                    guard let planned = preview.rects[target.id] else { return false }
                    let cap = caps[target.id]
                    let widthFree = cap == nil || cap!.width <= 0
                    let heightFree = cap == nil || cap!.height <= 0
                    return (widthFree && target.frame.width > planned.width + limits.tolerance)
                        || (heightFree && target.frame.height > planned.height + limits.tolerance)
                }
                let current = Dictionary(uniqueKeysWithValues: inspection.targets.map { ($0.id, $0.frame) })
                if grew, Self.covers(current.values.map { $0 }, along: axis, area: options.tilingArea(snapshot.workArea), tolerance: limits.tolerance) {
                    baseLayout = baseLayout.packing(rects: current)
                }
            }
        }
        var planOutcome = Planner.fit(baseLayout, in: snapshot.workArea, constraints: constraints, options: options, maximums: initialMaximums(ids, workArea: snapshot.workArea), focused: focused)
        // If the dialog region is why things do not fit, drop it and retry before floating tiles (tiles come first).
        if case .unfit = planOutcome, dropRegion() {
            planOutcome = Planner.fit(baseLayout, in: snapshot.workArea, constraints: constraints, options: options, maximums: initialMaximums(ids, workArea: snapshot.workArea), focused: focused)
        }
        if case .unfit = planOutcome, !kind.hasPrefix("edit:") {
            if let reason = gate(snapshot: snapshot) {
                return builder.finish(
                    outcome: .notPossible, stopReason: reason,
                    message: Self.changedAfterRequestMessage,
                    finishedAt: now(), wallMs: elapsedMs())
            }
            let prefer = adding.sorted() + baseLayout.windowIDs.reversed().filter { !adding.contains($0) }
            let relieved = OverflowRelief.relieve(
                baseLayout, in: snapshot.workArea, constraints: constraints, options: options,
                maximums: knowledge.maximums(for: ids, workArea: snapshot.workArea), preferring: prefer, focused: focused)
            let moving = inspection.targets.filter { relieved.floated.contains($0.id) }
            let nextIDs = inspection.targets.map(\.id).filter { !relieved.floated.contains($0) }
            let nextConstraints = knowledge.constraints(for: nextIDs, spaceID: snapshot.spaceID, workArea: snapshot.workArea)
            let nextOutcome = Planner.fit(
                relieved.layout, in: snapshot.workArea, constraints: nextConstraints, options: options,
                maximums: knowledge.maximums(for: nextIDs, workArea: snapshot.workArea), focused: focused)
            if !moving.isEmpty, case .fits = nextOutcome {
                inspection.targets.removeAll { relieved.floated.contains($0.id) }
                inspection.excluded.append(contentsOf: moving.map { Exclusion(window: $0, reason: Self.overflowFloatReason, code: Self.overflowFloatCode) })
                ids = nextIDs
                constraints = nextConstraints
                let keptTiming = builder.timing
                builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: kind)
                builder.timing = keptTiming
                baseLayout = relieved.layout
                planOutcome = nextOutcome
                if ids.isEmpty {
                    resultingLayout = baseLayout.normalized()
                    let names = moving.map { displayName($0.app) }.joined(separator: Copy.listSeparator)
                    return builder.finish(
                        outcome: .complete, stopReason: nil,
                        message: L(.arrangeOperationDidntFitKeptFloating(names, windows: moving.count)),
                        finishedAt: now(), wallMs: elapsedMs())
                }
            }
        }
        var plan: Plan
        switch planOutcome {
        case .fits(let p): plan = p
        case .unfit(let u):
            builder.markAllUnapplied(note: L(.arrangeOperationNotPossibleFoundBeforeMoving))
            let unfit = unfitMessage(u, targets: inspection.targets, area: snapshot.workArea)
            return builder.finish(
                outcome: .notPossible, stopReason: nil,
                message: kind.hasPrefix("edit:") ? L(.arrangeOperationEditDoesntFit(unfit)) : unfit,
                finishedAt: now(), wallMs: elapsedMs())
        }
        baseLayout = plan.layout
        // Zoom: only the target window fills the work area; the others leave the targets and keep their positions.
        if let zoomed, ids.contains(zoomed) {
            let others = inspection.targets.filter { $0.id != zoomed }
            inspection.targets.removeAll { $0.id != zoomed }
            inspection.excluded.append(contentsOf: others.map { Exclusion(window: $0, reason: L(.arrangeOperationKeptInPlaceWhileAnother)) })
            let keptTiming = builder.timing
            builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: kind)
            builder.timing = keptTiming
            plan.rects = [zoomed: options.tilingArea(snapshot.workArea).integralInset]
        }
        let finalLayout = baseLayout
        // Recalculations apply the same test: plans that would move current frames are never issued.
        func protectedConflict(_ rects: [WindowID: CGRect]) -> ObservedWindow? {
            inspection.targets.first { target in
                guard protected.contains(target.id), let planned = rects[target.id] else { return false }
                return !planned.matches(systemFrame(target.id, fallback: target.frame), tolerance: limits.tolerance)
            }
        }
        func protectionResult(_ target: ObservedWindow) -> OperationResult {
            if builder.issued == 0 {
                builder.markAllUnapplied(note: L(.arrangeOperationStoppedBecauseThePlanWould))
            } else if let reason = restoreOriginalFrames(&builder) {
                builder.markPendingUnapplied()
                return builder.finish(outcome: .interrupted, stopReason: reason, message: Self.interruptMessage(reason, builder: builder), finishedAt: now(), wallMs: elapsedMs())
            } else {
                builder.markPendingUnapplied()
            }
            return builder.finish(outcome: builder.issued == 0 || builder.rolledBack ? .notPossible : .partial, stopReason: nil,
                                  message: L(.arrangeOperationTheNewWindowCantJoin(target.app)),
                                  finishedAt: now(), wallMs: elapsedMs())
        }
        if let conflict = protectedConflict(plan.rects) { return protectionResult(conflict) }
        builder.rows = plan.rows

        // Dialog region: before writing tiles, place and confirm dialogs under the same authorization. If that stops or fails, no tile is written
        // and nothing is committed (avoiding the back-and-forth of shrinking tiles for an unplaceable strip and drift correction undoing it).
        if appliesRegion {
            switch placeDialogs(snapshot: snapshot) {
            case .stopped:
                let reason = gate(snapshot: snapshot) ?? .userInput
                builder.markAllUnapplied(note: Self.changedAfterRequestMessage)
                return builder.finish(outcome: .interrupted, stopReason: reason, message: Self.interruptMessage(reason, builder: builder), finishedAt: now(), wallMs: elapsedMs())
            case .aborted:
                builder.markAllUnapplied(note: L(.arrangeOperationNotMovedBecauseTheFixed))
                return placementAbortedResult(&builder, started: elapsedMs)
            case .done: break
            }
        }

        // MARK: Applying and reading back
        var retries = 0
        var didRedistribute = false
        // Writing the same plan again to confirm a constraint: once for a minimum and once for a maximum.
        var repeatedPlans = 0
        // Recalculations for minimums confirmed after the usual recalculation was spent (confirming takes a pass of its own).
        var minimumReplans = 0
        var didRelieve = false
        var stop: StopReason?
        var unresponsiveApps = Set<String>()

        var pullbacks: [WindowID: (requested: CGSize, actual: CGSize)] = [:]
        var pushbacks: [WindowID: (requested: CGSize, actual: CGSize)] = [:]
        var applyIteration = 0

        builder.timing.planMs = (clock.now - planStart).milliseconds
        applyLoop: while true {
            progress?(retries == 0 ? L(.arrangeOperationApplyingLayout) : L(.arrangeOperationRecalculatedToMatchActualSizes))
            // The first try requests frames larger than learned maximums; recalculations use the maximums.
            let maximums = (probeMaximums && applyIteration == 0) ? [:] : knowledge.maximums(for: ids, workArea: snapshot.workArea)
            applyIteration += 1
            var requests: [WindowID: CGRect] = [:]
            for (id, rect) in plan.rects { requests[id] = Self.clamp(rect, maximum: maximums[id]) }

            var wroteAny = false
            var timedOut = Set<WindowID>()
            var attemptedThisRound = Set<WindowID>()
            for target in inspection.targets {
                guard let planned = plan.rects[target.id], let request = requests[target.id] else { continue }
                var report = builder.report(for: target.id)
                report.planned = request
                if maximums[target.id] != nil, request != planned {
                    report.setNote(L(.arrangeOperationMaximumSizeDoesntFillIts(String(Int(request.width)), String(Int(request.height)))), .maximumSizeCap)
                }
                if report.status == .gone { builder.set(report); continue }
                if unresponsiveApps.contains(target.app) {
                    if report.issued == 0 {
                        report.status = .unapplied
                        report.setNote(L(.arrangeOperationNotSentBecauseTheSame))
                    }
                    builder.set(report)
                    continue
                }
                // Before each OS operation, check that it may still run.
                if let reason = gate(snapshot: snapshot) {
                    stop = reason
                    break applyLoop
                }
                let currentFrame: CGRect
                switch system.readFrame(target.id) {
                case .gone:
                    report.status = .gone
                    report.setNote(Self.closedDuringOperationNote)
                    builder.set(report)
                    knowledge.forget(target.id)
                    continue
                case .failed(let why):
                    report.status = .unapplied
                    report.setNote(L(.arrangeOperationCouldntReadTheWindowsFrame(why)))
                    builder.set(report)
                    continue
                case .frame(let current):
                    currentFrame = current
                    if protected.contains(target.id), !current.matches(request, tolerance: limits.tolerance) {
                        return protectionResult(target)
                    }
                    if current.matches(request, tolerance: limits.tolerance) {
                        if report.issued == 0 { report.status = .unchanged }
                        report.after = current
                        builder.set(report)
                        continue
                    }
                }
                // No write either if Pause or a Space switch happened during the synchronous AX read.
                if let reason = gate(snapshot: snapshot) {
                    stop = reason
                    break applyLoop
                }
                // Do not write a window that moved to another Space without input (unknown membership is left to the check at observation time).
                if movedToAnotherSpace(target.id) {
                    stop = .targetsChanged
                    break applyLoop
                }
                let w0 = clock.now
                if builder.timing.keyToFirstWriteMs == nil, let pressedAt {
                    builder.timing.keyToFirstWriteMs = now().timeIntervalSince(pressedAt) * 1000
                }
                let result = system.writeFrame(target.id, frame: request, currentFrame: currentFrame, timeout: limits.perAppTimeout) { [self] in
                    mayWrite(target.id, snapshot: snapshot)
                }
                let wd = clock.now - w0
                let writeMs = wd.milliseconds
                builder.maxWriteMs = max(builder.maxWriteMs, writeMs)
                builder.timing.writeMs += writeMs
                builder.issued += 1
                report.issued += 1
                wroteAny = true
                switch result {
                case .issued:
                    attemptedThisRound.insert(target.id)
                    report.status = .mismatch
                case .gone:
                    report.status = .gone
                    report.setNote(Self.closedDuringOperationNote)
                    knowledge.forget(target.id)
                case .rejected(let why):
                    attemptedThisRound.insert(target.id)
                    report.status = .mismatch
                    report.setNote(L(.arrangeOperationMacOSRejectedTheRequest(why)))
                case .timedOut:
                    report.status = .mismatch
                    report.setNote(L(.arrangeOperationTheAppDidntRespondIn))
                    unresponsiveApps.insert(target.app)
                    timedOut.insert(target.id)
                }
                builder.set(report)
                // Moved to another Space in the middle of the write: stop without writing the rest.
                if movedToAnotherSpace(target.id) {
                    stop = .targetsChanged
                    break applyLoop
                }
            }

            var settledFrames: [WindowID: SettledFrame] = [:]
            if wroteAny {
                // A raise after writing frames passes the same stop check right before sending.
                if let reason = gate(snapshot: snapshot) {
                    stop = reason
                } else if let focused, plan.layout.containsAccordion(around: focused),
                   inspection.targets.contains(where: { $0.id == focused }) {
                    _ = system.raise(focused, timeout: limits.perAppTimeout, activateIf: { [self] in
                        lifetime.isActive && gate(snapshot: snapshot) == nil
                    })
                }
                let settleStart = clock.now
                // Apps sometimes move their other windows along, so keep those windows in the settle check too.
                let changedApps = Set(inspection.targets.filter { attemptedThisRound.contains($0.id) }.map(\.app))
                settledFrames = waitUntilReadbackSettles(inspection.targets.filter { changedApps.contains($0.app) }, requests: requests)
                builder.timing.settleMs += (clock.now - settleStart).milliseconds
            }

            // After an interruption, records are read again; settled observations are not carried into another Space or input generation.
            if gate(snapshot: snapshot) != nil { settledFrames.removeAll() }

            // Read the actual positions and sizes back.
            progress?(L(.arrangeOperationCheckingActualSizes))
            var mismatched: [WindowID] = []
            var learned = false
            var needsRedistribute = false
            var repeatPlan = false
            var confirmedMinimum = false
            for target in inspection.targets {
                var report = builder.report(for: target.id)
                guard report.status != .gone, report.status != .unapplied, let request = report.planned else { continue }
                // Use the last measurement only right after the settle check; if reading other windows was slow, observe again.
                let actualRead: FrameRead
                if let settled = settledFrames[target.id], clock.now - settled.at <= .milliseconds(50),
                   gate(snapshot: snapshot) == nil {
                    actualRead = .frame(settled.frame)
                } else {
                    actualRead = system.readFrame(target.id)
                }
                switch actualRead {
                case .gone:
                    report.status = .gone
                    report.setNote(Self.closedBeforeCheckNote)
                    knowledge.forget(target.id)
                case .failed(let why):
                    report.status = .mismatch
                    report.setNote(Self.unreadableSizeNote(why))
                    mismatched.append(target.id)
                case .frame(let actual):
                    report.after = actual
                    // Sizes read after input, pause, cancellation, or a Space change may be the user's doing: kept in the result, but no constraints are learned.
                    let learnable = gate(snapshot: snapshot) == nil
                    if learnable { knowledge.recordObservedSize(id: target.id, actual: actual.size) }
                    if actual.matches(request, tolerance: limits.tolerance) {
                        if report.status != .unchanged { report.status = .verified }
                        if report.noteKind == .minimumSizePushback {
                            report.setNote(L(.arrangeOperationMeasuredMinimumSizeMatchedAfter(String(Int(actual.width)), String(Int(actual.height)))), .minimumSizeMeasured)
                        }
                    } else if timedOut.contains(target.id) || unresponsiveApps.contains(target.app) {
                        // The request was not processed, so the actual size is no evidence of constraints.
                        report.status = .mismatch
                        report.setNote(L(.arrangeOperationTheAppDidntRespondInTime(String(Int(actual.width)), String(Int(actual.height)))))
                        mismatched.append(target.id)
                    } else {
                        report.status = .mismatch
                        mismatched.append(target.id)
                        let pushed = learnable && (actual.width > request.width + limits.tolerance || actual.height > request.height + limits.tolerance)
                        let pulled = learnable && (actual.width < request.width - limits.tolerance || actual.height < request.height - limits.tolerance)
                        // As with a maximum, a minimum needs the same issued request to come back larger by the same amount again:
                        // an app that resizes its own window once (an Electron app maximizing a window it has just opened) gets the
                        // same plan written once more and then keeps its place, instead of turning into a window that cannot fit.
                        var pushNoted = false
                        if pushed {
                            let previous = pushbacks[target.id]
                            let written = attemptedThisRound.contains(target.id)
                            pushbacks[target.id] = written ? (request.size, actual.size) : nil
                            if written, let previous, previous.requested == request.size,
                               abs(previous.actual.width - actual.width) <= limits.tolerance,
                               abs(previous.actual.height - actual.height) <= limits.tolerance {
                                learned = true
                                knowledge.recordPushback(id: target.id, requested: request, actual: actual, spaceID: snapshot.spaceID, workArea: snapshot.workArea, tolerance: limits.tolerance, bundle: target.app, subrole: target.subrole)
                                report.setNote(L(.arrangeOperationLargerThanRequestedBecauseOf(String(Int(actual.width)), String(Int(actual.height)))), .minimumSizePushback)
                                pushNoted = true
                                confirmedMinimum = true
                            } else if limits.maxRetries > 0 {
                                repeatPlan = true
                            }
                        }
                        if pulled {
                            learned = true
                            // An unapplied request or a size mid-animation is never taken as a maximum.
                            // Learn only when the same issued request shows the same axis limit again.
                            let positionSettled = abs(actual.minX - request.minX) <= limits.tolerance
                                && abs(actual.minY - request.minY) <= limits.tolerance
                            if attemptedThisRound.contains(target.id), positionSettled {
                                var confirmedWidth = false
                                var confirmedHeight = false
                                if let previous = pullbacks[target.id] {
                                    var confirmed = request
                                    if previous.requested.width == request.width, abs(previous.actual.width - actual.width) <= limits.tolerance {
                                        confirmed.size.width = actual.width
                                        confirmedWidth = true
                                    }
                                    if previous.requested.height == request.height, abs(previous.actual.height - actual.height) <= limits.tolerance {
                                        confirmed.size.height = actual.height
                                        confirmedHeight = true
                                    }
                                    if confirmedWidth || confirmedHeight {
                                        knowledge.recordPullback(id: target.id, requested: request, actual: confirmed, spaceID: snapshot.spaceID, workArea: snapshot.workArea, tolerance: limits.tolerance)
                                        if plan.rects.count == 1, maximums[target.id] == nil { maximumsLearnedAlone[target.id] = options.tilingArea(snapshot.workArea).integralInset }
                                    }
                                }
                                pullbacks[target.id] = (request.size, actual.size)
                                let widthLimited = actual.width < request.width - limits.tolerance
                                let heightLimited = actual.height < request.height - limits.tolerance
                                // When a minimum-size recalculation changed the requested width, there is no repeat observation of the same request yet.
                                if (widthLimited && !confirmedWidth) || (heightLimited && !confirmedHeight) { repeatPlan = true }
                            } else {
                                // A size clipped at the screen edge at the pre-move position is not a constraint of the window.
                                pullbacks[target.id] = nil
                            }
                            let smaller = L(.arrangeOperationTheAppMadeItSmaller(String(Int(actual.width)), String(Int(actual.height))))
                            report.setNote(pushNoted ? L(.arrangeOperationNoteAndSmaller(report.note!, smaller)) : smaller, pushNoted ? .minimumSizePushback : nil)
                            // When a fixed size has been confirmed repeatedly and the position within the frame also matches, no further write is needed.
                            if let maximum = knowledge.maximums(for: [target.id], workArea: snapshot.workArea)[target.id] {
                                let adjusted = Self.clamp(request, maximum: maximum)
                                if actual.matches(adjusted, tolerance: limits.tolerance) {
                                    report.planned = adjusted
                                    report.status = .verified
                                    report.setNote(L(.arrangeOperationMaximumSizeConfirmedByRepeated(String(Int(adjusted.width)), String(Int(adjusted.height)))), .maximumSizeConfirmed)
                                    mismatched.removeAll { $0 == target.id }
                                    // While the frame is wider than the maximum, a recalculation that gives the excess to a resizable neighbor is still pending.
                                    // While zoomed, other windows do not move.
                                    if zoomed != target.id,
                                       request.width > adjusted.width + limits.tolerance || request.height > adjusted.height + limits.tolerance {
                                        needsRedistribute = true
                                    }
                                }
                            }
                        }
                        if !pushed && !pulled {
                            report.note = report.note ?? L(.arrangeOperationPositionDoesntMatchTheRequest)
                        }
                    }
                }
                builder.set(report)
            }
            builder.verified = true

            if let reason = gate(snapshot: snapshot) {
                stop = reason
                break applyLoop
            }

            if mismatched.isEmpty && !needsRedistribute { break applyLoop }
            let allowRetry = learned && retries < limits.maxRetries
            let allowRedistribute = needsRedistribute && !didRedistribute
            // Minimums can come to light one after another (a neighbor pushes back only once a recalculation made it narrower), and each
            // takes a confirming pass, so a minimum confirmed after the usual recalculation still gets one, twice at most. A recalculation
            // comes before writing the same plan again: it changes the requests that other windows would be confirming.
            let allowMinimumReplan = confirmedMinimum && limits.maxRetries > 0 && !allowRetry && !allowRedistribute && minimumReplans < 2
            let allowRepeat = repeatPlan && repeatedPlans < 2 && !allowRetry && !allowMinimumReplan
            guard allowRetry || allowRepeat || allowRedistribute || allowMinimumReplan else { break applyLoop }
            if allowRedistribute { didRedistribute = true }
            else if allowMinimumReplan { minimumReplans += 1 }
            else if allowRepeat { repeatedPlans += 1; continue }

            // Continue only if it can be recalculated keeping the structure, under the same authorization and limits.
            // Windows with confirmed maximums shrink their frames by that much and give the space to uncapped windows.
            constraints = knowledge.constraints(for: ids, spaceID: snapshot.spaceID, workArea: snapshot.workArea)
            switch Planner.fit(plan.layout, in: snapshot.workArea, constraints: constraints, options: options, maximums: knowledge.maximums(for: ids, workArea: snapshot.workArea), focused: focused) {
            case .fits(let replanned):
                plan = replanned
                if let zoomed, ids.contains(zoomed) { plan.rects = [zoomed: options.tilingArea(snapshot.workArea).integralInset] }
                if let conflict = protectedConflict(plan.rects) { return protectionResult(conflict) }
                retries += 1
            case .unfit(let u):
                // Learned maximums or minimums from actual sizes no longer fit: drop the region and retry (before floating tiles).
                if dropRegion(), case .fits(let replanned) = Planner.fit(plan.layout, in: snapshot.workArea, constraints: constraints, options: options, maximums: knowledge.maximums(for: ids, workArea: snapshot.workArea), focused: focused) {
                    plan = replanned
                    if let zoomed, ids.contains(zoomed) { plan.rects = [zoomed: options.tilingArea(snapshot.workArea).integralInset] }
                    if let conflict = protectedConflict(plan.rects) { return protectionResult(conflict) }
                    retries += 1
                    continue
                }
                if !didRelieve, !kind.hasPrefix("edit:"),
                   let relieved = relieveOverflow(plan: plan, inspection: &inspection, builder: &builder, constraints: constraints) {
                    didRelieve = true
                    plan = relieved.plan
                    ids = relieved.ids
                    builder.unfitNote = nil
                    if ids.isEmpty { break applyLoop }
                    retries += 1
                    continue
                }
                builder.unfitNote = unfitMessage(u, targets: inspection.targets, area: snapshot.workArea)
                break applyLoop
            }
        }

        builder.retries = retries
        if stop == nil, builder.unfitNote == nil, builder.issued > 0,
           builder.reports.values.contains(where: { $0.status == .mismatch }) {
            constraints = knowledge.constraints(for: ids, spaceID: snapshot.spaceID, workArea: snapshot.workArea)
            if case .unfit(let u) = Planner.fit(plan.layout, in: snapshot.workArea, constraints: constraints, options: options, maximums: knowledge.maximums(for: ids, workArea: snapshot.workArea), focused: focused) {
                builder.unfitNote = unfitMessage(u, targets: inspection.targets, area: snapshot.workArea)
            }
        }
        if stop == nil, builder.unfitNote != nil, builder.issued > 0, kind.hasPrefix("edit:") {
            progress?(L(.arrangeOperationReturningWindowsToTheirOriginal))
            if let reason = restoreOriginalFrames(&builder) {
                stop = reason
            }
        }
        let finishedAt = now()

        if let stop {
            // Stop handling: no new requests, but windows already sent are read back and confirmed.
            progress?(L(.arrangeOperationStoppingCheckingRequestsAlreadySent))
            for target in inspection.targets {
                var report = builder.report(for: target.id)
                if report.noteKind == .notRestoredAfterStop { continue }
                guard report.issued > 0, report.status != .gone, let request = report.planned else { continue }
                switch system.readFrame(target.id) {
                case .gone: report.status = .gone; report.setNote(Self.closedBeforeCheckNote)
                case .failed(let why): report.status = .mismatch; report.note = report.note ?? Self.unreadableSizeNote(why)
                case .frame(let actual):
                    report.after = actual
                    report.status = actual.matches(request, tolerance: limits.tolerance) ? .verified : .mismatch
                    if report.status == .mismatch {
                        report.note = report.note ?? L(.arrangeOperationDidntMatchTheRequestWhen(String(Int(actual.width)), String(Int(actual.height))))
                    }
                }
                builder.set(report)
            }
            builder.verified = true
            builder.markPendingUnapplied()
            return builder.finish(outcome: .interrupted, stopReason: stop, message: Self.interruptMessage(stop, builder: builder), finishedAt: finishedAt, wallMs: elapsedMs())
        }
        let statuses = builder.reports.values.map(\.status)
        let allGood = statuses.allSatisfy { $0 == .verified || $0 == .unchanged }
        if allGood, !snapshot.unobservedApps.isEmpty {
            // Some apps could not be observed. What moved is correct, but this is not overall success.
            let apps = snapshot.unobservedApps.map(displayName).joined(separator: Copy.listSeparator)
            if unanswered == .reclaim {
                // The layout without those apps' windows is committed; the windows stay where they are (the caller remembers them to return).
                resultingLayout = zoomed == nil ? plan.layout.normalized().packing(rects: plan.rects) : finalLayout.normalized()
                return builder.finish(outcome: .complete, stopReason: nil,
                                      message: L(.arrangeOperationArrangedUnobservedLeft(windows: statuses.count, apps)),
                                      finishedAt: finishedAt, wallMs: elapsedMs())
            }
            let message = L(.arrangeOperationArrangedUnobservedUnconfirmed(windows: statuses.count, apps))
            return builder.finish(outcome: .partial, stopReason: .appUnresponsive, message: message, finishedAt: finishedAt, wallMs: elapsedMs())
        }
        if allGood {
            resultingLayout = zoomed == nil ? plan.layout.normalized().packing(rects: plan.rects) : finalLayout.normalized()
            let placementNote = dialogPlacementMessage()
            let note = overflowSuffix(builder) + (placementNote.isEmpty ? "" : Copy.sentenceSeparator + placementNote)
            return builder.finish(outcome: .complete, stopReason: nil, message: completeMessage(tiled: statuses.count, ids: ids, note: note), finishedAt: finishedAt, wallMs: elapsedMs())
        }
        let goneOnly = statuses.allSatisfy { $0 == .verified || $0 == .unchanged || $0 == .gone }
        if goneOnly {
            let goneCount = statuses.filter { $0 == .gone }.count
            let message = L(.arrangeOperationClosedDuringArrangement(windows: goneCount))
            return builder.finish(outcome: .partial, stopReason: .targetsChanged, message: message, finishedAt: finishedAt, wallMs: elapsedMs())
        }
        if builder.rolledBack, let unfit = builder.unfitNote {
            return builder.finish(outcome: .notPossible, stopReason: nil,
                                  message: unfit + Copy.sentenceSeparator + L(.arrangeOperationWindowsWereReturned),
                                  finishedAt: finishedAt, wallMs: elapsedMs())
        }
        var stopReason: StopReason? = nil
        if !unresponsiveApps.isEmpty { stopReason = .appUnresponsive }
        return builder.finish(outcome: .partial, stopReason: stopReason, message: partialMessage(builder: builder, unresponsive: unresponsiveApps), finishedAt: finishedAt, wallMs: elapsedMs())
    }

    /// One sentence on the result of placing strip dialogs.
    private func dialogPlacementMessage() -> String {
        let unplaced = unplacedDialogs
        let placed = placementOutcomes.values.filter { $0 == .verified }.count
        if unplaced > 0 {
            return L(.arrangeOperationFixedSizeNotPlaced(windows: unplaced))
        }
        return placed == 0 ? "" : L(.arrangeOperationFixedSizePlaced(windows: placed))
    }

    /// Windows seen on another Space at least once during this operation. Not forgotten even if their membership later becomes unknown.
    private var departedWindows: Set<WindowID> = []

    /// Whether the window is known to be on another Space (including once during this operation). false when membership is unknown (left to the check at observation time).
    private func movedToAnotherSpace(_ id: WindowID) -> Bool {
        if departedWindows.contains(id) { return true }
        if system.membershipOf(id) == .other {
            departedWindows.insert(id)
            return true
        }
        return false
    }

    /// Check right before each setter on one window: the operation gate and the window's membership. The gate can change during the membership read, so it is checked once more at the end.
    private func mayWrite(_ id: WindowID, snapshot: Snapshot) -> Bool {
        gate(snapshot: snapshot) == nil && !movedToAnotherSpace(id) && gate(snapshot: snapshot) == nil
    }

    /// The rest is not written once a restore fails. Returns why it stopped midway.
    private func restoreOriginalFrames(_ builder: inout ResultBuilder) -> StopReason? {
        var restored = 0
        var failed = 0
        var stopped: StopReason?
        for id in builder.order {
            var report = builder.report(for: id)
            guard report.issued > 0, report.status != .gone else { continue }
            if stopped != nil {
                report.status = .unapplied
                report.setNote(Self.notRestoredAfterStopNote, .notRestoredAfterStop)
                builder.set(report)
                continue
            }
            if let reason = gate(snapshot: builder.snapshot) {
                stopped = reason
                report.status = .unapplied
                report.setNote(Self.notRestoredAfterStopNote, .notRestoredAfterStop)
                builder.set(report)
                continue
            }
            // Windows that moved to another Space are not restored (that would move them on their new Space).
            if movedToAnotherSpace(id) {
                report.status = .unapplied
                report.setNote(Self.notRestoredAfterStopNote, .notRestoredAfterStop)
                builder.set(report)
                continue
            }
            let original = restoreTarget(report)
            let snapshot = builder.snapshot
            switch system.writeFrame(id, frame: original, timeout: limits.perAppTimeout, shouldContinue: { [self] in mayWrite(id, snapshot: snapshot) }) {
            case .issued:
                builder.issued += 1
                report.issued += 1
                sleep(limits.settleDelay)
                switch system.readFrame(id) {
                case .frame(let actual):
                    report.after = actual
                    if frameRestored(actual, to: original) {
                        report.status = .unapplied
                        report.setNote(L(.arrangeOperationReturnedToItsOriginalPosition), .restoredOriginal)
                        restored += 1
                    } else {
                        report.status = .mismatch
                        report.setNote(L(.arrangeOperationCouldntReturnToItsOriginal(String(Int(actual.width)), String(Int(actual.height)))), .restoreFailed)
                        failed += 1
                    }
                case .gone:
                    report.status = .gone
                    report.setNote(Self.closedWhileRestoringNote)
                    failed += 1
                case .failed(let why):
                    report.status = .mismatch
                    report.setNote(L(.arrangeOperationCouldntReadTheActualSize(why)))
                    failed += 1
                }
            case .gone:
                report.status = .gone
                report.setNote(Self.closedWhileRestoringNote)
                failed += 1
            case .rejected(let why):
                report.status = .mismatch
                report.setNote(L(.arrangeOperationMovingItBackToIts(why)), .restoreFailed)
                failed += 1
            case .timedOut:
                report.status = .mismatch
                report.setNote(L(.arrangeOperationNoResponseWhileReturningIt), .restoreFailed)
                failed += 1
            }
            builder.set(report)
        }
        builder.rolledBack = restored > 0 && failed == 0 && stopped == nil
        return stopped
    }

    /// Back to the original origin. An original frame smaller than the learned minimum is grown to that minimum first.
    private func restoreTarget(_ report: TargetReport) -> CGRect {
        var frame = report.before
        if let minimum = knowledge.snapshot[report.id]?.minimum {
            if minimum.width > 0 { frame.size.width = max(frame.width, minimum.width) }
            if minimum.height > 0 { frame.size.height = max(frame.height, minimum.height) }
        }
        return frame
    }

    /// If the origin is back and the size is at least the request, it counts as restored even if the app held it at its minimum.
    private func frameRestored(_ actual: CGRect, to target: CGRect) -> Bool {
        if actual.matches(target, tolerance: limits.tolerance) { return true }
        let t = limits.tolerance
        return abs(actual.minX - target.minX) <= t
            && abs(actual.minY - target.minY) <= t
            && actual.width + t >= target.width
            && actual.height + t >= target.height
    }

    /// With an estimated maximum size, keeps the frame's origin and caps only the size.
    /// Probing operations pass no learned maximums to the first layout calculation.
    private func initialMaximums(_ ids: [WindowID], workArea: CGRect) -> [WindowID: CGSize] {
        if probeMaximums { return [:] }
        return knowledge.maximums(for: ids, workArea: workArea)
    }

    static func clamp(_ rect: CGRect, maximum: CGSize?) -> CGRect {
        guard let m = maximum else { return rect }
        var out = rect
        if m.width > 0 { out.size.width = min(rect.width, m.width) }
        if m.height > 0 { out.size.height = min(rect.height, m.height) }
        return out
    }

    /// Whether current frames cover the work area along this axis without gaps: a sign the user widened them after arranging.
    static func covers(_ frames: [CGRect], along axis: Axis, area: CGRect, tolerance: Double) -> Bool {
        let sorted = frames.sorted { axis == .horizontal ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard let first = sorted.first, let last = sorted.last else { return false }
        let start = axis == .horizontal ? first.minX : first.minY
        let end = axis == .horizontal ? last.maxX : last.maxY
        let areaStart = axis == .horizontal ? area.minX : area.minY
        let areaEnd = axis == .horizontal ? area.maxX : area.maxY
        if abs(start - areaStart) > tolerance || abs(end - areaEnd) > tolerance { return false }
        for index in 0..<(sorted.count - 1) {
            let edge = axis == .horizontal ? sorted[index].maxX : sorted[index].maxY
            let next = axis == .horizontal ? sorted[index + 1].minX : sorted[index + 1].minY
            if abs(edge - next) > tolerance { return false }
        }
        return true
    }

    // MARK: - Gate

    private func systemFrame(_ id: WindowID, fallback: CGRect) -> CGRect {
        if case .frame(let frame) = system.readFrame(id) { return frame }
        return fallback
    }

    private func gate(snapshot: Snapshot) -> StopReason? {
        guard system.axTrusted else { return .permissionLost }
        if let extraGate, !extraGate() { return .cancelled }
        return authorization.stopReason(system: system, control: control, snapshot: snapshot)
    }

    // MARK: - Messages

    private struct SettledFrame {
        var frame: CGRect
        var at: ContinuousClock.Instant
    }

    /// Reads for up to 400 ms until one reading matches every request, or two readings in a row agree.
    /// Tests with a zero wait return at once.
    private func waitUntilReadbackSettles(_ targets: [ObservedWindow], requests: [WindowID: CGRect]) -> [WindowID: SettledFrame] {
        guard !targets.isEmpty, limits.settleDelay > 0, !control.hurrySettle else { return [:] }
        let deadline = Date().addingTimeInterval(0.4)
        var previous: [WindowID: CGRect] = [:]
        while Date() < deadline {
            if control.hurrySettle { return [:] }
            sleep(min(limits.settleDelay, 0.05))
            var current: [WindowID: CGRect] = [:]
            var observed: [WindowID: SettledFrame] = [:]
            var stable = !previous.isEmpty
            var matched = true
            for target in targets {
                guard case .frame(let frame) = system.readFrame(target.id) else { stable = false; matched = false; continue }
                current[target.id] = frame
                observed[target.id] = SettledFrame(frame: frame, at: ContinuousClock().now)
                if previous[target.id] != frame { stable = false }
                if !(requests[target.id].map { frame.matches($0, tolerance: limits.tolerance) } ?? false) { matched = false }
            }
            if stable || matched, !control.hurrySettle { return observed }
            previous = current
        }
        return [:]
    }

    /// When a minimum size learned after writing makes things not fit, floats only the overflowing windows and rewrites the rest.
    private func relieveOverflow(
        plan: Plan,
        inspection: inout Inspection,
        builder: inout ResultBuilder,
        constraints: [WindowID: SizeKnowledge]
    ) -> (plan: Plan, ids: [WindowID])? {
        let area = builder.snapshot.workArea
        let prefer = adding.sorted() + plan.layout.windowIDs.reversed().filter { !adding.contains($0) }
        let maximums = knowledge.maximums(for: plan.layout.windowIDs, workArea: area)
        let relieved = OverflowRelief.relieve(
            plan.layout, in: area, constraints: constraints, options: options, maximums: maximums, preferring: prefer, focused: system.focusedWindowID())
        guard !relieved.floated.isEmpty else { return nil }
        let moving = inspection.targets.filter { relieved.floated.contains($0.id) }
        guard !moving.isEmpty else { return nil }
        let ids = inspection.targets.map(\.id).filter { !relieved.floated.contains($0) }
        guard case .fits(let reduced) = Planner.fit(
            relieved.layout, in: area, constraints: constraints, options: options, maximums: knowledge.maximums(for: ids, workArea: area), focused: system.focusedWindowID()
        ) else { return nil }
        builder.floatAside(moving.map(\.id), reason: Self.overflowFloatReason, code: Self.overflowFloatCode, windows: moving)
        inspection = builder.inspection
        return (reduced, ids)
    }

    private func overflowSuffix(_ builder: ResultBuilder) -> String {
        let count = builder.inspection.excluded.filter { $0.code == Self.overflowFloatCode }.count
        guard count > 0 else { return "" }
        return Copy.sentenceSeparator + L(.arrangeOperationOverflowKeptFloating(windows: count))
    }

    /// Integration reports how many windows were added, not how many moved.
    private func completeMessage(tiled: Int, ids: [WindowID], note: String) -> String {
        let arranged = L(.arrangeOperationArranged(windows: tiled))
        guard kind == "integrate-waiting" || kind == "auto-integrate", let prior = priorLayout, prior.root != nil else {
            return arranged + note
        }
        let managed = Set(prior.windowIDs)
        let added = ids.filter { !managed.contains($0) }.count
        guard added > 0 else { return arranged + note }
        return L(.arrangeOperationAddedToLayout(windows: added)) + note
    }

    func unfitMessage(_ u: Unfit, targets: [ObservedWindow], area: CGRect) -> String {
        func name(_ id: WindowID) -> String {
            guard let app = targets.first(where: { $0.id == id })?.app else { return id.description }
            return displayName(app)
        }
        switch u.cause {
        case .splitOverflow(let axis, let required, let available, let members):
            let axisName = axis == .horizontal ? L(.arrangeOperationWidth) : L(.arrangeOperationHeight)
            let names = members.map(name).joined(separator: Copy.listSeparator)
            return L(.arrangeOperationSplitOverflow(windows: members.count, axisName, String(Int(required)), String(Int(available)), names))
        case .windowLargerThanArea(let id, let required, let available):
            return L(.arrangeOperationTheMinimumSizeOfIs(name(id), String(Int(required.width)), String(Int(required.height)), String(Int(available.width)), String(Int(available.height))))
        }
    }

    static func interruptMessage(_ reason: StopReason, builder: ResultBuilder) -> String {
        let applied = builder.reports.values.filter { $0.status == .verified || $0.status == .mismatch }.count
        let unapplied = builder.reports.values.filter { $0.status == .unapplied }.count
        let tail = L(.arrangeOperationInterruptedTail(applied, unapplied))
        switch reason {
        case .paused:
            return L(.arrangeOperationInterruptedBecauseArrangementWasPaused(tail))
        case .userInput:
            return L(.arrangeOperationInterruptedBecauseInputWasDetected(tail))
        case .spaceChanged:
            return L(.arrangeOperationInterruptedBecauseTheSpaceChanged(tail))
        case .permissionLost:
            return L(.arrangeOperationInterruptedBecauseThePermissionWas(AccessPane.name(), tail))
        case .cancelled:
            return L(.arrangeOperationOperationCanceled(tail))
        case .targetsChanged:
            return L(.arrangeOperationInterruptedBecauseTheWindowsChanged(tail))
        case .appUnresponsive:
            return L(.arrangeOperationInterruptedBecauseAnAppDidnt(tail))
        }
    }

    func partialMessage(builder: ResultBuilder, unresponsive: Set<String>) -> String {
        let total = builder.reports.count
        let mismatched = builder.reports.values.filter { $0.status == .mismatch }
        var reasons: [String] = []
        if !unresponsive.isEmpty {
            let apps = unresponsive.sorted().map(displayName).joined(separator: Copy.listSeparator)
            reasons.append(L(.arrangeOperationDidntRespondInTime(apps)))
        }
        if let unfit = builder.unfitNote { reasons.append(unfit) }
        let pushed = mismatched.filter { $0.noteKind?.isMinimumSize == true }
        if !pushed.isEmpty && builder.unfitNote == nil {
            let apps = pushed.map { displayName($0.app) }.joined(separator: Copy.listSeparator)
            reasons.append(L(.arrangeOperationBecameLargerThanRequestedBecause(apps)))
        }
        let head = L(.arrangeOperationPartiallyApplied(mismatched.count, windows: total))
        let why = reasons.isEmpty ? "" : L(.arrangeOperationReasons(reasons.joined(separator: Copy.sentenceSeparator), reasons: reasons.count))
        let remedy = builder.unfitNote == nil ? L(.arrangeOperationToFixThis) : ""
        let keep = builder.reports.values.contains(where: { $0.noteKind?.isRestore == true })
            ? L(.arrangeOperationUnreturnedStay) : L(.arrangeOperationMovedStay)
        return [head, why, remedy, keep].filter { !$0.isEmpty }.joined(separator: Copy.sentenceSeparator)
    }

    // MARK: - Shared copy

    static var changedAfterRequestMessage: String {
        L(.arrangeOperationChangedAfterRequestMessage)
    }
    static var closedDuringOperationNote: String { L(.arrangeOperationClosedDuringOperationNote) }
    static var closedBeforeCheckNote: String { L(.arrangeOperationClosedBeforeCheckNote) }
    static var closedWhileRestoringNote: String { L(.arrangeOperationClosedWhileRestoringNote) }
    static var notRestoredAfterStopNote: String {
        L(.arrangeOperationNotRestoredAfterStopNote)
    }
    static func unreadableSizeNote(_ why: String) -> String { L(.arrangeOperationUnreadableSizeNote(why)) }
}
