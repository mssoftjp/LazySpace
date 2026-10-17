import AppKit
import Copy
import Settings
import XCTest
@testable import LazySpaceApp

final class ActionPictogramTests: XCTestCase {
    private let kinds: [ActionPictogram] = [
        .focus, .swap, .move, .join, .resize, .smartGrow, .smartShrink, .balance, .undo,
        .toggleSplit, .accordion, .arrange, .integrate, .pause, .reload, .close, .focusBack,
        .float, .zoom, .fullscreen, .minimize, .switchSpace(3), .spaceNext, .spacePrev, .spaceBack,
        .moveToSpace(3), .moveToSpaceNext, .moveToSpacePrev, .placementBeside, .placementEnd,
    ]

    override func tearDown() {
        Copy.language = .english
        super.tearDown()
    }

    func testEveryCommandAndDirectionGroupHasTheSharedPictogram() {
        for name in Config.commandNames {
            if name.hasPrefix("mode-") {
                XCTAssertNil(ActionPictogram.forCommand(name), name)
            } else {
                XCTAssertNotNil(ActionPictogram.forCommand(name), name)
            }
        }
        XCTAssertNil(ActionPictogram.forCommand("mode-custom"))
        XCTAssertNil(ActionPictogram.forCommand("mode-service"))
        XCTAssertNil(ActionPictogram.forCommand("mode-main"))
        for group in DirectionGroup.allCases {
            let pictogram = ActionPictogram.forGroup(group)
            for command in group.commands {
                XCTAssertEqual(ActionPictogram.forCommand(command), pictogram, command)
            }
        }
        XCTAssertEqual(ActionPictogram.forCommand("resize-width-shrink"), .resize)
        XCTAssertEqual(ActionPictogram.forCommand("resize-height-grow"), .resize)
        XCTAssertEqual(ActionPictogram.forCommand("resize-smart-grow"), .smartGrow)
        XCTAssertEqual(ActionPictogram.forCommand("resize-smart-shrink"), .smartShrink)
        XCTAssertEqual(ActionPictogram.forCommand("focus-back"), .focusBack)
        XCTAssertNotEqual(ActionPictogram.forCommand("focus-back"), ActionPictogram.forCommand("focus-left"))
        XCTAssertEqual(ActionPictogram.forCommand("switchSpace-nope"), nil)
        XCTAssertEqual(ActionPictogram.forCommand("space-3"), .switchSpace(3))
        XCTAssertEqual(ActionPictogram.forCommand("move-to-space-3"), .moveToSpace(3))
        XCTAssertNotEqual(ActionPictogram.forCommand("space-1"), ActionPictogram.forCommand("space-2"))
        XCTAssertNotEqual(ActionPictogram.forCommand("move-to-space-1"), ActionPictogram.forCommand("move-to-space-2"))
    }

    func testDescriptionsStayReadableInBothLanguagesWithoutInternalNames() {
        let hyphenated = Config.commandNames.filter { $0.contains("-") }
        for language in [Language.english, .japanese] {
            Copy.language = language
            for kind in kinds {
                XCTAssertFalse(kind.help.isEmpty, "\(kind) \(language.rawValue)")
                for token in hyphenated {
                    XCTAssertFalse(kind.help.contains(token), "\(kind) help contains \(token) in \(language.rawValue): \(kind.help)")
                }
            }
        }
        Copy.language = .english
        XCTAssertEqual(ActionPictogram.balance.help, "Resets the layout’s split ratios to equal shares.")
        XCTAssertEqual(ActionPictogram.accordion.help, "Switches the split between overlapping and tiled windows.")
        XCTAssertEqual(ActionPictogram.zoom.help, "Fills the work area with the focused window, or restores the tiled layout.")
        XCTAssertTrue(ActionPictogram.focus.help.contains("focus"))
        XCTAssertTrue(ActionPictogram.reload.help.contains("configuration"))
        XCTAssertTrue(ActionPictogram.close.help.contains("Closes"))
        Copy.language = .japanese
        XCTAssertEqual(ActionPictogram.balance.help, "レイアウトの分割比率を均等に戻します。")
        XCTAssertEqual(ActionPictogram.accordion.help, "分割内のウインドウを重ねて表示、または並べて表示します。")
        XCTAssertEqual(ActionPictogram.zoom.help, "フォーカス中のウインドウを作業領域いっぱいに広げる、または整列した表示に戻します。")
        XCTAssertTrue(ActionPictogram.focus.help.contains("フォーカス"))
    }

