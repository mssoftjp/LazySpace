import AppKit
import Copy
import Settings

final class RuleTextField: NSTextField {
    var ruleIndex = -1
}

final class FocusingSearchField: NSSearchField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// Value text takes no clicks; the table handles row selection.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ShortcutTable: NSTableView {
    var onDelete: (() -> Void)?
    var onRestore: (() -> Void)?
    var onReturn: (() -> Void)?

    /// Only the popup takes clicks before the table's selection.
    /// Everything else, including the value cell, goes to the table, so the first click only selects.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let deeper = super.hitTest(point) else { return nil }
        var view: NSView? = deeper
        while let current = view, current !== self {
            if current is NSPopUpButton { return current }
            view = current.superview
        }
        return self
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcutMods = mods.intersection([.command, .shift, .option, .control])
        if shortcutMods == .option, event.keyCode == 51 || event.keyCode == 117 {
            if !event.isARepeat { onRestore?() }
            return
        }
        let bare = shortcutMods.isEmpty
        // Key repeats and Delete / Return with other modifiers are not table actions.
        if bare, !event.isARepeat {
            switch event.keyCode {
            case 51, 117: onDelete?(); return
            case 36, 76: onReturn?(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// Action name and a picture of what it does.
final class ShortcutActionCell: NSTableCellView {
    let pictogramView = ActionPictogramView()

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            pictogramView.emphasized = backgroundStyle == .emphasized
            textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        pictogramView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pictogramView)
        addSubview(label)
        NSLayoutConstraint.activate([
            pictogramView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pictogramView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pictogramView.widthAnchor.constraint(equalToConstant: 28),
            pictogramView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: pictogramView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Right inset of values; direction popups use the same inset.
enum ShortcutColumnMetrics {
    static let trailingInset: CGFloat = 6
    static let recorderWidth: CGFloat = 110

    static let minimumColumnWidth: CGFloat = 120

    /// The recording box: 110 pt, or wider when the language's prompt needs it (with the label's 6 pt inset on each side).
    static func recorderWidth(for prompt: String, font: NSFont) -> CGFloat {
        max(recorderWidth, promptWidth(prompt, font: font) + 12)
    }

    /// The Shortcut column's narrowest width: 120 pt, or the prompt with its insets and the box's 6 pt margins.
    static func minimumColumnWidth(for prompt: String, font: NSFont) -> CGFloat {
        max(minimumColumnWidth, promptWidth(prompt, font: font) + 24)
    }

    private static func promptWidth(_ prompt: String, font: NSFont) -> CGFloat {
        let label = NSTextField(labelWithString: prompt)
        label.font = font
        return ceil(label.cell?.cellSize.width ?? 0)
    }
}

/// Selection inset from the row edges with rounded corners. Not used for group rows.
final class InsetSelectionRowView: NSTableRowView {
    static let horizontalInset: CGFloat = 10
    static let cornerRadius: CGFloat = 5

    var selectionRect: NSRect {
        bounds.insetBy(dx: Self.horizontalInset, dy: 0)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = selectionRect
        guard rect.width > 1, rect.height > 1 else { return }
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        color.setFill()
        path.fill()
    }
}

/// A direction group. Right edge aligned with value labels; text turns white when selected.
final class DirectionShortcutCell: NSTableCellView {
    private let stack = NSStackView()
    private var popups: [NSPopUpButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShortcutColumnMetrics.trailingInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPopups(_ popups: [NSPopUpButton]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        self.popups = popups
        for popup in popups {
            popup.controlSize = .regular
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 13)
            popup.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(popup)
        }
        applyTitleColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTitleColor() }
    }

    override func viewWillDraw() {
        applyTitleColor()
        super.viewWillDraw()
    }

    /// Colors only the button's title for selection, not the menu items.
    private func applyTitleColor() {
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let font = NSFont.systemFont(ofSize: 13)
        for popup in popups {
            popup.contentTintColor = color
            popup.font = font
            let title = popup.titleOfSelectedItem ?? ""
            popup.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: color,
                .font: font,
            ])
        }
    }
}

/// Shortcut column. Plain and right-aligned when idle; draws a field-like box only while recording.
final class ShortcutValueCell: NSTableCellView {
    var commandName = ""
    var actionLabel = ""
    var canRemove = false
    var canRestore = false
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?
    var onRestore: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var recording = false
    private var shown = ""
    let valueLabel = PassthroughLabel(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.alignment = .right
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.isBezeled = false
        valueLabel.drawsBackground = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.refusesFirstResponder = true
        valueLabel.setAccessibilityElement(false)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        textField = valueLabel
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAssignment(display: String?, recording: Bool) {
        self.recording = recording
        shown = display ?? ""
        valueLabel.stringValue = recording && shown.isEmpty ? L(.settingsControlsTypeShortcut) : shown
        applyRecordingColors()
        setAccessibilityLabel(accessibilityLabel())
        setAccessibilityValue(accessibilityValue())
        setAccessibilityHelp(accessibilityHelp())
        needsLayout = true
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyRecordingColors() }
    }

    override func layout() {
        super.layout()
        let h = valueLabel.intrinsicContentSize.height
        if recording {
            let box = recorderBox
            valueLabel.frame = NSRect(
                x: box.minX + 6,
                y: (box.midY - h / 2).rounded(),
                width: max(0, box.width - 12),
                height: h
            )
        } else {
            valueLabel.frame = NSRect(
                x: 4,
                y: (bounds.midY - h / 2).rounded(),
                width: max(0, bounds.width - 4 - ShortcutColumnMetrics.trailingInset),
                height: h
            )
        }
    }

    override func viewWillDraw() {
        applyRecordingColors()
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard recording else { return }
        let box = recorderBox
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { actionLabel }
    override func accessibilityHelp() -> String? {
        if recording {
            return L(.settingsControlsRecordingAShortcutPressEsc)
        }
        return L(.settingsControlsDoubleClickOrPressReturn)
    }
    override func accessibilityValue() -> Any? {
        if recording { return shown.isEmpty ? L(.settingsControlsTypeShortcut) : shown }
        return shown.isEmpty ? L(.settingsControlsUnassigned) : shown
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        if recording {
            actions.append(NSAccessibilityCustomAction(name: L(.settingsControlsCancelRecording)) { [weak self] in
                self?.onCancel?()
                return true
            })
        } else {
            actions.append(NSAccessibilityCustomAction(name: L(.settingsControlsChangeShortcut)) { [weak self] in
                self?.onChange?()
                return true
            })
        }
        if canRemove {
            actions.append(NSAccessibilityCustomAction(name: L(.settingsControlsRemoveShortcut)) { [weak self] in
                self?.onRemove?()
                return true
            })
        }
        if canRestore {
            actions.append(NSAccessibilityCustomAction(name: L(.settingsControlsRestoreDefault)) { [weak self] in
                self?.onRestore?()
                return true
            })
        }
        return actions
    }

    /// The recording box, at the row's right edge. Long keys are clipped inside it; the prompt always fits.
    var recorderBox: NSRect {
        let wanted = ShortcutColumnMetrics.recorderWidth(for: L(.settingsControlsTypeShortcut), font: valueLabel.font ?? .systemFont(ofSize: 13))
        let width = min(wanted, max(0, bounds.width - 12))
        return NSRect(
            x: bounds.maxX - ShortcutColumnMetrics.trailingInset - width,
            y: max(0, (bounds.height - 20) / 2),
            width: width,
            height: 20
        )
    }

    /// Recording text is colored for the box background; the idle selection color is left to the table.
    private func applyRecordingColors() {
        guard recording else { return }
        valueLabel.cell?.backgroundStyle = .normal
        valueLabel.textColor = shown.isEmpty ? .placeholderTextColor : .labelColor
    }
}
