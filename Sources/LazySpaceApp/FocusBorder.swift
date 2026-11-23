import AppKit
import LayoutCore
import MacSupport
import Settings

/// A transparent window that draws a border along its own edge, placed over or around another window. Writes nothing to that
/// window and lets clicks through. The focus border and the window list's outline each own one, so they share the drawing and
/// the corner radius.
final class BorderOverlay {
    let window: NSWindow
    private let view = BorderView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
    }

    var width: CGFloat {
        get { view.width }
        set { view.width = newValue; view.needsDisplay = true }
    }

    var color: NSColor {
        get { view.color }
        set { view.color = newValue; view.needsDisplay = true }
    }

    var isVisible: Bool { window.isVisible }

    /// `frame` is the overlay's own frame in screen coordinates (bottom-left origin); the border is drawn just inside it.
    func show(frame: CGRect) {
        if window.frame != frame { window.setFrame(frame, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// The border drawn just outside `frame` (screen coordinates).
    func show(around frame: CGRect) {
        show(frame: Self.outset(frame, width: width))
    }

    static func outset(_ frame: CGRect, width: CGFloat) -> CGRect {
        frame.insetBy(dx: -width, dy: -width)
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }

    /// CGWindowList bounds (top-left origin, main display) in screen coordinates.
    static func screenFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private final class BorderView: NSView {
        var width: CGFloat = 3
        var color: NSColor = .systemBlue

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: width * 2, yRadius: width * 2)
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        }
    }
}

/// A border around the focused window (optional). Frames come from Coordinator's observation (CGWindowList bounds).
final class FocusBorder {
    private let overlay = BorderOverlay()
    private var style = Config.FocusBorder()

    func apply(_ style: Config.FocusBorder) {
        self.style = style
        overlay.width = CGFloat(style.width)
        if let (r, g, b, a) = style.rgba { overlay.color = NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        if !style.enabled { hide() }
    }

    /// frame is a CGWindowList bounds (top-left origin, main display). nil hides the border.
    func show(around frame: CGRect?) {
        guard style.enabled, let frame, let primary = NSScreen.screens.first else { hide(); return }
        overlay.show(around: BorderOverlay.screenFrame(frame, primaryHeight: primary.frame.height))
    }

    func hide() {
        overlay.hide()
    }
}

/// The window list's outline: a short border on the edge of the selected row's window, so the user can tell which window a
/// row is. It never raises, focuses, or activates anything. The frame is read once and not followed: the outline is gone before
/// a window that moves or closes would matter. No fade, so a second selection never races an animation.
final class WindowHighlight {
    static let shared = WindowHighlight()
    static let duration: TimeInterval = 0.8

    private let overlay = BorderOverlay()
    private var generation: UInt64 = 0

    init() {
        overlay.width = 3
        overlay.color = .controlAccentColor
    }

    /// Read now, since the window may have moved after the list was read. nil when it is not on screen, is fading closed
    /// (fainter than the census counts as visible), or has no size.
    static func frame(of record: CGWindowRecord?, primaryHeight: CGFloat) -> CGRect? {
        guard let record, record.onScreen, record.alpha >= WindowCensus.vanishingAlpha,
              record.bounds.width > 0, record.bounds.height > 0 else { return nil }
        return BorderOverlay.screenFrame(record.bounds, primaryHeight: primaryHeight)
    }

    /// The window's own frame, so the line lies inside its edge. LazySpace tiles edge to edge: a line just outside would fall
    /// off the screen, under the menu bar, or on the neighbor.
    static func overlayFrame(_ windowFrame: CGRect) -> CGRect {
        windowFrame
    }

    /// nil removes a shown outline at once.
    func outline(_ id: WindowID?) {
        generation &+= 1
        guard let id, let primary = NSScreen.screens.first,
              let frame = Self.frame(of: WindowList.record(CGWindowID(id.raw)), primaryHeight: primary.frame.height) else {
            hide()
            return
        }
        overlay.show(frame: Self.overlayFrame(frame))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    private func hide() {
        overlay.hide()
    }
}
