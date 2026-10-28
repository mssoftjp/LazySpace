import Foundation
import Operations

/// The `--json` output (`docs/scripting.md`). The CLI owns this shape: window IDs are numbers, rectangles have named fields,
/// and outcomes are strings. The wire to the app and the state file keep Swift's encodings (`{"raw": N}`, `[[x, y], [width, height]]`,
/// `{"complete": {}}`): the state file's layouts store window IDs that way, and `StateStore.load` starts empty when they do not decode.
/// Only the places listed here are rewritten, and a value there in another shape stops the output instead of passing through.
enum PublicJSON {
    static let schemaVersion = 3

    struct ShapeError: Error, Equatable {
        /// Where the unexpected value is, such as `.status.focusedWindow`.
        var path: String
    }

    /// A JSON document. Integers are kept apart from doubles, so a 64-bit ID never passes through floating point.
    enum Value: Codable, Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case uint(UInt64)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int64.self) { self = .int(value) }
            else if let value = try? container.decode(UInt64.self) { self = .uint(value) }
            else if let value = try? container.decode(Double.self) { self = .double(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .uint(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        var isNumber: Bool {
            switch self {
            case .int, .uint, .double: true
            default: false
            }
        }
    }

    /// The response in this schema. Encoded with `ControlPort.encoder` before and after, so doubles keep `JSONEncoder`'s spelling
    /// (`0.1`; `JSONSerialization` would write `0.10000000000000001`).
    static func text(_ response: ControlPort.Response) throws -> String {
        let tree = try ControlPort.decoder.decode(Value.self, from: ControlPort.encoder.encode(response))
        return String(decoding: try ControlPort.encoder.encode(rewrite(tree)), as: UTF8.self)
    }

    /// Printed instead of a response that cannot be written in this schema. Keeps its receipt and operation IDs.
    static func failureText(for response: ControlPort.Response) -> String {
        var object: [String: Value] = [
            "ok": .bool(false), "code": .string(ResultCode.internalError.rawValue),
            "message": .string("The reply could not be written as JSON."), "schemaVersion": .int(Int64(schemaVersion)),
        ]
        if let id = response.requestID { object["requestID"] = .string(id) }
        if let id = response.operationID { object["operationID"] = .string(id) }
        guard let data = try? ControlPort.encoder.encode(Value.object(object)) else {
            return "{\"code\" : \"\(ResultCode.internalError.rawValue)\", \"ok\" : false, \"schemaVersion\" : \(schemaVersion)}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func rewrite(_ response: Value) throws -> Value {
        var object = try members(response, "")
        try replace(&object, "status", "", status)
        try replace(&object, "inspection", "", inspection)
        try replace(&object, "spaces", "", spaces)
        try replace(&object, "result", "", result)
        object["schemaVersion"] = .int(Int64(schemaVersion))
        return .object(object)
    }

    // MARK: - Places

    private static func status(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replace(&object, "focusedWindow", path, windowID)
        try replace(&object, "zoomed", path, windowID)
        try replaceEach(&object, "floating", path, windowID)
        try replaceEach(&object, "waiting", path, windowID)
        try replace(&object, "lastResult", path, result)
        return .object(object)
    }

    private static func result(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replace(&object, "outcome", path, outcome)
        try replace(&object, "workArea", path, rect)
        try replaceEach(&object, "targets", path) { target, path in
            var object = try members(target, path)
            try replace(&object, "id", path, windowID)
            for key in ["before", "planned", "after"] { try replace(&object, key, path, rect) }
            return .object(object)
        }
        try replaceEach(&object, "excluded", path, exclusion)
        return .object(object)
    }

    private static func inspection(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replace(&object, "snapshot", path) { snapshot, path in
            var object = try members(snapshot, path)
            try replace(&object, "workArea", path, rect)
            try replaceEach(&object, "windows", path, window)
            return .object(object)
        }
        try replaceEach(&object, "targets", path, window)
        try replaceEach(&object, "excluded", path, exclusion)
        return .object(object)
    }

    private static func spaces(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replaceEach(&object, "spaces", path) { entry, path in
            var object = try members(entry, path)
            try replaceEach(&object, "windowIDs", path, windowID)
            return .object(object)
        }
        try replaceEach(&object, "unknown", path, windowID)
        return .object(object)
    }

    private static func exclusion(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replace(&object, "window", path, window)
        return .object(object)
    }

    private static func window(_ value: Value, _ path: String) throws -> Value {
        var object = try members(value, path)
        try replace(&object, "id", path, windowID)
        try replace(&object, "frame", path, rect)
        return .object(object)
    }

    // MARK: - Shapes

    /// `{"raw": N}` becomes N.
    private static func windowID(_ value: Value, _ path: String) throws -> Value {
        guard case .object(let object) = value, object.count == 1, let raw = object["raw"] else { throw ShapeError(path: path) }
        switch raw {
        case .int(let number) where number >= 0: return raw
        case .uint: return raw
        default: throw ShapeError(path: path)
        }
    }

    /// `[[x, y], [width, height]]` becomes `{"x", "y", "width", "height"}`.
    private static func rect(_ value: Value, _ path: String) throws -> Value {
        guard case .array(let parts) = value, parts.count == 2, case .array(let origin) = parts[0], case .array(let size) = parts[1],
              origin.count == 2, size.count == 2, (origin + size).allSatisfy(\.isNumber) else { throw ShapeError(path: path) }
        return .object(["x": origin[0], "y": origin[1], "width": size[0], "height": size[1]])
    }

    /// Swift encodes `Outcome.notPossible` as `{"notPossible": {}}`; the output is `"notPossible"`.
    private static let outcomeNames: Set<String> = Set(Outcome.allCases.compactMap { outcome in
        guard let data = try? JSONEncoder().encode(outcome), case .object(let object)? = try? JSONDecoder().decode(Value.self, from: data) else { return nil }
        return object.keys.first
    })

    private static func outcome(_ value: Value, _ path: String) throws -> Value {
        guard case .object(let object) = value, object.count == 1, let entry = object.first,
              entry.value == .object([:]), outcomeNames.contains(entry.key) else { throw ShapeError(path: path) }
        return .string(entry.key)
    }

    // MARK: - Walking

    private static func members(_ value: Value, _ path: String) throws -> [String: Value] {
        guard case .object(let object) = value else { throw ShapeError(path: path) }
        return object
    }

    /// Rewrites `object[key]` when it is present. JSON null stays null.
    private static func replace(_ object: inout [String: Value], _ key: String, _ path: String,
                                _ transform: (Value, String) throws -> Value) rethrows {
        guard let value = object[key], value != .null else { return }
        object[key] = try transform(value, path + "." + key)
    }

    /// Rewrites every element of the array `object[key]` when it is present. JSON null stays null.
    private static func replaceEach(_ object: inout [String: Value], _ key: String, _ path: String,
                                    _ transform: (Value, String) throws -> Value) throws {
        guard let value = object[key], value != .null else { return }
        guard case .array(let elements) = value else { throw ShapeError(path: path + "." + key) }
        object[key] = .array(try elements.enumerated().map { try transform($0.element, "\(path).\(key)[\($0.offset)]") })
    }
}
