import Copy
import Foundation
import XCTest

/// Checks the String Catalogs: every module that shows text has one, every entry is translated in every shipped language
/// with the same arguments, keys make distinct symbols, and every key is used. A missing translation shows the key, not English.
final class CatalogTests: XCTestCase {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let textModules = ["Copy", "Operations", "Settings", "MacSupport", "LazySpaceApp"]
    /// Separators are the only values that may be empty or surrounded by whitespace.
    static let separators: Set<String> = ["copy.sentenceSeparator", "copy.listSeparator", "copy.clauseSeparator"]
    static let keyPattern = try! NSRegularExpression(pattern: #"^[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*)+$"#)
    static let specifierPattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|llu|ld|lu|lf|ld|d|u|f|@)|%#@([A-Za-z0-9_]+)@|%%"#)

    struct Entry {
        var module: String
        var key: String
        var json: [String: Any]
        var comment: String { json["comment"] as? String ?? "" }
        var localizations: [String: Any] { json["localizations"] as? [String: Any] ?? [:] }
    }

    static func catalogURL(_ module: String) -> URL {
        root.appendingPathComponent("Sources/\(module)/Resources/Localizable.xcstrings")
    }

    static func catalog(_ module: String) throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL(module))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], module)
    }

    static func entries() throws -> [Entry] {
        try textModules.flatMap { module -> [Entry] in
            let strings = try catalog(module)["strings"] as? [String: Any] ?? [:]
            return strings.keys.sorted().map { Entry(module: module, key: $0, json: strings[$0] as? [String: Any] ?? [:]) }
        }
    }

    /// The symbol SwiftPM generates for a key: `.` `-` `_` start a capitalized word, and the first letter is lowercase.
    static func symbol(_ key: String) -> String {
        let parts = key.split(whereSeparator: { ".-_".contains($0) }).map(String.init)
        let joined = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return joined.prefix(1).lowercased() + joined.dropFirst()
    }

    /// Every displayed form of one language's localization: the value, or each plural form, plus each substitution's forms.
    static func forms(_ localization: [String: Any]) -> [(label: String, unit: [String: Any])] {
        var out: [(String, [String: Any])] = []
        if let unit = localization["stringUnit"] as? [String: Any] { out.append(("value", unit)) }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            for (category, form) in plural.sorted(by: { $0.key < $1.key }) {
                if let unit = (form as? [String: Any])?["stringUnit"] as? [String: Any] { out.append(("plural \(category)", unit)) }
            }
        }
        for (name, substitution) in (localization["substitutions"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let plural = ((substitution as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
            for (category, form) in plural.sorted(by: { $0.key < $1.key }) {
                if let unit = (form as? [String: Any])?["stringUnit"] as? [String: Any] { out.append(("\(name) \(category)", unit)) }
            }
        }
        return out
    }

    /// Arguments a value uses, as (argument number, kind). Plain specifiers count from 1 in order; `%#@name@` takes its substitution's number.
    static func arguments(_ value: String, substitutions: [String: Any]) -> Set<String> {
        var out: Set<String> = []
        var next = 0
        let range = NSRange(value.startIndex..., in: value)
        for match in specifierPattern.matches(in: value, range: range) {
            let text = (value as NSString).substring(with: match.range)
            if text == "%%" { continue }
            if let nameRange = Range(match.range(at: 3), in: value) {
                let substitution = substitutions[String(value[nameRange])] as? [String: Any] ?? [:]
                let number = substitution["argNum"] as? Int ?? -1
                out.insert("\(number):\(kind(substitution["formatSpecifier"] as? String ?? "?"))")
                continue
            }
            let type = (value as NSString).substring(with: match.range(at: 2))
            let number: Int
            if let positional = Range(match.range(at: 1), in: value) { number = Int(value[positional]) ?? -1 } else { next += 1; number = next }
            out.insert("\(number):\(kind(type))")
        }
        return out
    }

    /// English arguments used only to choose a plural form: substitutions none of whose forms shows the number ("was" or "were"),
    /// and that no plain specifier shows either. Another language may leave these out.
    static func pluralSelectors(_ localization: [String: Any]) -> Set<String> {
        let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
        var selectors: Set<String> = []
        for case let substitution as [String: Any] in substitutions.values {
            let forms = ((substitution["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]).values
            let shown = forms.contains { ((($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? "").contains("%arg") }
            if !shown { selectors.insert("\(substitution["argNum"] as? Int ?? -1):\(kind(substitution["formatSpecifier"] as? String ?? "?"))") }
        }
        let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
        return selectors.subtracting(arguments(value, substitutions: [:]))
    }

    /// What is wrong with a translation's arguments compared with English, or nil.
    static func argumentProblem(english: [String: Any], other: [String: Any]) -> String? {
        let expected = arguments(of: english), actual = arguments(of: other)
        let missing = expected.subtracting(actual).subtracting(pluralSelectors(english))
        let extra = actual.subtracting(expected)
        return missing.isEmpty && extra.isEmpty ? nil : "\(actual.sorted()) vs en \(expected.sorted())"
    }

    static func kind(_ specifier: String) -> String {
        switch specifier {
        case "lld", "ld", "d": "int"
        case "llu", "lu", "u": "uint"
        case "lf", "f": "double"
        default: "object"
        }
    }

    /// Arguments of one language across its forms. A plural form may leave out its count, so the union is compared.
    static func arguments(of localization: [String: Any]) -> Set<String> {
        let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
        var out: Set<String> = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            out.formUnion(arguments(unit["value"] as? String ?? "", substitutions: substitutions))
        }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            for form in plural.values {
                let value = ((form as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                out.formUnion(arguments(value, substitutions: substitutions))
            }
        }
        return out
    }

    /// The plural categories each shipped language distinguishes for whole numbers (CLDR). A new language adds its own.
    static let pluralCategories: [Language: Set<String>] = [.english: ["one", "other"], .japanese: ["other"]]

    /// Plural forms a localization is missing, at the top level and in each substitution.
    static func missingPluralForms(_ localization: [String: Any], language: Language) -> [String] {
        guard let required = pluralCategories[language] else { return ["no plural categories listed for \(language.rawValue)"] }
        var plurals: [(String, [String: Any])] = []
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] { plurals.append(("plural", plural)) }
        for (name, substitution) in localization["substitutions"] as? [String: Any] ?? [:] {
            let plural = ((substitution as? [String: Any])?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
            plurals.append((name, plural))
        }
        return plurals.flatMap { label, plural in required.subtracting(plural.keys).sorted().map { "\(label) without \($0)" } }
    }

    // MARK: - Tests

    func testEveryShippedLanguageListsItsPluralCategories() {
        for language in Language.allCases { XCTAssertNotNil(Self.pluralCategories[language], language.rawValue) }
    }

    func testMissingPluralFormsAreFound() {
        func unit(_ value: String) -> [String: Any] { ["stringUnit": ["state": "translated", "value": value]] }
        let both: [String: Any] = ["variations": ["plural": ["one": unit("%arg Space"), "other": unit("%arg Spaces")]]]
        var english = unit("for %#@spaces@")
        english["substitutions"] = ["spaces": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": ["other": unit("%arg Spaces")]]]]
        XCTAssertEqual(Self.missingPluralForms(english, language: .english), ["spaces without one"])
        XCTAssertEqual(Self.missingPluralForms(["variations": ["plural": ["other": unit("%lld")]]], language: .english), ["plural without one"])
        XCTAssertEqual(Self.missingPluralForms(both, language: .english), [])
        XCTAssertEqual(Self.missingPluralForms(["variations": ["plural": ["other": unit("%lld")]]], language: .japanese), [])
        XCTAssertEqual(Self.missingPluralForms(unit("plain"), language: .english), [])
    }

    func testEveryTextModuleHasACatalogInEnglish() throws {
        for module in Self.textModules {
            let catalog = try Self.catalog(module)
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en", module)
            XCTAssertNotNil(catalog["strings"] as? [String: Any], module)
        }
    }

    func testEveryEntryIsTranslatedInEveryShippedLanguage() throws {
        var found: [String] = []
        for entry in try Self.entries() {
            for language in Language.allCases {
                guard let localization = entry.localizations[language.rawValue] as? [String: Any] else {
                    found.append("\(entry.module) \(entry.key) [\(language.rawValue)]: missing"); continue
                }
                let forms = Self.forms(localization)
                if forms.isEmpty { found.append("\(entry.module) \(entry.key) [\(language.rawValue)]: no value") }
                found += Self.missingPluralForms(localization, language: language).map { "\(entry.module) \(entry.key) [\(language.rawValue)]: \($0)" }
                for (label, unit) in forms {
                    let state = unit["state"] as? String ?? "missing"
                    let value = unit["value"] as? String ?? ""
                    if state != "translated" { found.append("\(entry.module) \(entry.key) [\(language.rawValue)] \(label): state \(state)") }
                    let mayBeEmpty = entry.key == "copy.sentenceSeparator" && language == .japanese
                    if value.isEmpty && !mayBeEmpty { found.append("\(entry.module) \(entry.key) [\(language.rawValue)] \(label): empty") }
                }
            }
        }
        XCTAssertEqual(found, [], "untranslated catalog entries:\n" + found.joined(separator: "\n"))
    }

    /// Every language uses English's arguments with the same types. A count that English uses only to choose a plural form
    /// ("was" or "were") may be left out by a language without that choice; anything else left out or added is a mistake.
    func testEveryLanguageUsesTheSameArgumentsAsEnglish() throws {
        var found: [String] = []
        for entry in try Self.entries() {
            guard let english = entry.localizations["en"] as? [String: Any] else { continue }
            for language in Language.allCases where language != .english {
                guard let localization = entry.localizations[language.rawValue] as? [String: Any] else { continue }
                if let problem = Self.argumentProblem(english: english, other: localization) {
                    found.append("\(entry.module) \(entry.key) [\(language.rawValue)]: \(problem)")
                }
            }
        }
        XCTAssertEqual(found, [], "arguments differ from English:\n" + found.joined(separator: "\n"))
    }

    func testEntriesAreManualAndKeysMakeDistinctSymbols() throws {
        var found: [String] = []
        var symbols: [String: [String: String]] = [:]
        for entry in try Self.entries() {
            if entry.json["extractionState"] as? String != "manual" { found.append("\(entry.module) \(entry.key): not manual") }
            let range = NSRange(entry.key.startIndex..., in: entry.key)
            if Self.keyPattern.firstMatch(in: entry.key, range: range) == nil { found.append("\(entry.module) \(entry.key): key format") }
            let symbol = Self.symbol(entry.key)
            if let other = symbols[entry.module]?[symbol] { found.append("\(entry.module) \(entry.key): same symbol as \(other)") }
            symbols[entry.module, default: [:]][symbol] = entry.key
        }
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    func testEntriesWithArgumentsHaveComments() throws {
        let found = try Self.entries().filter { entry in
            guard let english = entry.localizations["en"] as? [String: Any] else { return false }
            return !Self.arguments(of: english).isEmpty && entry.comment.trimmingCharacters(in: .whitespaces).isEmpty
        }.map { "\($0.module) \($0.key)" }
        XCTAssertEqual(found, [], "entries with arguments need a comment naming them:\n" + found.joined(separator: "\n"))
    }

    /// Code joins whole units only with the separator entries, so no other value starts or ends with whitespace.
    func testValuesAreWholeUnits() throws {
        var found: [String] = []
        for entry in try Self.entries() where !Self.separators.contains(entry.key) {
            for (language, localization) in entry.localizations {
                for (label, unit) in Self.forms(localization as? [String: Any] ?? [:]) {
                    let value = unit["value"] as? String ?? ""
                    if value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                        found.append("\(entry.module) \(entry.key) [\(language)] \(label): \(value.debugDescription)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "leading or trailing whitespace:\n" + found.joined(separator: "\n"))
    }

    func testEveryKeyIsUsedByItsModule() throws {
        var found: [String] = []
        for module in Self.textModules {
            let directory = Self.root.appendingPathComponent("Sources/\(module)")
            let sources = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
                .map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
            for entry in try Self.entries() where entry.module == module {
                let pattern = "\\.\(Self.symbol(entry.key))(?![A-Za-z0-9_])"
                if sources.range(of: pattern, options: .regularExpression) == nil { found.append("\(module) \(entry.key)") }
            }
        }
        XCTAssertEqual(found, [], "catalog keys no code uses:\n" + found.joined(separator: "\n"))
    }

    func testSymbolNamesFollowSwiftPM() {
        XCTAssertEqual(Self.symbol("menu.arrangeNow"), "menuArrangeNow")
        XCTAssertEqual(Self.symbol("refusal.noDisplay"), "refusalNoDisplay")
        XCTAssertEqual(Self.symbol("Menu.Upper"), "menuUpper")
    }

    /// Only a count that English never shows may be left out; a shown count, or any other argument, may not.
    func testOnlyPluralSelectorsMayBeLeftOut() {
        func unit(_ value: String) -> [String: Any] { ["stringUnit": ["state": "translated", "value": value]] }
        func english(_ value: String, one: String, other: String) -> [String: Any] {
            var localization = unit(value)
            localization["substitutions"] = ["windows": ["argNum": 2, "formatSpecifier": "lld", "variations": ["plural": [
                "one": unit(one), "other": unit(other)]]]]
            return localization
        }
        let chooser = english("%1$@ %#@windows@ kept.", one: "was", other: "were")
        XCTAssertNil(Self.argumentProblem(english: chooser, other: unit("%1$@はそのままです。")))
        XCTAssertNotNil(Self.argumentProblem(english: chooser, other: unit("そのままです。")), "the name is shown")
        let shown = english("%1$@: %#@windows@.", one: "%arg window", other: "%arg windows")
        XCTAssertNotNil(Self.argumentProblem(english: shown, other: unit("%1$@: ウインドウ")), "the count is shown")
        XCTAssertNil(Self.argumentProblem(english: shown, other: unit("%1$@: %2$lldつ")))
        XCTAssertNotNil(Self.argumentProblem(english: shown, other: unit("%1$@: %2$lldつ %3$@")), "an argument English lacks")
    }

    func testArgumentsAreReadFromEveryKindOfValue() {
        XCTAssertEqual(Self.arguments("Sent %@ to %@.", substitutions: [:]), ["1:object", "2:object"])
        XCTAssertEqual(Self.arguments("%2$@へ%1$@を送りました。", substitutions: [:]), ["1:object", "2:object"])
        XCTAssertEqual(Self.arguments("No display %1$@. %#@connected@", substitutions: ["connected": ["argNum": 2, "formatSpecifier": "lld"]]),
                       ["1:object", "2:int"])
        XCTAssertEqual(Self.arguments("100%% done", substitutions: [:]), [])
    }
}
