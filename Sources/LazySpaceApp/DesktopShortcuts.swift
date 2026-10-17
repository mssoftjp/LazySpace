import Copy
import Foundation
import MacSupport

/// Reader for tier 0 (macOS "Switch to Desktop N"). SpaceControl in the product, replaced in tests.
protocol DesktopShortcutSource {
    /// The target Space's Desktop number (1-16); nil unless there is one managed display, every type is readable, and it is a standard Desktop.
    func desktopNumber(of target: UInt64) -> Int?
    /// Number of standard Desktops on this display; nil when the conditions fail.
    func ordinaryDesktopCount() -> Int?
    func desktopShortcut(_ desktop: Int) -> SpaceControl.DesktopShortcutRead
    /// "Move left/right a Space".
    func arrowShortcut(right: Bool) -> SpaceControl.ArrowShortcutRead
}

extension SpaceControl: DesktopShortcutSource {}

/// Why tier 0 is not used.
enum DesktopShortcutBlock: Equatable {
    case multipleDisplays
    case reordersByRecentUse
    /// The order is unreadable, the target is not a standard Desktop, or its number is not 1-16.
    case notOrdinaryDesktop
    case dockUnknown
    case unread
    case off
    case unusable
    case conflict
    case suppressed
}

/// Whether to use tier 0.
enum DesktopShortcutDecision: Equatable {
    case use(SpaceControl.DesktopHotkey, dockPID: pid_t)
    case skip(DesktopShortcutBlock)
}

/// Records of observed pass-through (suppression) and confirmed arrival, keyed by the Dock pid and the observed hotkey setting (ID, enabled, key code, modifiers).
/// They vanish when the Dock pid or the hotkey setting changes. Suppression is per hotkey (per Desktop N; left and right separately).
/// Left/right pass-through is recorded only when switching (mouse not held); SpaceControl does not ask for records during drags.
struct HotkeyMemory: Equatable {
    struct Key: Hashable {
        var dockPID: pid_t
        var shortcut: SpaceControl.DesktopHotkey
    }

    struct ArrowKey: Hashable {
        var dockPID: pid_t
        var shortcut: SpaceControl.ArrowHotkey
    }

    private(set) var suppressed: Set<Key> = []
    private(set) var confirmed: Set<Key> = []
    private(set) var arrowSuppressed: Set<ArrowKey> = []
    private(set) var arrowConfirmed: Set<ArrowKey> = []

    /// Drops records of another Dock (restarted or unreadable).
    mutating func forget(exceptDock dock: pid_t?) {
        suppressed = suppressed.filter { $0.dockPID == dock }
        confirmed = confirmed.filter { $0.dockPID == dock }
        arrowSuppressed = arrowSuppressed.filter { $0.dockPID == dock }
        arrowConfirmed = arrowConfirmed.filter { $0.dockPID == dock }
    }

    /// Left/right expire the same way: off, unsendable, or a different assignment is a settings change. Conflicts and unreadable reads keep records.
    mutating func observe(right: Bool, _ read: SpaceControl.ArrowShortcutRead) {
        let current: SpaceControl.ArrowHotkey?
        switch read {
        case .usable(let shortcut), .conflict(let shortcut): current = shortcut
        case .off, .unusable: current = nil
        case .unread: return
        }
        arrowSuppressed = arrowSuppressed.filter { $0.shortcut.right != right || $0.shortcut == current }
        arrowConfirmed = arrowConfirmed.filter { $0.shortcut.right != right || $0.shortcut == current }
    }

    func isSuppressed(dock: pid_t, _ shortcut: SpaceControl.ArrowHotkey) -> Bool { arrowSuppressed.contains(ArrowKey(dockPID: dock, shortcut: shortcut)) }
    func isConfirmed(dock: pid_t, _ shortcut: SpaceControl.ArrowHotkey) -> Bool { arrowConfirmed.contains(ArrowKey(dockPID: dock, shortcut: shortcut)) }

    mutating func recordPassThrough(dock: pid_t, _ shortcut: SpaceControl.ArrowHotkey) {
        let key = ArrowKey(dockPID: dock, shortcut: shortcut)
        arrowSuppressed.insert(key); arrowConfirmed.remove(key)
    }

