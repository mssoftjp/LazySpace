import AppKit
import Copy
import Foundation
import Settings
import XCTest
@testable import LazySpace

/// Stands in for the notification center: records posts and withdrawals, and answers permission like macOS.
final class FakeNotifier: Notifying {
    var onActivate: ((String) -> Void)?
    /// What macOS has stored; `requestAuthorization` asks only while it is `.notDetermined`.
    var stored: NotificationPermission = .notDetermined
    /// What the user answers when asked.
    var answer: NotificationPermission = .allowed
    /// Keeps the request open until `finishRequest()`, like a prompt the user has not answered yet.
    var holdRequests = false
    private(set) var requests = 0
    private(set) var posted: [Notice] = []
    private(set) var withdrawn: [String] = []
    private(set) var settingsOpened = 0
    private var pending: [(NotificationPermission) -> Void] = []
    /// Keeps permission reads open until `finishRead(_:_:)`, so answers can arrive late or out of order.
    var holdReads = false
    private(set) var reads = 0
    private var pendingReads: [(NotificationPermission) -> Void] = []

    func requestAuthorization(_ completion: @escaping (NotificationPermission) -> Void) {
        requests += 1
        if holdRequests { pending.append(completion); return }
        if stored == .notDetermined { stored = answer }
        completion(stored)
    }

    /// Answers the open requests; `sampled` stands for an answer macOS read before `stored` changed.
    func finishRequest(_ sampled: NotificationPermission? = nil) {
        if stored == .notDetermined { stored = answer }
        let waiting = pending
        pending = []
        waiting.forEach { $0(sampled ?? stored) }
    }

    func permission(_ completion: @escaping (NotificationPermission) -> Void) {
        reads += 1
        if holdReads { pendingReads.append(completion); return }
        completion(stored)
    }

    /// Answers the read started `index`-th among those held, with what macOS said when it was sampled.
    func finishRead(_ index: Int, _ answer: NotificationPermission) { pendingReads[index](answer) }
    func post(_ notice: Notice) { posted.append(notice) }
    func withdraw(identifier: String) { withdrawn.append(identifier) }
    func openSettings() { settingsOpened += 1 }
}

/// What reaches macOS for each published problem, given the checkbox and the permission.
final class AttentionNotifierTests: XCTestCase {
    private let stageManager = AttentionState(reason: .automaticArrangement(.stageManager), notify: true)

    override func setUp() { Copy.apply(setting: "en") }

    func testAttachingWithdrawsWhatAnEarlierRunLeft() {
        let fake = FakeNotifier()
        _ = AttentionNotifier(notifier: fake)
        XCTAssertEqual(fake.withdrawn, [AttentionNotifier.identifier])
        XCTAssertEqual(fake.requests, 0, "attaching never asks macOS")
    }

    func testNothingIsSentOrAskedWhileTheKindIsOff() {
        let fake = FakeNotifier()
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(AttentionState(reason: .configuration, notify: false))
        notifier.update(AttentionState(reason: .accessibility, notify: false))
        XCTAssertEqual(fake.posted, [])
        XCTAssertEqual(fake.requests, 0)
    }

    func testTurningOnAsksOnceAndPostsTheCurrentProblemOnce() {
        let fake = FakeNotifier()
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(fake.posted.count, 1)
        XCTAssertEqual(fake.posted.first?.identifier, AttentionNotifier.identifier)
        XCTAssertEqual(fake.posted.first?.title, "Automatic arrangement stopped")
        XCTAssertEqual(fake.posted.first?.reason, "automatic-arrangement")
        XCTAssertTrue(fake.posted.first?.body.contains("Stage Manager") == true)
        notifier.update(stageManager)
        XCTAssertEqual(fake.posted.count, 1, "the same problem is not posted again")
        XCTAssertEqual(fake.requests, 1)
    }

