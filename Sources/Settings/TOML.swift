import Copy
import Foundation

/// The TOML subset settings need: tables, arrays of tables, basic values, one-line arrays, one-line inline tables.
/// Unsupported syntax is an error with its line number, never silently skipped.
public enum TOML {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { L("Line \(line): \(message)", "\(line)行目: \(message)") }
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
                guard line.hasSuffix("]]") else { throw ParseError(line: lineNo, message: L("Missing closing ]] for the array table.", "配列テーブルを閉じる]]がありません。")) }
                currentPath = try parseKeyPath(String(line.dropFirst(2).dropLast(2)), line: lineNo)
                currentIsArrayTable = true
                try appendArrayTable(&root, path: currentPath, line: lineNo)
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ParseError(line: lineNo, message: L("Missing closing ] for the table.", "テーブルを閉じる]がありません。")) }
                currentPath = try parseKeyPath(String(line.dropFirst().dropLast()), line: lineNo)
                currentIsArrayTable = false
                try ensureTable(&root, path: currentPath, line: lineNo)
                continue
            }
            guard let eq = topLevelEqualsIndex(line) else { throw ParseError(line: lineNo, message: L("Expected key = value.", "key = valueの形ではありません。")) }
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
        guard let last = path.last else { throw ParseError(line: line, message: L("The table name is empty.", "テーブル名が空です。")) }
        root = try withTable(root, path: Array(path.dropLast()), line: line) { parent in
            if parent[last] is [[String: Any]] { throw ParseError(line: line, message: L("\(last) is an array table; write [[\(last)]].", "\(last)は配列テーブルです。[[\(last)]]と書いてください。")) }
            if parent[last] != nil, parent[last] as? [String: Any] == nil { throw ParseError(line: line, message: L("\(last) is not a table.", "\(last)はテーブルではありません。")) }
            var p = parent
            p[last] = parent[last] ?? [String: Any]()
            return p
        }
    }

    private static func appendArrayTable(_ root: inout [String: Any], path: [String], line: Int) throws {
        guard let last = path.last else { throw ParseError(line: line, message: L("The table name is empty.", "テーブル名が空です。")) }
        root = try withTable(root, path: Array(path.dropLast()), line: line) { parent in
            var p = parent
            var arr = (p[last] as? [[String: Any]]) ?? []
            if p[last] != nil, p[last] as? [[String: Any]] == nil { throw ParseError(line: line, message: L("\(last) is not an array table.", "\(last)は配列テーブルではありません。")) }
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
            guard var last = arr.last else { throw ParseError(line: line, message: L("The array table \(first) is empty.", "配列テーブル\(first)が空です。")) }
            last = try withTable(last, path: Array(path.dropFirst()), line: line, f)
            var copy = arr
            copy[copy.count - 1] = last
            r[first] = copy
            return r
        }
        let child = (r[first] as? [String: Any]) ?? [:]
        if r[first] != nil, r[first] as? [String: Any] == nil { throw ParseError(line: line, message: L("\(first) is not a table.", "\(first)はテーブルではありません。")) }
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
            if table[first] != nil { throw ParseError(line: line, message: L("Duplicate key: \(first).", "\(first)が重複しています。")) }
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
        guard inQuote == nil else { throw ParseError(line: line, message: L("Missing closing quote.", "閉じる引用符がありません。")) }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        if parts.contains(where: \.isEmpty) { throw ParseError(line: line, message: L("The key name is empty.", "キー名が空です。")) }
        return parts
    }

    static func parseValue(_ text: String, line: Int) throws -> Any {
        var scanner = Scanner(text: text, line: line)
        let v = try scanner.value()
        scanner.skipSpaces()
        guard scanner.atEnd else { throw ParseError(line: line, message: L("Unexpected text after the value: \(scanner.rest)", "値の後に余分な文字があります: \(scanner.rest)")) }
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
            guard !atEnd else { throw TOML.ParseError(line: line, message: L("Missing value.", "値がありません。")) }
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
                            throw TOML.ParseError(line: line, message: L("Invalid \\\(e) escape.", "\\\(e)のエスケープが正しくありません。"))
                        }
                        i += count
                        out.unicodeScalars.append(scalar)
                    default:
                        throw TOML.ParseError(line: line, message: L("Unsupported escape \\\(e).", "\\\(e)は使えないエスケープです。"))
                    }
                } else {
                    out.append(ch)
                }
            }
            throw TOML.ParseError(line: line, message: L("Missing closing quote.", "閉じる引用符がありません。"))
        }

        mutating func array() throws -> [Any] {
            i += 1
            var out: [Any] = []
            while true {
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L("Missing closing ] for the array.", "配列を閉じる]がありません。")) }
                if chars[i] == "]" { i += 1; return out }
                out.append(try value())
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L("Missing closing ] for the array.", "配列を閉じる]がありません。")) }
                if chars[i] == "," { i += 1; continue }
                if chars[i] == "]" { i += 1; return out }
                throw TOML.ParseError(line: line, message: L("Array items must be separated by commas.", "配列の区切りが正しくありません。"))
            }
        }

        mutating func inlineTable() throws -> [String: Any] {
            i += 1
            var out: [String: Any] = [:]
            while true {
                skipSpaces()
                guard !atEnd else { throw TOML.ParseError(line: line, message: L("Missing closing } for the inline table.", "インラインテーブルを閉じる } がありません。")) }
                if chars[i] == "}" { i += 1; return out }
                var key = ""
                while !atEnd, chars[i] != "=" { key.append(chars[i]); i += 1 }
                guard !atEnd else { throw TOML.ParseError(line: line, message: L("Missing = after a key in the inline table.", "インラインテーブルのキーの後に = がありません。")) }
                i += 1
                let path = try TOML.parseKeyPath(key, line: line)
                let v = try value()
                var table = out
                try TOML.setKey(&table, keyPath: path, value: v, line: line)
                out = table
                skipSpaces()
                if !atEnd, chars[i] == "," { i += 1; continue }
                if !atEnd, chars[i] == "}" { continue }
                throw TOML.ParseError(line: line, message: L("Inline table items must be separated by commas.", "インラインテーブルの区切りが正しくありません。"))
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
            throw TOML.ParseError(line: line, message: L("Could not read the value: \(token)", "値を解釈できません: \(token)"))
        }
    }
}
