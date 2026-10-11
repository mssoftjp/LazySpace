import AppKit
import Foundation

/// Display geometry in the top-left-origin logical coordinates used by AX and CGWindowList.
public enum Screens {
    public struct Info: Codable, Equatable {
        public var name: String
        public var frame: CGRect
        public var workArea: CGRect
        public var scale: CGFloat
        public var isMain: Bool

        public init(name: String, frame: CGRect, workArea: CGRect, scale: CGFloat, isMain: Bool) {
            self.name = name
            self.frame = frame
            self.workArea = workArea
            self.scale = scale
            self.isMain = isMain
        }
    }

    /// Converts a Cocoa (bottom-left origin) rect to top-left origin.
    public static func topLeft(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let y = primary.frame.height - rect.maxY
        return CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
    }

    public static func all() -> [Info] {
        NSScreen.screens.map { s in
            Info(name: s.localizedName, frame: topLeft(s.frame), workArea: topLeft(s.visibleFrame), scale: s.backingScaleFactor, isMain: s == NSScreen.main)
        }
    }

    /// Work area (without menu bar and Dock) of the display with the menu bar; the default when the display is unknown.
    /// Not `NSScreen.main`, which is the screen with the key window.
    public static func primaryWorkArea() -> CGRect {
        guard let s = NSScreen.screens.first else { return .zero }
        return topLeft(s.visibleFrame)
    }

    /// Work area of the display matching SkyLight's "Display Identifier" (the CGDisplay UUID string), or the main display.
    /// Coordinates share one top-left origin across displays, so Planner can use them directly.
    public static func workArea(displayUUID: String?) -> CGRect {
        guard let displayUUID, let s = NSScreen.screens.first(where: { uuid(of: $0) == displayUUID }) else { return primaryWorkArea() }
        return topLeft(s.visibleFrame)
    }

    /// Work area of the display with this UUID, or nil (never the main display instead).
    public static func knownWorkArea(displayUUID: String) -> CGRect? {
        guard let s = NSScreen.screens.first(where: { uuid(of: $0) == displayUUID }) else { return nil }
        return topLeft(s.visibleFrame)
    }

    public static func uuid(of screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
}
