import AppKit
import Copy
import Foundation
import MacSupport
import Settings

/// Settings headings. Shows action names, never configuration command names.
enum SettingsCopy {
    static var keyColumns: [String] { [L("Action", "操作"), L("Shortcut", "ショートカット")] }
    static var ruleAppColumn: String { L("App", "アプリ") }
    static var ruleIdentifierColumn: String { L("Identifier", "識別子") }
    static var manualRuleTitle: String { L("Enter Bundle Identifier…", "バンドル識別子を入力…") }
    static var accessTitle: String { L("Access", "アクセス権") }
    static var accessAllowed: String { L("Allowed in \(AccessPane.name())", "「\(AccessPane.name())」で許可されています") }
    static var accessNotAllowed: String { L("Not allowed in \(AccessPane.name())", "「\(AccessPane.name())」で許可されていません") }
    static var accessCaption: String { L("Used to read and arrange windows.", "ウインドウの読み取りと整列に使います。") }
    static var accessButton: String { L("Open System Settings…", "システム設定を開く…") }
    static var notificationsTitle: String { L("Notifications", "通知") }
    static var notificationBox: String { L("Notify when LazySpace needs your attention", "対処が必要なときに通知") }
    static var notificationCaption: String {
        L("When arranging stops until you act, or a change to the configuration file can’t be applied. Choose how notifications appear in System Settings › Notifications.",
          "対処するまで整列が止まるときや、設定ファイルの変更を適用できないときに通知します。表示のしかたはシステム設定 › 通知で選べます。")
    }
    static var notificationsDenied: String { L("Notifications for LazySpace are turned off in System Settings.", "システム設定でLazySpaceの通知がオフになっています。") }
    static var notificationsNotYet: String { L("LazySpace is not allowed to send notifications yet.", "LazySpaceはまだ通知の送信を許可されていません。") }
    static var allowNotifications: String { L("Allow Notifications…", "通知を許可…") }
    static var accessHelp: String {
        L("Turn on LazySpace in Privacy & Security › \(AccessPane.name()). If it’s already on but this doesn’t change, an older copy of the app may still be listed: select LazySpace, click the Remove button (−), then click Open System Settings… again.",
          "プライバシーとセキュリティ › \(AccessPane.name())でLazySpaceをオンにしてください。オンなのにここが変わらない場合は、古いバージョンのアプリが登録されている可能性があります。LazySpaceを選択して削除ボタン（−）をクリックし、もう一度「システム設定を開く…」をクリックしてください。")
    }
    static func fileCaption() -> String {
        L("File edits reload automatically. Saving a change here keeps a backup of the previous file.",
          "ファイルの変更は自動で反映されます。ここで変更を保存すると、直前のファイルを控えに残します。")
    }
    static var externalChangeMessage: String {
        L("The file changed. Choose Reload to load it. Nothing was saved.",
          "ファイルが変更されています。「再読み込み」で読み込み直してください。保存していません。")
    }
    static var configBannerMessage: String { L("The configuration file could not be applied.", "設定ファイルを適用できません。") }
    static var configNotesMessage: String { L("The configuration loaded with notes.", "設定を読み込みました。注記があります。") }
    static var showDetailsTitle: String { L("Show Details", "詳細を表示") }
    static var tryAgainTitle: String { L("Try Again", "再試行") }
    static var reloadTitle: String { L("Reload", "再読み込み") }
    /// Language choices. Setting values are not translated; each language name is shown in that language.
    static var languageChoices: [(id: String, title: String)] {
        [("system", L("System", "システムに合わせる")), ("en", "English"), ("ja", "日本語")]
    }

    /// A name only for an exact match with a running app; nil for patterns and unknown identifiers.
    /// A prefix rule names no single app.
    static func knownAppName(_ app: String, name: (String) -> String?) -> String? {
        guard !app.isEmpty, !app.contains("*") else { return nil }
        return name(app)
    }

    static func commandLabel(_ name: String) -> String {
        guard let action = HotkeyBinding.action(forCommand: name) else { return name }
        return HotkeyBinding(keyCode: 0, modifiers: 0, action: action, display: "").label
    }
}

/// Sees mouse events in the Settings window first, as clicks outside the recorder.
final class SettingsEventWindow: NSWindow {
    weak var settings: SettingsWindowController?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            settings?.cancelRecordingForMouseDown(event)
        }
        super.sendEvent(event)
        if event.type == .leftMouseDown {
            settings?.releaseOutsideClickStatusHold()
        }
    }
}

