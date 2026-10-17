import AppKit
import Copy
import Foundation
import MacSupport
import Operations
import Settings

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var ready: ReadyWindowController?
    private var hotkeys: Hotkeys?
    private var recordingShortcut = false
    private let focusBorder = FocusBorder()
    private let coordinator: Coordinator
    private let receipts: MutationReceiptRegistry
    private var inspectionResponses: [String: ControlPort.Response] = [:]
    private var inspectionOrder: [String] = []
    private let showReadyAtLaunch: Bool
    private var spaceToken: NSObjectProtocol?
    private var screenToken: NSObjectProtocol?
    /// The one pending later reading of the menu bar number.
    private var statusReread: DispatchWorkItem?
    private var trustToken: NSObjectProtocol?
    private weak var trackedMenu: NSMenu?
    private var menuRefreshTimer: Timer?
    private static let accessPromptedKey = "access.prompted"
    /// Set by `main.swift`, the only place that knows Sparkle; nil in tests. Called once after launch.
    var makeUpdates: (() -> UpdateChecking?)?
    private var updates: UpdateChecking?

    init(showReadyAtLaunch: Bool, coordinator: Coordinator = .shared, receipts: MutationReceiptRegistry = MutationReceiptRegistry()) {
        self.showReadyAtLaunch = showReadyAtLaunch
        self.coordinator = coordinator
        self.receipts = receipts
        coordinator.onOperationID = { [receipts] id in receipts.claim(id) }
        coordinator.onTerminalResult = { [receipts] result in receipts.absorb(result) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let settings else { return .terminateNow }
        return settings.resolveLeave() ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = StatusMenuCopy.statusItemToolTip
        refreshStatusItem()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !ControlPort.startServer(handler: { [weak self] req in self?.handle(req) ?? ControlPort.Response(ok: false, message: L("LazySpace is not available.", "LazySpaceを利用できません。"), code: "internal-error") }) {
            NSLog("LazySpace: CLI control port unavailable; check the owner and permissions of the application support directory.")
        }
        hotkeys = Hotkeys(bindings: HotkeyBinding.from(coordinator.config, mode: coordinator.mode)) { [weak self] action, source, pressedAt in
            self?.perform(action, source: source, pressedAt: pressedAt)
        }
        _ = hotkeys?.register()
        syncCommandKeys()
        coordinator.system.input.onFlagsChanged = { [weak self] flags in self?.scheduleCheatsheet(flags) }
        focusBorder.apply(coordinator.config.focusBorder)
        coordinator.onFocusFrame = { [weak self] frame in self?.focusBorder.show(around: frame) }
        coordinator.onConfigChange = { [weak self] config in
            self?.focusBorder.apply(config.focusBorder)
            if !config.showShortcutGuide { self?.hideCheatsheet() }
            self?.reregisterHotkeys()
            // If Settings is open, follow the active configuration (unsaved draft changes are kept).
            if let settings = self?.settings, settings.window?.isVisible == true { settings.refresh() }
        }
        coordinator.onConfigStatus = { [weak self] error in
            guard let settings = self?.settings, settings.window?.isVisible == true else { return }
            settings.applyConfigStatus(error, isError: self?.coordinator.configError != nil)
        }
        coordinator.onModeChange = { [weak self] _ in self?.reregisterHotkeys() }
        coordinator.onTrustChange = { [weak self] trusted in self?.trustChanged(trusted) }
        // Right after the permission changes, the old value may be returned, so reread after a short delay.
        trustToken = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.coordinator.checkTrust() }
        }
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusItem()
        }
        // Connecting or disconnecting a display changes how many numbers there are; its name can be readable only a moment later.
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusItem()
            self?.scheduleStatusReread()
        }

        let previousOnChange = coordinator.onChange
        coordinator.onChange = { [weak self] in
            previousOnChange?()
            self?.ready?.refreshLabels()
            self?.refreshStatusItem()
        }

        // Before Settings can open, so it shows the update section from the start.
        updates = makeUpdates?()
        // Windows never move at launch. Without permission, Settings > General asks for it; the system dialog appears only once.
        // With permission, show the window list if setup is needed or on first launch.
        let s = coordinator.status()
        if !s.trusted {
            if !UserDefaults.standard.bool(forKey: Self.accessPromptedKey) {
                UserDefaults.standard.set(true, forKey: Self.accessPromptedKey)
                AXTrust.requestPrompt()
            }
            showSettings(pane: .general)
            if showReadyAtLaunch { showReady() }
        } else if showReadyAtLaunch || !s.manualAvailable || !coordinator.state.firstLaunchDone {
            showReady()
        }
    }

    /// Actions from shortcuts and the menu. After one command in a mode, returns to main (as configured).
    private func perform(_ action: HotkeyBinding.Action, source: String, pressedAt: Date = Date()) {
        hideCheatsheet()
        switch action {
        case .edit(let command): runEdit(command, source: source, pressedAt: pressedAt)
        case .arrange: coordinator.markFirstLaunchDone(); coordinator.arrange(source: source, pressedAt: pressedAt)
        case .integrate:
            // Nothing on screen; the reason stays in `lazyspace status` as the latest notice.
            if coordinator.waiting.isEmpty { coordinator.noteRefusal(L("No windows are waiting.", "待機中のウインドウはありません。")); return }
            if case .notApplicable = coordinator.integrateWaiting(source: source, pressedAt: pressedAt) { coordinator.noteRefusal(coordinator.notStartedMessage) }
        case .pauseResume:
            if coordinator.control.paused { coordinator.resume() } else { coordinator.pause() }
        case .reload: coordinator.reportReload(source: source)
        case .mode(let name):
            if case .refused(let why) = coordinator.setMode(name, source: source) { coordinator.noteRefusal(why) }
            return
        }
        if coordinator.shouldReturnToMainAfterCommand { coordinator.setMode(Config.mainModeName, source: "auto-return") }
    }

    /// Lets tests run a command through the same path as a registered shortcut.
    func testingPerformHotkey(_ action: HotkeyBinding.Action, source: String = "hotkey") {
        perform(action, source: source)
    }

    /// Switches to the current mode's shortcuts and shows the mode name in the status item.
    private func reregisterHotkeys() {
        guard let hotkeys, !recordingShortcut else { return }
        let mode = coordinator.mode
        _ = hotkeys.replace(HotkeyBinding.from(coordinator.config, mode: mode))
        syncCommandKeys()
        if !hotkeys.failed.isEmpty { coordinator.noteRefusal(L("Could not register these shortcuts: \(hotkeys.failed.joined(separator: ", "))", "登録できなかったショートカット: \(hotkeys.failed.joined(separator: ", "))")) }
        refreshStatusItem()
    }

    /// The menu bar shows the split icon and the desktop number (per display when there are several), plus the mode name in text for modes other than main.
    /// `reread`: the one later reading after a `–`; it never schedules another (a full-screen Space keeps its `–`).
    private func refreshStatusItem(reread: Bool = false) {
        if statusItem.button?.image == nil {
            statusItem.button?.image = StatusItemIcon.image
            statusItem.button?.imagePosition = .imageLeading
        }
        let number = StatusMenuCopy.barNumber(coordinator.spaceList())
        statusItem.button?.title = StatusMenuCopy.barTitle(mode: coordinator.mode, space: number)
        // A display's shown Space can be unreadable for a moment; read once more shortly after.
        if !reread, number?.contains("–") == true { scheduleStatusReread() }
    }

    private func scheduleStatusReread() {
        statusReread?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshStatusItem(reread: true) }
        statusReread = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Holding a modifier for about 0.8 s shows the current mode's key list.
    private func scheduleCheatsheet(_ flags: CGEventFlags) {
        modifierHold?.cancel()
        cheatsheetGeneration &+= 1
        let held = flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        guard coordinator.config.showShortcutGuide, !recordingShortcut, !held.isEmpty else { cheatsheet.hide(); return }
        let generation = cheatsheetGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.cheatsheetGeneration,
                  self.coordinator.config.showShortcutGuide, !self.recordingShortcut else { return }
            self.cheatsheet.show(config: self.coordinator.config, mode: self.coordinator.mode)
        }
        modifierHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func hideCheatsheet() {
        modifierHold?.cancel()
        cheatsheetGeneration &+= 1
        cheatsheet.hide()
    }

    /// Pressing a registered shortcut is a command to this app, not user input that competes with operations.
    /// Even if the tap counts the same keyDown after the acceptance baseline, the operation must not stop for userInput.
    private func syncCommandKeys() {
        let keys = (hotkeys?.registered ?? []).map { InputMonitor.CommandKey(keyCode: $0.keyCode, carbonModifiers: $0.modifiers) }
        coordinator.system.input.setCommandKeys(Set(keys))
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // While open, only update existing rows; reordering would change the target under the pointer.
        if trackedMenu === menu, !menu.items.isEmpty { refreshOpenSpaceMenu(); return }
        menu.removeAllItems()
        var s = coordinator.status()
        s.availableUpdate = updates?.offer
        let menuWindow = coordinator.menuWindowTarget()
        s.focusedWindow = menuWindow?.window
        // One read, so the transfer rows' shortcuts and actions come from the same configuration.
        let config = coordinator.config
        let bindings = HotkeyBinding.from(config, mode: s.mode)
        let menuSpaces = coordinator.spaceMenu()
        let canAct = s.manualAvailable && !s.paused && s.progress == .idle
        let onFullscreenSpace = menuSpaces.entries.contains { $0.isCurrent && $0.fullScreen }
        for entry in StatusMenuCopy.topEntries(status: s, spaceCount: menuSpaces.entries.count, modeCount: s.modes.count)
        where !onFullscreenSpace || ![.arrange, .integrate, .spacePause, .space].contains(entry.kind) {
            switch entry.kind {
            case .spaces:
                // No heading for the list (number, apps, and check mark explain it), except each display's name when there are several.
                for (offset, sp) in menuSpaces.entries.enumerated() {
                    if let header = SpaceOverviewMenu.header(before: offset, in: menuSpaces.entries) { menu.addItem(header) }
                    let item = SpaceOverviewMenu.item(sp, action: #selector(spaceOverviewAction(_:)), target: self)
                    let command = EditCommand.space(.id(sp.id))
                    // Shortcuts number the desktops of the current display only.
                    if let index = sp.index, !sp.otherDisplay {
                        HotkeyBinding.applyMenuShortcut(bindings.first { $0.command == .space(.index(index)) }, to: item)
                    }
                    // The current Space's row is only a marker; choosing it does nothing.
                    item.representedObject = sp.isCurrent ? nil : EditCommandBox(command, menuTarget: menuWindow)
                    item.isEnabled = sp.isCurrent || (canAct && coordinator.canApplyEdit(command, focused: s.focusedWindow))
                    menu.addItem(item)
                }
                if menuSpaces.reordersByRecentUse {
                    let note = NSMenuItem(title: StatusMenuCopy.spaceReorderNote, action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                }
                menu.addItem(.separator())
            case .accessibility, .configError:
                let item = NSMenuItem(title: entry.title, action: entry.kind == .accessibility ? #selector(showGeneralSettingsAction) : #selector(showSettingsAction), keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                item.target = self
                menu.addItem(item)
                menu.addItem(.separator())
            case .status:
                let item = NSMenuItem(title: entry.title, action: #selector(showReadyAction), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            case .arrange:
                let arrange = NSMenuItem(title: entry.title, action: #selector(arrangeAction), keyEquivalent: "")
                HotkeyBinding.applyMenuShortcut(bindings.first { $0.action == .arrange }, to: arrange)
                arrange.target = self
                arrange.isEnabled = canAct
                menu.addItem(arrange)
            case .integrate:
                let integrate = NSMenuItem(title: entry.title, action: #selector(integrateAction), keyEquivalent: "")
                HotkeyBinding.applyMenuShortcut(bindings.first { $0.action == .integrate }, to: integrate)
                integrate.target = self
                integrate.isEnabled = canAct
                menu.addItem(integrate)
            case .spacePause:
                let spaceItem = NSMenuItem(title: entry.title, action: #selector(spacePauseAction), keyEquivalent: "")
                spaceItem.target = self
                spaceItem.state = s.currentSpaceAutoPaused ? .off : .on
                spaceItem.isEnabled = s.manualAvailable && !s.paused
                menu.addItem(spaceItem)
            case .globalPause:
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                let global = NSMenuItem(
                    title: entry.title,
                    action: s.paused ? #selector(resumeAction) : #selector(pauseAction), keyEquivalent: "")
                HotkeyBinding.applyMenuShortcut(bindings.first { $0.action == .pauseResume }, to: global)
                global.target = self
                menu.addItem(global)
            case .edit:
                menu.addItem(editMenuItem(status: s, bindings: bindings, canAct: canAct))
                // Separates the window actions from what follows.
                menu.addItem(.separator())
            case .space:
                if let item = spaceMenuItem(bindings: bindings, menuSpaces: menuSpaces, window: menuWindow, follow: config.followMovedWindow) { menu.addItem(item) }
            case .mode:
                menu.addItem(modeMenuItem(status: s))
            case .update:
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                let update = NSMenuItem(title: entry.title, action: #selector(updateAction), keyEquivalent: "")
                update.target = self
                menu.addItem(update)
            case .settings:
                if menu.items.last?.isSeparatorItem == false, menu.items.last?.action != #selector(updateAction) { menu.addItem(.separator()) }
                let settings = NSMenuItem(title: entry.title, action: #selector(showSettingsAction), keyEquivalent: ",")
                settings.target = self
                menu.addItem(settings)
            case .quit:
                let quit = NSMenuItem(title: entry.title, action: #selector(quitAction), keyEquivalent: "q")
                quit.target = self
                menu.addItem(quit)
            }
        }
        menu.autoenablesItems = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackedMenu = menu
        menuRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refreshOpenSpaceMenu()
        }
        menuRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshOpenSpaceMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard trackedMenu === menu else { return }
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        trackedMenu = nil
    }

    private func refreshOpenSpaceMenu() {
        guard let menu = trackedMenu else { return }
        let observed = coordinator.menuWindowTarget()
        let canSend = coordinator.canSendFromMenu
        for parent in menu.items {
            if let box = parent.representedObject as? EditCommandBox,
               case .space = box.command, box.menuTarget == nil { box.menuTarget = observed }
            for item in parent.submenu?.items ?? [] {
                guard let box = item.representedObject as? EditCommandBox else { continue }
                let destination: UInt64
                switch box.command {
                case .sendToSpace(.id(let id)), .moveToSpace(.id(let id)): destination = id
                default: continue
                }
                // Only if the window was not yet visible mid-move, pin the first target observed.
                if box.menuTarget == nil { box.menuTarget = observed }
                updateSendItem(item, box: box, destination: destination, observed: observed, canSend: canSend)
            }
        }
    }

    private func updateSendItem(_ item: NSMenuItem, box: EditCommandBox, destination: UInt64,
                                observed: MenuWindowTarget?, canSend: Bool) {
        let sameWindow = observed != nil && box.menuTarget == observed
        item.isEnabled = canSend && sameWindow && destination != observed?.spaceID
        if observed == nil {
            item.toolTip = L("Select the window you want to send. This menu updates when it becomes available.",
                             "送りたいウインドウを選んでください。確認できると、このメニューから選べるようになります。")
        } else if !sameWindow {
            item.toolTip = L("The selected window changed. Open the menu again.", "対象のウインドウが変わりました。メニューを開き直してください。")
        } else if !canSend {
            item.toolTip = coordinator.control.paused
                ? L("Resume LazySpace to send this window.", "LazySpaceを再開すると、このウインドウを送れます。")
                : L("This becomes available when the current operation finishes and access is available.", "現在の処理が終わり、操作に必要な許可があると選べるようになります。")
        } else { item.toolTip = nil }
    }

    private func editMenuItem(status s: AppStatus, bindings: [HotkeyBinding], canAct: Bool) -> NSMenuItem {
        let editMenu = NSMenu(title: StatusMenuCopy.editTitle)
        editMenu.autoenablesItems = false
        for section in StatusMenuCopy.editSections {
            let submenu = NSMenu(title: section.title)
            submenu.autoenablesItems = false
            for command in section.commands {
                let floating = s.focusedWindow.map { s.floating.contains($0) } ?? false
                let zoomed = s.focusedWindow != nil && s.zoomed == s.focusedWindow
                let item = NSMenuItem(title: command.menuLabel(floating: floating, zoomed: zoomed), action: #selector(editAction(_:)), keyEquivalent: "")
                HotkeyBinding.applyMenuShortcut(bindings.first { $0.command == command }, to: item)
                item.target = self
                item.representedObject = EditCommandBox(command)
                let needsLayout = !(command == .fullscreen || command == .minimize)
                item.isEnabled = s.manualAvailable && !s.paused && s.progress == .idle && (s.currentSpaceManaged || !needsLayout)
                    && coordinator.canApplyEdit(command, focused: s.focusedWindow)
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            editMenu.addItem(item)
        }
        let editItem = NSMenuItem(title: StatusMenuCopy.editTitle, action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        return editItem
    }

    /// `follow` (`follow-moved-window` as the menu opens) decides each row's command once; an open menu keeps it, like its shortcuts.
    private func spaceMenuItem(bindings: [HotkeyBinding], menuSpaces: (entries: [SpaceMenuEntry], reordersByRecentUse: Bool), window: MenuWindowTarget?, follow: Bool) -> NSMenuItem? {
        let spaces = menuSpaces.entries.filter { $0.index != nil }
        guard spaces.count > 1 else { return nil }
        let title = StatusMenuCopy.moveWindowToSpaceTitle
        let spaceMenu = NSMenu(title: title)
        spaceMenu.autoenablesItems = false
        // The note about changing numbers appears once, in the Space list at the top.
        for (offset, sp) in spaces.enumerated() {
            guard let index = sp.index else { continue }
            if let header = SpaceOverviewMenu.header(before: offset, in: spaces) { spaceMenu.addItem(header) }
            let command = EditCommand.sendToSpace(.id(sp.id)).following(follow)
            let item = SpaceOverviewMenu.item(sp, action: #selector(editAction(_:)), target: self)
            if !sp.otherDisplay {
                let shortcut = EditCommand.sendToSpace(.index(index)).following(follow)
                HotkeyBinding.applyMenuShortcut(bindings.first { $0.command == shortcut }, to: item)
            }
            let box = EditCommandBox(command, menuTarget: window)
            item.representedObject = box
            updateSendItem(item, box: box, destination: sp.id, observed: window, canSend: coordinator.canSendFromMenu)
            spaceMenu.addItem(item)
        }
        let spaceItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        spaceItem.submenu = spaceMenu
        return spaceItem
    }

    private func modeMenuItem(status s: AppStatus) -> NSMenuItem {
        let modeMenu = NSMenu(title: L("Mode", "モード"))
        modeMenu.autoenablesItems = false
        for name in s.modes {
            let binding = HotkeyBinding.from(coordinator.config, mode: s.mode).first { $0.action == .mode(name) }
            let item = NSMenuItem(title: name, action: #selector(modeAction(_:)), keyEquivalent: "")
            HotkeyBinding.applyMenuShortcut(binding, to: item)
            item.target = self
            item.representedObject = name
            item.state = name == s.mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: StatusMenuCopy.modeTitle(s.mode), action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        return modeItem
    }

    @objc private func arrangeAction() { coordinator.markFirstLaunchDone(); coordinator.arrange(source: "menu") }
    @objc private func integrateAction() { perform(.integrate, source: "menu") }
    @objc private func spaceOverviewAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? EditCommandBox else { return }
        // macOS 27 reports the press on the item (`rightMouseDown`), not the release, as the current event.
        if let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp, case .space(let destination) = box.command {
            let command = EditCommand.sendToSpace(destination).following(coordinator.config.followMovedWindow)
            guard let target = box.menuTarget else {
                let why = L("Could not find the focused window. Select the window to send, then try again.", "フォーカス中のウインドウを確認できません。送りたいウインドウを選んでから操作してください。")
                coordinator.noteRefusal(L("“\(command.label)”: \(why)", "「\(command.label)」: \(why)"))
                return
            }
            runEdit(command, source: "menu", menuTarget: target)
        } else {
            runEdit(box.command, source: "menu")
        }
    }
    @objc private func editAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? EditCommandBox else { return }
        runEdit(box.command, source: "menu", menuTarget: box.menuTarget)
    }

    /// Shows the user the acceptance result of an edit (refusals appear in the window list's progress area and the menu's latest row).
    private func runEdit(_ command: EditCommand, source: String, pressedAt: Date = Date(), menuTarget: MenuWindowTarget? = nil) {
        switch coordinator.edit(command, source: source, pressedAt: pressedAt, menuTarget: menuTarget) {
        case .started: break
        case .busy: coordinator.noteRefusal(L("Another operation is in progress, so “\(command.label)” was not accepted.", "処理中のため「\(command.label)」を受け付けませんでした"))
        case .refused(let why, _): coordinator.noteRefusal(L("“\(command.label)”: \(why)", "「\(command.label)」: \(why)"))
        }
    }
    @objc private func pauseAction() { coordinator.pause() }
    @objc private func spacePauseAction() { coordinator.setCurrentSpaceAutoPaused(!coordinator.currentSpaceAutoPaused) }
    @objc private func resumeAction() { coordinator.resume() }
    @objc private func modeAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if case .refused(let why) = coordinator.setMode(name, source: "menu") { coordinator.noteRefusal(why) }
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
    private var settings: SettingsWindowController?
    private let cheatsheet = KeyCheatsheet()
    private var modifierHold: DispatchWorkItem?
    private var cheatsheetGeneration: UInt64 = 0
    @objc private func showSettingsAction() { showSettings(pane: nil) }
    /// Installing quits LazySpace, so a pending Settings edit is settled first.
    @objc private func updateAction() {
        if settings?.resolveLeave() == false { return }
        updates?.checkForUpdates()
    }
    @objc private func showGeneralSettingsAction() { showSettings(pane: .general) }

    private func trustChanged(_ trusted: Bool) {
        settings?.refreshAccess()
        // On first launch, show the window list as soon as permission is granted.
        if trusted, !coordinator.state.firstLaunchDone { showReady() }
    }

    private func showSettings(pane: SettingsPane?) {
        if settings == nil {
            settings = SettingsWindowController()
            settings?.updates = updates
            // While recording a key, unregister global shortcuts so the pressed key does not run an action.
            settings?.onRecording = { [weak self] recording in
                guard let self else { return }
                self.recordingShortcut = recording
                if recording { self.hideCheatsheet(); self.hotkeys?.unregister(); self.syncCommandKeys() } else { self.reregisterHotkeys() }
            }
        }
        settings?.showWindow(nil)
        settings?.refresh()
        if let pane { settings?.show(pane: pane) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func showReadyAction() { showReady() }

    private func showReady() {
        if ready == nil { ready = ReadyWindowController(openGeneralSettings: { [weak self] in self?.showSettings(pane: .general) }) }
        ready?.showWindow(nil)
        ready?.refreshLabels()
        ready?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Control port (same path as the CLI)

    func handle(_ req: ControlPort.Request) -> ControlPort.Response {
        if let error = req.validationError {
            return ControlPort.Response(ok: false, message: error, code: "usage")
        }
        switch req.cmd {
        case "status":
            var status = coordinator.status()
            status.availableUpdate = updates?.offer
            return ControlPort.Response(ok: true, message: "", status: status)
        case "result":
            guard let id = req.arg, !id.isEmpty else {
                return ControlPort.Response(ok: false, message: "A result ID is required.", code: "usage")
            }
            // A receipt token never falls through to the ordinary result cache.
            if id.contains(":") {
                let outcome = receipts.query(id)
                return outcome.response(requestID: MutationReceiptRegistry.isCanonicalToken(id) ? id : nil)
            }
            if var result = coordinator.result(id: id) {
                // Match the queued acceptance ID with the ID of the operation that actually ran, for the CLI's completion wait.
                result.id = id
                var status = coordinator.status()
                status.lastResult = result
                return ControlPort.Response(ok: result.outcome == .complete, message: result.message, status: status, operationID: id, code: "finished", result: result)
            }
            // The completion wait polls every 20 ms. Unfinished replies carry no status (building it reads settings and login items each time).
            if coordinator.resultPending(id: id) {
                return ControlPort.Response(ok: true, message: L("In progress.", "処理中"), operationID: id, code: "pending")
            }
            return ControlPort.Response(ok: false, message: "Unknown or expired operation ID.", operationID: id, code: "unknown-operation")
        case "settle.v2":
            let id = UUID().uuidString
            coordinator.observeSettlement { [weak self] observation in
                DispatchQueue.main.async {
                    self?.storeObservation(ControlPort.Response(ok: true, message: "", operationID: id, settlement: observation), id: id)
                }
            }
            return ControlPort.Response(ok: true, message: "Observing.", operationID: id, code: "pending")
        case "inspect":
            let id = UUID().uuidString
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let snap = self.coordinator.system.snapshot()
                let inspection = coordinator.inspectSnapshot(snap)
                let spaces = SpaceOverview.take()
                DispatchQueue.main.async {
                    self.storeObservation(ControlPort.Response(ok: true, message: "", status: self.coordinator.status(), inspection: inspection, spaces: spaces), id: id)
                }
            }
            return ControlPort.Response(ok: true, message: L("Reading windows…", "観測中"), operationID: id)
        case "inspect-result":
            guard let id = req.arg else { return ControlPort.Response(ok: false, message: L("Missing inspection ID.", "観測IDがありません"), code: "usage") }
            if let response = inspectionResponses.removeValue(forKey: id) { inspectionOrder.removeAll { $0 == id }; return response }
            return ControlPort.Response(ok: true, message: L("Reading windows…", "観測中"), operationID: id)
        case "request-token.v3":
            switch receipts.reserve() {
            case .reserved(let id):
                return ControlPort.Response(ok: true, message: "Reserved.", code: "reserved", requestID: id)
            case .refused(let outcome):
                return outcome.response(requestID: nil)
            }
        case "arrange.v3", "integrate.v3", "focus-window.v3", "edit.v3":
            return dispatchMutation(req)
        case "mode":
            let name = (req.arg ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return ControlPort.Response(ok: true, message: StatusMenuCopy.modeTitle(coordinator.mode), status: coordinator.status()) }
            switch coordinator.setMode(name, source: "cli") {
            case .changed: return ControlPort.Response(ok: true, message: StatusMenuCopy.modeTitle(name), status: coordinator.status())
            case .unchanged: return ControlPort.Response(ok: true, message: L("Already in mode \(name).", "既にモード\(name)です"), status: coordinator.status())
            case .refused(let why): return ControlPort.Response(ok: false, message: why, status: coordinator.status(), code: "unknown-mode")
            }
        case "login-item":
            switch (req.arg ?? "").lowercased() {
            case "on", "true", "enable": coordinator.setLoginItem(true)
            case "off", "false", "disable": coordinator.setLoginItem(false)
            case "": break
            default: return ControlPort.Response(ok: false, message: L("login-item takes on or off.", "login-itemにはonかoffを指定します"), status: coordinator.status(), code: "usage")
            }
            let s = coordinator.status()
            return ControlPort.Response(ok: true, message: "\(MacItem.openAtLogin): \(s.loginItem)", status: s)
        case "reload":
            let message = coordinator.reloadConfig(source: "cli")
            let ok = coordinator.configError == nil
            return ControlPort.Response(ok: ok, message: message, status: coordinator.status(), code: ok ? nil : "config-error")
        case "pause":
            coordinator.pause()
            return ControlPort.Response(ok: true, message: StatusMenuCopy.pauseNotice(), status: coordinator.status())
        case "resume":
            if let reason = coordinator.resume() {
                return ControlPort.Response(ok: false, message: reason, status: coordinator.status(), code: "resume-unavailable")
            }
            return ControlPort.Response(ok: true, message: StatusMenuCopy.resumeNotice(), status: coordinator.status())
        case "settings":
            showSettingsAction()
            return ControlPort.Response(ok: true, message: "")
        case "show":
            showReady()
            return ControlPort.Response(ok: true, message: "", status: coordinator.status())
        case "quit":
            return Self.makeQuitResponse()
        default:
            return ControlPort.Response(ok: false, message: L("Unknown command: \(req.cmd)", "不明なコマンド: \(req.cmd)"), code: "unknown-command")
        }
    }

    /// Drops unclaimed observations oldest first (dictionary order is not insertion order, so order is kept separately).
    private func storeObservation(_ response: ControlPort.Response, id: String) {
        inspectionOrder.removeAll { $0 == id }
        inspectionOrder.append(id)
        while inspectionOrder.count > 32 { inspectionResponses.removeValue(forKey: inspectionOrder.removeFirst()) }
        inspectionResponses[id] = response
    }

    /// Bind the receipt, then run the existing operation path once. Replays never reach coordinator code.
    private func dispatchMutation(_ req: ControlPort.Request) -> ControlPort.Response {
        let requestID = req.requestID ?? ""
        let edit = req.cmd == "edit.v3" ? EditCommand.parse(req.arg ?? "") : nil
        let payload = MutationReceiptRegistry.Payload(cmd: req.cmd, edit: edit, windowID: req.windowID, expectedSpaceID: req.expectedSpaceID, expectedPID: req.expectedPID, desiredState: req.desiredState)
        switch receipts.begin(requestID, payload: payload) {
        case .outcome(let outcome):
            return outcome.response(requestID: requestID)
        case .dispatch:
            receipts.arm(requestID)
            defer { receipts.disarm() }
            let product = performMutation(req)
            return receipts.finish(requestID, product).response(requestID: requestID)
        }
    }

    private func performMutation(_ req: ControlPort.Request) -> MutationReceiptRegistry.Product {
        switch req.cmd {
        case "arrange.v3":
            return performArrange(req, integrate: false)
        case "integrate.v3":
            return performArrange(req, integrate: true)
        case "focus-window.v3":
            return product(coordinator.agentEdit(nil, windowID: req.windowID, expectedSpaceID: req.expectedSpaceID, expectedPID: req.expectedPID), accepted: "Accepted.")
        case "edit.v3":
            guard let command = EditCommand.parse(req.arg ?? "") else {
                return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "internal-error", message: "Invalid edit command.", operationID: nil, result: nil))
            }
            // The timeline origin is when ControlPort accepted this request.
            let timeline = OperationTimeline()
            return product(coordinator.agentEdit(command, windowID: req.windowID, expectedSpaceID: req.expectedSpaceID, expectedPID: req.expectedPID,
                                                 desiredState: req.desiredState, timeline: timeline), accepted: "Accepted.")
        default:
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "internal-error", message: "This command is not a mutation.", operationID: nil, result: nil))
        }
    }

    private func performArrange(_ req: ControlPort.Request, integrate: Bool) -> MutationReceiptRegistry.Product {
        var authorization = OperationAuthorization(system: coordinator.system, control: coordinator.control)
        authorization.expectedSpaceID = req.expectedSpaceID
        if let expected = req.expectedSpaceID, authorization.spaceID != expected {
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "space-mismatch", message: "Expected Space does not match.", operationID: nil, result: nil))
        }
        let accepted = integrate
            ? coordinator.integrateWaiting(source: "agent", authorization: authorization)
            : coordinator.arrange(source: "agent", authorization: authorization)
        switch accepted {
        case .started(let id):
            return .started(operationID: id, message: L("Accepted.", "受け付けました"))
        case .busy:
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "busy", message: L("Another operation is in progress; the request was not accepted.", "処理中のため受け付けません"), operationID: nil, result: nil))
        case .notApplicable:
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "not-started", message: L("This Space has no layout yet.", "この操作スペースにはまだレイアウトがありません"), operationID: nil, result: nil))
        }
    }

    private func product(_ accepted: Coordinator.EditAccept, accepted message: String) -> MutationReceiptRegistry.Product {
        switch accepted {
        case .started(let id):
            return .started(operationID: id, message: message)
        case .busy:
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: "busy", message: L("Another operation is in progress; the request was not accepted.", "処理中のため受け付けません"), operationID: nil, result: nil))
        case .refused(let why, let code):
            return .refused(MutationReceiptRegistry.Outcome(ok: false, code: code, message: why, operationID: nil, result: nil))
        }
    }

    /// Quitting is not complete when requested; the unsaved-changes prompt can cancel it.
    static func makeQuitResponse(terminate: @escaping () -> Void = { NSApp.terminate(nil) }) -> ControlPort.Response {
        DispatchQueue.main.async(execute: terminate)
        return ControlPort.Response(ok: true, message: L("Quit requested. Unsaved changes in Settings can cancel it.",
                                                         "終了を要求しました。設定に未保存の変更があると、終了を取り消せます。"))
    }
}

/// Shows where the CLI is and how to put it on PATH (copy only; writes no files).
enum CLIHelp {
    static func present() {
        let exe = Bundle.main.executableURL?.path ?? "LazySpace.app/Contents/MacOS/LazySpace"
        let shim = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/lazyspace").path
        let source = FileManager.default.fileExists(atPath: shim) ? shim : exe
        // New Macs have no /usr/local/bin, and /usr/local belongs to root.
        let command = "sudo mkdir -p /usr/local/bin && sudo ln -s \"\(source)\" /usr/local/bin/lazyspace"
        let alert = NSAlert()
        alert.messageText = L("Command-Line Setup", "コマンドラインの設定")
        alert.informativeText = L(
            "The same executable works as a command-line tool when it is called with the lowercase name lazyspace. Create a symbolic link in a folder on your PATH. This is not needed if you installed LazySpace with Homebrew Cask.\n\n\(command)\n\nExamples:\nlazyspace status\nlazyspace focus left\nlazyspace list-spaces\nlazyspace help",
            "同じ実行ファイルを小文字のlazyspaceという名前で呼ぶとCLIとして動きます。PATHの通った場所にシンボリックリンクを置いてください（Homebrew Caskで入れた場合は不要）。\n\n\(command)\n\n例:\nlazyspace status\nlazyspace focus left\nlazyspace list-spaces\nlazyspace help")
        alert.addButton(withTitle: L("Copy Command", "コマンドをコピー"))
        alert.addButton(withTitle: L("Close", "閉じる"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}

final class EditCommandBox: NSObject {
    let command: EditCommand
    var menuTarget: MenuWindowTarget?
    init(_ c: EditCommand, menuTarget: MenuWindowTarget? = nil) { command = c; self.menuTarget = menuTarget }
}
