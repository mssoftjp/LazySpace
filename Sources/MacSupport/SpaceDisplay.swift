import CoreGraphics
import Foundation

/// The display holding a standard Space. Writes to a Space other than the current one happen only when this is unambiguous.
public struct SpaceDisplay: Equatable {
    /// SkyLight's "Display Identifier".
    public var display: String
    public var workArea: CGRect
    /// Shown on its display now.
    public var shown: Bool

    public init(display: String, workArea: CGRect, shown: Bool) {
        self.display = display
        self.workArea = workArea
        self.shown = shown
    }

    /// The display, when exactly one display lists the Space and its type is a standard Space (0).
    /// nil when the type is unknown, the Space appears on several displays, or it is not found.
    public static func holding(_ space: UInt64, in displays: [SpaceObserver.ManagedDisplay]) -> SpaceObserver.ManagedDisplay? {
        let holders = displays.filter { $0.spaces.contains(space) }
        guard holders.count == 1, let display = holders.first,
              let index = display.spaces.firstIndex(of: space), display.spaceTypes.count == display.spaces.count,
              display.spaceTypes[index] == 0 else { return nil }
        return display
    }
}
