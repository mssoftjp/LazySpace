import CoreGraphics
import XCTest
import LayoutCore
@testable import Operations

/// Whole arrangements on the common Mac work areas, with windows that refuse to shrink below their minimum, as apps do on a Mac:
/// LazySpace learns each minimum when a window pushes back, and a row that does not fit side by side overlaps instead of floating a window.
/// `ScreenSizeMatrixTests` (LayoutCoreTests) keeps the same list of work areas.
final class ScreenSizeArrangeTests: XCTestCase {
    /// Work areas in points: the screen below the menu bar (33 points with a camera housing, 24 or 25 without), and without the Dock unless named.
    static let screens: [(name: String, area: CGRect)] = [
        ("13-inch laptop", CGRect(x: 0, y: 33, width: 1470, height: 923)),
        ("13-inch laptop, larger text", CGRect(x: 0, y: 33, width: 1280, height: 799)),
        ("13-inch laptop at more space, 15-inch laptop", CGRect(x: 0, y: 33, width: 1710, height: 1079)),
        ("14-inch laptop", CGRect(x: 0, y: 33, width: 1512, height: 949)),
        ("14-inch laptop, larger text", CGRect(x: 0, y: 33, width: 1352, height: 845)),
        ("14-inch laptop, more space", CGRect(x: 0, y: 33, width: 1800, height: 1136)),
        ("14-inch laptop, Dock at the left", CGRect(x: 70, y: 33, width: 1442, height: 949)),
        ("14-inch laptop, Dock below", CGRect(x: 0, y: 33, width: 1512, height: 879)),
        ("15-inch laptop, larger text", CGRect(x: 0, y: 33, width: 1440, height: 899)),
        ("16-inch laptop", CGRect(x: 0, y: 33, width: 1728, height: 1084)),
        ("16-inch laptop, larger text", CGRect(x: 0, y: 33, width: 1496, height: 934)),
        ("16-inch laptop, more space", CGRect(x: 0, y: 33, width: 2056, height: 1296)),
        ("13-inch laptop without a camera housing", CGRect(x: 0, y: 24, width: 1440, height: 876)),
        ("13-inch laptop without a camera housing, larger text", CGRect(x: 0, y: 24, width: 1280, height: 776)),
        ("full HD display", CGRect(x: 0, y: 30, width: 1920, height: 1050)),
        ("QHD display", CGRect(x: 0, y: 25, width: 2560, height: 1415)),
        ("24-inch all-in-one", CGRect(x: 0, y: 25, width: 2240, height: 1235)),
        ("6K display", CGRect(x: 0, y: 25, width: 3008, height: 1667)),
        ("full HD display in portrait", CGRect(x: 0, y: 30, width: 1080, height: 1890)),
        ("QHD display in portrait", CGRect(x: 0, y: 25, width: 1440, height: 2535)),
        ("tablet as a display", CGRect(x: 0, y: 24, width: 1366, height: 1000)),
        ("full HD display left of the main one", CGRect(x: -1920, y: 25, width: 1920, height: 1055)),
    ]

    struct App {
        let name: String
        let minimum: CGSize
        var fixedWidth = false
    }

    static let editor = App(name: "editor 840", minimum: CGSize(width: 840, height: 500))
    static let photos = App(name: "photos 800", minimum: CGSize(width: 800, height: 500))
    static let store = App(name: "store 1000", minimum: CGSize(width: 1000, height: 600))
    static let settings = App(name: "settings fixed 740", minimum: CGSize(width: 740, height: 500), fixedWidth: true)
    static let wide = App(name: "wide 1280", minimum: CGSize(width: 1280, height: 700))
    static let plain600 = App(name: "600", minimum: CGSize(width: 600, height: 400))
    static let plain400 = App(name: "400", minimum: CGSize(width: 400, height: 300))
    static let plain300 = App(name: "300", minimum: CGSize(width: 300, height: 200))
    /// Taller than the work area of a laptop with larger text.
    static let tall = App(name: "tall 900", minimum: CGSize(width: 400, height: 900))

