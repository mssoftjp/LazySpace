import XCTest
import LayoutCore
@testable import MacSupport
import Operations
import Settings
@testable import LazySpaceApp

/// Apps that resize a window on their own once it is shown. An Electron app that saved its last window as maximized opens a new
/// window at the whole work area and maximizes it again about 0.2 s after showing it, which is usually after LazySpace placed it.
final class SelfResizingWindowTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StateStore(root: root)
        var state = PersistedState()
        state.layouts["7"] = Planner.rowLayout([WindowID(1)], rows: 1)
        store.save(state)
        system = CoordinatorSystem()
        system.frames = [WindowID(1): full]
        coordinator = Coordinator(system: system, store: store, configURL: root.appendingPathComponent("config.toml"), takeCensus: system.census, takeOverview: { nil })
        coordinator.limits.settleDelay = 0
        _ = coordinator.arrange(source: "test")
        drain()
        tick(); tick(); tick()
        coordinator.noteSpaceArrival(at: Date().addingTimeInterval(-2))
    }

    override func tearDownWithError() throws {
        drain()
        try FileManager.default.removeItem(at: root)
    }

    private func drain() {
        let done = expectation(description: "Operations drained")
        coordinator.operationsQueue.async { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func tick() {
        coordinator.operationsQueue.sync { coordinator.tick() }
        drain()
    }

    private func mouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)!
        system.input.record(type, event: event)
        system.inputActivityCount += 1
    }

    private let left = CGRect(x: 0, y: 0, width: 960, height: 1080)
    private let right = CGRect(x: 960, y: 0, width: 960, height: 1080)

    /// The app maximizes the new window while LazySpace reads back its own write: it is written again and stays tiled.
    func testANewWindowThatZoomsDuringTheReadbackStaysTiled() {
        var zoomed = false
        system.onWrite = { [unowned self] id, frame in
            guard id == WindowID(2), !zoomed, frame.width < full.width else { return }
            zoomed = true
            system.frames[WindowID(2)] = full
        }
        system.frames[WindowID(2)] = full
        for _ in 0..<6 { tick() }
        XCTAssertTrue(zoomed)
        XCTAssertEqual(system.frames[WindowID(1)], left)
        XCTAssertEqual(system.frames[WindowID(2)], right)
        XCTAssertEqual(coordinator.state.layouts["7"]?.windowIDs, [WindowID(1), WindowID(2)])
        XCTAssertNil(coordinator.state.floating["7"], "not floated as a window that cannot fit")
        XCTAssertEqual(coordinator.knowledge.snapshot[WindowID(2)]?.minimum ?? .zero, .zero, "one larger readback is not a minimum")
    }

    /// A click (on "New Window", say) and then the app maximizing the window LazySpace has placed: the zoom is put back and
    /// never taken as the user widening the window.
    func testAZoomAfterAClickIsPutBackInsteadOfWideningTheWindow() {
        mouse(.leftMouseDown)
        tick()
        mouse(.leftMouseUp)
        system.frames[WindowID(2)] = full
        for _ in 0..<4 { tick() }
        XCTAssertEqual(system.frames[WindowID(2)], right, "placed beside window 1")
        system.frames[WindowID(2)] = full
        tick()
        Thread.sleep(forTimeInterval: coordinator.quietInterval + 0.05)
        for _ in 0..<3 { tick() }
        XCTAssertEqual(system.frames[WindowID(1)], left, "window 1 keeps its half")
        XCTAssertEqual(system.frames[WindowID(2)], right, "put back")
        XCTAssertNotEqual(coordinator.lastResult?.kind, "mouse-resize")
    }
}
