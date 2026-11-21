import AppKit
import Copy
import Settings

/// When the shortcut list opens: after a set of modifiers is held, with nothing else pressed, for the wait.
/// In main, only for a set some shortcut uses exactly, so ⇧ held while typing or ⌘ before another app's shortcut shows nothing;
/// in another mode, whose keys may have no modifier, for any held modifier.
struct CheatsheetHold {
    enum Step: Equatable { case wait, hide }
    /// The modifiers last held, as Carbon modifiers.
    private(set) var held: UInt32 = 0
    private var inputCount: UInt64 = 0

    /// A change of the held modifiers, with the input count read along with it. `.hide` also hides a list already shown.
    mutating func modifiersChanged(to held: UInt32, inputCount: UInt64, mode: String, bindings: [HotkeyBinding]) -> Step {
        self.held = held
        self.inputCount = inputCount
        return Self.applies(held: held, mode: mode, bindings: bindings) ? .wait : .hide
    }

    /// When the wait ends: only if no key, click, drag, or scroll came meanwhile, and the set still applies to the current mode and shortcuts.
    func showsAfterWait(inputCount: UInt64, mode: String, bindings: [HotkeyBinding]) -> Bool {
        inputCount == self.inputCount && Self.applies(held: held, mode: mode, bindings: bindings)
    }

    static func applies(held: UInt32, mode: String, bindings: [HotkeyBinding]) -> Bool {
        guard held != 0, !bindings.isEmpty else { return false }
        if mode != Config.mainModeName { return true }
        return bindings.contains { $0.modifiers == held }
    }

    /// Carbon modifiers as the configuration's modifier names.
    static func modifierNames(_ carbon: UInt32) -> Set<String> {
        var names = Set<String>()
        if carbon & 0x0800 != 0 { names.insert("alt") }
        if carbon & 0x0200 != 0 { names.insert("shift") }
        if carbon & 0x1000 != 0 { names.insert("ctrl") }
        if carbon & 0x0100 != 0 { names.insert("cmd") }
        return names
    }

    /// The held modifiers as Carbon modifiers, the form `HotkeyBinding.modifiers` uses.
    static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskAlternate) { m |= 0x0800 }
        if flags.contains(.maskShift) { m |= 0x0200 }
        if flags.contains(.maskControl) { m |= 0x1000 }
        if flags.contains(.maskCommand) { m |= 0x0100 }
        return m
    }
}

/// How the shortcut list groups a mode's shortcuts: one section per set of modifiers, with runs on one row.
enum CheatsheetLayout {
    struct Row: Equatable {
        var keys: String
        var label: String
        /// How many shortcuts the row stands for.
        var commands: Int
    }

    struct Section: Equatable {
        var modifiers: Set<String>
        /// The set's glyphs in macOS order (⌃⌥⇧⌘); empty for keys without a modifier.
        var heading: String
        var rows: [Row]
    }

    private static let directions = ["left", "down", "up", "right"]
    /// Spacing between the key glyphs of a run ("H J K L"): an en space, a typographic gap between key symbols, not a join of sentences.
    private static let keyGap = "\u{2002}"
    private static let directionLabels: [String: () -> String] = [
        "focus": { L(.keyCheatsheetFocusEachDirection) },
        "move": { L(.keyCheatsheetReorderEachDirection) },
        "swap": { L(.keyCheatsheetSwapEachDirection) },
    ]
    /// Desktop commands that take a number, longest prefix first.
    private static let desktopPrefixes = ["move-to-space-follow-", "move-to-space-", "space-"]

    static func sections(_ config: Config, mode: String) -> [Section] {
        guard let keys = config.keys(forMode: mode) else { return [] }
        let usable = keys.filter { HotkeyBinding.action(forCommand: $0.key) != nil }
        let order = Dictionary(config.allCommandNames.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: usable, by: { $0.value.modifiers })
        return groups.keys.sorted(by: setPrecedes).map { modifiers in
            let section = Dictionary(uniqueKeysWithValues: groups[modifiers, default: []].map { ($0.key, $0.value) })
            let names = section.keys.sorted { (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1) }
            var rows: [Row] = []
            var done = Set<String>()
            for name in names where !done.contains(name) {
                if let (row, used) = directionRun(name, in: section) ?? desktopRun(name, in: section, config: config) {
                    rows.append(row)
                    done.formUnion(used)
                } else {
                    rows.append(Row(keys: glyph(section[name]!), label: label(name, config), commands: 1))
                    done.insert(name)
                }
            }
            return Section(modifiers: modifiers, heading: Config.Key(modifiers: modifiers, key: "").display, rows: rows)
        }
    }

