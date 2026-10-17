import AppKit
import Sparkle

/// The only file that imports Sparkle; `main.swift` creates it, so tests and the regression checks never do.
/// LazySpace is Sparkle's user driver: `UpdateFlow` decides what to show and `UpdateAlerts` shows standard macOS alerts,
/// so Sparkle's own windows never appear. This class only translates between Sparkle and those two.
final class SparkleUpdates: NSObject, UpdateChecking, SPUUserDriver {
    private var updater: SPUUpdater?
    private let flow: UpdateFlow
    private let currentVersion: String
    var offer: UpdateOffer? { flow.offer }
    var onChange: (() -> Void)? {
        get { flow.onChange }
        set { flow.onChange = newValue }
    }
    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    static func makeIfAllowed(bundle: Bundle) -> UpdateChecking? {
        guard UpdateEligibility.allowed(bundle: bundle) else { return nil }
        let updates = SparkleUpdates(bundle: bundle)
        do {
            try updates.updater?.start()
        } catch {
            NSLog("LazySpace: the updater did not start: \(error.localizedDescription)")
            // Sparkle holds its user driver strongly; let both go.
            updates.updater = nil
            return nil
        }
        return updates
    }

    private init(bundle: Bundle) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        flow = UpdateFlow(dialogs: UpdateAlerts(currentVersion: currentVersion))
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: nil)
    }

    /// Starts a check, or, while a session runs, brings it forward (Sparkle calls `showUpdateInFocus`).
    func checkForUpdates() {
        flow.userAsked()
        updater?.checkForUpdates()
    }

    // MARK: SPUUserDriver

    /// `SUEnableAutomaticChecks` is set, so Sparkle does not ask; this answers the same if it ever does. About turns the
    /// check off.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        flow.userStartedCheck(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = UpdateOffer(version: appcastItem.displayVersionString, build: appcastItem.versionString)
        let canSkip = state.stage == .notDownloaded && !appcastItem.isCriticalUpdate
        flow.found(offer, userInitiated: state.userInitiated, canSkip: canSkip) { choice in
            switch choice {
            case .install where appcastItem.isInformationOnlyUpdate:
                // Nothing to download: Sparkle must not be told to install; the page describes the update.
                if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
                reply(.dismiss)
            case .install: reply(.install)
            case .later: reply(.dismiss)
            case .skip: reply(.skip)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    /// On the newest version, LazySpace says so in its own words; for other reasons (for example, the update needs a newer
    /// macOS) Sparkle's explanation is the detail.
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let newest = reason == .onLatestVersion || reason == .onNewerThanLatestVersion
        flow.upToDate(detail: newest ? UpdateCopy.newest(currentVersion) : error.localizedRecoverySuggestion ?? error.localizedDescription, done: acknowledgement)
    }

    /// Sparkle's description is the detail; the title says whether checking or installing failed.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        flow.failed(detail: error.localizedDescription, done: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        flow.downloadStarted(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        flow.expect(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        flow.received(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        flow.preparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        flow.readyToInstall { reply($0 == .install ? .install : .dismiss) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        flow.installing(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
    }

    /// The old copy rarely lives to see this; the relaunched one is the confirmation.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        flow.focus()
    }

    func dismissUpdateInstallation() {
        flow.ended()
    }
}
