import Darwin
import Foundation
import XCTest
@testable import LazySpaceApp

final class ControlCredentialTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LazySpace-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }

    private func chmodACL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testCredentialIsOwnerOnlyAndRotates() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ControlCredential.generate()
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(ControlPort.name(for: first).contains(first))
        XCTAssertTrue(ControlCredential.publish(first, root: root))
        XCTAssertEqual(ControlCredential.read(root: root), first)
        var info = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("control-credential").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let next = ControlCredential.generate()
        XCTAssertNotEqual(next, first)
        XCTAssertTrue(ControlCredential.publish(next, root: root))
        XCTAssertEqual(ControlCredential.read(root: root), next)
    }

    func testUnsafeCredentialPathsFailClosed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = ControlCredential.generate()
        let file = root.appendingPathComponent("control-credential")
        XCTAssertTrue(ControlCredential.publish(credential, root: root))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertNil(ControlCredential.read(root: root))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        try chmodACL(["+a", "everyone deny write", file.path])
        XCTAssertEqual(ControlCredential.read(root: root), credential)
        try chmodACL(["+a", "everyone allow read", file.path])
        XCTAssertNil(ControlCredential.read(root: root))
        try chmodACL(["-N", file.path])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertNil(ControlCredential.read(root: root))

        XCTAssertEqual(chmod(root.path, 0o777), 0)
        XCTAssertFalse(ControlCredential.publish(credential, root: root))
        XCTAssertNil(ControlCredential.read(root: root))
    }

    func testDenyOnlyDirectoryACLAllowsControl() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = ControlCredential.generate()
        XCTAssertTrue(ControlCredential.publish(credential, root: root))
        try chmodACL(["+a", "everyone deny delete", root.path])
        XCTAssertEqual(ControlCredential.read(root: root), credential)
        try chmodACL(["+a", "everyone allow write", root.path])
        XCTAssertNil(ControlCredential.read(root: root))
        XCTAssertFalse(ControlCredential.publish(ControlCredential.generate(), root: root))
        try chmodACL(["-N", root.path])
    }

    func testInstanceLockDiagnosesRunningApp() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = open(root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDONLY, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { if lock >= 0 { close(lock) } }
        XCTAssertFalse(ControlCredential.instanceLockIsHeld(root: root))
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(ControlCredential.instanceLockIsHeld(root: root))
        XCTAssertEqual(chmod(root.path, 0o777), 0)
        XCTAssertTrue(ControlCredential.instanceLockIsHeld(root: root))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        XCTAssertFalse(ControlCredential.instanceLockIsHeld(root: root))
    }

    func testRunningAppCommunicationErrorHasDistinctJSONCode() throws {
        let invocation = CLI.Invocation(cmd: "status", json: true)
        let output = CLI.execute(invocation, send: { _, _ in nil }, unavailable: "App is running but control is unavailable.", unavailableCode: "control-unavailable")
        XCTAssertEqual(output.exitCode, 2)
        let response = try ControlPort.decoder.decode(ControlPort.Response.self, from: Data(output.stdout.utf8))
        XCTAssertEqual(response.code, "control-unavailable")
        XCTAssertEqual(response.message, "App is running but control is unavailable.")
    }

    func testUnauthenticatedRequestNeverReachesHandler() throws {
        let credential = ControlCredential.generate()
        var calls = 0
        let handler: (ControlPort.Request) -> ControlPort.Response = { _ in
            calls += 1
            return ControlPort.Response(ok: true, message: "accepted")
        }
        let raw = Data(#"{"cmd":"status"}"#.utf8)
        XCTAssertEqual(ControlPort.authenticatedResponse(for: raw, credential: credential, handler: handler).code, "unauthorized")
        let wrong = Data(#"{"credential":"wrong","request":{"cmd":"status"}}"#.utf8)
        XCTAssertEqual(ControlPort.authenticatedResponse(for: wrong, credential: credential, handler: handler).code, "unauthorized")
        XCTAssertEqual(calls, 0)

        let valid = try ControlPort.wireData(ControlPort.Request(cmd: "status", arg: nil), credential: credential)
        XCTAssertTrue(ControlPort.authenticatedResponse(for: valid, credential: credential, handler: handler).ok)
        XCTAssertEqual(calls, 1)
        let extra = try JSONSerialization.data(withJSONObject: ["credential": credential, "request": ["cmd": "status", "extra": true]])
        XCTAssertEqual(ControlPort.authenticatedResponse(for: extra, credential: credential, handler: handler).code, "invalid-request")
        XCTAssertEqual(calls, 1)
    }
}
