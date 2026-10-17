import Foundation
import XCTest

/// Applies the wording rules (W1-W10) to product source strings and user documents.
/// What each rule forbids is noted at its definition below.
final class WordingRulesTests: XCTestCase {
    struct Violation: CustomStringConvertible {
        var file: String
        var line: Int
        var rule: String
        var text: String
        var description: String { "\(file):\(line): \(rule): \(text)" }
    }

    /// Exceptions: exact match of file and string (interpolations as `\(…)`), always with a reason.
    static let exceptions: [(file: String, text: String, reason: String)] = [
        ("Sources/MacSupport/SpaceControl.swift", #"Space \(…)"#,
         "Diagnostic fallback: identifies a Space without a desktop number by its ID (not a numbered desktop)."),
    ]

    static let sourceModules = ["Copy", "LayoutCore", "Operations", "Settings", "MacSupport", "LazySpaceApp", "LazySpace"]
    static let japaneseDocuments = ["README.ja.md", "docs/guide.ja.md"]
    static let englishDocuments = ["README.md", "Tests/README.md", "docs/scripting.md", "docs/guide.md"]

    /// Stands in for interpolations and inline code in documents; W7 treats it as a Latin letter.
    static let placeholder: Unicode.Scalar = "\u{E000}"

    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: - Checks

    func testProductJapaneseStrings() throws {
        let found = try Self.sourceLiterals().filter { $0.text.contains(where: Self.isJapanese) }
            .flatMap { Self.violations(in: $0, rules: Self.japaneseRules + [Self.w8]) }
        report(found, kind: "product Japanese strings")
    }

    func testProductStringsInAnyLanguage() throws {
        let found = try Self.sourceLiterals().flatMap { Self.violations(in: $0, rules: Self.anyLanguageRules) }
        report(found, kind: "product strings")
    }

    func testJapaneseDocuments() throws {
        let found = try Self.japaneseDocuments.flatMap { path in
            try Self.documentLines(path).filter { $0.text.contains(where: Self.isJapanese) }
                .flatMap { Self.violations(in: $0, rules: Self.japaneseRules) }
        }
        report(found, kind: "Japanese documents")
    }

    func testEnglishDocuments() throws {
        let found = try Self.englishDocuments.flatMap { path in
            try Self.documentLines(path).flatMap { Self.violations(in: $0, rules: Self.anyLanguageRules) }
        }
        report(found, kind: "English documents")
    }

    /// Code comments are written in English.
    func testCodeCommentsAreEnglish() throws {
        let found = try Self.codeComments().filter { $0.text.contains(where: Self.isJapanese) }
        XCTAssertEqual(found.count, 0, "Japanese in code comments:\n" + found.map { "\($0.file):\($0.line): \($0.display)" }.joined(separator: "\n"))
    }

