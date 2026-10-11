import AppKit
import Foundation
import LayoutCore

/// Per-Space window overview, counting windows on other Spaces too, from CGWindowList and SLS without AX.
public struct SpaceOverview: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var spaceID: UInt64
        public var type: Int32?
        public var isCurrent: Bool
        public var windowIDs: [WindowID]
        /// Apps with windows on this Space (screen reading order, no duplicates). Used for the menu overview.
        public var apps: [App]? = nil
        /// The Space uuid, only when it appears once across all displays.
        public var uuid: String? = nil
        /// Standard desktop number; nil for full screen, Split View, and unknown types.
        public var desktopIndex: Int? = nil
        /// SkyLight's display identifier, the display's name as macOS shows it (`DisplayGroups`), and its 1-based position (`--display`).
        /// Name and position are nil when a display cannot be matched to a screen.
        public var display: String? = nil
        public var displayName: String? = nil
        public var displayIndex: Int? = nil
    }
    public struct App: Codable, Equatable {
        public var name: String
        public var bundleID: String?
        public var pid: Int32
    }
    public var spaces: [Entry]
    /// Windows on no Space (membership unknown).
    public var unknown: [WindowID]
    /// Whether Mission Control's "Automatically rearrange Spaces based on most recent use" is on.
    /// When on, the order changes with each switch, so `space N` numbers are unstable.
    public var reordersByRecentUse: Bool = false

    /// The Dock setting (mru-spaces); the macOS default (on) when the key is absent.
    public static func dockReordersByRecentUse() -> Bool {
        (CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString) as? Bool) ?? true
    }

    /// Top-edge difference that still counts as the same row. Absorbs a few points from tile gaps and rounding, and is half the
    /// minimum counted window height (40 pt), so two windows stacked without overlapping are not one row on their own.
    /// A window in between (tops 0 / 20 / 40) still chains them into one row (see `ordered`).
    static let rowTolerance: CGFloat = 20

    /// Screen reading order (rows from the top, left to right within a row). Apps sort by their earliest window, then by name (the Finder comparison), then pid.
    /// Coordinates are CGWindowList global coordinates (top-left origin). A tolerance inside the comparator breaks transitivity, so row numbers come first:
    /// walk tops in ascending order and start a new row when the difference from the previous top exceeds the tolerance.
    /// Measuring from the row's first window would let a slightly higher window lead the row and split its tiles; the previous-top difference keeps tile rows intact.
    /// The trade-off: a staircase of steps within tolerance chains into one row. Counted windows are at least 40 pt high, so tile rows are 40 pt apart and do not chain
    /// by themselves, but a window in between (tops 0 / 20 / 40) joins them into one row.
    /// Windows that are not `ranked` count for neither rows nor position; apps with only such windows come last by name.
    static func ordered(_ windows: [(app: App, bounds: CGRect, ranked: Bool)]) -> [App] {
        var rowOf: [CGFloat: Int] = [:]
        var previous = -CGFloat.infinity
        var row = -1
        for top in Set(windows.filter(\.ranked).map(\.bounds.minY)).sorted() {
            if top - previous > rowTolerance { row += 1 }
            previous = top
            rowOf[top] = row
        }
        var first: [pid_t: (app: App, row: Int, x: CGFloat, y: CGFloat)] = [:]
        for w in windows {
            let key = w.ranked ? (rowOf[w.bounds.minY] ?? 0, w.bounds.minX, w.bounds.minY) : (Int.max, CGFloat.infinity, CGFloat.infinity)
            if let f = first[w.app.pid], (f.row, f.x, f.y) <= key { continue }
            first[w.app.pid] = (w.app, key.0, key.1, key.2)
        }
        return first.values.sorted {
            if ($0.row, $0.x, $0.y) != ($1.row, $1.x, $1.y) { return ($0.row, $0.x, $0.y) < ($1.row, $1.x, $1.y) }
            switch $0.app.name.localizedStandardCompare($1.app.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return $0.app.pid < $1.app.pid
            }
        }.map(\.app)
    }

    /// Whether a window counts for position. Not for hidden apps or transparent windows, nor, on a Space shown on a display, windows not on screen (minimized, for example).
    /// Windows of a Space not shown are usually not on screen and cannot be told from minimized ones, so they count; so do all windows when the shown Spaces are unknown (empty).
    static func rankable(appHidden: Bool, alpha: Double, onScreen: Bool, space: UInt64, visibleSpaces: Set<UInt64>) -> Bool {
        !appHidden && alpha > 0 && (onScreen || !visibleSpaces.contains(space))
    }

    /// Mission Control's overview concerns displayed windows. Ordered-out
    /// panels, minimized windows and hidden app windows are not desktop content.
    /// Failure to read the optional ordering API preserves the CG fallback.
    static func includesWindow(appHidden: Bool, alpha: Double, orderedIn: Bool?) -> Bool {
        !appHidden && alpha > 0 && orderedIn != false
    }

    public static func take() -> SpaceOverview? {
        guard let observer = SpaceObserver() else { return nil }
        let active = observer.activeSpace()
        let displays = observer.managedDisplays()
        var entries: [UInt64: Entry] = [:]
        // Mission Control order (display order, then Space order within it). ID values say nothing about order.
        var order: [UInt64] = []
        let uuids = SpaceObserver.uniqueUUIDs(displays)
        let names = DisplayGroups.screenNames()
        let groups = DisplayGroups.make(displays, names: names)
        // Without groups (a display cannot be matched to a screen), only the display with the current Space, as in the menu.
        let listed = groups.isEmpty && displays.count > 1 ? displays.filter { $0.spaces.contains(active ?? 0) } : displays
        for (offset, d) in listed.enumerated() {
            let numbers = SpaceObserver.desktopNumbers(d.records.map { ($0.id, $0.type) })
            let group = groups.isEmpty ? nil : groups[offset]
            let name = group?.name ?? (listed.count == 1 ? names[d.display] : nil)
            let index = group?.index ?? (displays.count == 1 ? 1 : nil)
            for record in d.records {
                guard entries[record.id] == nil else { return nil }
                entries[record.id] = Entry(spaceID: record.id, type: record.type, isCurrent: record.id == active, windowIDs: [], uuid: uuids[record.id], desktopIndex: numbers[record.id],
                                           display: d.display, displayName: name, displayIndex: index)
                order.append(record.id)
            }
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        // Spaces shown on each display, plus the current Space in case display information is missing.
        let visible = Set(displays.compactMap(\.currentSpace) + [active].compactMap { $0 })
        var unknown: [WindowID] = []
        let me = ProcessInfo.processInfo.processIdentifier
        var windows: [UInt64: [(app: App, bounds: CGRect, ranked: Bool)]] = [:]
        for (wid, rec) in WindowList.all() where rec.layer == 0 && rec.pid != me && rec.bounds.width >= 60 && rec.bounds.height >= 40 {
            guard let app = NSRunningApplication(processIdentifier: rec.pid), app.activationPolicy == .regular else { continue }
            guard includesWindow(appHidden: app.isHidden, alpha: rec.alpha, orderedIn: observer.isOrderedIn(wid)) else { continue }
            let list = observer.spaces(for: wid)
            if list.isEmpty { unknown.append(WindowID(wid)); continue }
            let entryApp = App(name: app.localizedName ?? app.bundleIdentifier ?? "pid \(rec.pid)", bundleID: app.bundleIdentifier, pid: rec.pid)
            for sid in list where entries[sid] != nil {
                entries[sid]?.windowIDs.append(WindowID(wid))
                // Counted, but invisible windows do not count for position (`rankable`).
                let ranked = rankable(appHidden: app.isHidden, alpha: rec.alpha, onScreen: rec.onScreen, space: sid, visibleSpaces: visible)
                windows[sid, default: []].append((entryApp, rec.bounds, ranked))
            }
        }
        for sid in entries.keys {
            entries[sid]?.apps = ordered(windows[sid] ?? [])
        }
        return SpaceOverview(spaces: entries.values.sorted { (position[$0.spaceID] ?? .max) < (position[$1.spaceID] ?? .max) }, unknown: unknown.sorted(),
                             reordersByRecentUse: dockReordersByRecentUse())
    }
}