    func testAlreadyAllowedPostsOnceWhenTurnedOn() {
        let fake = FakeNotifier()
        fake.stored = .allowed
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(AttentionState(reason: .configuration, notify: false))
        notifier.update(AttentionState(reason: .configuration, notify: true))
        XCTAssertEqual(fake.posted.map(\.reason), ["configuration"])
    }

    func testDeniedIsNeverCountedAsDelivered() {
        let fake = FakeNotifier()
        fake.answer = .denied
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        XCTAssertEqual(fake.posted, [])
        XCTAssertEqual(notifier.permission, .denied)
        // The user allows LazySpace in System Settings; the next permission read posts the problem that still holds.
        fake.stored = .allowed
        notifier.refreshPermission()
        XCTAssertEqual(fake.posted.count, 1)
    }

    func testANewProblemRereadsPermissionFirst() {
        let fake = FakeNotifier()
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        XCTAssertEqual(fake.posted.count, 1)
        fake.stored = .denied
        notifier.update(AttentionState(reason: .automaticArrangement(.sharedSpaces), notify: true))
        XCTAssertEqual(fake.posted.count, 1, "nothing is posted while macOS does not allow it")
        fake.stored = .allowed
        notifier.update(AttentionState(reason: .configuration, notify: true))
        XCTAssertEqual(fake.posted.map(\.reason), ["automatic-arrangement", "configuration"])
    }

    func testTheEndOfTheProblemAndTurningOffWithdraw() {
        let fake = FakeNotifier()
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        notifier.update(AttentionState(reason: nil, notify: true))
        XCTAssertEqual(fake.withdrawn, [AttentionNotifier.identifier, AttentionNotifier.identifier])
        notifier.update(stageManager)
        notifier.update(AttentionState(reason: .automaticArrangement(.stageManager), notify: false))
        XCTAssertEqual(fake.withdrawn.count, 3)
        XCTAssertEqual(fake.posted.count, 2)
        notifier.withdraw()
        XCTAssertEqual(fake.withdrawn.count, 4)
    }

    func testALateAnswerUsesTheCurrentCheckboxAndProblem() {
        let fake = FakeNotifier()
        fake.holdRequests = true
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        notifier.update(AttentionState(reason: .automaticArrangement(.stageManager), notify: false))
        notifier.update(stageManager)
        XCTAssertEqual(fake.requests, 1, "requests are coalesced while macOS is asking")
        notifier.update(AttentionState(reason: .configuration, notify: true))
        fake.finishRequest()
        XCTAssertEqual(fake.posted.map(\.reason), ["configuration"])

        let off = FakeNotifier()
        off.holdRequests = true
        let turnedOff = AttentionNotifier(notifier: off)
        turnedOff.update(stageManager)
        turnedOff.update(AttentionState(reason: .automaticArrangement(.stageManager), notify: false))
        off.finishRequest()
        XCTAssertEqual(off.posted, [], "an answer that arrives after the box was turned off posts nothing")
    }

    /// A slow refusal sampled before the user allowed LazySpace in System Settings does not hide the problem: the read asked
    /// for meanwhile runs after it and has the last word.
    func testADelayedRefusalDoesNotHideALaterAllow() {
        let fake = FakeNotifier()
        fake.holdRequests = true
        fake.holdReads = true
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        fake.stored = .allowed
        notifier.refreshPermission()
        XCTAssertEqual(fake.reads, 0, "a read waits for the open request")
        fake.finishRequest(.denied)
        XCTAssertEqual(fake.posted, [])
        XCTAssertEqual(fake.reads, 1, "the waiting read starts after the answer")
        fake.finishRead(0, .allowed)
        XCTAssertEqual(notifier.permission, .allowed)
        XCTAssertEqual(fake.posted.count, 1)
    }

