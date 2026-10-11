import AppKit
import Foundation
import LayoutCore
import MacSupport
import Operations

// MARK: - windows

struct WindowsReport: Codable {
    var probe = "windows"
    var env: EnvironmentRecord
    var trusted: Bool
    var spaceID: UInt64?
    var workArea: CGRect
    var observed: [ObservedWindow]
    var targets: [WindowID]
    var excluded: [String]
    var subject: WindowID?
    var subjectApp: String?
    var original: CGRect?
    var requested: CGRect?
    var writeResult: String?
    var readback: CGRect?
    var matchedWithin1pt: Bool?
    var restored: CGRect?
    var restoreMatched: Bool?
    var timings: [Timing]
    var verdict: String
}

enum ProbeWindows {
    static func run(args: Args, env: EnvironmentRecord, outDir: String) {
        let system = MacWindowSystem()
        var timings: [Timing] = []
        var snap: Snapshot!
        timings.append(Timing(label: "snapshot", ms: ms { snap = system.snapshot() }))
        let inspection = TargetSelection.inspect(snap)
        var report = WindowsReport(
            env: env, trusted: snap.trusted, spaceID: snap.spaceID, workArea: snap.workArea, observed: snap.windows,
            targets: inspection.targets.map(\.id), excluded: inspection.excluded.map { "\($0.window.app) \($0.window.id): \($0.reason)" },
            timings: [], verdict: "")
        defer { report.timings = timings; _ = Report.write(report, name: "windows", dir: outDir) }

        guard snap.trusted else { report.verdict = "NOT_TRUSTED: AX not allowed. Do not proceed past the permission dialog alone"; return }
        let wanted = args["app"]
        guard let subject = inspection.targets.first(where: { wanted == nil || $0.app == wanted }) else {
            report.verdict = "NO_SUBJECT: no standard target window on the current Space"
            return
        }
        report.subject = subject.id
        report.subjectApp = subject.app
        report.original = subject.frame
        let area = snap.workArea
        let requested = CGRect(x: floor(area.minX + 40), y: floor(area.minY + 40), width: floor(area.width / 2) - 80, height: floor(area.height) - 80)
        report.requested = requested
        var write: WriteResult = .issued
        timings.append(Timing(label: "write", ms: ms { write = system.writeFrame(subject.id, frame: requested, timeout: 2) }))
        report.writeResult = "\(write)"
        Thread.sleep(forTimeInterval: 0.1)
        var read: FrameRead = .gone
        timings.append(Timing(label: "readback", ms: ms { read = system.readFrame(subject.id) }))
        if case .frame(let f) = read {
            report.readback = f
            report.matchedWithin1pt = f.matches(requested, tolerance: 1)
        }
        Thread.sleep(forTimeInterval: 0.1)
        _ = system.writeFrame(subject.id, frame: subject.frame, timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        if case .frame(let f) = system.readFrame(subject.id) {
            report.restored = f
            report.restoreMatched = f.matches(subject.frame, tolerance: 1)
        }
        report.verdict = (report.matchedWithin1pt == true && report.restoreMatched == true) ? "PASS" : "FAIL: readback does not match the request"
    }
}

// MARK: - spaces

struct SpacesReport: Codable {
    struct WindowSpaces: Codable { var id: WindowID; var app: String; var spaces: [UInt64]; var membership: String }
    struct Change: Codable { var atMs: Double; var from: UInt64?; var to: UInt64? }
    var probe = "spaces"
    var env: EnvironmentRecord
    var available: Bool
    var missingSymbols: [String]
    var activeSpace: UInt64?
    var activeSpaceType: Int32?
    var managed: [SpaceObserver.ManagedDisplay]
    var windows: [WindowSpaces]
    var unknownCount: Int
    var watchSeconds: Double
    var polledChanges: [Change]
    var notificationCount: UInt64
    var verdict: String
}

enum ProbeSpaces {
    static func run(args: Args, env: EnvironmentRecord, outDir: String) {
        let observer = SpaceObserver()
        let system = MacWindowSystem()
        let snap = system.snapshot()
        var report = SpacesReport(
            env: env, available: observer != nil, missingSymbols: PrivateSymbols_missing(), activeSpace: observer?.activeSpace(),
            activeSpaceType: observer?.activeSpace().flatMap { observer?.spaceType($0) }, managed: observer?.managedDisplays() ?? [],
            windows: snap.windows.map { .init(id: $0.id, app: $0.app, spaces: observer?.spaces(for: $0.id.raw) ?? [], membership: $0.membership.rawValue) },
            unknownCount: snap.windows.filter { $0.membership == .unknown }.count,
            watchSeconds: args.double("watch", 0), polledChanges: [], notificationCount: 0, verdict: "")
        guard let observer else {
            report.verdict = "UNAVAILABLE: SkyLight symbols missing. Do not substitute guessed numbers or custom workspaces"
            _ = Report.write(report, name: "spaces", dir: outDir)
            return
        }
        if report.watchSeconds > 0 {
            let counter = SpaceChangeCounter()
            var last = observer.activeSpace()
            let clock = ContinuousClock()
            let t0 = clock.now
            let deadline = Date().addingTimeInterval(report.watchSeconds)
            FileHandle.standardError.write("watching space changes for \(report.watchSeconds)s — switch Spaces now\n".data(using: .utf8)!)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let now = observer.activeSpace()
                if now != last {
                    let d = clock.now - t0
                    report.polledChanges.append(.init(atMs: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, from: last, to: now))
                    last = now
                }
            }
            report.notificationCount = counter.count
        }
        let ok = report.activeSpace != nil && !report.managed.isEmpty
        if report.watchSeconds > 0 {
            report.verdict = ok && !report.polledChanges.isEmpty ? "PASS" : (ok ? "PARTIAL: no switch observed (check that a switch was made)" : "FAIL")
        } else {
            report.verdict = ok ? "PASS(no watch)" : "FAIL: cannot read the active space or managed displays"
        }
        _ = Report.write(report, name: "spaces", dir: outDir)
    }

