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
        case .unknown: return L("Space can't be determined", "所属する操作スペースを確認できない")
        case .other: return L("On another Space", "別の操作スペースにある")
        case .otherDisplay: return L("On a display without the menu bar", "メニューバーのないディスプレイにある")
        case .allSpaces: return L("Appears on all Spaces", "すべての操作スペースに表示されるウインドウ")
        case .current: break
        }
        switch w.kind {
        case .standard: return nil
        case .dialog: return L("Fixed-size window", "大きさが固定のウインドウ")
        case .sheet: return L("Sheet", "シート")
        case .palette: return L("Tool palette or floating panel", "ツールパレット・フローティングパネル")
        case .minimized: return L("Minimized", "最小化中")
        case .hiddenApp: return L("App is hidden", "非表示のアプリ")
        case .fullscreen: return L("Full screen or Split View", "フルスクリーンまたはSplit View")
        case .nonNormalLayer: return L("Not a standard window", "通常のウインドウではない")
        case .unknownRole: return L("Window type can't be determined", "ウインドウの種類を判定できない")
        }
    }
}
