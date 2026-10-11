import Copy
@testable import LazySpace
import XCTest

/// Stands in for Sparkle: records checks and lets the test publish or clear an offer.
final class FakeUpdates: UpdateChecking {
    var offer: UpdateOffer?
    var onChange: (() -> Void)?
    var checksAutomatically = true
    private(set) var checks = 0
    func checkForUpdates() { checks += 1 }
}

/// Records what an update session shows, in a compact form, and answers like the user.
final class FakeDialogs: UpdateDialogs {
    private(set) var events: [String] = []
    private var reply: ((UpdateChoice) -> Void)?
    private var done: (() -> Void)?

    func ask(_ offer: UpdateOffer, canSkip: Bool, reply: @escaping (UpdateChoice) -> Void) {
        events.append("ask \(offer.version)" + (canSkip ? " skip" : ""))
        self.reply = reply
    }

    func progress(_ step: UpdateStep, action: (() -> Void)?) {
        let name: String
        switch step {
        case .checking: name = "checking"
        case .downloading(let fraction): name = "downloading" + (fraction.map { " \($0)" } ?? "")
        case .preparing: name = "preparing"
        case .installing: name = "installing"
        case .waitingToQuit: name = "waitingToQuit"
        }
        let button = action == nil ? "" : (step == .waitingToQuit ? " retry" : " cancel")
        events.append("progress \(name)\(button)")
    }

    func tell(title: String, detail: String, done: @escaping () -> Void) {
        events.append("tell \(title)")
        self.done = done
    }

    func bringToFront() { events.append("front") }
    func close() { events.append("close") }
    func answer(_ choice: UpdateChoice) { reply?(choice) }
    func acknowledge() { done?() }
}

final class UpdatesTests: XCTestCase {
    override func setUp() { Copy.language = .english }
    override func tearDown() { Copy.language = .english }

    private let feed: [String: Any] = ["SUFeedURL": "https://github.com/mssoftjp/LazySpace/releases/latest/download/appcast.xml"]

    /// Only a distributed copy that can replace itself checks: development builds have no feed, and tests, the disk image,
    /// translocated copies, and read-only volumes never start an updater.
    func testOnlyAnInstalledReleaseChecksForUpdates() {
        XCTAssertTrue(UpdateEligibility.allowed(bundlePath: "/Applications/LazySpace.app", info: feed, underTests: false, onReadOnlyVolume: false))
        XCTAssertFalse(UpdateEligibility.allowed(bundlePath: "/Applications/LazySpace.app", info: [:], underTests: false, onReadOnlyVolume: false))
        XCTAssertFalse(UpdateEligibility.allowed(bundlePath: "/Applications/LazySpace.app", info: ["SUFeedURL": ""], underTests: false, onReadOnlyVolume: false))
        XCTAssertFalse(UpdateEligibility.allowed(bundlePath: "/Applications/LazySpace.app", info: feed, underTests: true, onReadOnlyVolume: false))
        XCTAssertFalse(UpdateEligibility.allowed(bundlePath: "/Volumes/LazySpace/LazySpace.app", info: feed, underTests: false, onReadOnlyVolume: true))
        XCTAssertFalse(UpdateEligibility.allowed(bundlePath: "/private/var/folders/xy/T/AppTranslocation/1A2B/d/LazySpace.app", info: feed, underTests: false, onReadOnlyVolume: false))
    }

    func testThisTestRunIsRecognizedAsTests() {
        XCTAssertTrue(UpdateEligibility.runningUnderTests)
    }

    /// The update line sits with Settings and Quit, so it is there while paused too, and only while an update is available.
    func testTheMenuOffersAnAvailableUpdateBesideSettings() {
        var s = sampleStatus()
        XCTAssertFalse(StatusMenuCopy.topEntries(status: s, spaceCount: 1, modeCount: 1).contains { $0.kind == .update })
        s.availableUpdate = UpdateOffer(version: "0.5.1", build: "202611010000")
        let entries = StatusMenuCopy.topEntries(status: s, spaceCount: 1, modeCount: 1)
        let update = entries.firstIndex { $0.kind == .update }
        XCTAssertEqual(update.map { entries[$0].title }, "Update LazySpace to 0.5.1…")
        XCTAssertEqual(update.map { entries[$0 + 1].kind }, .settings)
        s.paused = true
        XCTAssertEqual(StatusMenuCopy.topEntries(status: s, spaceCount: 1, modeCount: 1).map(\.kind), [.globalPause, .update, .settings, .status, .quit])
        Copy.language = .japanese
        XCTAssertEqual(StatusMenuCopy.topEntries(status: s, spaceCount: 1, modeCount: 1).first { $0.kind == .update }?.title, "LazySpace 0.5.1にアップデート…")
    }