    /// Answers can never arrive out of order: one question at a time, and the reads asked for meanwhile become one more.
    func testRefreshesWhileOneIsOpenBecomeOneMoreRead() {
        let fake = FakeNotifier()
        fake.stored = .allowed
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        XCTAssertEqual(fake.posted.count, 1)
        fake.holdReads = true
        notifier.refreshPermission()
        notifier.refreshPermission()
        notifier.refreshPermission()
        XCTAssertEqual(fake.reads, 1)
        fake.finishRead(0, .allowed)
        XCTAssertEqual(fake.reads, 2)
        fake.finishRead(1, .allowed)
        XCTAssertEqual(fake.reads, 2)
        XCTAssertEqual(fake.withdrawn, [AttentionNotifier.identifier])
        XCTAssertEqual(fake.posted.count, 1)
    }

    /// Turning the box off drops a request that was waiting for an open read, so macOS never asks after it was turned off.
    func testTurningOffDropsAWaitingRequest() {
        let fake = FakeNotifier()
        fake.holdReads = true
        let notifier = AttentionNotifier(notifier: fake)
        notifier.refreshPermission()
        notifier.update(stageManager)
        notifier.update(AttentionState(reason: .automaticArrangement(.stageManager), notify: false))
        fake.finishRead(0, .notDetermined)
        XCTAssertEqual(fake.requests, 0)
        XCTAssertEqual(fake.posted, [])
    }

    /// A request that completes without macOS asking (measured for an app run from /tmp) is remembered until another answer.
    func testARequestMacOSDidNotShowIsRememberedUntilAnotherAnswer() {
        let fake = FakeNotifier()
        fake.answer = .notDetermined
        let notifier = AttentionNotifier(notifier: fake)
        var changes = 0
        notifier.onPermissionChange = { changes += 1 }
        notifier.update(stageManager)
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(notifier.permission, .notDetermined)
        XCTAssertTrue(notifier.askFailed)
        XCTAssertEqual(fake.posted, [])
        XCTAssertEqual(changes, 1)
        notifier.refreshPermission()
        XCTAssertTrue(notifier.askFailed, "a read of the same answer does not clear it")
        XCTAssertEqual(changes, 1)
        fake.stored = .allowed
        notifier.refreshPermission()
        XCTAssertFalse(notifier.askFailed)
        XCTAssertEqual(fake.posted.count, 1, "the problem that holds is posted once macOS allows it")
    }

    /// A plain read of .notDetermined only means "not asked yet".
    func testAReadOfNotDeterminedIsNotARefusal() {
        let fake = FakeNotifier()
        fake.holdRequests = true
        let notifier = AttentionNotifier(notifier: fake)
        notifier.refreshPermission()
        XCTAssertEqual(notifier.permission, .notDetermined)
        XCTAssertFalse(notifier.askFailed)
        notifier.update(stageManager)
        fake.finishRequest(.allowed)
        XCTAssertFalse(notifier.askFailed)
        XCTAssertEqual(fake.posted.count, 1)
    }

    /// A read that the change callback starts while an answer is stored waits for the queued one: never two at once.
    func testACallbackDuringAnAnswerDoesNotStartASecondRead() {
        let fake = FakeNotifier()
        fake.holdRequests = true
        fake.holdReads = true
        let notifier = AttentionNotifier(notifier: fake)
        notifier.update(stageManager)
        notifier.refreshPermission()
        notifier.onPermissionChange = { notifier.refreshPermission() }
        fake.finishRequest()
        XCTAssertEqual(fake.reads, 1, "the queued read and the callback's read become one")
    }

    /// The flag alone changing is a change, so Settings shows the line even when .notDetermined was read before.
    func testAChangeOfAskFailedAloneReportsAChange() {
        let fake = FakeNotifier()
        let notifier = AttentionNotifier(notifier: fake)
        var changes = 0
        notifier.onPermissionChange = { changes += 1 }
        notifier.refreshPermission()
        XCTAssertEqual(changes, 1)
        fake.answer = .notDetermined
        notifier.requestAuthorization()
        XCTAssertEqual(notifier.permission, .notDetermined)
        XCTAssertTrue(notifier.askFailed)
        XCTAssertEqual(changes, 2)
    }

