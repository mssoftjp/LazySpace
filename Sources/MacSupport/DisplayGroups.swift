import AppKit
import Foundation

/// The Spaces of one display, as listed in the menu and by `list-spaces` when more than one display has its own Spaces.
public struct DisplayGroup: Equatable {
    /// SkyLight's "Display Identifier" (the CGDisplay UUID string).
    public var display: String
    /// The name macOS shows for the display, with " (n)" in display order when two displays share it.
    public var name: String
    /// 1-based position in SkyLight's display order (`--display N`).
    public var index: Int
    public var records: [SpaceObserver.Space]
    /// The Space this display is showing.
    public var shown: UInt64?

    public init(display: String, name: String, index: Int, records: [SpaceObserver.Space], shown: UInt64?) {
        self.display = display; self.name = name; self.index = index; self.records = records; self.shown = shown
    }

    public var order: [(id: UInt64, type: Int32?)] { records.map { (id: $0.id, type: $0.type) } }
    /// Ordinary desktops in Mission Control order (desktop N is `desktops[N - 1]`).
    public var desktops: [UInt64] {
        let numbers = SpaceObserver.desktopNumbers(order)
        return records.compactMap { numbers[$0.id] == nil ? nil : $0.id }
    }
}

public enum DisplayGroups {
    /// Groups in SkyLight's display order. Empty with fewer than two displays, or when any display cannot be matched to a screen name
    /// (a display being connected or disconnected): callers then use the current display alone, as with one display.
    public static func make(_ displays: [SpaceObserver.ManagedDisplay], names: [String: String]) -> [DisplayGroup] {
        guard displays.count >= 2, Set(displays.map(\.display)).count == displays.count else { return [] }
        var matched: [String] = []
        for display in displays {
            guard let name = names[display.display], !name.isEmpty else { return [] }
            matched.append(name)
        }
        var counts: [String: Int] = [:]
        for name in matched { counts[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return zip(displays, matched).enumerated().map { offset, pair in
            let (display, name) = pair
            var label = name
            if counts[name, default: 0] > 1 {
                seen[name, default: 0] += 1
                label = "\(name) (\(seen[name]!))"
            }
            return DisplayGroup(display: display.display, name: label, index: offset + 1, records: display.records, shown: display.currentSpace)
        }
    }

    /// Screen names by display identifier (`NSScreen.localizedName`).
    public static func screenNames() -> [String: String] {
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            if let uuid = Screens.uuid(of: screen) { names[uuid] = screen.localizedName }
        }
        return names
    }
}
