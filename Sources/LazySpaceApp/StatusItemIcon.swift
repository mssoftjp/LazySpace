import AppKit
import Copy

/// The app icon's three panels, uniformly scaled into an 18-point menu-bar template.
/// The contours and spacing match Assets/LazySpace.icon/Assets exactly.
enum StatusItemIcon {
    // These are the color icon's paths in its original 1024-unit coordinates.
    // Preserve its 236-unit panel widths, 24-unit gaps, and quadratic corners.
    static let panelPaths: [CGPath] = {
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 158, y: 205))
        left.addQuadCurve(to: CGPoint(x: 134, y: 222), control: CGPoint(x: 134, y: 197))
        left.addLine(to: CGPoint(x: 134, y: 802))
        left.addQuadCurve(to: CGPoint(x: 158, y: 819), control: CGPoint(x: 134, y: 827))
        left.addLine(to: CGPoint(x: 348, y: 759))
        left.addQuadCurve(to: CGPoint(x: 370, y: 729), control: CGPoint(x: 370, y: 752))
        left.addLine(to: CGPoint(x: 370, y: 295))
        left.addQuadCurve(to: CGPoint(x: 348, y: 265), control: CGPoint(x: 370, y: 272))
        left.closeSubpath()

        let center = CGMutablePath()
        center.move(to: CGPoint(x: 418, y: 274))
        center.addLine(to: CGPoint(x: 606, y: 274))
        center.addQuadCurve(to: CGPoint(x: 630, y: 298), control: CGPoint(x: 630, y: 274))
        center.addLine(to: CGPoint(x: 630, y: 726))
        center.addQuadCurve(to: CGPoint(x: 606, y: 750), control: CGPoint(x: 630, y: 750))
        center.addLine(to: CGPoint(x: 418, y: 750))
        center.addQuadCurve(to: CGPoint(x: 394, y: 726), control: CGPoint(x: 394, y: 750))
        center.addLine(to: CGPoint(x: 394, y: 298))
        center.addQuadCurve(to: CGPoint(x: 418, y: 274), control: CGPoint(x: 394, y: 274))
        center.closeSubpath()

        var mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1024, ty: 0)
        return [left, center, left.copy(using: &mirror)!]
    }()

    static let image = make(marked: false)
    /// The same mark with a dot at the top right, set apart from the right panel by a cleared ring: something needs the user.
    static let markedImage = make(marked: true)

    private static func make(marked: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setFillColor(NSColor.black.cgColor)

            context.saveGState()
            // Fit the full 756-unit mark into 16.5 pt, keeping a 0.75 pt inset.
            // Use one scale for both axes and all panels, including the gaps.
            let scale: CGFloat = 16.5 / 756
            context.translateBy(x: 9, y: 9)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -512, y: -512)
            for panel in panelPaths {
                context.addPath(panel)
                context.fillPath()
            }
            context.restoreGState()

            if marked {
                let center = CGPoint(x: 15.5, y: 15.5)
                func circle(_ radius: CGFloat) -> CGRect {
                    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                }
                context.setBlendMode(.clear)
                context.fillEllipse(in: circle(4))
                context.setBlendMode(.normal)
                context.fillEllipse(in: circle(2.5))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LazySpace"
        return image
    }
}

/// What the menu bar item shows besides the desktop number. Only states the user must know about change it: a global pause
/// dims it, and a problem LazySpace cannot get past without the user marks it. A Space whose automatic arrangement the user
/// turned off changes nothing.
struct StatusItemLook: Equatable {
    var dimmed: Bool
    var marked: Bool
    /// Read by VoiceOver after the item's name: the problem first, since it needs action, else the pause.
    var accessibilityValue: String?

    init(dimmed: Bool, marked: Bool, accessibilityValue: String?) {
        self.dimmed = dimmed
        self.marked = marked
        self.accessibilityValue = accessibilityValue
    }

    init(paused: Bool, attention: AttentionReason?) {
        dimmed = paused
        marked = attention != nil
        accessibilityValue = attention.map(NotificationCopy.title) ?? (paused ? L(.editCommandsPausedInAllSpaces) : nil)
    }

    var image: NSImage { marked ? StatusItemIcon.markedImage : StatusItemIcon.image }
}
