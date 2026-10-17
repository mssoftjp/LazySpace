import AppKit
import Foundation
import MacSupport

/// Look of the Space overview and send destinations: number, app icons, and app names per row.
/// Text lives in `StatusMenuCopy`; whether and how to switch lives in `AppDelegate`.
enum SpaceOverviewMenu {
    /// Up to 3 icons, same width on every row so app names line up.
    static let iconSize: CGFloat = 16
    static let iconStep: CGFloat = 11
    static let maxIcons = 3
    static var iconStripWidth: CGFloat { iconSize + iconStep * CGFloat(maxIcons - 1) }

    static func item(_ entry: SpaceMenuEntry, action: Selector, target: AnyObject) -> NSMenuItem {
        let contents = entry.apps.map { StatusMenuCopy.spaceContents($0.map(\.name), fullScreen: entry.fullScreen) }
            ?? (entry.fullScreen ? StatusMenuCopy.fullScreenNote : StatusMenuCopy.unknownSpaceContents)
        let prefix = entry.index.map { "\($0)  " } ?? ""
        let item = NSMenuItem(title: prefix + contents, action: action, keyEquivalent: "")
        item.attributedTitle = title(index: entry.index, icons: icons(for: entry.apps ?? []), contents: contents, dimmed: entry.apps?.isEmpty ?? true)
        item.toolTip = StatusMenuCopy.spaceToolTip(entry)
        item.state = entry.isShown || entry.isCurrent ? .on : .off
        item.target = target
        return item
    }

    /// The display's name above its first row, when Spaces are grouped by display.
    static func header(before offset: Int, in entries: [SpaceMenuEntry]) -> NSMenuItem? {
        guard let name = entries[offset].displayName, offset == 0 || entries[offset - 1].displayName != name else { return nil }
        return NSMenuItem.sectionHeader(title: name)
    }

    /// Number (monospaced digits), icons, then app names. Icons sit inside the string after the number, not as the row image,
    /// and share one width on every row so names line up. An empty Space's name is dimmed.
    static func title(index: Int?, icons: NSImage, contents: String, dimmed: Bool) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let numberWidth = font.pointSize * 1.8
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: numberWidth),
                              NSTextTab(textAlignment: .left, location: numberWidth + icons.size.width + font.pointSize * 0.6)]
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: (index.map(String.init) ?? "") + "\t", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium),
            .paragraphStyle: paragraph,
        ])
        let attachment = NSTextAttachment()
        attachment.image = icons
        // Vertically centered on the cap height.
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - icons.size.height) / 2, width: icons.size.width, height: icons.size.height)
        let iconText = NSMutableAttributedString(attachment: attachment)
        iconText.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: iconText.length))
        text.append(iconText)
        guard !contents.isEmpty else { return text }
        text.append(NSAttributedString(string: "\t" + contents, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        return text
    }

    /// App icons slightly overlapped. A fourth and later app show as "and N more" in the names. Empty: a transparent image of the same width.
    static func icons(for apps: [SpaceOverview.App]) -> NSImage {
        let images = apps.prefix(maxIcons).compactMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
        let size = NSSize(width: iconStripWidth, height: iconSize)
        return NSImage(size: size, flipped: false) { _ in
            // Draw back to front so the first app is on top.
            for (i, image) in images.enumerated().reversed() {
                image.draw(in: NSRect(x: CGFloat(i) * iconStep, y: 0, width: iconSize, height: iconSize),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }
}
