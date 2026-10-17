import Copy
import Foundation
import LayoutCore
@testable import Operations
import Settings
@testable import LazySpaceApp

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS: \(name)") }
    else { failures += 1; print("FAIL: \(name)") }
}
// The catalogs compiled next to each module's library resolve: a missing one would show the key.
check(MacItem.openAtLogin == "Open at Login" && L(.arrangeOperationArranged(windows: 1), in: .english) == "Arranged 1 window.",
      "catalog text resolves in the regression build")

func run(_ s: FakeSystem, _ k: ConstraintKnowledge) -> OperationResult {
    ArrangeOperation(system: s, control: OperationControl(), knowledge: k,
                     limits: OperationLimits(settleDelay: 0), sleep: { _ in }).run()
}
func drain(_ coordinator: Coordinator) -> Bool {
    let done = DispatchSemaphore(value: 0)
    coordinator.operationsQueue.async { done.signal() }
    let deadline = Date().addingTimeInterval(10)
    while done.wait(timeout: .now()) != .success {
        if Date() >= deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}
let a = WindowID(1), b = WindowID(2)
// A manually enlarged window disproves the old maximum before planning.
do {
    let s = FakeSystem(windows: [window(1), window(2)])
    let k = ConstraintKnowledge()
    k.recordPullback(id: a, requested: s.snap.workArea,
                     actual: CGRect(x: 0, y: 30, width: 698, height: 745),
                     spaceID: 7, workArea: s.snap.workArea, tolerance: 1)
    s.frames[a] = s.snap.workArea
    let r = run(s, k)
    check(r.outcome == .complete && s.frames[a]?.size == CGSize(width: 960, height: 1050),
          "fresh size disproves stale maximum before layout")
}
// An AX request may return before resizing has taken effect. Retry the intended frame.
do {
    let s = FakeSystem(windows: [window(1), window(2)])
    let k = ConstraintKnowledge()
    s.onWrite = { sys, count in
        if count == 1 { sys.frames[a] = CGRect(x: 0, y: 30, width: 698, height: 745) }
    }
    let r = run(s, k)
    check(r.outcome == .complete && s.frames[a]?.size == CGSize(width: 960, height: 1050),
          "transient resize does not shrink the intended tile")
}
// An app that opens its first foreground window participates after input settles.
do {
    let s = FakeSystem(windows: [window(1), window(2)])
    let k = ConstraintKnowledge()
    s.onWrite = { sys, _ in
        sys.frames[a] = CGRect(x: 152, y: 73, width: 960, height: 1007)
    }
    let result = run(s, k)
    check(result.outcome == .partial && k.maximums(for: [a], workArea: s.snap.workArea)[a] == nil,
          "screen-edge clipping before position settles is not a size limit")
}
do {
    let prev = Census(windows: [a: 10], frontmostPID: 10, spaceID: 7, frontWindow: a)
    let cur = Census(windows: [a: 10, b: 20], frontmostPID: 20, spaceID: 7, frontWindow: b)
    let out = AutoDecide.decide(.init(previous: prev, current: cur, inputQuiet: true,
                                     paused: false, hasLayout: true, managed: [a]))
    check(out.actions == [.integrate([b], beside: a)], "new foreground app joins beside previous window")
    let already = AutoDecide.decide(.init(previous: prev, current: cur, inputQuiet: true,
                                         paused: false, hasLayout: true, managed: [a, b]))
    check(already.actions.isEmpty && already.deferredAdded.isEmpty, "window already in the layout is not integrated again")
    let deferred = AutoDecide.decide(.init(previous: prev, current: cur, inputQuiet: false,
                                          paused: false, hasLayout: true, managed: [a]))
    check(deferred.actions.isEmpty && deferred.deferredAdded == [b], "new app waits for input to settle")
}
// Genuine fixed sizes remain supported after two matching observations.
do {
    let s = FakeSystem(windows: [window(1), window(2)])
    s.fixed[a] = CGSize(width: 230, height: 408)
    let k = ConstraintKnowledge()
    let result = run(s, k)
    check(result.outcome == .complete && s.frames[a] == CGRect(x: 0, y: 30, width: 230, height: 408)
          && s.frames[b] == CGRect(x: 230, y: 30, width: 1690, height: 1050),
          "confirmed fixed size keeps its size and the flexible window takes the rest")
}
do {
    let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let s = FakeSystem(windows: [window(1, app: "calc"), window(2, app: "editor"), window(3, app: "browser")], area: area)
    s.fixed[a] = CGSize(width: 230, height: 408)
    s.minimums[b] = CGSize(width: 700, height: 400)
    let result = ArrangeOperation(system: s, control: OperationControl(), knowledge: ConstraintKnowledge(),
                                  limits: OperationLimits(settleDelay: 0), sleep: { _ in }).run()
    let editor = s.frames[b]
    let browser = s.frames[WindowID(3)]
    check(result.outcome == .complete
          && s.frames[a] == CGRect(x: 0, y: 33, width: 230, height: 408)
          && editor?.width == 700 && browser?.width == 582
          && editor?.minX == 230 && browser?.minX == 930
          && editor?.height == 949 && browser?.height == 949,
          "fixed, large minimum, and flexible windows pack on a 1512-wide screen")
}
// The signed app left a 175pt gap on this display: fixed 230×440, then the
// minimum window at x=405. A later window must close that gap using the maximum
// already learned, including when it arrives in a second operation.
do {
    let area = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let s = FakeSystem(windows: [window(1, app: "a"), window(2, app: "b")], area: area)
    s.fixed[a] = CGSize(width: 230, height: 440)
    s.minimums[b] = CGSize(width: 700, height: 400)
    let k = ConstraintKnowledge()
    let limits = OperationLimits(settleDelay: 0)
    let firstOp = ArrangeOperation(system: s, control: OperationControl(), knowledge: k, limits: limits, sleep: { _ in })
    let first = firstOp.run()
    let firstPacked = s.frames[a] == CGRect(x: 0, y: 33, width: 230, height: 440)
        && s.frames[b] == CGRect(x: 230, y: 33, width: 1282, height: 949)
    let c = WindowID(3)
    s.snap.windows.append(window(3, app: "c"))
    s.frames[c] = CGRect(x: 80, y: 470, width: 520, height: 392)
    let second = ArrangeOperation(system: s, control: OperationControl(), knowledge: k, limits: limits,
                                  priorLayout: firstOp.resultingLayout, sleep: { _ in }).run()
    let editor = s.frames[b]
    let flex = s.frames[c]
    let edge = area.maxX
    check(first.outcome == .complete && firstPacked
          && second.outcome == .complete
          && s.frames[a] == CGRect(x: 0, y: 33, width: 230, height: 440)
          && editor?.minX == 230 && editor?.height == 949 && (editor?.width ?? 0) > 700
          && flex?.height == 949 && flex?.maxX == edge
          && s.frames[a]!.maxX == editor?.minX && editor?.maxX == flex?.minX,
          "second window closes the gap beside a confirmed 230x440 window")
}
// Pause and a Space change still prevent automatic enrollment.
do {
    let s = FakeSystem(windows: [window(1), window(2)])
    s.fixed[a] = CGSize(width: 1100, height: 408)
    let result = run(s, ConstraintKnowledge())
    check(result.outcome == .complete && s.frames[a] == CGRect(x: 0, y: 30, width: 1100, height: 408),
          "fixed height is confirmed even when minimum width replans")
}
do {
    let prev = Census(windows: [a: 10], frontmostPID: 10, spaceID: 7, frontWindow: a)
    var cur = Census(windows: [a: 10, b: 20], frontmostPID: 20, spaceID: 7, frontWindow: b)
    let paused = AutoDecide.decide(.init(previous: prev, current: cur, inputQuiet: true,
                                        paused: true, hasLayout: true, managed: [a]))
    check(paused.actions.isEmpty, "paused Space does not enroll new app")
    cur.spaceID = 8
    let changed = AutoDecide.decide(.init(previous: prev, current: cur, inputQuiet: true,
                                         paused: false, hasLayout: true, managed: [a]))
    check(changed.actions == [.rebase], "Space switch only rebases")
}
// The preview and execution must agree on app rules, including floating rules.
for action in ["ignore", "float"] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config.toml")
    try "[[rule]]\napp = \"test\"\naction = \"\(action)\"\n".write(to: config, atomically: true, encoding: .utf8)
    let system = CoordinatorSystem()
    let c = Coordinator(system: system, store: StateStore(root: root), configURL: config)
    _ = c.reloadConfig(source: "test")
    var inspection: Inspection?
    c.inspect { inspection = $0 }
    let deadline = Date().addingTimeInterval(5)
    while inspection == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(inspection?.targets.isEmpty == true && inspection?.excluded.count == 2,
          "preview applies \(action) app rule")
    check(system.writes == 0, "preview never writes frames")
    if case .started(let id) = c.arrange(source: "test") {
        check(drain(c), "rule-filtered arrangement completes")
        let result = c.result(id: id)
        check(result?.outcome == .nothingToDo && result?.excluded.count == 2 && system.writes == 0,
              "execution agrees with preview for \(action)")
    } else {
        check(false, "execution accepts rule-filtered inspection")
    }
}
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(root: root)
    var state = PersistedState()
    state.floating["7"] = [a]
    store.save(state)
    let system = CoordinatorSystem()
    let before = system.frames[a]
    let c = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"))
    c.limits.settleDelay = 0
    let preview = c.inspectSnapshot(system.snapshot())
    check(preview.targets.map(\.id) == [b], "preview excludes manually floated window")
    if case .started(let id) = c.arrange(source: "test") {
        check(drain(c), "floating-window arrangement completes")
        check(c.result(id: id)?.outcome == .complete && system.frames[a] == before,
              "execution preserves manually floated window")
    } else {
        check(false, "manual floating arrangement accepted")
    }
}
for (name, passed) in frameWriterChecks() { check(passed, name) }
for (name, passed) in try automaticIntegrationChecks() { check(passed, name) }
exit(failures == 0 ? 0 : 1)
