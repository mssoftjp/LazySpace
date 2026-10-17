import AppKit
import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations
import Settings

/// Layout edit intent. Shortcuts, the menu, and the CLI all convert to this and call `Coordinator.edit`.
enum EditCommand: Equatable {
    case focus(Direction)
    case swap(Direction)
    case move(Direction)
    case join(Direction)
    case resize(Axis, Double)
    /// Changes the share along the parent split's direction (AeroSpace resize smart).
    case resizeSmart(Double)
    /// Evens out every split's ratios.
    case balance
    case toggleOrientation
    /// Toggles the parent split between tiles and accordion, keeping its orientation.
    case toggleAccordion
    case toggleFloat
    case toggleZoom
    /// Back to the previously focused window (toggles).
    case focusBack
    /// Undoes the last layout edit.
    case undo
    /// Closes the focused window (like ⌘W; the AX close button).
    case close
    /// Switches Spaces (by synthesizing the OS shortcut and letting the OS do it).
    case space(SpaceTarget)
    /// Moves the focused window to another Space and shows that Space (`move-to-space --follow`).
    case moveToSpace(SpaceTarget)
    /// Sends the focused window to another Space without switching (default `move-to-space`; only with the direct move).
    case sendToSpace(SpaceTarget)
    /// Native full screen toggle (AXFullScreen).
    case fullscreen
    /// Minimize (AXMinimized).
    case minimize

    /// CLI forms: focus-left, swap-right, move-down, join-up, resize-width +0.05, resize-smart -0.05, balance, toggle-split, float, zoom, focus-back, undo, close,
    /// space-3 / space-next / space-prev / space-back, move-to-space-3 / move-to-space-next / move-to-space-prev, fullscreen, minimize,
    static func parse(_ text: String) -> EditCommand? {
        for (prefix, make) in [("move-to-space-follow-", EditCommand.moveToSpace), ("move-to-space-", EditCommand.sendToSpace), ("space-", EditCommand.space)]
        where text.hasPrefix(prefix) {
            guard let target = SpaceTarget.parse(String(text.dropFirst(prefix.count))) else { return nil }
            if prefix != "space-", target == .back { return nil }
            return make(target)
        }
        let parts = text.split(separator: " ").map(String.init)
        guard let head = parts.first, head.hasPrefix("resize-") ? parts.count <= 2 : parts.count == 1 else { return nil }
        func dir(_ s: String) -> Direction? { Direction(rawValue: s) }
        let pieces = head.split(separator: "-").map(String.init)
        switch (pieces.first, pieces.count) {
        case ("focus", 2) where pieces[1] == "back": return .focusBack
        case ("focus", 2): return dir(pieces[1]).map { .focus($0) }
        case ("swap", 2): return dir(pieces[1]).map { .swap($0) }
        case ("move", 2): return dir(pieces[1]).map { .move($0) }
        case ("join", 2): return dir(pieces[1]).map { .join($0) }
        case ("resize", 2):
            guard parts.count <= 2, let delta = parts.count > 1 ? Double(parts[1]) : 0.05,
                  delta.isFinite, delta != 0, abs(delta) < 1 else { return nil }
            if pieces[1] == "smart" { return .resizeSmart(delta) }
            guard pieces[1] == "width" || pieces[1] == "height" else { return nil }
            return .resize(pieces[1] == "width" ? .horizontal : .vertical, delta)
        case ("balance", 1): return .balance
        case ("toggle", 2) where pieces[1] == "split": return .toggleOrientation
        case ("accordion", 1): return .toggleAccordion
        case ("float", 1): return .toggleFloat
        case ("zoom", 1): return .toggleZoom
        case ("undo", 1): return .undo
        case ("close", 1): return .close
        case ("fullscreen", 1): return .fullscreen
        case ("minimize", 1): return .minimize
        default: return nil
        }
    }

