import AppKit
import Copy
import Settings

/// A small picture showing what an action does to windows.
enum ActionPictogram: Equatable {
    case focus
    case swap
    case move
    case join
    case resize
    case smartGrow
    case smartShrink
    case balance
    case undo
    case toggleSplit
    case accordion
    case arrange
    case integrate
    case pause
    case reload
    case close
    case focusBack
    case float
    case zoom
    case fullscreen
    case minimize
    case switchSpace(Int)
    case spaceNext
    case spacePrev
    case spaceBack
    case moveToSpace(Int)
    case moveToSpaceNext
    case moveToSpacePrev
    case placementBeside
    case placementEnd

    /// Command name to picture. Mode switches are not listed.
    static func forCommand(_ name: String) -> ActionPictogram? {
        if name.hasPrefix("mode-") { return nil }
        switch name {
        case "focus-back": return .focusBack
        case "resize-smart-grow": return .smartGrow
        case "resize-smart-shrink": return .smartShrink
        case "balance": return .balance
        case "undo": return .undo
        case "toggle-split": return .toggleSplit
        case "accordion": return .accordion
        case "arrange": return .arrange
        case "integrate": return .integrate
        case "pause-resume": return .pause
        case "reload": return .reload
        case "close": return .close
        case "float": return .float
        case "zoom": return .zoom
        case "fullscreen": return .fullscreen
        case "minimize": return .minimize
        case "space-next": return .spaceNext
        case "space-prev": return .spacePrev
        case "space-back": return .spaceBack
        case "move-to-space-next", "move-to-space-follow-next": return .moveToSpaceNext
        case "move-to-space-prev", "move-to-space-follow-prev": return .moveToSpacePrev
        default: break
        }
        if name.hasPrefix("focus-") { return .focus }
        if name.hasPrefix("swap-") { return .swap }
        if name.hasPrefix("join-") { return .join }
        if name.hasPrefix("resize-") { return .resize }
        if name.hasPrefix("move-to-space-follow-") {
            guard let n = Int(name.dropFirst("move-to-space-follow-".count)), (1...9).contains(n) else { return nil }
            return .moveToSpace(n)
        }
        if name.hasPrefix("move-to-space-"),
           let n = Int(name.dropFirst("move-to-space-".count)), (1...9).contains(n) {
            return .moveToSpace(n)
        }
        if name.hasPrefix("move-") { return .move }
        if name.hasPrefix("space-"),
           let n = Int(name.dropFirst("space-".count)), (1...9).contains(n) {
            return .switchSpace(n)
        }
        return nil
    }

    /// A direction group uses the picture of its horizontal direction.
    static func forGroup(_ group: DirectionGroup) -> ActionPictogram {
        switch group {
        case .focus: return .focus
        case .swap: return .swap
        case .move: return .move
        case .join: return .join
        case .resize: return .resize
        }
    }

