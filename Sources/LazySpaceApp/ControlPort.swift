import CryptoKit
import Foundation
import MacSupport
import Operations
import LayoutCore

/// Local IPC connecting the UI and CLI to the same operation path. Every wire request
/// carries a per-launch credential stored in an owner-only file; CFMessagePort alone
/// does not identify the sender.
enum ControlPort {
    static func name(for credential: String) -> String {
        let digest = SHA256.hash(data: Data(credential.utf8))
        return "jp.lazyspace.control.\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    struct Request: Codable {
        var cmd: String
        var arg: String?
        var windowID: WindowID?
        var expectedSpaceID: UInt64?
        var expectedPID: Int32?
        var desiredState: Bool?
        var requestID: String? = nil

        static let mutationCommands: Set<String> = ["edit.v3", "focus-window.v3", "arrange.v3", "integrate.v3"]

        var validationError: String? {
            let edit = arg.flatMap(EditCommand.parse)
            let stateCommands: [EditCommand] = [.toggleFloat, .toggleZoom, .fullscreen, .minimize]
            let mutation = Self.mutationCommands.contains(cmd)
            if requestID != nil, !mutation { return "This command does not accept a request ID." }
            if mutation {
                guard let requestID, MutationReceiptRegistry.isCanonicalToken(requestID) else { return "A canonical request ID is required." }
            }
            if cmd == "request-token.v3", arg != nil || windowID != nil || expectedSpaceID != nil || expectedPID != nil || desiredState != nil || requestID != nil {
                return "request-token accepts no arguments."
            }
            if windowID != nil {
                guard expectedSpaceID != nil, windowID!.raw > 0 else { return "A valid window target requires an expected Space." }
                if cmd != "focus-window.v3" && cmd != "edit.v3" { return "This command does not accept a window target." }
                if let edit, [.undo, .balance, .focusBack].contains(edit) { return "This edit does not accept a window target." }
                if case .space? = edit { return "Space switching does not accept a window target." }
            }
            if let expectedPID, windowID == nil || expectedPID <= 0 { return "A positive process ID requires a window target." }
            if let expectedSpaceID, expectedSpaceID == 0 || !mutation { return "Invalid Space precondition." }
            if desiredState != nil, cmd != "edit.v3" || edit == nil || !stateCommands.contains(edit!) { return "This command does not accept a desired state." }
            if cmd == "edit.v3" {
                guard let edit else { return "Invalid edit command." }
                if edit == .minimize && desiredState == false && windowID == nil { return "minimize off requires a window target." }
                if stateCommands.contains(edit) && desiredState == nil { return "An explicit desired state is required." }
            }
            if cmd == "focus-window.v3", windowID == nil { return "A window target is required." }
            if ["status", "show", "settings", "pause", "resume", "quit", "reload", "arrange.v3", "integrate.v3", "focus-window.v3", "inspect", "settle.v2", "request-token.v3"].contains(cmd), arg != nil { return "Unexpected argument." }
            return nil
        }
    }
    private struct WireRequest: Codable {
        var credential: String
        var request: Request
    }
    struct Settlement: Codable {
        var settled: Bool
        var spaceID: UInt64?
        var observedAt: Date
        var stableFor: TimeInterval
        var requiredStableFor: TimeInterval
        var blockers: [String]
    }
    struct Response: Codable {
        var ok: Bool
        var message: String
        var status: AppStatus?
        var inspection: Inspection?
        var spaces: SpaceOverview?
        var operationID: String?
        var settlement: Settlement? = nil
        var schemaVersion: Int = 2
        var code: String? = nil
        /// Session-scoped mutation receipt. Distinct from `operationID` and `result.id`.
        var requestID: String? = nil
        /// Terminal operation, when this response completed one. Its id stays the operation ID.
        var result: OperationResult? = nil
        /// Set only by the CLI: ms from the acceptance reply to receiving the completed result (CLI clock). Its origin differs from the server's `result.timeline`, so never add them.
        var receivedAt: Double? = nil
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Server (app side)