    /// Windows in the order they were opened.
    static let sets: [[App]] = [
        [editor], [store], [wide],
        [editor, settings], [editor, photos], [editor, store], [photos, store], [store, store], [plain600, plain600], [plain400, wide],
        [editor, photos, settings], [editor, settings, store], [plain400, editor, store], [wide, plain300, wide], [plain600, plain600, plain600],
        [editor, photos, settings, store], [plain600, plain600, plain600, plain600], [plain400, plain400, plain400, plain400],
        [plain300, plain300, plain300, plain300, plain300],
        [tall], [editor, tall], [tall, plain300, plain300],
    ]

    /// The windows in the order they were opened, each a little lower and to the right of the last, at least 500 by 400 points or their minimum.
    static func system(_ apps: [App], in area: CGRect) -> FakeSystem {
        let windows = apps.indices.map { window(UInt32($0 + 1), app: "app.\($0)", x: area.minX + CGFloat($0) * 40) }
        let s = FakeSystem(windows: windows, area: area)
        for (index, app) in apps.enumerated() {
            let id = WindowID(UInt32(index + 1))
            s.frames[id] = CGRect(x: area.minX + CGFloat(index) * 40, y: area.minY + CGFloat(index) * 30, width: max(500, app.minimum.width), height: max(400, app.minimum.height))
            s.minimums[id] = app.minimum
            if app.fixedWidth { s.maximums[id] = CGSize(width: app.minimum.width, height: 100_000) }
        }
        return s
    }

    /// Whether one row, folded where it must be, holds the apps: each fits in its part of a fold, the whole width alone, else the width minus two strips.
    static func oneRowHolds(_ apps: [App], in area: CGRect) -> Bool {
        let strip = PlannerOptions().accordionPadding.rounded()
        return apps.allSatisfy { $0.minimum.width <= area.width - (apps.count == 1 ? 0 : 2 * strip) && $0.minimum.height <= area.height }
    }

    static func floated(_ result: OperationResult) -> Set<WindowID> {
        Set(result.excluded.filter { $0.code == .overflowFloat }.map(\.window.id))
    }

    static func folds(_ node: LayoutNode?) -> Bool {
        guard let box = node?.box else { return false }
        return box.accordion || box.children.contains { folds($0) }
    }