    /// Description of the picture, without the command name itself.
    var help: String {
        switch self {
        case .focus:
            return L("Moves the focus to the neighboring window. Windows stay in place.",
                     "隣のウインドウへフォーカスを移します。ウインドウは動きません。")
        case .swap:
            return L("The focused window trades places with its neighbor.",
                     "フォーカス中のウインドウと隣のウインドウの位置を入れ替えます。")
        case .move:
            return L("Moves the focused window one step in the layout. Other windows shift to make room.",
                     "フォーカス中のウインドウをレイアウト内で1つ動かします。他のウインドウが詰めます。")
        case .join:
            return L("Groups the focused window with its neighbor so they share one slot.",
                     "フォーカス中のウインドウを隣とまとめ、1つの枠を分け合います。")
        case .resize:
            return L("Moves the edge between the focused window and its neighbor.",
                     "フォーカス中のウインドウと隣の境目を動かします。")
        case .smartGrow, .smartShrink:
            return L("Makes the focused window larger / smaller along its split.",
                     "分割の向きに沿って、フォーカス中のウインドウを大きく／小さくします。")
        case .balance:
            return L("Resets the layout’s split ratios to equal shares.",
                     "レイアウトの分割比率を均等に戻します。")
        case .undo:
            return L("Undoes the last layout change.", "直前のレイアウト変更を取り消します。")
        case .toggleSplit:
            return L("Switches the split between side by side and stacked.",
                     "左右の分割と上下の分割を切り替えます。")
        case .accordion:
            return L("Switches the split between overlapping and tiled windows.",
                     "分割内のウインドウを重ねて表示、または並べて表示します。")
        case .arrange:
            return L("Arranges this Space and starts tiling it.",
                     "この操作スペースを整列し、タイル配置を始めます。")
        case .integrate:
            return L("Adds one waiting window to the layout.",
                     "待機中のウインドウを1つレイアウトに加えます。")
        case .pause:
            return L("Pauses or resumes arranging in every Space.",
                     "すべての操作スペースの整列を一時停止・再開します。")
        case .reload:
            return L("Reloads the configuration file. Windows don't move.",
                     "設定ファイルを読み込み直します。ウインドウは動きません。")
        case .close:
            return L("Closes the focused window.", "フォーカス中のウインドウを閉じます。")
        case .focusBack:
            return L("Returns the focus to the previously focused window.",
                     "直前にフォーカスしていたウインドウへ戻ります。")
        case .float:
            return L("Takes the focused window out of the layout, or puts it back.",
                     "フォーカス中のウインドウをレイアウトから外す、または戻します。")
        case .zoom:
            return L("Fills the work area with the focused window, or restores the tiled layout.",
                     "フォーカス中のウインドウを作業領域いっぱいに広げる、または整列した表示に戻します。")
        case .fullscreen:
            return L("Turns macOS full screen on or off for the focused window.",
                     "フォーカス中のウインドウのmacOSフルスクリーンを切り替えます。")
        case .minimize:
            return L("Minimizes the focused window to the Dock.",
                     "フォーカス中のウインドウをDockにしまいます。")
        case .switchSpace(let n):
            return L("Shows \(Copy.desktop(n)). Windows stay where they are.",
                     "\(Copy.desktop(n))を表示します。ウインドウは動きません。")
        case .spaceNext, .spacePrev:
            return L("Shows the next / previous Space.", "次／前の操作スペースを表示します。")
        case .spaceBack:
            return L("Returns to the Space you used last.", "直前に使った操作スペースに戻ります。")
        case .moveToSpace(let n):
            return L("Moves the focused window to \(Copy.desktop(n)).",
                     "フォーカス中のウインドウを\(Copy.desktop(n))へ送ります。")
        case .moveToSpaceNext, .moveToSpacePrev:
            return L("Moves the focused window to the next / previous Space.",
                     "フォーカス中のウインドウを次／前の操作スペースへ送ります。")
        case .placementBeside:
            return L("New windows open next to the focused window.",
                     "新しいウインドウはフォーカス中のウインドウの隣に入ります。")
        case .placementEnd:
            return L("New windows are added at the end of the layout.",
                     "新しいウインドウはレイアウトの末尾に入ります。")
        }
    }

    /// Drawing colors; roles change for selected rows and increased contrast.
    struct Palette {
        var frame: NSColor
        var tile: NSColor
        var subject: NSColor
        var arrow: NSColor
        var ghost: NSColor
        var onSubject: NSColor
        var subjectOutline: NSColor?
        var subjectOutlineWidth: CGFloat
        var arrowWidth: CGFloat

        static func standard(increaseContrast: Bool) -> Palette {
            if increaseContrast {
                return Palette(
                    frame: .labelColor,
                    tile: .labelColor.withAlphaComponent(0.30),
                    subject: .controlAccentColor,
                    arrow: .labelColor,
                    ghost: .labelColor,
                    onSubject: .white,
                    subjectOutline: .labelColor,
                    subjectOutlineWidth: 1,
                    arrowWidth: 1.5
                )
            }
            return Palette(
                frame: .secondaryLabelColor,
                tile: .labelColor.withAlphaComponent(0.16),
                subject: .controlAccentColor,
                arrow: .labelColor,
                ghost: .secondaryLabelColor,
                onSubject: .white,
                subjectOutline: nil,
                subjectOutlineWidth: 0,
                arrowWidth: 1.25
            )
        }

