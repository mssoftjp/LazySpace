import CoreGraphics
import Foundation
import LayoutCore

/// Cheap observation for automatic arrangement: standard windows visible on the current Space and the front app.
public struct Census: Equatable {
    /// Window ID -> owner pid
    public var windows: [WindowID: Int32]
    public var frontmostPID: Int32?
    public var spaceID: UInt64?
    /// CGWindowList bounds (logical, top-left origin). Used to detect mouse edits.
    public var bounds: [WindowID: CGRect]
    /// The front app's frontmost window (from CGWindowList order, no AX). Used for the insertion point and focus history.
    public var frontWindow: WindowID?

    public init(windows: [WindowID: Int32], frontmostPID: Int32?, spaceID: UInt64?, bounds: [WindowID: CGRect] = [:], frontWindow: WindowID? = nil) {
        self.windows = windows
        self.frontmostPID = frontmostPID
        self.spaceID = spaceID
        self.bounds = bounds
        self.frontWindow = frontWindow
    }
}

public enum AutoAction: Equatable {
    /// Newly appeared windows. Once input is quiet, they join the layout whether or not their app is in front.
    /// beside: the managed window that was in front before they appeared; if any, they go next to it.
    case integrate([WindowID], beside: WindowID?)
    /// Windows in the layout disappeared; redistribute the rest within the existing structure.
    /// wasFront: a disappeared window was in front (focus may be left floating after it closes).
    case refitAfterRemoval([WindowID], wasFront: Bool)
    /// The Space changed; only reset the baseline.
    case rebase
}

/// Decisions on windows appearing and disappearing. No clocks, AX, or Spaces.
public enum AutoDecide {
    public struct Input: Equatable {
        public var previous: Census
        public var current: Census
        /// No user input for a while.
        public var inputQuiet: Bool
        public var paused: Bool
        /// Whether this Space has saved layout intent (otherwise it is unmanaged).
        public var hasLayout: Bool
        /// Windows in the layout intent.
        public var managed: Set<WindowID>

        public init(previous: Census, current: Census, inputQuiet: Bool, paused: Bool, hasLayout: Bool, managed: Set<WindowID>) {
            self.previous = previous
            self.current = current
            self.inputQuiet = inputQuiet
            self.paused = paused
            self.hasLayout = hasLayout
            self.managed = managed
        }
    }

    public struct Output: Equatable {
        public var actions: [AutoAction]
        /// New windows whose decision was deferred: kept out of the baseline so they are "new" again next time.
        public var deferredAdded: [WindowID]
        /// Disappeared windows whose decision was deferred: kept in the baseline so they are "gone" again next time.
        public var deferredRemoved: [WindowID]

        public init(actions: [AutoAction], deferredAdded: [WindowID] = [], deferredRemoved: [WindowID] = []) {
            self.actions = actions
            self.deferredAdded = deferredAdded
            self.deferredRemoved = deferredRemoved
        }
    }

    public static func decide(_ input: Input) -> Output {
        let prev = input.previous, cur = input.current
        if prev.spaceID != cur.spaceID { return Output(actions: [.rebase]) }

        let added = cur.windows.keys.filter { prev.windows[$0] == nil }.sorted()
        let removed = prev.windows.keys.filter { cur.windows[$0] == nil }.sorted()

        var actions: [AutoAction] = []
        var deferredAdded: [WindowID] = []
        var deferredRemoved: [WindowID] = []

        // While paused or on an unmanaged Space, cause no new writes; only keep tracking.
        guard !input.paused, input.hasLayout else { return Output(actions: []) }

        var integrate: [WindowID] = []
        for id in added {
            guard cur.windows[id] != nil else { continue }
            // A window the last automatic start or arrangement already placed is not new, even with a stale baseline.
            // Integrating it again would immediately put the same window through an empty redistribution.
            if input.managed.contains(id) { continue }
            // Background windows follow the same beside rule; only during input are they deferred until things are still.
            if !input.inputQuiet { deferredAdded.append(id); continue }
            integrate.append(id)
        }
        if !integrate.isEmpty {
            // Insertion point: beside the window that was in front before it appeared, if that window is in the layout.
            let anchor = prev.frontWindow.flatMap { input.managed.contains($0) && cur.windows[$0] != nil ? $0 : nil }
            actions.append(.integrate(integrate, beside: anchor))
        }

        let goneManaged = removed.filter { input.managed.contains($0) }
        if !goneManaged.isEmpty {
            let wasFront = prev.frontWindow.map { goneManaged.contains($0) } ?? false
            if input.inputQuiet { actions.append(.refitAfterRemoval(goneManaged, wasFront: wasFront)) }
            else { deferredRemoved.append(contentsOf: goneManaged) }
        }
        return Output(actions: actions, deferredAdded: deferredAdded, deferredRemoved: deferredRemoved)
    }
}
