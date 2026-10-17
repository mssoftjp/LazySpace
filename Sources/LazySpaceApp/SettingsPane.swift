import AppKit
import Copy

enum SettingsPane: String, CaseIterable {
    case general, layout, keys, apps, advanced, about

    var title: String {
        switch self {
        case .general: return L(.settingsPaneGeneral)
        case .layout: return L(.settingsPaneArrangement)
        case .keys: return L(.settingsPaneShortcuts)
        case .apps: return L(.settingsPaneApps)
        case .advanced: return L(.settingsPaneAdvanced)
        case .about: return L(.settingsPaneAbout)
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.2x2"
        case .keys: return "keyboard"
        case .apps: return "app.badge"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

}

/// Native controls with a consistent reading order, spacing, and scroll fallback.
enum SettingsPaneLayout {
    /// `flexible` takes the extra space: lowest hugging priority, while the others stay at their intrinsic height.
    static func sections(_ views: [NSView], spacing: CGFloat = 24, flexible: NSView? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            if view is NSButton {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if view === flexible {
                view.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
                view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            } else {
                view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            }
        }
        if flexible != nil {
            stack.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        }
        return stack
    }

    static func section(_ title: String?, _ views: [NSView], flexible: NSView? = nil) -> NSStackView {
        var content = views
        if let title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            content.insert(heading, at: 0)
        }
        return sections(content, spacing: 12, flexible: flexible)
    }

    /// Titles in the label column shared by General and Arrangement.
    static let formLabels: [LocalizedStringResource] = [
        .settingsWindowLanguage, .settingsWindowNotificationsTitle, .settingsWindowWindowSpacing, .settingsWindowPlaceNewWindows,
        .settingsWindowBorder, .settingsWindowBorderWidth, .settingsWindowBorderColor,
    ]

    /// That column's width, measured from every language's titles and capped at a wrapping width.
    static let formLabelWidth: CGFloat = SettingsForm.labelWidth(for: formLabels)

    static func centered(_ view: NSView, width: CGFloat = 480) -> NSView {
        let wrap = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        let preferred = view.widthAnchor.constraint(equalToConstant: width)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrap.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            view.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
            preferred,
        ])
        return wrap
    }

    static func scrolling(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        content.setContentCompressionResistancePriority(.required, for: .vertical)
        document.addSubview(content)
        let fill = document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        fill.identifier = "pane-fill"
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            fill,
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            // Measured from the scroll view, not the clip view: a scroll bar that takes width (a mouse attached)
            // narrows only the right margin when it appears, so centered forms do not shift sideways.
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -56),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        return scroll
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// In panes with a table, only the table stretches to the remaining height. Its intrinsic height is the minimum; the parent's constraints decide the rest.
class PaneScrollView: NSScrollView {
    var flexibleMinimum: CGFloat = 160

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: flexibleMinimum)
    }

    override var fittingSize: NSSize {
        var size = super.fittingSize
        size.height = flexibleMinimum
        return size
    }
}

/// Overlays the empty-state hint on the table. Intrinsic height is the inner scroll view's minimum, and it stretches with it.
final class FlexibleOverlay: NSView {
    let flexible: NSView

    init(flexible: NSView) {
        self.flexible = flexible
        super.init(frame: .zero)
        flexible.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flexible)
        NSLayoutConstraint.activate([
            flexible.topAnchor.constraint(equalTo: topAnchor),
            flexible.bottomAnchor.constraint(equalTo: bottomAnchor),
            flexible.leadingAnchor.constraint(equalTo: leadingAnchor),
            flexible.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let height = flexible.intrinsicContentSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: height > 1 ? height : 160)
    }
}

