import CoreGraphics
import Copy
import Foundation

/// Rewrites only changed values while keeping the file's lines and comments.
/// Shapes the parser cannot read, or changes that need tables reorganized, are errors so the caller leaves the text alone.
public enum ConfigDocument {
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// `source` must load as `previous`; the result loads as `next`.
    public static func applying(_ next: Config, to source: String, replacing previous: Config) throws -> String {
        if previous == next { return source }
        let doc = try Document(source)
        try doc.apply(from: previous, to: next)
        let output = doc.text
        let loaded: Config
        do { loaded = try Config.load(toml: output) } catch {
            throw problem(L("Settings could not keep this file's formatting while saving. Edit the file, then choose Reload. Nothing was saved.",
                            "このファイルの体裁を保ったまま保存できません。ファイルを編集してから「再読み込み」を選んでください。保存していません。"))
        }
        guard loaded == next else {
            throw problem(L("Settings could not update every changed value without rewriting the file. Edit the file, then choose Reload. Nothing was saved.",
                            "変更をファイルの形を保ったまま反映できません。ファイルを編集してから「再読み込み」を選んでください。保存していません。"))
        }
        return output
    }

    private static func problem(_ message: String) -> Problem { Problem(message: message) }

    private static func literal(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private static func number(_ value: Double) -> String { Config.number(value) }

    private static func stringArray(_ values: [String]) -> String {
        "[" + values.map(literal).joined(separator: ", ") + "]"
    }

    private final class Document {
        struct Row {
            var content: String
            var ending: String
        }

        struct Assignment {
            var line: Int
            var absolute: [String]
            var array: (name: [String], index: Int)?
            var relative: [String]
        }

        struct Block {
            var header: Int
            var fields: [String: Int]
            var lastData: Int
        }

        var rows: [Row]
        private var assignments: [Assignment] = []
        private var headers: [(line: Int, path: [String], array: Bool)] = []
        private var deletions: Set<Int> = []
        private var insertions: [(index: Int, lines: [String])] = []

        init(_ text: String) throws {
            rows = Self.split(text)
            try parse()
        }

        var text: String { rows.map { $0.content + $0.ending }.joined() }

        func apply(from previous: Config, to next: Config) throws {
            if previous.modes != next.modes {
                throw problem(L("Settings does not edit binding modes. Change those tables in the file, then choose Reload. Nothing was saved.",
                                "設定画面ではバインディングモードを編集できません。モードの表はファイルで変更し、「再読み込み」を選んでください。保存していません。"))
            }
            try applyScalars(from: previous, to: next)
            try applyGaps(from: previous, to: next)
            try applyTables(from: previous, to: next)
            try applyKeys(from: previous, to: next)
            try applyCollection(previous.rules, next.rules, name: ["rule"], label: "rule", lines: Self.ruleLines, write: { block, old, new in
                try self.updateField(block, "app", changed: old.app != new.app, value: ConfigDocument.literal(new.app))
                if old.title != new.title {
                    if new.title.isEmpty { self.retire(block.fields["title"]) }
                    else { try self.updateField(block, "title", changed: true, value: ConfigDocument.literal(new.title)) }
                }
                try self.updateField(block, "action", changed: old.action != new.action, value: "\"\(new.action.rawValue)\"")
                if old.space != new.space {
                    if let n = new.space { try self.updateField(block, "space", changed: true, value: String(n)) }
                    else { self.retire(block.fields["space"]) }
                }
                if old.follow != new.follow {
                    if new.follow { try self.updateField(block, "follow", changed: true, value: "true") } else { self.retire(block.fields["follow"]) }
                }
            })
            applyStructural()
        }

        // MARK: Values

        private func applyScalars(from previous: Config, to next: Config) throws {
            try syncNumber("accordion-padding", previous.accordionPadding, next.accordionPadding)
            try syncNumber("quiet-interval", previous.quietInterval, next.quietInterval)
            try syncNumber("per-app-timeout", previous.perAppTimeout, next.perAppTimeout)
            try syncBool("focus-after-close", previous.focusAfterClose, next.focusAfterClose)
            try syncBool("show-shortcut-guide", previous.showShortcutGuide, next.showShortcutGuide)
            try syncBool("place-dialogs-beside", previous.placeDialogsBeside, next.placeDialogsBeside)
            try syncString("language", previous.language, next.language)
            try syncString("new-window-placement", previous.newWindowPlacement.rawValue, next.newWindowPlacement.rawValue)
            try syncSize("preferred-minimum", previous.preferredMinimum, next.preferredMinimum)
            try syncSize("unknown-floor", previous.unknownFloor, next.unknownFloor)
            if previous.startAtLogin != next.startAtLogin {
                if let value = next.startAtLogin { try setRoot("start-at-login", value ? "true" : "false") }
                else if let line = line(for: ["start-at-login"]) { deletions.insert(line) }
            }
            try syncArray("exec-on-space-change", previous.execOnSpaceChange, next.execOnSpaceChange)
            try syncArray("exec-on-window-sent", previous.execOnWindowSent, next.execOnWindowSent)
            try syncArray("exec-on-mode-change", previous.execOnModeChange, next.execOnModeChange)
        }

        private func applyTables(from previous: Config, to next: Config) throws {
            try syncNested(["focus-border", "enabled"], previous.focusBorder.enabled, next.focusBorder.enabled, fallback: false)
            try syncNested(["focus-border", "width"], previous.focusBorder.width, next.focusBorder.width, fallback: 3, number: true)
            try syncNested(["focus-border", "color"], previous.focusBorder.color, next.focusBorder.color, fallback: "#4C8DFF", string: true)
            try syncNested(["notifications", "needs-attention"], previous.notifications.needsAttention, next.notifications.needsAttention, fallback: false)
        }

        private func applyGaps(from previous: Config, to next: Config) throws {
            let gaps = gapLines()
            let gapChanged = previous.gap != next.gap || previous.gapVertical != next.gapVertical
            let outerChanged = previous.outerLeft != next.outerLeft || previous.outerTop != next.outerTop
                || previous.outerRight != next.outerRight || previous.outerBottom != next.outerBottom
            if gaps.opaque && (gapChanged || outerChanged) {
                throw problem(L("Settings can't update gaps written as an inline table. Edit the [gaps] table in the file, then choose Reload. Nothing was saved.",
                                "隙間がインラインテーブルで書かれているため更新できません。ファイルの[gaps]を編集してから「再読み込み」を選んでください。保存していません。"))
            }
            if gapChanged { try applyInnerGaps(gaps, previous, next) }
            if outerChanged { try applyOuterGaps(gaps, previous, next) }
        }

        private func applyInnerGaps(_ gaps: GapLines, _ previous: Config, _ next: Config) throws {
            if previous.gap != next.gap {
                if let line = gaps.horizontal {
                    try replaceNumber(line, next.gap)
                } else {
                    try setRoot("gap", ConfigDocument.number(next.gap))
                }
            }
            if next.gapVertical == nil {
                if let line = gaps.vertical, numericValue(line) != next.gap {
                    try replaceNumber(line, next.gap)
                }
            } else if previous.gapVertical != next.gapVertical {
                if let line = gaps.vertical { try replaceNumber(line, next.gapVertical!) }
                else { try setRootPath(["gaps", "inner-vertical"], ConfigDocument.number(next.gapVertical!)) }
            }
        }

        private func applyOuterGaps(_ gaps: GapLines, _ previous: Config, _ next: Config) throws {
            let edges = ["left", "top", "right", "bottom"]
            func value(_ edge: String, _ config: Config) -> Double {
                switch edge {
                case "left": return config.outerLeft
                case "top": return config.outerTop
                case "right": return config.outerRight
                default: return config.outerBottom
                }
            }
            for edge in edges where value(edge, previous) != value(edge, next) {
                if let line = gaps.outer[edge] {
                    try replaceNumber(line, value(edge, next))
                } else {
                    try setRootPath(["gaps", "outer-\(edge)"], ConfigDocument.number(value(edge, next)))
                }
            }
        }

        private func applyKeys(from previous: Config, to next: Config) throws {
            let names = Set(previous.keys.keys).union(next.keys.keys).union(Config.defaultKeys.keys)
            var appended: [String] = []
            for name in names.sorted() {
                let old = previous.keys[name]
                let new = next.keys[name]
                guard old != new else { continue }
                let literal = new.map { ConfigDocument.literal($0.configText) } ?? "\"none\""
                if let line = line(for: ["keys", name]) {
                    try replaceValue(line, literal)
                } else if new != nil || Config.defaultKeys[name] != nil {
                    appended.append("\(name) = \(literal)")
                }
            }
            guard !appended.isEmpty else { return }
            if let header = headers.last(where: { $0.path == ["keys"] && !$0.array }) {
                let at = headers.filter { $0.line > header.line }.map(\.line).min() ?? rows.count
                insertions.append((at, appended))
            } else if assignments.contains(where: { $0.array == nil && $0.absolute.first == "keys" }) {
                let at = headers.map(\.line).min() ?? rows.count
                insertions.append((at, appended.map { "keys.\($0)" }))
            } else {
                insertions.append((rows.count, ["[keys]"] + appended))
            }
        }

        private func applyCollection<T: Equatable>(_ previous: [T], _ next: [T], name: [String], label: String, lines: (T) -> [String], write: (Block, T, T) throws -> Void) throws {
            guard previous != next else { return }
            let blocks = blocks(named: name)
            guard blocks.count == previous.count else {
                throw problem(L("Settings can't update \(label) entries written in this form. Edit them in the file, then choose Reload. Nothing was saved.",
                                "\(label)がこの書き方だと更新できません。ファイルで編集してから「再読み込み」を選んでください。保存していません。"))
            }
            let plan = Self.diff(previous, next)
            for step in plan.steps {
                switch step {
                case .edit(let old, let new):
                    try write(blocks[old], previous[old], next[new])
                case .delete(let old):
                    deleteData(blocks[old])
                case .insert(let new):
                    let at = insertIndex(for: new, pairs: plan.pairs, blocks: blocks)
                    insertions.append((at, lines(next[new])))
                }
            }
        }

        // MARK: Find and replace

        private func syncNumber(_ key: String, _ old: Double, _ new: Double) throws {
            guard old != new else { return }
            try setRoot(key, ConfigDocument.number(new))
        }

        private func syncBool(_ key: String, _ old: Bool, _ new: Bool) throws {
            guard old != new else { return }
            try setRoot(key, new ? "true" : "false")
        }

        private func syncString(_ key: String, _ old: String, _ new: String) throws {
            guard old != new else { return }
            try setRoot(key, ConfigDocument.literal(new))
        }

        private func syncSize(_ key: String, _ old: CGSize, _ new: CGSize) throws {
            guard old != new else { return }
            try setRoot(key, "[\(ConfigDocument.number(new.width)), \(ConfigDocument.number(new.height))]")
        }

        private func syncArray(_ key: String, _ old: [String], _ new: [String]) throws {
            guard old != new else { return }
            if new.isEmpty {
                if let line = line(for: [key]) { deletions.insert(line) }
            } else {
                try setRoot(key, ConfigDocument.stringArray(new))
            }
        }

        private func syncNested(_ path: [String], _ old: Bool, _ new: Bool, fallback: Bool) throws {
            guard old != new else { return }
            if let line = line(for: path) { try replaceValue(line, new ? "true" : "false"); return }
            if new != fallback { try setRootPath(path, new ? "true" : "false") }
        }

        private func syncNested(_ path: [String], _ old: Double, _ new: Double, fallback: Double, number: Bool) throws {
            guard number, old != new else { return }
            if let line = line(for: path) { try replaceNumber(line, new); return }
            if new != fallback { try setRootPath(path, ConfigDocument.number(new)) }
        }

        private func syncNested(_ path: [String], _ old: String, _ new: String, fallback: String, string: Bool) throws {
            guard string, old != new else { return }
            if let line = line(for: path) { try replaceValue(line, ConfigDocument.literal(new)); return }
            if new != fallback { try setRootPath(path, ConfigDocument.literal(new)) }
        }

        private func setRoot(_ key: String, _ literal: String) throws {
            try setRootPath([key], literal)
        }

        private func setRootPath(_ path: [String], _ literal: String) throws {
            if let line = line(for: path) {
                try replaceValue(line, literal)
                return
            }
            let text = path.count == 1 ? "\(path[0]) = \(literal)" : "\(path.joined(separator: ".")) = \(literal)"
            let at = headers.map(\.line).min() ?? rows.count
            insertions.append((at, [text]))
        }

        private func replaceNumber(_ line: Int, _ value: Double) throws {
            try replaceValue(line, ConfigDocument.number(value))
        }

        private func numericValue(_ line: Int) -> Double? {
            guard let raw = valueToken(rows[line].content), let value = try? TOML.parseValue(raw, line: 1) else { return nil }
            if let number = value as? Int { return Double(number) }
            if let number = value as? Double { return number }
            return nil
        }

        /// Replaces values of changed fields only. A trailing comment on a removed line stays as its own comment.
        private func updateField(_ block: Block, _ key: String, changed: Bool, value: String) throws {
            guard changed else { return }
            if let line = block.fields[key] { try replaceValue(line, value) }
            else { insertions.append((block.lastData + 1, ["\(key) = \(value)"])) }
        }

        private func replaceValue(_ line: Int, _ literal: String) throws {
            rows[line].content = try Self.replacingValue(in: rows[line].content, with: literal)
        }

        private func line(for path: [String]) -> Int? {
            assignments.last { $0.array == nil && $0.absolute == path }?.line
        }

        private func deleteData(_ block: Block) {
            retire(block.header)
            for line in block.fields.values { retire(line) }
        }

        /// Removes a data line, keeping only the text of its trailing comment if any.
        private func retire(_ line: Int?) {
            guard let line else { return }
            let comment = TOML.codeAndComment(rows[line].content).comment.trimmingCharacters(in: .whitespaces)
            if comment.isEmpty { deletions.insert(line) }
            else { rows[line].content = comment }
        }

        private func insertIndex(for newIndex: Int, pairs: [(Int, Int)], blocks: [Block]) -> Int {
            if let old = pairs.first(where: { $0.1 >= newIndex })?.0 { return blocks[old].header }
            if let last = blocks.last { return last.lastData + 1 }
            return headers.map(\.line).min() ?? rows.count
        }

        private func blocks(named name: [String]) -> [Block] {
            var result: [Block] = []
            var current: Block?
            func close() {
                if let current { result.append(current) }
                current = nil
            }
            for header in headers.sorted(by: { $0.line < $1.line }) {
                if header.array && header.path == name {
                    close()
                    current = Block(header: header.line, fields: [:], lastData: header.line)
                } else if current != nil {
                    close()
                }
            }
            close()
            let owned = assignments.filter { $0.array?.name == name }
            for item in owned {
                guard let index = item.array?.index, result.indices.contains(index), item.relative.count == 1 else { continue }
                result[index].fields[item.relative[0]] = item.line
                result[index].lastData = max(result[index].lastData, item.line)
            }
            return result
        }

        // MARK: Gap lines

        /// Lines that write gaps. For horizontal, `[gaps] inner-horizontal` wins over `gap` (as in the loader).
        private struct GapLines {
            var horizontal: Int?
            var vertical: Int?
            var outer: [String: Int] = [:]
            var opaque = false
        }

        private func gapLines() -> GapLines {
            var gaps = GapLines()
            var root: Int?
            var innerHorizontal: Int?
            for item in assignments where item.array == nil {
                switch item.absolute {
                case ["gaps"]: gaps.opaque = true
                case ["gap"] where isNumber(item.line): root = item.line
                case ["gaps", "inner-horizontal"] where isNumber(item.line): innerHorizontal = item.line
                case ["gaps", "inner-vertical"] where isNumber(item.line): gaps.vertical = item.line
                default:
                    if item.absolute.count == 2, item.absolute[0] == "gaps", item.absolute[1].hasPrefix("outer-"), isNumber(item.line) {
                        gaps.outer[String(item.absolute[1].dropFirst(6))] = item.line
                    }
                }
            }
            gaps.horizontal = innerHorizontal ?? root
            return gaps
        }

        private func isNumber(_ line: Int) -> Bool {
            guard let raw = valueToken(rows[line].content), let value = try? TOML.parseValue(raw, line: 1) else { return false }
            return value is Int || value is Double
        }

        // MARK: Structural changes

        private func applyStructural() {
            let terminalEnding = rows.last?.ending ?? ""
            let structural = !deletions.isEmpty || !insertions.isEmpty
            for line in deletions.sorted(by: >) {
                guard rows.indices.contains(line) else { continue }
                rows.remove(at: line)
                for index in insertions.indices where insertions[index].index > line {
                    insertions[index].index -= 1
                }
            }
            let ordered = insertions.enumerated().sorted { lhs, rhs in
                if lhs.element.index != rhs.element.index { return lhs.element.index > rhs.element.index }
                return lhs.offset > rhs.offset
            }
            for item in ordered {
                insert(item.element.lines, at: min(item.element.index, rows.count))
            }
            if structural, let last = rows.indices.last {
                rows[last].ending = terminalEnding
            }
        }

        private func insert(_ block: [String], at index: Int) {
            guard !block.isEmpty else { return }
            let nl = rows.contains { $0.ending == "\r\n" } ? "\r\n" : "\n"
            if rows.count == 1 && rows[0].content.isEmpty && rows[0].ending.isEmpty {
                rows = block.map { Row(content: $0, ending: nl) }
                return
            }
            if index >= rows.count {
                let open = rows.last?.ending.isEmpty == true
                if open, let last = rows.indices.last { rows[last].ending = nl }
                for (offset, line) in block.enumerated() {
                    let last = offset == block.count - 1
                    rows.append(Row(content: line, ending: last && open ? "" : nl))
                }
                return
            }
            rows.insert(contentsOf: block.map { Row(content: $0, ending: nl) }, at: index)
        }

        // MARK: Reading

        private func parse() throws {
            var table: [String] = []
            var array: (name: [String], index: Int)?
            var counts: [String: Int] = [:]
            for (index, row) in rows.enumerated() {
                let code = TOML.codeAndComment(row.content).code.trimmingCharacters(in: .whitespaces)
                if code.isEmpty { continue }
                if code.hasPrefix("[["), code.hasSuffix("]]") {
                    let path = try TOML.parseKeyPath(String(code.dropFirst(2).dropLast(2)), line: index + 1)
                    let key = path.joined(separator: ".")
                    counts[key, default: 0] += 1
                    table = path
                    array = (path, counts[key]! - 1)
                    headers.append((index, path, true))
                    continue
                }
                if code.hasPrefix("["), code.hasSuffix("]") {
                    table = try TOML.parseKeyPath(String(code.dropFirst().dropLast()), line: index + 1)
                    array = nil
                    headers.append((index, table, false))
                    continue
                }
                guard let eq = TOML.topLevelEqualsIndex(code) else {
                    throw problem(L("Settings can't update line \(index + 1) because it is not a single key and value. Edit the file, then choose Reload. Nothing was saved.",
                                    "\(index + 1)行目は一つのキーと値ではないため更新できません。ファイルを編集してから「再読み込み」を選んでください。保存していません。"))
                }
                let key = try TOML.parseKeyPath(String(code[..<eq]), line: index + 1)
                assignments.append(Assignment(line: index, absolute: table + key, array: array, relative: key))
            }
        }

        /// `\r\n` is one grapheme as a Swift Character, so split lines by scalars.
        private static func split(_ text: String) -> [Row] {
            var rows: [Row] = []
            var current = ""
            let scalars = text.unicodeScalars
            var index = scalars.startIndex
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == "\r" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\n" {
                        rows.append(Row(content: current, ending: "\r\n"))
                        current = ""
                        index = scalars.index(after: next)
                        continue
                    }
                }
                if scalar == "\n" {
                    rows.append(Row(content: current, ending: "\n"))
                    current = ""
                    index = scalars.index(after: index)
                    continue
                }
                current.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
            if !current.isEmpty || rows.isEmpty { rows.append(Row(content: current, ending: "")) }
            return rows
        }

