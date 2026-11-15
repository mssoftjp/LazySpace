import XCTest
import LayoutCore
@testable import MacSupport
import Operations
@testable import LazySpaceApp

/// When input cannot be observed, LazySpace tells whether Input Monitoring is switched off for it. Reading that is slow,
/// so it is read only while input is not fully observed: at once, then at most every 5 s.
final class InputMonitoringTests: XCTestCase {
    private var root: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                  takeCensus: system.census, takeOverview: { nil })
    }

    override func tearDownWithError() throws {
        coordinator.operationsQueue.sync {}
        try? FileManager.default.removeItem(at: root)
    }

    private func refresh(at seconds: TimeInterval) {
        coordinator.operationsQueue.sync { coordinator.refreshInputObservation(now: t0.addingTimeInterval(seconds)) }
    }

    private func cause() -> String? { coordinator.status().autoUnavailableCause }

    func testInputMonitoringOffIsTheCauseOnlyWithTheTapRefusedAndTrustGranted() {
        system.inputMode = .unavailable
        system.listenAccess = false
        XCTAssertEqual(cause(), "inputObservation", "unknown until the first answer")
        refresh(at: 0)
        XCTAssertEqual(cause(), "inputMonitoring")
        system.trusted = false
        XCTAssertEqual(cause(), "accessibility", "missing Accessibility still comes first")
        system.trusted = true
        system.listenAccess = true
        refresh(at: 5)
        XCTAssertEqual(cause(), "inputObservation", "allowed, but the tap was refused: the cause is unknown")
        system.inputMode = .mouseOnly
        XCTAssertNil(cause(), "automatic arrangement works with the mouse alone")
    }

    func testTheAnswerIsReadAtOnceThenEveryFiveSecondsAndNeverWhileInputIsObserved() {
        refresh(at: 0)
        XCTAssertEqual(system.listenAccessReads, 0, "never read while mouse and keyboard are observed")
        system.inputMode = .unavailable
        refresh(at: 1)
        XCTAssertEqual(system.listenAccessReads, 1, "read at once")
        refresh(at: 3)
        XCTAssertEqual(system.listenAccessReads, 1)
        refresh(at: 6)
        XCTAssertEqual(system.listenAccessReads, 2)
    }

    /// An old denial never shows after recovery, and Accessibility lost and granted again starts with no answer.
    func testTheKeptAnswerIsDroppedOnRecoveryAndWhenTrustIsLost() {
        system.inputMode = .unavailable
        system.listenAccess = false
        refresh(at: 0)
        XCTAssertEqual(cause(), "inputMonitoring")
        system.inputMode = .mouseAndKeyboard
        refresh(at: 1)
        system.inputMode = .unavailable
        XCTAssertEqual(cause(), "inputObservation", "the old answer was dropped")
        refresh(at: 2)
        XCTAssertEqual(cause(), "inputMonitoring")
        system.trusted = false
        coordinator.operationsQueue.sync { coordinator.tick() }
        system.trusted = true
        XCTAssertEqual(cause(), "inputObservation", "dropped while Accessibility was missing")
    }

    /// A start that brings keys back drops the answer at once, so a failure right after it does not reuse an old denial.
    func testASuccessfulStartDropsTheAnswerAtOnce() {
        system.inputMode = .unavailable
        system.listenAccess = false
        system.startResult = .mouseAndKeyboard
        refresh(at: 0)
        XCTAssertEqual(system.inputStarts, [false])
        system.inputMode = .unavailable
        XCTAssertEqual(cause(), "inputObservation", "the denial read before the start is gone")
    }

    /// Trust lost and granted again between ticks, seen only through the system notification, drops the answer too.
    func testATrustChangeSeenOnlyByTheNotificationDropsTheAnswer() {
        system.inputMode = .unavailable
        system.listenAccess = false
        refresh(at: 0)
        XCTAssertEqual(cause(), "inputMonitoring")
        system.trusted = false
        coordinator.checkTrust()
        coordinator.operationsQueue.sync {}
        system.trusted = true
        coordinator.checkTrust()
        coordinator.operationsQueue.sync {}
        XCTAssertEqual(cause(), "inputObservation")
    }

    /// Replacing drops a drag in progress, so it waits while a mouse button is held.
    func testMouseOnlyIsNotReplacedWhileAButtonIsHeld() {
        system.inputMode = .mouseOnly
        system.listenAccess = true
        system.anyMouseButtonHeld = true
        refresh(at: 0)
        refresh(at: 30)
        XCTAssertEqual(system.inputStarts, [])
        system.anyMouseButtonHeld = false
        refresh(at: 31)
        XCTAssertEqual(system.inputStarts, [true])
    }

    func testTheWaitStopsGrowingAtFiveMinutes() {
        system.inputMode = .mouseOnly
        system.listenAccess = true
        var t: TimeInterval = 0
        var waits: [TimeInterval] = []
        var last: TimeInterval?
        while system.inputStarts.count < 9 {
            let before = system.inputStarts.count
            refresh(at: t)
            if system.inputStarts.count > before { if let last { waits.append(t - last) }; last = t }
            t += 5
        }
        XCTAssertEqual(waits, [5, 10, 20, 40, 80, 160, 300, 300])
    }

    func testAnUnavailableTapIsCreatedAgainEveryFiveSeconds() {
        system.inputMode = .unavailable
        refresh(at: 10)
        refresh(at: 12)
        refresh(at: 15)
        XCTAssertEqual(system.inputStarts, [false, false])
    }

    /// Mouse only with listening allowed: replaced at once, then after 5, 10, 20 s; the wait starts over when the answer turns true again.
    func testMouseOnlyIsReplacedWithAGrowingWait() {
        system.inputMode = .mouseOnly
        system.listenAccess = true
        refresh(at: 0)
        XCTAssertEqual(system.inputStarts, [true], "at once")
        refresh(at: 4)
        refresh(at: 5)
        XCTAssertEqual(system.inputStarts, [true, true])
        refresh(at: 14)
        XCTAssertEqual(system.inputStarts.count, 2)
        refresh(at: 15)
        XCTAssertEqual(system.inputStarts.count, 3)
        system.listenAccess = false
        refresh(at: 20)
        refresh(at: 60)
        XCTAssertEqual(system.inputStarts.count, 3, "not replaced while listening is not allowed")
        system.listenAccess = true
        refresh(at: 65)
        XCTAssertEqual(system.inputStarts.count, 4, "turned true: at once again")
        refresh(at: 70)
        XCTAssertEqual(system.inputStarts.count, 5, "and the wait starts over at 5 s")
    }

    /// Asking would show the macOS prompt and add an Input Monitoring entry, which then refuses the tap until the user turns it on.
    func testLazySpaceNeverAsksMacOSForInputMonitoring() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let request = "CGRequest" + "ListenEventAccess"
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20, "the scan reached the sources")
        let asking = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(request) }.map(\.lastPathComponent)
        XCTAssertEqual(asking, [])
    }
}