    /// Notices are fixed text: nothing from the configuration file, its path, or windows reaches a banner.
    func testNoticesAreFixedTextInBothLanguages() {
        let reasons: [AttentionReason] = [.accessibility, .configuration, .automaticArrangement(.inputUnobservable),
                                          .automaticArrangement(.configUnapplied), .automaticArrangement(.stageManager),
                                          .automaticArrangement(.sharedSpaces)]
        for language in ["en", "ja"] {
            Copy.apply(setting: language)
            for reason in reasons {
                let notice = NotificationCopy.notice(for: reason)
                XCTAssertEqual(notice.identifier, AttentionNotifier.identifier)
                XCTAssertFalse(notice.title.isEmpty)
                XCTAssertFalse(notice.body.isEmpty)
                XCTAssertFalse(notice.body.contains("config.toml"), notice.body)
                XCTAssertFalse(notice.body.contains("/"), notice.body)
                XCTAssertEqual(AttentionReason.Kind(rawValue: notice.reason), reason.kind)
            }
        }
        Copy.apply(setting: "en")
    }
}

/// When the coordinator publishes a problem: transitions only, after two equal reviews, nil at once.
final class AttentionReviewTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!
    private var system: CoordinatorSystem!
    private var coordinator: Coordinator!
    private var published: [AttentionState] = []

    override func setUpWithError() throws {
        Copy.apply(setting: "en")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configURL = root.appendingPathComponent("config.toml")
        try "[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        system = CoordinatorSystem()
        coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = coordinator.reloadConfig(source: "test")
        coordinator.onAttentionChange = { [unowned self] state in published.append(state) }
    }

    override func tearDownWithError() throws {
        drainMain()
        Copy.apply(setting: "en")
        try FileManager.default.removeItem(at: root)
    }

    private func drainMain() {
        let done = expectation(description: "Main drained")
        coordinator.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
    }

    private func tick(_ count: Int = 1) {
        for _ in 0..<count { coordinator.operationsQueue.sync { coordinator.tick() } }
        drainMain()
    }

    private var reasons: [AttentionReason?] { published.map(\.reason) }

    func testHealthyStartPublishesOnlyTheCheckbox() {
        tick(3)
        XCTAssertEqual(published, [AttentionState(reason: nil, notify: true)])
    }

    func testStageManagerAfterTwoReviewsThenEndAtOnce() {
        tick()
        system.stageManagerOn = true
        tick()
        XCTAssertEqual(reasons, [nil], "one review is not enough")
        tick()
        XCTAssertEqual(reasons, [nil, .automaticArrangement(.stageManager)])
        tick(2)
        XCTAssertEqual(published.count, 2, "a problem that holds is published once")
        system.stageManagerOn = false
        tick()
        XCTAssertEqual(reasons, [nil, .automaticArrangement(.stageManager), nil])
    }

    func testAOneReviewFlapIsNotPublished() {
        tick()
        system.inputAvailable = false
        tick()
        system.inputAvailable = true
        tick(2)
        XCTAssertEqual(reasons, [nil])
    }

    func testAnotherCauseIsANewProblemButALanguageChangeIsNot() throws {
        system.stageManagerOn = true
        tick(2)
        XCTAssertEqual(reasons, [nil, .automaticArrangement(.stageManager)])
        try "language = \"ja\"\n[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick(2)
        XCTAssertEqual(reasons, [nil, .automaticArrangement(.stageManager)], "the language does not make it a new problem")
        system.stageManagerOn = false
        system.displaysShareOneSpace = true
        tick(2)
        XCTAssertEqual(reasons.last, .automaticArrangement(.sharedSpaces))
    }

    func testAccessibilityLostOnlyAfterItWasSeenGranted() {
        system.trusted = false
        let launch = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = launch.reloadConfig(source: "test")
        var states: [AttentionState] = []
        launch.onAttentionChange = { states.append($0) }
        for _ in 0..<3 { launch.operationsQueue.sync { launch.tick() } }
        let done = expectation(description: "Main drained")
        launch.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states.map(\.reason), [nil], "no access at launch is Settings' job, not a notification")

        system.trusted = true
        tick()
        system.trusted = false
        system.stageManagerOn = true
        tick(2)
        XCTAssertEqual(reasons, [nil, .accessibility], "access comes before the gate")
        system.trusted = true
        tick(2)
        XCTAssertEqual(reasons.last, .automaticArrangement(.stageManager), "the gate still holds once access is back")
    }

    /// A grant seen between ticks (the system's permission notification) counts as seen.
    func testAGrantSeenBetweenTicksCounts() {
        system.trusted = false
        let launch = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = launch.reloadConfig(source: "test")
        var states: [AttentionState] = []
        launch.onAttentionChange = { states.append($0) }
        system.trusted = true
        launch.checkTrust()
        launch.operationsQueue.sync {}
        system.trusted = false
        for _ in 0..<2 { launch.operationsQueue.sync { launch.tick() } }
        let done = expectation(description: "Main drained")
        launch.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states.last?.reason, .accessibility)
    }

    /// So does a grant seen only by a report between ticks.
    func testAGrantSeenByAReportCounts() {
        system.trusted = false
        let launch = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = launch.reloadConfig(source: "test")
        var states: [AttentionState] = []
        launch.onAttentionChange = { states.append($0) }
        system.trusted = true
        launch.requestAttentionReport()
        launch.operationsQueue.sync {}
        system.trusted = false
        for _ in 0..<2 { launch.operationsQueue.sync { launch.tick() } }
        let done = expectation(description: "Main drained")
        launch.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states.last?.reason, .accessibility)
    }

    func testAConfigurationErrorIsOneProblemWhateverItsText() throws {
        tick()
        try "[gaps\n[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick(2)
        XCTAssertEqual(reasons, [nil, .configuration])
        XCTAssertTrue(published.last?.notify == true, "the last valid configuration keeps the checkbox")
        try "gap = \"wide\"\n[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick(2)
        XCTAssertEqual(reasons, [nil, .configuration], "a different error text is the same problem")
        try "[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick()
        XCTAssertEqual(reasons, [nil, .configuration, nil])
    }

    /// No access since launch still lets a later configuration error through; only the access problem waits for a grant.
    func testAConfigurationErrorWithoutAccessSinceLaunch() throws {
        system.trusted = false
        let launch = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = launch.reloadConfig(source: "test")
        var states: [AttentionState] = []
        launch.onAttentionChange = { states.append($0) }
        try "[gaps\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = launch.reloadConfig(source: "test")
        for _ in 0..<2 { launch.operationsQueue.sync { launch.tick() } }
        let done = expectation(description: "Main drained")
        launch.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states.last, AttentionState(reason: .configuration, notify: true))
    }

    /// A file broken at launch leaves the defaults in use, so the checkbox is off and nothing is posted.
    func testAFileBrokenAtLaunchKeepsNotificationsOff() throws {
        try "[gaps\n[notifications]\nneeds-attention = true\n".write(to: configURL, atomically: true, encoding: .utf8)
        let launch = Coordinator(system: system, store: StateStore(root: root), configURL: configURL, takeCensus: system.census, takeOverview: { nil })
        _ = launch.reloadConfig(source: "launch")
        var states: [AttentionState] = []
        launch.onAttentionChange = { states.append($0) }
        for _ in 0..<3 { launch.operationsQueue.sync { launch.tick() } }
        let done = expectation(description: "Main drained")
        launch.operationsQueue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states, [AttentionState(reason: .configuration, notify: false)])
    }

    /// A report that sees a problem gone also forgets it as a candidate, so one later sighting is not taken as the second review.
    func testAReportThatSeesTheEndResetsTheTwoReviewRule() {
        system.stageManagerOn = true
        tick(2)
        XCTAssertEqual(reasons, [nil, .automaticArrangement(.stageManager)])
        system.stageManagerOn = false
        coordinator.requestAttentionReport()
        drainMain()
        XCTAssertEqual(published.last, AttentionState(reason: nil, notify: true))
        system.stageManagerOn = true
        tick()
        XCTAssertEqual(published.last, AttentionState(reason: nil, notify: true), "one sighting after the report is not enough")
        tick()
        XCTAssertEqual(reasons.last, .automaticArrangement(.stageManager))
    }

    func testPauseIsNeverAProblem() {
        tick()
        coordinator.pause()
        tick(3)
        XCTAssertEqual(reasons, [nil])
    }

    /// A report between ticks follows the reload it comes after and never repeats a problem that is gone.
    func testAReportAfterAFixingReloadDoesNotRepeatTheOldProblem() throws {
        try "[gaps\n".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        tick(2)
        XCTAssertEqual(published.last, AttentionState(reason: .configuration, notify: true))
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        _ = coordinator.reloadConfig(source: "test")
        coordinator.requestAttentionReport()
        drainMain()
        XCTAssertEqual(published.last, AttentionState(reason: nil, notify: false))
        coordinator.requestAttentionReport()
        drainMain()
        XCTAssertEqual(published.count, 4, "a report is sent even when nothing changed")
    }
}