    /// Keys without a modifier first; then by size, and among equal sizes by ⇧, ⌃, ⌘.
    private static func setPrecedes(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let weight = ["alt": 0, "shift": 1, "ctrl": 2, "cmd": 3]
        let wa = a.map { weight[$0] ?? 9 }.sorted(), wb = b.map { weight[$0] ?? 9 }.sorted()
        return wa.count != wb.count ? wa.count < wb.count : wa.lexicographicallyPrecedes(wb)
    }

    private static func glyph(_ key: Config.Key) -> String { Config.Key(modifiers: [], key: key.key).display }

    private static func label(_ name: String, _ config: Config) -> String {
        guard var action = HotkeyBinding.action(forCommand: name) else { return name }
        if case .edit(let command) = action { action = .edit(command.following(config.followMovedWindow)) }
        return HotkeyBinding(keyCode: 0, modifiers: 0, action: action, display: "").label
    }

    /// Left, down, up, right of one command, when all four are in this set.
    private static func directionRun(_ name: String, in section: [String: Config.Key]) -> (Row, Set<String>)? {
        guard name.hasSuffix("-left") else { return nil }
        let prefix = String(name.dropLast("-left".count))
        guard let text = directionLabels[prefix] else { return nil }
        let names = directions.map { "\(prefix)-\($0)" }
        let keys = names.compactMap { section[$0] }
        guard keys.count == names.count else { return nil }
        return (Row(keys: keys.map(glyph).joined(separator: keyGap), label: text(), commands: names.count), Set(names))
    }

    /// Three or more consecutive desktops of one command whose desktop N is on key N.
    private static func desktopRun(_ name: String, in section: [String: Config.Key], config: Config) -> (Row, Set<String>)? {
        guard let prefix = desktopPrefixes.first(where: { name.hasPrefix($0) }), let first = Int(name.dropFirst(prefix.count)) else { return nil }
        func onOwnKey(_ n: Int) -> Bool { section["\(prefix)\(n)"]?.key == String(n) }
        guard onOwnKey(first), !onOwnKey(first - 1) else { return nil }
        var last = first
        while onOwnKey(last + 1) { last += 1 }
        guard last - first + 1 >= 3 else { return nil }
        let desktops = Copy.desktops(first, last)
        let text: String
        switch prefix {
        case "space-": text = L(.editCommandsSwitchTo(desktops))
        case "move-to-space-": text = config.followMovedWindow ? L(.editCommandsMoveWindowToAndFollow(desktops)) : L(.editCommandsSendWindowTo(desktops))
        default: text = L(.editCommandsMoveWindowToAndFollow(desktops))
        }
        return (Row(keys: Copy.numberRange(String(first), String(last)), label: text, commands: last - first + 1),
                Set((first...last).map { "\(prefix)\($0)" }))
    }
}