    var label: String {
        func en(_ x: Direction) -> String { ["left": "Left", "right": "Right", "up": "Up", "down": "Down"][x.rawValue]! }
        func ja(_ x: Direction) -> String { ["left": "左", "right": "右", "up": "上", "down": "下"][x.rawValue]! }
        func neighbor(_ x: Direction) -> String {
            ["left": "Window on Left", "right": "Window on Right", "up": "Window Above", "down": "Window Below"][x.rawValue]!
        }
        switch self {
        case .focus(let x): return L("Focus \(en(x))", "\(ja(x))のウインドウに切り替え")
        case .swap(let x): return L("Swap with \(neighbor(x))", "\(ja(x))のウインドウと交換")
        case .move(let x): return L("Reorder \(en(x))", "\(ja(x))へ並べ替える")
        case .join(let x):
            return x.axis == .horizontal
                ? L("Stack Below \(neighbor(x))", "\(ja(x))のウインドウの下にまとめる")
                : L("Place Beside \(neighbor(x))", "\(ja(x))のウインドウの右にまとめる")
        case .resize(let a, let v):
            if a == .horizontal { return v >= 0 ? L("Increase Width", "幅を広げる") : L("Decrease Width", "幅を狭める") }
            return v >= 0 ? L("Increase Height", "高さを増やす") : L("Decrease Height", "高さを減らす")
        case .resizeSmart(let v): return v >= 0 ? L("Grow Along Split", "並び方向に広げる") : L("Shrink Along Split", "並び方向に縮める")
        case .balance: return L("Equalize Split Ratios", "分割の割合を均等にする")
        case .toggleOrientation: return L("Switch Horizontal / Vertical", "縦並び／横並びを切り替え")
        case .toggleAccordion: return L("Switch Overlapping / Tiled", "重ねて表示／並べて表示")
        case .toggleFloat: return L("Toggle Tiling for Window", "整列対象から外す／戻す")
        case .toggleZoom: return L("Fill Work Area / Restore Layout", "作業領域いっぱいに表示／戻す")
        case .focusBack: return L("Focus Previous Window", "直前のウインドウに戻る")
        case .undo: return L("Undo Layout Change", "レイアウト変更を取り消す")
        case .close: return L("Close Window", "ウインドウを閉じる")
        case .space(let t):
            switch t {
            case .index(let n), .desktop(let n, _): return L("Switch to \(Copy.desktop(n))", "\(Copy.desktop(n))へ切り替え")
            case .next: return L("Switch to Next Space", "次の操作スペースへ移動")
            case .prev: return L("Switch to Previous Space", "前の操作スペースへ移動")
            case .back: return L("Switch to Last Used Space", "直前の操作スペースへ移動")
            case .id: return L("Switch to Space", "操作スペースへ移動")
            }
        case .moveToSpace(let t):
            switch t {
            case .index(let n), .desktop(let n, _): return L("Move Window to \(Copy.desktop(n)) and Follow", "ウインドウを\(Copy.desktop(n))へ移動して切り替え")
            case .next: return L("Move Window to Next Space and Follow", "ウインドウを次の操作スペースへ移動して切り替え")
            case .prev: return L("Move Window to Previous Space and Follow", "ウインドウを前の操作スペースへ移動して切り替え")
            case .back: return L("Move Window to Last Used Space and Follow", "ウインドウを直前の操作スペースへ移動して切り替え")
            case .id: return L("Move Window to Space and Follow", "ウインドウを操作スペースへ移動して切り替え")
            }
        case .sendToSpace(let t):
            switch t {
            case .index(let n), .desktop(let n, _): return L("Send Window to \(Copy.desktop(n))", "ウインドウを\(Copy.desktop(n))へ送る")
            case .next: return L("Send Window to Next Space", "ウインドウを次の操作スペースへ送る")
            case .prev: return L("Send Window to Previous Space", "ウインドウを前の操作スペースへ送る")
            case .back: return L("Send Window to Last Used Space", "ウインドウを直前の操作スペースへ送る")
            case .id: return L("Send Window to Space", "ウインドウを操作スペースへ送る")
            }
        case .fullscreen: return L("Toggle Full Screen", "フルスクリーンを切り替え")
        case .minimize: return L("Minimize Window", "ウインドウを最小化")
        }
    }