    static func PrivateSymbols_missing() -> [String] { EnvironmentRecord.capture().missingPrivateSymbols }
}

// MARK: - constraints

struct ConstraintsReport: Codable {
    struct Case: Codable {
        var id: WindowID
        var app: String
        var original: CGRect
        var tinyRequested: CGSize
        var tinyResult: CGSize?
        var minEstimate: CGSize?
        var hugeRequested: CGSize
        var hugeResult: CGSize?
        var maxEstimate: CGSize?
        var fixedSize: Bool?
        var restored: Bool
        var writeMs: [Double]
    }
    var probe = "constraints"
    var env: EnvironmentRecord
    var app: String
    var cases: [Case]
    var verdict: String
}

enum ProbeConstraints {
    static func run(args: Args, env: EnvironmentRecord, outDir: String) {
        guard let app = args["app"] else { print("--app is required"); exit(2) }
        let system = MacWindowSystem()
        let snap = system.snapshot()
        let inspection = TargetSelection.inspect(snap)
        var report = ConstraintsReport(env: env, app: app, cases: [], verdict: "")
        let area = snap.workArea
        for t in inspection.targets where t.app == app {
            var c = ConstraintsReport.Case(id: t.id, app: t.app, original: t.frame, tinyRequested: CGSize(width: 50, height: 50), hugeRequested: area.size, restored: false, writeMs: [])
            let tiny = CGRect(origin: CGPoint(x: area.minX + 20, y: area.minY + 20), size: c.tinyRequested)
            c.writeMs.append(ms { _ = system.writeFrame(t.id, frame: tiny, timeout: 2) })
            Thread.sleep(forTimeInterval: 0.15)
            if case .frame(let f) = system.readFrame(t.id) {
                c.tinyResult = f.size
                c.minEstimate = CGSize(width: f.width > c.tinyRequested.width + 1 ? f.width : 0, height: f.height > c.tinyRequested.height + 1 ? f.height : 0)
            }
            let huge = CGRect(origin: area.origin, size: c.hugeRequested)
            c.writeMs.append(ms { _ = system.writeFrame(t.id, frame: huge, timeout: 2) })
            Thread.sleep(forTimeInterval: 0.15)
            if case .frame(let f) = system.readFrame(t.id) {
                c.hugeResult = f.size
                c.maxEstimate = CGSize(width: f.width < c.hugeRequested.width - 1 ? f.width : 0, height: f.height < c.hugeRequested.height - 1 ? f.height : 0)
                if let tinyResult = c.tinyResult {
                    c.fixedSize = abs(tinyResult.width - f.width) <= 1 && abs(tinyResult.height - f.height) <= 1
                }
            }
            c.writeMs.append(ms { _ = system.writeFrame(t.id, frame: t.frame, timeout: 2) })
            Thread.sleep(forTimeInterval: 0.15)
            if case .frame(let f) = system.readFrame(t.id) { c.restored = f.matches(t.frame, tolerance: 1) }
            report.cases.append(c)
        }
        if report.cases.isEmpty {
            report.verdict = "NO_SUBJECT: no standard window of \(app) on the current Space"
        } else {
            let allRestored = report.cases.allSatisfy(\.restored)
            report.verdict = allRestored ? "PASS: refusal / correction identified" : "PARTIAL: some windows were not restored exactly"
        }
        _ = Report.write(report, name: "constraints", dir: outDir)
    }
}

// MARK: - input

struct InputReport: Codable {
    var probe = "input"
    var env: EnvironmentRecord
    var mode: String
    var seconds: Double
    var total: UInt64
    var mouseDown: UInt64
    var drag: UInt64
    var key: UInt64
    var scroll: UInt64
    var synthetic: Bool
    var verdict: String
}