/// Shows the current mode's keys while a modifier is held. Never takes focus.
/// Backed by the system glass.
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

    var isVisible: Bool { panel.isVisible }

    /// Shows the list, grouped by set of modifiers (`CheatsheetLayout`), with the `held` set (Carbon modifiers) drawn darker than the others.
    func show(config: Config, mode: String, held: UInt32) {
        let visible = Self.screen(containing: NSEvent.mouseLocation)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        guard let (root, size) = Self.content(config: config, mode: mode, held: held, visible: visible) else { hide(); return }
        panel.title = Self.brandTitle
        install(root, size: size)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - Self.screenInset)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// The list's content view and size, without the panel; tests lay it out in every language.
    static func content(config: Config, mode: String, held: UInt32, visible: NSRect) -> (NSView, NSSize)? {
        let sections = CheatsheetLayout.sections(config, mode: mode)
        guard !sections.isEmpty else { return nil }
        let heldNames = CheatsheetHold.modifierNames(held)
        let emphasis = sections.contains { $0.modifiers == heldNames }
        var lines: [Line] = []
        for section in sections {
            if !section.heading.isEmpty { lines.append(.heading(section.heading)) }
            let dim = emphasis && section.modifiers != heldNames
            lines += section.rows.map { .row(keys: $0.keys, label: $0.label, dim: dim) }
        }
        let title = brandTitle, subtitle = modeSubtitle(mode)
        let layout = measure(title: title, subtitle: subtitle, lines: lines, visible: visible)
        return (makeRoot(title: title, subtitle: subtitle, lines: lines, layout: layout), layout.size)
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

    private enum Line {
        case heading(String)
        case row(keys: String, label: String, dim: Bool)
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
    private static let rowHeight: CGFloat = 22
    private static let headingHeight: CGFloat = 22
    private static let headingFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let columnGap: CGFloat = 16
    private static let insetX: CGFloat = 16
    private static let insetY: CGFloat = 14
    private static let blockGap: CGFloat = 8
    /// The list may take up to this share of the screen's height, and scrolls beyond it.
    private static let maxScreenShare: CGFloat = 0.7
    private static let screenInset: CGFloat = 24
    private static let cornerRadius: CGFloat = 18
    private static let scrollerReserve: CGFloat = 14

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func labelWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(label(text, font: font, color: .labelColor, alignment: .left).cell?.cellSize.width ?? textWidth(text, font: font))
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    private static func measure(title: String, subtitle: String?, lines: [Line], visible: NSRect) -> Measure {
        let titleHeight = lineHeight(titleFont)
        let subtitleHeight = subtitle == nil ? 0 : lineHeight(subtitleFont)
        let gaps = blockGap + (subtitle == nil ? 0 : blockGap)
        let header = insetY + titleHeight + gaps + subtitleHeight
        let rowsHeight = lines.reduce(CGFloat(0)) { total, line in
            if case .heading = line { return total + headingHeight } else { return total + rowHeight }
        }
        let screenHeight = max(header + rowHeight + insetY, visible.height - screenInset * 2)
        let height = min(header + rowsHeight + insetY, min(visible.height * maxScreenShare, screenHeight))
        let bodyHeight = max(rowHeight, height - header - insetY)
        let scrolls = rowsHeight > bodyHeight + 0.5
        let scroller = scrolls ? scrollerReserve : 0
        let rows = lines.compactMap { line -> (String, String)? in if case .row(let keys, let label, _) = line { return (keys, label) } else { return nil } }
        // A label's cell adds its own padding to the text, so the columns are measured as the labels themselves.
        let keyWidth = rows.map { labelWidth($0.0, font: keyFont) }.max() ?? 0
        let actionWidth = rows.map { labelWidth($0.1, font: actionFont) }.max() ?? 0
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

    private static func makeRoot(title: String, subtitle: String?, lines: [Line], layout: Measure) -> NSView {
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
        for line in lines {
            switch line {
            case .heading(let text):
                let heading = label(text, font: headingFont, color: .secondaryLabelColor, alignment: .left)
                let gridRow = grid.addRow(with: [heading, NSGridCell.emptyContentView])
                gridRow.mergeCells(in: NSRange(location: 0, length: 2))
                gridRow.height = headingHeight
                gridRow.yPlacement = .bottom
            case .row(let keys, let text, let dim):
                let color: NSColor = dim ? .secondaryLabelColor : .labelColor
                let key = label(keys, font: keyFont, color: color, alignment: .right)
                let action = label(text, font: actionFont, color: color, alignment: .left)
                let gridRow = grid.addRow(with: [key, action])
                gridRow.height = rowHeight
                gridRow.yPlacement = .fill
            }
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
        let glass = NSGlassEffectView(frame: root.frame)
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = root
        panel.contentView = glass
    }
}

/// Starts scrolling at the top of the list; NSGridView itself stacks rows from the top.
private final class CheatsheetColumnDocument: NSView {
    override var isFlipped: Bool { true }
}