    /// Toggles with a known state are labeled with what will happen next.
    func menuLabel(floating: Bool, zoomed: Bool) -> String {
        switch self {
        case .toggleFloat:
            return floating ? L("Return Window to Tiling", "整列対象に戻す") : L("Remove Window from Tiling", "整列対象から外す")
        case .toggleZoom:
            return zoomed ? L("Restore Tiled Layout", "整列した表示に戻す") : L("Fill Work Area", "作業領域いっぱいに広げる")
        default: return label
        }
    }

    var kind: String {
        switch self {
        case .focus: return "edit:focus"
        case .swap: return "edit:swap"
        case .move: return "edit:move"
        case .join: return "edit:join"
        case .resize, .resizeSmart: return "edit:resize"
        case .balance: return "edit:balance"
        case .toggleOrientation: return "edit:toggle-split"
        case .toggleAccordion: return "edit:accordion"
        case .toggleFloat: return "edit:float"
        case .toggleZoom: return "edit:zoom"
        case .focusBack: return "edit:focus-back"
        case .undo: return "edit:undo"
        case .close: return "edit:close"
        case .space: return "space"
        case .moveToSpace: return "move-to-space"
        case .sendToSpace: return "send-to-space"
        case .fullscreen: return "edit:fullscreen"
        case .minimize: return "edit:minimize"
        }
    }

    /// `follow-moved-window`: a default send becomes "move and follow". Resolved where the user acts (shortcuts, the menu), never for the command line.
    func following(_ on: Bool) -> EditCommand {
        if on, case .sendToSpace(let target) = self { return .moveToSpace(target) }
        return self
    }
}

/// One Space row in the menu. apps is nil when window membership could not be observed.
/// One Space in `Coordinator.spaceList()`. `isCurrent` is the current Space only; `isShown` is each display's shown Space.
/// `displayName` is set only when Spaces are grouped by display.
struct SpaceListItem: Equatable {
    var index: Int?
    var id: UInt64
    var isCurrent: Bool
    var isShown: Bool
    var displayName: String? = nil
    var otherDisplay: Bool = false
}

struct SpaceMenuEntry: Equatable {
    var index: Int?
    var id: UInt64
    var isCurrent: Bool
    var windows: Int?
    var apps: [SpaceOverview.App]?
    var fullScreen: Bool
    var isShown: Bool = false
    var displayName: String? = nil
    var otherDisplay: Bool = false
}

enum StatusMenuCopy {
    /// Menu bar text: the desktop number (`barNumber`) and the mode name other than main.
    static func barTitle(mode: String, space: String?) -> String {
        [space, mode == Config.mainModeName ? nil : mode].compactMap { $0 }.joined(separator: " · ")
    }

    /// The current desktop's number. With several displays, each display's shown desktop in list order (`4|1`), `–` for a Space without a number;
    /// one status item is drawn on every display's menu bar, so it cannot show each display its own number.
    static func barNumber(_ list: [SpaceListItem]) -> String? {
        guard list.contains(where: { $0.displayName != nil }) else { return list.first(where: \.isCurrent)?.index.map(String.init) }
        var displays: [String?] = []
        for item in list where !displays.contains(item.displayName) { displays.append(item.displayName) }
        return displays.map { name in list.first { $0.displayName == name && $0.isShown }?.index.map(String.init) ?? "–" }.joined(separator: "|")
    }

    static func availabilityTitle(_ s: AppStatus) -> String {
        switch s.availability {
        case .needsSetup: return L("Setup Required", "初期設定が必要")
        case .manualOnly: return L("Manual Arrangement Only", "手動整列のみ")
        case .paused: return L("Paused in All Spaces", "すべての操作スペースで一時停止中")
        case .automatic:
            if s.currentSpaceAutoPaused { return L("Automatic Arrangement Off in This Space", "この操作スペースの自動整列はオフ") }
            return s.currentSpaceManaged
                ? L("Automatic Arrangement Active", "自動整列中")
                : L("Automatic Arrangement Available (This Space Not Started)", "自動整列を利用可能（この操作スペースは未開始）")
        }
    }

    static var arrangeTitle: String { L("Arrange Now", "今すぐ整列") }

    static var automaticSpaceTitle: String { L("Automatically Arrange This Space", "この操作スペースを自動整列") }

    static func globalPauseTitle(paused: Bool) -> String {
        paused ? L("Resume LazySpace", "LazySpaceを再開") : L("Pause LazySpace", "LazySpaceを一時停止")
    }

