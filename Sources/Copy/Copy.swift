import Foundation

/// Language of user-facing text. English is the base and Japanese its translation. Command names, settings keys, and JSON keys are never translated.
public enum Language: String, Codable, CaseIterable {
    case english = "en"
    case japanese = "ja"
}

public enum Copy {
    private static let lock = NSLock()
    private static var _language: Language = Copy.initialLanguage()

    /// The language in use. Changes when the `language` setting is loaded.
    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return _language }
        set { lock.lock(); _language = newValue; lock.unlock() }
    }

    /// Japanese if macOS's first preferred language is Japanese, otherwise English.
    public static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> Language {
        guard let first = preferred.first else { return .english }
        return first.hasPrefix("ja") ? .japanese : .english
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
            ? L("Device Control and Data Access", "デバイスの制御とデータへのアクセス")
            : L("Accessibility", "アクセシビリティ")
    }
}

/// macOS item names as shown in macOS 27.0, without quotes.
public enum MacItem {
    public static func moveSpace(right: Bool) -> String {
        right ? L("Move right a Space", "右の操作スペースに移動") : L("Move left a Space", "左の操作スペースに移動")
    }

    /// "Switch to Desktop N"; N stays when the number is unknown.
    public static func switchToDesktop(_ desktop: Int?) -> String {
        let number = desktop.map(String.init) ?? "N"
        return L("Switch to Desktop \(number)", "デスクトップ\(number)へ切り替え")
    }

    public static var stageManager: String { L("Stage Manager", "ステージマネージャ") }

    /// The login item switch. LazySpace's own setting uses the same words.
    public static var openAtLogin: String { L("Open at Login", "ログイン時に開く") }

    /// System Settings › General pane, renamed from "Login Items" in macOS 15.
    public static func loginItems(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        osMajor >= 15 ? L("Login Items & Extensions", "ログイン項目と機能拡張") : L("Login Items", "ログイン項目")
    }

    /// The Mission Control option.
    public static var separateSpaces: String { L("Displays have separate Spaces", "ディスプレイごとに個別の操作スペース") }
}

extension Copy {
    /// Name of a numbered desktop, as Mission Control shows it.
    public static func desktop(_ number: Int) -> String {
        L("Desktop \(number)", "デスクトップ\(number)")
    }

    /// Separator for sentences joined at run time: a space in English, nothing in Japanese.
    public static var sentenceSeparator: String { L(" ", "") }
}

/// Picks the current language's text from an English and Japanese pair. English is required and is the fallback.
public func L(_ english: String, _ japanese: String) -> String {
    Copy.language == .japanese ? japanese : english
}