        static var emphasized: Palette {
            let alt = NSColor.alternateSelectedControlTextColor
            return Palette(
                frame: alt.withAlphaComponent(0.85),
                tile: alt.withAlphaComponent(0.35),
                subject: alt.withAlphaComponent(1),
                arrow: alt.withAlphaComponent(1),
                ghost: alt.withAlphaComponent(0.85),
                onSubject: .selectedContentBackgroundColor,
                subjectOutline: nil,
                subjectOutlineWidth: 0,
                arrowWidth: 1.25
            )
        }
    }
}

/// Draws the picture in 28x18 unit coordinates.
enum ActionPictogramPainter {
    static func draw(_ pictogram: ActionPictogram, in rect: NSRect, palette: ActionPictogram.Palette) {
        guard let ctx = NSGraphicsContext.current?.cgContext, rect.width > 1, rect.height > 1 else { return }
        let scale = min(rect.width / 28, rect.height / 18)
        guard scale > 0, scale.isFinite else { return }
        let canvas = PictogramCanvas(
            ctx: ctx,
            scale: scale,
            ox: rect.midX - 14 * scale,
            oy: rect.midY - 9 * scale,
            flipped: NSGraphicsContext.current?.isFlipped ?? false,
            palette: palette
        )
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        canvas.paint(pictogram)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// The picture shown in the table and the arrangement preview.
final class ActionPictogramView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 18) }

    var pictogram: ActionPictogram? {
        didSet { needsDisplay = true }
    }

    var emphasized = false {
        didSet {
            if emphasized != oldValue { needsDisplay = true }
        }
    }

    private var contrastObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let contrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver)
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pictogram, bounds.width > 1, bounds.height > 1 else { return }
        ActionPictogramPainter.draw(pictogram, in: bounds, palette: paletteForDraw())
    }

    private func paletteForDraw() -> ActionPictogram.Palette {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if emphasized {
            var palette = ActionPictogram.Palette.emphasized
            if contrast {
                palette.subjectOutline = .labelColor
                palette.subjectOutlineWidth = 1
                palette.arrowWidth = 1.5
            }
            return palette
        }
        return .standard(increaseContrast: contrast)
    }
}

/// Lines and fills of the picture. y grows downward in unit coordinates.
private struct PictogramCanvas {
    let ctx: CGContext
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat
    let flipped: Bool
    let palette: ActionPictogram.Palette

    private let interior = CGRect(x: 3, y: 3, width: 22, height: 12)
    private let left = CGRect(x: 3, y: 3, width: 10.25, height: 12)
    private let right = CGRect(x: 14.75, y: 3, width: 10.25, height: 12)
    private let rightTop = CGRect(x: 14.75, y: 3, width: 10.25, height: 5.25)
    private let rightBottom = CGRect(x: 14.75, y: 9.75, width: 10.25, height: 5.25)
    private let third1 = CGRect(x: 3, y: 3, width: 6.33, height: 12)
    private let third2 = CGRect(x: 10.83, y: 3, width: 6.34, height: 12)
    private let third3 = CGRect(x: 18.67, y: 3, width: 6.33, height: 12)
    private let before = CGRect(x: 1.5, y: 3.5, width: 11, height: 11)
    private let after = CGRect(x: 15.5, y: 3.5, width: 11, height: 11)
    private let slot0 = CGRect(x: 1.5, y: 6, width: 7.5, height: 10.5)
    private let slot1 = CGRect(x: 10.25, y: 6, width: 7.5, height: 10.5)
    private let slot2 = CGRect(x: 19, y: 6, width: 7.5, height: 10.5)