    func testContrastOutlineIsOnePointAndEmphasizedUsesTheSelectionPalette() {
        let standard = ActionPictogram.Palette.standard(increaseContrast: false)
        let contrast = ActionPictogram.Palette.standard(increaseContrast: true)
        let emphasized = ActionPictogram.Palette.emphasized
        XCTAssertEqual(standard.subjectOutlineWidth, 0)
        XCTAssertNil(standard.subjectOutline)
        XCTAssertEqual(standard.arrowWidth, 1.25, accuracy: 0.001)
        XCTAssertEqual(contrast.subjectOutlineWidth, 1, accuracy: 0.001)
        XCTAssertNotNil(contrast.subjectOutline)
        XCTAssertEqual(contrast.arrowWidth, 1.5, accuracy: 0.001)
        XCTAssertEqual(emphasized.subjectOutlineWidth, 0)
        XCTAssertEqual(emphasized.arrowWidth, 1.25, accuracy: 0.001)
    }

    func testPictogramsAreDistinctInLightAndDarkAndWhenEmphasized() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let images = try kinds.map { try bitmap($0, appearance: appearance, emphasized: false) }
            for image in images {
                XCTAssertFalse(try isBlank(image), "\(appearance.rawValue)")
            }
            for index in images.indices {
                for other in images.indices where other > index {
                    XCTAssertFalse(try samePixels(images[index], images[other]), "\(kinds[index]) matches \(kinds[other]) in \(appearance.rawValue)")
                }
            }
            for kind in kinds {
                let emphasized = try bitmap(kind, appearance: appearance, emphasized: true)
                XCTAssertFalse(try isBlank(emphasized))
                let standard = try bitmap(kind, appearance: appearance, emphasized: false)
                XCTAssertFalse(try samePixels(emphasized, standard), "\(kind) \(appearance.rawValue)")
                if appearance == .aqua, kind == .join || kind == .close {
                    XCTAssertFalse(containsDarkPixels(emphasized), "\(kind) emphasized in light mode still has dark ink")
                }
            }
        }
        XCTAssertFalse(try samePixels(bitmap(.switchSpace(1), appearance: .aqua, emphasized: false), bitmap(.switchSpace(2), appearance: .aqua, emphasized: false)))
        XCTAssertFalse(try samePixels(bitmap(.moveToSpace(1), appearance: .aqua, emphasized: false), bitmap(.moveToSpace(2), appearance: .aqua, emphasized: false)))
        XCTAssertFalse(try samePixels(bitmap(.switchSpace(3), appearance: .darkAqua, emphasized: false), bitmap(.moveToSpace(3), appearance: .darkAqua, emphasized: false)))
    }

    func testResizeAndSwapDifferAtOneX() throws {
        let size = NSSize(width: 28, height: 18)
        let resize = try bitmap(.resize, appearance: .aqua, emphasized: false, size: size)
        let swap = try bitmap(.swap, appearance: .aqua, emphasized: false, size: size)
        XCTAssertEqual(resize.pixelsWide, 28)
        XCTAssertEqual(resize.pixelsHigh, 18)
        XCTAssertFalse(try samePixels(resize, swap), "resize and swap are the same at 1x")
    }

    func testJoinSubjectSitsOnTheLowerRightTile() throws {
        let size = NSSize(width: 112, height: 72)
        let rep = try bitmap(.join, appearance: .aqua, emphasized: false, size: size)
        let yIncreasesDownward = try bitmapYIncreasesDownward(size: size)
        let accent = try resolved(.controlAccentColor, appearance: .aqua)
        var hits: [(Int, Int)] = []
        for y in 0..<rep.pixelsHigh {
            for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if distance(color, accent) < 0.34 { hits.append((x, y)) }
            }
        }
        XCTAssertGreaterThan(hits.count, 40, "accent pixels \(hits.count)")
        let meanY = CGFloat(hits.map(\.1).reduce(0, +)) / CGFloat(hits.count)
        let fromTop = yIncreasesDownward ? meanY / CGFloat(rep.pixelsHigh) : 1 - meanY / CGFloat(rep.pixelsHigh)
        let lowerTile = 12.4 / 18
        let upperTile = 5.625 / 18
        XCTAssertLessThan(abs(fromTop - lowerTile), 0.15, "subject fraction from top \(fromTop); y increases downward \(yIncreasesDownward)")
        XCTAssertGreaterThan(abs(fromTop - upperTile), 0.2, "subject is in the upper tile, the reversed join diagram")
    }

    /// Whether y = 0 in `colorAt` is the top of the image, found by painting only the top row of an unflipped bitmap red.
    private func bitmapYIncreasesDownward(size: NSSize) throws -> Bool {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: size.height - 4, width: 8, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        func isRed(_ y: Int) -> Bool {
            guard let color = rep.colorAt(x: 2, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2
        }
        let lowYIsRed = isRed(2)
        let highYIsRed = isRed(Int(size.height) - 2)
        XCTAssertNotEqual(lowYIsRed, highYIsRed, "red reference did not identify an edge")
        return lowYIsRed
    }

    func testContrastObserverDoesNotKeepTheViewAlive() {
        weak var released: ActionPictogramView?
        autoreleasepool {
            let view = ActionPictogramView(frame: NSRect(x: 0, y: 0, width: 28, height: 18))
            view.pictogram = .focus
            released = view
        }
        XCTAssertNil(released)
        NotificationCenter.default.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    func testOptInContactSheetWritesLightDarkAndEmphasizedPictograms() throws {
        guard let directory = contactSheetDirectory() else { return }
        for (language, code) in [(Language.english, "en"), (.japanese, "ja")] {
            Copy.language = language
            let sheet = try contactSheet(language: code)
            try write(sheet, to: directory.appendingPathComponent("pictograms-\(code).png"))
        }
        let written = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(written.contains { $0.lastPathComponent == "pictograms-en.png" })
        XCTAssertTrue(written.contains { $0.lastPathComponent == "pictograms-ja.png" })
    }

    private func bitmap(_ pictogram: ActionPictogram, appearance: NSAppearance.Name, emphasized: Bool, contrast: Bool = false, onSelection: Bool = false, size: NSSize = NSSize(width: 56, height: 36)) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            let background = onSelection ? NSColor.controlAccentColor : NSColor(srgbRed: 0.45, green: 0.47, blue: 0.5, alpha: 1)
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            let palette = emphasized ? ActionPictogram.Palette.emphasized : .standard(increaseContrast: contrast)
            ActionPictogramPainter.draw(pictogram, in: NSRect(origin: .zero, size: size), palette: palette)
        }
        return rep
    }

    private func isBlank(_ rep: NSBitmapImageRep) throws -> Bool {
        guard let first = rep.colorAt(x: 0, y: 0) else { return true }
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if distance(color, first) > 0.08 { return false }
            }
        }
        return true
    }

    private func samePixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Bool {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let left = try XCTUnwrap(a.colorAt(x: x, y: y))
                let right = try XCTUnwrap(b.colorAt(x: x, y: y))
                if distance(left, right) > 0.02 { return false }
            }
        }
        return true
    }

    private func resolved(_ color: NSColor, appearance: NSAppearance.Name) throws -> NSColor {
        var resolved = color
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = (color.usingColorSpace(.sRGB) ?? color)
        }
        return resolved
    }

    private func containsDarkPixels(_ rep: NSBitmapImageRep) -> Bool {
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.4 else { continue }
                let luma = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if luma < 0.22 { return true }
            }
        }
        return false
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let left = a.usingColorSpace(.sRGB) ?? a
        let right = b.usingColorSpace(.sRGB) ?? b
        let dr = left.redComponent - right.redComponent
        let dg = left.greenComponent - right.greenComponent
        let db = left.blueComponent - right.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func contactSheetDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["LAZYSPACE_SETTINGS_CONTACT_SHEET"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func contactSheet(language code: String) throws -> NSBitmapImageRep {
        let columns = 6
        let cell = NSSize(width: 168, height: 92)
        let rows = Int(ceil(Double(kinds.count) / Double(columns)))
        let blocks: [(String, NSAppearance.Name, Bool, Bool)] = [
            ("\(code) light", .aqua, false, false),
            ("\(code) light emphasized", .aqua, true, false),
            ("\(code) dark", .darkAqua, false, false),
            ("\(code) dark emphasized", .darkAqua, true, false),
            ("\(code) light contrast", .aqua, false, true),
            ("\(code) dark contrast", .darkAqua, false, true),
        ]
        let width = columns * Int(cell.width)
        let height = blocks.count * (rows * Int(cell.height) + 28)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        for (blockIndex, block) in blocks.enumerated() {
            let originY = CGFloat(height - (blockIndex + 1) * (rows * Int(cell.height) + 28))
            let title = NSAttributedString(string: block.0, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            title.draw(at: NSPoint(x: 8, y: originY + CGFloat(rows * Int(cell.height)) + 6))
            for (index, kind) in kinds.enumerated() {
                let column = index % columns
                let row = index / columns
                let frame = NSRect(
                    x: CGFloat(column) * cell.width + 8,
                    y: originY + CGFloat(rows - row - 1) * cell.height + 8,
                    width: 56,
                    height: 36
                )
                let image = try bitmap(kind, appearance: block.1, emphasized: block.2, contrast: block.3, onSelection: block.2, size: NSSize(width: 56, height: 36))
                image.draw(in: frame)
                let caption = NSAttributedString(string: label(kind), attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
                caption.draw(in: NSRect(x: frame.minX, y: frame.maxY + 2, width: cell.width - 16, height: 28))
            }
        }
        return rep
    }

    private func label(_ kind: ActionPictogram) -> String {
        let name: String
        switch kind {
        case .switchSpace(let n): name = "switchSpace(\(n))"
        case .moveToSpace(let n): name = "moveToSpace(\(n))"
        default: name = String(describing: kind)
        }
        return "\(name)\n\(kind.help)"
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
