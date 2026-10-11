import AppKit
import Foundation
import MacSupport
import Operations

/// lzprobe output. With `--json` (`direct-switch-app`, `direct-move`), all diagnostics go to stderr and stdout gets only one final JSON document
/// (`SwitchSequence.Document`). Tests replace the destinations.
enum ProbeOutput {
    static var json = false
    static var writeOut: (String) -> Void = { print($0) }
    static var writeErr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
}

/// One diagnostic line: stderr with `--json`, otherwise stdout.
func diag(_ text: String) {
    ProbeOutput.json ? ProbeOutput.writeErr(text) : ProbeOutput.writeOut(text)
}

/// `--then` (a second operation with zero gap), `--json` (one document with the timeline), and `--settle` for `direct-switch-app` and `direct-move`.
/// The second operation starts on the same thread only when the first succeeds, with no wait. Each record (duration, Space right after, membership)
/// is taken right after its operation ends, before the next starts. The timeline origin is just before entering SpaceControl's public method,
/// so `accepted`, `queued`, and `prepared` share one time (candidates and plan are built beforehand).
enum SwitchSequence {
    enum Mode: String, CaseIterable {
        /// App activation (plus one jump and stepping through Spaces in between). Never tier 0.
        case app
        /// Tier 0 only (macOS "Switch to Desktop N").
        case hotkey
        /// Left/right stepping only.
        case stepping
    }

    /// Record of one operation, in ms. `startMs` from the sequence start, `callMs` the duration of this call.
    struct Record: Codable, Equatable {
        var label: String
        var ok: Bool
        var detail: String
        var startMs: Double
        var callMs: Double
        var fromSpace: UInt64?
        var toSpace: UInt64?
        var steps: Int?
        var wallMs: Double?
        /// Current Space read right after the operation (before the next).
        var activeAfter: UInt64?
        /// Membership of the carried window (moves only), read right after the operation.
        var membershipAfter: [UInt64]?
        var timeline: [TimelineEvent]
    }

    /// The single stdout document for `--json`.
    struct Document: Codable, Equatable {
        var command: String
        var settle: String
        var operations: [Record]
        /// The whole sequence (first operation's start to last operation's end), separate from each `callMs`.
        var sequenceMs: Double
        /// Whether the pass-through tap drained (best effort); nil before waiting.
        var drained: Bool?
        var ok: Bool
        /// Why it stopped before any operation (missing arguments or observations).
        var error: String?
    }

    /// Sequence clock (monotonic).
    final class Clock {
        private let clock = ContinuousClock()
        private let origin: ContinuousClock.Instant
        init() { origin = clock.now }
        var ms: Double {
            let d = clock.now - origin
            return ((Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) * 10).rounded() / 10
        }
    }

