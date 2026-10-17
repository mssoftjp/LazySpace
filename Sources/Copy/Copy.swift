import Foundation

/// A shipped display language: every catalog translates every entry into it. English is the source language.
/// Command names, settings keys, and JSON keys are never translated.
public enum Language: String, Codable, CaseIterable {
    case english = "en"
    case japanese = "ja"

    /// Selects this language's catalog values. Cached because `L` runs often.
    public var locale: Locale { Self.locales[self]! }
    private static let locales = Dictionary(uniqueKeysWithValues: allCases.map { ($0, Locale(identifier: $0.rawValue)) })

    /// The language's name in that language, as macOS gives it.
    public var endonym: String { locale.localizedString(forLanguageCode: rawValue) ?? rawValue }
}

public enum Copy {
    private static let lock = NSLock()
    private static var _language: Language = Copy.initialLanguage()

    /// The language in use. Changes when the `language` setting is loaded.
    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return _language }
        set { lock.lock(); _language = newValue; lock.unlock() }
    }

    /// The first of macOS's preferred languages that LazySpace ships, matched the way macOS matches an app's localizations; otherwise English.
    public static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> Language {
        let codes = Language.allCases.map(\.rawValue)
        return Bundle.preferredLocalizations(from: codes, forPreferences: preferred).first.flatMap(Language.init(rawValue:)) ?? .english
    }

    /// Applies the `language` setting. `LAZYSPACE_LANGUAGE` overrides it. "system" stays English in tests.
    public static func apply(setting: String) {
        if let forced = environmentLanguage() { language = forced; return }
        if let explicit = Language(rawValue: setting.lowercased()) { language = explicit; return }
        language = initialLanguage()
    }

    /// Language at launch, before settings are read: `LAZYSPACE_LANGUAGE` if set. Tests run in English.
    static func initialLanguage() -> Language {
        if let forced = environmentLanguage() { return forced }
        if NSClassFromString("XCTestCase") != nil { return .english }
        return systemLanguage()
    }

    private static func environmentLanguage() -> Language? {
        ProcessInfo.processInfo.environment["LAZYSPACE_LANGUAGE"].flatMap { Language(rawValue: $0) }
    }
}

/// The System Settings pane that grants window control. Renamed from "Accessibility" in macOS 27.
public enum AccessPane {
    public static func name(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        osMajor >= 27
            ? L(.copyDeviceControlAndDataAccess)
            : L(.copyAccessibility)
    }
}

/// macOS item names as shown in macOS 27.0, without quotes.
public enum MacItem {
    public static func moveSpace(right: Bool) -> String {
        right ? L(.copyMoveRightASpace) : L(.copyMoveLeftASpace)
    }

    /// "Switch to Desktop N"; N stays when the number is unknown.
    public static func switchToDesktop(_ desktop: Int?) -> String {
        let number = desktop.map(String.init) ?? "N"
        return L(.copySwitchToDesktop(number))
    }

    public static var stageManager: String { L(.copyStageManager) }

    /// The login item switch. LazySpace's own setting uses the same words.
    public static var openAtLogin: String { L(.copyOpenAtLogin) }

    /// System Settings › General pane, renamed from "Login Items" in macOS 15.
    public static func loginItems(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        osMajor >= 15 ? L(.copyLoginItemsExtensions) : L(.copyLoginItems)
    }

    /// The Mission Control option.
    public static var separateSpaces: String { L(.copySeparateSpaces) }
}

extension Copy {
    /// Name of a numbered desktop, as Mission Control shows it.
    public static func desktop(_ number: Int) -> String {
        L(.copyDesktop(String(number)))
    }

    /// Separator for sentences joined at run time: a space in English, nothing in Japanese.
    public static var sentenceSeparator: String { L(" ", "") }
}

/// The current language's text for a catalog entry: `L(.menuArrangeNow)`.
public func L(_ resource: LocalizedStringResource) -> String {
    L(resource, in: Copy.language)
}

/// The text in an explicit language. The locale is always set: without it, plural rules would follow macOS's language.
public func L(_ resource: LocalizedStringResource, in language: Language) -> String {
    var resource = resource
    resource.locale = language.locale
    return String(localized: resource)
}

/// Picks the current language's text from an English and Japanese pair. English is required and is the fallback.
public func L(_ english: String, _ japanese: String) -> String {
    Copy.language == .japanese ? japanese : english
}
