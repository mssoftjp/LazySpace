import AppKit
import Copy
import Foundation
import MacSupport
import ServiceManagement

/// Open at Login via SMAppService (public API). Registration works only when running from the .app bundle.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// The user must allow it in System Settings (Login Items).
        case requiresApproval
        case notFound
        case unavailable(String)

        var text: String {
            switch self {
            case .enabled: return L("On", "オン")
            case .disabled: return L("Off", "オフ")
            case .requiresApproval: return L("Approval required in System Settings › General › \(MacItem.loginItems()). Allow LazySpace there to turn it on.",
                                             "システム設定 › 一般 › \(MacItem.loginItems())でLazySpaceを許可すると有効になります")
            case .notFound: return L("Off", "オフ")
            case .unavailable(let why): return L("Unavailable: \(why)", "利用できません: \(why)")
            }
        }
    }

    /// Cannot register outside an app bundle (swift run and the like).
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static func state() -> State {
        guard isBundled else { return .unavailable(L("Available only when LazySpace runs from LazySpace.app.", "アプリ束（LazySpace.app）から起動した時だけ使えます")) }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .disabled
        @unknown default: return .unavailable(L("Unknown state", "不明な状態"))
        }
    }

    /// Registers or unregisters; returns the reason on failure.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isBundled else { return L("Open at Login can be set only when LazySpace runs from LazySpace.app.", "「ログイン時に開く」はアプリ束（LazySpace.app）から起動した時だけ設定できます") }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status != .notRegistered && SMAppService.mainApp.status != .notFound { try SMAppService.mainApp.unregister() }
            }
            return nil
        } catch {
            return enabled
                ? L("Could not turn on Open at Login: \(error.localizedDescription)", "「ログイン時に開く」をオンにできません: \(error.localizedDescription)")
                : L("Could not turn off Open at Login: \(error.localizedDescription)", "「ログイン時に開く」をオフにできません: \(error.localizedDescription)")
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The exec-on-* hooks from the configuration. Launched without waiting; failures are reported in one sentence.
enum HookRunner {
    /// Apps launched from Finder or as login items have no Homebrew in PATH, so prepend it for hook commands.
    static func hookPATH(_ inherited: String?) -> String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin"]
        for part in (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init) where !parts.contains(part) {
            parts.append(part)
        }
        return parts.joined(separator: ":")
    }

    /// argv[0] without a / is looked up in PATH (via /usr/bin/env). The command is responsible for itself, so it runs with
    /// its own privacy permissions, never LazySpace's Accessibility access. Returns its process ID, or nil if it did not start.
    @discardableResult
    static func run(_ argv: [String], environment extra: [String: String], onProblem: @escaping (String) -> Void) -> pid_t? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        let path = first.contains("/") ? first : "/usr/bin/env"
        let arguments = first.contains("/") ? argv : [path] + argv
        let label = argv.joined(separator: " ")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = hookPATH(env["PATH"])
        for (k, v) in extra { env[k] = v }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // As with Process: none of LazySpace's descriptors, default signal handling, and a process group of its own.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setpgroup(&attributes, 0)
        // Without it the command would borrow LazySpace's permissions, so it does not run at all.
        guard disclaim(&attributes) else {
            onProblem(L("Could not start hook \(label): macOS cannot run it apart from LazySpace's permissions.",
                        "フック\(label)を起動できません: LazySpaceの許可から切り離して実行できません。"))
            return nil
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArguments + cEnvironment).forEach { free($0) } }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attributes, cArguments, cEnvironment)
        guard error == 0 else {
            let reason = String(cString: strerror(error))
            onProblem(L("Could not start hook \(label): \(reason)", "フック\(label)を起動できません: \(reason)"))
            return nil
        }
        whenExited(pid) { status in
            // A normal exit keeps its code in the second byte; otherwise the low bits are the signal, as Process reports it.
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
            guard code != 0 else { return }
            onProblem(L("Hook \(label) exited with status \(code).", "フック\(label)が終了コード\(code)で終わりました。"))
        }
        return pid
    }

    /// Tests replace it to see a missing symbol.
    static var disclaim: (inout posix_spawnattr_t?) -> Bool = { PrivateSymbols.disclaimResponsibility(&$0) }

    private static let reaper = DispatchQueue(label: "jp.lazyspace.hooks")

    /// Reaps the process once it exits and passes its wait status.
    private static func whenExited(_ pid: pid_t, _ done: @escaping (Int32) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: reaper)
        var finished = false
        // The exit event can arrive just before the process becomes waitable, so after it the wait blocks briefly.
        func reap(blocking: Bool) {
            guard !finished else { return }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, blocking ? 0 : WNOHANG) } while result == -1 && errno == EINTR
            guard result == pid || blocking else { return }
            finished = true
            // The handler holds the source until here.
            source.cancel()
            if result == pid { done(status) }
        }
        source.setEventHandler { reap(blocking: true) }
        source.resume()
        // A command that exits before the source watches is reaped here.
        reaper.async { reap(blocking: false) }
    }
}
