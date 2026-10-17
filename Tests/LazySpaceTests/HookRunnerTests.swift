import Darwin
import XCTest
@testable import LazySpaceApp

/// Hooks and `[[exec]]` commands run as their own processes in macOS's eyes, with their own privacy permissions.
final class HookRunnerTests: XCTestCase {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Hooks can call Homebrew commands even with the PATH of an app launched as a login item.
    func testHookPATHFindsHomebrewFirstWithoutDuplicates() {
        XCTAssertEqual(HookRunner.hookPATH("/usr/bin:/bin:/usr/sbin:/sbin"), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(HookRunner.hookPATH("/usr/local/bin:/usr/bin"), "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
        XCTAssertEqual(HookRunner.hookPATH(nil), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// A configuration edit must not borrow LazySpace's Accessibility access: the command is responsible for itself.
    func testCommandsAreResponsibleForThemselves() throws {
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsible = unsafeBitCast(symbol, to: ResponsibleFn.self)
        let pid = try XCTUnwrap(HookRunner.run(["/bin/sleep", "5"], environment: [:]) { _ in })
        defer { kill(pid, SIGKILL) }
        XCTAssertEqual(responsible(pid), pid)
        XCTAssertNotEqual(responsible(getpid()), pid)
    }

    /// Names without a slash are looked up in PATH, and the hook's variables arrive.
    func testCommandsFindPATHAndReceiveTheirVariables() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("out").path
        var problems: [String] = []
        HookRunner.run(["sh", "-c", "printf %s \"$LAZYSPACE_MODE\" > \"$OUT\""], environment: ["LAZYSPACE_MODE": "resize", "OUT": out]) { problems.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOfFile: out)) != "resize", Date() < deadline { usleep(20_000) }
        XCTAssertEqual(try String(contentsOfFile: out), "resize")
        XCTAssertEqual(problems, [])
    }

    func testAFailingOrMissingCommandIsReportedInOneSentence() throws {
        let reported = expectation(description: "exit status")
        HookRunner.run(["/usr/bin/false"], environment: [:]) { problem in
            XCTAssertEqual(problem, "Hook /usr/bin/false exited with status 1.")
            reported.fulfill()
        }
        wait(for: [reported], timeout: 5)
        var problems: [String] = []
        XCTAssertNil(HookRunner.run(["/nonexistent/hook"], environment: [:]) { problems.append($0) })
        XCTAssertEqual(problems, ["Could not start hook /nonexistent/hook: No such file or directory"])
    }

    /// If macOS ever stops offering the separation, hooks do not run rather than borrow LazySpace's permissions.
    func testWithoutSeparationNothingRuns() throws {
        let saved = HookRunner.disclaim
        HookRunner.disclaim = { _ in false }
        defer { HookRunner.disclaim = saved }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var problems: [String] = []
        XCTAssertNil(HookRunner.run(["/bin/mkdir", folder.path], environment: [:]) { problems.append($0) })
        XCTAssertEqual(problems, ["Could not start hook /bin/mkdir \(folder.path): macOS cannot run it apart from LazySpace's permissions."])
        usleep(200_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