    static var editTitle: String { L("Edit Layout", "レイアウトを編集") }
    static var moveWindowToSpaceTitle: String { L("Move Window to Space", "ウインドウを別の操作スペースへ") }

    static func modeTitle(_ mode: String) -> String { L("Mode: \(mode)", "モード: \(mode)") }
    static var settingsTitle: String { L("Settings…", "設定…") }
    static var quitTitle: String { L("Quit LazySpace", "LazySpaceを終了") }
    static var statusItemToolTip: String { L("Open LazySpace controls and status.", "LazySpaceの操作と状態を表示します。") }

    /// A top-level item; separators are not included.
    struct TopEntry: Equatable {
        enum Kind: Equatable { case accessibility, configError, spaces, status, arrange, integrate, spacePause, globalPause, edit, space, mode, update, settings, quit }
        var kind: Kind
        var title: String
    }

    static func topEntries(status s: AppStatus, spaceCount: Int, modeCount: Int) -> [TopEntry] {
        // An available update sits with Settings, so it stays while paused and on full-screen Spaces.
        let utilities = (s.availableUpdate.map { [TopEntry(kind: .update, title: UpdateCopy.menuTitle($0))] } ?? [])
            + [TopEntry(kind: .settings, title: settingsTitle),
               TopEntry(kind: .status, title: ReadyWindowController.menuTitle),
               TopEntry(kind: .quit, title: quitTitle)]
        // Nothing works without permission, so its entry comes first; while the configuration file cannot be applied, its entry comes next.
        let access = (s.trusted ? [] : [TopEntry(kind: .accessibility, title: accessibilityTitle)])
            + (s.configError == nil ? [] : [TopEntry(kind: .configError, title: configErrorTitle)])
        if s.paused { return access + [TopEntry(kind: .globalPause, title: globalPauseTitle(paused: true))] + utilities }
        // With several Spaces, what is on each Space comes first (like AeroSpace's workspace list).
        var items = access + (spaceCount > 1 ? [TopEntry(kind: .spaces, title: ""), TopEntry(kind: .space, title: moveWindowToSpaceTitle)] : [])
        // The window actions are used most, so they come before the arrangement items.
        items += [
            TopEntry(kind: .edit, title: editTitle),
            TopEntry(kind: .spacePause, title: automaticSpaceTitle),
            TopEntry(kind: .arrange, title: arrangeTitle),
        ]
        if offersIntegrate(waiting: s.waiting.count) {
            items.append(TopEntry(kind: .integrate, title: integrateTitle(waiting: s.waiting.count)))
        }
        if modeCount > 1 { items.append(TopEntry(kind: .mode, title: modeTitle(s.mode))) }
        items.append(TopEntry(kind: .globalPause, title: globalPauseTitle(paused: false)))
        return items + utilities
    }

    static var configErrorTitle: String { L("The Configuration File Could Not Be Applied…", "設定ファイルを適用できません…") }
    static var accessibilityTitle: String { L("Allow LazySpace in \(AccessPane.name())…", "「\(AccessPane.name())」でLazySpaceを許可…") }
    static var emptySpace: String { "—" }
    static var unknownSpaceContents: String { L("Windows unavailable", "ウインドウを確認できません") }
    static var fullScreenNote: String { L("Full Screen", "フルスクリーン") }

    /// Width (in half-width units) of app names in an overview row, short enough that the menu stays under half the screen.
    static let appListWidth = 36

    /// As many app names as fit, with a count for the rest. The first is shown even if long.
    static func appList(_ names: [String], width: Int = appListWidth) -> String {
        var shown: [String] = []
        var used = 0
        for (i, name) in names.enumerated() {
            let add = (shown.isEmpty ? 0 : 2) + CLI.displayWidth(name)
            if !shown.isEmpty, used + add > width {
                return shown.joined(separator: ", ") + L(" +\(names.count - i) more", "ほか\(names.count - i)")
            }
            shown.append(name)
            used += add
        }
        return shown.joined(separator: ", ")
    }

