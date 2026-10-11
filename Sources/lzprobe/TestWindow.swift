import AppKit
import Foundation

/// Dedicated test app for reproducing constraints and delays. Not a substitute for checks with real apps.
///   lzprobe testwindow [--slow-set sec] [--min W,H] [--fixed W,H] [--label text]
/// Adds and removes windows in one process (for response timing): SIGUSR1 opens one, SIGUSR2 closes the last opened.
enum TestWindowApp {
    final class SlowWindow: NSWindow {
        var slowSet: TimeInterval = 0
        // AX position and size writes end up here; reads do not.
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            if slowSet > 0 { Thread.sleep(forTimeInterval: slowSet) }
            super.setFrame(frameRect, display: flag)
        }
        override func setFrameOrigin(_ point: NSPoint) {
            if slowSet > 0 { Thread.sleep(forTimeInterval: slowSet) }
            super.setFrameOrigin(point)
        }
    }

    final class Delegate: NSObject, NSApplicationDelegate {
        var window: SlowWindow!
        var extra: [NSWindow] = []
        var signalSources: [DispatchSourceSignal] = []
        let args: Args
        init(args: Args) { self.args = args }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let w = SlowWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 380), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.slowSet = args.double("slow-set", 0)
            w.title = args["label"] ?? "LazySpace TestWindow"
            if let m = args["min"] { let p = m.split(separator: ",").compactMap { Double($0) }; if p.count == 2 { w.contentMinSize = NSSize(width: p[0], height: p[1]) } }
            if let f = args["fixed"] {
                let p = f.split(separator: ",").compactMap { Double($0) }
                if p.count == 2 {
                    let s = NSSize(width: p[0], height: p[1])
                    w.contentMinSize = s; w.contentMaxSize = s
                    w.setContentSize(s)
                }
            }
            let label = NSTextField(labelWithString: "TestWindow slow-set=\(w.slowSet)s min=\(w.contentMinSize) pid=\(ProcessInfo.processInfo.processIdentifier)")
            label.frame = NSRect(x: 16, y: 16, width: 480, height: 40)
            w.contentView?.addSubview(label)
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            window = w
            if args["activate"] != nil { NSApp.activate(ignoringOtherApps: true) }
            for (sig, handler) in [(SIGUSR1, openExtra), (SIGUSR2, closeExtra)] as [(Int32, () -> Void)] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler(handler: handler)
                source.resume()
                signalSources.append(source)
            }
        }

        private func openExtra() {
            let w = NSWindow(contentRect: NSRect(x: 240 + 30 * extra.count, y: 240, width: 520, height: 380), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "\(window.title) +\(extra.count + 1)"
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            extra.append(w)
        }

        private func closeExtra() {
            extra.popLast()?.close()
        }
    }

    static func run(args: Args) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(args: args)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}
