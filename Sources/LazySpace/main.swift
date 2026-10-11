import AppKit
import Copy
import Foundation
import Settings

// CLI: sends commands to the running app through the same operation path. Without the app, nothing moves.
// Called as `lazyspace` (the symlink) without arguments, it prints usage.
let argv = Array(CommandLine.arguments.dropFirst())
// The executable is LazySpace; called as lowercase lazyspace (the symlink), it acts as the CLI.
let invokedAsCLI = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "lazyspace"

func write(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write((text.hasSuffix("\n") ? text : text + "\n").data(using: .utf8)!)
}

// CLI output follows the configuration's language, or the macOS setting when unreadable.
if invokedAsCLI || !argv.isEmpty,
   let text = try? String(contentsOf: Coordinator.defaultConfigURL, encoding: .utf8),
   let config = try? Config.load(toml: text) {
    Copy.apply(setting: config.language)
}

let notRunningMessage = L("Could not communicate with LazySpace. Start the app or check the operation result before retrying.",
                          "LazySpaceと通信できません。アプリの起動状態、または操作結果を確認してから再試行してください。")

func fail(_ message: String, code: String, operationID: String? = nil, exitCode: Int32 = 1) -> Never {
    if argv.contains("--json") {
        write(CLI.render(ControlPort.Response(ok: false, message: message, operationID: operationID, code: code),
                         invocation: CLI.Invocation(cmd: "error", json: true)))
    } else { write(message, to: .standardError) }
    exit(exitCode)
}

if let parsed = CLI.parse(argv) ?? (invokedAsCLI && argv.isEmpty ? .help : nil) {
    switch parsed {
    case .help:
        write(CLI.usage)
        exit(0)
    case .version:
        write("LazySpace \(CLI.executableVersion())")
        exit(0)
    case .error(let message):
        fail(message, code: "usage")
    case .invocation(let invocation):
        let instanceLockHeld = ControlCredential.instanceLockIsHeld(root: StateStore.defaultRoot)
        let unavailable = instanceLockHeld
            ? L("LazySpace appears to be running, but CLI communication is unavailable. Check the LazySpace Application Support folder permissions or try again after startup.",
                "LazySpaceは起動中のようですが、CLIから通信できません。LazySpaceのApplication Supportフォルダのアクセス権を確認するか、起動完了後に再試行してください。")
            : notRunningMessage
        let output = CLI.execute(invocation,
                                 send: { request, timeout in ControlPort.send(request, timeout: timeout) },
                                 unavailable: unavailable,
                                 unavailableCode: instanceLockHeld ? "control-unavailable" : "connection-unavailable")
        if output.stderr == nil || !output.stdout.isEmpty { write(output.stdout) }
        if let error = output.stderr { write(error, to: .standardError) }
        exit(output.exitCode)
    }
}

// One LazySpace per user, so a second copy never starts automatic arrangement or saves state.
// Take the state folder lock before creating Coordinator. If taken, show the running copy's window list (without waiting for a reply) and quit.
try? FileManager.default.createDirectory(at: StateStore.defaultRoot, withIntermediateDirectories: true)
let instanceLock = open(StateStore.defaultRoot.appendingPathComponent("instance.lock").path, O_CREAT | O_RDONLY, 0o600)
// If the lock file cannot be opened, quit when a running copy answers (otherwise run without the lock).
if instanceLock >= 0 ? flock(instanceLock, LOCK_EX | LOCK_NB) != 0 : ControlPort.send("status", timeout: 0.5) != nil {
    _ = ControlPort.send("show", timeout: 0.5)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(showReadyAtLaunch: argv.contains("--ready"))
delegate.makeUpdates = { SparkleUpdates.makeIfAllowed(bundle: .main) }
app.delegate = delegate
app.run()