    /// Space contents: a dash when empty, with a note for a full-screen Space.
    static func spaceContents(_ names: [String], fullScreen: Bool) -> String {
        if fullScreen && names.isEmpty { return fullScreenNote }
        let list = names.isEmpty ? emptySpace : appList(names)
        return fullScreen ? list + L(" (\(fullScreenNote))", "（\(fullScreenNote)）") : list
    }

    /// Tooltip for an overview row: all names, only when some were left out.
    static func spaceToolTip(_ entry: SpaceMenuEntry) -> String? {
        guard let names = entry.apps?.map(\.name), appList(names) != names.joined(separator: ", ") else { return nil }
        return names.joined(separator: ", ")
    }

    static var spaceReorderNote: String { L("Desktop numbers follow recent use and can change.", "デスクトップの番号は使用状況で入れ替わります。") }

    static func startHint(arrangeKey: String?) -> String {
        let title = arrangeTitle
        if let arrangeKey { return L("\(arrangeKey) (or the menu item “\(title)”)", "\(arrangeKey)（またはメニュー「\(title)」）") }
        return L("the menu item “\(title)”", "メニュー「\(title)」")
    }

    static func notStartedMessage(arrangeKey: String?) -> String {
        let hint = startHint(arrangeKey: arrangeKey)
        return L("This Space has not started tiling yet. Use \(hint) to start.", "この操作スペースはまだ整列していません。\(hint)で始めてください。")
    }

    /// Old operation results stay out of the menu: shown only for a managed Space or within the last 30 minutes.
    /// Space switches are not operation results, so they never appear in the everyday status.
    static let recentLimit: TimeInterval = 30 * 60

    static func showsRecent(result: OperationResult, managed: Bool, now: Date = Date()) -> Bool {
        guard result.kind != "space" else { return false }
        return managed || now.timeIntervalSince(result.finishedAt) <= recentLimit
    }

    static func resumeNotice() -> String { L("Resumed LazySpace.", "LazySpaceを再開しました。") }
    static func pauseNotice() -> String { L("Paused LazySpace.", "LazySpaceを一時停止しました。") }


    static func offersIntegrate(waiting: Int) -> Bool { waiting > 0 }

    /// One window per integration; the count is the total waiting.
    static func integrateTitle(waiting: Int) -> String {
        waiting > 1
            ? L("Add One Waiting Window (\(waiting) Waiting)", "待機中のウインドウを1つ追加（\(waiting)つ待機中）")
            : L("Add One Waiting Window", "待機中のウインドウを1つ追加")
    }

    /// The everyday status line. No window numbers, even while zoomed.
    static func occupancyLine(waiting: Int, floatingCount: Int, zoomed: Bool) -> String {
        var line = L("Waiting windows: \(waiting)", "待機中のウインドウ: \(waiting)")
        if floatingCount > 0 { line += L("  Floating: \(floatingCount)", "  フローティング: \(floatingCount)") }
        if zoomed { line += L("  Zoomed", "  ズーム中") }
        return line
    }

    struct Section: Equatable {
        var title: String
        var commands: [EditCommand]
    }

    /// Disables menu items that cannot run in the current layout. undo and focus back, which cannot be judged, only check for history.
    static func canApply(
        _ command: EditCommand,
        layout: Layout?,
        focused: WindowID?,
        floating: Set<WindowID> = [],
        waiting: Set<WindowID> = [],
        rects: [WindowID: CGRect] = [:],
        canUndo: Bool = false,
        canFocusBack: Bool = false,
        regionMembers: Set<WindowID> = []
    ) -> Bool {
        switch command {
        case .fullscreen, .minimize:
            return focused != nil
        case .undo:
            return canUndo
        case .focusBack:
            return canFocusBack
        case .space:
            return true
        case .moveToSpace, .sendToSpace:
            return focused != nil
        default:
            break
        }
        guard let layout, let focused else { return false }
        let inLayout = layout.windowIDs.contains(focused)
        let managed = inLayout && !floating.contains(focused)
        switch command {
        case .toggleFloat:
            return true
        case .close:
            return inLayout || floating.contains(focused) || waiting.contains(focused)
        case .toggleZoom:
            return managed
        case .focus(let direction):
            // Directional focus can move from and to dialogs in the region (rects include the region's frames).
            guard managed || regionMembers.contains(focused) else { return false }
            return LayoutEdit.neighbor(of: focused, direction: direction, rects: rects, layout: layout) != nil
        case .swap(let direction), .move(let direction), .join(let direction):
            guard managed else { return false }
            return LayoutEdit.neighbor(of: focused, direction: direction, rects: rects, layout: layout) != nil
        case .resize(let axis, let delta):
            guard managed else { return false }
            return LayoutEdit.resize(focused, axis: axis, by: delta, in: layout) != nil
        case .resizeSmart:
            return managed && layout.parentAxis(of: focused) != nil
        case .balance:
            return layout.balanced() != layout
        case .toggleOrientation:
            guard managed else { return false }
            return LayoutEdit.toggleOrientation(of: focused, in: layout) != nil
        case .toggleAccordion:
            guard managed else { return false }
            return LayoutEdit.toggleAccordion(of: focused, in: layout) != nil
        default:
            return false
        }
    }

