import Copy
import Foundation

/// The TOML subset settings need: tables, arrays of tables, basic values, one-line arrays, one-line inline tables.
/// Unsupported syntax is an error with its line number, never silently skipped.
public enum TOML {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { L(.tomlDescription(String(line), message)) }
    }

    public static func parse(_ text: String) throws -> [String: Any] {
        var root: [String: Any] = [:]
        var currentPath: [String] = []
        var currentIsArrayTable = false
        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else { throw ParseError(line: lineNo, message: L(.tomlMissingArrayTableClose)) }
                currentPath = try parseKeyPath(String(line.dropFirst(2).dropLast(2)), line: lineNo)
                currentIsArrayTable = true
                try appendArrayTable(&root, path: currentPath, line: lineNo)
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(line: lineNo, message: L(.tomlMissingTableClose)) }
                currentPath = try parseKeyPath(String(line.dropFirst().dropLast()), line: lineNo)
                currentIsArrayTable = false
                try ensureTable(&root, path: currentPath, line: lineNo)
                continue
            }
            guard let eq = topLevelEqualsIndex(line) else { throw ParseError(line: lineNo, message: L(.tomlExpectedKeyValue)) }
            let keyText = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let keyPath = try parseKeyPath(keyText, line: lineNo)
            let value = try parseValue(valueText, line: lineNo)
            try set(&root, tablePath: currentPath, inArrayTable: currentIsArrayTable, keyPath: keyPath, value: value, line: lineNo)
        }
        return root
    }

    // MARK: - Structure

    private static func ensureTable(_ root: inout [String: Any], path: [String], line: Int) throws {
        // `[name]` after `[[name]]` would otherwise reopen the last element of the array of tables.
        guard let last = path.last else { throw ParseError(line: line, message: L(.tomlTheTableNameIsEmpty)) }
        root = try withTable(root, path: Array(path.dropLast()), line: line) { parent in
            if parent[last] is [[String: Any]] { throw ParseError(line: line, message: L(.tomlIsAnArrayTableWrite(last, last))) }
            if parent[last] != nil, parent[last] as? [String: Any] == nil { throw ParseError(line: line, message: L(.tomlIsNotATable(last))) }
            var p = parent
            p[last] = parent[last] ?? [String: Any]()
            return p
        }
    }

    private static func appendArrayTable(_ root: inout [String: Any], path: [String], line: Int) throws {
        guard let last = path.last else { throw ParseError(line: line, message: L(.tomlTheTableNameIsEmpty)) }
        root = try withTable(root, path: Array(path.dropLast()), line: line) { parent in
            var p = parent
            var arr = (p[last] as? [[String: Any]]) ?? []
            if p[last] != nil, p[last] as? [[String: Any]] == nil { throw ParseError(line: line, message: L(.tomlIsNotAnArrayTable(last))) }
            arr.append([:])
            p[last] = arr
            return p
        }
    }

    /// Takes out the table at path, transforms it, and puts it back. For an array of tables, the last element.
    private static func withTable(_ root: [String: Any], path: [String], line: Int, _ f: ([String: Any]) throws -> [String: Any]) throws -> [String: Any] {
        guard let first = path.first else { return try f(root) }
        var r = root
        if let arr = r[first] as? [[String: Any]] {
            guard var last = arr.last else { throw ParseError(line: line, message: L(.tomlTheArrayTableIsEmpty(first))) }
            last = try withTable(last, path: Array(path.dropFirst()), line: line, f)
            var copy = arr
            copy[copy.count - 1] = last
            r[first] = copy
            return r
        }
        let child = (r[first] as? [String: Any]) ?? [:]
        if r[first] != nil, r[first] as? [String: Any] == nil { throw ParseError(line: line, message: L(.tomlIsNotATable(first))) }
        r[first] = try withTable(child, path: Array(path.dropFirst()), line: line, f)
        return r
    }

    private static func set(_ root: inout [String: Any], tablePath: [String], inArrayTable: Bool, keyPath: [String], value: Any, line: Int) throws {
        root = try withTable(root, path: tablePath, line: line) { table in
            var t = table
            try setKey(&t, keyPath: keyPath, value: value, line: line)
            return t
        }
    }

    private static func setKey(_ table: inout [String: Any], keyPath: [String], value: Any, line: Int) throws {
        guard let first = keyPath.first else { return }
        if keyPath.count == 1 {
            if table[first] != nil { throw ParseError(line: line, message: L(.tomlDuplicateKey(first))) }
            table[first] = value
            return
        }
        var child = (table[first] as? [String: Any]) ?? [:]
        try setKey(&child, keyPath: Array(keyPath.dropFirst()), value: value, line: line)
        table[first] = child
    }

    // MARK: - Lexing

    static func codeAndComment(_ line: String) -> (code: String, comment: String) {
        guard let end = firstTopLevel("#", in: line) else { return (line, "") }
        return (String(line[..<end]), String(line[end...]))
    }

    private static func stripComment(_ line: String) -> String {
        codeAndComment(line).code
    }

    static func topLevelEqualsIndex(_ line: String) -> String.Index? {
        firstTopLevel("=", in: line)
    }

    /// The first target outside strings. `\"` inside a basic string ("...") does not end it.
    private static func firstTopLevel(_ target: Character, in line: String) -> String.Index? {
        var inSingle = false, inDouble = false, escaped = false
        for i in line.indices {
            let ch = line[i]
            if inDouble {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inDouble = false }
                continue
            }
            if inSingle {
                if ch == "'" { inSingle = false }
                continue
            }
            if ch == target { return i }
            if ch == "\"" { inDouble = true }
            else if ch == "'" { inSingle = true }
        }
        return nil
    }

    static func parseKeyPath(_ text: String, line: Int) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote: Character? = nil
        for ch in text {
            if let q = inQuote {
                if ch == q { inQuote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(ch)
            }
        }
        guard inQuote == nil else { throw ParseError(line: line, message: L(.tomlMissingClosingQuote)) }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        if parts.contains(where: \.isEmpty) { throw ParseError(line: line, message: L(.tomlTheKeyNameIsEmpty)) }
        return parts
    }

    static func parseValue(_ text: String, line: Int) throws -> Any {
        var scanner = Scanner(text: text, line: line)
        let v = try scanner.value()
        scanner.skipSpaces()
        guard scanner.atEnd else { throw ParseError(line: line, message: L(.tomlUnexpectedTextAfterTheValue(scanner.rest))) }
        return v
    }

    struct Scanner {
        var chars: [Character]
        var i = 0
        let line: Int
        init(text: String, line: Int) { chars = Array(text); self.line = line }
        var atEnd: Bool { i >= chars.count }
        var rest: String { String(chars[min(i, chars.count)...]) }
        mutating func skipSpaces() { while !atEnd, chars[i] == " " || chars[i] == "\t" { i += 1 } }

        mutating func value() throws -> Any {
            skipSpaces()
            guard !atEnd else { throw TOML.ParseError(line: line, message: L(.tomlMissingValue)) }
            switch chars[i] {
            case "\"", "'": return try string()
            case "[": return try array()
            case "{": return try inlineTable()
            default: return try scalar()
            }
        }

        mutating func string() throws -> String {
            let q = chars[i]; i += 1
            var out = ""
            while !atEnd {
                let ch = chars[i]; i += 1
                if ch == q { return out }
                if ch == "\\", q == "\"", !atEnd {
                    let e = chars[i]; i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u", "U":
                        let count = e == "u" ? 4 : 8
                        guard i + count <= chars.count, let code = UInt32(String(chars[i..<(i + count)]), radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw TOML.ParseError(line: line, message: L(.tomlInvalidEscape(String(describing: e))))
                        }
                        i += count
                        out.unicodeScalars.append(scalar)
                    default:
                        throw TOML.ParseError(line: line, message: L(.tomlUnsupportedEscape(String(describing: e))))
                    }
                } else {
                    out.append(ch)
                }
            }
            throw TOML.ParseError(line: line, message: L(.tomlMissingClosingQuote))
        }

        mutating func array() throws -> [Any] {
            i += 1
            var out: [Any] = []
            while true {
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L(.tomlMissingArrayClose)) }
                if chars[i] == "]" { i += 1; return out }
                out.append(try value())
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L(.tomlMissingArrayClose)) }
                if chars[i] == "," { i += 1; continue }
                if chars[i] == "]" { i += 1; return out }
                throw TOML.ParseError(line: line, message: L(.tomlArrayItemsMustBeSeparated))
            }
        }

        mutating func inlineTable() throws -> [String: Any] {
            i += 1
            var out: [String: Any] = [:]
            while true {
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L(.tomlMissingClosingForTheInline)) }
                if chars[i] == "}" { i += 1; return out }
                var key = ""
                while !atEnd, chars[i] != "=" { key.append(chars[i]); i += 1 }
                guard !atEnd else { throw TOML.ParseError(line: line, message: L(.tomlMissingAfterAKeyIn)) }
                i += 1
                let path = try TOML.parseKeyPath(key, line: line)
                let v = try value()
                var table = out
                try TOML.setKey(&table, keyPath: path, value: v, line: line)
                out = table
                skipSpaces()
                if !atEnd, chars[i] == "," { i += 1; continue }
                if !atEnd, chars[i] == "}" { continue }
                throw TOML.ParseError(line: line, message: L(.tomlInlineTableItemsMustBe))
            }
        }

        mutating func scalar() throws -> Any {
            var token = ""
            while !atEnd, chars[i] != ",", chars[i] != "]", chars[i] != "}", chars[i] != " ", chars[i] != "\t" { token.append(chars[i]); i += 1 }
            if token == "true" { return true }
            if token == "false" { return false }
            let cleaned = token.replacingOccurrences(of: "_", with: "")
            if let n = Int(cleaned) { return n }
            if let d = Double(cleaned) { return d }
            throw TOML.ParseError(line: line, message: L(.tomlCouldNotReadTheValue(token)))
        }
    }
}
