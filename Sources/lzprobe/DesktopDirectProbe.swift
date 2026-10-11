// Desktop-number experiment for one display and type 0 Spaces only. Hotkeys are only read. Records observations and does not undo on failure.
import AppKit
import Darwin
import Foundation
import MacSupport

enum DesktopDirect {
    static let probeBundle = "jp.lazyspace.probe"
    static let probeTitle = "LazySpace Direct Transfer Probe"
    private static let known: UInt64 = 0x00010000 | 0x00020000 | 0x00040000 | 0x00080000 | 0x00100000 | 0x00200000 | 0x00400000 | 0x00800000
    private static let chordBits: UInt64 = 0x00020000 | 0x00040000 | 0x00080000 | 0x00100000
    private static func box<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    /// Events with the synthetic tag are not in InputMonitor.count, so any increase is user input.
    final class UserInput {
        let monitor = InputMonitor()
        var baseline: UInt64 = 0
        var interrupted = false
        func arm() -> Bool {
            guard monitor.start() == .mouseAndKeyboard else { return false }
            baseline = monitor.count
            return true
        }
        func check() -> Bool {
            if monitor.count != baseline { interrupted = true }
            return !interrupted
        }
    }

    final class Held {
        var keys: CGEventSource?
        var mouseSource: CGEventSource?
        var down = false
        var code: CGKeyCode = 0
        var mods: [CGKeyCode] = []
        var mouse = false
        var point = CGPoint.zero
        func key(_ code: CGKeyCode, _ isDown: Bool, _ flags: CGEventFlags) -> Bool {
            guard let event = CGEvent(keyboardEventSource: keys, virtualKey: code, keyDown: isDown) else { return false }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: SpaceControl.syntheticTag)
            event.post(tap: .cghidEventTap)
            return true
        }
        func button(_ type: CGEventType, _ point: CGPoint) -> Bool {
            guard let event = CGEvent(mouseEventSource: mouseSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return false }
            event.setIntegerValueField(.eventSourceUserData, value: SpaceControl.syntheticTag)
            event.post(tap: .cghidEventTap)
            self.point = point
            return true
        }
        func release() {
            if down, key(code, false, []) { down = false }
            while let mod = mods.last { if key(mod, false, []) { mods.removeLast() } else { break } }
            if mouse, button(.leftMouseUp, CGEvent(source: nil)?.location ?? point) { mouse = false }
        }
    }

    struct Hotkey {
        var id: Int, status: Int?, code: UInt32?, flags: UInt64?, enabled: Bool?, availability: String
        var json: [String: Any] { [
            "id": id, "getterStatus": box(status), "keyCode": box(code.map(Int.init)), "flags": box(flags.map(Int.init)),
            "flagsHex": box(flags.map { String(format: "0x%08llx", $0) }), "enabled": box(enabled), "availability": availability,
        ] }
        var sendable: Bool {
            guard availability == "enabled", let code, let flags, code <= UInt32(UInt16.max) else { return false }
            let blocked: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            return !blocked.contains(code) && flags & ~known == 0 && flags & (0x10000 | 0x400000) == 0 && flags & chordBits != 0
        }
    }

    static func run(_ args: Args) -> Never {
        let command = args.command, style = args["style"] ?? "held"
        var exitCode: Int32 = 2
        var report: [String: Any] = ["probe": command, "style": style, "writesHotkeys": false, "autoReturned": false, "posted": false, "shortcutSent": false, "changes": [Any]()]
        let held = Held()
        let user = UserInput()
        var origin: CGPoint?, anchor: CGPoint?, warped = false
        func stop() -> Never {
            held.release()
            var restored = false
            if !user.interrupted, warped, let origin, let anchor, let now = CGEvent(source: nil)?.location {
                let dx = now.x - anchor.x, dy = now.y - anchor.y
                if dx * dx + dy * dy <= 1600 { CGWarpMouseCursorPosition(origin); restored = true }
            }
            report["cursorRestored"] = restored
            report["interrupted"] = user.interrupted
            report["keyReleased"] = !held.down && held.mods.isEmpty
            report["mouseReleased"] = !held.mouse
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if let dir = args["out"], dir != "true" {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(command).json")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
            exit(exitCode)
        }
        func reject(_ reason: String, _ posted: Bool = false, _ status: Int32 = 2) -> Never {
            report["reason"] = reason; report["verdict"] = user.interrupted ? "interrupted" : "rejected"; report["posted"] = posted
            exitCode = user.interrupted ? 130 : status
            stop()
        }
        guard style == "held" || style == "pair" else { reject("style-invalid") }
        guard let desktop = Int(args["desktop"] ?? ""), (1...16).contains(desktop) else { reject("desktop-out-of-range") }
        guard let observer = SpaceObserver() else { reject("space-unavailable") }
        report["hotkey"] = hotkey(desktop).json
        let spaces = singleDisplay(observer)
        report["order"] = spaces?.map { Int($0) } ?? []
        let active = observer.activeSpace()
        report["source"] = box(active.map(Int.init))
        guard let spaces else { report["verdict"] = "rejected"; report["reason"] = "space-map-rejected"; exitCode = command == "desktop-read" ? 0 : 2; stop() }
        guard desktop <= spaces.count else { report["verdict"] = "rejected"; report["reason"] = "no-such-desktop"; exitCode = command == "desktop-read" ? 0 : 2; stop() }
        let target = spaces[desktop - 1]
        report["target"] = Int(target)
        if command == "desktop-read" {
            report["after"] = box(active.map(Int.init)); report["verdict"] = "read"; report["reason"] = "read"; exitCode = 0; stop()
        }
        let key = hotkey(desktop)
        report["hotkey"] = key.json
        guard key.availability == "enabled" else { reject(key.availability == "disabled" ? "hotkey-disabled" : "hotkey-unknown") }
        guard key.sendable, let active else { reject(key.sendable ? "space-unavailable" : "hotkey-unusable") }
        if active == target { report["after"] = Int(active); reject("already-there") }
        // No final membership verdict while the mouse is held; only the ~1 s after release counts.
        func releasedWatch(_ window: CGWindowID?, _ before: [UInt64]) {
            held.release()
            var changes: [[String: Any]] = []
            var previous = "\(active)|\(before)"
            let seen = watch(observer, window, 1, Date(), "released", user, &previous, &changes)
            report["changes"] = changes
            report["after"] = box(seen.after.map(Int.init))
            report["membershipAfter"] = seen.membership.map { Int($0) }
        }
        if command == "desktop-transfer" {
            guard let raw = args["window"], let id = UInt32(raw), id != 0 else { reject("window-required") }
            report["window"] = Int(id)
            guard let found = cgWindow(id) else { reject("window-not-found") }
            let bundle = NSRunningApplication(processIdentifier: found.pid)?.bundleIdentifier
            report["pid"] = Int(found.pid); report["bundleID"] = bundle ?? ""; report["layer"] = found.layer
            report["bounds"] = ["x": Double(found.bounds.minX), "y": Double(found.bounds.minY), "width": Double(found.bounds.width), "height": Double(found.bounds.height)]
            guard bundle == probeBundle else { reject("bundle-not-probe") }
            guard let title = axTitle(found.pid, id) else { reject("title-unconfirmed") }
            report["title"] = title
            guard title == probeTitle else { reject("title-not-probe") }
            guard found.layer == 0 else { reject("window-layer") }
            guard found.onScreen else { reject("window-offscreen") }
            guard found.bounds.minX.isFinite, found.bounds.minY.isFinite, found.bounds.width.isFinite, found.bounds.height.isFinite,
                  found.bounds.width >= 40, found.bounds.height >= 20 else { reject("bounds-invalid") }
            var membership = observer.spaces(for: id)
            report["membershipBefore"] = membership.map { Int($0) }
            guard membership == [active] else { reject(membership.isEmpty ? "membership-unreadable" : "membership-not-source") }
            let grab = CGPoint(x: found.bounds.midX, y: found.bounds.minY + 6)
            guard topmost(at: grab) == id else { reject("grab-covered") }
            if let busy = physicalIdle() { reject(busy) }
            guard user.arm() else { reject("input-monitor-unavailable") }
            origin = CGEvent(source: nil)?.location
            guard let source = CGEventSource(stateID: .privateState) else { reject("source-private-unavailable") }
            held.mouseSource = source
            warped = true
            guard drag(held, found.bounds, &anchor, user) else {
                let posted = held.mouse
                if posted { releasedWatch(id, membership) }
                reject(user.interrupted ? "interrupted" : "event-failed", posted, user.interrupted ? 130 : (posted ? 0 : 2))
            }
            let now = observer.activeSpace()
            membership = observer.spaces(for: id)
            guard user.check(), now == active, membership == [active] else {
                releasedWatch(id, membership)
                reject(user.interrupted ? "interrupted" : (now == target ? "already-there" : "changed-before-shortcut"), true, user.interrupted ? 130 : 0)
            }
            let fresh = hotkey(desktop)
            report["hotkey"] = fresh.json
            guard user.check(), fresh.sendable else {
                releasedWatch(id, membership)
                reject(user.interrupted ? "interrupted" : (fresh.availability == "disabled" ? "hotkey-disabled" : "hotkey-changed"), true, user.interrupted ? 130 : 0)
            }
            held.keys = style == "pair" ? nil : source
            finishPost(held, fresh, style, observer, id, active, target, membership, user, &report, &exitCode)
            stop()
        }
        guard observer.activeSpace() == active else { reject(observer.activeSpace() == target ? "already-there" : "space-changed-before-shortcut") }
        let fresh = hotkey(desktop)
        report["hotkey"] = fresh.json
        guard fresh.sendable else { reject(fresh.availability == "disabled" ? "hotkey-disabled" : "hotkey-changed") }
        if let busy = physicalIdle() { reject(busy) }
        guard user.arm() else { reject("input-monitor-unavailable") }
        guard let source = CGEventSource(stateID: .privateState) else { reject("source-private-unavailable") }
        held.keys = style == "pair" ? nil : source
        finishPost(held, fresh, style, observer, nil, active, target, [], user, &report, &exitCode)
        stop()
    }

    /// After one post, watches only the active Space for ~2 s while held, then the active Space and membership for ~1 s after release, and gives the verdict.
    private static func finishPost(_ held: Held, _ key: Hotkey, _ style: String, _ observer: SpaceObserver, _ window: CGWindowID?, _ source: UInt64, _ target: UInt64, _ before: [UInt64], _ user: UserInput, _ report: inout [String: Any], _ exitCode: inout Int32) {
        let sent = postChord(key, style, held, user)
        let postedKeys = sent || held.down || !held.mods.isEmpty
        report["shortcutSent"] = sent
        report["posted"] = postedKeys || held.mouse
        var changes: [[String: Any]] = []
        var previous = "\(source)|\(before)"
        let t0 = Date()
        if sent && user.check() {
            let heldPhase = watch(observer, window, 2, t0, "held", user, &previous, &changes)
            report["activeWhileHeld"] = box(heldPhase.after.map(Int.init))
            report["membershipWhileHeld"] = heldPhase.membership.map { Int($0) }
        }
        held.release()
        let after = watch(observer, window, 1, t0, "released", user, &previous, &changes)
        report["changes"] = changes
        report["after"] = box(after.after.map(Int.init))
        report["membershipAfter"] = after.membership.map { Int($0) }
        let verdict: String
        if user.interrupted { verdict = "interrupted" }
        else if !sent { verdict = "chord-incomplete" }
        else if window == nil { verdict = after.after == target ? "observed-switch" : (after.after == source ? "observed-unchanged" : "observed-other") }
        else if after.after == target && after.membership == [target] { verdict = "observed-transferred" }
        else if after.membership == [source] { verdict = "observed-not-transferred" }
        else { verdict = "observed-ambiguous" }
        report["verdict"] = verdict; report["reason"] = verdict
        exitCode = user.interrupted ? 130 : ((report["posted"] as? Bool) == true ? 0 : 2)
    }

    private static func postChord(_ key: Hotkey, _ style: String, _ held: Held, _ user: UserInput) -> Bool {
        guard let code = key.code, let flags = key.flags else { return false }
        let main = CGKeyCode(code), eventFlags = CGEventFlags(rawValue: flags)
        if style == "pair" {
            guard user.check(), held.key(main, true, eventFlags) else { return false }
            held.down = true; held.code = main; Thread.sleep(forTimeInterval: 0.02)
            guard held.key(main, false, []) else { return false }
            held.down = false
            return true
        }
        var accumulated: UInt64 = 0
        let physical: [(CGKeyCode, UInt64)] = [(59, 0x40000), (58, 0x80000), (56, 0x20000), (55, 0x100000)]
        for item in physical where flags & item.1 != 0 {
            guard user.check(), held.key(item.0, true, CGEventFlags(rawValue: accumulated | item.1)) else { return false }
            accumulated |= item.1
            held.mods.append(item.0); Thread.sleep(forTimeInterval: 0.02)
        }
        guard user.check(), held.key(main, true, eventFlags) else { return false }
        held.down = true; held.code = main; Thread.sleep(forTimeInterval: 0.02)
        guard held.key(main, false, eventFlags) else { return false }
        held.down = false; Thread.sleep(forTimeInterval: 0.02)
        while let mod = held.mods.last {
            guard held.key(mod, false, []) else { return false }
            held.mods.removeLast(); Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    private static func drag(_ held: Held, _ bounds: CGRect, _ anchor: inout CGPoint?, _ user: UserInput) -> Bool {
        let grab = CGPoint(x: bounds.midX, y: bounds.minY + 6)
        anchor = grab
        CGWarpMouseCursorPosition(grab)
        guard user.check(), held.button(.mouseMoved, grab) else { return false }
        Thread.sleep(forTimeInterval: 0.05)
        guard user.check(), held.button(.leftMouseDown, grab) else { return false }
        held.mouse = true
        for delta in [3.0, 6.0, 3.0, 0.0] {
            Thread.sleep(forTimeInterval: 0.03)
            let next = CGPoint(x: grab.x + delta, y: grab.y + delta)
            guard user.check(), held.button(.leftMouseDragged, next) else { return false }
            anchor = next
        }
        Thread.sleep(forTimeInterval: 0.1)
        return user.check()
    }

    private static func watch(_ observer: SpaceObserver, _ window: CGWindowID?, _ seconds: TimeInterval, _ t0: Date, _ phase: String, _ user: UserInput, _ previous: inout String, _ changes: inout [[String: Any]]) -> (after: UInt64?, membership: [UInt64]) {
        let deadline = Date().addingTimeInterval(seconds)
        var after = observer.activeSpace()
        var membership = window.map { observer.spaces(for: $0) } ?? []
        while Date() < deadline {
            if !user.check() { break }
            after = observer.activeSpace()
            if let window { membership = observer.spaces(for: window) }
            let token = "\(after ?? 0)|\(membership)"
            if token != previous {
                changes.append(["atMs": Int(Date().timeIntervalSince(t0) * 1000), "phase": phase, "active": box(after.map(Int.init)), "membership": membership.map { Int($0) }])
                previous = token
            }
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { break }
            Thread.sleep(forTimeInterval: min(0.05, remain))
        }
        after = observer.activeSpace()
        if let window { membership = observer.spaces(for: window) }
        return (after, membership)
    }

    private static func hotkey(_ desktop: Int) -> Hotkey {
        let id = 118 + desktop - 1
        let missing = Hotkey(id: id, status: nil, code: nil, flags: nil, enabled: nil, availability: "unknown")
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSGetSymbolicHotKeyValue") else { return missing }
        typealias Get = @convention(c) (Int32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
        typealias On = @convention(c) (Int32) -> Bool
        var equivalent: UInt32 = 0, code: UInt32 = 0, modifiers: UInt32 = 0
        let status = unsafeBitCast(symbol, to: Get.self)(Int32(id), &equivalent, &code, &modifiers)
        guard status == 0 else { return Hotkey(id: id, status: Int(status), code: nil, flags: nil, enabled: nil, availability: "unknown") }
        guard let enabledSymbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled") else {
            return Hotkey(id: id, status: 0, code: code, flags: UInt64(modifiers), enabled: nil, availability: "unknown")
        }
        let enabled = unsafeBitCast(enabledSymbol, to: On.self)(Int32(id))
        return Hotkey(id: id, status: 0, code: code, flags: UInt64(modifiers), enabled: enabled, availability: enabled ? "enabled" : "disabled")
    }

    private static func singleDisplay(_ observer: SpaceObserver) -> [UInt64]? {
        let displays = observer.managedDisplays()
        guard displays.count == 1, let display = displays.first, !display.spaces.isEmpty, display.spaces.count == display.spaceTypes.count else { return nil }
        guard display.spaceTypes.allSatisfy({ $0 == 0 }), Set(display.spaces).count == display.spaces.count, display.spaces.allSatisfy({ $0 != 0 }) else { return nil }
        return display.spaces
    }

    /// The frontmost on-screen window containing the grab point. Only test windows are grabbed.
    private static func topmost(at point: CGPoint) -> CGWindowID? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for row in rows {
            guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let box = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: box) else { continue }
            if bounds.width > 0, bounds.height > 0, bounds.contains(point) { return id }
        }
        return nil
    }

    /// Posts nothing if a physical button or modifier is down at the start. Shows no permission dialog.
    private static func physicalIdle() -> String? {
        if NSEvent.pressedMouseButtons != 0 { return "buttons-held" }
        let mask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        if !CGEventSource.flagsState(.hidSystemState).intersection(mask).isEmpty { return "modifiers-held" }
        return nil
    }

    private static func cgWindow(_ id: CGWindowID) -> (pid: pid_t, layer: Int, bounds: CGRect, onScreen: Bool)? {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for row in rows {
            guard (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id, let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            var bounds = CGRect.zero
            if let box = row[kCGWindowBounds as String] as? NSDictionary { bounds = CGRect(dictionaryRepresentation: box) ?? .zero }
            return (pid, (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds, (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
        return nil
    }

    private static func axTitle(_ pid: pid_t, _ id: CGWindowID) -> String? {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(0.3)
        guard case .success(let windows) = app.windows() else { return nil }
        return windows.first { $0.windowID() == id }?.string(kAXTitleAttribute)
    }
}