enum ProbeInput {
    static func run(args: Args, env: EnvironmentRecord, outDir: String) {
        let monitor = InputMonitor()
        let mode = monitor.start()
        let seconds = args.double("seconds", 5)
        FileHandle.standardError.write("mode=\(mode.rawValue). observing input for \(seconds)s — click / drag / type now\n".data(using: .utf8)!)
        if args["synth"] != nil {
            // Mechanism check: posts one harmless scroll (delta 0) at the HID level. Not a substitute for real input.
            Thread {
                Thread.sleep(forTimeInterval: 1.0)
                if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0) {
                    e.post(tap: .cghidEventTap)
                }
            }.start()
        }
        Thread.sleep(forTimeInterval: seconds)
        let b = monitor.breakdown
        let total = monitor.count
        monitor.stop()
        let verdict: String
        if mode == .unavailable { verdict = "FAIL: cannot create the event tap (Accessibility / Input Monitoring)" }
        else if total == 0 { verdict = "INCONCLUSIVE: 0 callbacks. No input, or input not observed. Not treated as protected" }
        else if args["synth"] != nil { verdict = "MECHANISM_OK: synthetic events observed. Not evidence for real input" }
        else { verdict = "PASS" }
        _ = Report.write(InputReport(env: env, mode: mode.rawValue, seconds: seconds, total: total, mouseDown: b.mouseDown, drag: b.drag, key: b.key, scroll: b.scroll, synthetic: args["synth"] != nil, verdict: verdict), name: "input", dir: outDir)
    }
}

// MARK: - interrupt

struct InterruptReport: Codable {
    var probe = "interrupt"
    var env: EnvironmentRecord
    var app: String
    var pid: Int32?
    var subject: WindowID?
    var timeoutRequested: Double
    var stoppedReadMs: Double?
    var stoppedReadResult: String?
    var stoppedWriteMs: Double?
    var stoppedWriteResult: String?
    var heartbeatTicks: Int
    var heartbeatMaxGapMs: Double
    var resumedReadResult: String?
    var restored: Bool?
    var verdict: String
}

enum ProbeInterrupt {
    static func run(args: Args, env: EnvironmentRecord, outDir: String) {
        guard let app = args["app"] else { print("--app is required"); exit(2) }
        let timeout = args.double("timeout", 1.0)
        let system = MacWindowSystem()
        let snap = system.snapshot()
        let inspection = TargetSelection.inspect(snap)
        var report = InterruptReport(env: env, app: app, timeoutRequested: timeout, heartbeatTicks: 0, heartbeatMaxGapMs: 0, verdict: "")
        guard let t = inspection.targets.first(where: { $0.app == app }) else {
            report.verdict = "NO_SUBJECT"
            _ = Report.write(report, name: "interrupt", dir: outDir)
            return
        }
        report.pid = t.pid
        report.subject = t.id

        // A heartbeat on another thread measures that a bounded request does not stall other work.
        let heartbeat = Heartbeat()
        heartbeat.start()

        kill(t.pid, SIGSTOP)
        Thread.sleep(forTimeInterval: 0.2)
        var read: FrameRead = .gone
        report.stoppedReadMs = ms { read = system.readFrame(t.id) }
        report.stoppedReadResult = "\(read)"
        var write: WriteResult = .issued
        let moved = t.frame.offsetBy(dx: 30, dy: 30)
        report.stoppedWriteMs = ms { write = system.writeFrame(t.id, frame: moved, timeout: timeout) }
        report.stoppedWriteResult = "\(write)"
        kill(t.pid, SIGCONT)
        Thread.sleep(forTimeInterval: 0.5)
        heartbeat.stop()
        report.heartbeatTicks = heartbeat.ticks
        report.heartbeatMaxGapMs = heartbeat.maxGapMs

        let after = system.readFrame(t.id)
        report.resumedReadResult = "\(after)"
        _ = system.writeFrame(t.id, frame: t.frame, timeout: 2)
        Thread.sleep(forTimeInterval: 0.15)
        if case .frame(let f) = system.readFrame(t.id) { report.restored = f.matches(t.frame, tolerance: 1) }

        let boundedStopped = (report.stoppedReadMs ?? 0) <= timeout * 1000 * 2.5 && (report.stoppedWriteMs ?? 0) <= timeout * 1000 * 2.5
        let heartbeatOK = report.heartbeatMaxGapMs < 250
        report.verdict = boundedStopped && heartbeatOK ? "PASS: returned within the deadline; other threads not blocked" : "FAIL: bounded=\(boundedStopped) heartbeat=\(heartbeatOK)"
        _ = Report.write(report, name: "interrupt", dir: outDir)
    }
}

final class Heartbeat {
    private let lock = NSLock()
    private(set) var ticks = 0
    private(set) var maxGapMs = 0.0
    private var running = false
    private var thread: Thread?

    func start() {
        running = true
        thread = Thread { [self] in
            let clock = ContinuousClock()
            var last = clock.now
            while self.lock.withLock({ self.running }) {
                Thread.sleep(forTimeInterval: 0.05)
                let now = clock.now
                let d = now - last
                let gap = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                self.lock.withLock {
                    self.ticks += 1
                    self.maxGapMs = max(self.maxGapMs, gap)
                }
                last = now
            }
        }
        thread?.start()
    }

    func stop() { lock.withLock { running = false } }
}
