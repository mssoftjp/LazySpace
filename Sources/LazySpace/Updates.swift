import Copy
import Foundation

/// A newer version found by a scheduled update check.
struct UpdateOffer: Codable, Equatable {
    var version: String
    var build: String
}

/// What the app sees of the updater. Main thread only; only `SparkleUpdates` (created by `main.swift`) talks to Sparkle,
/// so tests and the regression checks never start an updater.
protocol UpdateChecking: AnyObject {
    /// A newer version found by a scheduled check, until Sparkle's update session for it ends, whatever the user chose.
    var offer: UpdateOffer? { get }
    var onChange: (() -> Void)? { get set }
    /// The daily check; Sparkle keeps the choice. Checking by hand works either way.
    var checksAutomatically: Bool { get set }
    /// Opens Sparkle's update window: the pending update if there is one, otherwise a fresh check.
    func checkForUpdates()
}

/// Whether this copy may check for and install updates.
enum UpdateEligibility {
    static var runningUnderTests: Bool { NSClassFromString("XCTestCase") != nil }

    /// Development builds have no feed. A copy on the disk image, translocated by Gatekeeper, or on a read-only volume
    /// cannot replace itself, so it does not offer what it cannot install.
    static func allowed(bundlePath: String, info: [String: Any], underTests: Bool, onReadOnlyVolume: Bool) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { return false }
        if underTests || onReadOnlyVolume { return false }
        return !bundlePath.contains("/AppTranslocation/")
    }

    static func allowed(bundle: Bundle) -> Bool {
        let readOnly = (try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return allowed(bundlePath: bundle.bundlePath, info: bundle.infoDictionary ?? [:], underTests: runningUnderTests, onReadOnlyVolume: readOnly)
    }
}

enum UpdateCopy {
    static func menuTitle(_ offer: UpdateOffer) -> String { L("Update LazySpace to \(offer.version)…", "LazySpace \(offer.version)にアップデート…") }
    /// Without a final period, for the `status` row.
    static func available(_ offer: UpdateOffer) -> String { L("LazySpace \(offer.version) is available", "LazySpace \(offer.version)が利用できます") }
    static func notice(_ offer: UpdateOffer) -> String { available(offer) + L(".", "。") }
    static var statusRow: String { L("Update", "アップデート") }
    static var updateButton: String { L("Update…", "アップデート…") }
    static var checkButton: String { L("Check for Updates…", "アップデートを確認…") }
    static var automaticCheck: String { L("Automatically check for updates", "アップデートを自動的に確認") }

    static var install: String { L("Install Update", "アップデートをインストール") }
    static var later: String { L("Remind Me Later", "あとで通知") }
    static var skip: String { L("Skip This Version", "このバージョンをスキップ") }
    static func askDetail(current: String) -> String {
        L("You have version \(current). LazySpace quits and reopens to finish installing.", "使用中のバージョンは\(current)です。インストールすると、LazySpaceが再起動します。")
    }

    static func title(_ step: UpdateStep) -> String {
        switch step {
        case .checking: L("Checking for updates…", "アップデートを確認しています…")
        case .downloading: L("Downloading the update…", "アップデートをダウンロードしています…")
        case .preparing: L("Preparing to install…", "インストールの準備をしています…")
        case .installing: L("Installing the update…", "アップデートをインストールしています…")
        case .waitingToQuit: L("LazySpace needs to quit to install the update", "アップデートをインストールするには、LazySpaceを終了する必要があります")
        }
    }

    static func detail(_ step: UpdateStep) -> String {
        switch step {
        case .installing: L("LazySpace reopens when it's done.", "完了するとLazySpaceが再起動します。")
        case .waitingToQuit: L("The update is downloaded. LazySpace reopens after installing.", "アップデートはダウンロード済みです。インストール後にLazySpaceが再起動します。")
        default: ""
        }
    }

    static var upToDate: String { L("LazySpace is up to date", "LazySpaceは最新の状態です") }
    static func newest(_ version: String) -> String { L("Version \(version) is the newest version.", "バージョン\(version)が最新のバージョンです。") }
    static var checkFailed: String { L("Could not check for updates", "アップデートを確認できませんでした") }
    static var installFailed: String { L("The update could not be installed", "アップデートをインストールできませんでした") }

    static var cancel: String { L("Cancel", "キャンセル") }
    static var quitAndInstall: String { L("Quit and Install", "終了してインストール") }
    static var ok: String { L("OK", "OK") }
}

enum UpdateChoice: Equatable {
    case install, later, skip
}

/// What the progress alert shows.
enum UpdateStep: Equatable {
    case checking
    /// `fraction` is nil until the download's length is known.
    case downloading(fraction: Double?)
    case preparing
    case installing
    /// Sparkle asked LazySpace to quit and it has not yet (for example, a pending Settings edit was kept).
    case waitingToQuit
}