    /// `hotkey:3`, `stepping:2`, `app:4`, or just a number (same path as `mode`).
    static func parse(_ spec: String, default mode: Mode) -> (mode: Mode, index: Int)? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 1 { return Int(parts[0]).map { (mode, $0) } }
        guard let parsed = Mode(rawValue: parts[0]), let index = Int(parts[1]) else { return nil }
        return (parsed, index)
    }

    /// `--settle observed|fixed`: observed is the product default (the shortcut path returns on observed arrival); fixed is the old fixed wait before step 1 (for comparison).
    static func applySettle(_ settle: String?, to control: SpaceControl, command: String) {
        switch settle {
        case nil, "observed": control.settle = .observedArrival
        case "fixed": control.settle = .fixedWaits
        default: fail("--settle must be observed or fixed", command: command)
        }
        diag("settle: \(settle ?? "observed")")
    }

    /// A new timeline (lzprobe acceptance).
    static func timeline() -> OperationTimeline {
        let timeline = OperationTimeline()
        timeline.mark("queued")
        timeline.mark("prepared")
        return timeline
    }

    /// One switch, called on a thread standing in for the operations queue. `app` candidates come from the app list at this moment.
    static func run(_ mode: Mode, to index: Int, control: SpaceControl, system: MacWindowSystem, hop: Bool, sequence: Clock) -> Record {
        let label = "\(mode.rawValue):\(index)"
        let start = sequence.ms
        func record(ok: Bool, detail: String, result: SpaceControl.Result? = nil, timeline: [TimelineEvent] = []) -> Record {
            let call = sequence.ms - start
            return Record(label: label, ok: ok, detail: detail, startMs: start, callMs: call, fromSpace: result?.fromSpace, toSpace: result?.toSpace,
                          steps: result?.steps, wallMs: result?.wallMs, activeAfter: system.currentSpaceID(), membershipAfter: nil, timeline: timeline)
        }
        guard let home = system.currentSpaceID(), let dest = control.spaceID(atIndex: index) else {
            return record(ok: false, detail: "\(label): no such space or the active Space is unreadable")
        }
        switch mode {
        case .hotkey:
            let desktop = control.desktopNumber(of: dest)
            let read = desktop.map { control.desktopShortcut($0) }
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            guard case .usable(let shortcut)? = read, let dock, NSScreen.screens.count == 1, !SpaceOverview.dockReordersByRecentUse() else {
                return record(ok: false, detail: "\(label): tier 0 not eligible (desktop \(desktop.map(String.init) ?? "-") shortcut \(read.map { "\($0)" } ?? "-"))")
            }
            var events: [SpaceControl.HotkeyEvent] = []
            let plan = SpaceControl.HotkeyPlan(shortcut: shortcut, dockPID: dock, report: { events.append($0) })
            let timeline = timeline()
            let attempt = control.switchViaDesktopShortcut(spaceID: dest, plan: plan, source: home, timeline: timeline)
            timeline.mark("published")
            var detail = "\(label): tier 0: \(attempt) events \(events)"
            if case .failed(let f) = attempt { detail += "\n  detail: \(control.failureDetail(f) ?? "")" }
            if case .switched(let r) = attempt { return record(ok: true, detail: detail, result: r, timeline: timeline.events) }
            return record(ok: false, detail: detail, timeline: timeline.events)
        case .stepping, .app:
            let saved = control.direct
            if mode == .stepping { control.direct = nil }
            defer { control.direct = saved }
            var table: [UInt64: [SpaceControl.Candidate]] = [:]
            if mode == .app, let inventory = AppWindowInventory.take() {
                for space in control.orderedSpaces().map(\.id) where space != home {
                    table[space] = inventory.eligibleApps(on: space).map { .app($0.pid, bundleID: $0.bundleID) }
                }
            }
            let timeline = timeline()
            let plan = SpaceControl.SwitchPlan(source: home, windows: [:], apps: { table }, hopAllowed: mode == .app && hop, timeline: timeline)
            let outcome = control.switchTo(spaceID: dest, plan: plan)
            timeline.mark("published")
            switch outcome {
            case .success(let r):
                return record(ok: true, detail: "\(label): switched \(r.fromSpace) -> \(r.toSpace) steps=\(r.steps)", result: r, timeline: timeline.events)
            case .failure(let f):
                return record(ok: false, detail: "\(label): failed: \(f)\(control.failureDetail(f) ?? "")", timeline: timeline.events)
            }
        }
    }

    /// One human-readable line (stdout, or stderr with `--json`).
    static func describe(_ record: Record) -> String {
        var line = String(format: "%@ — call %.0f ms (from sequence start %.0f ms)", record.detail, record.callMs, record.startMs)
        if let wall = record.wallMs { line += String(format: " wall %.0f ms", wall) }
        line += " active \(record.activeAfter.map(String.init) ?? "-")"
        if let membership = record.membershipAfter { line += " membership \(membership)" }
        return line
    }

    /// After the drain: with `--json`, writes one document to stdout. Returns success for the exit code.
    @discardableResult
    static func emit(_ document: Document, drained: Bool?) -> Bool {
        var final = document
        final.drained = drained
        final.ok = document.ok && drained != false
        if ProbeOutput.json, let data = try? encoder.encode(final) {
            ProbeOutput.writeOut(String(decoding: data, as: UTF8.self))
        }
        return final.ok
    }

    /// Stops before any operation (exit code 2). With `--json`, writes one document with the reason.
    static func fail(_ message: String, command: String) -> Never {
        diag(message)
        emit(Document(command: command, settle: "", operations: [], sequenceMs: 0, drained: nil, ok: false, error: message), drained: nil)
        exit(2)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