    func paint(_ pictogram: ActionPictogram) {
        switch pictogram {
        case .focus:
            spaceFrame()
            tile(left, subject: false)
            tile(right, subject: false)
            ring(right)
            arrow(from: CGPoint(x: 5, y: 9), to: CGPoint(x: 11.5, y: 9))
        case .swap:
            spaceFrame()
            tile(left, subject: true)
            tile(right, subject: false)
            arrow(from: CGPoint(x: 7, y: 9), to: CGPoint(x: 21, y: 9), doubleHead: true)
        case .move:
            spaceFrame()
            tile(third1, subject: false)
            ghost(third2)
            tile(third3, subject: true)
            arrow(from: CGPoint(x: 12, y: 9), to: CGPoint(x: 21.5, y: 9))
        case .join:
            spaceFrame()
            ghost(left)
            tile(rightTop, subject: false)
            tile(rightBottom, subject: true)
            stroke(rounded(right.insetBy(dx: -0.75, dy: -0.75), radius: 2), color: palette.arrow, width: 1)
            arrow(from: CGPoint(x: 6, y: 9), to: CGPoint(x: 16.2, y: 12.4))
        case .resize:
            spaceFrame()
            tile(CGRect(x: 3, y: 3, width: 13, height: 12), subject: true)
            tile(CGRect(x: 17.5, y: 3, width: 7.5, height: 12), subject: false)
            arrow(from: CGPoint(x: 11.5, y: 9), to: CGPoint(x: 22, y: 9), doubleHead: true)
            resizeDivider()
        case .smartGrow:
            spaceFrame()
            tile(CGRect(x: 10, y: 3, width: 8, height: 12), subject: true)
            arrow(from: CGPoint(x: 9, y: 9), to: CGPoint(x: 4, y: 9))
            arrow(from: CGPoint(x: 19, y: 9), to: CGPoint(x: 24, y: 9))
        case .smartShrink:
            spaceFrame()
            tile(CGRect(x: 10, y: 3, width: 8, height: 12), subject: true)
            arrow(from: CGPoint(x: 3.5, y: 9), to: CGPoint(x: 9, y: 9))
            arrow(from: CGPoint(x: 24.5, y: 9), to: CGPoint(x: 19, y: 9))
        case .balance:
            spaceFrame()
            tile(CGRect(x: 3, y: 3, width: 6.33, height: 8.5), subject: false)
            tile(CGRect(x: 10.83, y: 3, width: 6.34, height: 8.5), subject: false)
            tile(CGRect(x: 18.67, y: 3, width: 6.33, height: 8.5), subject: false)
            ruler()
        case .undo:
            spaceFrame()
            tile(left, subject: false)
            tile(right, subject: false)
            strokeCurve(arc(center: CGPoint(x: 14, y: 9), radius: 4, start: 50, sweep: -300), headAtEnd: true)
        case .toggleSplit:
            spaceFrame(before)
            sideBySide(in: before, leftSubject: true)
            chevron()
            spaceFrame(after)
            stacked(in: after, topSubject: true)
        case .accordion:
            spaceFrame()
            card(CGRect(x: 3, y: 3, width: 14, height: 12), subject: false, separate: false)
            card(CGRect(x: 6.5, y: 3, width: 14, height: 12), subject: false, separate: true)
            card(CGRect(x: 11, y: 3, width: 14, height: 12), subject: true, separate: true)
        case .arrange:
            spaceFrame(before)
            tile(CGRect(x: 3.5, y: 5.5, width: 5.5, height: 5), subject: false)
            tile(CGRect(x: 5.5, y: 7.5, width: 5.5, height: 5), subject: false, separate: true)
            chevron()
            spaceFrame(after, color: palette.subject, width: 1.25)
            sideBySide(in: after, leftSubject: false)
        case .integrate:
            spaceFrame()
            tile(left, subject: false)
            ghost(right)
            tile(CGRect(x: 19, y: 0.5, width: 7.5, height: 5.5), subject: true, separate: true)
            arrow(from: CGPoint(x: 22.75, y: 6.5), to: CGPoint(x: 22.75, y: 12))
        case .pause:
            spaceFrame()
            tile(left, subject: false)
            tile(right, subject: false)
            badge(CGRect(x: 18.5, y: 8.5, width: 9, height: 9))
            pauseBars(in: CGRect(x: 18.5, y: 8.5, width: 9, height: 9))
        case .reload:
            page()
            badge(CGRect(x: 14.5, y: 8.5, width: 9, height: 9))
            strokeCurve(arc(center: CGPoint(x: 19, y: 13), radius: 2.5, start: -30, sweep: 280), headAtEnd: true, color: palette.onSubject)
        case .close:
            spaceFrame()
            tile(left, subject: false)
            ghost(right)
            cross(center: CGPoint(x: 19.875, y: 9), size: 4)
        case .focusBack:
            spaceFrame()
            tile(left, subject: false)
            ring(left)
            tile(right, subject: false)
            strokeCurve(quad(from: CGPoint(x: 19.9, y: 7), control: CGPoint(x: 14, y: 3.5), to: CGPoint(x: 8.1, y: 7)), headAtEnd: true)
        case .float:
            spaceFrame()
            tile(left, subject: false)
            ghost(right)
            let lifted = CGRect(x: 13.5, y: 1, width: 10, height: 8)
            stroke(rounded(lifted.offsetBy(dx: 1, dy: 1), radius: 1.5), color: palette.arrow.withAlphaComponent(0.35), width: 1)
            tile(lifted, subject: true, separate: true)
        case .zoom:
            spaceFrame()
            band(CGRect(x: 3, y: 3, width: 22, height: 1.75))
            tile(CGRect(x: 3, y: 6.25, width: 22, height: 8.75), subject: true)
        case .fullscreen:
            tile(interior, subject: true)
            spaceFrame(color: palette.subject, width: 1.25)
            arrow(from: CGPoint(x: 11, y: 9), to: CGPoint(x: 6, y: 5.5), color: palette.onSubject)
            arrow(from: CGPoint(x: 17, y: 9), to: CGPoint(x: 22, y: 12.5), color: palette.onSubject)
        case .minimize:
            spaceFrame()
            ghost(CGRect(x: 6, y: 3, width: 16, height: 7.5))
            band(CGRect(x: 8, y: 13.25, width: 12, height: 1.75))
            tile(CGRect(x: 12, y: 12.25, width: 4, height: 2.5), subject: true, separate: true)
            arrow(from: CGPoint(x: 14, y: 7), to: CGPoint(x: 14, y: 12))
        case .switchSpace(let n):
            slotStroke(slot0, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: true, width: 1.25)
            digit(n, center: center(of: slot2), size: 7, color: palette.arrow)
            arrow(from: CGPoint(x: 5.25, y: 3), to: CGPoint(x: 22.75, y: 3))
        case .spaceNext:
            slotStroke(slot0, subject: false)
            fillSlot(slot1, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: true, width: 1.25)
            arrow(from: CGPoint(x: 14, y: 3), to: CGPoint(x: 22.75, y: 3))
        case .spacePrev:
            slotStroke(slot0, subject: true, width: 1.25)
            fillSlot(slot1, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: false)
            arrow(from: CGPoint(x: 14, y: 3), to: CGPoint(x: 5.25, y: 3))
        case .spaceBack:
            slotStroke(slot0, subject: true, width: 1.25)
            slotStroke(slot1, subject: false)
            fillSlot(slot2, subject: false)
            slotStroke(slot2, subject: false)
            strokeCurve(quad(from: CGPoint(x: 22.75, y: 5), control: CGPoint(x: 14, y: 0.75), to: CGPoint(x: 5.25, y: 5)), headAtEnd: true)
        case .moveToSpace(let n):
            slotStroke(slot0, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: false)
            ghost(slot0.insetBy(dx: 1.25, dy: 1.25))
            tile(slot2.insetBy(dx: 1.25, dy: 1.25), subject: true)
            digit(n, center: center(of: slot2), size: 7, color: palette.onSubject)
            arrow(from: CGPoint(x: 5.25, y: 3), to: CGPoint(x: 22.75, y: 3))
        case .moveToSpaceNext:
            slotStroke(slot0, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: false)
            ghost(slot1.insetBy(dx: 1.25, dy: 1.25))
            tile(slot2.insetBy(dx: 1.25, dy: 1.25), subject: true)
            arrow(from: CGPoint(x: 15.5, y: 3), to: CGPoint(x: 21.5, y: 3))
        case .moveToSpacePrev:
            slotStroke(slot0, subject: false)
            slotStroke(slot1, subject: false)
            slotStroke(slot2, subject: false)
            ghost(slot1.insetBy(dx: 1.25, dy: 1.25))
            tile(slot0.insetBy(dx: 1.25, dy: 1.25), subject: true)
            arrow(from: CGPoint(x: 12.5, y: 3), to: CGPoint(x: 6.5, y: 3))
        case .placementBeside:
            spaceFrame()
            tile(third1, subject: false)
            ring(third1)
            tile(third2, subject: true)
            tile(third3, subject: false)
            arrow(from: CGPoint(x: 14, y: 0.25), to: CGPoint(x: 14, y: 6.5))
        case .placementEnd:
            spaceFrame()
            tile(third1, subject: false)
            ring(third1)
            tile(third2, subject: false)
            tile(third3, subject: true)
            arrow(from: CGPoint(x: 21.83, y: 0.25), to: CGPoint(x: 21.83, y: 6.5))
        }
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        if flipped { return CGPoint(x: ox + x * scale, y: oy + y * scale) }
        return CGPoint(x: ox + x * scale, y: oy + (18 - y) * scale)
    }