        private static func replacingValue(in line: String, with literal: String) throws -> String {
            let parts = TOML.codeAndComment(line)
            guard let eq = TOML.topLevelEqualsIndex(parts.code) else {
                throw problem(L("Settings can't find a value to replace. Edit the file, then choose Reload. Nothing was saved.",
                                "置き換える値が見つかりません。ファイルを編集してから「再読み込み」を選んでください。保存していません。"))
            }
            let after = parts.code.index(after: eq)
            let tail = parts.code[after...]
            let lead = tail.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = tail.dropFirst(lead.count)
            let trailCount = rest.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
            let token = rest.dropLast(trailCount)
            guard !token.isEmpty else {
                throw problem(L("Settings can't find a value to replace. Edit the file, then choose Reload. Nothing was saved.",
                                "置き換える値が見つかりません。ファイルを編集してから「再読み込み」を選んでください。保存していません。"))
            }
            _ = try TOML.parseValue(String(token), line: 1)
            return String(parts.code[..<after]) + lead + literal + rest.suffix(trailCount) + parts.comment
        }

        private func valueToken(_ line: String) -> String? {
            let code = TOML.codeAndComment(line).code
            guard let eq = TOML.topLevelEqualsIndex(code) else { return nil }
            let tail = code[code.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }

        private static func ruleLines(_ rule: Config.Rule) -> [String] {
            var lines = ["[[rule]]", "app = \(ConfigDocument.literal(rule.app))"]
            if !rule.title.isEmpty { lines.append("title = \(ConfigDocument.literal(rule.title))") }
            lines.append("action = \"\(rule.action.rawValue)\"")
            if let n = rule.space { lines.append("space = \(n)") }
            if rule.follow { lines.append("follow = true") }
            return lines
        }

        private struct Plan {
            enum Step { case edit(Int, Int), delete(Int), insert(Int) }
            var steps: [Step]
            var pairs: [(Int, Int)]
        }

        private static func diff<T: Equatable>(_ old: [T], _ new: [T]) -> Plan {
            let n = old.count, m = new.count
            var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in 1...n {
                    for j in 1...m {
                        if old[i - 1] == new[j - 1] { dp[i][j] = dp[i - 1][j - 1] + 1 }
                        else { dp[i][j] = max(dp[i - 1][j], dp[i][j - 1]) }
                    }
                }
            }
            var pairs: [(Int, Int)] = []
            var i = n, j = m
            while i > 0 && j > 0 {
                if old[i - 1] == new[j - 1] {
                    pairs.append((i - 1, j - 1))
                    i -= 1
                    j -= 1
                } else if dp[i - 1][j] >= dp[i][j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            pairs.reverse()
            let anchors = [(-1, -1)] + pairs + [(n, m)]
            var steps: [Plan.Step] = []
            for index in 0..<(anchors.count - 1) {
                let start = anchors[index], end = anchors[index + 1]
                let oldGap = Array((start.0 + 1)..<end.0)
                let newGap = Array((start.1 + 1)..<end.1)
                let paired = min(oldGap.count, newGap.count)
                for offset in 0..<paired { steps.append(.edit(oldGap[offset], newGap[offset])) }
                if oldGap.count > paired { steps.append(contentsOf: oldGap[paired...].map { .delete($0) }) }
                if newGap.count > paired { steps.append(contentsOf: newGap[paired...].map { .insert($0) }) }
            }
            return Plan(steps: steps, pairs: pairs)
        }
    }
}
