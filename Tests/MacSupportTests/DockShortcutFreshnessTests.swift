import XCTest
import Darwin
@testable import MacSupport

/// Dock freshness compares only the settings file's modification time with this session's Dock launch time. Unreadable means unknown.
final class DockShortcutFreshnessTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    private func readers(modified: Date?, pids: [pid_t?], start: Date?) -> (DockShortcutFreshness.Readers, () -> Int) {
        var reads = 0
        var remaining = pids
        let readers = DockShortcutFreshness.Readers(preferencesModified: { modified }, dockPID: {
            reads += 1
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }, startTime: { _ in start })
        return (readers, { reads })
    }

    func testNewerOlderAndEqualTimes() {
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started.addingTimeInterval(1), pids: [7, 7], start: started).0), .preferencesNewer)
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started.addingTimeInterval(-1), pids: [7, 7], start: started).0), .current)
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started, pids: [7, 7], start: started).0), .current, "equal is not newer")
    }

    /// Unreadable modification time (no file, no permission), no Dock, or no launch time (including another user's Dock) -> unknown.
    func testAnythingUnreadableIsUnknown() {
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: nil, pids: [7, 7], start: started).0), .unknown)
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started.addingTimeInterval(1), pids: [nil, nil], start: started).0), .unknown)
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started.addingTimeInterval(1), pids: [7, 7], start: nil).0), .unknown)
    }

    /// The Dock pid is read before and after sampling; if it changed (the Dock restarted), unknown.
    func testADockRestartDuringSamplingIsUnknown() {
        let (changed, reads) = readers(modified: started.addingTimeInterval(1), pids: [7, 8], start: started)
        XCTAssertEqual(DockShortcutFreshness.read(changed), .unknown)
        XCTAssertEqual(reads(), 2, "the pid is read before and after the other samples")
        XCTAssertEqual(DockShortcutFreshness.read(readers(modified: started.addingTimeInterval(1), pids: [7, nil], start: started).0), .unknown, "the Dock quit")
        XCTAssertEqual(DockShortcutFreshness.evaluate(preferencesModified: started.addingTimeInterval(1), dockStarted: started, dockBefore: 7, dockAfter: 7), .preferencesNewer)
    }

    /// The launch-time reader (`kinfo_proc`) reads this process and ignores other users' processes (launchd, root). Read-only.
    func testTheSystemStartTimeReaderChecksTheOwner() throws {
        let mine = try XCTUnwrap(DockShortcutFreshness.Readers.system.startTime(getpid()))
        XCTAssertLessThanOrEqual(mine, Date())
        XCTAssertGreaterThan(mine, Date().addingTimeInterval(-86_400 * 30))
        if getuid() != 0 { XCTAssertNil(DockShortcutFreshness.Readers.system.startTime(1), "a process of another user is not this session's Dock") }
        XCTAssertNil(DockShortcutFreshness.Readers.system.startTime(-1))
    }
}