/// Settings. Values, shortcuts, and rules are edited here so the user never has to touch TOML.
/// A completed change applies only the changed values to the file right away (the previous file stays as `.bak`), keeping comments and unchanged lines. Windows never move.
/// Numbers being typed are not written until the edit completes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSToolbarDelegate {
    private let coordinator: Coordinator
    private let preferences: UserDefaults
    private var selectedPane: SettingsPane = .general
    private var panes: [SettingsPane: NSView] = [:]
    private let paneContainer = NSView()
    /// The last configuration loaded; matches the one in use.
    private var saved = Config()
    /// A valid configuration whose write failed; nil means the same as saved.
    private var pending: Config?
    /// The configuration on screen: the failed attempt if any, otherwise saved.
    private var draft: Config { pending ?? saved }
    /// The configuration last drawn; tables are not rebuilt when unchanged.
    private var rendered: Config?
    private var refreshing = false
    private var committing = false
    /// Global shortcuts are unregistered while recording a key (so the pressed key does not run an action).
    var onRecording: ((Bool) -> Void)?

    // General
    private let gapField = NSTextField()
    private let placementPopup = NSPopUpButton()
    private let placementPreview = ActionPictogramView()
    private let dialogsBesideBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let accessIcon = NSImageView()
    private let accessState = NSTextField(labelWithString: "")
    private let accessCaption = NSTextField.settingsText( "")
    private let accessButton = NSButton(title: "", target: nil, action: nil)
    private let accessHelp = NSTextField.settingsText( "")
    private var accessCaptionRow: NSGridRow?
    private var accessButtonRow: NSGridRow?
    private var accessHelpRow: NSGridRow?
    private let loginBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginStatus = NSTextField.settingsText( "")
    private let loginSettingsButton = NSButton(title: "", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let notificationBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notificationStatus = NSTextField.settingsText("")
    private let notificationButton = NSButton(title: "", target: nil, action: nil)
    private var notificationStatusRow: NSGridRow?
    private var notificationButtonRow: NSGridRow?
    /// Nil when this copy cannot send notifications (no bundle, tests); the checkbox still saves the choice.
    var attention: AttentionNotifier? {
        didSet {
            attention?.onPermissionChange = { [weak self] in self?.renderNotifications() }
            renderNotifications()
        }
    }
    private let shortcutGuideBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let borderBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let borderWidthField = NSTextField()
    private let borderColorWell = NSColorWell()
    private var borderWidthRow: NSGridRow?
    private var borderColorRow: NSGridRow?
    private var loginStatusRow: NSGridRow?
    private var loginSettingsRow: NSGridRow?
    private let gapError = NSTextField.settingsText( "")
    private let borderWidthError = NSTextField.settingsText( "")
    private let ruleError = NSTextField.settingsText( "")
    private enum NumericField: Hashable { case gap, borderWidth }
    private var invalidFields: Set<NumericField> = []
    /// Number fields not yet saved because they are mid-edit or invalid; redraws do not overwrite them.
    private var uncommittedNumbers: Set<NumericField> = []
    /// App identifier being edited, remembered by row of the list on screen so rules with the same identifier do not mix.
    private struct RuleEdit { var row: Int; var text: String; var message: String? }
    private var ruleEdit: RuleEdit?
    /// Resolves the name shown next to a rule's identifier; tests inject their own.
    var appName: (String) -> String? = AppNames.knownName

    // Shortcuts
    private let keysTable = ShortcutTable()
    private var keyRows: [ShortcutRow] = []
    private var shortcutSelection: ShortcutSelection?
    private let keySearch = FocusingSearchField()
    private let shortcutInstruction = NSTextField.settingsText( "")
    private let shortcutContextMenu = NSMenu()
    private let messageDetailsButton = NSButton(title: "", target: nil, action: nil)
    private let restoreMainButton = NSButton(title: "", target: nil, action: nil)
    /// nil shows the confirmation dialog; tests return true / false to avoid the modal.
    var confirmMainShortcutReset: (() -> Bool)?
    private let recordingLabel = NSTextField.settingsText( "")
    private let nativeStatusIcon = NSImageView()
    private let nativeStatusLabel = NSTextField.settingsText( "")
    private let keyboardSettingsButton = NSButton(title: "", target: nil, action: nil)
    private let keyboardSettingsHint = NSTextField(labelWithString: "")
    private let modeNote = NSTextField.settingsText( "")
    private let modeFileButton = NSButton(title: "", target: nil, action: nil)
    private var modeRow: NSView?
    private var keyboardRow: NSView?
    private var nativeStatusRow: NSView?
    private var shortcutActionRow: NSStackView?
    /// The flexible space left of the message. Spacing is added on both sides, so width calculations count it as an arranged view.
    private var shortcutActionGap: NSView?
    private var nativeLeft: SystemSpaceShortcut = .unread
    private var nativeRight: SystemSpaceShortcut = .unread
    private var announcedStatus = ""
    /// Lets tests replace the 79 / 81 reads; nil uses Coordinator's path.
    var nativeShortcutReader: ((Bool) -> SystemSpaceShortcut)?
    /// Left/right hotkey state (replaced in tests). nil means no Space observation, so no no-response guidance.
    var arrowStateReader: (() -> (left: DesktopShortcuts.State, right: DesktopShortcuts.State)?)?
    /// Lets tests record text sent to assistive technologies for announcement.
    var announcementObserver: ((String) -> Void)?
    private var restoringSelection = false
    /// While focus returns from the search field to the table, the search field's begin hook does not clear the recording.
    private var transferringShortcutFocus = false
    private var keyMonitor: Any?
    private var recordingTarget: RecordingTarget?
    /// Key whose release must come before global shortcuts unregistered for recording come back.
    private var resumeHotkeysOnKeyUp: UInt16?
    /// The recording window that waits for that key's release.
    private var hotkeyHoldOwner: NSWindow?
    private var hotkeysSuspended = false
    private var hotkeyResumeTimer: Timer?
    private var appResignObserver: NSObjectProtocol?
    /// If no release arrives while inactive, shortcuts come back after this time.
    var hotkeyResumeGrace: TimeInterval = 0.6
    /// Whether the recorded key is still physically down (mouse buttons too). Replaced by tests.
    var recordedKeyStillDown: (UInt16) -> Bool = { code in
        if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) { return true }
        return NSEvent.pressedMouseButtons != 0
    }
    /// While selecting a row to start recording, selection changes do not clear the recording.
    private var suppressSelectionSideEffects = false
    /// The cancel message shown by an outside click is not cleared by that click's selection change.
    private var outsideClickKeptCancelStatus = false
    /// A resign while the window becomes key to start recording does not clear the recording.
    private var claimingRecordingFocus = false
    /// When saving a shortcut removes its row, select the neighbor; if search only hid it, remember it.
    private var reconcileMissingShortcut = false
    /// A failed-save message, not cleared by selection or pane changes.
    private var commandStatusSticky = false
    private var stickyFailureText = ""
    /// Height changes are batched during building and redrawing.
    private var layoutHold = 0
    /// A height change that arrived while a sheet or menu was open.
    private var deferredResize = false
    private var openMenuCount = 0
    private enum RecordingTarget: Equatable { case command(String, mode: String) }
    private enum StatusTone { case secondary, accent, warning, failure }
    private enum ShortcutSelection: Equatable {
        case direction(DirectionGroup)
        case heading(ShortcutSection)
        case command(String)
    }

    /// A menu item carries the row it was opened for; at run time it checks that row is still visible.
    private final class ShortcutActionToken: NSObject {
        let selection: ShortcutSelection
        init(_ selection: ShortcutSelection) { self.selection = selection }
    }

    // Rules
    private let rulesTable = NSTableView()
    private let addRuleButton = NSButton(title: "+", target: nil, action: nil)
    private let addRuleMenu = NSMenu()
    private let removeRuleButton = NSButton(title: "−", target: nil, action: nil)
    private let rulesEmptyLabel = NSTextField.settingsText( "")
    private var rulesScroll: PaneScrollView?

    private var keysScroll: PaneScrollView?
    // File
    private let pathLabel = NSTextField.settingsText( "")
    private let errorLabel = NSTextField.settingsText( "")
    /// Times the leave confirmation was actually shown; an injected leavePrompt does not count.
    private(set) var leavePresentationCount = 0

    /// The file's valid contents differed from saved while there were unsaved edits.
    private var externalChange = false
    private let configBanner = NSStackView()
    private let configBannerLabel = NSTextField.settingsText( "")
    private let recoveryBanner = NSStackView()
    private let recoveryLabel = NSTextField.settingsText( "")
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private let reloadButton = NSButton(title: "", target: nil, action: nil)
    private var recoveryText = ""
    private var recoveryAllowsRetry = false
    private var recoveryWidth: NSLayoutConstraint?
    private let paneStack = NSStackView()
    /// Choice for the leave confirmation; nil shows the dialog. Tests replace it to avoid the modal.
    var leavePrompt: (() -> LeaveChoice)?

    /// The running app's Info.plist, shown in About; tests replace it.
    var bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:] { didSet { refreshAbout() } }
    /// Opens About's links; tests record them instead of opening a browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Nil when this copy does not check for updates; About then has no update section.
    var updates: UpdateChecking? {
        didSet {
            updates?.onChange = { [weak self] in self?.refreshAbout() }
            refreshAbout()
        }
    }
    private let aboutVersion = NSTextField.settingsText("")
    private let aboutCopyright = NSTextField.settingsText("")
    private let updateNotice = NSTextField.settingsText("")
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private let automaticCheckBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var updateSection: NSView?
    enum LeaveChoice { case retry, discard, cancel }

    /// State that needs confirmation before closing. Valid values being typed do not count; they are committed on close.
    private var needsAttention: Bool {
        pending != nil || !invalidFields.isEmpty || ruleEdit?.message != nil || externalChange
    }

    private var editorBlocksRefresh: Bool {
        needsAttention || !uncommittedNumbers.isEmpty || ruleEdit != nil
    }

    /// Language the window was built in; rebuilt when it changes.
    private var builtLanguage: Language?
    private var sizeConstraintsAdded = false

    /// Settings edits only main's keys; modes in the file are left as they are.
    private var currentMode: String { Config.mainModeName }

    init(coordinator: Coordinator = .shared, preferences: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.preferences = preferences
        saved = coordinator.config
        selectedPane = SettingsPane(rawValue: preferences.string(forKey: "settings.selectedPane") ?? "") ?? .general
        let window = SettingsEventWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.settings = self
        window.delegate = self
        window.toolbarStyle = .preference
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            self?.handleApplicationResigned()
        }
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        hotkeyResumeTimer?.invalidate()
        if let appResignObserver { NotificationCenter.default.removeObserver(appResignObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if hotkeysSuspended { onRecording?(false) }
    }

    // MARK: - Building

    private func build() {
        guard let content = window?.contentView else { return }
        layoutHold += 1
        defer {
            layoutHold -= 1
            if layoutHold == 0 { resizePane(animated: false) }
        }
        builtLanguage = Copy.language
        content.subviews.forEach { $0.removeFromSuperview() }
        paneStack.arrangedSubviews.forEach { paneStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        panes = [
            .general: SettingsPaneLayout.scrolling(buildGeneral()),
            .layout: SettingsPaneLayout.scrolling(buildLayout()),
            .keys: SettingsPaneLayout.scrolling(buildKeys()),
            .apps: SettingsPaneLayout.scrolling(buildRules()),
            .advanced: SettingsPaneLayout.scrolling(buildAdvanced()),
            .about: SettingsPaneLayout.scrolling(buildAbout()),
        ]
        sizeConstraintsAdded = true
        configureBanner()
        configureRecovery()
        paneStack.orientation = .vertical
        paneStack.alignment = .leading
        paneStack.spacing = 0
        paneStack.detachesHiddenViews = true
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        paneContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if paneStack.superview == nil { paneContainer.addSubview(paneStack) }
        content.addSubview(paneContainer)

        let toolbar = NSToolbar(identifier: "LazySpace.Settings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar

        NSLayoutConstraint.activate([
            paneStack.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            paneStack.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor),
            paneContainer.topAnchor.constraint(equalTo: content.topAnchor),
            paneContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        showPane(selectedPane, animated: false)
    }

    private func configureBanner() {
        configBannerLabel.stringValue = SettingsCopy.configBannerMessage
        configBannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        configBannerLabel.maximumNumberOfLines = 0
        configBannerLabel.cell?.wraps = true
        configBannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: SettingsCopy.showDetailsTitle, target: self, action: #selector(showConfigDetails))
        button.setContentHuggingPriority(.required, for: .horizontal)
        configBanner.orientation = .horizontal
        configBanner.alignment = .centerY
        configBanner.spacing = 12
        configBanner.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 24)
        configBanner.arrangedSubviews.forEach { configBanner.removeArrangedSubview($0); $0.removeFromSuperview() }
        configBanner.addArrangedSubview(configBannerLabel)
        configBanner.addArrangedSubview(button)
        configBanner.detachesHiddenViews = false
        configBanner.isHidden = true
        if !paneStack.arrangedSubviews.contains(configBanner) { paneStack.insertArrangedSubview(configBanner, at: 0) }
        configBanner.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
    }

    /// Shows only the reason a save failed; takes no height when hidden.
    private func configureRecovery() {
        recoveryLabel.font = .systemFont(ofSize: 11)
        recoveryLabel.textColor = .systemRed
        recoveryLabel.maximumNumberOfLines = 0
        recoveryLabel.cell?.wraps = true
        recoveryLabel.cell?.isScrollable = false
        recoveryLabel.lineBreakMode = .byWordWrapping
        recoveryLabel.preferredMaxLayoutWidth = 672
        recoveryLabel.setAccessibilityLabel(L("Settings Recovery", "設定の復旧"))
        recoveryLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        recoveryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryButton.title = SettingsCopy.tryAgainTitle
        retryButton.target = self
        retryButton.action = #selector(retrySave)
        reloadButton.title = SettingsCopy.reloadTitle
        reloadButton.target = self
        reloadButton.action = #selector(reloadFromFile)
        for button in [retryButton, reloadButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [retryButton, reloadButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        recoveryBanner.orientation = .vertical
        recoveryBanner.alignment = .leading
        recoveryBanner.spacing = 6
        recoveryBanner.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 24)
        recoveryBanner.detachesHiddenViews = true
        recoveryBanner.arrangedSubviews.forEach { recoveryBanner.removeArrangedSubview($0); $0.removeFromSuperview() }
        recoveryBanner.addArrangedSubview(recoveryLabel)
        recoveryBanner.addArrangedSubview(buttons)
        recoveryBanner.isHidden = true
        if recoveryBanner.constraints.isEmpty {
            recoveryLabel.widthAnchor.constraint(equalTo: recoveryBanner.widthAnchor, constant: -48).isActive = true
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        item.autovalidates = false
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        finishActiveEditors()
        endRecording(.clearTransient)
        clearTransientShortcutStatus()
        showPane(pane, animated: true)
    }

    /// Opens from outside, showing the given pane (as permission guidance does).
    func show(pane: SettingsPane) {
        finishActiveEditors()
        endRecording(.clearTransient)
        clearTransientShortcutStatus()
        showPane(pane, animated: false)
    }

    private func showPane(_ pane: SettingsPane, animated: Bool) {
        guard let view = panes[pane], let window else { return }
        for arranged in paneStack.arrangedSubviews where arranged !== configBanner && arranged !== recoveryBanner {
            paneStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        paneStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let switched = pane != selectedPane
        selectedPane = pane
        preferences.set(pane.rawValue, forKey: "settings.selectedPane")
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        if pane == .keys { refreshNativeShortcuts() }
        if pane == .about { refreshAutomaticCheck() }
        resizePane(animated: animated && switched && window.isVisible)
        revealClippedValidationErrors()
    }

    /// Tests pin an 800 pt visible area; nil uses the window's screen, or 800 without one.
    var visibleHeightForLayout: CGFloat?

    /// Keeps the top edge when possible; otherwise shifts vertically, and clips width and height larger than the visible area.
    static func clampedFrame(_ frame: NSRect, within visible: NSRect) -> NSRect {
        guard visible.width > 1, visible.height > 1, frame.width > 0, frame.height > 0 else { return frame }
        func fitted(_ origin: CGFloat, length: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            var origin = origin
            let overflow = origin + length - high
            if overflow > 0 { origin -= overflow }
            if origin < low { origin = low }
            return origin
        }
        var result = frame
        result.size.width = min(frame.width, visible.width)
        result.size.height = min(frame.height, visible.height)
        result.origin.x = fitted(frame.minX, length: result.width, low: visible.minX, high: visible.maxX)
        result.origin.y = fitted(frame.maxY - result.height, length: result.height, low: visible.minY, high: visible.maxY)
        return result
    }

    /// App content height; on short screens, the visible area minus 130 pt.
    static let contentHeightCap: CGFloat = 440
    /// Only Shortcuts is taller, showing about 10 rows; the screen cap is the same.
    static let shortcutContentHeight: CGFloat = 500
    /// General, Arrangement, and Advanced shrink to a height with even top and bottom margins; taller content wins.
    static let formHeightFloor: CGFloat = 100

    private func layoutVisibleHeight() -> CGFloat {
        if let visibleHeightForLayout { return visibleHeightForLayout }
        return window?.screen?.visibleFrame.height ?? 800
    }

    private func commonContentHeight() -> CGFloat {
        min(Self.contentHeightCap, layoutVisibleHeight() - 130)
    }

    private var layingOutPane = false

    /// General, Arrangement, and Advanced take their content height; table panes (Shortcuts, Apps) a fixed height. Including the banner, fit on screen keeping the top edge.
    /// Unchanged while a sheet or menu is open and applied at once when it closes. No animation during validation and recording.
    private func resizePane(animated: Bool = false) {
        if layoutHold > 0 { return }
        guard !layingOutPane, let window, panes[selectedPane] is NSScrollView else { return }
        if window.attachedSheet != nil || openMenuCount > 0 {
            deferredResize = true
            return
        }
        layingOutPane = true
        defer { layingOutPane = false }
        let maxTotal = layoutVisibleHeight() - 130
        let chrome = chromeHeight()
        let height: CGFloat
        switch selectedPane {
        case .general, .layout, .advanced, .about:
            // Content height plus the banner, capped by the screen.
            height = min(maxTotal, max(Self.formHeightFloor, naturalFormHeight() + chrome))
        case .keys, .apps:
            // Table panes have a fixed height; the banner comes out of it and the window does not grow.
            let cap = selectedPane == .keys ? Self.shortcutContentHeight : Self.contentHeightCap
            let preferred = min(cap, max(160, maxTotal))
            let minBody: CGFloat = 160
            if chrome == 0 || preferred - chrome >= minBody {
                height = preferred
            } else {
                height = min(maxTotal, minBody + chrome)
            }
        }
        let top = window.frame.maxY
        let currentHeight = window.contentView?.bounds.height ?? 0
        let currentWidth = window.contentView?.bounds.width ?? 0
        if abs(currentHeight - height) > 0.5 || abs(currentWidth - 720) > 0.5 {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let testing = NSClassFromString("XCTestCase") != nil
            var frame = window.frame
            let content = NSRect(x: 0, y: 0, width: 720, height: height)
            frame.size = window.frameRect(forContentRect: content).size
            frame.origin.x = window.frame.minX
            frame.origin.y = top - frame.height
            // While tests replace the screen height, snapping to the real screen would break position checks.
            if visibleHeightForLayout == nil, let visible = window.screen?.visibleFrame {
                frame = Self.clampedFrame(frame, within: visible)
            }
            if animated, window.isVisible, !reduceMotion, !testing {
                NSAnimationContext.runAnimationGroup({ _ in
                    window.animator().setFrame(frame, display: true)
                }, completionHandler: { [weak self] in
                    self?.reflow()
                })
            } else {
                window.setFrame(frame, display: true)
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        reflow()
    }

    private func flushDeferredResize() {
        guard deferredResize, layoutHold == 0, openMenuCount == 0, window?.attachedSheet == nil else { return }
        deferredResize = false
        resizePane(animated: false)
    }

    /// Banner and recovery area, outside the pane's scroll view; no height when hidden.
    private func chromeHeight() -> CGFloat {
        var height: CGFloat = 0
        for banner in [configBanner, recoveryBanner] where banner.superview != nil && !banner.isHidden {
            banner.layoutSubtreeIfNeeded()
            let fitted = banner.fittingSize.height
            height += fitted > 1 ? fitted : banner.bounds.height
        }
        return height
    }

    /// Measures the form stack at the window's width. The scroll view's fittingSize is circular, so it is not used.
    private func naturalFormHeight() -> CGFloat {
        guard let window, let scroll = panes[selectedPane] as? NSScrollView,
              let document = scroll.documentView,
              let content = document.subviews.first else { return commonContentHeight() }
        window.contentView?.layoutSubtreeIfNeeded()
        guard scroll.contentView.bounds.width > 100 else { return commonContentHeight() }
        content.layoutSubtreeIfNeeded()
        let fitted = content.fittingSize.height
        guard fitted > 1 else { return commonContentHeight() }
        return max(120, ceil(fitted + 48))
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        resizePane()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        resizePane()
    }

    func windowDidResize(_ notification: Notification) {
        guard !layingOutPane else { return }
        reflow()
    }

    /// Matches wrapping widths to the window. Table heights are held by constraints and unchanged here.
    private func reflow() {
        guard let scroll = panes[selectedPane] as? NSScrollView else { return }
        let width = max(200, scroll.contentView.bounds.width - 56)
        for label in [nativeStatusLabel, modeNote, gapError, borderWidthError, ruleError, recoveryLabel, configBannerLabel, shortcutInstruction, rulesEmptyLabel] {
            label.preferredMaxLayoutWidth = width
        }
        gapError.preferredMaxLayoutWidth = 280
        borderWidthError.preferredMaxLayoutWidth = 280
        window?.contentView?.layoutSubtreeIfNeeded()
        updateMessageDetails(recordingLabel.stringValue)
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }
    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }
    private func heading(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 12, weight: .semibold); return t }
    private func caption(_ s: String) -> NSTextField { let t = NSTextField.settingsText( s); t.font = .systemFont(ofSize: 11); t.textColor = .secondaryLabelColor; return t }
    private func label(_ s: String, tip: String? = nil) -> NSTextField { let t = NSTextField(labelWithString: s); t.toolTip = tip; return t }
    private func number(_ field: NSTextField, width: CGFloat = 64) -> NSTextField {
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        if !sizeConstraintsAdded { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        field.delegate = self
        return field
    }
    /// Gives symbol-only buttons a tooltip and an accessibility name.
    private func describe(_ button: NSButton, name: String, tip: String) {
        button.toolTip = tip
        button.setAccessibilityLabel(name)
    }
    private func button(_ title: String, _ sel: Selector) -> NSButton { NSButton(title: title, target: self, action: sel) }
    private func tableScroll(_ table: NSTableView, minimumHeight: CGFloat, rowHeight: CGFloat) -> PaneScrollView {
        let sv = InsetTableScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        let height = sv.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
        height.priority = .required
        height.isActive = true
        sv.flexibleMinimum = minimumHeight
        sv.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        sv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        table.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.rowHeight = rowHeight
        table.allowsMultipleSelection = false
        return sv
    }
    private func column(_ table: NSTableView, _ id: String, _ title: String, width: CGFloat, minWidth: CGFloat = 60) {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title; c.width = width; c.minWidth = minWidth
        table.addTableColumn(c)
    }
    private func removeColumns(_ table: NSTableView) {
        for c in table.tableColumns { table.removeTableColumn(c) }
    }

    private func fieldError(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.isHidden = true
        return label
    }

    private func numberedControl(_ field: NSTextField, unit: String, error: NSTextField) -> NSView {
        _ = number(field)
        return vstack([hstack([field, label(unit)]), fieldError(error)], spacing: 2)
    }

    private func buildGeneral() -> NSView {
        accessIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        accessIcon.setContentHuggingPriority(.required, for: .horizontal)
        for label in [accessCaption, accessHelp] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
        }
        accessCaption.stringValue = SettingsCopy.accessCaption
        accessHelp.stringValue = SettingsCopy.accessHelp
        accessButton.title = SettingsCopy.accessButton
        accessButton.target = self; accessButton.action = #selector(openAccessSettings)
        let accessRow = NSStackView(views: [accessIcon, accessState])
        accessRow.orientation = .horizontal
        accessRow.alignment = .firstBaseline
        accessRow.spacing = 6
        loginBox.title = MacItem.openAtLogin
        loginBox.target = self; loginBox.action = #selector(loginChanged)
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.maximumNumberOfLines = 0
        loginStatus.cell?.wraps = true
        loginSettingsButton.title = L("Open Login Items…", "ログイン項目を開く…")
        loginSettingsButton.target = self; loginSettingsButton.action = #selector(openLoginSettings)
        languagePopup.removeAllItems()
        for choice in SettingsCopy.languageChoices {
            languagePopup.addItem(withTitle: choice.title)
            languagePopup.lastItem?.representedObject = choice.id
        }
        languagePopup.target = self; languagePopup.action = #selector(controlChanged)
        let form = SettingsForm(labelWidth: SettingsPaneLayout.formLabelWidth)
        form.addLabeled(SettingsCopy.accessTitle, accessRow)
        accessCaptionRow = form.addPlain(accessCaption)
        accessButtonRow = form.addPlain(accessButton)
        accessHelpRow = form.addPlain(accessHelp)
        accessHelpRow?.bottomPadding = 10
        form.addPlain(loginBox)
        loginStatusRow = form.addPlain(loginStatus)
        loginSettingsRow = form.addPlain(loginSettingsButton)
        form.addLabeled(L("Language", "言語"), languagePopup)
        notificationBox.title = SettingsCopy.notificationBox
        notificationBox.target = self; notificationBox.action = #selector(controlChanged)
        form.addLabeled(SettingsCopy.notificationsTitle, SettingsForm.checkboxColumn(
            notificationBox, explanation: SettingsCopy.notificationCaption, columnWidth: form.controlColumnWidth))
        notificationStatus.font = .systemFont(ofSize: 11)
        notificationStatus.textColor = .secondaryLabelColor
        notificationStatus.maximumNumberOfLines = 0
        notificationStatus.cell?.wraps = true
        notificationButton.target = self; notificationButton.action = #selector(notificationButtonClicked)
        notificationStatusRow = form.addPlain(notificationStatus)
        notificationButtonRow = form.addPlain(notificationButton)
        loginStatusRow?.isHidden = true
        loginSettingsRow?.isHidden = true
        renderAccess()
        renderNotifications()
        return SettingsPaneLayout.centered(form, width: SettingsForm.width)
    }

    private func buildLayout() -> NSView {
        placementPopup.removeAllItems()
        placementPopup.addItems(withTitles: [L("Beside the focused window", "フォーカス中のウインドウの隣"), L("At the end", "末尾")])
        placementPopup.target = self; placementPopup.action = #selector(controlChanged)
        if !sizeConstraintsAdded {
            placementPreview.translatesAutoresizingMaskIntoConstraints = false
            placementPreview.widthAnchor.constraint(equalToConstant: 42).isActive = true
            placementPreview.heightAnchor.constraint(equalToConstant: 27).isActive = true
        }
        placementPreview.setContentHuggingPriority(.required, for: .horizontal)
        placementPreview.setContentHuggingPriority(.required, for: .vertical)
        placementPreview.setContentCompressionResistancePriority(.required, for: .horizontal)
        placementPreview.setContentCompressionResistancePriority(.required, for: .vertical)
        let placementRow = hstack([placementPopup, placementPreview], spacing: 8)
        gapField.setAccessibilityLabel(L("Window spacing in points", "ウインドウの間隔（ポイント）"))
        borderBox.title = L("Show around the focused window", "フォーカス中のウインドウに表示")
        borderBox.target = self; borderBox.action = #selector(controlChanged)
        _ = number(borderWidthField)
        borderColorWell.target = self; borderColorWell.action = #selector(colorChanged)
        borderColorWell.translatesAutoresizingMaskIntoConstraints = false
        if !sizeConstraintsAdded {
            borderColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
            borderColorWell.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        borderWidthField.setAccessibilityLabel(L("Border width in points", "枠線の太さ（ポイント）"))
        borderColorWell.setAccessibilityLabel(L("Border color", "枠線の色"))
        let form = SettingsForm(labelWidth: SettingsPaneLayout.formLabelWidth)
        dialogsBesideBox.title = L("Keep fixed-size windows next to arranged windows", "大きさが固定のウインドウを整列したウインドウと並べて表示")
        dialogsBesideBox.target = self; dialogsBesideBox.action = #selector(controlChanged)
        form.addPlain(SettingsForm.checkboxColumn(
            dialogsBesideBox,
            explanation: L("Keeps windows like Calculator or alerts from being hidden behind other windows.",
                           "計算機や警告などが、ほかのウインドウで隠れないように並べます。"),
            columnWidth: form.controlColumnWidth
        ))
        form.addLabeled(L("Window spacing", "ウインドウの間隔"), numberedControl(gapField, unit: L("pt (0–200)", "pt（0〜200）"), error: gapError))
        form.addLabeled(L("Place new windows", "新しいウインドウの位置"), placementRow)
        form.addLabeled(L("Border", "枠線"), borderBox)
        borderWidthRow = form.addLabeled(L("Border width", "枠線の太さ"), numberedControl(borderWidthField, unit: L("pt (1–12)", "pt（1〜12）"), error: borderWidthError))
        borderColorRow = form.addLabeled(L("Border color", "枠線の色"), borderColorWell)
        borderWidthRow?.isHidden = true
        borderColorRow?.isHidden = true
        return SettingsPaneLayout.centered(form, width: SettingsForm.width)
    }

    private func buildAbout() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        let name = NSTextField.settingsText("LazySpace")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        for label in [aboutVersion, aboutCopyright] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.isSelectable = true
        }
        let link = LinkButton(title: AboutCopy.repositoryTitle, target: self, action: #selector(openRepository))
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        automaticCheckBox.target = self
        automaticCheckBox.action = #selector(automaticCheckChanged)
        let updates = vstack([updateNotice, updateButton, automaticCheckBox])
        updates.detachesHiddenViews = true
        updateSection = updates
        let column = vstack([icon, name, vstack([aboutVersion, aboutCopyright], spacing: 2), link, updates], spacing: 12)
        column.setCustomSpacing(4, after: name)
        column.detachesHiddenViews = true
        refreshAbout()
        return SettingsPaneLayout.centered(column, width: SettingsForm.width)
    }

    /// Follows the bundle and the updater; called whenever either changes, also while About is shown.
    func refreshAbout() {
        let short = bundleInfo["CFBundleShortVersionString"] as? String ?? "dev"
        aboutVersion.stringValue = AboutCopy.version(short: short, build: bundleInfo["CFBundleVersion"] as? String ?? "")
        aboutCopyright.stringValue = bundleInfo["NSHumanReadableCopyright"] as? String ?? ""
        aboutCopyright.isHidden = aboutCopyright.stringValue.isEmpty
        updateSection?.isHidden = updates == nil
        let offer = updates?.offer
        updateNotice.stringValue = offer.map(UpdateCopy.notice) ?? ""
        updateNotice.isHidden = offer == nil
        updateButton.title = offer == nil ? UpdateCopy.checkButton : UpdateCopy.updateButton
        automaticCheckBox.title = UpdateCopy.automaticCheck
        refreshAutomaticCheck()
        if selectedPane == .about { resizePane() }
    }

    @objc private func openRepository() { openURL(AboutCopy.repository) }

    /// Sparkle can change the setting too (`defaults write`, another copy of LazySpace), so it is read whenever About comes into view.
    private func refreshAutomaticCheck() {
        automaticCheckBox.state = updates?.checksAutomatically == true ? .on : .off
    }

    /// Applies at once, like Open at Login; it is not part of the configuration file.
    @objc private func automaticCheckChanged() {
        updates?.checksAutomatically = automaticCheckBox.state == .on
    }

    /// Installing quits LazySpace, so a pending edit is settled first; cancelling starts nothing.
    @objc private func updateClicked() {
        guard resolveLeave() else { return }
        updates?.checkForUpdates()
    }

    private func buildAdvanced() -> NSView {
        SettingsPaneLayout.sections([SettingsPaneLayout.section(L("Configuration File", "設定ファイル"), [buildFile()])])
    }

    private func buildKeys() -> NSView {
        shortcutGuideBox.title = L("Show shortcuts when holding modifier keys", "修飾キーの長押しでショートカットを表示")
        shortcutGuideBox.target = self; shortcutGuideBox.action = #selector(controlChanged)
        removeColumns(keysTable)
        keysTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        column(keysTable, "label", SettingsCopy.keyColumns[0], width: 404, minWidth: 240)
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.title = SettingsCopy.keyColumns[1]
        keyColumn.width = 216
        keyColumn.minWidth = 120
        keyColumn.resizingMask = .autoresizingMask
        keysTable.addTableColumn(keyColumn)
        if let labelColumn = keysTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("label")) {
            labelColumn.resizingMask = .userResizingMask
        }
        keysTable.doubleAction = #selector(recordClickedKey(_:))
        keysTable.target = self
        keysTable.floatsGroupRows = false
        keysTable.onDelete = { [weak self] in self?.removeKeyAction() }
        keysTable.onRestore = { [weak self] in self?.restoreSelectedShortcut() }
        keysTable.onReturn = { [weak self] in self?.handleShortcutReturn() }
        shortcutContextMenu.autoenablesItems = false
        shortcutContextMenu.delegate = self
        keysTable.menu = shortcutContextMenu
        keySearch.placeholderString = L("Search Actions", "操作を検索")
        keySearch.target = self
        keySearch.action = #selector(searchKeys)
        keySearch.delegate = self
        keySearch.sendsSearchStringImmediately = true
        keySearch.sendsWholeSearchString = true
        keySearch.onFocus = { [weak self] in
            guard let self, self.recordingTarget != nil, !self.transferringShortcutFocus else { return }
            self.endRecording(.cancelShow)
        }
        keysTable.allowsEmptySelection = true
        restoreMainButton.title = L("Restore Defaults", "デフォルトに戻す")
        restoreMainButton.target = self; restoreMainButton.action = #selector(restoreMainShortcuts)
        restoreMainButton.toolTip = L("Restore every shortcut in this list to its default.",
                                      "この一覧のショートカットをすべてデフォルトに戻します。")
        shortcutInstruction.stringValue = L("To change a shortcut, double-click it or press Return, then type the new keys. Delete removes it; Option-Delete restores its default; Esc cancels.",
                                            "ショートカットを変更するには、ダブルクリックするかReturnを押して新しいキーを入力します。Deleteで解除、⌥Deleteでデフォルトに戻し、Escでキャンセルします。")
        shortcutInstruction.font = .systemFont(ofSize: 11)
        shortcutInstruction.textColor = .secondaryLabelColor
        shortcutInstruction.maximumNumberOfLines = 0
        shortcutInstruction.cell?.wraps = true
        messageDetailsButton.title = L("Details…", "詳細…")
        messageDetailsButton.target = self
        messageDetailsButton.action = #selector(showShortcutMessageDetails)
        messageDetailsButton.bezelStyle = .inline
        messageDetailsButton.controlSize = .small
        messageDetailsButton.isHidden = true
        messageDetailsButton.setAccessibilityLabel(L("Details…", "詳細…"))
        prepareMessage(recordingLabel)
        recordingLabel.setAccessibilityLabel(L("Shortcut Message", "ショートカットの案内"))
        prepareMessage(nativeStatusLabel)
        nativeStatusLabel.textColor = .labelColor
        nativeStatusLabel.setAccessibilityLabel(L("Space Switching Status", "操作スペース切り替えの状態"))
        nativeStatusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L("Warning", "警告"))
        nativeStatusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        nativeStatusIcon.contentTintColor = .systemOrange
        nativeStatusIcon.setContentHuggingPriority(.required, for: .horizontal)
        keyboardSettingsButton.title = L("Open Keyboard Settings…", "キーボード設定を開く…")
        keyboardSettingsButton.target = self; keyboardSettingsButton.action = #selector(openKeyboardSettings)
        keyboardSettingsHint.stringValue = L("Keyboard Shortcuts… › Mission Control", "キーボードショートカット… › Mission Control")
        keyboardSettingsHint.font = .systemFont(ofSize: 11)
        keyboardSettingsHint.textColor = .secondaryLabelColor
        modeNote.font = .systemFont(ofSize: 11)
        modeNote.textColor = .secondaryLabelColor
        modeNote.maximumNumberOfLines = 0
        modeNote.cell?.wraps = true
        modeFileButton.title = L("Open File", "ファイルを開く")
        modeFileButton.target = self; modeFileButton.action = #selector(openFile)
        modeFileButton.setContentHuggingPriority(.required, for: .horizontal)
        let modes = hstack([modeNote, modeFileButton])
        modes.alignment = .firstBaseline
        modeNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeRow = modes
        if !sizeConstraintsAdded {
            keySearch.translatesAutoresizingMaskIntoConstraints = false
            keySearch.widthAnchor.constraint(equalToConstant: 240).isActive = true
            keySearch.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        keySearch.setContentHuggingPriority(.required, for: .horizontal)
        keySearch.setContentCompressionResistancePriority(.required, for: .horizontal)
        keySearch.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        shortcutGuideBox.setContentHuggingPriority(.required, for: .horizontal)
        shortcutGuideBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRow = hstack([keySearch, spacer, shortcutGuideBox])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let table = tableScroll(keysTable, minimumHeight: 160, rowHeight: 26)
        keysScroll = table
        let statusRow = NSStackView(views: [nativeStatusIcon, nativeStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 6
        nativeStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Shown only with a warning; its contents are reread on every display.
        statusRow.isHidden = true
        nativeStatusRow = statusRow
        let keyboard = hstack([keyboardSettingsButton, keyboardSettingsHint])
        keyboard.isHidden = true
        keyboardRow = keyboard
        let gap = NSView()
        gap.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        gap.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        shortcutActionGap = gap
        let actions = hstack([restoreMainButton, gap, recordingLabel, messageDetailsButton])
        actions.detachesHiddenViews = true
        messageDetailsButton.setContentHuggingPriority(.required, for: .horizontal)
        messageDetailsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutActionRow = actions
        return SettingsPaneLayout.sections([
            topRow,
            shortcutInstruction,
            table,
            actions,
            statusRow,
            keyboard,
            modes,
        ], spacing: 8, flexible: table)
    }

    private func buildRules() -> NSView {
        removeColumns(rulesTable)
        column(rulesTable, "name", SettingsCopy.ruleAppColumn, width: 180)
        column(rulesTable, "app", SettingsCopy.ruleIdentifierColumn, width: 430)
        rulesTable.headerView = nil
        configurePlusMinus(addRuleButton, add: true)
        addRuleButton.target = self
        addRuleButton.action = #selector(showAddRuleMenu)
        addRuleMenu.delegate = self
        configurePlusMinus(removeRuleButton, add: false)
        removeRuleButton.target = self; removeRuleButton.action = #selector(removeRuleAction)
        describe(addRuleButton, name: L("Add App", "アプリを追加"), tip: L("Add an app whose windows stay out of the arrangement.", "整列しないアプリを追加します。"))
        describe(removeRuleButton, name: L("Remove Selected Rule", "選択したルールを削除"), tip: L("Remove the selected rule.", "選択したルールを削除します。"))
        rulesEmptyLabel.stringValue = L("No apps\nClick + to add one.",
                                        "アプリはありません\n＋ で追加します。")
        rulesEmptyLabel.alignment = .center
        rulesEmptyLabel.maximumNumberOfLines = 3
        rulesEmptyLabel.font = .systemFont(ofSize: 12)
        rulesEmptyLabel.textColor = .secondaryLabelColor
        let table = tableScroll(rulesTable, minimumHeight: 160, rowHeight: 26)
        rulesScroll = table
        prepareMessage(ruleError)
        ruleError.textColor = .systemRed
        ruleError.isHidden = true
        let host = overlay(rulesEmptyLabel, on: table)
        return SettingsPaneLayout.sections([
            caption(L("Windows of these apps aren't arranged.", "これらのアプリのウインドウは整列しません。")),
            host,
            ruleError,
            hstack([addRuleButton, removeRuleButton]),
        ], spacing: 12, flexible: host)
    }

    /// Puts the empty-state hint in front of the scroll view's clip view; added directly under NSScrollView, the table would hide it.
    private func overlay(_ label: NSTextField, on scroll: NSView) -> NSView {
        let host = FlexibleOverlay(flexible: scroll)
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
        ])
        return host
    }

    /// + / -, with a fixed width that fits the symbol.
    private func configurePlusMinus(_ button: NSButton, add: Bool) {
        let name = add ? NSImage.addTemplateName : NSImage.removeTemplateName
        button.image = NSImage(named: name)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.imageScaling = .scaleProportionallyDown
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !sizeConstraintsAdded {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
    }

    private func buildFile() -> NSView {
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.cell?.wraps = true
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.isSelectable = true
        pathLabel.maximumNumberOfLines = 0
        return SettingsPaneLayout.sections([
            pathLabel,
            caption(SettingsCopy.fileCaption()),
            hstack([
                button(L("Open File", "ファイルを開く"), #selector(openFile)),
                button(L("Show in Finder", "Finderで表示"), #selector(reveal)),
                button(L("Command-Line Setup…", "コマンドラインの設定…"), #selector(showCLIHelp)),
            ]),
            errorLabel,
        ], spacing: 12)
    }

    /// Shortcut messages take one line in the button row.
    /// Native status and rule errors are shown in full.
    private func prepareMessage(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        for constraint in label.constraints where constraint.identifier == "status-height" {
            constraint.isActive = false
        }
        if label === recordingLabel {
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.lineBreakMode = .byTruncatingTail
            label.alignment = .right
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentHuggingPriority(.required, for: .vertical)
            label.isHidden = false
        } else {
            label.maximumNumberOfLines = 0
            label.cell?.truncatesLastVisibleLine = false
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentHuggingPriority(.required, for: .vertical)
        }
    }

    private var reservedStatusHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        return ceil(font.boundingRectForFont.height) * 2
    }

    // MARK: - Updating the display

    /// Takes in the file's state, without overwriting fields being typed or a failed save.
    func refresh() {
        if refreshing { return }
        refreshing = true
        layoutHold += 1
        defer {
            refreshing = false
            layoutHold -= 1
            if layoutHold == 0 { resizePane(animated: false) }
        }
        let rebuild = builtLanguage != Copy.language
        if rebuild {
            build()
            rendered = nil
            if !recoveryText.isEmpty { showRecovery(recoveryText, allowRetry: recoveryAllowsRetry) }
        }
        let status = coordinator.status()
        applyFileChrome(status)
        let effective = coordinator.config
        if !editorBlocksRefresh {
            saved = effective
            pending = nil
            externalChange = false
            invalidFields.removeAll()
            uncommittedNumbers.removeAll()
            ruleEdit = nil
            clearRecovery()
        } else if status.configError == nil, effective != saved {
            externalChange = true
            if pending == nil { showRecovery(SettingsCopy.externalChangeMessage, allowRetry: false) }
        }
        if rebuild || rendered != draft { renderDraft() }
        else { updateChrome() }
        if selectedPane == .keys { refreshNativeShortcuts() }
    }

    private func applyFileChrome(_ status: AppStatus) {
        pathLabel.stringValue = status.configPath
        let notes = status.configNotes
        let message = status.configError ?? (notes.isEmpty ? nil : notes.joined(separator: "\n"))
        configBannerLabel.stringValue = status.configError == nil && !notes.isEmpty ? SettingsCopy.configNotesMessage : SettingsCopy.configBannerMessage
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        let wasHidden = configBanner.isHidden
        configBanner.isHidden = message == nil
        if wasHidden != configBanner.isHidden { resizePane() }
    }

    /// Shows read errors and non-fatal notes in the banner. Leaves the draft, recording, and number fields alone.
    func applyConfigStatus(_ error: String?, isError: Bool = true) {
        configBannerLabel.stringValue = isError ? SettingsCopy.configBannerMessage : SettingsCopy.configNotesMessage
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        let wasHidden = configBanner.isHidden
        configBanner.isHidden = error == nil
        if wasHidden != configBanner.isHidden { resizePane() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshAccess()
        refreshNativeShortcuts()
        refreshAutomaticCheck()
        // Notifications may have been allowed or turned off in System Settings meanwhile.
        if notificationBox.state == .on { attention?.refreshPermission() }
    }

    /// One line and a button, only while the box is on and macOS does not allow LazySpace to send notifications.
    func renderNotifications() {
        let before = notificationStatusRow?.isHidden
        let permission = notificationBox.state == .on ? attention?.permission : nil
        switch permission {
        case .denied?:
            notificationStatus.stringValue = SettingsCopy.notificationsDenied
            notificationButton.title = SettingsCopy.accessButton
        case .notDetermined?:
            notificationStatus.stringValue = SettingsCopy.notificationsNotYet
            notificationButton.title = SettingsCopy.allowNotifications
        case .allowed?, nil:
            break
        }
        let hidden = permission == nil || permission == .allowed
        notificationStatus.isHidden = hidden
        notificationButton.isHidden = hidden
        notificationStatusRow?.isHidden = hidden
        notificationButtonRow?.isHidden = hidden
        if before != nil, before != hidden { resizePane() }
    }

    @objc private func notificationButtonClicked() {
        if attention?.permission == .notDetermined { attention?.requestAuthorization() } else { attention?.openSettings() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if claimingRecordingFocus { return }
        let resigned = notification.object as? NSWindow
        if let resigned, resigned !== window { return }
        if recordingTarget != nil {
            endRecording(.cancelShow)
            return
        }
        if hotkeyHoldOwner == nil || hotkeyHoldOwner === window {
            resolveHotkeysAfterOwnerLeft()
        }
    }

    private func handleApplicationResigned() {
        guard resumeHotkeysOnKeyUp != nil else { return }
        resolveHotkeysAfterOwnerLeft()
    }

    @objc private func showConfigDetails() {
        finishActiveEditors()
        endRecording(.clearTransient)
        clearTransientShortcutStatus()
        showPane(.advanced, animated: true)
    }

    private func renderDraft() {
        let c = draft
        if !uncommittedNumbers.contains(.gap) { gapField.stringValue = Config.number(c.gap) }
        placementPopup.selectItem(at: c.newWindowPlacement == .besideFocused ? 0 : 1)
        renderPlacementPreview()
        dialogsBesideBox.state = c.placeDialogsBeside ? .on : .off
        renderLogin()
        renderAccess()
        languagePopup.selectItem(at: max(0, languagePopup.indexOfItem(withRepresentedObject: SettingsRules.languageID(c.language))))
        shortcutGuideBox.state = c.showShortcutGuide ? .on : .off
        borderBox.state = c.focusBorder.enabled ? .on : .off
        notificationBox.state = c.notifications.needsAttention ? .on : .off
        renderNotifications()
        if !uncommittedNumbers.contains(.borderWidth) { borderWidthField.stringValue = Config.number(c.focusBorder.width) }
        if let (r, g, b, a) = c.focusBorder.rgba { borderColorWell.color = NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

        updateAppearanceDetails()
        renderShortcuts()

        rebuildAddRuleMenu()
        rulesEmptyLabel.isHidden = !draft.rules.isEmpty
        rulesTable.reloadData()
        if let message = ruleEdit?.message {
            ruleError.stringValue = message
            ruleError.isHidden = false
        } else {
            ruleError.stringValue = ""
            ruleError.isHidden = true
        }
        updateModeNote()
        updateShortcutButtons()
        updateSelectionButtons()
        updateChrome()
        rendered = draft
        resizePane(animated: false)
        revealClippedValidationErrors()
    }

    private func renderShortcuts() {
        let names = Config.commandNames.filter { !$0.hasPrefix("mode-") }
        let commands = names.compactMap { name -> (name: String, label: String)? in
            guard let action = HotkeyBinding.action(forCommand: name) else { return nil }
            return (name, HotkeyBinding(keyCode: 0, modifiers: 0, action: action, display: "").label)
        }
        let previousIndex = keysTable.selectedRow
        let token: ShortcutSelection? = {
            if previousIndex >= 0, previousIndex < keyRows.count { return identity(of: keyRows[previousIndex]) }
            return shortcutSelection
        }()
        let reconcile = reconcileMissingShortcut
        reconcileMissingShortcut = false
        let origin = keysScroll?.contentView.bounds.origin
        shortcutSelection = token
        keyRows = ShortcutList.rows(commands: commands, saved: saved.keys, draft: draft.keys, search: keySearch.stringValue)
        if let target = recordingTarget, !recordingTargetIsVisible(target) { endRecording(.cancelShow) }
        restoringSelection = true
        keysTable.reloadData()
        if let token, let row = keyRows.firstIndex(where: { identity(of: $0) == token }) {
            shortcutSelection = token
            keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if reconcile, token != nil, let neighbor = neighborRow(afterRemoving: previousIndex) {
            shortcutSelection = identity(of: keyRows[neighbor])
            keysTable.selectRowIndexes(IndexSet(integer: neighbor), byExtendingSelection: false)
        } else {
            keysTable.deselectAll(nil)
        }
        restoringSelection = false
        restoreScroll(origin)
        updateShortcutButtons()
        renderNativeStatus()
        reflow()
    }

    /// The selectable row that took a removed row's place, or the one before.
    private func neighborRow(afterRemoving index: Int) -> Int? {
        let forward = index >= 0 ? selectableShortcutRow(atOrAfter: index) : nil
        if let forward { return forward }
        return selectableShortcutRow(before: index)
    }

    private func selectableShortcutRow(atOrAfter index: Int) -> Int? {
        guard index >= 0, index < keyRows.count else { return nil }
        for row in index..<keyRows.count where isSelectableShortcutRow(row) { return row }
        return nil
    }

    private func selectableShortcutRow(before index: Int) -> Int? {
        let start = min(index, keyRows.count) - 1
        guard start >= 0 else { return nil }
        for row in stride(from: start, through: 0, by: -1) where isSelectableShortcutRow(row) { return row }
        return nil
    }

    private func isSelectableShortcutRow(_ row: Int) -> Bool {
        guard keyRows.indices.contains(row) else { return false }
        if case .heading = keyRows[row] { return false }
        return true
    }

    private func restoreScroll(_ origin: NSPoint?) {
        guard let origin, let scroll = keysScroll else { return }
        let clip = scroll.contentView
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func searchKeys() {
        if case .command = recordingTarget { endRecording(.cancelShow) }
        renderShortcuts()
    }

    private func updateChrome() {
        window?.isDocumentEdited = needsAttention
        if pending == nil, invalidFields.isEmpty, ruleEdit == nil, !externalChange {
            clearRecovery()
        }
    }

    private func showRecovery(_ text: String, allowRetry: Bool) {
        recoveryText = text
        recoveryAllowsRetry = allowRetry
        recoveryLabel.stringValue = text
        recoveryLabel.preferredMaxLayoutWidth = max(200, (window?.contentView?.bounds.width ?? 720) - 48)
        retryButton.isHidden = !allowRetry
        retryButton.title = SettingsCopy.tryAgainTitle
        reloadButton.title = SettingsCopy.reloadTitle
        recoveryLabel.setAccessibilityLabel(L("Settings Recovery", "設定の復旧"))
        let wasHidden = recoveryBanner.superview == nil
        if wasHidden {
            let index = paneStack.arrangedSubviews.firstIndex(of: configBanner).map { $0 + 1 } ?? 0
            paneStack.insertArrangedSubview(recoveryBanner, at: index)
            recoveryWidth?.isActive = false
            let width = recoveryBanner.widthAnchor.constraint(equalTo: paneStack.widthAnchor)
            width.isActive = true
            recoveryWidth = width
        }
        recoveryBanner.isHidden = false
        window?.isDocumentEdited = needsAttention
        if wasHidden { resizePane() }
    }

    private func clearRecovery() {
        recoveryText = ""
        recoveryAllowsRetry = false
        recoveryLabel.stringValue = ""
        guard recoveryBanner.superview != nil else { return }
        recoveryBanner.isHidden = true
        paneStack.removeArrangedSubview(recoveryBanner)
        recoveryBanner.removeFromSuperview()
        resizePane()
    }

    /// Writes a completed change once, based on the current file. Identical contents are not written; a failure is never called saved.
    @discardableResult
    private func commit(_ proposed: Config) -> Bool {
        let candidate = SettingsRules.normalized(proposed)
        if candidate == saved {
            if pending != nil {
                pending = nil
                externalChange = false
                clearRecovery()
                clearStickyShortcutFailure()
                renderDraft()
            } else {
                updateChrome()
            }
            return true
        }
        if committing { return false }
        committing = true
        defer { committing = false }
        if let problem = coordinator.saveConfig(candidate, baseline: saved, source: "settings-window") {
            pending = candidate
            showRecovery(problem, allowRetry: true)
            renderDraft()
            return false
        }
        saved = coordinator.config
        pending = nil
        externalChange = false
        clearRecovery()
        clearStickyShortcutFailure()
        if builtLanguage != Copy.language {
            build()
            rendered = nil
        }
        renderDraft()
        return true
    }

    @objc private func retrySave() {
        guard let pending else { return }
        commit(pending)
    }

    @objc private func reloadFromFile() {
        discardLocalEdits()
    }

    /// Discards the failed save and invalid fields and rereads the file.
    private func discardLocalEdits() {
        stopRecording()
        invalidFields.removeAll()
        uncommittedNumbers.removeAll()
        ruleEdit = nil
        gapError.isHidden = true
        gapError.stringValue = ""
        borderWidthError.isHidden = true
        borderWidthError.stringValue = ""
        ruleError.isHidden = true
        ruleError.stringValue = ""
        pending = nil
        externalChange = false
        clearRecovery()
        commandStatusSticky = false
        stickyFailureText = ""
        setShortcutMessage("", warning: false)
        _ = coordinator.reloadConfig(source: "settings-reload")
        saved = coordinator.config
        rendered = nil
        refresh()
    }

    /// Commits valid number fields; invalid ones stay as they are and others are not read.
    private func finishActiveEditors() {
        window?.makeFirstResponder(nil)
        if uncommittedNumbers.contains(.gap) { finishNumber(gapField, .gap, 0...200, error: gapError) }
        if uncommittedNumbers.contains(.borderWidth) { finishNumber(borderWidthField, .borderWidth, 1...12, error: borderWidthError) }
    }

    // MARK: - General pane

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? RuleTextField else { return }
        noteRuleEdit(field, replacingOriginal: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === keySearch { searchKeys(); return }
        guard let field = obj.object as? NSTextField else { return }
        if field === gapField { previewNumber(field, .gap, 0...200, error: gapError) }
        else if field === borderWidthField { previewNumber(field, .borderWidth, 1...12, error: borderWidthError) }
        else if let ruleField = field as? RuleTextField { noteRuleEdit(ruleField, replacingOriginal: false) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === gapField { finishNumber(field, .gap, 0...200, error: gapError) }
        else if field === borderWidthField { finishNumber(field, .borderWidth, 1...12, error: borderWidthError) }
        else if let ruleField = field as? RuleTextField { finishRuleEdit(ruleField) }
    }

    @objc private func controlChanged() {
        endRecording(.cancelShow)
        var next = draft
        let placement: Config.NewWindowPlacement = placementPopup.indexOfSelectedItem == 0 ? .besideFocused : .end
        var changed = false
        if next.newWindowPlacement != placement { next.newWindowPlacement = placement; changed = true }
        if next.placeDialogsBeside != (dialogsBesideBox.state == .on) { next.placeDialogsBeside = dialogsBesideBox.state == .on; changed = true }
        if let id = languagePopup.selectedItem?.representedObject as? String, id != SettingsRules.languageID(next.language) {
            next.language = id
            changed = true
        }
        if next.showShortcutGuide != (shortcutGuideBox.state == .on) { next.showShortcutGuide = shortcutGuideBox.state == .on; changed = true }
        if next.focusBorder.enabled != (borderBox.state == .on) { next.focusBorder.enabled = borderBox.state == .on; changed = true }
        if next.notifications.needsAttention != (notificationBox.state == .on) { next.notifications.needsAttention = notificationBox.state == .on; changed = true }
        guard changed else { return }
        commit(next)
        updateAppearanceDetails()
    }

    @objc private func colorChanged() {
        endRecording(.cancelShow)
        guard let c = borderColorWell.color.usingColorSpace(.sRGB) else { return }
        let nextColor = (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)), Int(round(c.alphaComponent * 255)))
        if let current = Config.parseColor(draft.focusBorder.color) {
            let stored = (Int(round(current.0 * 255)), Int(round(current.1 * 255)), Int(round(current.2 * 255)), Int(round(current.3 * 255)))
            if stored == nextColor { return }
        }
        var next = draft
        next.focusBorder.color = nextColor.3 == 255
            ? String(format: "#%02X%02X%02X", nextColor.0, nextColor.1, nextColor.2)
            : String(format: "#%02X%02X%02X%02X", nextColor.0, nextColor.1, nextColor.2, nextColor.3)
        commit(next)
    }

    @objc private func loginChanged() {
        endRecording(.cancelShow)
        var next = draft
        let enabled = loginBox.state == .on
        guard next.startAtLogin != enabled else { return }
        next.startAtLogin = enabled
        commit(next)
    }

    @objc private func openLoginSettings() { LoginItem.openSystemSettings() }

    /// Shows the registration dialog and opens the System Settings list. If a registration remains in the list, no dialog appears.
    @objc private func openAccessSettings() {
        AXTrust.requestPrompt()
        AXTrust.openSystemSettings()
    }

    /// Rereads the permission state, leaving the draft and fields being typed alone.
    func refreshAccess() {
        let before = accessButtonRow?.isHidden
        renderAccess()
        if before != accessButtonRow?.isHidden { resizePane() }
    }

    private func renderAccess() {
        let trusted = AXTrust.isTrusted()
        accessIcon.image = NSImage(
            systemSymbolName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil)
        accessIcon.contentTintColor = trusted ? .systemGreen : .systemOrange
        accessState.stringValue = trusted ? SettingsCopy.accessAllowed : SettingsCopy.accessNotAllowed
        accessState.setAccessibilityLabel(SettingsCopy.accessTitle)
        accessButton.isHidden = trusted
        accessButtonRow?.isHidden = trusted
        accessHelp.isHidden = trusted
        accessHelpRow?.isHidden = trusted
        // Space between the permission row and login items; without permission, the space goes below the caption.
        accessCaptionRow?.bottomPadding = trusted ? 10 : 0
    }

    private func renderLogin() {
        let state = LoginItem.state()
        loginBox.state = (draft.startAtLogin ?? (state == .enabled || state == .requiresApproval)) ? .on : .off
        loginSettingsButton.isHidden = true
        loginSettingsRow?.isHidden = true
        loginStatus.isHidden = true
        loginStatusRow?.isHidden = true
        loginBox.isEnabled = true
        if state == .requiresApproval {
            loginStatus.stringValue = L("Allow LazySpace in \(MacItem.loginItems()) to finish setup.", "「\(MacItem.loginItems())」でLazySpaceを許可すると有効になります。")
            loginStatus.isHidden = false
            loginStatusRow?.isHidden = false
            loginSettingsButton.isHidden = false
            loginSettingsRow?.isHidden = false
        } else if case .unavailable(let reason) = state {
            loginBox.isEnabled = false
            loginStatus.stringValue = reason
            loginStatus.isHidden = false
            loginStatusRow?.isHidden = false
        } else if let wanted = draft.startAtLogin, wanted != (state == .enabled), !needsAttention {
            loginStatus.stringValue = L("The macOS login setting differs. Check \(MacItem.loginItems()).", "macOSのログイン設定と一致していません。「\(MacItem.loginItems())」を確認してください。")
            loginStatus.isHidden = false
            loginStatusRow?.isHidden = false
            loginSettingsButton.isHidden = false
            loginSettingsRow?.isHidden = false
        }
    }

    private func updateAppearanceDetails() {
        let hidden = !draft.focusBorder.enabled
        borderWidthRow?.isHidden = hidden
        borderColorRow?.isHidden = hidden
    }

    private func previewNumber(_ field: NSTextField, _ key: NumericField, _ range: ClosedRange<Double>, error: NSTextField) {
        uncommittedNumbers.insert(key)
        if SettingsRules.parsedNumber(field.stringValue, in: range) != nil {
            invalidFields.remove(key)
            error.isHidden = true
            error.stringValue = ""
        } else {
            invalidFields.insert(key)
            showNumberError(error, range: range)
        }
        updateChrome()
        revealClippedValidationErrors(preferred: field)
    }

    private func finishNumber(_ field: NSTextField, _ key: NumericField, _ range: ClosedRange<Double>, error: NSTextField) {
        guard let value = SettingsRules.parsedNumber(field.stringValue, in: range) else {
            invalidFields.insert(key)
            uncommittedNumbers.insert(key)
            showNumberError(error, range: range)
            updateChrome()
            revealClippedValidationErrors(preferred: field)
            return
        }
        invalidFields.remove(key)
        uncommittedNumbers.remove(key)
        error.isHidden = true
        error.stringValue = ""
        field.stringValue = Config.number(value)
        var next = draft
        switch key {
        case .gap:
            guard next.gap != value else { updateChrome(); return }
            next.gap = value
        case .borderWidth:
            guard next.focusBorder.width != value else { updateChrome(); return }
            next.focusBorder.width = value
        }
        commit(next)
    }

    private func showNumberError(_ error: NSTextField, range: ClosedRange<Double>) {
        error.stringValue = SettingsRules.numberError(range: range)
        error.isHidden = false
    }

    private var revealingError = false

    /// Scrolls to show only gap and border errors clipped by the pane, then returns input focus.
    private func revealClippedValidationErrors(preferred field: NSTextField? = nil) {
        guard selectedPane == .layout, !layingOutPane, !revealingError else { return }
        revealingError = true
        defer { revealingError = false }
        let activeField = field ?? (window?.firstResponder as? NSTextField)
            ?? ((window?.firstResponder as? NSTextView)?.delegate as? NSTextField)
        let errors = activeField === gapField ? [gapError]
            : activeField === borderWidthField ? [borderWidthError] : [gapError, borderWidthError]
        for error in errors {
            guard !error.isHiddenOrHasHiddenAncestor, error.window != nil, let scroll = error.enclosingScrollView else { continue }
            scroll.layoutSubtreeIfNeeded()
            let clip = scroll.contentView.bounds
            guard clip.height > 1 else { continue }
            let frame = error.convert(error.bounds, to: scroll.contentView)
            if clip.insetBy(dx: 0, dy: -1).contains(frame) { continue }
            let responder = window?.firstResponder
            error.scrollToVisible(error.bounds)
            if window?.firstResponder !== responder {
                window?.makeFirstResponder(responder)
            }
            break
        }
    }

    // MARK: - Shortcuts pane

    /// Does nothing if the same action is already recording; for another action, ends the current recording first.
    private func beginRecording(_ name: String) {
        if case .command(let current, _) = recordingTarget, current == name {
            focusShortcutTable()
            return
        }
        guard rowIndex(forCommand: name) != nil else { return }
        startRecording(.command(name, mode: currentMode))
    }

    @objc private func recordClickedKey(_ table: NSTableView) {
        let row = table.clickedRow
        guard table === keysTable, keyRows.indices.contains(row), case .command(let name, _) = keyRows[row] else { return }
        beginRecording(name)
    }

    private func handleShortcutReturn() {
        let row = keysTable.selectedRow
        guard keyRows.indices.contains(row) else { return }
        switch keyRows[row] {
        case .command(let name, _):
            beginRecording(name)
        case .direction:
            focusDirectionPopup(row)
        case .heading:
            break
        }
    }

    @objc private func removeKeyAction() {
        guard keyRows.indices.contains(keysTable.selectedRow) else { return }
        removeShortcutSelection(identity(of: keyRows[keysTable.selectedRow]))
    }

    private func restoreSelectedShortcut() {
        guard recordingTarget == nil else { return }
        let row = keysTable.selectedRow
        guard canRestore(row) else { NSSound.beep(); return }
        restoreShortcutSelection(identity(of: keyRows[row]))
    }

    /// Uses only the context menu's identifier; without one, it is not the selected row.
    private func validatedSelection(_ sender: Any?) -> ShortcutSelection? {
        guard let item = sender as? NSMenuItem,
              let token = item.representedObject as? ShortcutActionToken,
              keyRows.contains(where: { identity(of: $0) == token.selection }) else { return nil }
        return token.selection
    }

    @objc private func changeShortcutAction(_ sender: Any?) {
        guard let selection = validatedSelection(sender) else { return }
        switch selection {
        case .command(let name):
            beginRecording(name)
        case .direction:
            guard let row = rowIndex(for: selection) else { return }
            if keysTable.selectedRow != row {
                keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            focusDirectionPopup(row)
        case .heading:
            break
        }
    }

    @objc private func removeShortcutAction(_ sender: Any?) {
        removeShortcutSelection(validatedSelection(sender))
    }

    @objc private func restoreShortcutAction(_ sender: Any?) {
        restoreShortcutSelection(validatedSelection(sender))
    }

    private func restoreShortcutSelection(_ selection: ShortcutSelection?) {
        guard let selection, let row = rowIndex(for: selection) else { return }
        if recordingTarget != nil { endRecording(.cancelShow, restoreTableFocus: false) }
        resetShortcut(at: row)
        focusShortcutTable()
    }

    private func removeShortcutSelection(_ selection: ShortcutSelection?) {
        guard let selection, let row = rowIndex(for: selection) else { return }
        if recordingTarget != nil { endRecording(.cancelShow, restoreTableFocus: false) }
        let label = shortcutActionLabel(selection)
        guard removeShortcut(at: row) else {
            focusShortcutTable()
            return
        }
        announce(Self.removedShortcut(label))
        focusShortcutTable()
    }

    private func focusDirectionPopup(_ row: Int) {
        guard let popup = directionPopup(tag: 1, row: row) ?? directionPopup(tag: 2, row: row) else { return }
        window?.makeFirstResponder(popup)
        // Menu tracking would block tests: check up to focus here, and open the menu only in a real run.
        if NSClassFromString("XCTestCase") == nil, window?.isVisible == true {
            popup.performClick(nil)
        }
    }

    private func directionPopup(tag: Int, row: Int) -> NSPopUpButton? {
        let column = keysTable.column(withIdentifier: NSUserInterfaceItemIdentifier("key"))
        guard column >= 0, let cell = keysTable.view(atColumn: column, row: row, makeIfNecessary: true) else { return nil }
        return popup(in: cell, tag: tag)
    }

    private func popup(in view: NSView, tag: Int) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.tag == tag { return popup }
        for subview in view.subviews {
            if let found = popup(in: subview, tag: tag) { return found }
        }
        return nil
    }

    /// Recorder actions return keyboard focus to the table; the search field's begin hook does not clear the recording.
    private func focusShortcutTable() {
        guard let window, window.firstResponder !== keysTable else { return }
        transferringShortcutFocus = true
        window.makeFirstResponder(keysTable)
        transferringShortcutFocus = false
    }

    private func rowIndex(forCommand name: String) -> Int? {
        keyRows.firstIndex { $0.commandName == name }
    }

    private func rowIndex(for selection: ShortcutSelection) -> Int? {
        keyRows.firstIndex { identity(of: $0) == selection }
    }

    private func shortcutActionLabel(_ selection: ShortcutSelection) -> String {
        switch selection {
        case .command(let name): return labelForCommand(name)
        case .direction(let group): return group.title
        case .heading(let section): return section.title
        }
    }

    private func selectShortcut(_ name: String, row: Int) {
        suppressSelectionSideEffects = true
        shortcutSelection = .command(name)
        keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionSideEffects = false
        updateShortcutButtons()
    }

    private static func removedShortcut(_ label: String) -> String {
        L("Removed the shortcut from “\(label)”.", "「\(label)」の割り当てを解除しました。")
    }

    /// Resets only main's keys to defaults, leaving mode contents alone.
    /// `mode-<name>` entries into user-declared modes stay; if such an entry collides with a default key, the whole reset is refused.
    @objc private func restoreMainShortcuts() {
        let conflicts = mainDefaultModeEntryConflicts()
        guard conflicts.isEmpty else {
            setShortcutMessage(conflicts.joined(separator: Copy.sentenceSeparator), warning: true)
            return
        }
        let confirmed: Bool
        if let confirmMainShortcutReset {
            confirmed = confirmMainShortcutReset()
        } else {
            let alert = NSAlert()
            alert.messageText = L("Restore all shortcuts to their defaults?", "すべてのショートカットをデフォルトに戻しますか？")
            alert.informativeText = L("Every shortcut in this list returns to its default.",
                                      "この一覧のショートカットをすべてデフォルトに戻します。")
            alert.addButton(withTitle: L("Restore Defaults", "デフォルトに戻す"))
            alert.addButton(withTitle: L("Cancel", "キャンセル"))
            confirmed = alert.runModal() == .alertFirstButtonReturn
        }
        if recordingTarget != nil { endRecording(.cancelShow, restoreTableFocus: false) }
        guard confirmed else { return }
        var next = draft
        next.keys = keysAfterMainShortcutReset()
        reconcileMissingShortcut = true
        let savedOK = commit(next)
        guard savedOK else {
            let message = Self.notApplied
            setShortcutMessage(message, warning: true)
            announce(message)
            return
        }
        commandStatusSticky = false
        stickyFailureText = ""
        setShortcutMessage("", warning: false)
        announce(L("Restored default shortcuts.", "ショートカットをデフォルトに戻しました。"))
    }

    /// Entries kept through a reset: user-declared modes.
    private func preservedModeEntryNames() -> [String] {
        draft.keys.keys.compactMap { name -> String? in
            guard let mode = Config.modeName(fromCommand: name), mode != Config.mainModeName else { return nil }
            guard draft.modes[mode] != nil else { return nil }
            return name
        }.sorted()
    }

    /// Default main keys with the kept mode entries laid over them.
    private func keysAfterMainShortcutReset() -> [String: Config.Key] {
        var next = Config.defaultKeys
        for name in preservedModeEntryNames() {
            if let key = draft.keys[name] { next[name] = key }
        }
        return next
    }

    /// Sentences for kept entries colliding with default keys; any one prevents the reset.
    private func mainDefaultModeEntryConflicts() -> [String] {
        var lines: [String] = []
        for name in preservedModeEntryNames() {
            guard let key = draft.keys[name] else { continue }
            let owners = Config.defaultKeys.compactMap { owner, defaultKey in defaultKey == key ? owner : nil }.sorted()
            for owner in owners {
                let entry = labelForCommand(name)
                let defaultAction = labelForCommand(owner)
                lines.append(L("\(key.display) is used by \(entry). It is also the default for \(defaultAction). Change the mode shortcut first.",
                               "\(key.display)は「\(entry)」に使われています。「\(defaultAction)」のデフォルトでもあります。先にモードへ入るショートカットを変えてください。"))
            }
        }
        return lines
    }

    private func resetShortcut(at row: Int) {
        guard row >= 0, row < keyRows.count else { return }
        let assigning: [String: Config.Key]
        let except: Set<String>
        switch keyRows[row] {
        case .heading: return
        case .direction(let group):
            guard canRestore(row) else { return }
            assigning = group.standardKeys
            except = Set(group.commands)
        case .command(let name, _):
            guard canRestore(row), let key = Config.defaultKeys[name] else { return }
            assigning = [name: key]
            except = [name]
        }
        var next = draft
        var moves: [(Config.Key, String)] = []
        for key in assigning.values {
            for label in SettingsRules.displace(key, in: &next, except: except) {
                moves.append((key, label))
            }
        }
        for name in except { next.keys[name] = nil }
        for (name, key) in assigning { next.keys[name] = key }
        reconcileMissingShortcut = true
        let savedOK = commit(next)
        reportShortcutResult(savedOK: savedOK, moves: moves, keys: Array(assigning.values))
    }

    @discardableResult
    private func removeShortcut(at row: Int) -> Bool {
        guard row >= 0, row < keyRows.count, canRemove(row) else { return false }
        var next = draft
        switch keyRows[row] {
        case .heading: return false
        case .direction(let group):
            for name in group.commands { next.keys[name] = nil }
        case .command(let name, _):
            next.keys[name] = nil
        }
        reconcileMissingShortcut = true
        let savedOK = commit(next)
        if savedOK {
            commandStatusSticky = false
            stickyFailureText = ""
            setShortcutMessage("", warning: false)
        }
        return savedOK
    }

    @objc private func directionControlChanged(_ sender: NSPopUpButton) {
        let row = keysTable.row(for: sender)
        guard row >= 0, row < keyRows.count, case .direction(let group) = keyRows[row] else { return }
        if keysTable.selectedRow != row {
            shortcutSelection = .direction(group)
            keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if recordingTarget != nil {
            endRecording(.cancelShow, restoreTableFocus: false)
        }
        let table = draft.keys(forMode: currentMode) ?? [:]
        let current = group.matched(in: table)
        if sender.tag == 1 {
            guard let id = sender.selectedItem?.representedObject as? String, id != "custom",
                  let choice = SettingsRules.modifierChoices.first(where: { $0.id == id }) else { return }
            applyDirection(group, modifiers: choice.modifiers, pattern: current?.pattern ?? .hjkl)
        } else {
            guard let raw = sender.selectedItem?.representedObject as? String, let pattern = DirectionPattern(rawValue: raw) else { return }
            applyDirection(group, modifiers: current?.modifiers ?? ["alt"], pattern: pattern)
        }
    }

    private static var recordingCanceled: String { L("Recording canceled.", "記録をキャンセルしました。") }

    private func applyDirection(_ group: DirectionGroup, modifiers: Set<String>, pattern: DirectionPattern) {
        let assigning = group.keys(modifiers: modifiers, pattern: pattern)
        if assigning.values.contains(where: { $0.modifiers.isEmpty && !$0.isFunctionKey }) {
            setShortcutMessage(L("Shortcuts need a modifier key (⌥ ⇧ ⌃ ⌘), except function keys.", "修飾キー（⌥ ⇧ ⌃ ⌘）が必要です（Fキーを除く）。"), warning: true)
            renderShortcuts()
            return
        }
        var next = draft
        var moves: [(Config.Key, String)] = []
        let except = Set(group.commands)
        for (name, key) in assigning {
            for label in SettingsRules.displace(key, in: &next, except: except) {
                moves.append((key, label))
            }
            next.keys[name] = key
        }
        reconcileMissingShortcut = true
        let savedOK = commit(next)
        reportShortcutResult(savedOK: savedOK, moves: moves, keys: Array(assigning.values))
    }

    /// Shows moves and warnings only when the write succeeded; the success sentence is only announced.
    private func reportShortcutResult(savedOK: Bool, moves: [(Config.Key, String)], keys: [Config.Key]) {
        guard savedOK else {
            let message = Self.notApplied
            setShortcutMessage(message, warning: true, sticky: true)
            announce(message)
            return
        }
        commandStatusSticky = false
        stickyFailureText = ""
        let (text, warning) = shortcutNotes(moves: moves, keys: keys)
        setShortcutMessage(text, warning: warning)
        if text.isEmpty {
            announce(L("Applied the shortcuts.", "ショートカットを適用しました。"))
        } else {
            announce(text)
        }
    }

    private static var notApplied: String { L("Not applied.", "適用していません。") }

    private func shortcutNotes(moves: [(Config.Key, String)], keys: [Config.Key]) -> (String, Bool) {
        var notes = moves.map { key, label in
            L("\(key.display) moved from “\(label)”.", "\(key.display)は「\(label)」から移動しました。")
        }
        notes += keys.flatMap {
            ShortcutConflicts.messages(for: $0, systemHotkeys: listedSystemHotkeys(), optionGlyph: KeyboardGlyph.optionOnlyCharacter(keyCode: $0.keyCode))
        }
        let unique = SettingsRules.uniqueInOrder(notes)
        let warnings = keys.contains {
            !ShortcutConflicts.messages(for: $0, systemHotkeys: listedSystemHotkeys(), optionGlyph: KeyboardGlyph.optionOnlyCharacter(keyCode: $0.keyCode)).isEmpty
        }
        return (unique.joined(separator: Copy.sentenceSeparator), warnings)
    }

    private enum RecordingEnd {
        /// Stop recording, clear the message, and restore shortcuts at once.
        case clearTransient
        /// Stopped by a click or selection: say it was cancelled and leave focus where the click went.
        case cancelShow
        /// After a key confirms or clears: shortcuts stay off until that key is released.
        case deferKey(UInt16)
        /// Moving to another recording: global shortcuts stay unregistered.
        case keepSuspended
    }

    private func startRecording(_ target: RecordingTarget) {
        let switching = recordingTarget != nil
        if switching {
            endRecording(.keepSuspended, restoreTableFocus: false)
        }
        invalidateHotkeyResumeWatch()
        resumeHotkeysOnKeyUp = nil
        hotkeyHoldOwner = nil
        // Process a resign that arrives late from activation before starting to record.
        revealRecordingOwner(target)
        recordingTarget = target
        if case .command(let name, _) = target, let row = rowIndex(forCommand: name) {
            selectShortcut(name, row: row)
        }
        suspendHotkeys()
        updateVisibleShortcutCells()
        updateShortcutButtons()
        let prompt = recordingPrompt(target)
        clearTransientShortcutStatus()
        let spoken = L("Recording a shortcut for \(targetLabel(target)). \(prompt)",
                       "\(targetLabel(target))のショートカットを記録しています。\(prompt)")
        announce(spoken, on: recordingOwnerWindow)
        claimRecordingFocus()
    }

    /// Before closing or changing panes. Stops only the recording; the caller writes the result text.
    private func stopRecording() {
        endRecording(.clearTransient, restoreTableFocus: false)
    }

    private func endRecording(_ end: RecordingEnd, restoreTableFocus: Bool = false) {
        let target = recordingTarget
        let owner = recordingOwnerWindow
        guard target != nil || hotkeysSuspended || resumeHotkeysOnKeyUp != nil else { return }
        recordingTarget = nil
        updateVisibleShortcutCells()
        updateShortcutButtons()
        if target != nil {
            switch end {
            case .cancelShow:
                clearTransientShortcutStatus()
                announce(Self.recordingCanceled, on: owner)
            case .clearTransient:
                clearTransientShortcutStatus()
            case .deferKey, .keepSuspended:
                break
            }
        }
        switch end {
        case .deferKey(let code):
            resumeHotkeysOnKeyUp = code
            hotkeyHoldOwner = owner
            installRecordingMonitor()
        case .keepSuspended:
            break
        case .cancelShow, .clearTransient:
            if resumeHotkeysOnKeyUp == nil { resumeHotkeysNow() }
        }
        if restoreTableFocus, case .command = target {
            focusShortcutTable()
        }
    }

    private func suspendHotkeys() {
        installRecordingMonitor()
        if !hotkeysSuspended {
            hotkeysSuspended = true
            onRecording?(true)
        }
    }

    private func resumeHotkeysNow() {
        invalidateHotkeyResumeWatch()
        resumeHotkeysOnKeyUp = nil
        hotkeyHoldOwner = nil
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if hotkeysSuspended {
            hotkeysSuspended = false
            onRecording?(false)
        }
    }

    /// After the owner window goes inactive: restore if the key is up, or after a short grace if it is still down.
    private func resolveHotkeysAfterOwnerLeft() {
        guard let code = resumeHotkeysOnKeyUp else {
            if recordingTarget == nil { resumeHotkeysNow() }
            return
        }
        if !recordedKeyStillDown(code) {
            resumeHotkeysNow()
            return
        }
        armHotkeyResumeWatch()
    }

    private func armHotkeyResumeWatch() {
        if hotkeyResumeTimer != nil { return }
        let started = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let code = self.resumeHotkeysOnKeyUp else {
                timer.invalidate()
                self.hotkeyResumeTimer = nil
                return
            }
            let expired = Date().timeIntervalSince(started) >= self.hotkeyResumeGrace
            if expired || !self.recordedKeyStillDown(code) {
                timer.invalidate()
                self.hotkeyResumeTimer = nil
                self.resumeHotkeysNow()
            }
        }
        hotkeyResumeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidateHotkeyResumeWatch() {
        hotkeyResumeTimer?.invalidate()
        hotkeyResumeTimer = nil
    }

    private func installRecordingMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredKey(event)
        }
    }

    private func handleMonitoredKey(_ event: NSEvent) -> NSEvent? {
        if recordingTarget == nil {
            guard let pending = resumeHotkeysOnKeyUp, event.keyCode == pending else { return event }
            if event.type == .keyUp {
                resumeHotkeysNow()
                return nil
            }
            if event.isARepeat { return nil }
            return event
        }
        guard event.type == .keyDown, capturesRecording(event) else { return event }
        if event.isARepeat { return nil }
        return recorded(event)
    }

    /// Takes keys only for the owner window. While the app is in front, that window must be key.
    /// Test hosts cannot come forward, so the owner window's events are taken only when there is no other key window.
    private func capturesRecording(_ event: NSEvent) -> Bool {
        guard let owner = recordingOwnerWindow else { return false }
        guard recorderOwnsFocus(in: owner) else { return false }
        guard let eventWindow = event.window, eventWindow === owner else { return false }
        if owner.isKeyWindow { return true }
        if NSApp.isActive { return false }
        if let key = NSApp.keyWindow, key !== owner { return false }
        return true
    }

    private func recorderOwnsFocus(in owner: NSWindow) -> Bool {
        guard let responder = owner.firstResponder else { return false }
        switch recordingTarget {
        case .command:
            return responder === keysTable
        case nil:
            return false
        }
    }

    private func revealRecordingOwner(_ target: RecordingTarget) {
        showKey(window)
        RunLoop.current.run(until: Date())
    }

    private func claimRecordingFocus() {
        claimingRecordingFocus = true
        defer { claimingRecordingFocus = false }
        switch recordingTarget {
        case .command:
            focusShortcutTable()
        case nil:
            break
        }
    }

    /// Makes the owner window key while recording; even in a test host that cannot come forward, no other key window is created.
    private func showKey(_ window: NSWindow?) {
        guard let window else { return }
        let host = window.sheetParent ?? window
        NSApp.activate(ignoringOtherApps: true)
        if !host.isVisible { host.orderFrontRegardless() }
        if host !== window, !window.isVisible { window.orderFrontRegardless() }
        window.makeKey()
    }

    /// Ends recording on a mouse-down outside the recorder and its button.
    func cancelRecordingForMouseDown(_ event: NSEvent) {
        guard recordingTarget != nil, let owner = recordingOwnerWindow else { return }
        guard event.window === owner else { return }
        guard !clickKeepsRecording(event) else { return }
        endRecording(.cancelShow, restoreTableFocus: false)
        outsideClickKeptCancelStatus = true
    }

    func releaseOutsideClickStatusHold() {
        outsideClickKeptCancelStatus = false
    }

    private func clickKeepsRecording(_ event: NSEvent) -> Bool {
        if case .command(let name, _) = recordingTarget, let row = rowIndex(forCommand: name),
           let cell = shortcutValueCell(at: row) {
            let box = cell.convert(cell.recorderBox, to: nil)
            if box.contains(event.locationInWindow) { return true }
        }
        guard let content = event.window?.contentView else { return false }
        guard let hit = content.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view {
            if let cell = current as? ShortcutValueCell, cell.recording { return true }
            view = current.superview
        }
        return false
    }

    private func shortcutValueCell(at row: Int) -> ShortcutValueCell? {
        let column = keysTable.column(withIdentifier: NSUserInterfaceItemIdentifier("key"))
        guard column >= 0 else { return nil }
        return keysTable.view(atColumn: column, row: row, makeIfNecessary: false) as? ShortcutValueCell
    }

    private var recordingOwnerWindow: NSWindow? {
        switch recordingTarget {
        case .command: return window
        case nil: return nil
        }
    }

    private func recordingPrompt(_ target: RecordingTarget?) -> String {
        switch target {
        case .command:
            return L("Press a key — Esc cancels, Delete clears.",
                     "キーを押してください — Escでキャンセル、Deleteで解除")
        case nil:
            return ""
        }
    }

    private func targetLabel(_ target: RecordingTarget) -> String {
        switch target {
        case .command(let name, _): return labelForCommand(name)
        }
    }

    private func recorded(_ event: NSEvent) -> NSEvent? {
        guard let target = recordingTarget else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = Set<String>()
        if flags.contains(.option) { mods.insert("alt") }
        if flags.contains(.shift) { mods.insert("shift") }
        if flags.contains(.control) { mods.insert("ctrl") }
        if flags.contains(.command) { mods.insert("cmd") }
        let bare = mods.isEmpty
        guard let name = Config.Key.keyCodes.first(where: { $0.value == UInt32(event.keyCode) })?.key else {
            rejectRecording(L("This key can't be used in a shortcut. Press a different key.", "このキーは割り当てに使えません。別のキーを押してください。"), target: target)
            return nil
        }
        if name == "tab", bare || mods == ["shift"] {
            endRecording(.deferKey(event.keyCode), restoreTableFocus: false)
            noteRecordingCanceled(target)
            return event
        }
        let key = Config.Key(modifiers: mods, key: name)
        if bare {
            if name == "esc" {
                endRecording(.deferKey(event.keyCode), restoreTableFocus: true)
                noteRecordingCanceled(target)
                return nil
            }
            if name == "backspace" || name == "forwarddelete" {
                if case .command(let command, _) = target {
                    let label = targetLabel(target)
                    endRecording(.deferKey(event.keyCode), restoreTableFocus: false)
                    if let row = rowIndex(forCommand: command), removeShortcut(at: row) {
                        announce(Self.removedShortcut(label))
                    } else if pending != nil {
                        setShortcutMessage(Self.notApplied, warning: true, sticky: true)
                        announce(Self.notApplied)
                    } else {
                        commandStatusSticky = false
                        stickyFailureText = ""
                        setShortcutMessage("", warning: false)
                    }
                    focusShortcutTable()
                    return nil
                }
            }
            if !key.isFunctionKey {
                rejectRecording(L("Shortcuts need a modifier key (⌥ ⇧ ⌃ ⌘), except function keys. Press another shortcut.",
                                  "修飾キー（⌥ ⇧ ⌃ ⌘）が必要です（Fキーを除く）。もう一度押してください。"), target: target)
                return nil
            }
        }
        guard case .command(let command, _) = target else { return nil }
        var next = draft
        let released = SettingsRules.displace(key, in: &next, except: [command])
        next.keys[command] = key
        let what = targetLabel(target)
        endRecording(.deferKey(event.keyCode), restoreTableFocus: false)
        reconcileMissingShortcut = true
        let savedOK = commit(next)
        focusShortcutTable()
        guard savedOK else {
            let message = Self.notApplied
            setShortcutMessage(message, warning: true, sticky: true)
            announce(message)
            return nil
        }
        let assigned = L("Assigned \(key.display) to \(what).", "\(key.display)を「\(what)」に割り当てました。")
        let moves = released.map { label in
            L("\(key.display) moved from “\(label)”.", "\(key.display)は「\(label)」から移動しました。")
        }
        let warnings = ShortcutConflicts.messages(for: key, systemHotkeys: listedSystemHotkeys(), optionGlyph: KeyboardGlyph.optionOnlyCharacter(keyCode: key.keyCode))
        commandStatusSticky = false
        stickyFailureText = ""
        setShortcutMessage((moves + warnings).joined(separator: Copy.sentenceSeparator), warning: !warnings.isEmpty)
        announce(([assigned] + moves + warnings).joined(separator: Copy.sentenceSeparator))
        return nil
    }

    /// Beeps for an unusable key and leaves the reason in the current message, without changing which keys are accepted.
    private func rejectRecording(_ text: String, target: RecordingTarget) {
        NSSound.beep()
        publishRecordingStatus(text, tone: .warning, target: target)
    }

    /// The cancel sentence is announced, not shown in the shortcut list.
    private func noteRecordingCanceled(_ target: RecordingTarget) {
        clearTransientShortcutStatus()
        announce(Self.recordingCanceled, on: window)
    }

    private func labelForCommand(_ name: String) -> String {
        for row in keyRows {
            if case .command(let command, let label) = row, command == name { return label }
        }
        return SettingsCopy.commandLabel(name)
    }

    private func setShortcutMessage(_ text: String, warning: Bool, sticky: Bool = false) {
        if text.isEmpty, commandStatusSticky, !sticky { return }
        if sticky, !text.isEmpty {
            commandStatusSticky = true
            stickyFailureText = text
            applyStatus(recordingLabel, text: text, tone: .failure)
            return
        }
        commandStatusSticky = false
        stickyFailureText = ""
        applyStatus(recordingLabel, text: text, tone: warning ? .warning : .secondary)
    }

    private func clearStickyShortcutFailure() {
        guard commandStatusSticky else { return }
        commandStatusSticky = false
        stickyFailureText = ""
        applyStatus(recordingLabel, text: "", tone: .secondary)
    }

    private func clearTransientShortcutStatus() {
        guard !commandStatusSticky else { return }
        applyStatus(recordingLabel, text: "", tone: .secondary)
    }

    private func publishRecordingStatus(_ text: String, tone: StatusTone, target: RecordingTarget?) {
        if text.isEmpty {
            clearTransientShortcutStatus()
        } else if commandStatusSticky, tone != .failure {
            let failure = stickyFailureText.isEmpty ? Self.notApplied : stickyFailureText
            applyStatus(recordingLabel, text: failure + "\n" + text, tone: .failure)
        } else {
            if tone == .failure {
                commandStatusSticky = true
                stickyFailureText = text
            }
            applyStatus(recordingLabel, text: text, tone: tone)
        }
    }

    private func applyStatus(_ label: NSTextField, text: String, tone: StatusTone) {
        label.stringValue = text
        label.toolTip = text.isEmpty ? nil : text
        label.setAccessibilityValue(text)
        label.setAccessibilityHelp(text.isEmpty ? nil : text)
        switch tone {
        case .secondary: label.textColor = .secondaryLabelColor
        case .accent: label.textColor = .controlAccentColor
        case .warning, .failure: label.textColor = .systemOrange
        }
        if label === recordingLabel { updateMessageDetails(text) }
        reflow()
    }

    /// Shows "Details…" only for messages that do not fit one line or contain line breaks. The width is the laid-out label's, including spacing on both sides of the spacer.
    private func updateMessageDetails(_ text: String) {
        guard let row = shortcutActionRow, row.bounds.width > 1 else {
            messageDetailsButton.isHidden = true
            return
        }
        let font = recordingLabel.font ?? .systemFont(ofSize: 11)
        let slot = shortcutMessageSlotWidth()
        guard slot > 1 else {
            messageDetailsButton.isHidden = true
            return
        }
        let overflows = shortcutMessageOverflows(text, font: font, width: slot)
        messageDetailsButton.isHidden = !overflows
        recordingLabel.preferredMaxLayoutWidth = max(40, slot)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        if overflows {
            recordingLabel.preferredMaxLayoutWidth = max(40, recordingLabel.bounds.width)
        }
    }

    /// Width the message actually gets without Details, measured after stretching the label to fill the space.
    private func shortcutMessageSlotWidth() -> CGFloat {
        guard let row = shortcutActionRow, let gap = shortcutActionGap else { return 0 }
        let labelHugging = recordingLabel.contentHuggingPriority(for: .horizontal)
        let gapHugging = gap.contentHuggingPriority(for: .horizontal)
        defer {
            recordingLabel.setContentHuggingPriority(labelHugging, for: .horizontal)
            gap.setContentHuggingPriority(gapHugging, for: .horizontal)
        }
        messageDetailsButton.isHidden = true
        recordingLabel.preferredMaxLayoutWidth = max(row.bounds.width, 1)
        recordingLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        gap.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        return recordingLabel.bounds.width
    }

    private func shortcutMessageOverflows(_ text: String, font: NSFont, width: CGFloat) -> Bool {
        guard !text.isEmpty else { return false }
        if text.contains(where: \.isNewline) { return true }
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return measured > width + 0.5
    }

    @objc private func showShortcutMessageDetails() {
        let text = recordingLabel.stringValue
        showShortcutDetails(text, from: messageDetailsButton, width: 360)
    }

    private func showShortcutDetails(_ text: String, from button: NSButton, width: CGFloat) {
        guard !text.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let field = NSTextField.settingsText( text)
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width + 24, height: 80))
        field.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            field.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            field.widthAnchor.constraint(equalToConstant: width),
        ])
        let controller = NSViewController()
        controller.view = host
        popover.contentViewController = controller
        popover.contentSize = host.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func updateVisibleShortcutCells() {
        let table = draft.keys(forMode: currentMode) ?? [:]
        let column = keysTable.column(withIdentifier: NSUserInterfaceItemIdentifier("key"))
        guard column >= 0 else { return }
        for row in 0..<keyRows.count {
            guard let cell = keysTable.view(atColumn: column, row: row, makeIfNecessary: false) as? ShortcutValueCell else { continue }
            guard case .command(let name, let label) = keyRows[row] else { continue }
            configureValueCell(cell, name: name, label: label, table: table)
        }
    }

    private func configureValueCell(_ cell: ShortcutValueCell, name: String, label: String, table: [String: Config.Key]) {
        cell.commandName = name
        cell.actionLabel = label
        cell.canRemove = table[name] != nil
        cell.canRestore = Config.defaultKeys[name] != nil && table[name] != Config.defaultKeys[name]
        let recording = if case .command(let current, _) = recordingTarget { current == name } else { false }
        cell.setAssignment(display: table[name]?.display, recording: recording)
        cell.onChange = { [weak self] in self?.beginRecording(name) }
        cell.onRemove = { [weak self] in self?.removeNamedShortcut(name) }
        cell.onRestore = { [weak self] in self?.restoreNamedShortcut(name) }
        cell.onCancel = { [weak self] in
            guard let self else { return }
            if case .command(let current, _) = self.recordingTarget, current == name {
                self.endRecording(.cancelShow, restoreTableFocus: true)
            }
        }
    }

    private func removeNamedShortcut(_ name: String) {
        removeShortcutSelection(.command(name))
    }

    private func restoreNamedShortcut(_ name: String) {
        guard let row = rowIndex(forCommand: name) else { return }
        if recordingTarget != nil { endRecording(.cancelShow, restoreTableFocus: false) }
        resetShortcut(at: row)
        focusShortcutTable()
    }

    private func listedSystemHotkeys() -> [ShortcutConflicts.SystemHotkey] {
        ShortcutConflicts.enabledSystemHotkeys().filter { $0.symbolicID != 79 && $0.symbolicID != 81 }
    }

    private func mainKeyList(_ config: Config) -> [Config.Key] {
        Array(config.keys.values)
    }

    private func refreshNativeShortcuts() {
        let read = nativeShortcutReader ?? { [coordinator] right in coordinator.systemSpaceShortcut(right: right) }
        let left = read(false)
        let right = read(true)
        nativeLeft = left
        nativeRight = right
        renderNativeStatus()
    }

    private func renderPlacementPreview() {
        let beside = placementPopup.indexOfSelectedItem == 0
        let pictogram: ActionPictogram = beside ? .placementBeside : .placementEnd
        placementPreview.pictogram = pictogram
        placementPopup.setAccessibilityHelp(pictogram.help)
        placementPreview.toolTip = pictogram.help
    }

    private func renderNativeStatus() {
        let states = (arrowStateReader ?? { [coordinator] in coordinator.arrowShortcutStates() })()
        let warning = NativeShortcutStatus.warning(left: nativeLeft, right: nativeRight,
                                                   saved: mainKeyList(saved), draft: mainKeyList(draft),
                                                   paused: (states?.left == .paused, states?.right == .paused))
        // Without a warning the whole row is hidden (the stack drops hidden views, so no gap remains).
        nativeStatusRow?.isHidden = warning == nil
        keyboardRow?.isHidden = warning?.showsKeyboardSettings != true
        nativeStatusLabel.stringValue = warning?.text ?? ""
        // Becoming empty is not announced; the same warning appearing again is announced again.
        if nativeStatusLabel.stringValue != announcedStatus {
            announcedStatus = nativeStatusLabel.stringValue
            if selectedPane == .keys { announce(announcedStatus) }
        }
        reflow()
    }

    private func updateModeNote() {
        let fileModes = draft.modes.keys.sorted()
        modeRow?.isHidden = fileModes.isEmpty
        let list = fileModes.joined(separator: ", ")
        modeNote.stringValue = fileModes.isEmpty ? "" : L("Modes in the configuration file (\(list)) aren't shown here. Edit them in the file.",
                                                         "設定ファイルのモード（\(list)）はここには表示されません。ファイルで編集してください。")
    }

    private func announce(_ text: String, on owner: NSWindow? = nil) {
        guard !text.isEmpty, let element = owner ?? window else { return }
        announcementObserver?(text)
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high,
        ])
    }

    private func identity(of row: ShortcutRow) -> ShortcutSelection? {
        switch row {
        case .direction(let group): return .direction(group)
        case .heading(let heading): return .heading(heading.section)
        case .command(let name, _): return .command(name)
        }
    }

    private func recordingTargetIsVisible(_ target: RecordingTarget) -> Bool {
        switch target {
        case .command(let name, _):
            return keyRows.contains { $0.commandName == name }
        }
    }

    private func updateShortcutButtons() {
        // If only the user's mode entries differ from defaults, there is nothing to reset, so the button is disabled.
        restoreMainButton.isEnabled = recordingTarget == nil && draft.keys != keysAfterMainShortcutReset()
    }

    /// Action menu for the clicked row; items are disabled for headings and empty space.
    private func fillShortcutMenu(_ menu: NSMenu?, selection: ShortcutSelection?) {
        guard let menu else { return }
        menu.autoenablesItems = false
        menu.removeAllItems()
        let token = selection.map { ShortcutActionToken($0) }
        let titles = shortcutMenuTitles(selection)
        let enabled = shortcutMenuEnabled(selection)
        let specs: [(String, Int, Bool, Selector)] = [
            (titles.change, 1, enabled.change, #selector(changeShortcutAction(_:))),
            (titles.remove, 2, enabled.remove, #selector(removeShortcutAction(_:))),
            (titles.restore, 3, enabled.restore, #selector(restoreShortcutAction(_:))),
        ]
        for (title, tag, isEnabled, action) in specs {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = isEnabled
            item.representedObject = token
            menu.addItem(item)
        }
    }

    private func shortcutMenuTitles(_ selection: ShortcutSelection?) -> (change: String, remove: String, restore: String) {
        switch selection {
        case .direction(let group):
            return (
                L("Change \(group.title) Shortcuts…", "\(group.title)のショートカットを変更…"),
                L("Remove \(group.title) Shortcuts", "\(group.title)の割り当てを解除"),
                L("Restore \(group.title) Defaults", "\(group.title)をデフォルトに戻す")
            )
        default:
            return (
                L("Change Shortcut…", "ショートカットを変更…"),
                L("Remove Shortcut", "割り当てを解除"),
                L("Restore Default", "デフォルトに戻す")
            )
        }
    }

    private func shortcutMenuEnabled(_ selection: ShortcutSelection?) -> (change: Bool, remove: Bool, restore: Bool) {
        guard let selection, let row = rowIndex(for: selection) else { return (false, false, false) }
        switch selection {
        case .heading:
            return (false, false, false)
        case .command, .direction:
            return (true, canRemove(row), canRestore(row))
        }
    }

    /// Lets tests build the menu item for a clicked row; real runs use the same items.
    func contextMenuItem(tag: Int, clickedRow: Int) -> NSMenuItem? {
        let selection = keyRows.indices.contains(clickedRow) ? identity(of: keyRows[clickedRow]) : nil
        fillShortcutMenu(shortcutContextMenu, selection: selection)
        return shortcutContextMenu.items.first { $0.tag == tag }
    }

    @objc private func showAddRuleMenu() {
        rebuildAddRuleMenu()
        addRuleMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: addRuleButton.bounds.height), in: addRuleButton)
    }

    /// Lets tests use the add menu's existing path without opening it modally.
    func preparedAddRuleMenu() -> NSMenu {
        rebuildAddRuleMenu()
        return addRuleMenu
    }

    private func rebuildAddRuleMenu() {
        addRuleMenu.removeAllItems()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let name = app.localizedName ?? "?"
            let item = NSMenuItem(title: name, action: #selector(addRuleAction(_:)), keyEquivalent: "")
            item.toolTip = app.bundleIdentifier
            item.target = self
            item.representedObject = app.bundleIdentifier
            addRuleMenu.addItem(item)
        }
        if !apps.isEmpty { addRuleMenu.addItem(.separator()) }
        let manual = NSMenuItem(title: SettingsCopy.manualRuleTitle, action: #selector(addRuleAction(_:)), keyEquivalent: "")
        manual.target = self
        addRuleMenu.addItem(manual)
    }

    private func updateSelectionButtons() {
        removeRuleButton.isEnabled = rulesTable.selectedRow >= 0 && rulesTable.selectedRow < draft.rules.count
        updateShortcutButtons()
    }

    private func canRemove(_ row: Int) -> Bool {
        guard row >= 0, row < keyRows.count else { return false }
        switch keyRows[row] {
        case .heading: return false
        case .direction(let group): return group.commands.contains { draft.keys[$0] != nil }
        case .command(let name, _): return draft.keys[name] != nil
        }
    }

    private func canRestore(_ row: Int) -> Bool {
        guard row >= 0, row < keyRows.count else { return false }
        switch keyRows[row] {
        case .heading: return false
        case .direction(let group):
            return group.commands.contains { draft.keys[$0] != Config.defaultKeys[$0] }
        case .command(let name, _):
            guard Config.defaultKeys[name] != nil else { return false }
            return draft.keys[name] != Config.defaultKeys[name]
        }
    }

    /// A heading combines title and explanation in one row view.
    private func headingSpan(_ heading: ShortcutHeading) -> NSView {
        let title = NSTextField(labelWithString: heading.title)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        var textColumn: NSView = title
        if !heading.detail.isEmpty {
            let detail = NSTextField.settingsText( heading.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 0
            textColumn = vstack([title, detail], spacing: 2)
        }
        let row = NSView()
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textColumn)
        NSLayoutConstraint.activate([
            textColumn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            textColumn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            textColumn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textColumn.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 4),
            textColumn.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -4),
        ])
        return row
    }

    /// Opens macOS Keyboard settings (if that fails, opens System Settings and returns false). Used by Settings and the window list.
    static func openSystemKeyboardSettings() -> Bool {
        if let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"), NSWorkspace.shared.open(keyboard) { return true }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(app)
        }
        return false
    }

    @objc private func openKeyboardSettings() {
        if Self.openSystemKeyboardSettings() { return }
        setShortcutMessage(L("Couldn't open Keyboard settings. In System Settings, choose Keyboard, then Keyboard Shortcuts… › Mission Control.",
                             "キーボード設定を開けませんでした。システム設定 › キーボード › キーボードショートカット… › Mission Controlを開いてください。"), warning: true)
    }

    // MARK: - Rules pane

    @objc private func addRuleAction(_ sender: NSMenuItem) {
        var app = sender.representedObject as? String
        if app == nil {
            let alert = NSAlert()
            alert.messageText = L("Enter Bundle Identifier", "バンドル識別子を入力")
            alert.informativeText = L("For example, com.apple.calculator. A trailing * matches a prefix, for example com.microsoft.*.",
                                      "例: com.apple.calculator。末尾の * は前方一致です（例: com.microsoft.*）。")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: L("Add", "追加")); alert.addButton(withTitle: L("Cancel", "キャンセル"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            app = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let app else { return }
        guard SettingsRules.isValidAppIdentifier(app) else {
            ruleError.stringValue = SettingsRules.appIdentifierMessage(app)
            ruleError.isHidden = false
            return
        }
        if let i = draft.rules.firstIndex(where: { $0.app == app }) {
            rulesTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            return
        }
        var next = draft
        next.rules.append(Config.Rule(app: app, action: .ignore))
        guard commit(next) else { return }
        if let row = draft.rules.lastIndex(where: { $0.app == app }) {
            rulesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateSelectionButtons()
        }
    }

    @objc private func removeRuleAction() {
        let row = rulesTable.selectedRow
        guard row >= 0, row < draft.rules.count else { return }
        if var edit = ruleEdit {
            if edit.row == row { ruleEdit = nil }
            else if edit.row > row { edit.row -= 1; ruleEdit = edit }
        }
        var next = draft
        next.rules.remove(at: row)
        commit(next)
    }

    /// Remembers uncommitted text from the start of input. Even valid text is not an error until the edit completes, and it never moves to another row.
    private func noteRuleEdit(_ field: RuleTextField, replacingOriginal: Bool) {
        let row = field.ruleIndex
        guard draft.rules.indices.contains(row) else { return }
        if var edit = ruleEdit {
            guard edit.row == row else { return }
            if replacingOriginal { return }
            edit.text = field.stringValue
            edit.message = nil
            ruleEdit = edit
        } else {
            ruleEdit = RuleEdit(row: row, text: field.stringValue, message: nil)
        }
        ruleError.stringValue = ""
        ruleError.isHidden = true
        updateChrome()
    }

    private func finishRuleEdit(_ field: RuleTextField) {
        let row = field.ruleIndex
        guard draft.rules.indices.contains(row) else { return }
        if let edit = ruleEdit {
            guard draft.rules.indices.contains(edit.row) else {
                clearRuleEdit()
                return
            }
            guard edit.row == row else {
                field.stringValue = draft.rules[row].app
                return
            }
        }
        let original = draft.rules[row].app
        let app = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if app == original {
            clearRuleEdit()
            return
        }
        guard SettingsRules.isValidAppIdentifier(app) else {
            keepRuleEdit(row: row, text: field.stringValue, message: SettingsRules.appIdentifierMessage(app))
            return
        }
        if draft.rules.enumerated().contains(where: { $0.offset != row && $0.element.app == app }) {
            keepRuleEdit(row: row, text: field.stringValue, message: L("That app is already listed.", "そのアプリは既にあります。"))
            return
        }
        var next = draft
        next.rules[row].app = app
        clearRuleEdit()
        commit(next)
    }

    private func clearRuleEdit() {
        ruleEdit = nil
        ruleError.stringValue = ""
        ruleError.isHidden = true
        updateChrome()
    }

    private func keepRuleEdit(row: Int, text: String, message: String) {
        ruleEdit = RuleEdit(row: row, text: text, message: message)
        ruleError.stringValue = message
        ruleError.isHidden = false
        updateChrome()
    }

    // MARK: - Tables (data source and delegate)

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case keysTable: return keyRows.count
        case rulesTable: return draft.rules.count
        default: return 0
        }
    }

    /// Known apps get their name shown; the edit field keeps only the identifier. Not saved until the edit completes.
    /// Blank when no installed or running app has the identifier, and for prefix rules.
    private func ruleNameCell(_ app: String) -> NSView {
        let title = NSTextField(labelWithString: SettingsCopy.knownAppName(app, name: appName) ?? "")
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        return title
    }

    private func ruleAppCell(_ app: String, row: Int) -> NSView {
        let field = RuleTextField(string: ruleEdit?.row == row ? ruleEdit!.text : app)
        field.ruleIndex = row
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = app
        return field
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView == keysTable, keyRows.indices.contains(row) else { return true }
        if case .heading = keyRows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === keysTable, keyRows.indices.contains(row) else { return false }
        if case .heading = keyRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === keysTable || tableView === rulesTable else { return nil }
        let group = tableView === keysTable && keyRows.indices.contains(row) && {
            if case .heading = keyRows[row] { return true }
            return false
        }()
        let identifier = NSUserInterfaceItemIdentifier(group ? "settings.group" : "settings.inset")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableRowView {
            return reused
        }
        let created: NSTableRowView = group ? NSTableRowView() : InsetSelectionRowView()
        created.identifier = identifier
        return created
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, let table = notification.object as? NSTableView else { return }
        if table == keysTable {
            let row = keysTable.selectedRow
            let newIdentity = (row >= 0 && row < keyRows.count) ? identity(of: keyRows[row]) : nil
            let changed = newIdentity != shortcutSelection
            shortcutSelection = newIdentity
            if !suppressSelectionSideEffects, changed {
                if case .command(let name, _) = recordingTarget, newIdentity != .command(name) {
                    endRecording(.cancelShow, restoreTableFocus: false)
                } else if recordingTarget == nil {
                    if outsideClickKeptCancelStatus {
                        outsideClickKeptCancelStatus = false
                    } else {
                        clearTransientShortcutStatus()
                    }
                }
            }
        }
        updateSelectionButtons()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView == keysTable, row >= 0, row < keyRows.count else { return tableView.rowHeight }
        guard case .heading(let heading) = keyRows[row] else { return 26 }
        guard !heading.detail.isEmpty else { return 26 }
        let width = max(160, (tableView.bounds.width > 1 ? tableView.bounds.width : 520) - 140)
        let detail = NSTextField.settingsText( heading.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.preferredMaxLayoutWidth = width
        return max(44, 28 + detail.fittingSize.height)
    }

    private func directionControls(_ group: DirectionGroup, table: [String: Config.Key]) -> NSView {
        let matched = group.matched(in: table)
        let unassigned = group.commands.allSatisfy { table[$0] == nil }
        let modifiers = NSPopUpButton()
        modifiers.tag = 1
        let modsAreListed = matched.map { hit in SettingsRules.modifierChoices.contains { $0.modifiers == hit.modifiers } } ?? false
        if !modsAreListed {
            let custom = NSMenuItem(title: group.summary(in: table), action: nil, keyEquivalent: "")
            custom.representedObject = "custom"
            modifiers.menu?.addItem(custom)
        }
        for choice in SettingsRules.modifierChoices {
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.representedObject = choice.id
            modifiers.menu?.addItem(item)
        }
        if let matched, let choice = SettingsRules.modifierChoices.first(where: { $0.modifiers == matched.modifiers }) {
            modifiers.selectItem(at: modifiers.indexOfItem(withRepresentedObject: choice.id))
        } else {
            modifiers.selectItem(at: 0)
        }
        modifiers.setAccessibilityLabel(L("\(group.title) modifier keys", "\(group.title)の修飾キー"))
        modifiers.target = self
        modifiers.action = #selector(directionControlChanged(_:))
        modifiers.menu?.delegate = self

        let cell = DirectionShortcutCell()
        // An unassigned group shows a single dash; choosing it fills the group with HJKL.
        guard !unassigned else {
            cell.setPopups([modifiers])
            return cell
        }

        let pattern = NSPopUpButton()
        pattern.tag = 2
        if matched == nil {
            let custom = NSMenuItem(title: L("Custom", "個別設定"), action: nil, keyEquivalent: "")
            custom.representedObject = "custom"
            pattern.menu?.addItem(custom)
        }
        for item in [DirectionPattern.hjkl, .arrows] {
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.representedObject = item.rawValue
            pattern.menu?.addItem(menuItem)
        }
        if let matched {
            pattern.selectItem(at: pattern.indexOfItem(withRepresentedObject: matched.pattern.rawValue))
        } else {
            pattern.selectItem(at: 0)
        }
        pattern.setAccessibilityLabel(L("\(group.title) keys", "\(group.title)のキー"))
        pattern.target = self
        pattern.action = #selector(directionControlChanged(_:))
        pattern.menu?.delegate = self
        cell.setPopups([modifiers, pattern])
        return cell
    }

    private func actionCell(_ title: String, pictogram: ActionPictogram?) -> ShortcutActionCell {
        let cell = ShortcutActionCell()
        cell.textField?.stringValue = title
        cell.textField?.setAccessibilityLabel(title)
        cell.pictogramView.pictogram = pictogram
        let help = pictogram?.help ?? ""
        cell.toolTip = help
        cell.textField?.toolTip = help
        cell.textField?.setAccessibilityHelp(help)
        return cell
    }

    private func commandValueCell(name: String, label: String, table: [String: Config.Key]) -> ShortcutValueCell {
        let cell = ShortcutValueCell()
        configureValueCell(cell, name: name, label: label, table: table)
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === keysTable, tableColumn == nil {
            guard keyRows.indices.contains(row), case .heading(let heading) = keyRows[row] else { return nil }
            return headingSpan(heading)
        }
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        func text(_ s: String, mono: Bool = false, dim: Bool = false) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
            t.textColor = dim ? .tertiaryLabelColor : .labelColor
            t.lineBreakMode = .byTruncatingTail
            if !dim { t.toolTip = s }
            return t
        }
        switch tableView {
        case keysTable:
            let table = draft.keys(forMode: currentMode) ?? [:]
            switch keyRows[row] {
            case .heading:
                return nil
            case .direction(let group):
                switch id {
                case "label": return actionCell(group.title, pictogram: ActionPictogram.forGroup(group))
                default: return directionControls(group, table: table)
                }
            case .command(let name, let label):
                switch id {
                case "label": return actionCell(label, pictogram: ActionPictogram.forCommand(name))
                default: return commandValueCell(name: name, label: label, table: table)
                }
            }
        case rulesTable:
            let rule = draft.rules[row]
            if id == "name" { return ruleNameCell(rule.app) }
            var badges = [ruleAppCell(rule.app, row: row)]
            if rule.action == .float {
                let floating = caption(L("Floating", "フローティング"))
                floating.toolTip = L("Set in the configuration file. The window keeps its position.", "設定ファイルで指定。位置を保ちます。")
                badges.append(floating)
            }
            if rule.action == .space {
                let target = rule.space.map(Copy.desktop) ?? "?"
                let send = caption(rule.follow ? L("Opens on \(target), follows", "\(target)で開いて切り替え") : L("Opens on \(target)", "\(target)で開く"))
                send.toolTip = L("Set in the configuration file. New windows of this app are sent to \(target) when they open; the window is still tiled there.",
                                 "設定ファイルで指定。このアプリの新しいウインドウを、開いたときに\(target)へ送ります（そこでは通常どおり整列します）。")
                badges.append(send)
            }
            if !rule.title.isEmpty {
                let filter = caption(L("Title condition", "タイトル条件あり"))
                filter.toolTip = rule.title
                badges.append(filter)
            }
            return badges.count == 1 ? badges[0] : hstack(badges)
        default: return nil
        }
    }

    // MARK: - Closing and the file

    private func focusInvalidField() {
        if invalidFields.contains(.gap) {
            showPane(.layout, animated: false)
            window?.makeFirstResponder(gapField)
        } else if invalidFields.contains(.borderWidth) {
            borderWidthRow?.isHidden = false
            borderColorRow?.isHidden = false
            showPane(.layout, animated: false)
            window?.makeFirstResponder(borderWidthField)
        }
    }

    private func focusProblem() {
        if ruleEdit?.message != nil {
            showPane(.apps, animated: false)
            return
        }
        if !invalidFields.isEmpty {
            focusInvalidField()
            return
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func resolveLeave() -> Bool {
        finishActiveEditors()
        stopRecording()
        guard needsAttention else { return true }
        let choice: LeaveChoice
        if let leavePrompt {
            choice = leavePrompt()
        } else {
            leavePresentationCount += 1
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            choice = presentLeaveAlert()
        }
        switch choice {
        case .retry:
            if let pending, commit(pending), !needsAttention { return true }
            focusProblem()
            return false
        case .discard:
            discardLocalEdits()
            return !needsAttention
        case .cancel:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { resolveLeave() }

    private func presentLeaveAlert() -> LeaveChoice {
        let alert = NSAlert()
        if pending != nil {
            alert.messageText = L("A change could not be saved", "変更を保存できませんでした")
            alert.informativeText = L("Try Again writes this change. Discard loads the file and drops it.", "再試行でこの変更を書き込みます。破棄するとファイルを読み込み、この変更を捨てます。")
            alert.addButton(withTitle: SettingsCopy.tryAgainTitle)
            alert.addButton(withTitle: L("Discard", "破棄"))
            alert.addButton(withTitle: L("Cancel", "キャンセル"))
        } else {
            alert.messageText = L("A value needs to be corrected", "修正が必要な値があります")
            alert.informativeText = L("Review returns to the value. Discard restores the last saved value.", "確認でその値に戻ります。破棄すると最後に保存した値に戻します。")
            alert.addButton(withTitle: L("Review", "確認"))
            alert.addButton(withTitle: L("Discard", "破棄"))
            alert.addButton(withTitle: L("Cancel", "キャンセル"))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    @objc private func openFile() { NSWorkspace.shared.open(coordinator.configURL) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([coordinator.configURL]) }
    @objc private func showCLIHelp() { CLIHelp.present() }

}

extension SettingsWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === shortcutContextMenu {
            menu.autoenablesItems = false
        }
        guard menu === shortcutContextMenu else { return }
        let row = keysTable.clickedRow
        let selection = keyRows.indices.contains(row) ? identity(of: keyRows[row]) : nil
        fillShortcutMenu(menu, selection: selection)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === shortcutContextMenu {
            openMenuCount += 1
            if recordingTarget != nil { endRecording(.cancelShow, restoreTableFocus: false) }
            return
        }
        guard let popup = popupOwning(menu) else { return }
        let row = keysTable.row(for: popup)
        guard keyRows.indices.contains(row), case .direction = keyRows[row] else { return }
        if keysTable.selectedRow != row {
            keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if recordingTarget != nil {
            endRecording(.cancelShow, restoreTableFocus: false)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === shortcutContextMenu else { return }
        openMenuCount = max(0, openMenuCount - 1)
        flushDeferredResize()
    }

    private func popupOwning(_ menu: NSMenu) -> NSPopUpButton? {
        let column = keysTable.column(withIdentifier: NSUserInterfaceItemIdentifier("key"))
        guard column >= 0 else { return nil }
        for row in 0..<keyRows.count {
            guard let cell = keysTable.view(atColumn: column, row: row, makeIfNecessary: false) else { continue }
            if let found = popup(in: cell, owning: menu) { return found }
        }
        return nil
    }

    private func popup(in view: NSView, owning menu: NSMenu) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.menu === menu { return popup }
        for subview in view.subviews {
            if let found = popup(in: subview, owning: menu) { return found }
        }
        return nil
    }
}
