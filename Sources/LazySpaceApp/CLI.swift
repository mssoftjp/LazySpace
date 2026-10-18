import Copy
import Foundation
import LayoutCore
import MacSupport
import Operations

/// App version: the short version from VERSION, the build number from install time. Status shows both.
enum BundleVersion {
    static func short(_ bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static func build(_ bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    static func label(_ bundle: Bundle = .main) -> String {
        let version = short(bundle)
        let build = build(bundle)
        guard !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}

/// Command line. Talks to the running app over ControlPort through the same operation path; without the app, nothing moves.
/// Explicit subcommands only. Machine targets, preconditions, and desired states travel in separate fields.
enum CLI {
    struct Invocation: Equatable {
        /// ControlPort command name.
        var cmd: String
        var arg: String?
        /// Output JSON (default: human-readable text).
        var json: Bool = false
        /// Polls until the result is final.
        var waitsForResult: Bool { ["arrange.v3", "integrate.v3", "edit.v3", "focus-window.v3"].contains(cmd) }
        /// View selection (list-spaces shows only the Space list from the inspect result).
        var view: String? = nil
        var windowID: WindowID? = nil
        var expectedSpaceID: UInt64? = nil
        var expectedPID: Int32? = nil
        var desiredState: Bool? = nil
        /// Caller-supplied receipt. Nil asks the CLI to reserve one before the single mutation send.
        var requestID: String? = nil
    }

    struct Output: Equatable {
        var stdout: String = ""
        var stderr: String?
        var exitCode: Int32
    }

    enum Parsed: Equatable {
        case help
        case version
        case invocation(Invocation)
        case error(String)
    }

    /// `lazyspace help`. Command syntax that reads the same in every language stays in code; the descriptions are catalog entries,
    /// and the columns are laid out here so a translation never aligns text.
    static var usage: String { helpLines.map(render).joined(separator: "\n") }

    enum HelpLine {
        case blank
        /// A heading or paragraph at the left margin.
        case text(LocalizedStringResource)
        /// A line at the left margin that reads the same in every language.
        case plain(String)
        /// An indented line.
        case indented(LocalizedStringResource)
        /// An indented line that reads the same in every language.
        case literal(String)
        /// A command and its description.
        case row(String, LocalizedStringResource)
        /// A command whose placeholders are translated, and its description.
        case localizedRow(LocalizedStringResource, LocalizedStringResource)
        /// Another line of the description above, in the description column.
        case more(LocalizedStringResource)
    }

    /// Commands start after two spaces; descriptions start at column 31.
    static func render(_ line: HelpLine) -> String {
        switch line {
        case .blank: ""
        case .text(let text): L(text)
        case .plain(let text): text
        case .indented(let text): "  " + L(text)
        case .literal(let text): "  " + text
        case .row(let syntax, let text): "  " + padded(syntax, to: 29) + L(text)
        case .localizedRow(let syntax, let text): "  " + padded(L(syntax), to: 29) + L(text)
        case .more(let text): String(repeating: " ", count: 31) + L(text)
        }
    }

    private static let commandNames: Set<String> = [
        "help", "version", "status", "show", "settings", "pause", "resume", "quit", "reload",
        "arrange", "integrate", "list-windows", "list-spaces", "focus", "swap", "move", "join",
        "resize", "float", "zoom", "fullscreen", "minimize", "toggle-split", "accordion", "balance", "undo", "close",
        "space", "move-to-space", "mode", "login-item", "wait-settled", "result", "request-token"
    ]

    static let helpLines: [HelpLine] = [
        .text(.cliHelpUsage),
        .blank,
        .text(.cliHelpSectionStatus),
        .row("status", .cliHelpStatus),
        .row("list-windows", .cliHelpListWindows),
        .row("list-spaces", .cliHelpListSpaces),
        .row("show", .cliHelpShow),
        .row("settings", .cliHelpSettings),
        .blank,
        .text(.cliHelpSectionArrangement),
        .row("arrange", .cliHelpArrange),
        .row("integrate", .cliHelpIntegrate),
        .row("pause", .cliHelpPause),
        .row("resume", .cliHelpResume),
        .blank,
        .text(.cliHelpSectionLayoutEditing),
        .localizedRow(.cliHelpFocusDirectionSyntax, .cliHelpFocusDirection),
        .row("focus back", .cliHelpFocusBack),
        .localizedRow(.cliHelpSwapDirectionSyntax, .cliHelpSwapDirection),
        .localizedRow(.cliHelpMoveDirectionSyntax, .cliHelpMoveDirection),
        .localizedRow(.cliHelpJoinDirectionSyntax, .cliHelpJoinDirection),
        .localizedRow(.cliHelpResizeAxisAmountSyntax, .cliHelpResizeAxisAmount),
        .row("balance", .cliHelpBalance),
        .row("toggle-split", .cliHelpToggleSplit),
        .row("accordion", .cliHelpAccordion),
        .row("float on|off", .cliHelpFloatOnOff),
        .row("zoom on|off", .cliHelpZoomOnOff),
        .row("undo", .cliHelpUndo),
        .row("close", .cliHelpClose),
        .row("fullscreen on|off", .cliHelpFullscreenOnOff),
        .row("minimize on|off", .cliHelpMinimizeOnOff),
        .blank,
        .text(.cliHelpSectionSpaces),
        .localizedRow(.cliHelpSpaceNumberSyntax, .cliHelpSpaceNumber),
        .localizedRow(.cliHelpSpaceNextSpaceSyntax, .cliHelpSpaceNextSpace),
        .row("space back", .cliHelpSpaceBack),
        .localizedRow(.cliHelpMoveToSpaceSyntax, .cliHelpMoveToSpace),
        .indented(.cliHelpSpacesMoveToSpace),
        .more(.cliHelpMoveToSpaceMore),
        .indented(.cliHelpSpacesMoveToSpace2),
        .more(.cliHelpMoveToSpaceMore2),
        .more(.cliHelpMoveToSpaceMore3),
        .indented(.cliHelpSpacesSpaceNumberDisplay),
        .more(.cliHelpSpaceNumberDisplayMore),
        .blank,
        .text(.cliHelpSectionSettings),
        .row("mode", .cliHelpMode),
        .localizedRow(.cliHelpModeNameSyntax, .cliHelpModeName),
        .row("reload", .cliHelpReload),
        .row("login-item", .cliHelpLoginItem),
        .indented(.cliHelpSettingsLoginItemOn),
        .more(.cliHelpLoginItemOnMore),
        .blank,
        .text(.cliHelpSectionOther),
        .localizedRow(.cliHelpWaitSettledSecondsSyntax, .cliHelpWaitSettledSeconds),
        .row("request-token", .cliHelpRequestToken),
        .localizedRow(.cliHelpResultIdSyntax, .cliHelpResultId),
        .row("version", .cliHelpVersion),
        .row("help", .cliHelpHelp),
        .row("quit", .cliHelpQuit),
        .blank,
        .text(.cliHelpSectionExplicitTargets),
        .indented(.cliHelpExplicitTargetsWindowIdId),
        .indented(.cliHelpExplicitTargetsAvailableOnWindow),
        .indented(.cliHelpExplicitTargetsFocusWindowId),
        .indented(.cliHelpExplicitTargetsExpectSpaceId),
        .indented(.cliHelpExplicitTargetsRequestIdToken),
        .indented(.cliHelpExplicitTargetsTheCLIReserves),
        .indented(.cliHelpExplicitTargetsResendingTheSame),
        .indented(.cliHelpExplicitTargetsBusyAndOther),
        .indented(.cliHelpExplicitTargetsRequestTokenDoes),
        .indented(.cliHelpExplicitTargetsMoveToSpace),
        .indented(.cliHelpExplicitTargetsWaitSettledCovers),
        .blank,
        .text(.cliHelpSectionJSONOutput),
        .indented(.cliHelpJSONOutputJsonIncludesSchemaVersion),
        .indented(.cliHelpJSONOutputAFinishedMutation),
        .indented(.cliHelpJSONOutputResultIdAnd),
        .indented(.cliHelpJSONOutputHelpAndVersion),
        .indented(.cliHelpJSONOutputScriptsShouldRead),
        .blank,
        .text(.cliHelpSectionExitCodes),
        .indented(.cliHelpExitCodes0SucceededOr),
        .indented(.cliHelpExitCodes1RefusedPartially),
        .indented(.cliHelpExitCodes2CommunicationWith),
        .indented(.cliHelpExitCodesWithExit2),
        .blank,
        .text(.cliHelpRunTheCLIAs),
        .blank,
        .text(.cliHelpConfigurationConfigLazyspaceConfig),
    ]



    /// Parses arguments; nil means not the CLI (launch as the app).
    static func parse(_ rawArgs: [String]) -> Parsed? {
        if rawArgs.isEmpty || rawArgs == ["--ready"] { return nil }
        var positional: [String] = []
        var options: [String: String] = [:]
        var json = false
        var follow = false
        var i = 0
        func error(_ message: String) -> Parsed { .error(message + " Run `lazyspace help`.") }
        while i < rawArgs.count {
            let token = rawArgs[i]
            switch token {
            case "--json":
                if json { return error("Duplicate --json.") }; json = true
            case "--follow":
                if follow { return error("Duplicate --follow.") }; follow = true
            case "--window-id", "--expect-space-id", "--expect-pid", "--request-id", "--display":
                guard options[token] == nil, i + 1 < rawArgs.count else { return error("Missing or duplicate value for \(token).") }
                i += 1; options[token] = rawArgs[i]
            case "--help", "-h":
                guard rawArgs.count == 1 else { return error("help accepts no arguments.") }; return .help
            case "--version", "-v":
                guard rawArgs.count == 1 else { return error("version accepts no arguments.") }; return .version
            default:
                if token.hasPrefix("--") { return error("Unknown option: \(token).") }
                positional.append(token)
            }
            i += 1
        }
        guard let name = positional.first else { return error("A command is required.") }
        let rest = Array(positional.dropFirst())
        let window = options["--window-id"].flatMap(UInt32.init).map(WindowID.init)
        let space = options["--expect-space-id"].flatMap(UInt64.init)
        let pid = options["--expect-pid"].flatMap(Int32.init)
        if options["--window-id"] != nil && (window == nil || window?.raw == 0) { return error("Invalid window ID.") }
        if options["--expect-space-id"] != nil && (space == nil || space == 0) { return error("Invalid Space ID.") }
        if options["--expect-pid"] != nil && (pid == nil || pid! <= 0) { return error("Invalid process ID.") }
        if window != nil && space == nil { return error("--window-id requires --expect-space-id.") }
        if pid != nil && window == nil { return error("--expect-pid requires --window-id.") }
        let targetCommands = ["focus", "swap", "move", "join", "resize", "float", "zoom", "close", "fullscreen", "minimize", "move-to-space", "toggle-split", "accordion"]
        let spaceCommands = targetCommands + ["arrange", "integrate", "balance", "undo", "space"]
        if window != nil && !targetCommands.contains(name) { return error("\(name) does not accept a window target.") }
        if space != nil && !spaceCommands.contains(name) { return error("\(name) does not accept a Space precondition.") }
        if follow && name != "move-to-space" { return error("\(name) does not accept --follow.") }
        var display: Int?
        if let value = options["--display"] {
            guard name == "space" || name == "move-to-space" else { return error("\(name) does not accept --display.") }
            guard case .index(let n)? = SpaceTarget.parseUserInput(value) else { return error("Invalid display number.") }
            display = n
        }
        let requestIDCommands: Set<String> = ["arrange", "integrate", "focus", "swap", "move", "join", "resize", "float", "zoom", "fullscreen", "minimize", "toggle-split", "accordion", "balance", "undo", "close", "space", "move-to-space"]
        if let token = options["--request-id"] {
            guard requestIDCommands.contains(name) else {
                return error(commandNames.contains(name) ? "\(name) does not accept --request-id." : "Unknown command: \(name).")
            }
            guard MutationReceiptRegistry.isCanonicalToken(token) else { return error("--request-id must be a canonical request token.") }
        }
        func inv(_ cmd: String, _ arg: String? = nil, view: String? = nil, desired: Bool? = nil) -> Parsed {
            .invocation(Invocation(cmd: cmd, arg: arg, json: json, view: view, windowID: window, expectedSpaceID: space, expectedPID: pid, desiredState: desired, requestID: options["--request-id"]))
        }
        func arity(_ range: ClosedRange<Int>) -> Bool { range.contains(rest.count) }
        switch name {
        case "help", "version":
            guard rest.isEmpty, !json else { return error("\(name) accepts no arguments.") }
            return name == "help" ? .help : .version
        case "status", "show", "settings", "pause", "resume", "quit", "reload":
            guard rest.isEmpty else { return error("Unexpected argument for \(name).") }
            return inv(name)
        case "arrange", "integrate":
            guard rest.isEmpty else { return error("Unexpected argument for \(name).") }
            return inv(name + ".v3")
        case "list-windows", "list-spaces":
            guard rest.isEmpty else { return error("Unexpected argument for \(name).") }
            return inv("inspect", view: name == "list-windows" ? "windows" : "spaces")
        case "focus" where rest.isEmpty && window != nil:
            return inv("focus-window.v3")
        case "focus" where rest == ["back"]:
            guard window == nil else { return error("focus back does not accept a window target.") }
            return inv("edit.v3", "focus-back")
        case "focus", "swap", "move", "join":
            guard arity(1...1), Direction(rawValue: rest[0]) != nil else { return error("\(name) requires one direction: left, down, up, right.") }
            return inv("edit.v3", "\(name)-\(rest[0])")
        case "resize":
            guard arity(1...2), ["width", "height", "smart"].contains(rest[0]) else { return error("resize requires width, height, or smart and an optional amount.") }
            let amount = rest.count == 2 ? rest[1] : "0.05"
            guard let number = Double(amount), number.isFinite, abs(number) < 1, number != 0 else { return error("resize amount must be nonzero and between -1 and 1.") }
            return inv("edit.v3", "resize-\(rest[0]) \(amount)")
        case "float", "zoom", "fullscreen", "minimize":
            guard arity(1...1), ["on", "off"].contains(rest[0]) else { return error("\(name) requires on or off.") }
            if name == "minimize", rest[0] == "off", window == nil { return error("minimize off requires --window-id.") }
            return inv("edit.v3", name, desired: rest[0] == "on")
        case "toggle-split", "accordion", "balance", "undo", "close":
            guard rest.isEmpty else { return error("Unexpected argument for \(name).") }
            return inv("edit.v3", name)
        case "space", "move-to-space":
            guard arity(1...1), var target = SpaceTarget.parseUserInput(rest[0]), name == "space" || target != .back else { return error("Invalid Space destination.") }
            if let display {
                guard case .index(let n) = target else { return error("--display needs a desktop number.") }
                target = .desktop(n, display: display)
            }
            return inv("edit.v3", (follow ? "move-to-space-follow" : name) + "-" + target.editText)
        case "mode", "login-item":
            guard arity(0...1), name != "login-item" || rest.isEmpty || ["on", "off"].contains(rest[0]) else { return error("Invalid arguments for \(name).") }
            return inv(name, rest.first)
        case "wait-settled":
            guard arity(0...1) else { return error("wait-settled accepts one timeout.") }
            if let value = rest.first { guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 120 else { return error("Timeout must be in (0, 120] seconds.") } }
            return inv(name, rest.first)
        case "request-token":
            guard rest.isEmpty else { return error("Unexpected argument for \(name).") }
            return inv("request-token.v3")
        case "result":
            guard arity(1...1), UUID(uuidString: rest[0]) != nil || MutationReceiptRegistry.isCanonicalToken(rest[0]) else {
                return error("result requires an operation UUID or a request token.")
            }
            return inv(name, rest[0])
        default: return error("Unknown command: \(name).")
        }
    }

    /// This executable's version, read from the .app's Info.plist even through the lazyspace symlink.
    static func executableVersion() -> String {
        if Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil { return BundleVersion.label() }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundleURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL) { return BundleVersion.label(bundle) }
        return "dev"
    }

    // MARK: - Output

    /// The latest result may belong to another operation; only a completion with the requested ID counts.
    static func settledForRequest(_ observation: ControlPort.Settlement, elapsed: TimeInterval) -> Bool {
        // Client duration is monotonic; observedAt is informational ISO8601.
        observation.settled && elapsed >= observation.requiredStableFor
    }

    static func exitCode(_ response: ControlPort.Response, invocation: Invocation) -> Int32 {
        response.ok && (invocation.cmd != "result" || response.code == "finished") ? 0 : 1
    }

    static func completedResult(in response: ControlPort.Response, operationID: String?) -> OperationResult? {
        guard let operationID, response.operationID == operationID, let result = response.result, result.id == operationID else { return nil }
        return result
    }

    /// One CLI invocation. `send` is the process boundary: a nil reply is a lost response, not a reason to resend.
    static func execute(_ invocation: Invocation,
                        send: (ControlPort.Request, TimeInterval) -> ControlPort.Response?,
                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        now: () -> Date = Date.init,
                        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        unavailable: String,
                        unavailableCode: String = "connection-unavailable") -> Output {
        func present(_ response: ControlPort.Response, exit: Int32? = nil, textToStderr: Bool = false) -> Output {
            let rendered = render(response, invocation: invocation)
            let code = exit ?? exitCode(response, invocation: invocation)
            if invocation.json || !textToStderr { return Output(stdout: rendered, exitCode: code) }
            return Output(stderr: rendered, exitCode: code)
        }
        func lost(_ message: String, requestID: String?, operationID: String?, exit: Int32) -> Output {
            let response = ControlPort.Response(ok: false, message: message, operationID: operationID, code: exit == 2 ? unavailableCode : "timeout", requestID: requestID)
            return present(response, exit: exit, textToStderr: true)
        }
        if invocation.cmd == "wait-settled" {
            let waitStarted = uptime()
            let seconds = Double(invocation.arg ?? "5") ?? 5
            let deadline = now().addingTimeInterval(seconds)
            var last: ControlPort.Response?
            while now() < deadline {
                let remaining = deadline.timeIntervalSince(now())
                guard let started = send(ControlPort.Request(cmd: "settle.v2"), min(1, max(0.05, remaining))) else {
                    return lost(unavailable, requestID: nil, operationID: nil, exit: 2)
                }
                guard started.ok, let id = started.operationID else { return present(started, exit: 1) }
                while now() < deadline {
                    sleep(0.05)
                    let slice = deadline.timeIntervalSince(now())
                    guard let observation = send(ControlPort.Request(cmd: "inspect-result", arg: id), min(1, max(0.05, slice))) else {
                        return lost(unavailable, requestID: nil, operationID: nil, exit: 2)
                    }
                    if let settled = observation.settlement {
                        last = observation
                        if settledForRequest(settled, elapsed: uptime() - waitStarted) {
                            let text = invocation.json ? render(observation, invocation: invocation) : "Current-Space geometry was stable after observation."
                            return Output(stdout: text, exitCode: 0)
                        }
                        break
                    }
                }
                sleep(0.1)
            }
            var response = last ?? ControlPort.Response(ok: false, message: "")
            response.ok = false
            response.code = "timeout"
            response.message = "Current-Space observation did not settle before the timeout."
            return present(response, exit: 1)
        }
        if invocation.waitsForResult {
            return executeMutation(invocation, send: send, sleep: sleep, now: now, uptime: uptime, unavailable: unavailable, present: present, lost: lost)
        }
        if invocation.cmd == "request-token.v3" || invocation.cmd == "result" {
            return executeIdentityQuery(invocation, send: send, unavailable: unavailable, present: present, lost: lost)
        }
        guard let response = send(ControlPort.Request(cmd: invocation.cmd, arg: invocation.arg, windowID: invocation.windowID, expectedSpaceID: invocation.expectedSpaceID, expectedPID: invocation.expectedPID, desiredState: invocation.desiredState, requestID: invocation.requestID), 5) else {
            return lost(unavailable, requestID: invocation.requestID, operationID: nil, exit: 2)
        }
        if invocation.cmd == "inspect", let id = response.operationID {
            let deadline = now().addingTimeInterval(30)
            while now() < deadline {
                sleep(0.25)
                guard let next = send(ControlPort.Request(cmd: "inspect-result", arg: id), 5) else {
                    return lost(unavailable, requestID: nil, operationID: id, exit: 2)
                }
                if next.inspection != nil { return present(next, exit: 0) }
            }
            return lost("Window inspection did not finish before the timeout.", requestID: nil, operationID: id, exit: 1)
        }
        return present(response)
    }

    private static func executeMutation(_ invocation: Invocation,
                                        send: (ControlPort.Request, TimeInterval) -> ControlPort.Response?,
                                        sleep: (TimeInterval) -> Void,
                                        now: () -> Date,
                                        uptime: () -> TimeInterval,
                                        unavailable: String,
                                        present: (ControlPort.Response, Int32?, Bool) -> Output,
                                        lost: (String, String?, String?, Int32) -> Output) -> Output {
        let requestID: String
        if let supplied = invocation.requestID {
            requestID = supplied
        } else {
            guard let allocated = send(ControlPort.Request(cmd: "request-token.v3"), 5) else {
                return lost(unavailable, nil, nil, 2)
            }
            var ignored: String?
            let checked = correlated(allocated, context: .reservation, seenOperationID: &ignored)
            guard checked.ok, let id = checked.requestID else { return present(checked, 1, false) }
            requestID = id
        }
        let request = ControlPort.Request(cmd: invocation.cmd, arg: invocation.arg, windowID: invocation.windowID, expectedSpaceID: invocation.expectedSpaceID, expectedPID: invocation.expectedPID, desiredState: invocation.desiredState, requestID: requestID)
        guard let response = send(request, 5) else {
            return lost(unavailable, requestID, nil, 2)
        }
        let acceptedAt = uptime()
        var knownOperationID: String?
        let accepted = correlated(response, context: .request(requestID, knownOperationID: knownOperationID), seenOperationID: &knownOperationID)
        guard accepted.code != "protocol-error" else { return present(accepted, 1, false) }
        // Adds the time since the acceptance reply (CLI clock) to a completed result under its own key.
        func received(_ response: ControlPort.Response) -> ControlPort.Response {
            var stamped = response
            stamped.receivedAt = ((uptime() - acceptedAt) * 10_000).rounded() / 10
            return stamped
        }
        if let completed = completedResult(in: accepted, operationID: accepted.operationID) {
            return present(received(accepted), completed.outcome == .complete ? 0 : 1, false)
        }
        guard accepted.code == "pending" else { return present(accepted, nil, false) }
        let started = now()
        let deadline = started.addingTimeInterval(120)
        var last = accepted
        while now() < deadline {
            sleep(resultPollInterval(elapsed: now().timeIntervalSince(started)))
            let remaining = deadline.timeIntervalSince(now())
            guard let polled = send(ControlPort.Request(cmd: "result", arg: requestID), min(1, max(0.05, remaining))) else {
                return lost(unavailable, requestID, knownOperationID, 2)
            }
            let valid = correlated(polled, context: .request(requestID, knownOperationID: knownOperationID), seenOperationID: &knownOperationID)
            if valid.code == "protocol-error" { return present(valid, 1, false) }
            last = valid
            if completedResult(in: valid, operationID: valid.operationID) != nil || !valid.ok { break }
        }
        if let completed = completedResult(in: last, operationID: last.operationID) {
            return present(received(last), completed.outcome == .complete ? 0 : 1, false)
        }
        if !last.ok { return present(last, nil, false) }
        let timeout = ControlPort.Response(ok: false, message: "Could not get the operation result. Query this request ID before sending a different mutation.", operationID: knownOperationID, code: "timeout", requestID: requestID)
        return present(timeout, 1, true)
    }

    /// Result polling interval. Space switches finish in about a second, so 20 ms for the first 2 s (like SpaceControl's arrival watch),
    /// 100 ms up to 10 s, then 250 ms (so long operations such as arranging do not add main-thread queries).
    static func resultPollInterval(elapsed: TimeInterval) -> TimeInterval {
        if elapsed < 2 { return 0.02 }
        if elapsed < 10 { return 0.1 }
        return 0.25
    }

    /// `request-token` and `result` use the same reply rules as mutation polling.
    private static func executeIdentityQuery(_ invocation: Invocation,
                                             send: (ControlPort.Request, TimeInterval) -> ControlPort.Response?,
                                             unavailable: String,
                                             present: (ControlPort.Response, Int32?, Bool) -> Output,
                                             lost: (String, String?, String?, Int32) -> Output) -> Output {
        let request = ControlPort.Request(cmd: invocation.cmd, arg: invocation.arg)
        guard let response = send(request, 5) else {
            if invocation.cmd == "result", let arg = invocation.arg {
                if MutationReceiptRegistry.isCanonicalToken(arg) { return lost(unavailable, arg, nil, 2) }
                return lost(unavailable, nil, arg, 2)
            }
            return lost(unavailable, nil, nil, 2)
        }
        var seen: String?
        let context: ReplyContext
        if invocation.cmd == "request-token.v3" {
            context = .reservation
        } else if let arg = invocation.arg, MutationReceiptRegistry.isCanonicalToken(arg) {
            context = .request(arg, knownOperationID: nil)
        } else {
            let operationID = invocation.arg ?? ""
            seen = operationID
            context = .operation(operationID)
        }
        return present(correlated(response, context: context, seenOperationID: &seen), nil, false)
    }

    private enum ReplyContext {
        /// Public or automatic `request-token`.
        case reservation
        /// Mutation reply or receipt lookup. `knownOperationID` was already accepted, if any.
        case request(String, knownOperationID: String?)
        /// Result lookup by an ordinary operation UUID.
        case operation(String)
    }

    private static func protocolFailure(requestID: String?, operationID: String?, message: String) -> ControlPort.Response {
        ControlPort.Response(ok: false, message: message, operationID: operationID, code: "protocol-error", requestID: requestID)
    }

    /// Schema, identity, and state for a reservation, mutation, or result reply.
    /// A different nonnil operation ID is rejected. Pending and finished replies must keep an ID
    /// already seen. Terminal lookup errors may omit it; the known ID is then kept locally.
    private static func correlated(_ response: ControlPort.Response, context: ReplyContext, seenOperationID: inout String?) -> ControlPort.Response {
        let requiredRequestID: String?
        let knownOperationID: String?
        switch context {
        case .reservation:
            requiredRequestID = nil
            knownOperationID = nil
        case .request(let requestID, let known):
            requiredRequestID = requestID
            knownOperationID = known
        case .operation(let operationID):
            requiredRequestID = nil
            knownOperationID = operationID
        }
        let failure = protocolFailure(requestID: requiredRequestID, operationID: knownOperationID, message: "The response did not match the retained request.")
        guard response.schemaVersion == 2 else { return failure }
        if let requiredRequestID, response.requestID != requiredRequestID { return failure }
        if let result = response.result, result.id != response.operationID { return failure }
        if let knownOperationID, let returned = response.operationID, returned != knownOperationID { return failure }

        switch context {
        case .reservation:
            if response.ok {
                guard response.code == "reserved", let id = response.requestID, MutationReceiptRegistry.isCanonicalToken(id),
                      response.operationID == nil, response.result == nil else { return failure }
                return response
            }
            guard let code = response.code, !code.isEmpty, response.result == nil, response.operationID == nil else { return failure }
            return response
        case .request, .operation:
            switch response.code {
            case "pending":
                guard response.ok, response.result == nil else { return failure }
                if let knownOperationID, response.operationID != knownOperationID { return failure }
                if seenOperationID == nil { seenOperationID = response.operationID }
                return response
            case "finished":
                guard let result = response.result, let operationID = response.operationID, result.id == operationID,
                      response.ok == (result.outcome == .complete) else { return failure }
                if let knownOperationID, operationID != knownOperationID { return failure }
                if seenOperationID == nil { seenOperationID = operationID }
                return response
            case "reserved", nil:
                return failure
            default:
                guard response.ok == false, response.result == nil, response.code?.isEmpty == false else { return failure }
                var accepted = response
                if accepted.operationID == nil { accepted.operationID = knownOperationID }
                return accepted
            }
        }
    }

    static func render(_ res: ControlPort.Response, invocation: Invocation) -> String {
        if invocation.json {
            var response = res
            if invocation.cmd == "inspect" {
                response.status = nil
                if invocation.view == "spaces" { response.inspection = nil } else { response.spaces = nil }
            }
            return (try? ControlPort.encoder.encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        switch invocation.cmd {
        case "status":
            return res.status.map(statusText) ?? res.message
        case "inspect":
            if invocation.view == "spaces" { return res.spaces.map(spacesText) ?? L(.cliCouldNotGetTheList) }
            return res.inspection.map { windowsText($0) } ?? res.message
        case "arrange.v3", "integrate.v3", "edit.v3", "focus-window.v3", "result", "request-token.v3":
            var lines: [String] = []
            let completed = completedResult(in: res, operationID: res.operationID)
            if let requestID = res.requestID { lines.append("Request: \(requestID)") }
            if let operationID = res.operationID, res.requestID != nil { lines.append("Operation: \(operationID)") }
            if !res.message.isEmpty, completed == nil || !res.ok { lines.append(res.message) }
            if let completed { lines.append(resultText(completed)) }
            if lines.isEmpty { lines.append(res.message) }
            return lines.joined(separator: "\n")
        default:
            return res.message.isEmpty ? (res.ok ? "OK" : L(.cliFailed)) : res.message
        }
    }

    /// The "This Space" line, from the configuration, global pause, automatic availability, this Space's pause, and whether it started.
    static func currentSpaceText(_ s: AppStatus) -> String {
        if !s.trusted || s.availability == .needsSetup { return L(.cliSetupRequired) }
        if s.paused { return L(.cliPausedGlobally) }
        if !s.autoAvailable { return L(.cliManualArrangementOnly) }
        if s.currentSpaceAutoPaused { return L(.cliAutomaticArrangementOffInThis) }
        return s.currentSpaceManaged ? L(.cliAutomaticArrangementActive) : L(.cliWaitingToStart)
    }

    static func automaticArrangementText(_ s: AppStatus) -> String {
        s.autoAvailable ? L(.cliAvailable) : L(.cliUnavailableBecause(s.autoReason))
    }

    static func statusText(_ s: AppStatus) -> String {
        // A label longer than its column is not cut; the value follows after one space.
        func row(_ label: String, _ value: String) -> String {
            let head = label + ":"
            return (displayWidth(head) < 24 ? padded(head, to: 24) : head + " ") + value
        }
        func indented(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\n  ") }
        var lines = [
            "LazySpace \(s.version)",
            row(L(.cliActivity), s.idle ? L(.cliIdle) : L(.cliOperationsOrMouseInteractionsIn)),
            row(L(.cliStatus), StatusMenuCopy.availabilityTitle(s)),
            row(L(.cliThisSpace), currentSpaceText(s)),
            row(AccessPane.name(), s.trusted ? L(.cliGranted) : L(.cliNotGranted)),
            row(L(.cliManualArrangement), s.manualAvailable ? L(.cliAvailable) : L(.cliUnavailableBecause(s.manualReason))),
            row(L(.cliAutomaticArrangement), automaticArrangementText(s)),
            row(L(.appDelegateMode), s.modes.count > 1 ? L(.cliModeWithChoices(s.mode, s.modes.joined(separator: Copy.listSeparator))) : s.mode),
            row(MacItem.openAtLogin, s.loginItem),
            StatusMenuCopy.occupancyLine(waiting: s.waiting.count, floatingCount: s.floating.count, zoomed: s.zoomed != nil),
            row(L(.cliConfiguration), s.configPath) + (s.configError.map { "\n  " + L(.cliConfigError(indented($0))) } ?? "") + s.configNotes.map { "\n  " + L(.cliConfigNote(indented($0))) }.joined(),
        ]
        lines.append(row(L(.cliFixedSizeWindows), s.dialogRegion))
        if let desktop = s.desktopShortcuts { lines.append(row(L(.cliDesktopShortcuts), desktop)) }
        if let left = s.leftShortcut { lines.append(row(MacItem.moveSpace(right: false), left)) }
        if let right = s.rightShortcut { lines.append(row(MacItem.moveSpace(right: true), right)) }
        if let freshness = s.dockShortcutFreshness { lines.append(row(L(.cliShortcutPreferences), freshness)) }
        if s.progress != .idle { lines.append(row(L(.cliInProgress), s.progressText)) }
        if let refusal = s.lastRefusal { lines.append(row(L(.cliLatestNotice), refusal)) }
        if let update = s.availableUpdate { lines.append(row(UpdateCopy.statusRow, UpdateCopy.available(update))) }
        if let r = s.lastResult, StatusMenuCopy.showsRecent(result: r, managed: s.currentSpaceManaged) {
            let title = ReadyWindowController.outcomeTitle(r)
            let body = ReadyWindowController.resultBody(r, name: AppNames.localized)
            let text = body.isEmpty ? title : title + "\n" + body
            lines.append(row(L(.cliLatestOperation), indented(text)))
        }
        return lines.joined(separator: "\n")
    }

    /// Terminal columns: 2 for hiragana, katakana, and kanji. Counting characters would misalign Japanese columns.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
    }

    private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Pads to a display width, never cutting inside a character.
    static func padded(_ text: String, to width: Int) -> String {
        var kept = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let w = scalarWidth(scalar)
            if used + w > width { break }
            kept.unicodeScalars.append(scalar)
            used += w
        }
        if used < width { kept += String(repeating: " ", count: width - used) }
        return kept
    }

    static func windowsText(_ ins: Inspection, name: (String) -> String = AppNames.localized) -> String {
        var lines: [String] = []
        func row(_ id: String, _ app: String, _ size: String, _ note: String) {
            lines.append(padded(id, to: 8) + padded(app, to: 28) + padded(size, to: 22) + note)
        }
        row("ID", L(.cliApp), L(.cliSizeAndPosition), ReadyWindowController.verdictColumnTitle)
        for t in ins.targets { row(t.id.description, ReadyWindowController.shownApp(t.app, name: name), sizeText(t.frame), ReadyWindowController.eligibleVerdict) }
        for e in ins.excluded { row(e.window.id.description, ReadyWindowController.shownApp(e.window.app, name: name), sizeText(e.window.frame), ReadyWindowController.exclusionText(e)) }
        for a in ins.snapshot.unobservedApps { row("-", ReadyWindowController.shownApp(a, name: name), "?", L(.cliNoResponseCouldNotRead)) }
        if ins.targets.isEmpty && ins.excluded.isEmpty { lines.append(ins.snapshot.trusted ? L(.cliNoWindows) : L(.cliCannotReadWindowsWithoutThe(AccessPane.name()))) }
        let unobserved = ins.snapshot.unobservedApps.count
        lines.append(unobserved == 0
                     ? L(.cliEligibleExcluded(ins.targets.count, ins.excluded.count))
                     : L(.cliEligibleExcludedNoResponse(ins.targets.count, ins.excluded.count, unobserved)))
        return lines.joined(separator: "\n")
    }

    static func spacesText(_ overview: SpaceOverview) -> String {
        let idWidth = 8
        // Wide enough for the language's heading and kinds; never narrower than 14, so English and Japanese keep their layout.
        let kindWidth = max(14, ([L(.cliType)] + [0, 4, nil].map(spaceKindLabel)).map(displayWidth).max() ?? 0)
        // The last column's heading is not cut (it is wider than the numbers).
        var lines = ["     " + padded("ID", to: idWidth) + " " + padded(L(.cliType), to: kindWidth) + " " + L(.cliWindowCountHeading)]
        let numbers = SpaceObserver.desktopNumbers(overview.spaces.map { ($0.spaceID, $0.type) })
        // A heading per display only when there are several (`--display` takes its number).
        let grouped = Set(overview.spaces.compactMap(\.display)).count > 1
        for (offset, e) in overview.spaces.enumerated() {
            if grouped, offset == 0 || overview.spaces[offset - 1].display != e.display {
                let name = e.displayName ?? L(.cliUnknownDisplay)
                lines.append(e.displayIndex.map { L(.cliDisplay(String($0), name)) } ?? name)
            }
            let number = e.desktopIndex ?? numbers[e.spaceID]
            let label = number.map { "\($0)." } ?? " —"
            let count = e.type == 0 ? String(e.windowIDs.count) : "—"
            let mark = e.isCurrent ? "*" : " "
            let type = Self.spaceKindLabel(e.type)
            lines.append("\(mark) \(label) \(padded(String(e.spaceID), to: idWidth)) \(padded(type, to: kindWidth)) \(count)")
        }
        if !overview.unknown.isEmpty { lines.append(L(.cliWindowsInAnUnknownSpace(overview.unknown.count))) }
        lines.append(L(.cliCurrentSpaceOnlyOrdinaryDesktops))
        if grouped { lines.append(L(.cliForADesktopOfAnother)) }
        if overview.reordersByRecentUse {
            lines.append(L(.cliNoteMissionControlsAutomaticallyRearrange))
        }
        return lines.joined(separator: "\n")
    }

    /// Space kind for the Space list, without OS numbers or English abbreviations.
    static func spaceKindLabel(_ type: Int32?) -> String {
        switch type {
        case 0: return L(.cliStandard)
        case 4: return L(.cliFullScreen)
        default: return L(.cliOther)
        }
    }

    static func resultText(_ r: OperationResult, name: (String) -> String = AppNames.localized) -> String {
        let title = ReadyWindowController.outcomeTitle(r)
        let body = ReadyWindowController.resultBody(r, name: name)
        return body.isEmpty ? title : title + "\n" + body
    }

    static func sizeText(_ f: CGRect) -> String { "\(Int(f.width))×\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY))" }
}