    func testArrangementsOnEveryScreen() {
        var failures: [String] = []
        for screen in Self.screens {
            for apps in Self.sets {
                let label = "\(screen.name): \(apps.map(\.name).joined(separator: " + "))"
                let area = screen.area
                let s = Self.system(apps, in: area)
                let knowledge = ConstraintKnowledge()
                let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0), sleep: { _ in })
                let r = op.run()
                let floated = Self.floated(r)
                if Self.oneRowHolds(apps, in: area) {
                    if r.outcome != .complete { failures.append("\(label): \(r.outcome) — \(r.message)") }
                    if !floated.isEmpty { failures.append("\(label): floated \(floated.sorted()) although one overlapping row holds every window") }
                }
                // A window up to a point larger than the area matches its request within the tolerance, so it is not taken as larger.
                for (index, app) in apps.enumerated() where app.minimum.width > area.width + 1 || app.minimum.height > area.height + 1 {
                    if !floated.contains(WindowID(UInt32(index + 1))) { failures.append("\(label): window \(index + 1) is larger than the area but did not float") }
                }
                // A window floats only when it is needed: with the windows that stayed, one overlapping row would not hold it.
                let stayed = apps.indices.filter { !floated.contains(WindowID(UInt32($0 + 1))) }
                for id in floated {
                    if Self.oneRowHolds((stayed + [Int(id.raw) - 1]).map { apps[$0] }, in: area) { failures.append("\(label): window \(id.raw) floated although one overlapping row holds it with the windows that stayed") }
                }
                // FakeSystem keeps every window at its minimum or above, as apps do, so the frames are checked only against the area.
                for index in apps.indices {
                    let id = WindowID(UInt32(index + 1))
                    guard !floated.contains(id), let frame = s.frames[id] else { continue }
                    if !area.insetBy(dx: -1, dy: -1).contains(frame) { failures.append("\(label): window \(index + 1) \(frame) leaves the area") }
                    if op.resultingLayout?.windowIDs.contains(id) != true { failures.append("\(label): window \(index + 1) is not in the layout") }
                }
                guard r.outcome == .complete else { continue }
                s.writes.removeAll()
                let again = ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                             priorLayout: op.resultingLayout, sleep: { _ in })
                let second = again.run()
                if second.outcome != .complete { failures.append("\(label): the second arrangement is \(second.outcome) — \(second.message)") }
                if !s.writes.isEmpty {
                    let written = s.writes.map { "window \($0.0.raw) to \($0.1)" }.joined(separator: ", ")
                    failures.append("\(label): the second arrangement wrote \(written) (first arrangement left \(apps.indices.map { s.frames[WindowID(UInt32($0 + 1))].map { "\($0)" } ?? "-" }); floated \(floated.sorted()); second excluded \(second.excluded.map { "\($0.window.id.raw) \($0.code.map { "\($0)" } ?? $0.reason)" }))")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    /// A dialog strip beside the tiles stays only while the tiles fit beside it without overlapping; otherwise it gives way.
    /// Minimums learned while writing can drop it halfway, which takes passes of its own; the next arrangement then completes.
    func testADialogStripNeverMakesTheTilesFold() {
        var failures: [String] = []
        var partial: [String] = []
        for screen in Self.screens {
            for apps in Self.sets {
                let label = "\(screen.name) with a dialog strip: \(apps.map(\.name).joined(separator: " + "))"
                let s = Self.system(apps, in: screen.area)
                let knowledge = ConstraintKnowledge()
                var (r, op) = Self.arrangeBesideAStrip(s, knowledge: knowledge)
                if r.outcome != .complete {
                    partial.append(label)
                    (r, op) = Self.arrangeBesideAStrip(s, knowledge: knowledge)
                }
                if r.outcome != .complete { failures.append("\(label): \(r.outcome) twice — \(r.message)") }
                Self.checkStrip(op, result: r, system: s, area: screen.area, label: label, failures: &failures)
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
        XCTAssertEqual(partial, Self.partialBesideAStrip, "first arrangements left partial")
    }

    /// First arrangements that end partial because their limits come to light in more passes than one arrangement confirms:
    /// beside the strip, the minimums learned while writing drop it, and the fixed window then needs a pass of its own.
    static let partialBesideAStrip = [
        "QHD display with a dialog strip: editor 840 + photos 800 + settings fixed 740",
    ]

    /// As above, beside the strip.
    static let partialOneAtATime = [
        "QHD display with a dialog strip, opened one at a time: editor 840 + photos 800 + settings fixed 740, window 3",
        "QHD display with a dialog strip, opened one at a time: editor 840 + photos 800 + settings fixed 740 + store 1000, window 3",
    ]

    static let stripWidth = 340.0

    static func arrangeBesideAStrip(_ s: FakeSystem, knowledge: ConstraintKnowledge, prior: Layout? = nil, heldOut: [WindowID: String] = [:],
                                    adding: Set<WindowID> = [], kind: String = "arrange") -> (OperationResult, ArrangeOperation) {
        var options = PlannerOptions()
        options.reservedRight = stripWidth
        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0), options: options,
                                  priorLayout: prior, heldOut: heldOut, adding: adding, kind: kind, sleep: { _ in })
        op.regionFallback = PlannerOptions()
        return (op.run(), op)
    }

    /// While the strip stays, the tiles beside it neither fold, nor float, nor reach into it.
    static func checkStrip(_ op: ArrangeOperation, result: OperationResult, system s: FakeSystem, area: CGRect, label: String, failures: inout [String]) {
        guard !op.regionDropped else { return }
        if folds(op.resultingShape?.root) { failures.append("\(label): the tiles fold beside the strip") }
        if !floated(result).isEmpty { failures.append("\(label): floated \(floated(result).sorted()) beside the strip") }
        for (id, frame) in s.frames where op.resultingLayout?.windowIDs.contains(id) == true && frame.maxX > area.maxX - stripWidth + 1 {
            failures.append("\(label): window \(id.raw) \(frame) reaches into the strip")
        }
    }

    /// Windows opened one at a time join the layout as they come. A window that joins and does not fit floats itself, never a window
    /// already arranged. Minimums can come to light in more passes than one arrangement confirms; the next one, which LazySpace starts
    /// when the Space is quiet again, then completes. Once every window is open, arranging again writes nothing.
    func testWindowsOpenedOneAtATime() {
        var failures: [String] = []
        var partial: [String] = []
        for (screen, strip) in Self.screens.flatMap({ screen in [(screen, false), (screen, true)] }) {
            for apps in Self.sets where apps.count > 1 {
                let label = "\(screen.name)\(strip ? " with a dialog strip" : ""), opened one at a time: \(apps.map(\.name).joined(separator: " + "))"
                let area = screen.area
                let s = Self.system(apps, in: area)
                let knowledge = ConstraintKnowledge()
                var layout: Layout?
                var floating: Set<WindowID> = []
                // A strip that gave way is not reserved again by later arrangements, as when it is cleared with the committed layout.
                var stripKept = strip
                for index in apps.indices {
                    let id = WindowID(UInt32(index + 1))
                    var held = Dictionary(uniqueKeysWithValues: floating.map { ($0, "floating") })
                    for later in apps.indices.dropFirst(index + 1) { held[WindowID(UInt32(later + 1))] = "not open yet" }
                    func integrate() -> (OperationResult, ArrangeOperation) {
                        if stripKept { return Self.arrangeBesideAStrip(s, knowledge: knowledge, prior: layout, heldOut: held, adding: [id], kind: "auto-integrate") }
                        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                                  priorLayout: layout, heldOut: held, adding: [id], kind: "auto-integrate", sleep: { _ in })
                        return (op.run(), op)
                    }
                    var (r, op) = integrate()
                    if r.outcome != .complete {
                        partial.append("\(label), window \(index + 1)")
                        (r, op) = integrate()
                    }
                    if r.outcome != .complete { failures.append("\(label): window \(index + 1) joins \(r.outcome) twice — \(r.message)"); break }
                    let floated = Self.floated(r)
                    if !floated.isSubset(of: [id]) { failures.append("\(label): window \(index + 1) joined and \(floated.subtracting([id]).sorted()) floated") }
                    if stripKept { Self.checkStrip(op, result: r, system: s, area: area, label: "\(label), window \(index + 1)", failures: &failures) }
                    if op.regionDropped { stripKept = false }
                    floating.formUnion(floated)
                    layout = op.resultingLayout
                    for (wid, frame) in s.frames where layout?.windowIDs.contains(wid) == true && !area.insetBy(dx: -1, dy: -1).contains(frame) {
                        failures.append("\(label): after window \(index + 1) joined, window \(wid.raw) \(frame) leaves the area")
                    }
                }
                s.writes.removeAll()
                let floatingHeld = Dictionary(uniqueKeysWithValues: floating.map { ($0, "floating") })
                let again = stripKept ? Self.arrangeBesideAStrip(s, knowledge: knowledge, prior: layout, heldOut: floatingHeld).0
                    : ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                       priorLayout: layout, heldOut: floatingHeld, sleep: { _ in }).run()
                if again.outcome != .complete || !s.writes.isEmpty { failures.append("\(label): arranging again is \(again.outcome) and wrote \(s.writes.count) frames") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(40).joined(separator: "\n"))
        XCTAssertEqual(partial, Self.partialOneAtATime, "first arrangements left partial")
    }

    /// The arrangement on another work area and back on the first, `trips` times; nil when it does not complete without floating a window.
    static func roundTrips(_ apps: [App], from a: CGRect, trips: Int, other: (FakeSystem, ConstraintKnowledge, Layout?) -> (OperationResult, ArrangeOperation),
                           back: (FakeSystem, ConstraintKnowledge, Layout?) -> (OperationResult, ArrangeOperation)) -> (before: [WindowID: CGRect], after: [[WindowID: CGRect]])? {
        let s = system(apps, in: a)
        let knowledge = ConstraintKnowledge()
        var (r, op) = back(s, knowledge, nil)
        guard r.outcome == .complete, floated(r).isEmpty else { return nil }
        let before = s.frames
        var after: [[WindowID: CGRect]] = []
        for _ in 1...trips {
            (r, op) = other(s, knowledge, op.resultingLayout)
            guard r.outcome == .complete, floated(r).isEmpty else { return nil }
            (r, op) = back(s, knowledge, op.resultingLayout)
            guard r.outcome == .complete else { return nil }
            after.append(s.frames)
        }
        return (before, after)
    }

    static func arrange(_ s: FakeSystem, _ knowledge: ConstraintKnowledge, _ prior: Layout?, in area: CGRect) -> (OperationResult, ArrangeOperation) {
        // macOS keeps a window's place relative to its display.
        let dx = area.minX - s.snap.workArea.minX, dy = area.minY - s.snap.workArea.minY
        for (id, frame) in s.frames { s.frames[id] = frame.offsetBy(dx: dx, dy: dy) }
        s.snap.workArea = area
        let op = ArrangeOperation(system: s, control: OperationControl(), knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        return (op.run(), op)
    }

    /// Another display and back, three times, with each screen and the next in the list and with a full HD display: the tiles before the
    /// change come back, also where a window is held at its minimum on the other display. A fixed-width window is left out: its width is a cap,
    /// and a split shaped by a cap takes the ratios of its tiles, which can lean by a point each time.
    func testTilesComeBackAfterADisplayChangeAndBack() {
        let fullHD = Self.screens.first { $0.name == "full HD display" }!
        var failures: [String] = []
        var compared = 0
        for (index, a) in Self.screens.enumerated() {
            for b in [Self.screens[(index + 1) % Self.screens.count], fullHD] where b.name != a.name {
                for apps in Self.sets where apps.count > 1 && !apps.contains(where: \.fixedWidth) {
                    guard let trips = Self.roundTrips(apps, from: a.area, trips: 3,
                                                      other: { Self.arrange($0, $1, $2, in: b.area) }, back: { Self.arrange($0, $1, $2, in: a.area) }) else { continue }
                    compared += 1
                    if let trip = trips.after.firstIndex(where: { $0 != trips.before }) {
                        failures.append("\(a.name) and \(b.name): \(apps.map(\.name).joined(separator: " + ")), trip \(trip + 1): \(trips.before.keys.sorted { $0.raw < $1.raw }.map { "\(trips.before[$0]!) now \(trips.after[trip][$0]!)" })")
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 400)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// A dialog strip reserved and released three times: the tiles before it come back, also where a window is held at its minimum beside it.
    /// A fixed-width window is left out, as for a display change.
    func testTilesComeBackAfterADialogStripComesAndGoes() {
        var failures: [String] = []
        var compared = 0
        for screen in Self.screens {
            for apps in Self.sets where apps.count > 1 && !apps.contains(where: \.fixedWidth) {
                guard let trips = Self.roundTrips(apps, from: screen.area, trips: 3,
                                                  other: { s, knowledge, prior in Self.arrangeBesideAStrip(s, knowledge: knowledge, prior: prior) },
                                                  back: { Self.arrange($0, $1, $2, in: screen.area) }) else { continue }
                compared += 1
                if let trip = trips.after.firstIndex(where: { $0 != trips.before }) {
                    failures.append("\(screen.name): \(apps.map(\.name).joined(separator: " + ")), cycle \(trip + 1): \(trips.before.keys.sorted { $0.raw < $1.raw }.map { "\(trips.before[$0]!) now \(trips.after[trip][$0]!)" })")
                }
            }
        }
        XCTAssertGreaterThan(compared, 200)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// Both lists of work areas are the same, so the planner and the arrangement are checked on the same screens.
    func testTheListMatchesThePlannerTests() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LayoutCoreTests/ScreenSizeMatrixTests.swift"), encoding: .utf8)
        for screen in Self.screens {
            let rect = "CGRect(x: \(Int(screen.area.minX)), y: \(Int(screen.area.minY)), width: \(Int(screen.area.width)), height: \(Int(screen.area.height)))"
            XCTAssertTrue(source.contains("Screen(name: \"\(screen.name)\", area: \(rect))"), screen.name)
        }
        XCTAssertEqual(source.components(separatedBy: "Screen(name: \"").count - 1, Self.screens.count)
    }
}