    static var editSections: [Section] {
        [
            Section(title: L("Focus Window", "操作するウインドウ"), commands: [.focus(.left), .focus(.right), .focus(.up), .focus(.down), .focusBack]),
            Section(title: L("Swap Positions", "位置を交換"), commands: [.swap(.left), .swap(.right), .swap(.up), .swap(.down)]),
            Section(title: L("Reorder", "並べ替え"), commands: [.move(.left), .move(.right), .move(.up), .move(.down)]),
            Section(title: L("Share Neighbor's Area", "隣の領域にまとめる"), commands: [.join(.left), .join(.right), .join(.up), .join(.down)]),
            Section(title: L("Size and Layout", "サイズとレイアウト"), commands: [
                .resize(.horizontal, 0.05), .resize(.horizontal, -0.05),
                .resize(.vertical, 0.05), .resize(.vertical, -0.05),
                .resizeSmart(0.05), .resizeSmart(-0.05),
                .balance, .toggleOrientation, .toggleAccordion,
            ]),
            Section(title: L("Window", "ウインドウ"), commands: [.toggleFloat, .toggleZoom, .undo, .close, .fullscreen, .minimize]),
        ]
    }
}

/// A Space reference. Numbers follow the `list-spaces` order (Mission Control order), starting at 1.
enum SpaceTarget: Equatable {
    case index(Int)
    case next
    case prev
    /// The previous Space (switching only).
    case back
    /// A Space observed in the menu. Full-screen Spaces without numbers can be chosen by OS ID.
    case id(UInt64)
    /// Desktop N of the display at a 1-based position in `list-spaces` (`--display`). Internal form "N@D".
    case desktop(Int, display: Int)

    static func parse(_ s: String) -> SpaceTarget? {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return parseUserInput(s) }
        guard case .index(let n) = parseUserInput(parts[0]), case .index(let d) = parseUserInput(parts[1]) else { return nil }
        return .desktop(n, display: d)
    }

    static func parseUserInput(_ s: String) -> SpaceTarget? {
        switch s {
        case "next": return .next
        case "prev", "previous": return .prev
        case "back": return .back
        default:
            guard !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(s), (1...99).contains(n) else { return nil }
            return .index(n)
        }
    }

    var editText: String {
        switch self {
        case .index(let n): return String(n)
        case .next: return "next"
        case .prev: return "prev"
        case .back: return "back"
        case .id(let id): return "id:\(id)"
        case .desktop(let n, let d): return "\(n)@\(d)"
        }
    }
}

/// One shortcut, built from the configuration (Config.keys / Config.modes[*].keys).
struct HotkeyBinding: Equatable {
    enum Action: Equatable {
        case edit(EditCommand)
        case arrange
        case integrate
        case pauseResume
        case reload
        /// Enters a binding mode ("main" returns).
        case mode(String)
    }
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifiers
    var action: Action
    var display: String
    var command: EditCommand? { if case .edit(let c) = action { return c } else { return nil } }

