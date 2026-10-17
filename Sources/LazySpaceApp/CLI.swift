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

    static var usage: String { L(usageEnglish, usageJapanese) }

    private static let commandNames: Set<String> = [
        "help", "version", "status", "show", "settings", "pause", "resume", "quit", "reload",
        "arrange", "integrate", "list-windows", "list-spaces", "focus", "swap", "move", "join",
        "resize", "float", "zoom", "fullscreen", "minimize", "toggle-split", "accordion", "balance", "undo", "close",
        "space", "move-to-space", "mode", "login-item", "wait-settled", "result", "request-token"
    ]

    private static let usageEnglish = """
    Usage: lazyspace <command> [arguments] [--json]

    Status (does not move windows)
      status                       Availability, mode, and the latest result
      list-windows                 Windows in the current Space and whether each is eligible or excluded
      list-spaces                  Spaces and the number of windows in each
      show                         Open the window list
      settings                     Open Settings directly

    Arrangement
      arrange                      Arrange the current Space (starts tiling it when automatic arrangement is available)
      integrate                    Add one waiting window to the layout
      pause                        Pause all Spaces
      resume                       Resume all Spaces (resuming does not move windows by itself)

    Layout editing (acts on the focused window; <direction> is left, down, up, or right)
      focus <direction>            Move focus to the neighboring window
      focus back                   Focus the previously focused window
      swap <direction>             Swap with the neighboring window
      move <direction>             Move within the layout
      join <direction>             Group with the neighboring window in a nested split
      resize <axis> [amount]       <axis> is width, height, or smart; [amount] is a ratio such as +0.05 or -0.05 (default +0.05)
      balance                      Balance layout ratios
      toggle-split                 Toggle split orientation
      accordion                    Toggle accordion layout
      float on|off                 Set floating state
      zoom on|off                  Set zoom state (fill the current work area)
      undo                         Undo the last layout change
      close                        Close the focused window (like ⌘W)
      fullscreen on|off            Set macOS full screen
      minimize on|off              Set minimized state

    Spaces (direct when the target Space has a window LazySpace knows; otherwise one Space at a time using the Mission Control shortcuts already set in System Settings, which are not changed, and stepping sends nothing if a shortcut is off; numbers count only ordinary desktops in list-spaces)
      space <number>               Switch to a numbered desktop (1–99)
      space next, space prev       Switch to the next or previous Space
      space back                   Switch to the Space you were on before
      move-to-space <number>       Send the focused window to a Space; stay on the current Space
      move-to-space next, move-to-space prev
                                   Send the focused window to the next or previous desktop without switching
      move-to-space <number> --follow
                                   Move the focused window and switch to its Space
                                   Sending without following needs the direct move; refused otherwise
      space <number> --display <n>, move-to-space <number> --display <n>
                                   A desktop of another display; n is the display's number in list-spaces

    Settings
      mode                         Show the current binding mode
      mode <name>                  Switch to a declared binding mode (main returns to the main mode)
      reload                       Request a configuration reload (changes to the file are also reloaded automatically; windows are not moved)
      login-item                   Show whether LazySpace opens at login
      login-item on, login-item off
                                   Turn opening at login on or off

    Other
      wait-settled [seconds]       Wait for fresh, stable current-Space observation (default 5; maximum 120)
      request-token                Reserve a mutation request ID (no window, layout, focus, or settings change)
      result <id>                  Retrieve a receipt or an operation (receipt tokens do not fall through)
      version                      Print the version
      help                         Print this help
      quit                         Quit LazySpace

    Explicit targets
      --window-id <id> --expect-space-id <id> [--expect-pid <pid>]
      Available on window editing commands. Without --window-id, the focused window is used.
      focus --window-id <id> --expect-space-id <id> focuses that window directly.
      --expect-space-id is also available on arrange, integrate, balance, undo, and space.
      --request-id <token> is accepted only by arrange, integrate, and window or Space edits.
      The CLI reserves a token when --request-id is omitted, sends the mutation once, and prints that token on failure.
      Resending the same token returns its outcome and does not dispatch again. A new attempt needs a new token.
      Busy and other refusals stay attached to that token. Keep the token yourself if this process may exit before printing it.
      request-token does not write a token to the configuration file. Restarting LazySpace makes old tokens unusable.
      Move-to-space requires the target to be in front. No implicit focus or Space changes.
      wait-settled covers this Space's observed geometry and LazySpace work, not future app activity.

    JSON output
      --json includes schemaVersion 2 and a machine-readable code on every error. Unknown arguments are rejected.
      A finished mutation has code finished; read ok and result.outcome to see whether it succeeded.
      result.id and operationID are the operation. requestID is the receipt. They are not interchangeable.
      help and version print text; they do not accept --json.
      Scripts should read the structured fields rather than the human-readable messages, which follow the display language.

    Exit codes
      0  Succeeded or completed
      1  Refused, partially applied, interrupted, or failed
      2  Communication with LazySpace failed
      With exit 2, code control-unavailable means the app instance lock is held but CLI communication failed.

    Run the CLI as the same logged-in user, without sudo. LAZYSPACE_SUPPORT must match the app.

    Configuration: ~/.config/lazyspace/config.toml
    """

    private static let usageJapanese = """
    使い方: lazyspace <コマンド> [引数] [--json]

    状態（ウインドウは動かさない）
      status                       利用可否・モード・直近の結果
      list-windows                 現在の操作スペースのウインドウと、整列対象か対象外か、その理由
      list-spaces                  操作スペースの一覧と各操作スペースのウインドウ数
      show                         ウインドウ一覧を開く
      settings                     設定を直接開く

    整列
      arrange                      現在の操作スペースを整列（自動整列を利用できるときは、この操作スペースの自動管理を開始）
      integrate                    待機中のウインドウを1つレイアウトに追加
      pause                        すべての操作スペースを一時停止
      resume                       すべての操作スペースを再開（再開そのものではウインドウを動かさない）

    レイアウト編集（フォーカス中のウインドウが対象。<方向>はleft / down / up / right）
      focus <方向>                 隣のウインドウへフォーカス
      focus back                   直前にフォーカスしていたウインドウへ
      swap <方向>                  隣のウインドウと交換
      move <方向>                  レイアウト内で移動
      join <方向>                  隣のウインドウと入れ子の分割でグループ化
      resize <軸> [量]             <軸>はwidth / height / smart、[量]は+0.05や-0.05のような比率（初期値+0.05）
      balance                      レイアウトの割合を均等にする
      toggle-split                 分割方向を切り替え
      accordion                    アコーディオン表示を切り替え
      float on|off                 フローティング状態を指定
      zoom on|off                  ズーム状態を指定（現在の作業領域いっぱいに表示）
      undo                         直前のレイアウト変更を取り消す
      close                        フォーカス中のウインドウを閉じる（⌘W相当）
      fullscreen on|off            macOSのフルスクリーン状態を指定
      minimize on|off              最小化状態を指定

    操作スペース（移動先のウインドウやアプリを前面にできれば直接。できなければ近くの操作スペースまで直接移り、残りをシステム設定のMission Controlショートカットで1つずつ移動し、設定は変えない。オフなら1つずつの移動は送らない。番号はlist-spacesの通常デスクトップだけを数える）
      space <番号>                 番号のデスクトップへ切り替え（1〜99）
      space next / space prev      次 / 前の操作スペースへ移動
      space back                   直前にいた操作スペースへ移動
      move-to-space <番号>         ウインドウだけを操作スペースへ送り、今の操作スペースに留まる
      move-to-space next / move-to-space prev
                                   ウインドウだけを次 / 前のデスクトップへ送る
      move-to-space <番号> --follow
                                   ウインドウを移動し、その操作スペースに切り替える
                                   切り替えずに送るには直接移動が必要。使えなければ拒否
      space <番号> --display <n>、move-to-space <番号> --display <n>
                                   別のディスプレイのデスクトップ。nはlist-spacesでのディスプレイの番号

    設定
      mode                         現在のバインディングモードを表示
      mode <名前>                  宣言したバインディングモードに切り替え（mainでmainモードに戻る）
      reload                       設定の再読み込みを要求（ファイルの変更は自動でも再読み込みする。ウインドウは動かさない）
      login-item                   ログイン時に開くかを表示
      login-item on / login-item off
                                   「ログイン時に開く」をオン / オフ

    その他
      wait-settled [秒]            現在の操作スペースを再観測し、安定を待つ（初期値5秒、最大120秒）
      request-token                変更要求のIDを予約する（ウインドウ・配置・フォーカス・設定は変えない）
      result <ID>                  予約IDまたは操作IDの結果を取得（予約IDは通常の結果へフォールバックしない）
      version                      版を表示
      help                         このヘルプを表示
      quit                         LazySpaceを終了

    対象の明示
      --window-id <ID> --expect-space-id <ID> [--expect-pid <PID>]
      ウインドウ編集で利用できます。window-idを省略するとフォーカス中のウインドウが対象です。
      focus --window-id <ID> --expect-space-id <ID>は指定したウインドウへ直接フォーカスします。
      expect-space-idはarrange / integrate / balance / undo / spaceでも利用できます。
      --request-id <トークン>はarrange、integrate、ウインドウ編集、操作スペース編集だけが受け付けます。
      省略するとCLIが予約してから変更を1回送り、失敗時もそのトークンを出します。
      同じトークンの再送は結果を返すだけで、操作はもう始まりません。やり直すときは新しいトークンが必要です。
      処理中や拒否もそのトークンに残ります。プロセスが終了する前にトークンを手元に残してください。
      request-tokenは設定ファイルへトークンを書きません。アプリを再起動すると古いトークンは使えません。
      move-to-spaceは対象が前面の場合のみ。暗黙のフォーカス・操作スペース移動は行いません。
      wait-settledは現在の操作スペースの観測とLazySpaceの処理が対象です。将来のアプリ動作は保証しません。

    JSON出力
      --jsonはschemaVersion 2と、すべてのエラーのcodeを含みます。不明な引数は拒否します。
      完了はcode finishedです。成功かどうかはokとresult.outcomeを見てください。
      result.idとoperationIDは操作、requestIDは予約です。互いに置き換えられません。
      helpとversionは文字で出力し、--jsonは受け付けません。
      スクリプトでは、表示言語に従う人向けのメッセージではなく、構造化されたフィールドを読んでください。

    終了コード
      0  成功・完了
      1  拒否・一部未適用・中断・失敗
      2  LazySpaceとの通信に失敗
      終了コード2のcontrol-unavailableは、アプリの起動ロックが保持されているがCLI通信に失敗したことを示します。

    CLIはアプリと同じログインユーザーで実行してください（sudo不可）。LAZYSPACE_SUPPORTはアプリと一致させてください。

    設定: ~/.config/lazyspace/config.toml
    """

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
            if invocation.view == "spaces" { return res.spaces.map(spacesText) ?? L("Could not get the list of Spaces. This version of macOS does not report which Space a window belongs to.", "操作スペースの一覧を取得できません（このmacOSではウインドウの所属を確認できません）。") }
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
            return res.message.isEmpty ? (res.ok ? "OK" : L("Failed", "失敗")) : res.message
        }
    }

    /// The "This Space" line, from the configuration, global pause, automatic availability, this Space's pause, and whether it started.
    static func currentSpaceText(_ s: AppStatus) -> String {
        if !s.trusted || s.availability == .needsSetup { return L("Setup Required", "初期設定が必要") }
        if s.paused { return L("Paused Globally", "すべての操作スペースで一時停止中") }
        if !s.autoAvailable { return L("Manual Arrangement Only", "手動整列のみ") }
        if s.currentSpaceAutoPaused { return L("Automatic Arrangement Off in This Space", "この操作スペースの自動整列はオフ") }
        return s.currentSpaceManaged ? L("Automatic Arrangement Active", "自動整列中") : L("Waiting to Start", "開始待ち")
    }

    static func automaticArrangementText(_ s: AppStatus) -> String {
        s.autoAvailable ? L("Available", "利用可能") : L("Unavailable", "利用不可") + " — " + s.autoReason
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
            row(L("Activity", "処理"), s.idle ? L("Idle", "待機中") : L("Operations or mouse interactions in progress", "操作またはマウス操作の途中")),
            row(L("Status", "状態"), StatusMenuCopy.availabilityTitle(s)),
            row(L("This Space", "この操作スペース"), currentSpaceText(s)),
            row(AccessPane.name(), s.trusted ? L("Granted", "許可済み") : L("Not Granted", "未許可")),
            row(L("Manual arrangement", "手動整列"), s.manualAvailable ? L("Available", "利用可能") : L("Unavailable", "利用不可") + " — " + s.manualReason),
            row(L("Automatic arrangement", "自動整列"), automaticArrangementText(s)),
            row(L("Mode", "モード"), s.mode + (s.modes.count > 1 ? L(" (available modes: \(s.modes.joined(separator: ", ")))", "（使えるモード: \(s.modes.joined(separator: ", "))）") : "")),
            row(MacItem.openAtLogin, s.loginItem),
            StatusMenuCopy.occupancyLine(waiting: s.waiting.count, floatingCount: s.floating.count, zoomed: s.zoomed != nil),
            row(L("Configuration", "設定"), s.configPath) + (s.configError.map { "\n  " + L("Error: ", "誤り: ") + indented($0) } ?? "") + s.configNotes.map { "\n  " + L("Note: ", "注記: ") + indented($0) }.joined(),
        ]
        lines.append(row(L("Fixed-size windows", "大きさが固定のウインドウ"), s.dialogRegion))
        if let desktop = s.desktopShortcuts { lines.append(row(L("Desktop shortcuts", "デスクトップのショートカット"), desktop)) }
        if let left = s.leftShortcut { lines.append(row(MacItem.moveSpace(right: false), left)) }
        if let right = s.rightShortcut { lines.append(row(MacItem.moveSpace(right: true), right)) }
        if let freshness = s.dockShortcutFreshness { lines.append(row(L("Shortcut preferences", "ショートカットの設定"), freshness)) }
        if s.progress != .idle { lines.append(row(L("In progress", "処理中"), s.progressText)) }
        if let refusal = s.lastRefusal { lines.append(row(L("Latest notice", "直近の通知"), refusal)) }
        if let update = s.availableUpdate { lines.append(row(UpdateCopy.statusRow, UpdateCopy.available(update))) }
        if let r = s.lastResult, StatusMenuCopy.showsRecent(result: r, managed: s.currentSpaceManaged) {
            let title = ReadyWindowController.outcomeTitle(r)
            let body = ReadyWindowController.resultBody(r, name: AppNames.localized)
            let text = body.isEmpty ? title : title + "\n" + body
            lines.append(row(L("Latest operation", "直近の操作"), indented(text)))
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
        row("ID", L("App", "アプリ"), L("Size and Position", "現在の位置・サイズ"), ReadyWindowController.verdictColumnTitle)
        for t in ins.targets { row(t.id.description, ReadyWindowController.shownApp(t.app, name: name), sizeText(t.frame), ReadyWindowController.eligibleVerdict) }
        for e in ins.excluded { row(e.window.id.description, ReadyWindowController.shownApp(e.window.app, name: name), sizeText(e.window.frame), ReadyWindowController.exclusionText(e)) }
        for a in ins.snapshot.unobservedApps { row("-", ReadyWindowController.shownApp(a, name: name), "?", L("No Response: could not read this app's windows before the timeout", "応答なし: 期限内にウインドウの一覧を読めませんでした")) }
        if ins.targets.isEmpty && ins.excluded.isEmpty { lines.append(ins.snapshot.trusted ? L("(No windows)", "（ウインドウがありません）") : L("(Cannot read windows without the \(AccessPane.name()) permission)", "（「\(AccessPane.name())」の許可がないため読めません）")) }
        let unobserved = ins.snapshot.unobservedApps.count
        lines.append(L("Eligible \(ins.targets.count) / Excluded \(ins.excluded.count)", "整列対象\(ins.targets.count) / 対象外\(ins.excluded.count)")
                     + (unobserved == 0 ? "" : L(" / No response \(unobserved)", " / 応答なし\(unobserved)")))
        return lines.joined(separator: "\n")
    }

    static func spacesText(_ overview: SpaceOverview) -> String {
        let idWidth = 8
        let kindWidth = 14
        // The last column's heading is not cut (it is wider than the numbers).
        var lines = ["     " + padded("ID", to: idWidth) + " " + padded(L("Type", "種類"), to: kindWidth) + " " + L("Windows", "ウインドウ数")]
        let numbers = SpaceObserver.desktopNumbers(overview.spaces.map { ($0.spaceID, $0.type) })
        // A heading per display only when there are several (`--display` takes its number).
        let grouped = Set(overview.spaces.compactMap(\.display)).count > 1
        for (offset, e) in overview.spaces.enumerated() {
            if grouped, offset == 0 || overview.spaces[offset - 1].display != e.display {
                let name = e.displayName ?? L("Unknown display", "不明なディスプレイ")
                lines.append(e.displayIndex.map { L("Display \($0): \(name)", "ディスプレイ\($0): \(name)") } ?? name)
            }
            let number = e.desktopIndex ?? numbers[e.spaceID]
            let label = number.map { "\($0)." } ?? " —"
            let count = e.type == 0 ? String(e.windowIDs.count) : "—"
            let mark = e.isCurrent ? "*" : " "
            let type = Self.spaceKindLabel(e.type)
            lines.append("\(mark) \(label) \(padded(String(e.spaceID), to: idWidth)) \(padded(type, to: kindWidth)) \(count)")
        }
        if !overview.unknown.isEmpty { lines.append(L("Windows in an unknown Space: \(overview.unknown.count)", "所属が分からないウインドウ: \(overview.unknown.count)")) }
        lines.append(L("* = current Space. Only ordinary desktops are numbered, in macOS order on each display. Full-screen / Split View spaces are unnumbered.", "* = 現在の操作スペース。通常のデスクトップだけをディスプレイごとにmacOSの並び順で数えます。フルスクリーン・Split Viewに番号は付きません。"))
        if grouped { lines.append(L("For a desktop of another display, add --display with the display's number.", "別のディスプレイのデスクトップには、--displayにディスプレイの番号を付けて指定します。")) }
        if overview.reordersByRecentUse {
            lines.append(L("Note: Mission Control’s “Automatically rearrange Spaces based on most recent use” is on. The order changes as you switch, so space numbers are not stable. Turning it off is recommended.", "注意: Mission Controlの「最新の使用状況に基づいて操作スペースを自動的に並べ替える」がオンです。切り替えのたびに並びが変わるため、デスクトップの番号は安定しません。オフを推奨します。"))
        }
        return lines.joined(separator: "\n")
    }

    /// Space kind for the Space list, without OS numbers or English abbreviations.
    static func spaceKindLabel(_ type: Int32?) -> String {
        switch type {
        case 0: return L("Standard", "通常")
        case 4: return L("Full Screen", "フルスクリーン")
        default: return L("Other", "その他")
        }
    }

    static func resultText(_ r: OperationResult, name: (String) -> String = AppNames.localized) -> String {
        let title = ReadyWindowController.outcomeTitle(r)
        let body = ReadyWindowController.resultBody(r, name: name)
        return body.isEmpty ? title : title + "\n" + body
    }

    static func sizeText(_ f: CGRect) -> String { "\(Int(f.width))×\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY))" }
}