    mutating func recordArrival(dock: pid_t, _ shortcut: SpaceControl.ArrowHotkey) {
        let key = ArrowKey(dockPID: dock, shortcut: shortcut)
        arrowConfirmed.insert(key); arrowSuppressed.remove(key)
    }

    /// Drops stale records to match the read setting (the same for planning and status). Off, unsendable, or a different assignment is a settings change.
    /// An overlap with a LazySpace shortcut (`conflict`) is not, so that setting's records stay. An unreadable read tells nothing, so records stay.
    mutating func observe(desktop: Int, _ read: SpaceControl.DesktopShortcutRead) {
        let id = Int32(117 + desktop)
        switch read {
        case .usable(let shortcut), .conflict(let shortcut): forget(id: id, unless: shortcut)
        case .off, .unusable: forget(id: id, unless: nil)
        case .unread: break
        }
    }

    /// When the hotkey's setting changed (or became unusable), drops records of the old setting.
    mutating func forget(id: Int32, unless current: SpaceControl.DesktopHotkey?) {
        suppressed = suppressed.filter { $0.shortcut.id != id || $0.shortcut == current }
        confirmed = confirmed.filter { $0.shortcut.id != id || $0.shortcut == current }
    }

    func isSuppressed(dock: pid_t, _ shortcut: SpaceControl.DesktopHotkey) -> Bool { suppressed.contains(Key(dockPID: dock, shortcut: shortcut)) }
    func isConfirmed(dock: pid_t, _ shortcut: SpaceControl.DesktopHotkey) -> Bool { confirmed.contains(Key(dockPID: dock, shortcut: shortcut)) }

    mutating func recordPassThrough(dock: pid_t, _ shortcut: SpaceControl.DesktopHotkey) {
        let key = Key(dockPID: dock, shortcut: shortcut)
        suppressed.insert(key); confirmed.remove(key)
    }

    mutating func recordArrival(dock: pid_t, _ shortcut: SpaceControl.DesktopHotkey) {
        let key = Key(dockPID: dock, shortcut: shortcut)
        confirmed.insert(key); suppressed.remove(key)
    }
}

enum DesktopShortcuts {
    /// Tier 0 conditions: one physical display, rearranging off, a standard Desktop target (1-16), a known Dock,
    /// an enabled sendable hotkey not overlapping a LazySpace shortcut, and no suppression record for this Dock and setting.
    static func decide(screens: Int, reorders: Bool, desktop: Int?, read: SpaceControl.DesktopShortcutRead?, dockPID: pid_t?,
                       memory: HotkeyMemory) -> DesktopShortcutDecision {
        if screens != 1 { return .skip(.multipleDisplays) }
        if reorders { return .skip(.reordersByRecentUse) }
        guard desktop != nil, let read else { return .skip(.notOrdinaryDesktop) }
        guard let dockPID else { return .skip(.dockUnknown) }
        switch read {
        case .unread: return .skip(.unread)
        case .off: return .skip(.off)
        case .unusable: return .skip(.unusable)
        case .conflict: return .skip(.conflict)
        case .usable(let shortcut):
            return memory.isSuppressed(dock: dockPID, shortcut) ? .skip(.suppressed) : .use(shortcut, dockPID: dockPID)
        }
    }

    /// Per-Desktop state for the status line.
    enum State: Equatable {
        /// A switch was confirmed recently.
        case working
        /// Set but unconfirmed.
        case unverified
        /// Paused after no response.
        case paused
        case ineligible(DesktopShortcutBlock)
    }