    private static var local: CFMessagePort?

    /// Accepted request keys (all fields of `Request`). Requests with unknown keys are rejected. Add new fields here too (a test checks).
    static let requestFields: Set<String> = ["cmd", "arg", "windowID", "expectedSpaceID", "expectedPID", "desiredState", "requestID"]

    static func decodeRequest(_ data: Data) -> Request? {
        let fields = requestFields
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: fields) else { return nil }
        return try? decoder.decode(Request.self, from: data)
    }

    /// Dispatch an already authenticated request (also used by request parsing tests).
    static func response(for data: Data, handler: (Request) -> Response) -> Response {
        guard let request = decodeRequest(data) else {
            return Response(ok: false, message: "Invalid request.", code: "invalid-request")
        }
        return handler(request)
    }

    static func authenticatedResponse(for data: Data, credential: String, handler: (Request) -> Response) -> Response {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["credential", "request"],
              let supplied = object["credential"] as? String,
              ControlCredential.matches(supplied, credential),
              let requestObject = object["request"] as? [String: Any],
              let requestData = try? JSONSerialization.data(withJSONObject: requestObject) else {
            return Response(ok: false, message: "Unauthorized control request.", code: "unauthorized")
        }
        return response(for: requestData, handler: handler)
    }

    static func wireData(_ request: Request, credential: String) throws -> Data {
        try encoder.encode(WireRequest(credential: credential, request: request))
    }

    static func startServer(handler: @escaping (Request) -> Response) -> Bool {
        let credential = ControlCredential.generate()
        // The box lives as long as the port (until the app quits); released only if the port was not created.
        let box = Unmanaged.passRetained(Box(credential: credential, handler: handler))
        var context = CFMessagePortContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, name(for: credential) as CFString, { _, _, data, info in
            guard let info, let data else { return nil }
            let box = Unmanaged<ControlPort.Box>.fromOpaque(info).takeUnretainedValue()
            let res = ControlPort.authenticatedResponse(for: data as Data, credential: box.credential, handler: box.handler)
            let out = (try? ControlPort.encoder.encode(res)) ?? Data()
            return Unmanaged.passRetained(out as CFData)
        }, &context, &shouldFree) else {
            box.release()
            return false
        }
        // A preexisting port must not be treated as our server or replace its credential.
        if shouldFree.boolValue {
            box.release()
            return false
        }
        guard ControlCredential.publish(credential, root: StateStore.defaultRoot) else {
            CFMessagePortInvalidate(port)
            box.release()
            return false
        }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        local = port
        return true
    }

    private final class Box {
        let credential: String
        let handler: (Request) -> Response
        init(credential: String, handler: @escaping (Request) -> Response) {
            self.credential = credential
            self.handler = handler
        }
    }

    // MARK: Client (CLI side)

    static func send(_ cmd: String, arg: String? = nil, windowID: WindowID? = nil, expectedSpaceID: UInt64? = nil,
                     expectedPID: Int32? = nil, desiredState: Bool? = nil, requestID: String? = nil, timeout: TimeInterval = 5) -> Response? {
        send(Request(cmd: cmd, arg: arg, windowID: windowID, expectedSpaceID: expectedSpaceID, expectedPID: expectedPID, desiredState: desiredState, requestID: requestID), timeout: timeout)
    }

    static func send(_ request: Request, timeout: TimeInterval = 5) -> Response? {
        guard let credential = ControlCredential.read(root: StateStore.defaultRoot) else { return nil }
        guard let remote = CFMessagePortCreateRemote(nil, name(for: credential) as CFString) else { return nil }
        guard let data = try? wireData(request, credential: credential) as CFData else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 1, data, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let replyData = reply?.takeRetainedValue() else { return nil }
        return try? decoder.decode(Response.self, from: replyData as Data)
    }
}