    /// `status` shows an available update in one row, and `--json` carries it; without one, neither mentions updates.
    func testStatusReportsAnAvailableUpdate() throws {
        var s = sampleStatus()
        XCTAssertFalse(CLI.statusText(s).contains("Update"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains("availableUpdate"))
        s.availableUpdate = UpdateOffer(version: "0.5.1", build: "202611010000")
        XCTAssertTrue(CLI.statusText(s).contains("LazySpace 0.5.1 is available"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        XCTAssertEqual(json?["availableUpdate"] as? [String: String], ["version": "0.5.1", "build": "202611010000"])
        Copy.language = .japanese
        XCTAssertTrue(CLI.statusText(s).contains("LazySpace 0.5.1が利用できます"))
    }

    /// A scheduled check shows nothing: the update waits in the menu and About until the user asks, then one alert asks.
    func testAScheduledUpdateWaitsQuietlyUntilTheUserAsks() {
        let dialogs = FakeDialogs()
        let flow = UpdateFlow(dialogs: dialogs)
        var changes = 0
        flow.onChange = { changes += 1 }
        var replies: [UpdateChoice] = []
        flow.found(UpdateOffer(version: "0.5.1", build: "2"), userInitiated: false, canSkip: true) { replies.append($0) }
        XCTAssertEqual(flow.offer, UpdateOffer(version: "0.5.1", build: "2"))
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(dialogs.events, [])
        flow.focus()
        XCTAssertEqual(dialogs.events, ["ask 0.5.1 skip"])
        flow.focus()
        XCTAssertEqual(dialogs.events, ["ask 0.5.1 skip", "front"], "asking again brings the open alert forward")
        dialogs.answer(.later)
        XCTAssertEqual(replies, [.later])
        XCTAssertNotNil(flow.offer, "the offer stays until Sparkle ends the session")
        flow.ended()
        XCTAssertNil(flow.offer)
        XCTAssertEqual(dialogs.events.last, "close")
        flow.found(UpdateOffer(version: "0.5.1", build: "2"), userInitiated: false, canSkip: true) { _ in }
        XCTAssertEqual(dialogs.events.last, "close", "the next session is quiet again")
    }

    /// A check the user starts shows its progress only if it takes over a second, so a quick answer appears alone.
    func testACheckTheUserStartsShowsProgressOnlyWhenSlow() {
        let dialogs = FakeDialogs()
        var delayed: [(TimeInterval, () -> Void)] = []
        let flow = UpdateFlow(dialogs: dialogs, after: { delayed.append(($0, $1)) })
        flow.userStartedCheck(cancel: {})
        XCTAssertEqual(delayed.map(\.0), [1])
        flow.found(UpdateOffer(version: "0.5.1", build: "2"), userInitiated: true, canSkip: false) { _ in }
        delayed[0].1()
        XCTAssertEqual(dialogs.events, ["ask 0.5.1"])
        flow.ended()
        flow.userStartedCheck(cancel: {})
        delayed[1].1()
        XCTAssertEqual(dialogs.events.last, "progress checking cancel")
    }

    /// Asking while a scheduled check is still fetching: the update it finds is put to the user at once.
    func testAskingDuringAScheduledCheckAsksWhenItFinds() {
        let dialogs = FakeDialogs()
        let flow = UpdateFlow(dialogs: dialogs)
        flow.userAsked()
        flow.found(UpdateOffer(version: "0.5.1", build: "2"), userInitiated: false, canSkip: true) { _ in }
        XCTAssertEqual(dialogs.events, ["ask 0.5.1 skip"])
    }

    /// Errors and "up to date" appear only while the user takes part in the session, in LazySpace's words;
    /// otherwise Sparkle hears at once that they were shown.
    func testMessagesAppearOnlyWhileTheUserIsInvolved() {
        let dialogs = FakeDialogs()
        let flow = UpdateFlow(dialogs: dialogs, after: { _, _ in })
        var acknowledged = 0
        flow.failed(detail: "Network", done: { acknowledged += 1 })
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(dialogs.events, [])
        flow.userStartedCheck(cancel: {})
        flow.upToDate(detail: "Version 0.5.0 is the newest version.", done: { acknowledged += 1 })
        XCTAssertEqual(dialogs.events.last, "tell LazySpace is up to date")
        XCTAssertEqual(acknowledged, 1)
        dialogs.acknowledge()
        XCTAssertEqual(acknowledged, 2)
        flow.ended()
        flow.userAsked()
        flow.failed(detail: "Network", done: {})
        XCTAssertEqual(dialogs.events.last, "tell Could not check for updates")
        flow.downloadStarted(cancel: {})
        flow.failed(detail: "Disk full", done: {})
        XCTAssertEqual(dialogs.events.last, "tell The update could not be installed")
    }

    /// Choosing Install is the only confirmation: download, preparation, and installation follow in one progress alert.
    func testInstallingShowsProgressWithoutASecondPrompt() {
        let dialogs = FakeDialogs()
        let flow = UpdateFlow(dialogs: dialogs)
        flow.found(UpdateOffer(version: "0.5.1", build: "2"), userInitiated: true, canSkip: true) { _ in }
        flow.downloadStarted(cancel: {})
        flow.expect(200)
        flow.received(50)
        flow.received(250)
        flow.preparing()
        var ready: [UpdateChoice] = []
        flow.readyToInstall { ready.append($0) }
        flow.installing(applicationTerminated: false, retry: {})
        flow.installing(applicationTerminated: true, retry: {})
        XCTAssertEqual(dialogs.events, [
            "ask 0.5.1 skip",
            "progress downloading cancel", "progress downloading 0.0 cancel", "progress downloading 0.25 cancel", "progress downloading 1.0 cancel",
            "progress preparing", "progress waitingToQuit retry", "progress installing",
        ])
        XCTAssertEqual(ready, [.install])
    }

    /// The alerts are standard macOS alerts: Install is the default, Remind Me Later answers Escape, Skip only when allowed.
    func testTheUpdateAlertOffersInstallLaterAndSkip() throws {
        let alerts = UpdateAlerts(currentVersion: "0.5.0")
        var shown = 0
        alerts.present = { _ in shown += 1 }
        var replies: [UpdateChoice] = []
        alerts.ask(UpdateOffer(version: "0.5.1", build: "2"), canSkip: true) { replies.append($0) }
        let alert = try XCTUnwrap(alerts.alert)
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(alert.messageText, "LazySpace 0.5.1 is available")
        XCTAssertEqual(alert.informativeText, "You have version 0.5.0. LazySpace quits and reopens to finish installing.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Install Update", "Remind Me Later", "Skip This Version"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}", ""])
        alert.buttons[2].performClick(nil)
        XCTAssertEqual(replies, [.skip])
        XCTAssertNil(alerts.alert, "answering closes the alert")
        alerts.ask(UpdateOffer(version: "0.5.1", build: "2"), canSkip: false) { _ in }
        XCTAssertEqual(alerts.alert?.buttons.map(\.title), ["Install Update", "Remind Me Later"])
        Copy.language = .japanese
        alerts.ask(UpdateOffer(version: "0.5.1", build: "2"), canSkip: true) { _ in }
        XCTAssertEqual(alerts.alert?.messageText, "LazySpace 0.5.1が利用できます")
        XCTAssertEqual(alerts.alert?.buttons.map(\.title), ["アップデートをインストール", "あとで通知", "このバージョンをスキップ"])
    }

    /// One progress alert follows the steps: a bar, Cancel while it can be cancelled, then Quit and Install if quitting was held up.
    func testTheProgressAlertFollowsTheSteps() throws {
        let alerts = UpdateAlerts(currentVersion: "0.5.0")
        var shown = 0
        alerts.present = { _ in shown += 1 }
        var cancelled = 0
        alerts.progress(.downloading(fraction: nil), action: { cancelled += 1 })
        let alert = try XCTUnwrap(alerts.alert)
        let bar = try XCTUnwrap(alert.accessoryView as? NSProgressIndicator)
        XCTAssertEqual(alert.messageText, "Downloading the update…")
        XCTAssertTrue(bar.isIndeterminate)
        alerts.progress(.downloading(fraction: 0.5), action: { cancelled += 1 })
        XCTAssertTrue(alerts.alert === alert, "the same alert follows the download")
        XCTAssertFalse(bar.isIndeterminate)
        XCTAssertEqual(bar.doubleValue, 0.5)
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel"])
        XCTAssertEqual(shown, 1, "progress updates in place and does not take the focus again")
        alert.buttons[0].performClick(nil)
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(alerts.alert)
        alerts.progress(.preparing, action: nil)
        XCTAssertEqual(alerts.alert?.messageText, "Preparing to install…")
        XCTAssertEqual(alerts.alert?.buttons.map(\.isEnabled), [false])
        alerts.progress(.installing, action: nil)
        XCTAssertEqual((alerts.alert?.accessoryView as? NSProgressIndicator)?.isIndeterminate, true, "a full bar would read as done")
        var retried = 0
        alerts.progress(.waitingToQuit, action: { retried += 1 })
        XCTAssertNil(alerts.alert?.accessoryView, "nothing progresses while waiting")
        XCTAssertEqual(alerts.alert?.informativeText, "The update is downloaded. LazySpace reopens after installing.")
        XCTAssertEqual(alerts.alert?.buttons.map(\.title), ["Quit and Install"])
        alerts.alert?.buttons[0].performClick(nil)
        XCTAssertEqual(retried, 1)
        XCTAssertNotNil(alerts.alert, "the alert stays while LazySpace quits")
        alerts.close()
        XCTAssertNil(alerts.alert)
    }

    private func sampleStatus() -> AppStatus {
        AppStatus(
            availability: .manualOnly, availabilityReason: "Manual arrangement only.", manualAvailable: true, manualReason: "Available",
            autoAvailable: false, autoReason: "Not checked", currentSpaceManaged: false, trusted: true,
            spaceObservation: true, inputObservation: "none", paused: false, progress: .idle, progressText: "",
            waiting: [], floating: [], zoomed: nil, lastRefusal: nil,
            configPath: "/tmp/config.toml", configError: nil, focusedWindow: nil, lastResult: nil, version: "0.5.0",
            mode: "main", modes: ["main"], loginItem: "Off", loginItemEnabled: false)
    }
}
