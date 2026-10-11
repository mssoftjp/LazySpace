import Foundation
import LayoutCore
import Operations
import Settings
@testable import LazySpace

/// Shared by XCTest and the CLT-only regression runner. All window writes use the test double.
func automaticIntegrationChecks() throws -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let a = WindowID(1), b = WindowID(2), c = WindowID(3), d = WindowID(4)

    func drain(_ coordinator: Coordinator) -> Bool {
        // A failed insertion may enqueue its fallback after the first barrier.
        for _ in 0..<2 {
            let done = DispatchSemaphore(value: 0)
            coordinator.operationsQueue.async { done.signal() }
            let deadline = Date().addingTimeInterval(10)
            while done.wait(timeout: .now()) != .success {
                if Date() >= deadline { return false }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        return !coordinator.isBusy
    }

    func withCoordinator(_ body: (Coordinator, CoordinatorSystem, StateStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Layout(root: .split(.horizontal, children: [.leaf(a), .leaf(b)], ratios: [0.5, 0.5]))
        store.save(state)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"),
                                      takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        try body(coordinator, system, store)
        checks.append(("automatic integration operations finish", drain(coordinator)))
    }

    // With no anchor, Zoom used to hide the arriving window while reporting success;
    // with an anchor, it tiled the windows but left the saved Zoom flag set.
    for anchor in [a, nil] as [WindowID?] {
        try withCoordinator { coordinator, system, store in
            _ = coordinator.edit(.toggleZoom, source: "test")
            checks.append(("Zoom setup completes", drain(coordinator) && system.frames[a]?.width == 1920))
            system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
            _ = coordinator.integrateForeground([c], beside: anchor)
            checks.append(("foreground integration finishes with anchor \(String(describing: anchor))", drain(coordinator)))
            let tiled = [a, b, c].compactMap { system.frames[$0] }
            let coversRow = tiled.count == 3
                && tiled.map(\.width).reduce(0, +) == 1920
                && tiled.allSatisfy { $0.height == 1080 }
            checks.append(("new foreground window exits Zoom and tiles all windows", coordinator.lastResult?.outcome == .complete
                           && Set(coordinator.state.layouts["7"]?.windowIDs ?? []) == [a, b, c]
                           && coversRow))
            checks.append(("successful integration clears in-memory and persisted Zoom", coordinator.state.zoomed["7"] == nil && store.load().zoomed["7"] == nil))
            let ids = coordinator.state.layouts["7"]?.windowIDs
            checks.append(("foreground insertion preserves placement preference", ids == (anchor == nil ? [a, b, c] : [a, c, b])))
        }
    }

    // An input interruption must leave the new window reachable via explicit Integrate.
    // It must not replay the cancelled operation after input stops.
    try withCoordinator { coordinator, system, _ in
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        coordinator.operationsQueue.suspend()
        _ = coordinator.integrateForeground([c], beside: a)
        system.inputActivityCount += 1
        coordinator.operationsQueue.resume()
        checks.append(("input interruption finishes", drain(coordinator)))
        checks.append(("interrupted foreground window is not banned from a later placement", coordinator.lastResult?.stopReason == .userInput
                       && system.writes == 0 && coordinator.waiting.isEmpty
                       && coordinator.state.layouts["7"]?.windowIDs == [a, b]))
        _ = coordinator.integrateWaiting(source: "test")
        checks.append(("explicit integration recovers the waiting foreground window", drain(coordinator)
                       && coordinator.lastResult?.outcome == .complete && coordinator.waiting.isEmpty
                       && Set(coordinator.state.layouts["7"]?.windowIDs ?? []) == [a, b, c]))
    }

    // Some tiles may verify before a later AX failure. The layout is committed only
    // as a whole, so even a verified new tile must stay waiting after a partial result.
    try withCoordinator { coordinator, system, _ in
        system.frames[a] = CGRect(x: 73, y: 0, width: 960, height: 1080)
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        system.frames[d] = CGRect(x: 200, y: 200, width: 600, height: 400)
        system.refusedWrites = [a]
        _ = coordinator.integrateForeground([c, d], beside: a)
        checks.append(("partial integration finishes", drain(coordinator)))
        checks.append(("refused position produces a partial result", coordinator.lastResult?.outcome == .partial))
        checks.append(("partial integration keeps the new windows out of the waiting list", coordinator.lastResult?.outcome == .partial
                       && coordinator.waiting.isEmpty && coordinator.state.layouts["7"]?.windowIDs == [a, b]))
        _ = coordinator.integrateForeground([c, d], beside: a)
        checks.append(("retry while the write is still refused does not park them as waiting", drain(coordinator)
                       && coordinator.lastResult?.outcome == .partial && coordinator.waiting.isEmpty
                       && coordinator.state.layouts["7"]?.windowIDs == [a, b]))
        system.refusedWrites = []
        _ = coordinator.integrateForeground([c, d], beside: a)
        checks.append(("the next observation can tile the windows that did not commit", drain(coordinator)
                       && coordinator.lastResult?.outcome == .complete && coordinator.waiting.isEmpty
                       && Set(coordinator.state.layouts["7"]?.windowIDs ?? []) == [a, b, c, d]))
    }

    // A constrained row may require a fallback, but must not renew an expired input gate.
    for interrupt in [false, true] {
        try withCoordinator { coordinator, system, _ in
            system.frames[c] = CGRect(x: 100, y: 100, width: 960, height: 400)
            for id in [a, b, c] {
                coordinator.knowledge.recordPushback(id: id, requested: CGRect(x: 0, y: 0, width: 600, height: 100),
                                                    actual: CGRect(x: 0, y: 0, width: 800, height: 100),
                                                    spaceID: 7, workArea: system.currentWorkArea(), tolerance: 1)
            }
            var snapshots = 0
            system.onSnapshot = {
                snapshots += 1
                if interrupt && snapshots == 1 {
                    // Input arrives just after the first gate checked its counter,
                    // before the planner discovers that the anchored row cannot fit.
                    system.onSpaceRead = {
                        system.onSpaceRead = nil
                        system.inputActivityCount += 1
                    }
                }
            }
            _ = coordinator.integrateForeground([c], beside: a)
            checks.append(("layout fallback finishes", drain(coordinator)))
            if interrupt {
                checks.append(("insertion stops before writing when input arrives", system.writes == 0
                               && coordinator.waiting.isEmpty && coordinator.state.layouts["7"]?.windowIDs == [a, b]))
            } else {
                checks.append(("overfull insertion floats the new window and keeps the row", snapshots == 1
                               && coordinator.lastResult?.outcome == .complete
                               && coordinator.state.layouts["7"]?.windowIDs == [a, b]
                               && coordinator.state.floating["7"] == [c]))
            }
        }
    }

    try withCoordinator { coordinator, system, store in
        system.minimums[a] = CGSize(width: 800, height: 700)
        system.minimums[b] = CGSize(width: 800, height: 700)
        system.minimums[c] = CGSize(width: 800, height: 700)
        system.frames[c] = CGRect(x: 100, y: 100, width: 800, height: 700)
        _ = coordinator.integrateForeground([c], beside: nil)
        checks.append(("unfit foreground integration finishes", drain(coordinator)))
        checks.append(("unfit integration floats the new window and keeps the existing row",
                       coordinator.lastResult?.outcome == .complete
                       && coordinator.lastResult?.message.contains("kept in place as floating") == true
                       && coordinator.state.layouts["7"]?.windowIDs == [a, b]
                       && coordinator.state.floating["7"] == [c]
                       && coordinator.waiting.isEmpty
                       && !store.load().sizeFacts.isEmpty))
    }

    try withCoordinator { coordinator, system, store in
        system.minimums[a] = CGSize(width: 800, height: 700)
        system.minimums[b] = CGSize(width: 800, height: 700)
        system.minimums[c] = CGSize(width: 800, height: 700)
        system.frames[c] = CGRect(x: 100, y: 100, width: 800, height: 700)
        _ = coordinator.integrateForeground([c], beside: a)
        checks.append(("unfit anchored integration finishes", drain(coordinator)))
        checks.append(("anchored integration floats the new window without rebuilding the row",
                       coordinator.lastResult?.outcome == .complete
                       && coordinator.lastResult?.message.contains("returned to where they were before") != true
                       && coordinator.state.layouts["7"]?.windowIDs == [a, b]
                       && coordinator.state.floating["7"] == [c]
                       && coordinator.waiting.isEmpty
                       && !store.load().sizeFacts.isEmpty))
    }

    // Excluded or disappearing windows are not failed tiling candidates.
    try withCoordinator { coordinator, system, _ in
        var config = Config()
        config.rules = [Config.Rule(app: "test", action: .ignore)]
        try config.render().write(to: coordinator.configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        _ = coordinator.integrateForeground([c], beside: a)
        checks.append(("ignored foreground window never becomes waiting", drain(coordinator) && coordinator.waiting.isEmpty && system.writes == 0))
    }
    try withCoordinator { coordinator, system, _ in
        _ = coordinator.integrateForeground([c], beside: a)
        checks.append(("already closed foreground window never becomes waiting", drain(coordinator) && coordinator.waiting.isEmpty && system.writes == 0))
    }
    try withCoordinator { coordinator, system, store in
        _ = coordinator.edit(.toggleZoom, source: "test")
        _ = drain(coordinator)
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        coordinator.operationsQueue.suspend()
        _ = coordinator.integrateForeground([c], beside: a)
        system.inputActivityCount += 1
        coordinator.operationsQueue.resume()
        checks.append(("failed integration preserves the existing Zoom state", drain(coordinator)
                       && coordinator.state.zoomed["7"] == a && store.load().zoomed["7"] == a))
        _ = coordinator.integrateWaiting(source: "test")
        checks.append(("explicit recovery finishes", drain(coordinator)))
        let recovered = [a, b, c].compactMap { system.frames[$0] }
        checks.append(("explicit recovery reveals the waiting window and exits Zoom",
                       coordinator.waiting.isEmpty && coordinator.state.zoomed["7"] == nil
                       && store.load().zoomed["7"] == nil
                       && recovered.count == 3
                       && recovered.map(\.width).reduce(0, +) == 1920
                       && recovered.allSatisfy { $0.height == 1080 }))
    }
    try withCoordinator { coordinator, system, store in
        _ = coordinator.edit(.toggleZoom, source: "test")
        _ = drain(coordinator)
        _ = coordinator.edit(.resize(.horizontal, 0.1), source: "test")
        checks.append(("layout edit exits Zoom consistently with visible tiles", drain(coordinator)
                       && coordinator.lastResult?.outcome == .complete
                       && coordinator.state.zoomed["7"] == nil && store.load().zoomed["7"] == nil
                       && system.frames[a]?.width == 1152 && system.frames[b]?.width == 768))
    }
    try withCoordinator { coordinator, system, _ in
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        coordinator.operationsQueue.suspend()
        _ = coordinator.integrateForeground([c], beside: a)
        system.space = 8
        coordinator.operationsQueue.resume()
        checks.append(("Space switch does not carry failed integration into destination", drain(coordinator)
                       && coordinator.waiting.isEmpty && coordinator.state.layouts["8"] == nil && system.writes == 0))
    }
    try withCoordinator { coordinator, system, _ in
        system.frames[c] = CGRect(x: 100, y: 100, width: 600, height: 400)
        coordinator.operationsQueue.suspend()
        _ = coordinator.integrateForeground([c], beside: a)
        coordinator.pause()
        coordinator.resume()
        coordinator.operationsQueue.resume()
        checks.append(("Pause and Resume do not resurrect pending integration", drain(coordinator)
                       && coordinator.waiting.isEmpty
                       && coordinator.state.layouts["7"]?.windowIDs == [a, b]
                       && system.writes == 0))
    }
    return checks
}