    /// The `lazyspace status` line. `global` is why it is unused on the whole display (several displays, rearranging, unreadable order, unknown Dock).
    static func statusLine(global: DesktopShortcutBlock?, states: [(desktop: Int, state: State)]) -> String {
        if let global { return L("Not used", "使っていません") + " — " + reason(global) }
        guard !states.isEmpty else { return L(.desktopShortcutsNotUsedNoOrdinaryDesktops) }
        var parts: [String] = []
        func numbers(_ wanted: (State) -> Bool) -> [Int] { states.filter { wanted($0.state) }.map(\.desktop) }
        let working = numbers { $0 == .working }
        if !working.isEmpty { parts.append(L("in use for Desktop ", "使用中: デスクトップ") + ranges(working)) }
        let unverified = numbers { $0 == .unverified }
        if !unverified.isEmpty { parts.append(L("on but not yet confirmed for ", "設定あり・未確認: ") + ranges(unverified)) }
        let paused = numbers { $0 == .paused }
        if !paused.isEmpty {
            parts.append(L(.desktopShortcutsPausedForMacOSDidNot(ranges(paused), pausedAdvice)))
        }
        var blocks: [DesktopShortcutBlock] = []
        for case (_, .ineligible(let block)) in states where !blocks.contains(block) { blocks.append(block) }
        for block in blocks {
            let list = numbers { $0 == .ineligible(block) }
            parts.append(L(.desktopShortcutsNotUsedFor(ranges(list), reason(block))))
        }
        let text = parts.joined(separator: L("; ", "、"))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The left/right state (`lazyspace status` and Settings).
    static func arrowState(_ read: SpaceControl.ArrowShortcutRead, dock: pid_t?, memory: HotkeyMemory) -> State {
        switch read {
        case .usable(let shortcut):
            guard let dock else { return .unverified }
            if memory.isSuppressed(dock: dock, shortcut) { return .paused }
            return memory.isConfirmed(dock: dock, shortcut) ? .working : .unverified
        case .conflict: return .ineligible(.conflict)
        case .off: return .ineligible(.off)
        case .unusable: return .ineligible(.unusable)
        case .unread: return .ineligible(.unread)
        }
    }

    static func arrowStatusText(_ state: State) -> String {
        switch state {
        case .working: return L(.desktopShortcutsInUse)
        case .unverified: return L(.desktopShortcutsOnButNotYetConfirmed)
        case .paused: return L(.desktopShortcutsPausedMacOSDidNotRespond(pausedAdvice))
        case .ineligible(let block): return L(.desktopShortcutsNotUsed(reason(block)))
        }
    }

    /// The status advice for a paused shortcut; the same remedy as `logOutAdvice`, never restarting the Dock.
    static var pausedAdvice: String {
        L(.desktopShortcutsPausedAdvice)
    }

    /// Guidance when macOS does not respond to the left/right shortcuts (Settings and operation results). Never recommends restarting the Dock.
    static var logOutAdvice: String {
        L(.desktopShortcutsLogOutAdvice)
    }

    /// Text when macOS did not respond to stepping, it is suppressed, or there is no tap.
    static func steppingText(_ issue: SpaceControl.SteppingIssue) -> String {
        switch issue {
        case .notHonored(let right):
            let name = MacItem.moveSpace(right: right)
            return L("macOS did not respond to “\(name)”.", "macOSが「\(name)」に応答しませんでした。") + Copy.sentenceSeparator + logOutAdvice
        case .suppressed(let right):
            let name = MacItem.moveSpace(right: right)
            return L("LazySpace is not using “\(name)” for now because macOS did not respond to it earlier.",
                     "以前macOSが「\(name)」に応答しなかったため、いまは使っていません。") + Copy.sentenceSeparator + logOutAdvice
        case .noTap:
            return L(.desktopShortcutsLazySpaceCouldNotPrepareTo)
        case .configuration(let text):
            return text
        }
    }

    static func reason(_ block: DesktopShortcutBlock) -> String {
        switch block {
        case .multipleDisplays: return L(.desktopShortcutsMoreThanOneDisplay)
        case .reordersByRecentUse: return L(.desktopShortcutsSpacesAreRearrangedByMost)
        case .notOrdinaryDesktop: return L(.desktopShortcutsTheOrderOfSpacesCould)
        case .dockUnknown: return L(.desktopShortcutsTheDockCouldNotBe)
        case .unread: return L(.desktopShortcutsShortcutCouldNotBeRead)
        case .off: return L(.desktopShortcutsShortcutOff)
        case .unusable: return L(.desktopShortcutsShortcutCannotBeSent)
        case .conflict: return L(.desktopShortcutsSameAsALazySpaceShortcut)
        case .suppressed: return L(.desktopShortcutsMacOSDidNotRespond)
        }
    }

    /// Collapses consecutive numbers (1, 2, 3, 5 -> 1–3, 5).
    static func ranges(_ numbers: [Int]) -> String {
        var out: [String] = []
        var i = 0
        let sorted = numbers.sorted()
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            out.append(j > i + 1 ? "\(sorted[i])–\(sorted[j])" : (j == i + 1 ? "\(sorted[i]), \(sorted[j])" : "\(sorted[i])"))
            i = j + 1
        }
        return out.joined(separator: ", ")
    }
}