    private func box(_ r: CGRect) -> CGRect {
        let a = p(r.minX, r.minY)
        let b = p(r.maxX, r.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func rounded(_ r: CGRect, radius: CGFloat) -> CGPath {
        let rect = box(r)
        let corner = min(radius * scale, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    private func resolved(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.sRGB) ?? color).cgColor
    }

    private func fill(_ path: CGPath, color: NSColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(resolved(color))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(resolved(color))
        ctx.setLineWidth(max(1, width) * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash.map { $0 * scale }) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func knockout(_ path: CGPath, width: CGFloat = 3.25) {
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.setLineWidth(width * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func spaceFrame(_ r: CGRect = CGRect(x: 1.5, y: 1.5, width: 25, height: 15), color: NSColor? = nil, width: CGFloat = 1) {
        stroke(rounded(r, radius: 2.5), color: color ?? palette.frame, width: width)
    }

    private func tile(_ r: CGRect, subject: Bool, separate: Bool = false) {
        let path = rounded(r, radius: 1.5)
        if separate { knockout(path) }
        fill(path, color: subject ? palette.subject : palette.tile)
        if subject, palette.subjectOutlineWidth >= 1, let outline = palette.subjectOutline {
            stroke(rounded(r.insetBy(dx: 0.5, dy: 0.5), radius: 1), color: outline, width: palette.subjectOutlineWidth)
        }
    }

    private func ghost(_ r: CGRect) {
        stroke(rounded(r, radius: 1.5), color: palette.ghost, width: 1, dash: [2, 1.5])
    }

    private func ring(_ r: CGRect) {
        stroke(rounded(r.insetBy(dx: 0.6, dy: 0.6), radius: 1), color: palette.subject, width: 1.25)
    }

    private func band(_ r: CGRect) {
        let doubled = min(1, palette.tile.alphaComponent * 2)
        fill(rounded(r, radius: 0.5), color: palette.tile.withAlphaComponent(max(doubled, 0.2)))
    }

    private func card(_ r: CGRect, subject: Bool, separate: Bool) {
        tile(r, subject: subject, separate: separate)
    }

    private func arrow(from a: CGPoint, to b: CGPoint, doubleHead: Bool = false, color: NSColor? = nil) {
        var path = CGMutablePath()
        path.move(to: p(a.x, a.y))
        path.addLine(to: p(b.x, b.y))
        addHead(to: &path, tip: b, awayFrom: a)
        if doubleHead { addHead(to: &path, tip: a, awayFrom: b) }
        knockout(path)
        stroke(path, color: color ?? palette.arrow, width: palette.arrowWidth)
    }

    private func addHead(to path: inout CGMutablePath, tip: CGPoint, awayFrom: CGPoint) {
        let dx = tip.x - awayFrom.x
        let dy = tip.y - awayFrom.y
        let len = max(0.001, hypot(dx, dy))
        let ux = dx / len
        let uy = dy / len
        let px = -uy
        let py = ux
        let back = 2.75 * cos(40 * CGFloat.pi / 180)
        let side = 2.75 * sin(40 * CGFloat.pi / 180)
        let left = CGPoint(x: tip.x - ux * back + px * side, y: tip.y - uy * back + py * side)
        let right = CGPoint(x: tip.x - ux * back - px * side, y: tip.y - uy * back - py * side)
        path.move(to: p(tip.x, tip.y))
        path.addLine(to: p(left.x, left.y))
        path.move(to: p(tip.x, tip.y))
        path.addLine(to: p(right.x, right.y))
    }

    private func strokeCurve(_ points: [CGPoint], headAtEnd: Bool, color: NSColor? = nil) {
        guard let first = points.first, points.count >= 2 else { return }
        var path = CGMutablePath()
        path.move(to: p(first.x, first.y))
        for point in points.dropFirst() { path.addLine(to: p(point.x, point.y)) }
        if headAtEnd, let last = points.last { addHead(to: &path, tip: last, awayFrom: points[points.count - 2]) }
        knockout(path)
        stroke(path, color: color ?? palette.arrow, width: palette.arrowWidth)
    }

    private func arc(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat) -> [CGPoint] {
        let steps = 28
        return (0...steps).map { i in
            let degrees = start + sweep * CGFloat(i) / CGFloat(steps)
            let radians = degrees * CGFloat.pi / 180
            return CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        }
    }

    private func quad(from: CGPoint, control: CGPoint, to: CGPoint) -> [CGPoint] {
        let steps = 16
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            return CGPoint(
                x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
            )
        }
    }

    private func chevron() {
        let path = CGMutablePath()
        let a = p(12.75, 7)
        let b = p(12.75, 11)
        let c = p(15.25, 9)
        path.move(to: a)
        path.addLine(to: b)
        path.addLine(to: c)
        path.closeSubpath()
        knockout(path)
        fill(path, color: palette.frame)
    }

    private func sideBySide(in frame: CGRect, leftSubject: Bool) {
        let inner = frame.insetBy(dx: 1.6, dy: 1.6)
        let gap: CGFloat = 0.8
        let width = (inner.width - gap) / 2
        tile(CGRect(x: inner.minX, y: inner.minY, width: width, height: inner.height), subject: leftSubject)
        tile(CGRect(x: inner.minX + width + gap, y: inner.minY, width: width, height: inner.height), subject: false)
    }

    private func stacked(in frame: CGRect, topSubject: Bool) {
        let inner = frame.insetBy(dx: 1.6, dy: 1.6)
        let gap: CGFloat = 0.8
        let height = (inner.height - gap) / 2
        tile(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: height), subject: topSubject)
        tile(CGRect(x: inner.minX, y: inner.minY + height + gap, width: inner.width, height: height), subject: false)
    }

    private func ruler() {
        let path = CGMutablePath()
        path.move(to: p(3, 13.5))
        path.addLine(to: p(25, 13.5))
        for x in [CGFloat(3), 10.08, 17.92, 25] {
            path.move(to: p(x, 12.5))
            path.addLine(to: p(x, 14.5))
        }
        stroke(path, color: palette.frame, width: 1)
    }

    private func badge(_ r: CGRect) {
        let path = CGPath(ellipseIn: box(r), transform: nil)
        knockout(path)
        fill(path, color: palette.subject)
        if palette.subjectOutlineWidth >= 1, let outline = palette.subjectOutline {
            stroke(path, color: outline, width: palette.subjectOutlineWidth)
        }
    }

    private func pauseBars(in badge: CGRect) {
        let midX = badge.midX
        let midY = badge.midY
        let bar = CGSize(width: 1.25, height: 4.5)
        fill(rounded(CGRect(x: midX - 1.6, y: midY - bar.height / 2, width: bar.width, height: bar.height), radius: 0.4), color: palette.onSubject)
        fill(rounded(CGRect(x: midX + 0.35, y: midY - bar.height / 2, width: bar.width, height: bar.height), radius: 0.4), color: palette.onSubject)
    }

    private func page() {
        let rect = CGRect(x: 7, y: 1, width: 12, height: 16)
        let dog: CGFloat = 3.5
        let path = CGMutablePath()
        path.move(to: p(rect.minX, rect.minY))
        path.addLine(to: p(rect.maxX - dog, rect.minY))
        path.addLine(to: p(rect.maxX, rect.minY + dog))
        path.addLine(to: p(rect.maxX, rect.maxY))
        path.addLine(to: p(rect.minX, rect.maxY))
        path.closeSubpath()
        fill(path, color: palette.tile)
        stroke(path, color: palette.frame, width: 1)
        let fold = CGMutablePath()
        fold.move(to: p(rect.maxX - dog, rect.minY))
        fold.addLine(to: p(rect.maxX - dog, rect.minY + dog))
        fold.addLine(to: p(rect.maxX, rect.minY + dog))
        fold.closeSubpath()
        fill(fold, color: palette.frame)
        for y in [CGFloat(6), 9, 12] {
            fill(rounded(CGRect(x: 9, y: y, width: 6.5, height: 1.15), radius: 0.4), color: palette.frame)
        }
    }

    private func cross(center: CGPoint, size: CGFloat) {
        let half = size / 2
        let path = CGMutablePath()
        path.move(to: p(center.x - half, center.y - half))
        path.addLine(to: p(center.x + half, center.y + half))
        path.move(to: p(center.x + half, center.y - half))
        path.addLine(to: p(center.x - half, center.y + half))
        knockout(path)
        stroke(path, color: palette.arrow, width: 1.25)
    }

    /// The resize divider, drawn after the arrows with its gap cut out first.
    private func resizeDivider() {
        let path = CGMutablePath()
        path.move(to: p(16.75, 1.5))
        path.addLine(to: p(16.75, 16.5))
        knockout(path)
        stroke(path, color: palette.arrow, width: 1.25)
    }

    private func slotStroke(_ r: CGRect, subject: Bool, width: CGFloat = 1) {
        stroke(rounded(r, radius: 1.6), color: subject ? palette.subject : palette.frame, width: width)
    }

    private func fillSlot(_ r: CGRect, subject: Bool) {
        fill(rounded(r.insetBy(dx: 1.25, dy: 1.25), radius: 1), color: subject ? palette.subject : palette.tile)
    }

    private func digit(_ n: Int, center: CGPoint, size: CGFloat, color: NSColor) {
        let text = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: size * scale, weight: .semibold),
            .foregroundColor: color,
        ])
        let measured = text.size()
        let origin = p(center.x, center.y)
        text.draw(in: NSRect(x: origin.x - measured.width / 2, y: origin.y - measured.height / 2, width: measured.width, height: measured.height))
    }

    private func center(of r: CGRect) -> CGPoint {
        CGPoint(x: r.midX, y: r.midY)
    }
}