    /// The comment scanners report comments only: not text inside raw, multiline, or interpolated strings, heredocs, or `$#`.
    func testCommentScannersFindCommentsOnly() {
        func swift(_ source: String) -> [String] { Self.lex(source, file: "S.swift").comments.map(\.display) }
        func hash(_ source: String, _ file: String) -> [String] { Self.hashComments(in: source, file: file).map(\.display) }

        XCTAssertEqual(swift(##"let a = #"quoted " // not"#"##), [])
        XCTAssertEqual(swift(###"let b = ##"a "# // not"## // yes"###), ["// yes"])
        XCTAssertEqual(swift(#"let c = "\(1 /* inside */)""#), ["/* inside */"])
        XCTAssertEqual(swift("let d = #\"\"\"\n// not\n\"\"\"#\n// yes"), ["// yes"])
        XCTAssertEqual(Self.lex(##"let e = #"say "hi" \n \#(x)"#"##, file: "S.swift").literals.first?.display, #"say "hi" \n \(…)"#)

        XCTAssertEqual(hash("x = 1# yes\ns = '#not'\nt = \"\"\"\n# not\n\"\"\"\n", "a.py"), ["# yes"])
        XCTAssertEqual(hash("#!/bin/sh\necho ok;# yes\necho $# ${#x} a#b\ncat <<'EOF'\n# not\nEOF\n# yes\n", "a.sh"), ["# yes", "# yes"])
        XCTAssertEqual(hash("cat <<-END\n\t# not\n\tEND\n", "b.sh"), [])
        XCTAssertEqual(hash("url = \"https://x#y\" # yes\n", "a.rb"), ["# yes"])
        XCTAssertEqual(hash("# yes\nfoo#bar\n", ".gitignore"), ["# yes"])
    }

    /// Sentences joined at run time use `Copy.sentenceSeparator` (a space in English, nothing in Japanese); only command arguments join with a space.
    /// Per-string checks cannot see the joined result, so the source is checked for how it joins.
    func testSentencesAreNotJoinedWithASpace() throws {
        let allowed = ["Sources/LazySpaceApp/Integration.swift"]
        var found: [String] = []
        for module in Self.sourceModules {
            let directory = Self.root.appendingPathComponent("Sources/\(module)")
            for file in try FileManager.default.contentsOfDirectory(atPath: directory.path).filter({ $0.hasSuffix(".swift") }).sorted() {
                let path = "Sources/\(module)/\(file)"
                let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains(#"joined(separator: " ")"#) {
                    if allowed.contains(path), line.contains("argv") { continue }
                    found.append("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(found, [], "join sentences with Copy.sentenceSeparator:\n" + found.joined(separator: "\n"))
    }

    func testExceptionListStaysShortAndExplained() {
        XCTAssertLessThanOrEqual(Self.exceptions.count, 5)
        for exception in Self.exceptions { XCTAssertFalse(exception.reason.isEmpty, exception.text) }
    }

    /// The scanner and the rules themselves, including comments, interpolations, and multiline strings.
    func testScannerAppliesEachRule() {
        let source = #"""
        // コメントの ウィンドウ は対象外
        let a = L("Window", "この Space にウィンドウはありません。")
        let b = L("Switched to Space \(n).", "\(label) へ切り替えました。 次へ")
        let c = "全画面で “Desktop” を「デスクトップに切り替え」"
        let d = """
             先頭の空白
            Move left a space
            """
        let e = "\(L("x", "Mission Control のショートカット"))" /* "ウィンドウ" */
        """#
        let literals = Self.literals(in: source, file: "Sample.swift")
        XCTAssertEqual(literals.map(\.line), [2, 2, 3, 3, 4, 5, 9, 9, 9])
        let rules = literals.flatMap { literal in
            literal.text.contains(where: Self.isJapanese)
                ? Self.violations(in: literal, rules: Self.japaneseRules + [Self.w8] + Self.anyLanguageRules)
                : Self.violations(in: literal, rules: Self.anyLanguageRules)
        }.map { "\($0.line):\($0.rule)" }
        XCTAssertEqual(Set(rules), ["2:W1", "2:W4", "2:W7", "3:W10", "3:W7", "3:W8", "4:W2", "4:W3", "4:W5", "4:W6", "6:W8", "7:W9", "9:W7"])
        let doc = Self.documentLines(text: "日本語の `code` です\n```\nウィンドウ\n```\nmacOSの設定", file: "Doc.md")
        XCTAssertEqual(doc.flatMap { Self.violations(in: $0, rules: Self.japaneseRules) }.map { "\($0.line):\($0.rule)" }, ["1:W7", "1:W7"])
        XCTAssertEqual(doc.count, 2, "fenced code is skipped")
    }

    private func report(_ found: [Violation], kind: String) {
        let counts = Dictionary(grouping: found, by: \.rule).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        print("WordingRules \(kind): \(found.count) violations \(counts)")
        guard !found.isEmpty else { return }
        XCTFail("\(found.count) wording violations in \(kind) (\(counts)):\n" + found.map(\.description).joined(separator: "\n"))
    }

    // MARK: - Rules

    struct Rule {
        var id: String
        var test: ([Unicode.Scalar]) -> [Int]
    }

    struct Text {
        var file: String
        var line: Int
        /// Line of each character (to point at the violating line in multiline strings).
        var lines: [Int]
        var text: [Unicode.Scalar]
        var display: String {
            String(String.UnicodeScalarView(text)).replacingOccurrences(of: String(Character(placeholder)), with: #"\(…)"#)
        }
    }

    static let japaneseRules: [Rule] = [
        // W1: the nonstandard katakana spelling of "window".
        Rule(id: "W1") { find("ウィンドウ", in: $0) },
        // W2: the kanji word for "full screen"; use the katakana word macOS uses.
        Rule(id: "W2") { find("全画面", in: $0) },
        // W3: curly double quotes; Japanese uses corner brackets.
        Rule(id: "W3") { s in s.indices.filter { s[$0] == "“" || s[$0] == "”" } },
        // W4: the word Space / Spaces ("LazySpace" excluded); Japanese uses the macOS term.
        Rule(id: "W4") { word("Space", plural: true, in: $0) },
        // W5: the word Desktop / Desktops; Japanese uses the katakana word.
        Rule(id: "W5") { word("Desktop", plural: true, in: $0) },
        // W6: "switch to the desktop" without a number; the macOS item is "Switch to Desktop N".
        Rule(id: "W6") { find("デスクトップに切り替え", in: $0) },
        // W7: a single half-width space between Japanese and a Latin letter, digit, interpolation, or inline code (two or more are allowed for alignment).
        Rule(id: "W7") { s in
            s.indices.dropFirst().dropLast().filter { i in
                s[i] == " " && ((isJapanese(s[i - 1]) && isLatin(s[i + 1])) || (isLatin(s[i - 1]) && isJapanese(s[i + 1])))
            }
        },
    ]

    // W8: a half-width space after a Japanese period or comma, or at the start or end of a string next to Japanese. Join sentences with `Copy.sentenceSeparator`.
    static let w8 = Rule(id: "W8") { s in
        var hits = s.indices.dropFirst().filter { s[$0] == " " && (s[$0 - 1] == "。" || s[$0 - 1] == "、") }
        if s.count > 1, s[0] == " ", isJapanese(s[1]) { hits.append(0) }
        if s.count > 1, s[s.count - 1] == " ", isJapanese(s[s.count - 2]) { hits.append(s.count - 1) }
        return hits
    }

    static let anyLanguageRules: [Rule] = [
        // W9: "Move left/right a space" with a lowercase space; the macOS item is "Move left a Space".
        Rule(id: "W9") { s in
            ["Move left a space", "Move right a space", "Move left/right a space"].flatMap { phrase in
                find(phrase, in: s).filter { $0 + phrase.unicodeScalars.count >= s.count || !isLetter(s[$0 + phrase.unicodeScalars.count]) }
            }
        },
        // W10: "Space " followed by a digit or interpolation; a numbered one is "Desktop 3" (`Copy.desktop`).
        Rule(id: "W10") { s in
            find("Space ", in: s).filter { i in
                let next = i + 6
                return (i == 0 || !isLetter(s[i - 1])) && next < s.count && (("0"..."9").contains(s[next]) || s[next] == placeholder)
            }
        },
    ]

    static func violations(in text: Text, rules: [Rule]) -> [Violation] {
        let display = text.display
        if exceptions.contains(where: { $0.file == text.file && $0.text == display }) { return [] }
        return rules.flatMap { rule in
            rule.test(text.text).map { Violation(file: text.file, line: text.lines.isEmpty ? text.line : text.lines[min($0, text.lines.count - 1)], rule: rule.id, text: display) }
        }
    }

    static func isJapanese(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }

    static func isJapanese(_ c: Character) -> Bool { c.unicodeScalars.contains { isJapanese($0) } }

    static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }

    static func isLatin(_ c: Unicode.Scalar) -> Bool { isLetter(c) || ("0"..."9").contains(c) || c == placeholder }

    static func find(_ needle: String, in s: [Unicode.Scalar]) -> [Int] {
        let n = Array(needle.unicodeScalars)
        guard n.count <= s.count else { return [] }
        return (0...(s.count - n.count)).filter { Array(s[$0..<($0 + n.count)]) == n }
    }

    /// A word not adjacent to Latin letters ("LazySpace" does not count).
    static func word(_ word: String, plural: Bool, in s: [Unicode.Scalar]) -> [Int] {
        find(word, in: s).filter { i in
            var end = i + word.unicodeScalars.count
            if plural, end < s.count, s[end] == "s" { end += 1 }
            return (i == 0 || !isLetter(s[i - 1])) && (end >= s.count || !isLetter(s[end]))
        }
    }

    // MARK: - Source strings

    static func sourceLiterals() throws -> [Text] {
        var out: [Text] = []
        for module in sourceModules {
            let directory = root.appendingPathComponent("Sources/\(module)")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
            for file in files {
                let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                out += literals(in: text, file: "Sources/\(module)/\(file)")
            }
        }
        return out
    }

    /// String literals in Swift source. Skips comments, replaces interpolations, and also extracts strings inside them.
    static func literals(in source: String, file: String) -> [Text] {
        lex(source, file: file).literals
    }

    static func lex(_ source: String, file: String) -> (literals: [Text], comments: [Text]) {
        let s = Array(source.unicodeScalars)
        var i = 0
        var line = 1
        var out: [Text] = []
        var comments: [Text] = []

        func at(_ k: Int, _ text: String) -> Bool {
            let t = Array(text.unicodeScalars)
            return k + t.count <= s.count && Array(s[k..<(k + t.count)]) == t
        }

        func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        func skipComment() {
            let start = i, startLine = line
            defer { comments.append(Text(file: file, line: startLine, lines: [], text: Array(s[start..<i]))) }
            if at(i, "//") {
                while i < s.count, s[i] != "\n" { i += 1 }
                return
            }
            var depth = 0
            repeat {
                if at(i, "/*") { depth += 1; i += 2 }
                else if at(i, "*/") { depth -= 1; i += 2 }
                else { advance() }
            } while depth > 0 && i < s.count
        }

        /// Reads from right after `"` or `"""` (and `hashes` `#` before it for a raw string).
        func literal(multiline: Bool, hashes: Int = 0) {
            let start = line
            let pounds = String(repeating: "#", count: hashes)
            let close = (multiline ? "\"\"\"" : "\"") + pounds
            let escape = "\\" + pounds
            var text: [Unicode.Scalar] = []
            var lines: [Int] = []
            var rawLineStarts: [Int] = []
            func append(_ c: Unicode.Scalar) { text.append(c); lines.append(line) }
            while i < s.count {
                if at(i, close) {
                    i += close.unicodeScalars.count
                    break
                }
                if !multiline, s[i] == "\n" { break }
                if at(i, escape) {
                    i += escape.unicodeScalars.count
                    guard i < s.count else { break }
                    switch s[i] {
                    case "(":
                        i += 1
                        interpolation()
                        append(placeholder)
                    case "n": append("\n"); i += 1
                    case "t": append("\t"); i += 1
                    case "u":
                        var hex = ""
                        i += 2
                        while i < s.count, s[i] != "}" { hex.unicodeScalars.append(s[i]); i += 1 }
                        i += 1
                        if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { append(scalar) }
                    case "\n": advance()
                    default: append(s[i]); i += 1
                    }
                    continue
                }
                if s[i] == "\n" { append("\n"); advance(); rawLineStarts.append(text.count); continue }
                append(s[i]); i += 1
            }
            if multiline { (text, lines) = stripIndentation(text, lines, rawLineStarts) }
            out.append(Text(file: file, line: start, lines: lines, text: text))
        }

        /// Reads a string literal starting at `i` (with optional raw-string `#`s). False if none starts here.
        func stringLiteral() -> Bool {
            var hashes = 0
            while i + hashes < s.count, s[i + hashes] == "#" { hashes += 1 }
            if at(i + hashes, "\"\"\"") { i += hashes + 3; literal(multiline: true, hashes: hashes); return true }
            if i + hashes < s.count, s[i + hashes] == "\"" { i += hashes + 1; literal(multiline: false, hashes: hashes); return true }
            return false
        }

        /// From right after `\(` to the matching `)`, extracting strings and comments inside.
        func interpolation() {
            var depth = 1
            while i < s.count {
                if at(i, "//") || at(i, "/*") { skipComment(); continue }
                if stringLiteral() { continue }
                if s[i] == "(" { depth += 1 }
                if s[i] == ")" { depth -= 1; if depth == 0 { i += 1; return } }
                advance()
            }
        }

        while i < s.count {
            if at(i, "//") || at(i, "/*") { skipComment(); continue }
            if stringLiteral() { continue }
            advance()
        }
        return (out.sorted { $0.line < $1.line }, comments)
    }

    /// Multiline strings: drop the first and last newline and remove the closing delimiter's indentation from each line (as Swift does).
    static func stripIndentation(_ text: [Unicode.Scalar], _ lines: [Int], _ starts: [Int]) -> ([Unicode.Scalar], [Int]) {
        guard let last = starts.last else { return (text, lines) }
        let indent = text.count - last
        var keep = Array(repeating: true, count: text.count)
        if let first = starts.first { keep[first - 1] = false }
        if last > 0 { keep[last - 1] = false }
        for start in starts {
            var k = start
            while k < text.count, k < start + indent, text[k] == " " { keep[k] = false; k += 1 }
        }
        let kept = text.indices.filter { keep[$0] }
        return (kept.map { text[$0] }, kept.map { lines[$0] })
    }

    // MARK: - Comments

    /// Comments in Swift files, and `#` comments in scripts and `.gitignore`. Untracked `*.local.*` files are skipped.
    static func codeComments() throws -> [Text] {
        var out: [Text] = []
        for directory in ["Sources", "Tests", "script"] {
            let base = root.appendingPathComponent(directory)
            guard let paths = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] else { continue }
            for path in paths.sorted() where !path.contains(".local.") {
                let file = "\(directory)/\(path)"
                let text = { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
                if path.hasSuffix(".swift") { out += lex(try text(), file: file).comments }
                else if [".sh", ".py", ".rb"].contains(where: path.hasSuffix) { out += hashComments(in: try text(), file: file) }
            }
        }
        out += lex(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8), file: "Package.swift").comments
        out += hashComments(in: try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8), file: ".gitignore")
        return out
    }

    /// `#` comments outside strings, by file type. Shell: a `#` starting a word, outside quotes and heredocs. Python and Ruby: any `#`
    /// outside quotes (strings may span lines; `\'\'\'` and `"""` in Python). `.gitignore`: lines starting with `#`. The shebang is not a comment.
    static func hashComments(in source: String, file: String) -> [Text] {
        let lines = source.components(separatedBy: "\n")
        if file.hasSuffix(".gitignore") {
            return lines.enumerated().filter { $0.element.hasPrefix("#") }
                .map { Text(file: file, line: $0.offset + 1, lines: [], text: Array($0.element.unicodeScalars)) }
        }
        let shell = file.hasSuffix(".sh")
        var out: [Text] = []
        var quote: [Unicode.Scalar]?
        var heredoc: (word: String, tabs: Bool)?
        for (index, line) in lines.enumerated() where !(index == 0 && line.hasPrefix("#!")) {
            if let doc = heredoc {
                if (doc.tabs ? String(line.drop { $0 == "\t" }) : line) == doc.word { heredoc = nil }
                continue
            }
            let s = Array(line.unicodeScalars)
            func at(_ k: Int, _ text: [Unicode.Scalar]) -> Bool { k + text.count <= s.count && Array(s[k..<(k + text.count)]) == text }
            var k = 0
            while k < s.count {
                if let q = quote {
                    if s[k] == "\\", q != ["\'"] || !shell { k += 2; continue }
                    if at(k, q) { k += q.count; quote = nil; continue }
                } else if !shell, at(k, ["\"", "\"", "\""]) || at(k, ["\'", "\'", "\'"]) {
                    quote = Array(s[k..<(k + 3)]); k += 3; continue
                } else if s[k] == "\"" || s[k] == "\'" {
                    quote = [s[k]]
                } else if s[k] == "\\" {
                    k += 2; continue
                } else if shell, at(k, ["<", "<"]), !at(k, ["<", "<", "<"]) {
                    let rest = String(String.UnicodeScalarView(s[(k + 2)...]))
                    let tabs = rest.hasPrefix("-")
                    let word = rest.dropFirst(tabs ? 1 : 0).drop { $0 == " " }.prefix { !" ;|&)".contains($0) }
                        .filter { $0 != "\'" && $0 != "\"" }
                    if !word.isEmpty { heredoc = (String(word), tabs) }
                } else if s[k] == "#", !shell || k == 0 || " \t;&|()".unicodeScalars.contains(s[k - 1]) {
                    out.append(Text(file: file, line: index + 1, lines: [], text: Array(s[k...])))
                    break
                }
                k += 1
            }
        }
        return out
    }

    // MARK: - Documents

    static func documentLines(_ path: String) throws -> [Text] {
        documentLines(text: try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), file: path)
    }

    /// Lines outside fenced code blocks, with inline code replaced.
    static func documentLines(text: String, file: String) -> [Text] {
        var out: [Text] = []
        var fenced = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || trimmed.isEmpty { continue }
            var scalars: [Unicode.Scalar] = []
            var inCode = false
            for c in raw.unicodeScalars {
                if c == "`" {
                    if !inCode { scalars.append(placeholder) }
                    inCode.toggle()
                } else if !inCode {
                    scalars.append(c)
                }
            }
            out.append(Text(file: file, line: index + 1, lines: [], text: scalars))
        }
        return out
    }
}
