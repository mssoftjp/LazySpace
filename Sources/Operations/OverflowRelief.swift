import CoreGraphics
import Foundation
import LayoutCore

/// When the minimum sizes add up to more than the work area, removes windows from the tree until they fit:
/// newly added windows first, then from the end of the order. Then puts back each removed window that fits once the others are out.
enum OverflowRelief {
    static func relieve(
        _ layout: Layout,
        in area: CGRect,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions,
        maximums: [WindowID: CGSize],
        preferring dropFirst: [WindowID],
        focused: WindowID? = nil
    ) -> (layout: Layout, floated: [WindowID]) {
        let original = layout
        var layout = layout
        var floated: [WindowID] = []
        let limit = layout.windowIDs.count + 1
        for _ in 0..<max(limit, 1) {
            switch Planner.fit(layout, in: area, constraints: constraints, options: options, maximums: maximums, focused: focused) {
            case .fits:
                return putBack(floated, into: original, in: area, constraints: constraints, options: options, maximums: maximums, focused: focused)
            case .unfit(let unfit):
                let offending = Set(unfit.offending)
                let present = layout.windowIDs
                let victim = dropFirst.first { offending.contains($0) && present.contains($0) }
                    ?? present.reversed().first { offending.contains($0) }
                guard let victim else { return (layout, floated) }
                floated.append(victim)
                layout = layout.removing([victim])
                if layout.root == nil {
                    return putBack(floated, into: original, in: area, constraints: constraints, options: options, maximums: maximums, focused: focused)
                }
            }
        }
        return (layout, floated)
    }

    /// A window removed early can fit once a later one is out: a small window added before two that cannot share a row was removed first,
    /// although only the two are in the way. Every float is saved, so an unneeded one would keep the window out for good.
    /// Tries the last removed first, so when only one of several fits, the one relief would remove first stays out.
    private static func putBack(
        _ floated: [WindowID],
        into original: Layout,
        in area: CGRect,
        constraints: [WindowID: SizeKnowledge],
        options: PlannerOptions,
        maximums: [WindowID: CGSize],
        focused: WindowID?
    ) -> (layout: Layout, floated: [WindowID]) {
        var out = Set(floated)
        for id in floated.reversed() {
            out.remove(id)
            if case .fits = Planner.fit(original.removing(out), in: area, constraints: constraints, options: options, maximums: maximums, focused: focused) { continue }
            out.insert(id)
        }
        let kept = floated.filter { out.contains($0) }
        return (original.removing(Set(kept)), kept)
    }
}
