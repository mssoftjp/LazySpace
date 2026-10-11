import AppKit
import Settings

/// A transparent window that draws a border around the focused window (optional).
/// Writes nothing to the window and lets clicks through. Frames come from Coordinator's observation (CGWindowList bounds).
final class FocusBorder {
    private let window: NSWindow
    private let view = BorderView()
    private var style = Config.FocusBorder()

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

    func apply(_ style: Config.FocusBorder) {
        self.style = style
        view.width = CGFloat(style.width)
        if let (r, g, b, a) = style.rgba { view.color = NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        view.needsDisplay = true
        if !style.enabled { hide() }
    }

    /// frame is a CGWindowList bounds (top-left origin, main display). nil hides the border.
    func show(around frame: CGRect?) {
        guard style.enabled, let frame, let primary = NSScreen.screens.first else { hide(); return }
        let w = CGFloat(style.width)
        let flipped = CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
        let outer = flipped.insetBy(dx: -w, dy: -w)
        if window.frame != outer { window.setFrame(outer, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
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
