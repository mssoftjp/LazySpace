import Copy
import CoreGraphics
import XCTest
import LayoutCore
@testable import Operations

final class ArrangeOperationTests: XCTestCase {
    var control: OperationControl!
    var knowledge: ConstraintKnowledge!

    override func setUp() {
        control = OperationControl()
        knowledge = ConstraintKnowledge()
    }

    func makeOp(_ system: FakeSystem, limits: OperationLimits = OperationLimits(settleDelay: 0)) -> ArrangeOperation {
        ArrangeOperation(system: system, control: control, knowledge: knowledge, limits: limits, sleep: { _ in })
    }

    func testWindowTitleIsNotWrittenIntoLogs() throws {
        var window = ObservedWindow(id: WindowID(1), pid: 1, app: "com.example", frame: CGRect(x: 0, y: 0, width: 10, height: 10), membership: .current, kind: .standard, detail: "role", title: "秘密のタイトル")
        window.title = "秘密のタイトル"
        let data = try JSONEncoder().encode(window)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("秘密"))
        let back = try JSONDecoder().decode(ObservedWindow.self, from: data)
        XCTAssertEqual(back.title, "")
        let ruled = TargetSelection.inspect(
            Snapshot(trusted: true, spaceID: 1, workArea: CGRect(x: 0, y: 0, width: 100, height: 100), windows: [window], spaceObservationAvailable: true),
            appRule: { $0.title.contains("秘密") ? "タイトルで浮動" : nil }
        )
        XCTAssertEqual(ruled.targets.count, 0)
        XCTAssertEqual(ruled.excluded.first?.reason, "タイトルで浮動")
    }

    func testAgedMaximumIsKeptWhenTheCurrentFrameStillFits() {
        var now = Date()
        knowledge = ConstraintKnowledge(ttl: 60, now: { now })
        let s = FakeSystem(windows: [window(1, app: "calc", x: 0), window(2, app: "b", x: 900)])
        let requested = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let capped = CGRect(x: 0, y: 30, width: 230, height: 408)
        knowledge.recordPullback(id: WindowID(1), requested: requested, actual: capped, spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
        XCTAssertEqual(knowledge.maximums(for: [WindowID(1)], workArea: s.snap.workArea)[WindowID(1)], CGSize(width: 230, height: 408))
        s.frames[WindowID(1)] = capped
        s.frames[WindowID(2)] = CGRect(x: 230, y: 30, width: 1690, height: 1050)
        let prior = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(1) && $0.1.width > 230 })
        XCTAssertEqual(s.frames[WindowID(1)]?.size, CGSize(width: 230, height: 408))
        now = now.addingTimeInterval(61)
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: s.snap.workArea)[WindowID(1)], "an expired maximum is not used even if the current frame fits")
    }

    func testUnfitMessageUsesTheProvidedAppName() {
        let s = FakeSystem(windows: [window(1, app: "com.example.big", x: 0), window(2, app: "com.example.other", x: 10)],
                           area: CGRect(x: 0, y: 0, width: 50, height: 50))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                  displayName: { $0 == "com.example.big" ? "大きいアプリ" : $0 }, sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertTrue(result.message.contains("大きいアプリ"), result.message)
        XCTAssertFalse(result.message.contains("com.example.big"), result.message)
    }

    func testObservedLargerSizeDisprovesMaximumBeforePlanning() {
        let s = FakeSystem(windows: [window(1), window(2)])
        knowledge.recordPullback(id: WindowID(1), requested: s.snap.workArea,
            actual: CGRect(x: 0, y: 30, width: 698, height: 745),
            spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
        s.frames[WindowID(1)] = s.snap.workArea
        XCTAssertEqual(makeOp(s).run().outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)]?.size, CGSize(width: 960, height: 1050))
    }

    func testTransientPullbackRetriesIntendedTile() {
        let s = FakeSystem(windows: [window(1), window(2)])
        s.onWrite = { sys, count in
            if count == 1 { sys.frames[WindowID(1)] = CGRect(x: 0, y: 30, width: 698, height: 745) }
        }
        XCTAssertEqual(makeOp(s).run().outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)]?.size, CGSize(width: 960, height: 1050))
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: s.snap.workArea)[WindowID(1)])
    }

    func testScreenEdgeClippingBeforePositionSettlesDoesNotTeachMaximum() {
        let s = FakeSystem(windows: [window(1), window(2)])
        s.onWrite = { sys, _ in
            sys.frames[WindowID(1)] = CGRect(x: 152, y: 73, width: 960, height: 1007)
        }
        XCTAssertEqual(makeOp(s).run().outcome, .partial)
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: s.snap.workArea)[WindowID(1)])
    }

    func testUndoRestoresSavedRatiosInsteadOfAdoptingCurrentFrames() {
        let s = FakeSystem(windows: [window(1), window(2)])
        s.frames[WindowID(1)] = CGRect(x: 0, y: 30, width: 768, height: 1050)
        s.frames[WindowID(2)] = CGRect(x: 768, y: 30, width: 1152, height: 1050)
        let saved = Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
            limits: OperationLimits(settleDelay: 0), priorLayout: saved, adoptObservedProportions: false,
                                  kind: "edit:undo", sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 960)
        XCTAssertEqual(result.issued, 2)
    }

    func testRetainedLayoutStillAdoptsObservedGrowth() {
        let s = FakeSystem(windows: [window(1), window(2)])
        s.frames[WindowID(1)] = CGRect(x: 0, y: 30, width: 768, height: 1050)
        s.frames[WindowID(2)] = CGRect(x: 768, y: 30, width: 1152, height: 1050)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0),
                                  priorLayout: Planner.rowLayout([WindowID(1), WindowID(2)], rows: 1), sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.issued, 0)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 768)
    }

    func testTwoWindowsComplete() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .complete)
        XCTAssertEqual(r.issued, 2)
        XCTAssertTrue(r.verified)
        XCTAssertEqual(r.targets.map(\.status), [.verified, .verified])
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 30, width: 960, height: 1050))
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 960, y: 30, width: 960, height: 1050))
        XCTAssertEqual(r.excluded.count, 0)
    }

    func testMinimumPushbackIsLearnedAndReplannedOnce() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.minimums[WindowID(2)] = CGSize(width: 1200, height: 300)
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(r.retries, 1)
        XCTAssertEqual(s.writes.filter { $0.0 == WindowID(2) }.map(\.1.width), [960, 960, 1200], "the same request comes back larger twice before the minimum is learned")
        XCTAssertEqual(s.frames[WindowID(2)]!.width, 1200)
        XCTAssertEqual(s.frames[WindowID(1)]!.width, 720)
        XCTAssertEqual(s.frames[WindowID(1)]!.maxX, s.frames[WindowID(2)]!.minX)
        // Constraints inferred from measurements stay scoped to this window, Space, and work area.
        XCTAssertEqual(knowledge.constraints(for: [WindowID(2)], spaceID: 7, workArea: s.snap.workArea)[WindowID(2)], .estimated(CGSize(width: 1200, height: 0)))
        XCTAssertEqual(knowledge.constraints(for: [WindowID(2)], spaceID: 8, workArea: s.snap.workArea)[WindowID(2)], .estimated(CGSize(width: 1200, height: 0)))
    }

    func testFixedSizeWindowIsPositionedWithoutFillingItsCell() {
        let s = FakeSystem(windows: [window(1, app: "calc", x: 0), window(2, app: "b", x: 900)])
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        let op = makeOp(s)
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 30, width: 230, height: 408))
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 230, y: 30, width: 1690, height: 1050))
        XCTAssertTrue([.maximumSizeCap, .maximumSizeConfirmed].contains(r.targets[0].noteKind), "\(String(describing: r.targets[0].noteKind))")
        XCTAssertTrue(r.targets[0].note?.contains("Maximum size") == true)
        guard case .split(.horizontal, _, let ratios)? = op.resultingLayout?.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 230.0 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 1690.0 / 1920.0, accuracy: 1e-9)
    }

    func testSavedPackedRatiosKeepThePackWhenMaximumsAreForgotten() {
        let s = FakeSystem(windows: [window(1, app: "calc", x: 0), window(2, app: "b", x: 900)])
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        let first = makeOp(s)
        XCTAssertEqual(first.run().outcome, .complete)
        let packed = first.resultingLayout
        XCTAssertNotNil(packed)
        knowledge = ConstraintKnowledge()
        s.fixed = [:]
        s.writes = []
        let second = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: packed, sleep: { _ in })
        let r2 = second.run()
        XCTAssertEqual(r2.outcome, .complete, r2.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 230)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 1690)
    }

    func testEndInsertKeepsPackedWidthWhenTheLargeChildHasAMinimum() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [
            window(1, app: "a", x: 0),
            window(2, app: "b", x: 230),
            window(3, app: "c", x: 80),
        ], area: area)
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 440)
        s.minimums[WindowID(2)] = CGSize(width: 700, height: 400)
        s.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 230, height: 440)
        s.frames[WindowID(2)] = CGRect(x: 230, y: 33, width: 1282, height: 949)
        s.frames[WindowID(3)] = CGRect(x: 80, y: 470, width: 520, height: 392)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 756, height: 949),
            actual: CGRect(x: 0, y: 33, width: 230, height: 440),
            spaceID: 7, workArea: area, tolerance: 1)
        let prior = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)), .leaf(WindowID(2)),
        ], ratios: [230.0 / 1512.0, 1282.0 / 1512.0]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 33, width: 230, height: 440))
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 230, y: 33, width: 806, height: 949))
        XCTAssertEqual(s.frames[WindowID(3)], CGRect(x: 1036, y: 33, width: 476, height: 949))
        guard case .split(.horizontal, _, let ratios)? = op.resultingLayout?.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 230.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 806.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[2], 476.0 / 1512.0, accuracy: 1e-9)
    }

    func testEndInsertStacksUnderAShortWideLeaf() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [
            window(1, app: "a", x: 0),
            window(2, app: "b", x: 700),
            window(3, app: "c", x: 80),
        ], area: area)
        s.fixed[WindowID(1)] = CGSize(width: 700, height: 440)
        s.minimums[WindowID(2)] = CGSize(width: 400, height: 300)
        s.minimums[WindowID(3)] = CGSize(width: 400, height: 300)
        s.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 700, height: 440)
        s.frames[WindowID(2)] = CGRect(x: 700, y: 33, width: 812, height: 949)
        s.frames[WindowID(3)] = CGRect(x: 80, y: 470, width: 400, height: 300)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 756, height: 949),
            actual: CGRect(x: 0, y: 33, width: 700, height: 440),
            spaceID: 7, workArea: area, tolerance: 1)
        let prior = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)), .leaf(WindowID(2)),
        ], ratios: [700.0 / 1512.0, 812.0 / 1512.0]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 700)
        XCTAssertEqual(s.frames[WindowID(1)]?.height, 440)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 812)
        XCTAssertEqual(s.frames[WindowID(2)]?.minX, 700)
        XCTAssertEqual(s.frames[WindowID(2)]?.height, 949)
        XCTAssertEqual(s.frames[WindowID(3)]?.width, 700)
        XCTAssertEqual(s.frames[WindowID(3)]?.minX, 0)
        XCTAssertEqual(s.frames[WindowID(3)]!.minY, 473, accuracy: 1)
        guard case .split(.horizontal, let children, let ratios)? = op.resultingLayout?.root else { return XCTFail() }
        XCTAssertEqual(ratios[0], 700.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 812.0 / 1512.0, accuracy: 1e-9)
        guard case .split(.vertical, _, _) = children[0] else { return XCTFail("C stacks below the short leaf") }
    }

    func testRefitAfterStackedWindowKeepsTheShortWideLeaf() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [
            window(1, app: "a", x: 0),
            window(2, app: "b", x: 700),
            window(3, app: "c", x: 80),
        ], area: area)
        s.fixed[WindowID(1)] = CGSize(width: 700, height: 440)
        s.minimums[WindowID(2)] = CGSize(width: 400, height: 300)
        s.minimums[WindowID(3)] = CGSize(width: 400, height: 300)
        s.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 700, height: 440)
        s.frames[WindowID(2)] = CGRect(x: 700, y: 33, width: 812, height: 949)
        s.frames[WindowID(3)] = CGRect(x: 80, y: 470, width: 400, height: 300)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 756, height: 949),
            actual: CGRect(x: 0, y: 33, width: 700, height: 440),
            spaceID: 7, workArea: area, tolerance: 1)
        let prior = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)), .leaf(WindowID(2)),
        ], ratios: [700.0 / 1512.0, 812.0 / 1512.0]))
        let first = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        XCTAssertEqual(first.run().outcome, .complete)
        XCTAssertEqual(knowledge.maximums(for: [WindowID(1)], workArea: area)[WindowID(1)]?.height, 440)
        s.gone.insert(WindowID(3))
        s.frames[WindowID(3)] = nil
        let second = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: first.resultingLayout, sleep: { _ in })
        let result = second.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 700)
        XCTAssertEqual(s.frames[WindowID(1)]?.height, 440)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 812)
        XCTAssertEqual(s.frames[WindowID(2)]?.minX, 700)
        XCTAssertEqual(s.frames[WindowID(2)]?.height, 949)
        guard case .split(.horizontal, let children, let ratios)? = second.resultingLayout?.root else { return XCTFail() }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(ratios[0], 700.0 / 1512.0, accuracy: 1e-9)
        XCTAssertEqual(ratios[1], 812.0 / 1512.0, accuracy: 1e-9)
        guard case .leaf(WindowID(1)) = children[0] else { return XCTFail("closing the stacked window collapses the vertical split") }
        XCTAssertEqual(second.resultingLayout?.leftoverHeights[WindowID(1)], 440)
    }

    func testRefitAfterStackedWindowKeepsHeightWithoutFacts() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [
            window(1, app: "a", x: 0),
            window(2, app: "b", x: 700),
            window(3, app: "c", x: 80),
        ], area: area)
        s.fixed[WindowID(1)] = CGSize(width: 700, height: 440)
        s.minimums[WindowID(2)] = CGSize(width: 400, height: 300)
        s.minimums[WindowID(3)] = CGSize(width: 400, height: 300)
        s.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 700, height: 440)
        s.frames[WindowID(2)] = CGRect(x: 700, y: 33, width: 812, height: 949)
        s.frames[WindowID(3)] = CGRect(x: 80, y: 470, width: 400, height: 300)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 756, height: 949),
            actual: CGRect(x: 0, y: 33, width: 700, height: 440),
            spaceID: 7, workArea: area, tolerance: 1)
        let prior = Layout(root: .split(.horizontal, children: [
            .leaf(WindowID(1)), .leaf(WindowID(2)),
        ], ratios: [700.0 / 1512.0, 812.0 / 1512.0]))
        let first = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        XCTAssertEqual(first.run().outcome, .complete)
        XCTAssertEqual(first.resultingLayout?.leftoverHeights[WindowID(1)], 440)
        knowledge = ConstraintKnowledge()
        s.fixed = [:]
        s.gone.insert(WindowID(3))
        s.frames[WindowID(3)] = nil
        let second = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: first.resultingLayout, sleep: { _ in })
        let result = second.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 700)
        XCTAssertEqual(s.frames[WindowID(1)]?.height, 440)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 812)
        XCTAssertEqual(s.frames[WindowID(2)]?.height, 949)
        XCTAssertEqual(second.resultingLayout?.leftoverHeights[WindowID(1)], 440)
    }

    func testMaximumDoesNotApplyOnAnotherWorkArea() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        knowledge.recordPullback(
            id: WindowID(1),
            requested: CGRect(x: 0, y: 33, width: 756, height: 949),
            actual: CGRect(x: 0, y: 33, width: 700, height: 440),
            spaceID: 7, workArea: area, tolerance: 1)
        XCTAssertEqual(knowledge.maximums(for: [WindowID(1)], workArea: area)[WindowID(1)]?.height, 440)
        let grown = CGRect(x: 0, y: 33, width: 1512, height: 980)
        XCTAssertNil(knowledge.maximums(for: [WindowID(1)], workArea: grown)[WindowID(1)])
    }

    func testGrownWindowRebasesPackedRatiosBeforePlanning() {
        let s = FakeSystem(windows: [window(1, app: "calc", x: 0), window(2, app: "b", x: 900)])
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        let first = makeOp(s)
        XCTAssertEqual(first.run().outcome, .complete)
        knowledge = ConstraintKnowledge()
        s.fixed = [:]
        s.frames[WindowID(1)] = CGRect(x: 0, y: 30, width: 960, height: 1050)
        s.frames[WindowID(2)] = CGRect(x: 960, y: 30, width: 960, height: 1050)
        let second = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: first.resultingLayout, sleep: { _ in })
        let r2 = second.run()
        XCTAssertEqual(r2.outcome, .complete, r2.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 960)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 960)
    }

    func testMixedConstraintsPackOnNarrowScreen() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [window(1, app: "calc"), window(2, app: "editor"), window(3, app: "browser")], area: area)
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 408)
        s.minimums[WindowID(2)] = CGSize(width: 700, height: 400)
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 33, width: 230, height: 408))
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 700)
        XCTAssertEqual(s.frames[WindowID(3)]?.width, 582)
        XCTAssertEqual(s.frames[WindowID(2)]?.minX, 230)
        XCTAssertEqual(s.frames[WindowID(3)]?.minX, 930)
        XCTAssertEqual(s.frames[WindowID(2)]?.height, 949)
        XCTAssertEqual(s.frames[WindowID(3)]?.height, 949)
        let frames = [WindowID(1), WindowID(2), WindowID(3)].compactMap { s.frames[$0] }
        for frame in frames { XCTAssertTrue(area.contains(frame), "\(frame) is outside the work area") }
        XCTAssertEqual(frames[0].maxX, frames[1].minX)
        XCTAssertEqual(frames[1].maxX, frames[2].minX)
    }

    func testFixedHeightConfirmedWhenMinimumWidthReplans() {
        let s = FakeSystem(windows: [window(1), window(2)])
        s.fixed[WindowID(1)] = CGSize(width: 1100, height: 408)
        let result = makeOp(s).run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 30, width: 1100, height: 408))
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 820)
    }

    func testSameRejectedRequestIsNotRepeatedForever() {
        // Pushed back but nothing learned (only the position is off): no retry.
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.onWrite = { sys, _ in
            // An app that shifts the position by 10 pt on its own
            for (k, v) in sys.frames { sys.frames[k] = v.offsetBy(dx: 10, dy: 0) }
        }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .partial)
        XCTAssertEqual(r.retries, 0)
        XCTAssertEqual(r.issued, 2)
    }

    func testPauseDuringIssueStopsFurtherWrites() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900), window(3, app: "c", x: 1500)])
        s.onWrite = { [control] _, n in if n == 1 { control!.paused = true } }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.stopReason, .paused)
        XCTAssertEqual(r.issued, 1)
        // The one window already sent is read back and confirmed by the stop handling; the rest are unapplied.
        XCTAssertEqual(r.targets.map(\.status), [.verified, .unapplied, .unapplied])
        XCTAssertTrue(r.verified)
        XCTAssertEqual(s.writes.count, 1)
        XCTAssertTrue(r.message.contains("paused"), r.message)
    }

    func testPauseDuringFrameReadPreventsWrite() {
        let s = FakeSystem(windows: [window(1, app: "a")])
        s.onRead = { [control] _, _ in control!.paused = true }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.stopReason, .paused)
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testPauseThenResumeDoesNotReviveOldOperation() {
        let s = FakeSystem(windows: [window(1, app: "a"), window(2, app: "b", x: 900)])
        s.onWrite = { [control] _, n in
            if n == 1 { control!.paused = true; control!.paused = false }
        }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.issued, 1)
    }

    func testPauseThenResumeBeforeExecutionInvalidatesAcceptedArrange() {
        let s = FakeSystem(windows: [window(1)])
        let op = makeOp(s)
        control.paused = true
        control.paused = false
        XCTAssertEqual(op.run().stopReason, .paused)
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testAcceptedArrangeDoesNotRetargetNewSpace() {
        let s = FakeSystem(windows: [window(1)])
        let op = makeOp(s)
        s.space = 8
        s.snap.spaceID = 8
        XCTAssertEqual(op.run().stopReason, .spaceChanged)
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testInputWhileArrangeIsQueuedCancelsIt() {
        let s = FakeSystem(windows: [window(1)])
        let op = makeOp(s)
        s.inputActivityCount += 1
        XCTAssertEqual(op.run().stopReason, .userInput)
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testQueuedFocusCannotSurvivePauseResumeOrUserInput() {
        for pause in [true, false] {
            let s = FakeSystem(windows: [window(1)])
            let op = FocusOperation(system: s, control: control, target: WindowID(1), sleep: { _ in })
            if pause { control.paused = true; control.paused = false }
            else { s.inputActivityCount += 1 }
            XCTAssertEqual(op.run().stopReason, pause ? .paused : .userInput)
            XCTAssertTrue(s.focusCalls.isEmpty)
        }
    }

    /// With "Displays have separate Spaces" off, a window mostly on the display without the menu bar is left alone,
    /// and a window that can't grow wide is centered on the menu-bar display's work area.
    func testWindowOnTheOtherDisplayIsLeftAloneWhileACappedWindowIsCentered() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900, membership: .otherDisplay)])
        let area = s.snap.workArea
        s.fixed[WindowID(1)] = CGSize(width: 740, height: area.height)
        let other = s.frames[WindowID(2)]
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1)])
        XCTAssertEqual(result.excluded.map(\.window.id), [WindowID(2)])
        XCTAssertEqual(s.frames[WindowID(2)], other)
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: area.minX + floor((area.width - 740) / 2), y: area.minY, width: 740, height: area.height))
    }

    /// When the strip is dropped because the window doesn't fit beside it, a maximum learned afterwards belongs to the whole tiling area.
    func testMaximumLearnedAfterDroppingTheStripRecordsTheWholeTilingArea() {
        let s = FakeSystem(windows: [window(1)])
        let area = s.snap.workArea
        knowledge.recordPushback(id: WindowID(1), requested: CGRect(x: 0, y: 0, width: 500, height: 400), actual: CGRect(x: 0, y: 0, width: 1100, height: 400),
                                 spaceID: s.snap.spaceID, workArea: area, tolerance: 1)
        s.fixed[WindowID(1)] = CGSize(width: 1200, height: area.height)
        var options = PlannerOptions()
        options.reservedRight = 900
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), options: options, sleep: { _ in })
        op.regionFallback = PlannerOptions()
        XCTAssertEqual(op.run().outcome, .complete)
        XCTAssertTrue(op.regionDropped)
        XCTAssertEqual(op.maximumsLearnedAlone[WindowID(1)], area.integralInset)
    }

    func testTransformCannotReinsertExcludedOrClosedWindows() {
        let s = FakeSystem(windows: [window(1), window(2, membership: .other)])
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0),
                                  transform: { layout, _ in layout.inserting(WindowID(2)).inserting(WindowID(3)) }, sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1)])
        XCTAssertEqual(s.frames[WindowID(1)], s.snap.workArea)
    }

    func testAutomaticRefitDoesNotIntegrateUnapprovedNewWindows() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900), window(3, x: 1200)])
        let before = s.frames[WindowID(3)]
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0),
                                  allowedWindows: [WindowID(1), WindowID(2)], kind: "auto-refit", sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1), WindowID(2)])
        XCTAssertEqual(s.frames[WindowID(3)], before)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(3) })
        XCTAssertEqual(result.excluded.map { $0.window.id }, [WindowID(3)])
    }

    /// A transient window an app shows during a full-screen transition (layer 0 but not standard) may look like a new front window,
    /// but existing windows are not redistributed because of it. Redistributing for disappeared windows is left to refit.
    func testAutomaticIntegrationWithNoStandardNewWindowWritesNothing() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        _ = makeOp(s).run()
        let prior = Coordinator_priorFor(s)
        // The moment window 1 moves to another Space for full screen and the same app's transient window 9 appears.
        s.snap.windows.removeAll { $0.id == WindowID(1) }
        s.snap.windows.append(window(9, membership: .unknown, kind: .unknownRole))
        s.writes = []
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0), priorLayout: prior,
                                  allowedWindows: [WindowID(1), WindowID(2), WindowID(9)], adding: [WindowID(9)],
                                  kind: "auto-integrate", sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .nothingToDo)
        XCTAssertNil(result.stopReason)
        XCTAssertTrue(s.writes.isEmpty)
        XCTAssertNil(op.resultingLayout)
    }

    /// When the adding window's app does not respond, the result records "unreadable", not "no window" (automatic retries count it as a failure).
    func testIntegrationWithAnUnresponsiveAddingAppReportsTheTimeout() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        _ = makeOp(s).run()
        let prior = Coordinator_priorFor(s)
        s.snap.unobservedApps = ["com.example.hung"]
        s.writes = []
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0), priorLayout: prior,
                                  allowedWindows: [WindowID(1), WindowID(2), WindowID(9)], adding: [WindowID(9)],
                                  kind: "auto-integrate", sleep: { _ in })
        let result = op.run()
        XCTAssertEqual(result.outcome, .nothingToDo)
        XCTAssertEqual(result.stopReason, .appUnresponsive)
        XCTAssertTrue(s.writes.isEmpty)
    }

    /// When an app that owns a layout window does not answer: waiting writes nothing, arranging around writes the windows that answered without committing,
    /// and reclaiming writes them and commits the layout without the app's window.
    func testUnansweredAppPolicies() {
        for policy in [ArrangeOperation.UnansweredPolicy.wait, .arrangeAround, .reclaim] {
            let s = FakeSystem(windows: [window(1), window(2, x: 900)])
            _ = makeOp(s).run()
            let prior = Coordinator_priorFor(s)
            s.snap.windows.removeAll { $0.id == WindowID(2) }
            s.snap.unobservedApps = ["com.example.hung"]
            s.writes = []
            let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                      limits: OperationLimits(settleDelay: 0), priorLayout: prior,
                                      allowedWindows: [WindowID(1), WindowID(2)],
                                      kind: "auto-refit", unanswered: policy, sleep: { _ in })
            let result = op.run()
            switch policy {
            case .wait:
                XCTAssertTrue(s.writes.isEmpty)
                XCTAssertEqual(result.stopReason, .appUnresponsive)
                XCTAssertNil(op.resultingLayout)
            case .arrangeAround:
                XCTAssertFalse(s.writes.isEmpty)
                XCTAssertEqual(result.outcome, .partial)
                XCTAssertNil(op.resultingLayout)
            case .reclaim:
                XCTAssertFalse(s.writes.isEmpty)
                XCTAssertEqual(result.outcome, .complete)
                XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1)])
            }
        }
    }

    func testProtectedIntegrationDoesNotPullInOtherSimultaneousWindows() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        _ = makeOp(s).run()
        let prior = Coordinator_priorFor(s)
        for id in [UInt32(3), 4] {
            let w = window(id, x: CGFloat(id) * 100)
            s.snap.windows.append(w)
            s.frames[w.id] = w.frame
        }
        s.writes = []
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0), priorLayout: prior,
                                  allowedWindows: [WindowID(1), WindowID(2), WindowID(3)],
                                  kind: "auto-integrate-protected",
                                  transform: { layout, rects in layout.inserting(WindowID(3), splitting: WindowID(2), targetRect: rects[WindowID(2)]!) },
                                  protected: [WindowID(1)], sleep: { _ in })
        XCTAssertEqual(op.run().outcome, .complete)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(1) || $0.0 == WindowID(4) })
        XCTAssertEqual(Set(op.resultingLayout!.windowIDs), [WindowID(1), WindowID(2), WindowID(3)])
    }

    /// Minimums found one after another (the second shows only once the first has narrowed its neighbors) are each confirmed and replanned.
    func testMinimumsFoundOneAfterAnotherAreEachReplanned() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 700), window(3, app: "c", x: 1400)])
        s.fixed[WindowID(1)] = CGSize(width: 1200, height: 408)
        s.minimums[WindowID(2)] = CGSize(width: 500, height: 0)
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.size, CGSize(width: 1200, height: 408))
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 500)
        XCTAssertEqual(s.frames[WindowID(3)]?.width, 220)
    }

    /// An app that enlarges its window once right after the write (an Electron app maximizing a window it has just opened)
    /// gets the same request again and keeps its place; one larger readback is not a minimum.
    func testOneLargerReadbackIsWrittenAgainAndNotLearned() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        var zoomed = false
        s.onWrite = { sys, _ in
            guard !zoomed, sys.writes.last?.0 == WindowID(2) else { return }
            zoomed = true
            sys.frames[WindowID(2)] = sys.snap.workArea
        }
        let r = makeOp(s).run()
        XCTAssertTrue(zoomed)
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 960, y: 30, width: 960, height: 1050))
        XCTAssertEqual(s.writes.filter { $0.0 == WindowID(2) }.count, 2, "written once more with the same request")
        XCTAssertEqual(knowledge.constraints(for: [WindowID(2)], spaceID: 7, workArea: s.snap.workArea)[WindowID(2)], .unknown)
    }

    /// A user resize during the readback after writing is not learned as a minimum size.
    func testAResizeDuringReadbackIsNotLearnedAsAMinimum() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        var resized = false
        s.onRead = { sys, id in
            guard !resized, id == WindowID(2), sys.writes.count >= 2, let frame = sys.frames[id] else { return }
            resized = true
            sys.frames[id] = CGRect(x: frame.minX - 300, y: frame.minY, width: frame.width + 300, height: frame.height)
            sys.inputActivityCount += 1 // the user dragged
        }
        let r = makeOp(s).run()
        XCTAssertTrue(resized)
        XCTAssertEqual(r.stopReason, .userInput)
        let learned = knowledge.constraints(for: [WindowID(2)], spaceID: 7, workArea: s.snap.workArea)[WindowID(2)]
        if case .estimated = learned { XCTFail("the user's resize is not a minimum size: \(String(describing: learned))") }
    }

    /// When the full window list could not be read, invisible windows are not treated as closed and an emptied layout is not committed.
    func testAFailedWindowListNeverPrunesTheLayout() {
        let s = FakeSystem(windows: [])
        s.snap.windowListAvailable = false
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        op.appliesRegion = true
        let r = op.run()
        XCTAssertNotEqual(r.outcome, .complete)
        XCTAssertNil(op.resultingLayout, "nothing is committed")
    }

    /// A window that moves to another Space during arrangement without input is not written.
    func testAWindowThatMovedToAnotherSpaceIsNotWritten() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.onWrite = { sys, n in if n == 1 { sys.membershipOverride[WindowID(2)] = .other } }
        let r = makeOp(s).run()
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(2) }, "no write to a window on another Space")
        XCTAssertEqual(r.stopReason, .targetsChanged)
        XCTAssertNotEqual(r.outcome, .complete)
    }

    /// A window that moves to another Space in the middle of its write gets no further setters.
    func testAWindowThatMovesDuringItsWriteIsNotWrittenFurther() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.betweenSetters = { sys, id in if id == WindowID(2) { sys.membershipOverride[id] = .other } }
        let r = makeOp(s).run()
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(2) }, "no setter after the window left the Space")
        XCTAssertEqual(r.stopReason, .targetsChanged)
    }

    /// A window once seen on another Space during writing is not written again, even if its membership later becomes unknown.
    func testADepartureSeenOnceIsNotForgottenWhenMembershipBecomesUnknown() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.betweenSetters = { sys, id in if id == WindowID(2) { sys.membershipQueue[id] = [.other] } } // read once as another Space, then unknown
        let r = makeOp(s).run()
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(2) })
        XCTAssertEqual(r.stopReason, .targetsChanged)
    }

    func testUserInputDuringIssueStopsAndDoesNotResume() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.onWrite = { sys, n in if n == 1 { sys.inputActivityCount += 1 } }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.stopReason, .userInput)
        XCTAssertEqual(s.writes.count, 1)
    }

    func testSpaceChangeDuringIssueStops() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.onWrite = { sys, n in if n == 1 { sys.space = 9 } }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.stopReason, .spaceChanged)
        XCTAssertEqual(s.writes.count, 1)
    }

    func testSpaceObservationLossStopsRemainingWrites() {
        let s = FakeSystem(windows: [window(1, app: "a"), window(2, app: "b", x: 900)])
        s.onWrite = { sys, n in if n == 1 { sys.space = nil } }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .interrupted)
        XCTAssertEqual(r.stopReason, .spaceChanged)
        XCTAssertEqual(s.writes.count, 1)
    }

    func testPausedBeforeStartWritesNothing() {
        let s = FakeSystem(windows: [window(1, app: "a")])
        control.paused = true
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .notPossible)
        XCTAssertEqual(r.stopReason, .paused)
        XCTAssertEqual(s.writes.count, 0)
    }

    func testNotTrustedWritesNothingAndExplains() {
        let s = FakeSystem(windows: [window(1, app: "a")], trusted: false)
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .notPossible)
        XCTAssertEqual(r.stopReason, .permissionLost)
        XCTAssertTrue(r.message.contains(AccessPane.name()), r.message)
        XCTAssertEqual(s.writes.count, 0)
    }

    func testUnfitKnownBeforeWriteWritesNothing() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        // Previously learned constraints do not fit, and the current sizes meet the same minimums.
        for id in [WindowID(1), WindowID(2)] { s.frames[id]?.size = CGSize(width: 1500, height: 900) }
        knowledge.recordPushback(id: WindowID(1), requested: CGRect(x: 0, y: 0, width: 10, height: 10), actual: CGRect(x: 0, y: 0, width: 1500, height: 900), spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
        knowledge.recordPushback(id: WindowID(2), requested: CGRect(x: 0, y: 0, width: 10, height: 10), actual: CGRect(x: 0, y: 0, width: 1500, height: 900), spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
        let op = makeOp(s)
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(op.resultingLayout?.windowIDs.count, 1)
        XCTAssertEqual(r.excluded.filter { $0.code == .overflowFloat }.count, 1)
        XCTAssertEqual(r.excluded.first { $0.code == .overflowFloat }?.reason, ArrangeOperation.overflowFloatReason)
        XCTAssertTrue(r.message.contains("kept in place as floating"), r.message)
    }

    func testUnresponsiveAppDoesNotBlockOthersAndIsNotSuccess() {
        let s = FakeSystem(windows: [window(1, app: "slow", x: 0), window(2, app: "b", x: 900)])
        s.unresponsiveApps = ["slow"]
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .partial)
        XCTAssertEqual(r.stopReason, .appUnresponsive)
        XCTAssertEqual(r.targets[0].status, .mismatch)
        XCTAssertEqual(r.targets[1].status, .verified)
    }

    func testWindowClosedMidOperationIsReportedNotHidden() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        s.onWrite = { sys, n in if n == 1 { sys.gone.insert(WindowID(2)) } }
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .partial)
        XCTAssertEqual(r.stopReason, .targetsChanged)
        XCTAssertEqual(r.targets[1].status, .gone)
        XCTAssertEqual(r.targets[0].status, .verified)
    }

    func testExcludedWindowsAreNeverWritten() {
        let s = FakeSystem(windows: [
            window(1, app: "a", x: 0),
            window(2, app: "b", x: 100, membership: .unknown),
            window(3, app: "c", x: 200, membership: .other),
            window(4, app: "d", x: 300, kind: .dialog),
            window(5, app: "e", x: 400, kind: .minimized),
            window(6, app: "f", x: 500, kind: .fullscreen),
        ])
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .complete)
        XCTAssertEqual(r.targets.map(\.id), [WindowID(1)])
        XCTAssertEqual(r.excluded.count, 5)
        XCTAssertEqual(Set(s.writes.map(\.0)), [WindowID(1)])
        XCTAssertTrue(r.excluded.contains { $0.window.id == WindowID(2) && $0.reason.contains("Space can't be determined") }, "\(r.excluded.map(\.reason))")
    }

    func testNothingToDoWhenNoTargets() {
        let s = FakeSystem(windows: [window(1, app: "a", kind: .dialog)])
        let r = makeOp(s).run()
        XCTAssertEqual(r.outcome, .nothingToDo)
        XCTAssertEqual(s.writes.count, 0)
    }

    func testTargetReadingOrderDoesNotDependOnObservationOrder() {
        func target(_ id: UInt32, x: CGFloat, y: CGFloat) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: "app", frame: CGRect(x: x, y: y, width: 100, height: 100), membership: .current, kind: .standard, detail: "")
        }
        let a = target(1, x: 300, y: 0), b = target(2, x: 200, y: 30), c = target(3, x: 100, y: 60)
        for windows in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            let snap = Snapshot(trusted: true, spaceID: 1, workArea: .zero, windows: windows, spaceObservationAvailable: true)
            XCTAssertEqual(TargetSelection.inspect(snap).targets.map(\.id), [WindowID(2), WindowID(1), WindowID(3)])
        }
    }

    func testOverlappingWindowsAreOrderedFrontToBack() {
        func window(_ id: UInt32, _ order: Int) -> ObservedWindow {
            ObservedWindow(id: WindowID(id), pid: 1, app: "app", frame: CGRect(x: 0, y: 33, width: 1512, height: 949), membership: .current, kind: .standard, detail: "", stackOrder: order)
        }
        let snap = Snapshot(trusted: true, spaceID: 1, workArea: CGRect(x: 0, y: 33, width: 1512, height: 949), windows: [window(1, 4), window(9, 0), window(3, 2)], spaceObservationAvailable: true)
        XCTAssertEqual(TargetSelection.inspect(snap).targets.map(\.id), [WindowID(9), WindowID(3), WindowID(1)])
        let left = ObservedWindow(id: WindowID(8), pid: 1, app: "right-front", frame: CGRect(x: 800, y: 33, width: 700, height: 400), membership: .current, kind: .standard, detail: "", stackOrder: 0)
        let right = ObservedWindow(id: WindowID(2), pid: 1, app: "left-back", frame: CGRect(x: 0, y: 33, width: 700, height: 400), membership: .current, kind: .standard, detail: "", stackOrder: 5)
        let placed = Snapshot(trusted: true, spaceID: 1, workArea: CGRect(x: 0, y: 33, width: 1512, height: 949), windows: [left, right], spaceObservationAvailable: true)
        XCTAssertEqual(TargetSelection.inspect(placed).targets.map(\.id), [WindowID(2), WindowID(8)])
    }

    func testDialogWithAZoomButtonIsADocumentWindow() {
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXDialog", dialogHasZoomButton: true), .standard)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXDialog", dialogHasZoomButton: false), .dialog)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXSystemDialog", dialogHasZoomButton: true), .dialog)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXSheet", subrole: "AXDialog", dialogHasZoomButton: true), .sheet)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXStandardWindow", dialogHasZoomButton: false), .standard)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXStandardWindow", dialogHasZoomButton: false, fullscreenButtonEnabled: false), .dialog)
        // Resizable windows without a full-screen button (Activity Monitor, System Settings) are arranged. Fixed-size ones like Calculator are dialogs.
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXStandardWindow", dialogHasZoomButton: false, fullscreenButtonEnabled: false, resizable: true), .standard)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXDialog", dialogHasZoomButton: true, fullscreenButtonEnabled: false, resizable: true), .standard)
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXDialog", dialogHasZoomButton: false, fullscreenButtonEnabled: false, resizable: true), .dialog, "a dialog without a zoom button stays a dialog")
        XCTAssertEqual(ObservedWindow.Kind.observed(hiddenApp: false, minimized: false, fullscreen: false, layer: 0, role: "AXWindow", subrole: "AXSystemDialog", dialogHasZoomButton: true, fullscreenButtonEnabled: false, resizable: true), .dialog)
        XCTAssertNil(TargetSelection.exclusionReason(window(1, app: "com.apple.dt.Xcode", kind: .standard)))
    }

    func testAlreadyArrangedIssuesNothing() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        _ = makeOp(s).run()
        let second = makeOp(s).run()
        XCTAssertEqual(second.outcome, .complete)
        XCTAssertEqual(second.issued, 0)
        XCTAssertEqual(second.targets.map(\.status), [.unchanged, .unchanged])
    }

    func testPriorLayoutIsReusedWhenSameWindows() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.25, 0.75]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)]!.width, 480)
        XCTAssertEqual(op.resultingLayout, prior)
    }

    func testNewWindowIsInsertedIntoPriorStructureAndGoneOneRemoved() {
        // Saved intent a:b = 0.75:0.25. b disappears and c appears -> a horizontal split of a and c; a keeps its ratio and shrinks.
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(3, app: "c", x: 900)])
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.75, 0.25]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1), WindowID(3)])
        XCTAssertEqual(s.frames[WindowID(1)]!.width, 960) // leaf a collapsed and c added at 0.5
        XCTAssertFalse(r.message.lowercased().contains("rebuil"))
    }

    func testPriorStructureThatCannotFitIsRebuiltAndSaidSo() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900), window(3, app: "c", x: 1200)])
        for id in [1, 2, 3] {
            s.frames[WindowID(UInt32(id))]?.size = CGSize(width: 900, height: 400)
            knowledge.recordPushback(id: WindowID(UInt32(id)), requested: CGRect(x: 0, y: 0, width: 10, height: 10), actual: CGRect(x: 0, y: 0, width: 900, height: 300), spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
        }
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.5, 0.5]))
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertTrue(r.excluded.contains { $0.code == .overflowFloat })
        XCTAssertTrue(r.message.contains("kept in place as floating"), r.message)
        XCTAssertFalse(r.message.lowercased().contains("rebuil"))
        XCTAssertEqual(op.resultingLayout?.windowIDs.count, 2)
    }

    func testHeldOutWindowsAreExcludedWithReasonAndNotWritten() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), heldOut: [WindowID(2): "waiting"], kind: "auto-integrate", sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.kind, "auto-integrate")
        XCTAssertEqual(r.targets.map(\.id), [WindowID(1)])
        XCTAssertTrue(r.excluded.contains { $0.window.id == WindowID(2) && $0.reason == "waiting" })
        XCTAssertEqual(Set(s.writes.map(\.0)), [WindowID(1)])
    }

    func testTransformEditsLayoutAndWritesOnlyChangedWindows() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900), window(3, app: "c", x: 1500)])
        _ = makeOp(s).run() // three side by side
        s.writes = []
        let prior = Coordinator_priorFor(s)
        // An edit swapping a and c.
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, kind: "edit:swap",
                                  transform: { layout, _ in LayoutEdit.swap(WindowID(1), WindowID(3), in: layout) }, sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(Set(s.writes.map(\.0)), [WindowID(1), WindowID(3)], "b does not move")
        XCTAssertEqual(r.targets.first { $0.id == WindowID(2) }?.status, .unchanged)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(3), WindowID(2), WindowID(1)])
    }

    func testTransformReturningNilWritesNothingAndExplains() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0)])
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), kind: "edit:focus",
                                  transform: { _, _ in nil }, transformFailure: "右に窓がありません。", sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .notPossible)
        XCTAssertEqual(r.message, "右に窓がありません。")
        XCTAssertEqual(s.writes.count, 0)
    }

    func testZoomFillsOnlyTargetAndKeepsOthersAndLayout() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        _ = makeOp(s).run()
        s.writes = []
        let prior = Coordinator_priorFor(s)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, kind: "zoom", zoomed: WindowID(2), sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(s.writes.map(\.0), [WindowID(2)])
        XCTAssertEqual(s.frames[WindowID(2)], s.snap.workArea)
        XCTAssertEqual(s.frames[WindowID(1)]!.width, 960, "other windows do not move")
        XCTAssertTrue(r.excluded.contains { $0.window.id == WindowID(1) && $0.reason.contains("zoomed") })
        XCTAssertEqual(op.resultingLayout, prior, "zoom does not change the layout intent")
    }

    func testZoomKeepsLeftoverHeightOnTheSameWindow() {
        let a = WindowID(1)
        let b = WindowID(2)
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 960)])
        s.frames[a] = CGRect(x: 0, y: 30, width: 960, height: 440)
        s.frames[b] = CGRect(x: 960, y: 30, width: 960, height: 1050)
        let prior = Layout(
            root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]),
            leftoverHeights: [a: 440]
        )
        let zoom = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, kind: "zoom", zoomed: b, sleep: { _ in })
        XCTAssertEqual(zoom.run().outcome, .complete)
        XCTAssertEqual(s.frames[b], s.snap.workArea)
        XCTAssertEqual(s.frames[a]?.height, 440)
        XCTAssertEqual(zoom.resultingLayout?.leftoverHeights[a], 440)
        s.writes = []
        let unzoom = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: zoom.resultingLayout, kind: "zoom", sleep: { _ in })
        XCTAssertEqual(unzoom.run().outcome, .complete)
        XCTAssertEqual(s.frames[a]?.height, 440)
        XCTAssertEqual(unzoom.resultingLayout?.leftoverHeights[a], 440)
    }

    func testZoomReplanKeepsWorkAreaOrigin() {
        let s = FakeSystem(windows: [window(1, app: "a"), window(2, app: "fixed", x: 900)])
        s.fixed[WindowID(2)] = CGSize(width: 230, height: 408)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0), zoomed: WindowID(2), sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(r.retries, 1)
        XCTAssertEqual(s.frames[WindowID(2)]?.origin, s.snap.workArea.origin)
    }

    func testInvalidateStopsAsCancelledRatherThanPause() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), sleep: { _ in })
        control.invalidate()
        let result = op.run()
        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertEqual(result.outcome, .notPossible)
        XCTAssertEqual(result.message, ArrangeOperation.changedAfterRequestMessage)
    }

    func testLightFocusSkipsSnapshotAndSettle() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        s.membershipOverride[WindowID(2)] = .current
        var snapshots = 0
        s.onSnapshot = { _ in snapshots += 1 }
        var sleeps = 0
        let pressed = Date().addingTimeInterval(-0.2)
        let result = FocusOperation(system: s, control: control, limits: OperationLimits(settleDelay: 0.08), target: WindowID(2), pressedAt: pressed, sleep: { _ in sleeps += 1 }).run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(sleeps, 0)
        XCTAssertEqual(s.focusCalls, [WindowID(2)])
        XCTAssertGreaterThan(result.timing?.keyToFirstWriteMs ?? 0, 100)
    }

    func testLightFocusRefusesUnknownMembershipWithoutSnapshot() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        s.membershipOverride[WindowID(2)] = .unknown
        var snapshots = 0
        s.onSnapshot = { _ in snapshots += 1 }
        let result = FocusOperation(system: s, control: control, target: WindowID(2)).run()
        XCTAssertEqual(result.outcome, .notPossible)
        XCTAssertEqual(result.stopReason, .targetsChanged)
        XCTAssertEqual(s.focusCalls, [])
        XCTAssertEqual(snapshots, 0)
    }

    func testQueuedCommandSkipsTheSettleWait() {
        let s = FakeSystem(windows: [window(1), window(2, x: 900)])
        var sleeps = 0
        control.hurrySettle = true
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0.2), sleep: { _ in sleeps += 1 })
        let result = op.run()
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(sleeps, 0, "no settle wait while the next command is waiting")
        XCTAssertNotNil(result.timing)
        XCTAssertGreaterThan(result.timing?.observeMs ?? -1, -0.1)
    }

    func testFocusOperationIssuesRaiseOnlyAndVerifies() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        let r = FocusOperation(system: s, control: control, limits: OperationLimits(settleDelay: 0), target: WindowID(2), sleep: { _ in }).run()
        XCTAssertEqual(r.outcome, .complete)
        XCTAssertEqual(r.kind, "focus")
        XCTAssertEqual(s.focusCalls, [WindowID(2)])
        XCTAssertEqual(s.writes.count, 0)
        control.paused = true
        let p = FocusOperation(system: s, control: control, target: WindowID(1)).run()
        XCTAssertEqual(p.outcome, .notPossible)
        XCTAssertEqual(s.focusCalls.count, 1)
    }

    func testFocusRejectsExcludedWindows() {
        for w in [window(1, membership: .other), window(1, kind: .fullscreen)] {
            let s = FakeSystem(windows: [w])
            let r = FocusOperation(system: s, control: control, target: WindowID(1)).run()
            XCTAssertEqual(r.outcome, .notPossible)
            XCTAssertTrue(s.focusCalls.isEmpty)
        }
    }

    /// Builds layout intent from the last complete result (standing in for what Coordinator saves).
    func Coordinator_priorFor(_ s: FakeSystem) -> Layout {
        let ids = s.snap.windows.map(\.id).sorted { s.frames[$0]!.minX < s.frames[$1]!.minX }
        return Planner.rowLayout(ids, rows: 1)
    }

    func testProtectedWindowIsNotResizedWhenTheAverageShareAlreadyMatches() {
        // With the sibling average, a's share stays 1/2, so a is not written even while protected, and the new window joins.
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        _ = makeOp(s).run(); s.writes = []
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [0.75, 0.25]))
        s.snap.windows.append(window(3, app: "c", x: 1500)); s.frames[WindowID(3)] = s.snap.windows[2].frame
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, kind: "auto-integrate-protected", protected: [WindowID(1)], sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(1) })
        XCTAssertTrue(op.resultingLayout?.windowIDs.contains(WindowID(3)) == true)
    }

    func testProtectedIntegrateRestoresTheNewWindowWhenItCannotJoin() {
        let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 230)], area: area)
        s.frames[WindowID(1)] = CGRect(x: 0, y: 33, width: 230, height: 440)
        s.frames[WindowID(2)] = CGRect(x: 230, y: 33, width: 1282, height: 949)
        s.fixed[WindowID(1)] = CGSize(width: 230, height: 440)
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2))], ratios: [230 / 1512, 1282 / 1512]))
        let originalC = CGRect(x: 80, y: 470, width: 520, height: 392)
        s.snap.windows.append(window(3, app: "c", x: 80))
        s.frames[WindowID(3)] = originalC
        s.minimums[WindowID(3)] = CGSize(width: 400, height: 300)
        let transform: ArrangeOperation.Transform = { layout, rects in
            guard let rect = rects[WindowID(1)] else { return nil }
            return layout.inserting(WindowID(3), splitting: WindowID(1), targetRect: rect)
        }
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                  priorLayout: prior, kind: "auto-integrate-protected", transform: transform,
                                  protected: [WindowID(2)], sleep: { _ in })
        let r = op.run()
        XCTAssertNotEqual(r.outcome, .complete, r.message)
        XCTAssertTrue(r.message.contains("waits"), r.message)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 230)
        XCTAssertEqual(s.frames[WindowID(2)]?.width, 1282)
        XCTAssertEqual(s.frames[WindowID(3)], originalC)
        XCTAssertTrue(s.writes.contains { $0.0 == WindowID(3) })
    }

    func testProtectedInsertionBySplittingAnotherLeafSucceeds() {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0), window(2, app: "b", x: 900)])
        _ = makeOp(s).run(); s.writes = []
        let prior = Coordinator_priorFor(s)
        s.snap.windows.append(window(3, app: "c", x: 1500)); s.frames[WindowID(3)] = s.snap.windows[2].frame
        let transform: ArrangeOperation.Transform = { layout, rects in layout.inserting(WindowID(3), splitting: WindowID(2), targetRect: rects[WindowID(2)]!) }
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior, kind: "auto-integrate-protected", transform: transform, protected: [WindowID(1)], sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(1) }, "protected windows are not written")
        XCTAssertEqual(s.frames[WindowID(1)]!.width, 960)
        // b's place (960 wide, 1050 high, portrait) is split top and bottom between b and c.
        XCTAssertEqual(s.frames[WindowID(2)]!.height, 525)
        XCTAssertEqual(s.frames[WindowID(3)]!.height, 525)
        XCTAssertEqual(s.frames[WindowID(3)]!.minY, 555)
    }

    func testReplanCannotMoveProtectedWindow() {
        let s = FakeSystem(windows: [window(1, app: "protected"), window(2, app: "large", x: 900)])
        s.frames[WindowID(1)] = CGRect(x: 0, y: 30, width: 960, height: 1050)
        s.frames[WindowID(2)] = CGRect(x: 960, y: 30, width: 500, height: 1050)
        s.minimums[WindowID(2)] = CGSize(width: 1200, height: 300)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge,
                                  limits: OperationLimits(settleDelay: 0), protected: [WindowID(1)], sleep: { _ in })
        let r = op.run()
        XCTAssertNotEqual(r.outcome, .complete)
        XCTAssertEqual(s.frames[WindowID(1)]?.width, 960)
        XCTAssertFalse(s.writes.contains { $0.0 == WindowID(1) })
    }

    func testLearnedUnfitAfterWriteFloatsTheOverflow() {
        let area = CGRect(x: 0, y: 33, width: 800, height: 400)
        let s = FakeSystem(windows: [window(1, app: "big.a"), window(2, app: "big.b", x: 300)], area: area)
        let original1 = CGRect(x: 0, y: 33, width: 500, height: 300)
        let original2 = CGRect(x: 300, y: 33, width: 500, height: 300)
        s.frames[WindowID(1)] = original1
        s.frames[WindowID(2)] = original2
        s.minimums[WindowID(1)] = CGSize(width: 500, height: 300)
        s.minimums[WindowID(2)] = CGSize(width: 500, height: 300)
        let op = makeOp(s)
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertTrue(r.excluded.contains { $0.code == .overflowFloat })
        XCTAssertTrue(r.message.contains("kept in place as floating"), r.message)
        XCTAssertFalse(r.message.contains("returned to where they were before"), r.message)
        XCTAssertFalse(r.targets.contains { $0.noteKind == .restoredOriginal })
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1)])
        XCTAssertEqual(r.excluded.map(\.window.id), [WindowID(2)])
        XCTAssertNotEqual(s.frames[WindowID(2)], original2)
        XCTAssertGreaterThan(s.writes.count, 1)
        XCTAssertTrue(r.targets.allSatisfy { $0.status == .verified || $0.status == .unchanged })
        if case .estimated(let size) = knowledge.constraints(for: [WindowID(1)], spaceID: 7, workArea: area)[WindowID(1)] {
            XCTAssertGreaterThan(size.width, 0)
        } else {
            XCTFail("learned minimum should remain after rollback")
        }
    }

    func testUnfitPairFloatsOneWindowInsteadOfRestoringTheOrigin() {
        let area = CGRect(x: 0, y: 33, width: 800, height: 400)
        let s = FakeSystem(windows: [window(1, app: "big.a"), window(2, app: "big.b", x: 40)], area: area)
        let original1 = CGRect(x: 40, y: 80, width: 200, height: 180)
        let original2 = CGRect(x: 80, y: 90, width: 200, height: 180)
        s.frames[WindowID(1)] = original1
        s.frames[WindowID(2)] = original2
        s.minimums[WindowID(1)] = CGSize(width: 500, height: 300)
        s.minimums[WindowID(2)] = CGSize(width: 500, height: 300)
        let op = makeOp(s)
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertTrue(r.excluded.contains { $0.code == .overflowFloat })
        XCTAssertTrue(r.message.contains("kept in place as floating"), r.message)
        XCTAssertEqual(op.resultingLayout?.windowIDs, [WindowID(1)])
        XCTAssertNotEqual(s.frames[WindowID(1)], CGRect(x: 40, y: 80, width: 500, height: 300))
        XCTAssertNotEqual(s.frames[WindowID(2)], original2)
    }

    func testResultRoundTripsThroughJSON() throws {
        let s = FakeSystem(windows: [window(1, app: "a", x: 0)])
        let r = makeOp(s).run()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(OperationResult.self, from: try enc.encode(r))
        XCTAssertEqual(back.id, r.id)
        XCTAssertEqual(back.outcome, r.outcome)
        XCTAssertEqual(back.targets, r.targets)
        XCTAssertEqual(back.message, r.message)
    }

    private func finderWindow(_ id: UInt32, identifier: String, frame: CGRect, fullScreen: Bool) -> ObservedWindow {
        ObservedWindow(id: WindowID(id), pid: 1, app: "com.apple.finder", frame: frame, membership: .current, kind: .standard, detail: "",
                       subrole: "AXStandardWindow", identifier: identifier, fullScreenButtonEnabled: fullScreen)
    }

    /// A Finder window fills the screen and a Get Info window (at most 400 x 900) joins it; the Get Info window teaches its kind that maximum.
    private func spaceWithFirstGetInfo() -> (FakeSystem, Layout?) {
        let area = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let s = FakeSystem(windows: [
            finderWindow(1, identifier: "FinderWindow", frame: area, fullScreen: true),
            finderWindow(2, identifier: "Info", frame: CGRect(x: 10, y: 40, width: 400, height: 900), fullScreen: false),
        ], area: area)
        s.maximums[WindowID(2)] = CGSize(width: 400, height: 900)
        let first = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                     priorLayout: Layout(root: .leaf(WindowID(1))), sleep: { _ in })
        let result = first.run()
        XCTAssertEqual(result.outcome, .complete, result.message)
        return (s, first.resultingLayout)
    }

    /// The first Get Info window, with no maximum known for its kind, is written its share like any window. Refusing that size twice confirms
    /// its maximum, and the row is planned again around it.
    func testTheFirstGetInfoWindowLearnsItsLimitFromItsShare() {
        let (s, _) = spaceWithFirstGetInfo()
        XCTAssertEqual(s.writes.first { $0.0 == WindowID(2) }?.1, CGRect(x: 960, y: 30, width: 960, height: 1050), "its share, not a request where it opened")
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 30, width: 1520, height: 1050))
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 1520, y: 30, width: 400, height: 900))
        XCTAssertEqual(knowledge.maximums(for: [WindowID(2)], workArea: s.snap.workArea)[WindowID(2)], CGSize(width: 400, height: 900))
    }

    private func join(_ window: ObservedWindow, maximum: CGSize, to s: FakeSystem, prior: Layout?) -> OperationResult {
        s.snap.windows.append(window)
        s.frames[window.id] = window.frame
        s.maximums[window.id] = maximum
        s.writes = []
        return ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0),
                                priorLayout: prior, sleep: { _ in }).run()
    }

    /// A second Get Info window opening at the size the first one taught its kind is planned at that size from the start, so every window moves once.
    func testASecondWindowOfAKindIsPlannedAtTheLearnedMaximum() {
        let (s, prior) = spaceWithFirstGetInfo()
        let r = join(finderWindow(3, identifier: "Info", frame: CGRect(x: 10, y: 40, width: 400, height: 900), fullScreen: false),
                     maximum: CGSize(width: 400, height: 900), to: s, prior: prior)
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(r.retries, 0)
        XCTAssertEqual(s.writes.filter { $0.0 == WindowID(3) }.map(\.1), [CGRect(x: 1520, y: 30, width: 400, height: 900)])
        XCTAssertEqual(Dictionary(grouping: s.writes, by: { $0.0 }).mapValues(\.count).values.max(), 1, "every window is written once")
        XCTAssertEqual(s.frames[WindowID(1)], CGRect(x: 0, y: 30, width: 1203, height: 1050))
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 1203, y: 30, width: 317, height: 900))
    }

    /// Another kind, a window that can fill the screen, or one that opens at another size does not borrow the kind's maximum:
    /// its first write is its share, not its final frame.
    func testOnlyAWindowOfTheSameKindAtThatSizeStartsAtTheLearnedMaximum() {
        let variants: [(String, ObservedWindow)] = [
            ("another identifier", finderWindow(3, identifier: "Other", frame: CGRect(x: 10, y: 40, width: 400, height: 900), fullScreen: false)),
            ("full-screen button", finderWindow(3, identifier: "Info", frame: CGRect(x: 10, y: 40, width: 400, height: 900), fullScreen: true)),
            ("another size", finderWindow(3, identifier: "Info", frame: CGRect(x: 10, y: 40, width: 380, height: 900), fullScreen: false)),
        ]
        for (name, window) in variants {
            knowledge = ConstraintKnowledge()
            let (s, prior) = spaceWithFirstGetInfo()
            let r = join(window, maximum: CGSize(width: 400, height: 900), to: s, prior: prior)
            XCTAssertEqual(r.outcome, .complete, "\(name): \(r.message)")
            XCTAssertNotEqual(s.writes.first { $0.0 == WindowID(3) }?.1, CGRect(x: 1520, y: 30, width: 400, height: 900), name)
            XCTAssertEqual(s.frames[WindowID(3)]?.width, 400, name)
        }
    }

    /// A single window does not take its kind's maximum: it asks for the whole area, so the solo probe has nothing left to test.
    func testASingleWindowOfAKindDoesNotBorrowTheMaximum() {
        let (s, _) = spaceWithFirstGetInfo()
        s.writes = []
        let window = finderWindow(3, identifier: "Info", frame: CGRect(x: 10, y: 40, width: 400, height: 900), fullScreen: false)
        s.snap.windows = [window]
        s.frames[window.id] = window.frame
        s.maximums[window.id] = CGSize(width: 400, height: 900)
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), sleep: { _ in })
        XCTAssertEqual(op.run().outcome, .complete)
        XCTAssertEqual(s.writes.filter { $0.0 == WindowID(3) }.first?.1.width, 1920)
        XCTAssertNotNil(op.maximumsLearnedAlone[WindowID(3)])
    }

    /// A third Get Info window joins a Finder window and two Get Info windows (measured live). The first Get Info window is made 285 wide and
    /// grows to 1308 to fit its contents, above the 1280 its layout remembers: the arrangement still completes and adds the new window.
    func testAWindowThatGrowsTallerWhenNarrowerKeepsTheHeightItNeeds() {
        let area = CGRect(x: 0, y: 30, width: 2560, height: 1410)
        let infos: [(UInt32, CGRect)] = [(2, CGRect(x: 1822, y: 30, width: 338, height: 1280)), (3, CGRect(x: 2160, y: 30, width: 400, height: 1280)),
                                         (4, CGRect(x: 10, y: 40, width: 400, height: 1280))]
        let s = FakeSystem(windows: [finderWindow(1, identifier: "FinderWindow", frame: CGRect(x: 0, y: 30, width: 1822, height: 1410), fullScreen: true)]
                           + infos.map { finderWindow($0.0, identifier: "Info", frame: $0.1, fullScreen: false) }, area: area)
        for (id, _) in infos {
            s.maximums[WindowID(id)] = CGSize(width: 400, height: area.height)
            s.contentHeights[WindowID(id)] = { $0 < 300 ? 1308 : 1280 }
        }
        for id: UInt32 in [2, 3] {
            knowledge.recordPullback(id: WindowID(id), requested: CGRect(x: 0, y: 30, width: 1280, height: 1410), actual: CGRect(x: 0, y: 30, width: 400, height: 1280),
                                     spaceID: 7, workArea: area, tolerance: 1, kind: "com.apple.finder\nAXStandardWindow\nInfo")
        }
        let prior = Layout(root: .split(.horizontal, children: [.leaf(WindowID(1)), .leaf(WindowID(2)), .leaf(WindowID(3))],
                                        ratios: [1822.0 / 2560.0, 338.0 / 2560.0, 400.0 / 2560.0]),
                           leftoverHeights: [WindowID(2): 1280, WindowID(3): 1280])
        let op = ArrangeOperation(system: s, control: control, knowledge: knowledge, limits: OperationLimits(settleDelay: 0), priorLayout: prior,
                                  adding: [WindowID(4)], kind: "auto-integrate", sleep: { _ in })
        let r = op.run()
        XCTAssertEqual(r.outcome, .complete, r.message)
        XCTAssertEqual(op.resultingLayout?.windowIDs.contains(WindowID(4)), true)
        XCTAssertEqual(s.frames[WindowID(2)], CGRect(x: 1537, y: 30, width: 285, height: 1308))
        XCTAssertEqual(s.frames[WindowID(4)], CGRect(x: 2160, y: 30, width: 400, height: 1280))
    }

    /// Portuguese counts 0 as one, so the messages that can report 0 arranged windows carry their own zero form.
    func testPortugueseReportsZeroArrangedWindowsInThePlural() {
        let zero = [L(.arrangeOperationArranged(windows: 0), in: .brazilianPortuguese),
                    L(.arrangeOperationArrangedUnobservedLeft(windows: 0, "Mail"), in: .brazilianPortuguese),
                    L(.arrangeOperationArrangedUnobservedUnconfirmed(windows: 0, "Mail"), in: .brazilianPortuguese)]
        for text in zero { XCTAssertTrue(text.contains("0 janelas"), text) }
        XCTAssertTrue(L(.arrangeOperationArranged(windows: 1), in: .brazilianPortuguese).contains("1 janela "))
    }
}
