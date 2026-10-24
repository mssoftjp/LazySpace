import AppKit
import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations


/// The window list for the current Space. Opening, refreshing, and Space changes never move windows.
final class ReadyWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let loadInspection: (@escaping (Inspection) -> Void) -> Void
    private let readLive: () -> WindowInspectLive
    private let markReady: () -> Void
    private let openGeneralSettings: () -> Void
    private let openAccessSettings: () -> Void

    private let spaceHeading = NSTextField(labelWithString: "")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let previousButton = NSButton(title: "", target: nil, action: nil)
    private let fixButton = NSButton(title: "", target: nil, action: nil)
    private let actionRow = NSStackView()
    private let tableScroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [InspectorRow] = []
    private var emptyMessage: String?
    private var pollTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var request: Request?
    private var displayedContext: WindowInspectContext?
    private var heldContext: WindowInspectContext?
    private var stableRetries = 0
    private var checking = false
    private var updatedAt: Date?
    private let scrollerStyle: NSScroller.Style

    struct InspectorRow: Equatable {
        var app: String
        var eligibility: String
        var toolTip: String? = nil
    }

    enum ListBody: Equatable {
        case rows([InspectorRow])
        case message(String)
    }

    private struct Request: Equatable {
        var generation: UInt64
        var context: WindowInspectContext
    }

    convenience init(openGeneralSettings: @escaping () -> Void) {
        self.init(
            loadInspection: { Coordinator.shared.inspect(completion: $0) },
            readLive: { Self.live(from: Coordinator.shared) },
            markReady: { Coordinator.shared.markFirstLaunchDone() },
            openGeneralSettings: openGeneralSettings,
            openAccessSettings: { AXTrust.openSystemSettings() })
    }

    init(loadInspection: @escaping (@escaping (Inspection) -> Void) -> Void,
         readLive: @escaping () -> WindowInspectLive,
         markReady: @escaping () -> Void,
         openGeneralSettings: @escaping () -> Void,
         openAccessSettings: @escaping () -> Void,
         scrollerStyle: NSScroller.Style = NSScroller.preferredScrollerStyle) {
        self.loadInspection = loadInspection
        self.readLive = readLive
        self.markReady = markReady
        self.openGeneralSettings = openGeneralSettings
        self.openAccessSettings = openAccessSettings
        self.scrollerStyle = scrollerStyle
        // Scroll bars that are always shown take their width from the table; open that much wider so the columns are
        // the same as with overlay scroll bars.
        let scrollerWidth = scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let size = NSSize(width: 560 + scrollerWidth, height: 340)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = Self.windowTitle
        window.contentMinSize = NSSize(width: 520, height: 220)
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        build()
        applyChrome(readLive())
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        pollTimer?.invalidate()
        removeSpaceObserver()
    }

    var testingPollTimer: Timer? { pollTimer }

    /// Status is not read while hidden; the cheap check while shown is refreshLabels.
    func testingTimerFired() {
        guard window?.isVisible == true else { return }
        refreshLabels()
    }

    func windowDidResize(_ notification: Notification) {
        fitTableToViewport()
    }

    /// Fits the last column into the visible width. Long reasons are truncated in the cell.
    private func fitTableToViewport() {
        guard tableScroll.contentView.bounds.width > 1 else { return }
        table.sizeLastColumnToFit()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        removeSpaceObserver()
        generation &+= 1
        request = nil
        checking = false
    }

    private func observeSpaceChanges() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.testingSpaceChanged()
            }
    }

    private func removeSpaceObserver() {
        guard let spaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        self.spaceObserver = nil
    }

    /// The Space changed while shown. refreshLabels does the heavy AX read only when the state changed.
    func testingSpaceChanged() {
        guard window?.isVisible == true else { return }
        refreshLabels()
    }

    private static func live(from coordinator: Coordinator) -> WindowInspectLive {
        let status = coordinator.status()
        return WindowInspectLive(
            spaceID: coordinator.system.currentSpaceID(),
            trusted: coordinator.system.axTrusted,
            spaceObservationAvailable: coordinator.system.spaceObservationAvailable,
            waiting: Set(status.waiting),
            status: status,
            firstLaunchDone: coordinator.state.firstLaunchDone)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // No checks while closed; the timer exists only while shown.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.testingTimerFired()
            }
        }
        observeSpaceChanges()
        refreshTargets()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        spaceHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .secondaryLabelColor
        updatedLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.font = .systemFont(ofSize: 12)
        reasonLabel.textColor = .labelColor
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshTargets)
        previousButton.bezelStyle = .rounded
        previousButton.target = self
        previousButton.action = #selector(showPrevious)
        fixButton.bezelStyle = .rounded
        fixButton.target = self
        fixButton.action = #selector(showFix)
        for button in [refreshButton, previousButton, fixButton, spaceHeading] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [spaceHeading, spacer, updatedLabel, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        stack.addArrangedSubview(header)
        stretch(header, in: stack)

        stack.addArrangedSubview(reasonLabel)
        stretch(reasonLabel, in: stack)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .labelColor
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.isHidden = true
        stack.addArrangedSubview(emptyLabel)
        stretch(emptyLabel, in: stack)

        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = scrollerStyle
        tableScroll.drawsBackground = false
        tableScroll.documentView = table
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        for (id, width) in [("app", 220.0), ("eligibility", 280.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "app" ? 120 : 160
            table.addTableColumn(column)
        }
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        stack.addArrangedSubview(tableScroll)
        stretch(tableScroll, in: stack)

        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.detachesHiddenViews = true
        actionRow.addArrangedSubview(previousButton)
        actionRow.addArrangedSubview(fixButton)
        stack.addArrangedSubview(actionRow)
    }

    private func stretch(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
    }

    // MARK: - Loading

    /// Cheap status update. Rereads the list only when the Space, permission, or Space observation changed while shown.
    func refreshLabels() {
        let live = readLive()
        applyChrome(live)
        guard window?.isVisible == true else { return }
        let current = live.context
        if let request {
            if request.context != current {
                stableRetries = 0
                heldContext = nil
                startInspect(live)
            }
            return
        }
        if heldContext == current { return }
        if displayedContext == current { return }
        guard displayedContext != nil || heldContext != nil else { return }
        stableRetries = 0
        heldContext = nil
        startInspect(live)
    }

    /// On opening and from the refresh button. Changes neither automatic arrangement nor the layout.
    @objc func refreshTargets() {
        stableRetries = 0
        heldContext = nil
        startInspect(readLive())
    }

    private func startInspect(_ live: WindowInspectLive) {
        generation += 1
        request = Request(generation: generation, context: live.context)
        checking = true
        rows = []
        updatedAt = nil
        displayedContext = nil
        applyList(.rows([]))
        applyChrome(live)
        let requestedGeneration = generation
        loadInspection { [weak self] inspection in
            self?.deliver(generation: requestedGeneration, inspection: inspection)
        }
    }

    private func deliver(generation: UInt64, inspection: Inspection) {
        let live = readLive()
        let snapshot = inspection.snapshot
        let decision = WindowInspectFreshness.decide(
            requestedGeneration: generation,
            latestGeneration: self.generation,
            requested: request?.context ?? live.context,
            snapshot: WindowInspectContext(
                spaceID: snapshot.spaceID,
                trusted: snapshot.trusted,
                spaceObservationAvailable: snapshot.spaceObservationAvailable),
            current: live.context,
            stableRetries: stableRetries)
        switch decision {
        case .ignore:
            return
        case .accept:
            stableRetries = 0
            heldContext = nil
            request = nil
            checking = false
            displayedContext = live.context
            updatedAt = Date()
            let snapshotContext = WindowInspectContext(
                spaceID: snapshot.spaceID,
                trusted: snapshot.trusted,
                spaceObservationAvailable: snapshot.spaceObservationAvailable)
            let waitingApplies = snapshotContext == live.context
            applyList(Self.presentation(inspection, waiting: live.waiting, waitingApplies: waitingApplies, name: AppNames.localized))
            if !live.firstLaunchDone, snapshot.trusted, snapshot.spaceObservationAvailable, snapshot.spaceID != nil {
                markReady()
            }
        case .rerequest:
            if request?.context == live.context { stableRetries += 1 } else { stableRetries = 0 }
            rows = []
            displayedContext = nil
            checking = true
            applyList(.rows([]))
            startInspect(live)
            return
        case .hold:
            request = nil
            checking = false
            displayedContext = nil
            heldContext = live.context
            updatedAt = nil
            rows = []
            applyList(.message(Self.mismatchText))
        }
        applyChrome(readLive())
    }

    private func applyList(_ body: ListBody) {
        switch body {
        case .rows(let next):
            rows = next
            emptyMessage = nil
            emptyLabel.stringValue = ""
            emptyLabel.isHidden = true
            tableScroll.isHidden = false
        case .message(let text):
            rows = []
            emptyMessage = text
            emptyLabel.stringValue = text
            emptyLabel.isHidden = false
            tableScroll.isHidden = true
        }
        table.reloadData()
    }

    // MARK: - Chrome

    private func applyChrome(_ live: WindowInspectLive) {
        let status = live.status
        window?.title = Self.windowTitle
        spaceHeading.stringValue = Self.spaceHeadingText
        refreshButton.title = Self.refreshTitle
        updatedLabel.stringValue = Self.updatedLabel(checking: checking, date: updatedAt)
        let titles = ["app": L(.cliApp), "eligibility": Self.verdictColumnTitle]
        for column in table.tableColumns {
            column.title = titles[column.identifier.rawValue] ?? column.title
        }
        let reason = Self.remediationReason(status) ?? ""
        reasonLabel.stringValue = reason
        reasonLabel.isHidden = reason.isEmpty
        previousButton.title = Self.previousTitle
        previousButton.isHidden = !Self.showsPreviousOperation(status.lastResult)
        fixButton.title = Self.fixTitle
        fixButton.isHidden = !Self.showsRemediation(status)
        actionRow.isHidden = previousButton.isHidden && fixButton.isHidden
    }

    @objc private func showPrevious() {
        let result = readLive().status.lastResult
        guard let result, Self.showsPreviousOperation(result), let window else { return }
        DetailSheet.present(
            title: L(.windowListPreviousOperation),
            body: Self.previousOperationText(result, name: AppNames.localized),
            choices: [DetailSheet.closeChoice],
            on: window) { _ in }
    }

    @objc private func showFix() {
        let status = readLive().status
        guard let window else { return }
        let choices = Self.remediationChoices(status)
        DetailSheet.present(
            title: Self.remediationSheetTitle,
            body: Self.remediationDetail(status),
            choices: choices,
            on: window) { [weak self] kind in
                guard let self else { return }
                switch kind {
                case .close:
                    break
                case .openGeneralSettings:
                    self.openGeneralSettings()
                case .openSettings:
                    self.openAccessSettings()
                }
            }
    }

    func visibleRows() -> [(app: String, eligibility: String)] {
        rows.map { ($0.app, $0.eligibility) }
    }

    struct MinimumWidthFit {
        var clipWidth: CGFloat
        var columnMaxX: CGFloat
        var cellMaxX: CGFloat
        var cellWidth: CGFloat
        var texts: [String]
        var lineBreak: NSLineBreakMode
    }

    /// Fits to the minimum content width, then reads the actual column and cell positions.
    func testingFitAtMinimumContentWidth() -> MinimumWidthFit {
        if let minSize = window?.contentMinSize {
            window?.setContentSize(minSize)
        }
        window?.layoutIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        tableScroll.layoutSubtreeIfNeeded()
        fitTableToViewport()
        table.layoutSubtreeIfNeeded()
        let clipWidth = tableScroll.contentView.bounds.maxX
        let lastColumn = max(table.numberOfColumns - 1, 0)
        let columnRect = table.convert(table.rect(ofColumn: lastColumn), to: tableScroll.contentView)
        var cellMaxX = columnRect.maxX
        var cellWidth: CGFloat = 0
        var lineBreak = NSLineBreakMode.byTruncatingTail
        var texts: [String] = []
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: lastColumn, row: row, makeIfNecessary: true) as? NSTextField else { continue }
            texts.append(cell.stringValue)
            lineBreak = cell.lineBreakMode
            cellWidth = max(cellWidth, cell.bounds.width)
            cellMaxX = max(cellMaxX, cell.convert(cell.bounds, to: tableScroll.contentView).maxX)
        }
        return MinimumWidthFit(
            clipWidth: clipWidth,
            columnMaxX: columnRect.maxX,
            cellMaxX: cellMaxX,
            cellWidth: cellWidth,
            texts: texts,
            lineBreak: lineBreak)
    }

    func testingCell(column identifier: String, row: Int) -> NSTextField? {
        guard rows.indices.contains(row) else { return nil }
        let column = table.tableColumns.first { $0.identifier.rawValue == identifier }
        return tableView(table, viewFor: column, row: row) as? NSTextField
    }

    struct Surface: Equatable {
        var title: String
        var columns: [String]
        var columnIdentifiers: [String]
        var header: String
        var refresh: String
        var updated: String
        var reason: String
        var emptyMessage: String
        var previousHidden: Bool
        var fixHidden: Bool
        var contentWidth: CGFloat
        var contentHeight: CGFloat
        var minWidth: CGFloat
        var buttonTitles: [String]
    }

    func surface() -> Surface {
        let buttons = [refreshButton, previousButton, fixButton]
        return Surface(
            title: window?.title ?? "",
            columns: table.tableColumns.map(\.title),
            columnIdentifiers: table.tableColumns.map(\.identifier.rawValue),
            header: spaceHeading.stringValue,
            refresh: refreshButton.title,
            updated: updatedLabel.stringValue,
            reason: reasonLabel.isHidden ? "" : reasonLabel.stringValue,
            emptyMessage: emptyLabel.isHidden ? "" : emptyLabel.stringValue,
            previousHidden: previousButton.isHidden,
            fixHidden: fixButton.isHidden,
            contentWidth: window?.contentView?.bounds.width ?? 0,
            contentHeight: window?.contentView?.bounds.height ?? 0,
            minWidth: window?.contentMinSize.width ?? 0,
            buttonTitles: buttons.map(\.title))
    }


    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier.rawValue ?? ""
        let text = identifier == "app" ? rows[row].app : rows[row].eligibility
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        let tip = rows[row].toolTip ?? text
        cell.toolTip = tip.isEmpty ? nil : tip
        cell.font = .systemFont(ofSize: 12)
        cell.textColor = .labelColor
        return cell
    }
}
