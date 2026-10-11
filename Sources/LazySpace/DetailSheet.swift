import AppKit
import Copy
import Foundation

/// Shows long text as selectable text with a bounded width and height.
enum DetailSheet {
    struct Choice: Equatable {
        enum Kind: Equatable {
            case close
            case openGeneralSettings
            case openSettings
        }
        var kind: Kind
        var title: String
    }

    static var closeChoice: Choice { Choice(kind: .close, title: L("Close", "閉じる")) }

    static func response(for index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    static func assemble(title: String, body: String, choices: [Choice]) -> (alert: NSAlert, actions: [NSApplication.ModalResponse: Choice.Kind]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textWidth = max(scroll.contentSize.width, 1)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: scroll.contentSize.height))
        textView.autoresizingMask = .width
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.string = body
        scroll.documentView = textView
        alert.accessoryView = scroll
        var actions: [NSApplication.ModalResponse: Choice.Kind] = [:]
        for (index, choice) in choices.enumerated() {
            let button = alert.addButton(withTitle: choice.title)
            if choice.kind != .close { button.keyEquivalent = "" }
            actions[response(for: index)] = choice.kind
        }
        alert.layout()
        if choices.first?.kind == .close, let close = alert.buttons.first {
            close.keyEquivalent = "\r"
            alert.window.defaultButtonCell = close.cell as? NSButtonCell
        }
        return (alert, actions)
    }

    /// Returns Close for an unmodified Escape only when the event's window or the key window is this sheet.
    static func escapeResponse(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        eventWindow: NSWindow?,
        keyWindow: NSWindow?,
        sheet: NSWindow,
        close: NSApplication.ModalResponse
    ) -> NSApplication.ModalResponse? {
        let held = modifiers.intersection(.deviceIndependentFlagsMask)
        if held.contains(.command) || held.contains(.shift) || held.contains(.option) || held.contains(.control) {
            return nil
        }
        guard keyCode == 53 || characters == "\u{1b}" else { return nil }
        if let eventWindow { return eventWindow === sheet ? close : nil }
        return keyWindow === sheet ? close : nil
    }

    static func present(title: String, body: String, choices: [Choice], on window: NSWindow, perform: @escaping (Choice.Kind) -> Void) {
        let sheet = assemble(title: title, body: body, choices: choices)
        let closeResponse = sheet.actions.first { $0.value == .close }?.key
        let monitor = SheetKeyMonitor()
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let closeResponse else { return event }
            let sheetWindow = sheet.alert.window
            guard let response = escapeResponse(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                eventWindow: event.window,
                keyWindow: NSApp.keyWindow,
                sheet: sheetWindow,
                close: closeResponse) else { return event }
            let parent = sheetWindow.sheetParent ?? window
            parent.endSheet(sheetWindow, returnCode: response)
            return nil
        }
        sheet.alert.beginSheetModal(for: window) { response in
            monitor.invalidate()
            guard let kind = sheet.actions[response] else { return }
            perform(kind)
        }
    }
}

/// Watches Escape only while the sheet is shown.
private final class SheetKeyMonitor {
    var token: Any?
    func invalidate() {
        if let token { NSEvent.removeMonitor(token) }
        self.token = nil
    }
    deinit { invalidate() }
}