/// A borderless button drawn as a hyperlink, with the pointing-hand cursor.
final class LinkButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        setAccessibilityRole(.link)
    }

    /// Lines the text up with the labels around it; the cell pads the title on both sides.
    override var alignmentRectInsets: NSEdgeInsets {
        let padding = max(0, ((cell?.cellSize.width ?? 0) - attributedTitle.size().width) / 2)
        return NSEdgeInsets(top: 0, left: padding, bottom: 0, right: padding)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A table with rounded corners and a 1 px separator-colored outline, without a border type.
final class InsetTableScrollView: PaneScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateInsetBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInsetBorder()
    }

    override func updateLayer() {
        super.updateLayer()
        updateInsetBorder()
    }

    private func updateInsetBorder() {
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// Right-aligned label column and control column. Checkboxes go in the control column, with explanations aligned to their titles.
final class SettingsForm: NSView {
    static let width: CGFloat = 640
    let grid = NSGridView()
    private let labelColumnWidth: CGFloat
    private var columnsConfigured = false

    /// Measures titles in every language: 132 for short columns, wrapping at 220 even for long titles.
    static func labelWidth(for titles: [LocalizedStringResource]) -> CGFloat {
        min(220, titles.flatMap { title in Language.allCases.map { measured(titled(L(title, in: $0), in: $0)) } }.reduce(132, max))
    }

    /// Width a label needs at the form's font, with its margin.
    static func measured(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 12
    }

    init(labelWidth: CGFloat) {
        labelColumnWidth = labelWidth
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Control column width: what remains after the label column and spacing. Explanations wrap within it.
    var controlColumnWidth: CGFloat { Self.width - labelColumnWidth - grid.columnSpacing }

    @discardableResult
    func addLabeled(_ title: String, _ control: NSView) -> NSGridRow {
        add(Self.trailingLabel(Self.titled(title)), control)
    }

    @discardableResult
    func addPlain(_ control: NSView) -> NSGridRow {
        add(NSView(), control)
    }

    /// The title with the language's colon, unless it already ends with one.
    static func titled(_ title: String, in language: Language = Copy.language) -> String {
        if [":", L(.settingsLabelColon(""), in: language)].contains(where: title.hasSuffix) { return title }
        return L(.settingsLabelColon(title), in: language)
    }

    static func trailingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.alignment = .right
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Explanations align with the title text, not the checkbox, and wrap at the control column's right edge.
    static func checkboxColumn(_ box: NSButton, explanation: String?, columnWidth: CGFloat) -> NSView {
        box.lineBreakMode = .byWordWrapping
        (box.cell as? NSButtonCell)?.wraps = true
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard let explanation else { return box }
        let caption = NSTextField.settingsText(explanation)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 0
        caption.cell?.wraps = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let host = NSView()
        caption.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(caption)
        let inset = titleInset(of: box)
        caption.preferredMaxLayoutWidth = max(40, columnWidth - inset)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            caption.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            caption.topAnchor.constraint(equalTo: host.topAnchor),
            caption.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        let stack = NSStackView(views: [box, host])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        // The pair is fixed to the control column width (sizing by the explanation or label could wrap a label that fits).
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        host.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        box.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        return stack
    }

    static func titleInset(of box: NSButton) -> CGFloat {
        guard let cell = box.cell as? NSButtonCell else { return 18 }
        let title = cell.titleRect(forBounds: NSRect(x: 0, y: 0, width: 480, height: 22))
        if title.minX > 8, title.minX < 36 { return title.minX }
        return 18
    }

    private func add(_ label: NSView, _ control: NSView) -> NSGridRow {
        let row = grid.addRow(with: [label, control])
        row.rowAlignment = .firstBaseline
        // Columns do not exist until a row is added; column(at:) before that crashes.
        if !columnsConfigured {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = labelColumnWidth
            grid.column(at: 1).xPlacement = .leading
            grid.column(at: 1).width = controlColumnWidth
            columnsConfigured = true
        }
        return row
    }
}

extension NSTextField {
    /// Explanation and status text in Settings. Read-only, so not selectable with the mouse (callers re-enable it where needed).
    static func settingsText(_ string: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.isSelectable = false
        return field
    }
}