/// What an update session shows. `UpdateAlerts` draws standard macOS alerts, one at a time; tests record instead.
protocol UpdateDialogs: AnyObject {
    /// Asks what to do about `offer`; answering closes the alert, then calls `reply`.
    func ask(_ offer: UpdateOffer, canSkip: Bool, reply: @escaping (UpdateChoice) -> Void)
    /// Shows or advances the progress alert. `action` is its button (Cancel, or Quit and Install); without one the button is disabled.
    func progress(_ step: UpdateStep, action: (() -> Void)?)
    /// A message the user acknowledges with OK.
    func tell(title: String, detail: String, done: @escaping () -> Void)
    func bringToFront()
    func close()
}

/// Decides what an update session shows, from Sparkle's user-driver calls, without Sparkle. Main thread only.
final class UpdateFlow {
    private let dialogs: UpdateDialogs
    private(set) var offer: UpdateOffer? {
        didSet { if offer != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
    /// The user asked to check or update during this session. Until then nothing appears on screen.
    private var userInvolved = false
    /// Cancels a check the user started, until it answers; its progress alert waits a second so a quick answer appears alone.
    private var cancelCheck: (() -> Void)?
    private var checks = 0
    private var downloading = false
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    /// A found update not yet put to the user, with Sparkle's reply.
    private var waiting: (offer: UpdateOffer, canSkip: Bool, reply: (UpdateChoice) -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var cancelDownload: (() -> Void)?

    init(dialogs: UpdateDialogs, after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.dialogs = dialogs
        self.after = after
    }

    /// The user chose Update or Check for Updates. Recorded before Sparkle answers, because a scheduled check that is
    /// still fetching ignores the request: the update it finds, or its error, is then shown at once.
    func userAsked() {
        userInvolved = true
    }

    func userStartedCheck(cancel: @escaping () -> Void) {
        userInvolved = true
        cancelCheck = cancel
        checks += 1
        let check = checks
        after(1) { [weak self] in
            guard let self, self.checks == check, let cancel = self.cancelCheck else { return }
            self.dialogs.progress(.checking, action: cancel)
        }
    }

    /// A scheduled check only publishes the offer; a check the user started asks at once.
    func found(_ offer: UpdateOffer, userInitiated: Bool, canSkip: Bool, reply: @escaping (UpdateChoice) -> Void) {
        cancelCheck = nil
        self.offer = offer
        waiting = (offer, canSkip, reply)
        if userInitiated || userInvolved { focus() }
    }

    /// The user chose Update or Check for Updates while a session runs: ask about a waiting update, or bring the alert forward.
    func focus() {
        userInvolved = true
        guard let waiting else {
            dialogs.bringToFront()
            return
        }
        self.waiting = nil
        dialogs.ask(waiting.offer, canSkip: waiting.canSkip, reply: waiting.reply)
    }

    func upToDate(detail: String, done: @escaping () -> Void) {
        tell(UpdateCopy.upToDate, detail, done)
    }

    /// `detail` is Sparkle's description of the error.
    func failed(detail: String, done: @escaping () -> Void) {
        tell(downloading ? UpdateCopy.installFailed : UpdateCopy.checkFailed, detail, done)
    }

    private func tell(_ title: String, _ detail: String, _ done: @escaping () -> Void) {
        cancelCheck = nil
        guard userInvolved else {
            done()
            return
        }
        dialogs.tell(title: title, detail: detail, done: done)
    }

    func downloadStarted(cancel: @escaping () -> Void) {
        downloading = true
        expectedLength = 0
        receivedLength = 0
        cancelDownload = cancel
        dialogs.progress(.downloading(fraction: nil), action: cancel)
    }

    func expect(_ length: UInt64) {
        expectedLength = length
        receivedLength = 0
        showDownload()
    }

    func received(_ length: UInt64) {
        receivedLength += length
        showDownload()
    }

    private func showDownload() {
        let fraction = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
        dialogs.progress(.downloading(fraction: fraction), action: cancelDownload)
    }

    func preparing() {
        cancelDownload = nil
        dialogs.progress(.preparing, action: nil)
    }

    /// The user already chose Install; Sparkle's second Install and Relaunch prompt is answered for them.
    func readyToInstall(reply: (UpdateChoice) -> Void) {
        reply(.install)
    }

    func installing(applicationTerminated: Bool, retry: @escaping () -> Void) {
        dialogs.progress(applicationTerminated ? .installing : .waitingToQuit, action: applicationTerminated ? nil : retry)
    }

    /// Install, Remind Me Later, Skip, Cancel, or a failure: the next scheduled check brings a remaining update back, quietly.
    func ended() {
        waiting = nil
        cancelCheck = nil
        cancelDownload = nil
        downloading = false
        userInvolved = false
        offer = nil
        dialogs.close()
    }
}

enum AboutCopy {
    static let repository = URL(string: "https://github.com/mssoftjp/LazySpace")!
    /// The link's text: the address without the scheme.
    static var repositoryTitle: String { (repository.host ?? "") + repository.path }

    static func version(short: String, build: String) -> String {
        guard !build.isEmpty, build != short else { return L("Version \(short)", "バージョン\(short)") }
        return L("Version \(short) (\(build))", "バージョン\(short)（\(build)）")
    }
}
