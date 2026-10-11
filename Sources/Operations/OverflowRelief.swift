import CoreGraphics
import Foundation
import LayoutCore

/// When the minimum sizes add up to more than the work area, removes windows from the tree until they fit:
/// newly added windows first, then from the end of the order.
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
        var layout = layout
        var floated: [WindowID] = []
        let limit = layout.windowIDs.count + 1
        for _ in 0..<max(limit, 1) {
            switch Planner.fit(layout, in: area, constraints: constraints, options: options, maximums: maximums, focused: focused) {
            case .fits:
                return (layout, floated)
            case .unfit(let unfit):
                let offending = Set(unfit.offending)
                let present = layout.windowIDs
                let victim = dropFirst.first { offending.contains($0) && present.contains($0) }
                    ?? present.reversed().first { offending.contains($0) }
                guard let victim else { return (layout, floated) }
                floated.append(victim)
                layout = layout.removing([victim])
                if layout.root == nil { return (layout, floated) }
            }
        }
        return (layout, floated)
    }
}
