import AppKit

/// Standard macOS alerts for an update session, one at a time. They are not modal, so arranging keeps running while one is open.
final class UpdateAlerts: NSObject, UpdateDialogs {
    private let currentVersion: String
    private(set) var alert: NSAlert?
    /// The shown alert's button actions, by button tag.
    private var actions: [() -> Void] = []
    /// Whether a button closes the alert before its action runs; Quit and Install keeps it while LazySpace quits.
    private var closesOnPress = true
    private var step: UpdateStep?
    private var bar: NSProgressIndicator?
    /// Puts an alert on screen; tests replace it so that no window appears.
    var present: (NSAlert) -> Void = { alert in
        // A menu-bar app is not active when its menu or Settings is used; the alert must come to the front.
        NSApp.activate(ignoringOtherApps: true)
        if !alert.window.isVisible { alert.window.center() }
        alert.window.makeKeyAndOrderFront(nil)
    }

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func ask(_ offer: UpdateOffer, canSkip: Bool, reply: @escaping (UpdateChoice) -> Void) {
        var buttons: [(title: String, key: String, action: () -> Void)] = [
            (UpdateCopy.install, "\r", { reply(.install) }),
            (UpdateCopy.later, "\u{1b}", { reply(.later) }),
        ]
        if canSkip { buttons.append((UpdateCopy.skip, "", { reply(.skip) })) }
        show(title: UpdateCopy.available(offer), detail: UpdateCopy.askDetail(current: currentVersion), buttons: buttons)
    }

    /// Creating the alert brings it forward once; later steps update it in place, so switching to another app while it
    /// downloads stays there.
    func progress(_ step: UpdateStep, action: (() -> Void)?) {
        let created = self.step == nil || alert == nil
        if created {
            show(title: "", detail: "", buttons: [("", "", {})], presenting: false)
            let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            self.bar = bar
        }
        guard let alert, let button = alert.buttons.first, let bar else { return }
        let waiting = step == .waitingToQuit
        actions = [action ?? {}]
        closesOnPress = !waiting
        button.isEnabled = action != nil
        if case .downloading(let fraction?) = step {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            // Nothing measurable: checking, preparing, and installing move; waiting does not.
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        // Only a new kind of step changes the text; download chunks only move the bar.
        guard created || !Self.sameKind(step, self.step) else { return }
        self.step = step
        alert.messageText = UpdateCopy.title(step)
        alert.informativeText = UpdateCopy.detail(step)
        button.title = waiting ? UpdateCopy.quitAndInstall : UpdateCopy.cancel
        button.keyEquivalent = waiting ? "\r" : "\u{1b}"
        alert.accessoryView = waiting ? nil : bar
        alert.layout()
        if created { present(alert) }
    }

    private static func sameKind(_ a: UpdateStep, _ b: UpdateStep?) -> Bool {
        switch (a, b) {
        case (.downloading, .downloading?): true
        default: a == b
        }
    }

    func tell(title: String, detail: String, done: @escaping () -> Void) {
        show(title: title, detail: detail, buttons: [(UpdateCopy.ok, "\r", done)])
    }

    func bringToFront() {
        if let alert { present(alert) }
    }

    func close() {
        alert?.window.orderOut(nil)
        alert = nil
        actions = []
        step = nil
        bar = nil
    }

    /// Replaces any shown alert.
    private func show(title: String, detail: String, buttons: [(title: String, key: String, action: () -> Void)], presenting: Bool = true) {
        close()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        for (index, entry) in buttons.enumerated() {
            let button = alert.addButton(withTitle: entry.title)
            button.keyEquivalent = entry.key
            button.tag = index
            button.target = self
            button.action = #selector(pressed(_:))
        }
        actions = buttons.map(\.action)
        closesOnPress = true
        self.alert = alert
        guard presenting else { return }
        alert.layout()
        present(alert)
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        if closesOnPress { close() }
        action()
    }
}
