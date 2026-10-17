import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// Chooses the targets of an explicit arrangement: standard windows whose membership is confirmed.
public enum TargetSelection {
    public static func inspect(_ snapshot: Snapshot, now: Date = Date(), appRule: ((ObservedWindow) -> String?)? = nil, heldOut: [WindowID: String] = [:]) -> Inspection {
        var targets: [ObservedWindow] = []
        var excluded: [Exclusion] = []
        for w in snapshot.windows {
            if let reason = exclusionReason(w) ?? appRule?(w) ?? heldOut[w.id] {
                excluded.append(Exclusion(window: w, reason: reason))
            } else {
                targets.append(w)
            }
        }
        return Inspection(snapshot: snapshot, targets: readingOrder(targets), excluded: excluded, takenAt: now)
    }

    /// A tolerance inside the comparator breaks transitivity. Instead, windows within 40 pt of a row's first window
    /// join that row, then sort by row, X, stack order, and ID. This also keeps staircased windows from chaining rows.
    private static func readingOrder(_ windows: [ObservedWindow]) -> [ObservedWindow] {
        var rowOf: [CGFloat: Int] = [:]
        var row = -1
        var topOfRow = -CGFloat.infinity
        for top in Set(windows.map(\.frame.minY)).sorted() {
            if top - topOfRow > 40 { row += 1; topOfRow = top }
            rowOf[top] = row
        }
        return windows.sorted { a, b in
            let aRow = rowOf[a.frame.minY]!, bRow = rowOf[b.frame.minY]!
            if aRow != bRow { return aRow < bRow }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            if a.stackOrder != b.stackOrder { return a.stackOrder < b.stackOrder }
            return a.id < b.id
        }
    }

    public static func exclusionReason(_ w: ObservedWindow) -> String? {
        switch w.membership {
        case .unknown: return L(.targetSelectionSpaceCantBeDetermined)
        case .other: return L(.targetSelectionOnAnotherSpace)
        case .otherDisplay: return L(.targetSelectionOnADisplayWithoutThe)
        case .allSpaces: return L(.targetSelectionAppearsOnAllSpaces)
        case .current: break
        }
        switch w.kind {
        case .standard: return nil
        case .dialog: return L(.targetSelectionFixedSizeWindow)
        case .sheet: return L(.targetSelectionSheet)
        case .palette: return L(.targetSelectionToolPaletteOrFloatingPanel)
        case .minimized: return L(.targetSelectionMinimized)
        case .hiddenApp: return L(.targetSelectionAppIsHidden)
        case .fullscreen: return L(.targetSelectionFullScreenOrSplitView)
        case .nonNormalLayer: return L(.targetSelectionNotAStandardWindow)
        case .unknownRole: return L(.targetSelectionWindowTypeCantBeDetermined)
        }
    }
}
