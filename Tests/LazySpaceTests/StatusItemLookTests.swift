import AppKit
import Copy
import XCTest
import Settings
@testable import LazySpaceApp

/// What the menu bar item shows: dimmed while paused, a dot while a problem needs the user, and nothing for anything else.
final class StatusItemLookTests: XCTestCase {
    func testOnlyPauseDimsAndOnlyAProblemMarks() {
        XCTAssertEqual(StatusItemLook(paused: false, attention: nil), StatusItemLook(dimmed: false, marked: false, accessibilityValue: nil))
        XCTAssertEqual(StatusItemLook(paused: true, attention: nil),
                       StatusItemLook(dimmed: true, marked: false, accessibilityValue: L(.editCommandsPausedInAllSpaces)))
        let problem = AttentionReason.automaticArrangement(.stageManager)
        XCTAssertEqual(StatusItemLook(paused: false, attention: problem),
                       StatusItemLook(dimmed: false, marked: true, accessibilityValue: NotificationCopy.title(problem)))
        XCTAssertEqual(StatusItemLook(paused: true, attention: .configuration),
                       StatusItemLook(dimmed: true, marked: true, accessibilityValue: NotificationCopy.title(.configuration)),
                       "VoiceOver reads the problem first: it needs action")
        XCTAssertTrue(StatusItemLook(paused: true, attention: nil).image === StatusItemIcon.image)
        XCTAssertTrue(StatusItemLook(paused: false, attention: .configuration).image === StatusItemIcon.markedImage)
    }

    func testTheMarkedIconIsTheSameTemplateWithADotAndAClearedRing() throws {
        XCTAssertTrue(StatusItemIcon.image.isTemplate)
        XCTAssertTrue(StatusItemIcon.markedImage.isTemplate)
        XCTAssertEqual(StatusItemIcon.markedImage.size, StatusItemIcon.image.size)
        let plain = try Self.alpha(StatusItemIcon.image)
        let marked = try Self.alpha(StatusItemIcon.markedImage)
        // Points in icon coordinates (18 × 18, origin at the bottom left).
        XCTAssertLessThan(plain(15.5, 16.5), 0.1, "above the right panel, outside the icon")
        XCTAssertGreaterThan(marked(15.5, 16.5), 0.9, "the dot")
        XCTAssertGreaterThan(plain(12.5, 13), 0.9, "the right panel's top")
        XCTAssertLessThan(marked(12.5, 13), 0.1, "the ring that sets the dot apart")
        for (x, y) in [(4.0, 9.0), (9.0, 9.0), (14.0, 6.0)] {
            XCTAssertEqual(marked(x, y), plain(x, y), accuracy: 0.01, "away from the dot nothing changes (\(x), \(y))")
        }
    }

    /// The problem reaches the icon through the delegate itself, with or without a notifier; pause comes from the coordinator.
    func testTheDelegateFollowsTheProblemAndThePause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                      takeCensus: system.census, takeOverview: { nil })
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        XCTAssertEqual(delegate.statusLook, StatusItemLook(paused: false, attention: nil))

        coordinator.onAttentionChange?(AttentionState(reason: .configuration, notify: false))
        XCTAssertTrue(delegate.statusLook.marked, "no notifier attached, notifications off")
        coordinator.onAttentionChange?(AttentionState(reason: nil, notify: false))
        XCTAssertFalse(delegate.statusLook.marked, "fixed")

        coordinator.setCurrentSpaceAutoPaused(true)
        XCTAssertFalse(delegate.statusLook.dimmed, "a Space's automatic arrangement turned off is not dimmed")
        coordinator.pause()
        XCTAssertTrue(delegate.statusLook.dimmed)
    }

    /// The icon's alpha at a point, read from a 4× rendering.
    private static func alpha(_ image: NSImage) throws -> (CGFloat, CGFloat) -> CGFloat {
        let scale: CGFloat = 4
        let side = Int(image.size.width * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return { x, y in
            let column = Int(x * scale), row = side - 1 - Int(y * scale)
            return rep.colorAt(x: column, y: row)?.alphaComponent ?? 0
        }
    }
}
