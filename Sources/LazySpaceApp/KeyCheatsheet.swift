import AppKit
import Copy
import Settings

/// Shows the current mode's keys while a modifier is held. Never takes focus.
/// Backed by the system glass on macOS 26 and later, and by the popover material before that.
final class KeyCheatsheet {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)

    init() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.title = Self.brandTitle
    }

    func show(config: Config, mode: String) {
        let bindings = HotkeyBinding.from(config, mode: mode).sorted { $0.display < $1.display }
        guard !bindings.isEmpty else { hide(); return }
        let title = Self.brandTitle
        let subtitle = Self.modeSubtitle(mode)
        panel.title = title
        let visible = Self.screen(containing: NSEvent.mouseLocation)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let rows = bindings.map { Row(key: $0.display, action: $0.label) }
        let layout = Self.measure(title: title, subtitle: subtitle, rows: rows, visible: visible)
        let root = Self.makeRoot(title: title, subtitle: subtitle, rows: rows, layout: layout)
        install(root, size: layout.size)
        let origin = NSPoint(x: visible.midX - layout.size.width / 2, y: visible.maxY - layout.size.height - Self.screenInset)
        panel.setFrame(NSRect(origin: origin, size: layout.size), display: true)
        panel.orderFrontRegardless()
    }

    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 640

    func hide() { panel.orderOut(nil) }

    // MARK: - Text and screen

    static var brandTitle: String { L(.keyCheatsheetBrandTitle) }

    /// A short subtitle with the mode name, except for main.
    static func modeSubtitle(_ mode: String) -> String? {
        guard mode != Config.mainModeName else { return nil }
        return L(.keyCheatsheetMode(mode))
    }

    /// In a menu-bar app, NSScreen.main is not necessarily the caller's screen.
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Metrics

    private struct Row {
        var key: String
        var action: String
    }

    private struct Measure {
        var size: NSSize
        var keyColumn: CGFloat
        var actionColumn: CGFloat
        var rowsHeight: CGFloat
        var bodyHeight: CGFloat
        var titleHeight: CGFloat
        var subtitleHeight: CGFloat
        var innerWidth: CGFloat
    }

    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 12)
    private static let keyFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let actionFont = NSFont.systemFont(ofSize: 13)
    private static let rowHeight: CGFloat = 24
    private static let columnGap: CGFloat = 16
    private static let insetX: CGFloat = 16
    private static let insetY: CGFloat = 14
    private static let blockGap: CGFloat = 8
    private static let maxPanelHeight: CGFloat = 360
    private static let screenInset: CGFloat = 24
    private static let cornerRadius: CGFloat = 18
    private static let scrollerReserve: CGFloat = 14

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private static func measure(title: String, subtitle: String?, rows: [Row], visible: NSRect) -> Measure {
        let titleHeight = lineHeight(titleFont)
        let subtitleHeight = subtitle == nil ? 0 : lineHeight(subtitleFont)
        let gaps = blockGap + (subtitle == nil ? 0 : blockGap)
        let header = insetY + titleHeight + gaps + subtitleHeight
        let rowsHeight = CGFloat(rows.count) * rowHeight
        let screenHeight = max(header + rowHeight + insetY, visible.height - screenInset * 2)
        let height = min(header + rowsHeight + insetY, min(maxPanelHeight, screenHeight))
        let bodyHeight = max(rowHeight, height - header - insetY)
        let scrolls = rowsHeight > bodyHeight + 0.5
        let scroller = scrolls ? scrollerReserve : 0
        let keyWidth = rows.map { textWidth($0.key, font: keyFont) }.max() ?? 0
        let actionWidth = rows.map { textWidth($0.action, font: actionFont) }.max() ?? 0
        let titleWidth = textWidth(title, font: titleFont)
        let subtitleWidth = subtitle.map { textWidth($0, font: subtitleFont) } ?? 0
        let needed = max(titleWidth, subtitleWidth, keyWidth + columnGap + actionWidth) + insetX * 2 + scroller
        let screenWidth = max(160, visible.width - screenInset * 2)
        let width = min(max(needed, min(minWidth, screenWidth)), min(maxWidth, screenWidth))
        let innerWidth = max(80, width - insetX * 2 - scroller)
        let keyColumn = min(max(keyWidth, 1), max(1, innerWidth - columnGap - 40))
        let actionColumn = max(40, innerWidth - columnGap - keyColumn)
        return Measure(
            size: NSSize(width: width, height: height),
            keyColumn: keyColumn,
            actionColumn: actionColumn,
            rowsHeight: rowsHeight,
            bodyHeight: bodyHeight,
            titleHeight: titleHeight,
            subtitleHeight: subtitleHeight,
            innerWidth: innerWidth)
    }

    // MARK: - Content

    private static func label(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func makeRoot(title: String, subtitle: String?, rows: [Row], layout: Measure) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: layout.size))
        root.autoresizingMask = [.width, .height]
        var top = layout.size.height - insetY
        let titleField = label(title, font: titleFont, color: .labelColor, alignment: .left)
        top -= layout.titleHeight
        titleField.frame = NSRect(x: insetX, y: top, width: layout.innerWidth, height: layout.titleHeight)
        titleField.autoresizingMask = [.width, .minYMargin]
        root.addSubview(titleField)
        top -= blockGap
        if let subtitle {
            let subtitleField = label(subtitle, font: subtitleFont, color: .secondaryLabelColor, alignment: .left)
            top -= layout.subtitleHeight
            subtitleField.frame = NSRect(x: insetX, y: top, width: layout.innerWidth, height: layout.subtitleHeight)
            subtitleField.autoresizingMask = [.width, .minYMargin]
            root.addSubview(subtitleField)
            top -= blockGap
        }

        let scroll = NSScrollView(frame: NSRect(x: insetX, y: insetY, width: layout.innerWidth, height: layout.bodyHeight))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = layout.rowsHeight > layout.bodyHeight + 0.5
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let document = CheatsheetColumnDocument(frame: NSRect(x: 0, y: 0, width: layout.innerWidth, height: layout.rowsHeight))
        let grid = NSGridView(frame: document.bounds)
        grid.translatesAutoresizingMaskIntoConstraints = true
        grid.autoresizingMask = [.width]
        grid.rowSpacing = 0
        grid.columnSpacing = columnGap
        for row in rows {
            let key = label(row.key, font: keyFont, color: .labelColor, alignment: .right)
            let action = label(row.action, font: actionFont, color: .labelColor, alignment: .left)
            let gridRow = grid.addRow(with: [key, action])
            gridRow.height = rowHeight
            gridRow.yPlacement = .fill
        }
        if grid.numberOfColumns > 1 {
            grid.column(at: 0).xPlacement = .fill
            grid.column(at: 0).width = layout.keyColumn
            grid.column(at: 1).xPlacement = .fill
            grid.column(at: 1).width = layout.actionColumn
        }
        document.addSubview(grid)
        scroll.documentView = document
        root.addSubview(scroll)
        return root
    }

    private func install(_ root: NSView, size: NSSize) {
        root.frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: root.frame)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = root
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: root.frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.autoresizesSubviews = true
            effect.addSubview(root)
            panel.contentView = effect
        }
    }
}

/// Starts scrolling at the top of the list; NSGridView itself stacks rows from the top.
private final class CheatsheetColumnDocument: NSView {
    override var isFlipped: Bool { true }
}
