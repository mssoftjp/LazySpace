// Investigation probe: a way to decide what works and what does not. Not shipped.
import AppKit
import Carbon
import Foundation
import LayoutCore
import MacSupport
import Operations

struct Args {
    var command: String
    var options: [String: String] = [:]

    init(_ argv: [String]) {
        command = argv.count > 1 ? argv[1] : "help"
        var i = 2
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 2 } else { options[key] = "true"; i += 1 }
            } else { i += 1 }
        }
    }

    subscript(_ key: String) -> String? { options[key] }
    func double(_ key: String, _ fallback: Double) -> Double { options[key].flatMap(Double.init) ?? fallback }
}

enum Report {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func write<T: Encodable>(_ value: T, name: String, dir: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(f.string(from: Date())).json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        do {
            data = try encoder.encode(value)
            try data.write(to: url)
        } catch {
            FileHandle.standardError.write("could not write \(url.path): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        print(String(decoding: data, as: UTF8.self))
        FileHandle.standardError.write("wrote \(url.path)\n".data(using: .utf8)!)
        return url.path
    }
}

struct Timing: Codable {
    var label: String
    var ms: Double
}

func ms(_ block: () -> Void) -> Double {
    let c = ContinuousClock()
    let t0 = c.now
    block()
    let d = c.now - t0
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Ending for checks that may post hotkeys (with attempt tags). Waits for the attempt's events to drain first, because the tap dies with this process
/// and could no longer swallow late keys. The wait is best effort (a quiet stretch, not proof nothing is left).
/// A drain timeout ends as failure. Used on both success and failure exits.
func drainAndExit(_ control: SpaceControl, ok: Bool, document: SwitchSequence.Document? = nil) -> Never {
    var drained: Bool?
    DispatchQueue.global(qos: .userInitiated).async {
        let quiet = control.drainPassThrough()
        DispatchQueue.main.async { drained = quiet }
    }
    while drained == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    diag("pass-through tap drained (best effort, 1 s quiet): \(drained!)")
    if drained! == false { diag("tagged events were still flowing when the probe gave up; late keys may not be swallowed after exit") }
    // --json: exactly one document, including the drain result, to stdout.
    if let document { SwitchSequence.emit(document, drained: drained!) }
    exit(ok && drained! ? 0 : 1)
}

let args = Args(CommandLine.arguments)
// --json: diagnostics to stderr, exactly one document to stdout (these two commands).
ProbeOutput.json = args["json"] != nil && ["direct-switch-app", "direct-move"].contains(args.command)
let outDir = args["out"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("lzprobe").path
let env = EnvironmentRecord.capture()

switch args.command {
case "env":
    _ = Report.write(env, name: "env", dir: outDir)

#if LAZYSPACE_PERF
case "arrange-benchmark":
    ReadBenchmark.arrange(args: args, outDir: outDir)
case "read-benchmark":
    ReadBenchmark.run(args: args, outDir: outDir)
case "list-benchmark":
    ReadBenchmark.lists(args: args, outDir: outDir)
#endif

case "windows":
    ProbeWindows.run(args: args, env: env, outDir: outDir)

case "spaces":
    ProbeSpaces.run(args: args, env: env, outDir: outDir)

case "desktop-read", "desktop-switch", "desktop-transfer":
    DesktopDirect.run(args)

case "space-uuids":
    // Read-only: prints each managed-display Space as one record (id, type, uuid), and whether each uuid is unique across displays.
    guard let observer = SpaceObserver() else { print("space observation unavailable"); exit(2) }
    let displays = observer.managedDisplays()
    let unique = SpaceObserver.uniqueUUIDs(displays)
    for display in displays {
        print("display \(display.display) current \(display.currentSpace.map(String.init) ?? "-")")
        for (i, record) in display.records.enumerated() {
            print("  order \(i + 1) id \(record.id) type \(record.type.map(String.init) ?? "-") uuid \(record.uuid ?? "-") uniqueUUID \(unique[record.id] != nil)")
        }
    }

case "direct-move":
    // Check: runs the product's SpaceControl.moveWindow on one window, with the direct path (bridged move -> raise). --stepping uses only the old stepping.
    // Targets a window on the current Space; its AX element is retained by a snapshot first (same condition as Coordinator).
    let command = "direct-move"
    guard let index = Int(args["to"] ?? "") else { SwitchSequence.fail("--window ID | --pid P and --to N are required", command: command) }
    let system = MacWindowSystem()
    _ = system.input.start()
    let seenWindows = system.snapshot().windows
    let wid: CGWindowID
    if let raw = args["window"], let given = UInt32(raw) { wid = given }
    else if let p = args["pid"].flatMap({ Int32($0) }), let w = seenWindows.first(where: { $0.pid == p && $0.membership == .current }) { wid = w.id.raw }
    else { SwitchSequence.fail("--window ID or --pid P (a process with a window on the current Space) is required", command: command) }
    guard let control = SpaceControl(input: system.input) else { SwitchSequence.fail("space observation unavailable", command: command) }
    if args["stepping"] == nil {
        // --no-raise: makes raise fail to exercise the reactivate path (us, then the target app).
        let noRaise = args["no-raise"] != nil
        control.direct = SpaceControl.systemDirectPath(raise: { wid, isCurrent, report in
            if noRaise { return .refused }
            switch system.raise(WindowID(wid), timeout: 1.0, activateIf: isCurrent, activated: { pid in report(pid.map { .requested($0) } ?? .abandoned) }) {
            case .issued: return .issued
            case .timedOut: return .unknown
            case .gone, .rejected: return .refused
            }
        }, focusedWindow: { system.focusedWindowID()?.raw })
    }
    diag("direct move: \(control.direct?.move != nil ? "available" : "unavailable")")
    guard let target = control.spaceID(atIndex: index) else { SwitchSequence.fail("no such space: \(index)", command: command) }
    let read = system.readFrame(WindowID(wid))
    guard case .frame(let frame) = read else {
        let seen = seenWindows.map { "\($0.id.raw):\($0.app):\($0.membership)" }
        SwitchSequence.fail("frame unreadable for \(wid): \(read); snapshot windows: \(seen)", command: command)
    }
    // reactivate is queued on the main thread, so the operation runs on another thread while the main run loop spins (same condition as Coordinator's operations queue).
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    // --hotkey-follow: follows the membership change with "Switch to Desktop N" (only when the conditions hold, as in the product's move-to-space).
    var follow: SpaceControl.HotkeyPlan?
    if args["hotkey-follow"] != nil {
        let desktop = control.desktopNumber(of: target)
        let read = desktop.map { control.desktopShortcut($0) }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        diag("follow desktop \(desktop.map(String.init) ?? "-") shortcut \(read.map { "\($0)" } ?? "-") dock \(dock.map(String.init) ?? "-")")
        if case .usable(let shortcut)? = read, let dock, NSScreen.screens.count == 1, !SpaceOverview.dockReordersByRecentUse() {
            follow = SpaceControl.HotkeyPlan(shortcut: shortcut, dockPID: dock, report: { diag("follow hotkey: \($0)") })
        } else { diag("follow hotkey not eligible; the window raise is used") }
    }
    SwitchSequence.applySettle(args["settle"], to: control, command: command)
    // --then [hotkey|stepping|app:]M: after a successful move (and follow), switches with zero gap (testing follow then another operation). --json gives one document.
    var then: (mode: SwitchSequence.Mode, index: Int)?
    if let spec = args["then"] {
        guard let next = SwitchSequence.parse(spec, default: .app) else { SwitchSequence.fail("--then must be [hotkey|stepping|app:]N", command: command) }
        then = next
    }
    // The result is built on the worker and handed to main (`finished` is read and written only on main).
    var finished: (records: [SwitchSequence.Record], sequenceMs: Double)?
    DispatchQueue.global(qos: .userInitiated).async {
        let sequence = SwitchSequence.Clock()
        let timeline = SwitchSequence.timeline()
        // --no-follow: `sendWindow`, as in the product's default `move-to-space` (changes membership only, no switch; nothing without the direct move).
        let r: Swift.Result<SpaceControl.Result, SpaceControl.Failure>
        var sendNote = ""
        if args["no-follow"] != nil {
            switch control.sendWindow(wid, toSpace: target, timeline: timeline) {
            case .confirmed(let result): r = .success(result)
            case .notIssued(let failure): r = .failure(failure)
            case .unconfirmed(let membership): r = .failure(.unavailable("issued, unconfirmed")); sendNote = " (sent, unconfirmed; membership \(membership))"
            case .elsewhere(let space): r = .failure(.unavailable("issued, elsewhere")); sendNote = " (sent, ended up on \(space))"
            case .interrupted: r = .failure(.interrupted); sendNote = " (sent, then interrupted)"
            }
        } else {
            r = control.moveWindow(wid, frame: frame, toSpace: target, follow: follow, timeline: timeline)
        }
        timeline.mark("published")
        // The move record is taken here, before the next operation starts (duration, Space right after, membership).
        let call = sequence.ms
        let active = system.currentSpaceID()
        let membership = SpaceObserver()?.spaces(for: wid) ?? []
        var move = SwitchSequence.Record(label: "move:\(index)", ok: false, detail: "", startMs: 0, callMs: call, activeAfter: active, membershipAfter: membership,
                                         timeline: timeline.events)
        switch r {
        case .success(let result):
            move.ok = true; move.fromSpace = result.fromSpace; move.toSpace = result.toSpace; move.steps = result.steps; move.wallMs = result.wallMs
            move.detail = "moved \(wid): \(result.fromSpace) -> \(result.toSpace) steps=\(result.steps)"
        case .failure(let f):
            move.detail = "move failed: \(f)\(control.failureDetail(f) ?? "")" + sendNote
        }
        var records = [move]
        if move.ok, let then {
            records.append(SwitchSequence.run(then.mode, to: then.index, control: control, system: system, hop: !SpaceOverview.dockReordersByRecentUse(), sequence: sequence))
        }
        let total = sequence.ms
        DispatchQueue.main.async { finished = (records, total) }
    }
    while finished == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    let records = finished!.records
    for record in records { diag(SwitchSequence.describe(record)) }
    if then != nil, records.count < 2 { diag("the move did not succeed; --then was not run") }
    diag(String(format: "sequence %.0f ms", finished!.sequenceMs))
    let moveOK = records.allSatisfy(\.ok) && (then == nil || records.count == 2)
    // Moves, including --stepping and --hotkey-follow, may post tagged keys, so every exit waits for the drain.
    drainAndExit(control, ok: moveOK, document: SwitchSequence.Document(command: command, settle: args["settle"] ?? "observed", operations: records,
                                                                        sequenceMs: finished!.sequenceMs, ok: moveOK))

case "direct-switch":
    // Check: runs the product's SpaceControl.switchTo with candidates: windows on the current Space (AX elements retained by a snapshot).
    // Steps: record current-Space windows as candidates -> move the --pid window directly to --to and follow -> switch back directly using the candidates.
    guard let index = Int(args["to"] ?? ""), let p = args["pid"].flatMap({ Int32($0) }) else { print("--pid P --to N are required"); exit(2) }
    let system = MacWindowSystem()
    _ = system.input.start()
    let seen = system.snapshot().windows
    guard let carried = seen.first(where: { $0.pid == p && $0.membership == .current }) else { print("no window of pid \(p) on this Space"); exit(2) }
    let candidates = seen.filter { $0.membership == .current && $0.id != carried.id }.map { $0.id.raw }
    guard let control = SpaceControl(input: system.input), let home = system.currentSpaceID() else { print("space observation unavailable"); exit(2) }
    control.direct = SpaceControl.systemDirectPath(raise: { wid, isCurrent, report in
        switch system.raise(WindowID(wid), timeout: 1.0, activateIf: isCurrent, activated: { pid in report(pid.map { .requested($0) } ?? .abandoned) }) {
        case .issued: return .issued
        case .timedOut: return .unknown
        case .gone, .rejected: return .refused
        }
    }, focusedWindow: { system.focusedWindowID()?.raw })
    guard let far = control.spaceID(atIndex: index) else { print("no such space: \(index)"); exit(2) }
    guard case .frame(let frame) = system.readFrame(carried.id) else { print("frame unreadable"); exit(2) }
    print("home \(home) far \(far) carried \(carried.id.raw) candidates \(candidates)")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var done: (text: String, ok: Bool)?
    DispatchQueue.global(qos: .userInitiated).async {
        var lines: [String] = []
        // The input baseline is shared by the outbound trip, the wait, and the return. If the user touches anything, the return does not start.
        let inputBaseline = system.inputActivityCount
        let untouched = { system.inputActivityCount == inputBaseline }
        let t0 = Date()
        let moved = control.moveWindow(carried.id.raw, frame: frame, toSpace: far, shouldContinue: untouched)
        lines.append("move+follow: \(moved) (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        guard case .success = moved else {
            DispatchQueue.main.async { done = (lines.joined(separator: "\n") + "\noutbound failed; return switch not attempted", false) }; return
        }
        Thread.sleep(forTimeInterval: 1.0)
        guard untouched(), system.currentSpaceID() == far else {
            DispatchQueue.main.async { done = (lines.joined(separator: "\n") + "\ninput or Space changed during the pause; return switch not attempted", false) }; return
        }
        let t1 = Date()
        let back = control.switchTo(spaceID: home, candidates: candidates, shouldContinue: untouched)
        lines.append("direct switch home: \(back) (\(Int(Date().timeIntervalSince(t1) * 1000)) ms) active=\(system.currentSpaceID() ?? 0)")
        if case .failure(let f) = back { lines.append("  detail: \(control.failureDetail(f) ?? "")") }
        var ok = false
        if case .success = back { ok = true }
        DispatchQueue.main.async { done = (lines.joined(separator: "\n"), ok) }
    }
    while done == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    print(done!.text)
    drainAndExit(control, ok: done!.ok)

case "direct-switch-app":
    // Check: runs the product's SpaceControl.switchTo with app candidates only (this process retains no window AX elements).
    // Candidates for the target and intermediate Spaces come from the raw window list (the same function as Coordinator). --no-hop skips the jump to an intermediate Space.
    let command = "direct-switch-app"
    guard let index = Int(args["to"] ?? "") else { SwitchSequence.fail("--to N is required", command: command) }
    let system = MacWindowSystem()
    _ = system.input.start()
    guard let control = SpaceControl(input: system.input), let home = system.currentSpaceID(), let inventory = AppWindowInventory.take() else {
        SwitchSequence.fail("space observation unavailable", command: command)
    }
    control.direct = SpaceControl.systemDirectPath(raise: { _, _, _ in .refused })
    guard let dest = control.spaceID(atIndex: index) else { SwitchSequence.fail("no such space: \(index)", command: command) }
    let order = control.orderedSpaces().map(\.id)
    var table: [UInt64: [SpaceControl.Candidate]] = [:]
    for space in order where space != home {
        table[space] = inventory.eligibleApps(on: space).map { .app($0.pid, bundleID: $0.bundleID) }
    }
    // Prints why each app was excluded for the target and intermediate Spaces, to explain an empty candidate table on a real Mac.
    if let i = order.firstIndex(of: home), let j = order.firstIndex(of: dest) {
        for space in order[min(i, j)...max(i, j)] where space != home {
            diag("Space \(control.label(space)) (\(space)):")
            for pid in inventory.apps.keys.sorted() where inventory.apps[pid]?.regular == true {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                diag("  \(name) [\(pid)]: \(inventory.exclusion(of: pid, on: space).map { "excluded — \($0)" } ?? "eligible")")
            }
        }
    }
    let hop = args["no-hop"] == nil && !SpaceOverview.dockReordersByRecentUse()
    diag("home \(home) dest \(dest) hop \(hop) candidates \(table.filter { !$0.value.isEmpty })")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    SwitchSequence.applySettle(args["settle"], to: control, command: command)
    // --hotkey: tries tier 0 only (macOS "Switch to Desktop N"), including the pass-through tap (an active annotated-session tap). The front app does not change.
    // --stepping-only: skips tiers 0-3 and switches by left/right stepping only (including the pass-through tap), to force the left/right path.
    // --then [hotkey|stepping|app:]M: after the first succeeds, a second switch with zero gap (testing consecutive commands). --json gives one document.
    let firstMode: SwitchSequence.Mode = args["hotkey"] != nil ? .hotkey : args["stepping-only"] != nil ? .stepping : .app
    var runs: [(mode: SwitchSequence.Mode, index: Int)] = [(firstMode, index)]
    if let spec = args["then"] {
        guard let next = SwitchSequence.parse(spec, default: firstMode) else { SwitchSequence.fail("--then must be [hotkey|stepping|app:]N", command: command) }
        runs.append(next)
    }
    if firstMode == .hotkey {
        let desktop = control.desktopNumber(of: dest)
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        diag("desktop \(desktop.map(String.init) ?? "-") shortcut \(desktop.map { "\(control.desktopShortcut($0))" } ?? "-") dock \(dock.map(String.init) ?? "-") screens \(NSScreen.screens.count) reorders \(SpaceOverview.dockReordersByRecentUse())")
    }
    var finished: (records: [SwitchSequence.Record], sequenceMs: Double)?
    DispatchQueue.global(qos: .userInitiated).async {
        let sequence = SwitchSequence.Clock()
        var done: [SwitchSequence.Record] = []
        for run in runs {
            let record = SwitchSequence.run(run.mode, to: run.index, control: control, system: system, hop: hop, sequence: sequence)
            done.append(record)
            if !record.ok { break }
        }
        let total = sequence.ms
        DispatchQueue.main.async { finished = (done, total) }
    }
    while finished == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    let records = finished!.records
    for record in records { diag(SwitchSequence.describe(record)) }
    if records.count < runs.count { diag("the first operation did not succeed; --then was not run") }
    diag(String(format: "sequence %.0f ms", finished!.sequenceMs))
    // The exit code is 0 only when every operation succeeded (the drain is always awaited).
    let allOK = records.count == runs.count && records.allSatisfy(\.ok)
    drainAndExit(control, ok: allOK, document: SwitchSequence.Document(command: command, settle: args["settle"] ?? "observed", operations: records,
                                                                      sequenceMs: finished!.sequenceMs, ok: allOK))

case "constraints":
    ProbeConstraints.run(args: args, env: env, outDir: outDir)

case "input":
    ProbeInput.run(args: args, env: env, outDir: outDir)

case "interrupt":
    ProbeInterrupt.run(args: args, env: env, outDir: outDir)

case "testwindow":
    TestWindowApp.run(args: args)

case "scramble":
    // Check: scatters the target windows on the current Space to random positions and sizes (the precondition for repeated tests).
    // With --first bundle.id, that app's window goes top-left to be first in arrangement order.
    let system = MacWindowSystem()
    let snap = system.snapshot()
    let ins = TargetSelection.inspect(snap)
    var seed = UInt64(exactly: args.double("seed", 1).rounded()) ?? 1
    func rnd(_ range: ClosedRange<Double>) -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(seed >> 11) / Double(1 << 53)
        return floor(range.lowerBound + unit * (range.upperBound - range.lowerBound))
    }
    let area = snap.workArea
    let first = args["first"]
    for (i, t) in ins.targets.enumerated() {
        let w = rnd(420...780), h = rnd(320...620)
        var f = CGRect(x: rnd(area.minX...(area.maxX - w)), y: rnd((area.minY + 150)...(area.maxY - h)), width: w, height: h)
        if t.app == first { f = CGRect(x: area.minX, y: area.minY, width: 500, height: 360) }
        let r = system.writeFrame(t.id, frame: f, timeout: 2)
        print("scramble \(i) \(t.app) → \(Int(f.minX)),\(Int(f.minY)) \(Int(w))×\(Int(h)) : \(r)")
    }

case "synth-drag":
    // Check: posts a mouse drag at the HID level (a substitute for real input; grabbing a title bar really moves the window).
    let x = args.double("x", 0), y = args.double("y", 0), dx = args.double("dx", 120), dy = args.double("dy", 80)
    let rawSteps = args.double("steps", 12)
    // Validate ranges before posting; crashing after mouseDown would leave the button held.
    guard [x, y, dx, dy].allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), rawSteps.isFinite, rawSteps >= 1, rawSteps <= 1000 else {
        FileHandle.standardError.write("synth-drag: x, y, dx, dy must be within ±100000 and steps 1–1000\n".data(using: .utf8)!)
        exit(2)
    }
    let steps = Int(rawSteps)
    func post(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let start = CGPoint(x: x, y: y)
    post(.mouseMoved, start)
    Thread.sleep(forTimeInterval: 0.05)
    post(.leftMouseDown, start)
    for i in 1...steps {
        Thread.sleep(forTimeInterval: 0.03)
        post(.leftMouseDragged, CGPoint(x: x + dx * Double(i) / Double(steps), y: y + dy * Double(i) / Double(steps)))
    }
    Thread.sleep(forTimeInterval: 0.03)
    post(.leftMouseUp, CGPoint(x: x + dx, y: y + dy))
    print("synth-drag from \(Int(x)),\(Int(y)) by \(Int(dx)),\(Int(dy))")

case "synth-key":
    // Check: posts a key press with modifiers at the HID level (checks the shortcut mechanism; not a substitute for real input).
    let code = CGKeyCode(UInt16(exactly: args.double("keycode", 37).rounded()) ?? 37)
    var flags: CGEventFlags = []
    if args["option"] != nil { flags.insert(.maskAlternate) }
    if args["shift"] != nil { flags.insert(.maskShift) }
    if args["control"] != nil { flags.insert(.maskControl) }
    if args["command"] != nil { flags.insert(.maskCommand) }
    // --hold: also posts the modifiers' own down/up (OS shortcut matching may need modifier transitions).
    // --nsapp: creates NSApplication before posting (to compare with and without a WindowServer connection).
    if args["nsapp"] != nil { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApplication.shared.finishLaunching(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    if args["hotkey"] != nil {
        // --hotkey: registers one Carbon global shortcut before posting (to compare with and without a hotkey client connection).
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x4C5A5052 /* LZPR */, id: 1)
        let err = RegisterEventHotKey(UInt32(kVK_F19), UInt32(cmdKey | optionKey | controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
        print("RegisterEventHotKey: \(err)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }
    if args["tap"] != nil {
        // --tap: installs a listen-only event tap before posting.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        if let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0); CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes); CGEvent.tapEnable(tap: t, enable: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
    }
    let tap: CGEventTapLocation = args["session"] != nil ? .cgSessionEventTap : .cghidEventTap
    let source = args["source"].flatMap { $0 == "hid" ? CGEventSource(stateID: .hidSystemState) : $0 == "private" ? CGEventSource(stateID: .privateState) : CGEventSource(stateID: .combinedSessionState) }
    let modifierCodes: [CGKeyCode] = (flags.contains(.maskControl) ? [59] : []) + (flags.contains(.maskAlternate) ? [58] : []) + (flags.contains(.maskShift) ? [56] : []) + (flags.contains(.maskCommand) ? [55] : [])
    if args["hold"] != nil {
        for m in modifierCodes { if let e = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: true) { e.flags = flags; e.post(tap: tap) }; Thread.sleep(forTimeInterval: 0.02) }
    }
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
            e.flags = flags
            e.post(tap: tap)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if args["hold"] != nil {
        for m in modifierCodes.reversed() { if let e = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: false) { e.flags = []; e.post(tap: tap) }; Thread.sleep(forTimeInterval: 0.02) }
    }
    if args["linger"] != nil { RunLoop.main.run(until: Date().addingTimeInterval(1.0)) }
    print("synth-key \(code) flags=\(flags.rawValue) hold=\(args["hold"] != nil) tap=\(tap.rawValue)")

case "ui-press":
    // Check: finds an AX element (button or menu item) of the given app by title and presses it.
    //   lzprobe ui-press --pid N --title "Arrange Now"
    guard let pidText = args["pid"], let pid = Int32(pidText), let title = args["title"] else { print("--pid and --title are required"); exit(2) }
    let app = AXUIElementCreateApplication(pid)
    func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success, let arr = v as? [AnyObject] else { return [] }
        return arr.map { unsafeBitCast($0, to: AXUIElement.self) }
    }
    func titleOf(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v)
        return v as? String ?? ""
    }
    func find(_ el: AXUIElement, _ wanted: String, depth: Int = 0) -> AXUIElement? {
        if depth > 12 { return nil }
        if titleOf(el) == wanted { return el }
        for c in children(el) { if let f = find(c, wanted, depth: depth + 1) { return f } }
        return nil
    }
    func roots() -> [AXUIElement] {
        var out = children(app)
        var extras: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success, let extras {
            out.append(unsafeBitCast(extras, to: AXUIElement.self))
        }
        return out
    }
    if let menuTitle = args["menu"] {
        guard let bar = roots().lazy.compactMap({ find($0, menuTitle) }).first else { print("menu bar item not found: \(menuTitle)"); exit(1) }
        print("press menubar item: \(AXUIElementPerformAction(bar, kAXPressAction as CFString).rawValue)")
        Thread.sleep(forTimeInterval: 0.4)
    }
    guard let target = roots().lazy.compactMap({ find($0, title) }).first else { print("element not found: \(title)"); exit(1) }
    print("press \(title): \(AXUIElementPerformAction(target, kAXPressAction as CFString).rawValue)")

case "raise-probe":
    // Check: sends only AXRaise to the given window (no app activation, focus, or frame writes).
    // Records stack order before and after (on-screen layer 0, position from the front), the front app, its focused window, and the target app's main window.
    // Without --window, only lists visible layer-0 windows (ID, pid, app, subrole).
    func layerZero() -> [(id: CGWindowID, pid: pid_t, bounds: CGRect)] {
        let all = WindowList.all()
        return WindowList.onScreenOrder().sorted { $0.value < $1.value }.compactMap { id, _ in
            guard let r = all[id], r.layer == 0, r.alpha > 0 else { return nil }
            return (id, r.pid, r.bounds)
        }
    }
    func axWindow(_ id: CGWindowID, pid: pid_t) -> AXElement? {
        guard case .success(let windows) = AXElement.application(pid: pid).windows() else { return nil }
        return windows.first { $0.windowID() == id }
    }
    func focused() -> (pid: pid_t?, window: CGWindowID?) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return (nil, nil) }
        guard case .success(let v) = AXElement.application(pid: pid).copyAttribute(kAXFocusedWindowAttribute) else { return (pid, nil) }
        return (pid, AXElement(raw: unsafeBitCast(v, to: AXUIElement.self)).windowID())
    }
    func snapshot(_ label: String, target: CGWindowID?) {
        let order = layerZero()
        let f = focused()
        let rank = target.flatMap { t in order.firstIndex { $0.id == t } }
        print("[\(label)] front pid=\(f.pid.map(String.init) ?? "?") focused=\(f.window.map(String.init) ?? "?") target rank=\(rank.map(String.init) ?? "-") of \(order.count)")
        print("  order: " + order.prefix(8).map { "\($0.id)(pid \($0.pid))" }.joined(separator: " > "))
    }
    guard let raw = args["window"], let target = CGWindowID(raw) else {
        for w in layerZero() {
            let app = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? "pid\(w.pid)"
            let subrole = axWindow(w.id, pid: w.pid)?.string(kAXSubroleAttribute) ?? "?"
            print("\(w.id)\tpid \(w.pid)\t\(app)\t\(subrole)\t\(Int(w.bounds.width))x\(Int(w.bounds.height))")
        }
        exit(0)
    }
    guard let rec = WindowList.all()[target], let element = axWindow(target, pid: rec.pid) else { print("window \(target) not found"); exit(1) }
    snapshot("before", target: target)
    let err = AXUIElementPerformAction(element.raw, kAXRaiseAction as CFString)
    print("AXRaise err=\(err.rawValue)")
    Thread.sleep(forTimeInterval: args.double("settle", 0.4))
    snapshot("after", target: target)
    let main = AXElement.application(pid: rec.pid).copyAttribute(kAXMainWindowAttribute)
    if case .success(let v) = main { print("target app main window=\(AXElement(raw: unsafeBitCast(v, to: AXUIElement.self)).windowID().map(String.init) ?? "?")") }

case "position-probe":
    // Check: writes only the position of the given window (size, activation, and focus untouched). Records frames, the front app, and focus before and after,
    // reads again after --settle seconds to see whether the app put it back, and finally restores the original position (--keep skips that).
    guard let raw = args["window"], let target = CGWindowID(raw),
          let to = args["to"]?.split(separator: ",").compactMap({ Double($0) }), to.count == 2 else {
        print("position-probe --window ID --to x,y [--settle s] [--keep]"); exit(1)
    }
    guard let rec = WindowList.all()[target], case .success(let windows) = AXElement.application(pid: rec.pid).windows(),
          let element = windows.first(where: { $0.windowID() == target }) else { print("window \(target) not found"); exit(1) }
    func report(_ label: String) {
        let cg = WindowList.all()[target]?.bounds
        let ax = element.frame()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focused = "?"
        if let front, case .success(let v) = AXElement.application(pid: front).copyAttribute(kAXFocusedWindowAttribute) {
            focused = AXElement(raw: unsafeBitCast(v, to: AXUIElement.self)).windowID().map(String.init) ?? "?"
        }
        print("[\(label)] cg=\(cg.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") ax=\((try? ax.get()).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-") front=\(front.map(String.init) ?? "?") focused=\(focused)")
    }
    report("before")
    let original = try? element.frame().get()
    let t0 = Date()
    let err = element.setPosition(CGPoint(x: to[0], y: to[1]))
    print("setPosition err=\(err.map { $0.label } ?? "none") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    Thread.sleep(forTimeInterval: 0.3)
    report("after 0.3s")
    Thread.sleep(forTimeInterval: args.double("settle", 1.5))
    report("after settle")
    if args["keep"] == nil, let original {
        _ = element.setPosition(original.origin)
        Thread.sleep(forTimeInterval: 0.3)
        report("restored")
    }

case "window-state":
    // Check: reads AXFullScreen / AXMinimized and their buttons for the front app's focused window, and tries writing with --set fullscreen|minimized.
    guard let front = NSWorkspace.shared.frontmostApplication else { print("no front app"); exit(1) }
    let app = AXUIElementCreateApplication(front.processIdentifier)
    var w: CFTypeRef?
    let e0 = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w)
    guard e0 == .success, let w else { print("no focused window: \(e0.rawValue)"); exit(1) }
    let win = unsafeBitCast(w, to: AXUIElement.self)
    for name in ["AXFullScreen", kAXMinimizedAttribute, kAXFullScreenButtonAttribute, kAXMinimizeButtonAttribute, kAXSubroleAttribute, kAXTitleAttribute] {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(win, name as CFString, &v)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(win, name as CFString, &settable)
        print("\(name): err=\(e.rawValue) value=\(v.map { String(describing: $0) } ?? "nil") settable=\(settable)")
    }
    if let set = args["set"] {
        let name = set == "fullscreen" ? "AXFullScreen" : kAXMinimizedAttribute
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(win, name as CFString, &v)
        let now = (v as? NSNumber)?.boolValue ?? false
        let e = AXUIElementSetAttributeValue(win, name as CFString, now ? kCFBooleanFalse : kCFBooleanTrue)
        print("set \(name) = \(!now): err=\(e.rawValue)")
        if e != .success {
            var b: CFTypeRef?
            let bn = set == "fullscreen" ? kAXFullScreenButtonAttribute : kAXMinimizeButtonAttribute
            let eb = AXUIElementCopyAttributeValue(win, bn as CFString, &b)
            if eb == .success, let b {
                print("press \(bn): err=\(AXUIElementPerformAction(unsafeBitCast(b, to: AXUIElement.self), kAXPressAction as CFString).rawValue)")
            } else { print("button \(bn): err=\(eb.rawValue)") }
        }
    }

default:
    print("""
    lzprobe <command> [--out dir]
      env
      windows      [--app bundle.id]              observe -> change position/size -> readback -> restore
      spaces       [--watch sec]                  Space observation and switch detection
      desktop-read --desktop N [--style held|pair]  read the Desktop N hotkey (no input)
      desktop-switch --desktop N [--style held|pair] send the enabled number key once and observe
      desktop-transfer --desktop N --window ID [--style held|pair] grab only the test window and send once
      direct-move  --window ID|--pid P --to N [--stepping|--no-raise|--hotkey-follow|--no-follow] run the product's SpaceControl.moveWindow on one window (direct path / stepping / reactivate path).
                   --no-follow uses sendWindow (changes membership only, no switch)
      space-uuids                               Spaces of each display (order, ID, type, uuid, uniqueness across all Spaces). Read-only
                   [--then [hotkey|stepping|app:]M] [--settle observed|fixed] [--json]  after a successful move, switch to M with zero gap. --json: diagnostics to stderr, one document to stdout
      direct-switch --pid P --to N              move the window directly to N and follow, then bring a window on the original Space forward and return directly
      direct-switch-app --to N [--no-hop]       switch to N by app activation only (plus one jump and stepping through Spaces in between)
      direct-switch-app --to N --hotkey         try only macOS "Switch to Desktop N" (tier 0), including the pass-through tap
      direct-switch-app --to N --stepping-only  skip tiers 0-3 and switch by left/right stepping only (including the pass-through tap)
      direct-switch-app ... [--then [hotkey|stepping|app:]M] [--settle observed|fixed] [--json]
                                                after the first succeeds, a second switch to M with zero gap (same route by default). --settle fixed restores the old fixed waits
      constraints  --app bundle.id                tell minimum / maximum sizes apart
      input        [--seconds sec]                input observation (counts only)
      interrupt    --app bundle.id [--timeout s]  bounded request to an unresponsive app
      raise-probe  [--window ID] [--settle s]      send only AXRaise to a window and record stack order, front app, and focus before and after (lists windows without an ID)
      position-probe --window ID --to x,y [--settle s] [--keep]  write only a window's position, record frames, front app, and focus before and after, then restore
    """)
}