    /// Uses NSMenuItem's standard shortcut field; modifiers are never derived back from display strings.
    static func applyMenuShortcut(_ binding: HotkeyBinding?, to item: NSMenuItem) {
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        guard let binding,
              let key = Config.Key.keyCodes.first(where: { $0.value == binding.keyCode })?.key else { return }
        var mask: NSEvent.ModifierFlags = []
        if binding.modifiers & 0x0100 != 0 { mask.insert(.command) }
        if binding.modifiers & 0x0200 != 0 { mask.insert(.shift) }
        if binding.modifiers & 0x0800 != 0 { mask.insert(.option) }
        if binding.modifiers & 0x1000 != 0 { mask.insert(.control) }
        let characters = [
            "slash": "/", "minus": "-", "equal": "=", "comma": ",", "period": ".", "semicolon": ";", "quote": "'", "backslash": "\\", "backtick": "`",
            "leftsquarebracket": "[", "rightsquarebracket": "]", "space": " ", "enter": "\r", "tab": "\t", "esc": "\u{1b}", "backspace": "\u{8}",
            "forwarddelete": "\u{f728}", "left": "\u{f702}", "right": "\u{f703}", "up": "\u{f700}", "down": "\u{f701}",
            "pageup": "\u{f72c}", "pagedown": "\u{f72d}", "home": "\u{f729}", "end": "\u{f72b}",
            "yen": "¥", "underscore": "_", "sectionsign": "§",
            "keypaddecimal": ".", "keypadmultiply": "*", "keypadplus": "+", "keypadclear": "\u{f739}",
            "keypaddivide": "/", "keypadenter": "\u{3}", "keypadminus": "-", "keypadequals": "=",
        ]
        let equivalent: String
        if let character = characters[key] { equivalent = character }
        else if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...20).contains(number) {
            equivalent = String(UnicodeScalar(0xf704 + number - 1)!)
        } else if key.hasPrefix("keypad"), let number = Int(key.dropFirst(6)) {
            equivalent = String(number)
        } else if key.count == 1 { equivalent = key }
        else { return } // Keys without a character keyEquivalent (Eisu, Kana, and the like) are handled only by Carbon.
        if key.hasPrefix("keypad") { mask.insert(.numericPad) }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = mask
    }

    /// Command name (settings key) -> action; nil when unknown.
    static func action(forCommand name: String) -> Action? {
        switch name {
        case "arrange": return .arrange
        case "integrate": return .integrate
        case "pause-resume": return .pauseResume
        case "reload": return .reload
        case "resize-width-shrink": return .edit(.resize(.horizontal, -0.05))
        case "resize-width-grow": return .edit(.resize(.horizontal, 0.05))
        case "resize-height-grow": return .edit(.resize(.vertical, 0.05))
        case "resize-height-shrink": return .edit(.resize(.vertical, -0.05))
        case "resize-smart-shrink": return .edit(.resizeSmart(-0.05))
        case "resize-smart-grow": return .edit(.resizeSmart(0.05))
        default:
            if let m = Config.modeName(fromCommand: name) { return .mode(m) }
            return EditCommand.parse(name).map { .edit($0) }
        }
    }

    /// Bindings of the given mode; empty for an undeclared mode. `move-to-space-*` follow when `follow-moved-window` is on.
    static func from(_ config: Config, mode: String = Config.mainModeName) -> [HotkeyBinding] {
        guard let keys = config.keys(forMode: mode) else { return [] }
        var out: [HotkeyBinding] = []
        for (name, key) in keys.sorted(by: { $0.key < $1.key }) {
            guard var action = action(forCommand: name) else { continue }
            if case .edit(let command) = action { action = .edit(command.following(config.followMovedWindow)) }
            out.append(HotkeyBinding(keyCode: key.keyCode, modifiers: key.carbonModifiers, action: action, display: key.display))
        }
        return out
    }

    var label: String {
        switch action {
        case .edit(let c): return c.label
        case .arrange: return L("Arrange This Space", "この操作スペースを整列")
        case .integrate: return L("Add One Waiting Window", "待機中のウインドウを1つ追加")
        case .pauseResume: return L("Pause or Resume LazySpace", "LazySpaceを一時停止／再開")
        case .reload: return L("Reload Configuration", "設定ファイルを再読み込み")
        case .mode(let m):
            if m == Config.mainModeName { return L("Return to main Mode", "mainモードへ戻る") }
            return L("Enter Mode \(m)", "モード\(m)へ")
        }
    }
}