/// AppDelegate wiring, through a fake notifier and a replaced navigation.
final class AttentionWiringTests: XCTestCase {
    func testClicksOpenThePlaceToFixIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                      takeCensus: system.census, takeOverview: { nil })
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        var opened: [AttentionReason.Kind] = []
        delegate.openForAttention = { opened.append($0) }
        let fake = FakeNotifier()
        delegate.attachNotifier(fake)
        fake.onActivate?("accessibility")
        fake.onActivate?("configuration")
        fake.onActivate?("automatic-arrangement")
        fake.onActivate?("unknown")
        XCTAssertEqual(opened, [.accessibility, .configuration, .automaticArrangement])
        XCTAssertEqual(fake.withdrawn, [AttentionNotifier.identifier])

        // Turned on, but macOS says no; the user allows LazySpace in System Settings and comes back without opening Settings.
        fake.answer = .denied
        coordinator.onAttentionChange?(AttentionState(reason: .automaticArrangement(.stageManager), notify: true))
        XCTAssertEqual(fake.posted, [])
        fake.stored = .allowed
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(fake.posted.map(\.reason), ["automatic-arrangement"])
    }

    /// Clicking the macOS prompt opens System Settings; leaving it rereads the permission even when Settings is closed.
    func testLeavingSystemSettingsRereadsPermission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = CoordinatorSystem()
        let coordinator = Coordinator(system: system, store: StateStore(root: root), configURL: root.appendingPathComponent("config.toml"),
                                      takeCensus: system.census, takeOverview: { nil })
        let delegate = AppDelegate(showReadyAtLaunch: false, coordinator: coordinator)
        let fake = FakeNotifier()
        fake.answer = .denied
        delegate.attachNotifier(fake)
        coordinator.onAttentionChange?(AttentionState(reason: .automaticArrangement(.stageManager), notify: true))
        XCTAssertEqual(fake.posted, [])
        fake.stored = .allowed
        delegate.systemSettingsLeft()
        XCTAssertEqual(fake.posted.map(\.reason), ["automatic-arrangement"])
        XCTAssertEqual(AppDelegate.systemSettingsBundleID, "com.apple.systempreferences")

        coordinator.onAttentionChange?(AttentionState(reason: .automaticArrangement(.stageManager), notify: false))
        let reads = fake.reads
        delegate.systemSettingsLeft()
        XCTAssertEqual(fake.reads, reads, "nothing is read while the kind is off")
    }
}
