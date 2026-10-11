import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// One arrangement of the current Space.
public final class ArrangeOperation {
    /// Reason given when a window that does not fit even at minimum size is taken out of the tree in place.
    public static var overflowFloatReason: String {
        L("Too large for the work area even at minimum size; kept in place as floating",
          "最小サイズでも作業領域に収まらないため、位置を保ってフローティングにしました")
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
                       message: L("The fixed-size windows could not be placed next to the arranged windows, so this change was not saved. LazySpace will try again.",
                                  "大きさが固定のウインドウを整列したウインドウと並べられなかったため、この変更は保存していません。あらためて試します。"),
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
        transform: Transform? = nil,
        transformFailure: String = L("This edit can't be performed.", "この編集は実行できません。"),
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
        self.transform = transform
        self.transformFailure = transformFailure
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

        progress?(L("Checking windows", "対象を確認しています"))
        let observeStart = clock.now
        let snapshot = system.snapshot(limitingTo: observedWindows)
        var inspection = TargetSelection.inspect(snapshot, now: startedAt, appRule: appRule, heldOut: heldOut.merging(heldOutAtExecution) { first, _ in first })
        if let allowedWindows {
            let deferred = inspection.targets.filter { !allowedWindows.contains($0.id) }
            inspection.targets.removeAll { !allowedWindows.contains($0.id) }
            let reason = L("Not part of this automatic arrangement; checked again next time", "この自動整列では除外。次の観測で判定します")
            inspection.excluded.append(contentsOf: deferred.map { Exclusion(window: $0, reason: reason) })
        }
        var builder = ResultBuilder(id: id, startedAt: startedAt, snapshot: snapshot, inspection: inspection, limits: limits, kind: kind)
        builder.timing.observeMs = (clock.now - observeStart).milliseconds
        let planStart = clock.now

        guard snapshot.trusted else {
            return builder.finish(
                outcome: .notPossible, stopReason: .permissionLost,
                message: L("LazySpace can't arrange windows without the \(AccessPane.name()) permission. Turn on LazySpace in System Settings › Privacy & Security › \(AccessPane.name()).",
                           "「\(AccessPane.name())」の許可がないため整列できません。システム設定 › プライバシーとセキュリティ › \(AccessPane.name())でLazySpaceをオンにしてください。"),
                finishedAt: now(), wallMs: elapsedMs())
        }
        guard snapshot.spaceObservationAvailable, snapshot.spaceID != nil else {
            return builder.finish(
                outcome: .notPossible, stopReason: nil,
                message: L("Windows were not arranged because the current Space can't be identified. Manual arrangement isn't available in this configuration.",
                           "現在の操作スペースを確認できないため整列しません。この構成では手動の整列を利用できません。"),
                finishedAt: now(), wallMs: elapsedMs())
        }
        if let reason = gate(snapshot: snapshot) {
            return builder.finish(
                outcome: .notPossible, stopReason: reason,
                message: Self.changedAfterRequestMessage,
                finishedAt: now(), wallMs: elapsedMs())
        }
        guard !inspection.targets.isEmpty else {
            // Even with no tiles, region changes are committed (operations that only place strip dialogs or only remove the strip),
            // and saved windows missing from a complete observation are removed (closed, or confirmed minimized or on another Space).
            // When the full window list could not be read, invisible windows are not treated as closed (an emptied layout is not committed).
            let prior = priorLayout ?? Layout(root: nil)
            let seen = Set(snapshot.windows.filter { $0.kind != .minimized && $0.membership != .other }.map(\.id))
            let gone = Set(prior.windowIDs).subtracting(seen)
            if appliesRegion || !gone.isEmpty, snapshot.unobservedApps.isEmpty, snapshot.windowListAvailable {
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
                return builder.finish(outcome: .complete, stopReason: nil,
                                      message: note.isEmpty ? L("No windows to arrange.", "整列するウインドウがありません。") : note,
                                      finishedAt: now(), wallMs: elapsedMs())
            }
            let apps = snapshot.unobservedApps.map(displayName).joined(separator: L(", ", "、"))
            let extra = snapshot.unobservedApps.isEmpty ? "" : L(" (\(apps) did not return a window list)", "（\(apps)はウインドウの一覧を返しませんでした）")
            return builder.finish(
                outcome: .nothingToDo, stopReason: snapshot.unobservedApps.isEmpty ? nil : .appUnresponsive,
                message: L("No windows to arrange\(extra). See the window list for excluded windows and reasons.",
                           "整列するウインドウがありません\(extra)。除外されたウインドウと理由は一覧で確認してください。"),
                finishedAt: now(), wallMs: elapsedMs())
        }
        // If none of the integration triggers (layer-0 windows seen in CGWindowList) is a standard window, this operation has no basis.
        // Transient windows apps show during full-screen transitions land here. Redistributing existing windows is left to refit for vanished windows.
        // If an app did not respond, its window may simply have been unobservable; automatic retries count this as a failure.
        if !adding.isEmpty, !inspection.targets.contains(where: { adding.contains($0.id) }) {
            return builder.finish(
                outcome: .nothingToDo, stopReason: snapshot.unobservedApps.isEmpty ? nil : .appUnresponsive,
                message: L("The window to add isn't eligible (it's temporary, or its type can't be determined). See the window list for excluded windows and reasons.",
                           "追加するウインドウは整列対象ではありません（一時的なウインドウ、または種類を判定できないウインドウ）。除外されたウインドウと理由は一覧で確認してください。"),
                finishedAt: now(), wallMs: elapsedMs())
        }

        progress?(L("Calculating layout", "配置を計算しています"))
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
                builder.markAllUnapplied(note: L("Edit not possible", "編集できません"))
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
                    let names = moving.map { displayName($0.app) }.joined(separator: L(", ", "、"))
                    return builder.finish(
                        outcome: .complete, stopReason: nil,
                        message: L("\(names) didn't fit even at minimum size and \(moving.count == 1 ? "was" : "were") kept in place as floating.",
                                   "\(names)は最小サイズでも収まらないため、位置を保ってフローティングにしました。"),
                        finishedAt: now(), wallMs: elapsedMs())
                }
            }
        }
        var plan: Plan
        switch planOutcome {
        case .fits(let p): plan = p
        case .unfit(let u):
            builder.markAllUnapplied(note: L("Not possible; found before moving any window", "配置を変える前に実行できないと判明"))
            let prefix = kind.hasPrefix("edit:") ? L("The windows don't fit with this edit. ", "この編集ではウインドウが収まりません。") : ""
            return builder.finish(
                outcome: .notPossible, stopReason: nil,
                message: prefix + unfitMessage(u, targets: inspection.targets, area: snapshot.workArea),
                finishedAt: now(), wallMs: elapsedMs())
        }
        baseLayout = plan.layout
        // Zoom: only the target window fills the work area; the others leave the targets and keep their positions.
        if let zoomed, ids.contains(zoomed) {
            let others = inspection.targets.filter { $0.id != zoomed }
            inspection.targets.removeAll { $0.id != zoomed }
            inspection.excluded.append(contentsOf: others.map { Exclusion(window: $0, reason: L("Kept in place while another window is zoomed", "ズーム中のため位置を保持")) })
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
                builder.markAllUnapplied(note: L("Stopped because the plan would move a protected window", "保護中のウインドウを動かす計画のため中止"))
            } else if let reason = restoreOriginalFrames(&builder) {
                builder.markPendingUnapplied()
                return builder.finish(outcome: .interrupted, stopReason: reason, message: Self.interruptMessage(reason, builder: builder), finishedAt: now(), wallMs: elapsedMs())
            } else {
                builder.markPendingUnapplied()
            }
            return builder.finish(outcome: builder.issued == 0 || builder.rolledBack ? .notPossible : .partial, stopReason: nil,
                                  message: L("The new window can't join the layout without moving the \(target.app) window you're using, so it stays in place and waits.",
                                             "\(target.app)のウインドウ（操作中）を動かさずには配置に入れられないため、新しいウインドウは位置を保って待機させます。"),
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
                builder.markAllUnapplied(note: L("Not moved because the fixed-size windows could not be placed", "大きさが固定のウインドウを置けなかったため動かしていません"))
                return placementAbortedResult(&builder, started: elapsedMs)
            case .done: break
            }
        }

        // MARK: Applying and reading back
        var retries = 0
        var didRedistribute = false
        var repeatedPlan = false
        var didRelieve = false
        var stop: StopReason?
        var unresponsiveApps = Set<String>()

        var pullbacks: [WindowID: (requested: CGSize, actual: CGSize)] = [:]
        var applyIteration = 0

        builder.timing.planMs = (clock.now - planStart).milliseconds
        applyLoop: while true {
            progress?(retries == 0 ? L("Applying layout", "適用しています") : L("Recalculated to match actual sizes", "実寸に合わせて再計算しました"))
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
                    report.setNote(L("Maximum size \(Int(request.width))×\(Int(request.height)); doesn't fill its area",
                                     "最大サイズ\(Int(request.width))×\(Int(request.height))のため枠を埋めない"), .maximumSizeCap)
                }
                if report.status == .gone { builder.set(report); continue }
                if unresponsiveApps.contains(target.app) {
                    if report.issued == 0 {
                        report.status = .unapplied
                        report.setNote(L("Not sent because the same app didn't respond", "同じアプリが応答しなかったため発行しません"))
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
                    report.setNote(L("Couldn't read the window's frame: \(why)", "読取失敗: \(why)"))
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
                    report.setNote(L("macOS rejected the request: \(why)", "OSが要求を拒否: \(why)"))
                case .timedOut:
                    report.status = .mismatch
                    report.setNote(L("The app didn't respond in time", "アプリが期限内に応答しなかった"))
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
            progress?(L("Checking actual sizes", "実寸を確認しています"))
            var mismatched: [WindowID] = []
            var learned = false
            var needsRedistribute = false
            var repeatPlan = false
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
                            report.setNote(L("Measured minimum size \(Int(actual.width))×\(Int(actual.height)); matched after recalculation",
                                             "最小サイズ\(Int(actual.width))×\(Int(actual.height))を実測し、再計算で一致"), .minimumSizeMeasured)
                        }
                    } else if timedOut.contains(target.id) || unresponsiveApps.contains(target.app) {
                        // The request was not processed, so the actual size is no evidence of constraints.
                        report.status = .mismatch
                        report.setNote(L("The app didn't respond in time (actual size \(Int(actual.width))×\(Int(actual.height)))",
                                         "アプリが期限内に応答しなかった（実寸\(Int(actual.width))×\(Int(actual.height))）"))
                        mismatched.append(target.id)
                    } else {
                        report.status = .mismatch
                        mismatched.append(target.id)
                        let pushed = learnable && (actual.width > request.width + limits.tolerance || actual.height > request.height + limits.tolerance)
                        let pulled = learnable && (actual.width < request.width - limits.tolerance || actual.height < request.height - limits.tolerance)
                        if pushed {
                            learned = true
                            knowledge.recordPushback(id: target.id, requested: request, actual: actual, spaceID: snapshot.spaceID, workArea: snapshot.workArea, tolerance: limits.tolerance, bundle: target.app, subrole: target.subrole)
                            report.setNote(L("Larger than requested because of its minimum size (\(Int(actual.width))×\(Int(actual.height)))",
                                             "最小サイズにより実寸が要求より大きい（\(Int(actual.width))×\(Int(actual.height))）"), .minimumSizePushback)
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
                            let smaller = L("The app made it smaller than requested (\(Int(actual.width))×\(Int(actual.height)))",
                                            "アプリが要求より小さく補正した（\(Int(actual.width))×\(Int(actual.height))）")
                            report.setNote((pushed ? report.note! + L(". ", "。") : "") + smaller, pushed ? .minimumSizePushback : nil)
                            // When a fixed size has been confirmed repeatedly and the position within the frame also matches, no further write is needed.
                            if let maximum = knowledge.maximums(for: [target.id], workArea: snapshot.workArea)[target.id] {
                                let adjusted = Self.clamp(request, maximum: maximum)
                                if actual.matches(adjusted, tolerance: limits.tolerance) {
                                    report.planned = adjusted
                                    report.status = .verified
                                    report.setNote(L("Maximum size \(Int(adjusted.width))×\(Int(adjusted.height)) confirmed by repeated measurement; position within its area matches",
                                                     "最大サイズ\(Int(adjusted.width))×\(Int(adjusted.height))を繰り返し実測。枠内の位置と一致"), .maximumSizeConfirmed)
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
                            report.note = report.note ?? L("Position doesn't match the request", "位置が要求と一致しない")
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
            let allowRepeat = repeatPlan && !repeatedPlan && !allowRetry
            let allowRedistribute = needsRedistribute && !didRedistribute
            guard allowRetry || allowRepeat || allowRedistribute else { break applyLoop }
            if allowRedistribute { didRedistribute = true }
            else if allowRepeat { repeatedPlan = true; continue }

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
            progress?(L("Returning windows to their original positions because they don't fit", "収まらないため元の位置に戻しています"))
            if let reason = restoreOriginalFrames(&builder) {
                stop = reason
            }
        }
        let finishedAt = now()

        if let stop {
            // Stop handling: no new requests, but windows already sent are read back and confirmed.
            progress?(L("Stopping: checking requests already sent", "停止処理中: 発行済みの操作を確認しています"))
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
                        report.note = report.note ?? L("Didn't match the request when interrupted (\(Int(actual.width))×\(Int(actual.height)))",
                                                       "中断時点で要求と一致していない（\(Int(actual.width))×\(Int(actual.height))）")
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
            let apps = snapshot.unobservedApps.map(displayName).joined(separator: L(", ", "、"))
            let message = L("Arranged \(windowCount(statuses.count)), but \(apps) didn't return a window list in time, so the set of windows couldn't be confirmed. Arrange again once that app responds.",
                            "\(statuses.count)つのウインドウを整列しましたが、\(apps)がウインドウの一覧を期限内に返さなかったため対象を確定できませんでした。そのアプリが応答するようになってから再度整列してください。")
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
            let message = L("\(goneCount == 1 ? "1 window was" : "\(goneCount) windows were") closed during arrangement. The rest are arranged. Arrange again if needed.",
                            "整列中に\(goneCount)つのウインドウが閉じられました。残りは整列済みです。必要なら再度整列してください。")
            return builder.finish(outcome: .partial, stopReason: .targetsChanged, message: message, finishedAt: finishedAt, wallMs: elapsedMs())
        }
        if builder.rolledBack, let unfit = builder.unfitNote {
            return builder.finish(outcome: .notPossible, stopReason: nil,
                                  message: unfit + L(" Windows were returned to where they were before.", "動かす前の位置に戻しました。"),
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
            return L("\(unplaced == 1 ? "1 fixed-size window" : "\(unplaced) fixed-size windows") could not be placed next to the arranged windows.", "大きさが固定のウインドウ\(unplaced)つを整列したウインドウと並べられませんでした。")
        }
        return placed == 0 ? "" : L("Placed \(placed == 1 ? "1 fixed-size window" : "\(placed) fixed-size windows") next to the arranged windows.", "大きさが固定のウインドウ\(placed)つを整列したウインドウと並べました。")
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
                        report.setNote(L("Returned to its original position because it didn't fit", "収まらないため元の位置に戻した"), .restoredOriginal)
                        restored += 1
                    } else {
                        report.status = .mismatch
                        report.setNote(L("Couldn't return to its original position (\(Int(actual.width))×\(Int(actual.height)))",
                                         "元の位置に戻せなかった（\(Int(actual.width))×\(Int(actual.height))）"), .restoreFailed)
                        failed += 1
                    }
                case .gone:
                    report.status = .gone
                    report.setNote(Self.closedWhileRestoringNote)
                    failed += 1
                case .failed(let why):
                    report.status = .mismatch
                    report.setNote(L("Couldn't read the actual size after returning it: \(why)", "戻したあと実寸を読めなかった: \(why)"))
                    failed += 1
                }
            case .gone:
                report.status = .gone
                report.setNote(Self.closedWhileRestoringNote)
                failed += 1
            case .rejected(let why):
                report.status = .mismatch
                report.setNote(L("Moving it back to its original position was rejected: \(why)", "元の位置への書き込みを拒否された: \(why)"), .restoreFailed)
                failed += 1
            case .timedOut:
                report.status = .mismatch
                report.setNote(L("No response while returning it to its original position", "元の位置へ戻す途中で応答がなかった"), .restoreFailed)
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
        return Copy.sentenceSeparator + L("\(windowCount(count)) didn't fit even at minimum size and \(count == 1 ? "was" : "were") kept in place as floating.",
                                          "\(count)つのウインドウは最小サイズでも収まらないため、位置を保ってフローティングにしました。")
    }

    /// Integration reports how many windows were added, not how many moved.
    private func completeMessage(tiled: Int, ids: [WindowID], note: String) -> String {
        let arranged = L("Arranged \(windowCount(tiled)).", "\(tiled)つのウインドウを整列しました。")
        guard kind == "integrate-waiting" || kind == "auto-integrate", let prior = priorLayout, prior.root != nil else {
            return arranged + note
        }
        let managed = Set(prior.windowIDs)
        let added = ids.filter { !managed.contains($0) }.count
        guard added > 0 else { return arranged + note }
        return L("Added \(windowCount(added)) to the layout.", "\(added)つのウインドウをレイアウトに加えました。") + note
    }

    func unfitMessage(_ u: Unfit, targets: [ObservedWindow], area: CGRect) -> String {
        func name(_ id: WindowID) -> String {
            guard let app = targets.first(where: { $0.id == id })?.app else { return id.description }
            return displayName(app)
        }
        switch u.cause {
        case .splitOverflow(let axis, let required, let available, let members):
            let axisName = axis == .horizontal ? L("width", "幅") : L("height", "高さ")
            let names = members.map(name).joined(separator: ", ")
            let subject = members.count == 1 ? "1 window doesn't" : "\(members.count) windows don't"
            return L("\(subject) fit in the work area (\(axisName) needed: \(Int(required)); available: \(Int(available))). Close or exclude a window, then arrange again. Windows: \(names).",
                     "\(members.count)つのウインドウが作業領域に収まりません（必要な\(axisName)\(Int(required)) > 利用可能\(Int(available))）。ウインドウを閉じるか除外してから、再度整列してください。対象: \(names)。")
        case .windowLargerThanArea(let id, let required, let available):
            return L("The minimum size of \(name(id)) (\(Int(required.width))×\(Int(required.height))) is larger than the work area (\(Int(available.width))×\(Int(available.height))). Exclude that window.",
                     "\(name(id))の最小サイズ\(Int(required.width))×\(Int(required.height))が領域\(Int(available.width))×\(Int(available.height))を超えています。そのウインドウを除外してください。")
        }
    }

    static func interruptMessage(_ reason: StopReason, builder: ResultBuilder) -> String {
        let applied = builder.reports.values.filter { $0.status == .verified || $0.status == .mismatch }.count
        let unapplied = builder.reports.values.filter { $0.status == .unapplied }.count
        let tail = L(" (\(applied) checked, \(unapplied) not applied; windows stay where they are now)",
                     "（\(applied)つは確認済み、\(unapplied)つは未適用。位置は現在のまま保ちます）")
        switch reason {
        case .paused:
            return L("Interrupted because arrangement was paused\(tail). Resume, then arrange again.",
                     "一時停止したため中断しました\(tail)。再開してから再度整列してください。")
        case .userInput:
            return L("Interrupted because input was detected\(tail). Arrange again once input settles.",
                     "操作中の入力を検知したため中断しました\(tail)。操作が落ち着いてから再度整列してください。")
        case .spaceChanged:
            return L("Interrupted because the Space changed\(tail). Return to the original Space, then arrange again.",
                     "操作スペースが切り替わったため中断しました\(tail)。元の操作スペースに戻ってから再度整列してください。")
        case .permissionLost:
            return L("Interrupted because the \(AccessPane.name()) permission was lost\(tail). Check it in System Settings.",
                     "「\(AccessPane.name())」の許可が失われたため中断しました\(tail)。システム設定で許可を確認してください。")
        case .cancelled:
            return L("Operation canceled\(tail).", "操作を取り消しました\(tail)。")
        case .targetsChanged:
            return L("Interrupted because the windows changed\(tail). Arrange again.",
                     "対象のウインドウが変わったため中断しました\(tail)。再度整列してください。")
        case .appUnresponsive:
            return L("Interrupted because an app didn't respond\(tail).", "アプリが応答しないため中断しました\(tail)。")
        }
    }

    func partialMessage(builder: ResultBuilder, unresponsive: Set<String>) -> String {
        let total = builder.reports.count
        let mismatched = builder.reports.values.filter { $0.status == .mismatch }
        var reasons: [String] = []
        if !unresponsive.isEmpty {
            let apps = unresponsive.sorted().map(displayName).joined(separator: ", ")
            reasons.append(L("\(apps) didn't respond in time.", "\(apps)が期限内に応答しませんでした。"))
        }
        if let unfit = builder.unfitNote { reasons.append(unfit) }
        let pushed = mismatched.filter { $0.noteKind?.isMinimumSize == true }
        if !pushed.isEmpty && builder.unfitNote == nil {
            let apps = pushed.map { displayName($0.app) }.joined(separator: ", ")
            reasons.append(L("\(apps) became larger than requested because of minimum size.", "\(apps)が最小サイズのため要求より大きくなりました。"))
        }
        let head = L("Partially applied: \(mismatched.count) of \(windowCount(total)) did not match the layout.",
                     "\(total)つのうち\(mismatched.count)つのウインドウがレイアウトどおりになりませんでした。")
        let why = reasons.isEmpty ? "" : L(reasons.count == 1 ? " Reason: " : " Reasons: ", "理由: ") + reasons.joined(separator: Copy.sentenceSeparator)
        let remedy = builder.unfitNote == nil
            ? L(" To fix this, close or exclude that window, then arrange again.", "対処: そのウインドウを閉じるか除外して、再度整列してください。")
            : ""
        let keep = builder.reports.values.contains(where: { $0.noteKind?.isRestore == true })
            ? L(" Windows that couldn't be returned stay where they are now.", "戻せなかったウインドウは現在の位置のままです。")
            : L(" Windows that moved stay where they are.", "動いたウインドウはそのまま保ちます。")
        return head + why + remedy + keep
    }

    // MARK: - Shared copy

    static var changedAfterRequestMessage: String {
        L("Windows were not arranged because pause, input, or the Space changed after the request. Try again if needed.",
          "受付後に一時停止・入力・操作スペースの状態が変わったため整列しません。必要なら改めて操作してください。")
    }
    static var closedDuringOperationNote: String { L("Closed during the operation", "操作中に閉じられた") }
    static var closedBeforeCheckNote: String { L("Closed before it could be checked", "確認時に閉じられていた") }
    static var closedWhileRestoringNote: String { L("Closed while being returned to its original position", "戻す途中で閉じられた") }
    static var notRestoredAfterStopNote: String {
        L("Not returned to its original position because the operation stopped", "停止したため元の位置に戻していません")
    }
    static func unreadableSizeNote(_ why: String) -> String { L("Couldn't read the actual size: \(why)", "実寸を読めなかった: \(why)") }
}
