import Copy
import Foundation
import LayoutCore

// MARK: - Result assembly

struct ResultBuilder {
    let id: String
    let startedAt: Date
    let snapshot: Snapshot
    var inspection: Inspection
    let limits: OperationLimits
    var reports: [WindowID: TargetReport] = [:]
    var order: [WindowID]
    var issued = 0
    var retries = 0
    var verified = false
    var maxWriteMs = 0.0
    var rows = 0
    var timing = OperationTiming()
    var unfitNote: String?
    var rolledBack = false
    let kind: String

    init(id: String, startedAt: Date, snapshot: Snapshot, inspection: Inspection, limits: OperationLimits, kind: String = "arrange") {
        self.kind = kind
        self.id = id
        self.startedAt = startedAt
        self.snapshot = snapshot
        self.inspection = inspection
        self.limits = limits
        self.order = inspection.targets.map(\.id)
        for t in inspection.targets {
            reports[t.id] = TargetReport(id: t.id, app: t.app, before: t.frame, planned: nil, after: nil, status: .unapplied, issued: 0, note: nil)
        }
    }

    func report(for id: WindowID) -> TargetReport { reports[id]! }
    mutating func set(_ r: TargetReport) { reports[r.id] = r }

    /// Drops windows that will not be written from the targets, keeping only the exclusion reason. Frames already written stay.
    mutating func floatAside(_ ids: [WindowID], reason: String, code: Exclusion.Code? = nil, windows: [ObservedWindow]) {
        let dropping = Set(ids)
        inspection.targets.removeAll { dropping.contains($0.id) }
        let already = Set(inspection.excluded.map(\.window.id))
        inspection.excluded.append(contentsOf: windows.filter { dropping.contains($0.id) && !already.contains($0.id) }.map { Exclusion(window: $0, reason: reason, code: code) })
        order.removeAll { dropping.contains($0) }
        for id in dropping { reports[id] = nil }
    }

    mutating func markAllUnapplied(note: String) {
        for id in order { reports[id]?.status = .unapplied; reports[id]?.setNote(note) }
    }

    /// On interruption: marks targets not yet sent as unapplied.
    mutating func markPendingUnapplied() {
        for id in order {
            guard var r = reports[id] else { continue }
            if r.issued == 0 && r.status != .gone && r.status != .unchanged {
                r.status = .unapplied
                r.note = r.note ?? L("Not sent because the operation was interrupted", "中断のため未発行")
                reports[id] = r
            }
        }
    }

    func finish(outcome: Outcome, stopReason: StopReason?, message: String, finishedAt: Date, wallMs: Double) -> OperationResult {
        OperationResult(
            id: id, kind: kind, startedAt: startedAt, finishedAt: finishedAt,
            outcome: outcome, stopReason: stopReason, spaceID: snapshot.spaceID, workArea: snapshot.workArea,
            targets: order.compactMap { reports[$0] }, excluded: inspection.excluded,
            issued: issued, retries: retries, verified: verified, maxWriteMs: maxWriteMs, wallMs: wallMs,
            message: message, tolerance: limits.tolerance, rows: rows, unobservedApps: snapshot.unobservedApps, timing: timing)
    }
}

extension TargetReport {
    /// Replaces the note and its kind together, so the old kind does not linger.
    mutating func setNote(_ text: String, _ kind: NoteKind? = nil) {
        note = text
        noteKind = kind
    }
}

func windowCount(_ n: Int) -> String { n == 1 ? "1 window" : "\(n) windows" }
