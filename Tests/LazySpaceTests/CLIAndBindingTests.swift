import Foundation
import XCTest
import LayoutCore
import Settings
import Operations
import MacSupport
@testable import LazySpaceApp

final class HotkeyBindingTests: XCTestCase {
    func testBindingsFollowModes() throws {
        let c = try Config.load(toml: """
        [keys]
        focus-left = "alt-h"
        mode-service = "alt-shift-semicolon"
        arrange = "none"
        [mode.service.keys]
        mode-main = "esc"
        arrange = "r"
        reload = "alt-r"
        integrate = "i"
        pause-resume = "p"
        """)
        let main = HotkeyBinding.from(c)
        XCTAssertTrue(main.contains { $0.action == .edit(.focus(.left)) })
        XCTAssertTrue(main.contains { $0.action == .mode("service") && $0.display == "⌥⇧;" })
        XCTAssertFalse(main.contains { $0.action == .arrange }, "defaults removed with none are not registered")
        let service = HotkeyBinding.from(c, mode: "service")
        XCTAssertEqual(service.count, 5)
        XCTAssertTrue(service.contains { $0.action == .mode("main") && $0.modifiers == 0 && $0.keyCode == 53 })
        XCTAssertTrue(service.contains { $0.action == .arrange && $0.modifiers == 0 })
        XCTAssertTrue(service.contains { $0.action == .reload })
        XCTAssertTrue(service.contains { $0.action == .integrate })
        XCTAssertTrue(service.contains { $0.action == .pauseResume })
        XCTAssertEqual(HotkeyBinding.from(c, mode: "nope"), [])
        XCTAssertEqual(HotkeyBinding.action(forCommand: "resize-height-shrink"), .edit(.resize(.vertical, -0.05)))
        XCTAssertNil(HotkeyBinding.action(forCommand: "dance"))
    }

    func testNewCommands() throws {
        XCTAssertEqual(HotkeyBinding.action(forCommand: "resize-smart-grow"), .edit(.resizeSmart(0.05)))
        XCTAssertEqual(HotkeyBinding.action(forCommand: "resize-smart-shrink"), .edit(.resizeSmart(-0.05)))
        XCTAssertEqual(HotkeyBinding.action(forCommand: "balance"), .edit(.balance))
        XCTAssertEqual(HotkeyBinding.action(forCommand: "undo"), .edit(.undo))
        XCTAssertEqual(HotkeyBinding.action(forCommand: "close"), .edit(.close))
        XCTAssertEqual(HotkeyBinding.action(forCommand: "focus-back"), .edit(.focusBack))
        XCTAssertEqual(EditCommand.parse("resize-smart -0.1"), .resizeSmart(-0.1))
        XCTAssertNil(EditCommand.parse("resize-depth"))
        // Every default key parses; mode entries and unmodified plain keys are not registered.
        for name in Config.defaultKeys.keys { XCTAssertNotNil(HotkeyBinding.action(forCommand: name), name) }
        XCTAssertTrue(HotkeyBinding.from(Config(), mode: "service").isEmpty)
        XCTAssertFalse(HotkeyBinding.from(Config()).contains { $0.action == .mode("service") })
        XCTAssertFalse(HotkeyBinding.from(Config()).contains { $0.modifiers == 0 })
    }

    /// A registered shortcut's keyDown is recognized by the tap as the same combination (Caps Lock and similar flags ignored).
    func testCommandKeyMatchesTapEvent() throws {
        let c = try Config.load(toml: """
        [keys]
        swap-right = "alt-shift-l"
        """)
        let binding = try XCTUnwrap(HotkeyBinding.from(c).first { $0.action == .edit(.swap(.right)) })
        let registered = InputMonitor.CommandKey(keyCode: binding.keyCode, carbonModifiers: binding.modifiers)
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(binding.keyCode), keyDown: true))
        event.flags = [.maskAlternate, .maskShift, .maskAlphaShift, .maskNonCoalesced]
        XCTAssertEqual(InputMonitor.CommandKey(event: event), registered)
        event.flags = [.maskAlternate]
        XCTAssertNotEqual(InputMonitor.CommandKey(event: event), registered, "different modifiers make a different input")
    }
}

/// CLI flags and binding names select the same window-transfer behavior.
final class WindowTransferCommandTests: XCTestCase {
    private func invocation(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws -> CLI.Invocation {
        guard case .invocation(let value)? = CLI.parse(arguments) else {
            XCTFail("Invalid invocation: \(arguments)", file: file, line: line)
            throw NSError(domain: "WindowTransferCommandTests", code: 1)
        }
        return value
    }

    func testWindowOnlyIsDefaultAndFollowingMustBeExplicit() throws {
        for (text, target) in [("2", SpaceTarget.index(2)), ("next", .next), ("prev", .prev)] {
            let normal = try invocation(["move-to-space", text])
            let follow = try invocation(["move-to-space", text, "--follow"])
            XCTAssertEqual(normal.cmd, "edit.v3")
            XCTAssertEqual(normal.arg.flatMap(EditCommand.parse), .sendToSpace(target))
            XCTAssertEqual(follow.arg.flatMap(EditCommand.parse), .moveToSpace(target))
        }
        let target = try invocation(["move-to-space", "2", "--follow", "--window-id", "42", "--expect-space-id", "7", "--expect-pid", "101"])
        XCTAssertEqual(target.windowID, WindowID(42))
        XCTAssertEqual(target.expectedSpaceID, 7)
        XCTAssertEqual(target.expectedPID, 101)
    }

    func testFollowFlagsCannotBeIgnoredOrCombined() {
        for arguments in [["space", "2", "--follow"], ["status", "--follow"],
                          ["move-to-space", "2", "--follow", "--follow"],
                          ["move-to-space", "back", "--follow"]] {
            guard case .error? = CLI.parse(arguments) else { XCTFail("accepted \(arguments)"); continue }
        }
        XCTAssertNil(EditCommand.parse("move-to-space-follow-back"))
        XCTAssertNil(EditCommand.parse("move-to-space-follow-0"))
    }

    func testDefaultKeysSendAndOptionalFollowingDoesNotAddDuplicateRows() throws {
        let defaults = HotkeyBinding.from(Config())
        for n in 1...9 {
            let key = try XCTUnwrap(Config.defaultKeys["move-to-space-\(n)"])
            let binding = try XCTUnwrap(defaults.first { $0.keyCode == key.keyCode && $0.modifiers == key.carbonModifiers })
            XCTAssertEqual(binding.command, .sendToSpace(.index(n)))
        }
        let custom = try Config.load(toml: """
        [keys]
        move-to-space-follow-3 = "alt-ctrl-3"
        move-to-space-follow-next = "alt-ctrl-right"
        """)
        let bindings = HotkeyBinding.from(custom)
        XCTAssertTrue(bindings.contains { $0.command == .moveToSpace(.index(3)) })
        XCTAssertTrue(bindings.contains { $0.command == .moveToSpace(.next) })
        for name in ["move-to-space-follow-3", "move-to-space-follow-next"] {
            XCTAssertNil(Config.defaultKeys[name])
            XCTAssertFalse(ShortcutList.shows(name, saved: [:], draft: [:]))
            XCTAssertEqual(ShortcutList.sectionID(for: name), .spaces)
        }
        let commands = Config.commandNames.map { ($0, HotkeyBinding.action(forCommand: $0).map { "\($0)" } ?? $0) }
        let rows = ShortcutList.rows(commands: commands, saved: custom.keys, draft: custom.keys, search: "")
        XCTAssertTrue(rows.compactMap(\.commandName).contains("move-to-space-follow-3"))
        XCTAssertTrue(rows.compactMap(\.commandName).contains("move-to-space-follow-next"))
        XCTAssertFalse(rows.compactMap(\.commandName).contains("move-to-space-follow-2"))
    }
}

final class CLIParseTests: XCTestCase {
    private func inv(_ args: [String]) -> CLI.Invocation? {
        if case .invocation(let i)? = CLI.parse(args) { return i }
        return nil
    }

    func testRetiredNameSyntaxIsRejected() {
        for args in [["space-name", "set", "2", "web"], ["space-name", "list"],
                     ["space-name", "clear", "web"], ["space", "web"], ["space", "name:web"],
                     ["move-to-space", "web"], ["move-to-space", "web", "--no-follow"]] {
            if case .invocation = CLI.parse(args) { XCTFail("accepted retired command: \(args)") }
        }
        for text in ["space-name:web", "move-to-space-name:web", "space-web"] {
            XCTAssertNil(EditCommand.parse(text), text)
        }
    }

    func testSpaceAndWindowStateCommands() throws {
        XCTAssertEqual(EditCommand.parse("space-3"), .space(.index(3)))
        XCTAssertEqual(EditCommand.parse("space-next"), .space(.next))
        XCTAssertEqual(EditCommand.parse("space-back"), .space(.back))
        XCTAssertEqual(EditCommand.parse("move-to-space-2"), .sendToSpace(.index(2)))
        XCTAssertEqual(EditCommand.parse("move-to-space-prev"), .sendToSpace(.prev))
        XCTAssertNil(EditCommand.parse("move-to-space-back"), "sending a window has no back destination")
        XCTAssertNil(EditCommand.parse("space-0"))
        XCTAssertEqual(EditCommand.parse("fullscreen"), .fullscreen)
        XCTAssertEqual(EditCommand.parse("minimize"), .minimize)

        XCTAssertEqual(inv(["space", "next"]), CLI.Invocation(cmd: "edit.v3", arg: "space-next"))
        XCTAssertEqual(inv(["space", "4"]), CLI.Invocation(cmd: "edit.v3", arg: "space-4"))
        XCTAssertEqual(inv(["move-to-space", "2"]), CLI.Invocation(cmd: "edit.v3", arg: "move-to-space-2"))
        XCTAssertEqual(inv(["fullscreen", "on"])?.desiredState, true)
        if case .error = CLI.parse(["move-to-space", "back"]) {} else { XCTFail("move-to-space back is an error") }
        if case .error = CLI.parse(["space"]) {} else { XCTFail("space needs a target") }

        // Assigned to a key in the configuration, it becomes a binding.
        let c = try Config.load(toml: """
        [keys]
        space-1 = "alt-1"
        move-to-space-next = "alt-shift-tab"
        fullscreen = "alt-shift-f"
        """)
        let main = HotkeyBinding.from(c)
        XCTAssertTrue(main.contains { $0.action == .edit(.space(.index(1))) })
        XCTAssertTrue(main.contains { $0.action == .edit(.sendToSpace(.next)) })
        XCTAssertTrue(main.contains { $0.action == .edit(.fullscreen) })
        XCTAssertTrue(Config.commandNames.contains("space-9"))
        XCTAssertFalse(Config.commandNames.contains("space-10"), "setting names go up to 9 (the CLI up to 99)")
    }

    func testAppLaunchArgumentsAreNotCLI() {
        XCTAssertNil(CLI.parse([]))
        XCTAssertNil(CLI.parse(["--ready"]))
    }

    func testHelpAndVersion() {
        XCTAssertEqual(CLI.parse(["help"]), .help)
        XCTAssertEqual(CLI.parse(["--help"]), .help)
        XCTAssertEqual(CLI.parse(["version"]), .version)
        XCTAssertEqual(CLI.parse(["--version"]), .version)
    }

    func testStrictSubcommands() {
        XCTAssertEqual(inv(["status"])?.cmd, "status")

        XCTAssertEqual(inv(["focus", "left"]), CLI.Invocation(cmd: "edit.v3", arg: "focus-left"))

        XCTAssertEqual(inv(["swap", "right"])?.arg, "swap-right")
        XCTAssertEqual(inv(["move", "down"])?.arg, "move-down")
        XCTAssertEqual(inv(["join", "up"])?.arg, "join-up")
        XCTAssertEqual(inv(["resize", "width", "+0.1"])?.arg, "resize-width +0.1")
        XCTAssertEqual(inv(["resize", "height"])?.arg, "resize-height 0.05")
        XCTAssertEqual(inv(["toggle-split"])?.arg, "toggle-split")
        XCTAssertEqual(inv(["float", "on"])?.arg, "float")
        XCTAssertEqual(inv(["zoom", "off"])?.arg, "zoom")
        XCTAssertEqual(inv(["focus", "back"])?.arg, "focus-back")
        XCTAssertEqual(inv(["resize", "smart", "-0.05"])?.arg, "resize-smart -0.05")
        XCTAssertEqual(inv(["balance"])?.arg, "balance")
        XCTAssertEqual(inv(["undo"])?.arg, "undo")
        XCTAssertEqual(inv(["close"])?.arg, "close")
        for a in ["focus-back", "resize-smart -0.05", "balance", "undo", "close"] { XCTAssertNotNil(EditCommand.parse(a), a) }
        XCTAssertEqual(inv(["list-windows"]), CLI.Invocation(cmd: "inspect", arg: nil, json: false, view: "windows"))
        XCTAssertEqual(inv(["list-spaces"])?.view, "spaces")

        XCTAssertEqual(inv(["mode"]), CLI.Invocation(cmd: "mode", arg: nil))
        XCTAssertEqual(inv(["mode", "service"])?.arg, "service")
        XCTAssertEqual(inv(["login-item", "on"])?.arg, "on")



        XCTAssertEqual(inv(["arrange", "--json"])?.json, true)
        XCTAssertEqual(inv(["--json", "status"])?.json, true)
        XCTAssertTrue(inv(["arrange"])!.waitsForResult)
        XCTAssertFalse(inv(["status"])!.waitsForResult)
    }

    func testErrorsForBadArguments() {
        for args in [["focus"], ["focus", "sideways"], ["resize", "depth"], ["resize", "width", "wide"], ["login-item", "maybe"], ["dance"], ["--dance"], ["edit"]] {
            guard case .error? = CLI.parse(args) else { return XCTFail("\(args) should be an error") }
        }
    }

    func testRejectsIgnoredArgumentsAndAmbiguousStateChanges() {
        for args in [["status", "--all"], ["list-windows", "--all"], ["close", "extra"],
                     ["focus", "left", "extra"], ["float"], ["zoom"], ["fullscreen"],
                     ["wait-settled", "abc"], ["wait-settled", "nan"], ["wait-settled", "-1"],
                     ["status", "--json", "--json"], ["--edit", "close"], ["edit", "close"],
                     ["close", "--window-id", "1"], ["status", "--expect-space-id", "7"],
                     ["close", "--window-id", "4294967296", "--expect-space-id", "7"],
                     ["import-aerospace"], ["import-aerospace", "--write"], ["--import-aerospace"], ["status", "--write"], ["--help", "junk"], ["resize", "width", "2"]] {
            guard case .error? = CLI.parse(args) else { XCTFail("Accepted \(args)"); continue }
        }
        XCTAssertNil(EditCommand.parse("float on"))
        XCTAssertNil(EditCommand.parse("close junk"))
    }

    func testExplicitTargetAndDesiredStateArePreserved() throws {
        let request = try XCTUnwrap(inv(["zoom", "on", "--window-id", "42", "--expect-space-id", "7", "--expect-pid", "100", "--json"]))
        XCTAssertEqual(request.cmd, "edit.v3")
        XCTAssertEqual(request.windowID, WindowID(42))
        XCTAssertEqual(request.expectedSpaceID, 7)
        XCTAssertEqual(request.expectedPID, 100)
        XCTAssertEqual(request.desiredState, true)
        XCTAssertTrue(request.json)
        XCTAssertEqual(inv(["focus", "--window-id", "42", "--expect-space-id", "7"])?.cmd, "focus-window.v3")
        XCTAssertEqual(inv(["settings"])?.cmd, "settings")
    }

    func testSettledRequestCannotReuseEarlierStableTime() {
        let observation = ControlPort.Settlement(settled: true, spaceID: 7, observedAt: Date(), stableFor: 10, requiredStableFor: 1, blockers: [])
        XCTAssertFalse(CLI.settledForRequest(observation, elapsed: 0.2))
        XCTAssertTrue(CLI.settledForRequest(observation, elapsed: 1.1))
        XCTAssertNil(inv(["minimize", "off"]))
        XCTAssertNotNil(inv(["minimize", "off", "--window-id", "1", "--expect-space-id", "7"]))
        XCTAssertNil(EditCommand.parse("resize-width 50"))
        XCTAssertNil(EditCommand.parse("resize-width 0"))
        XCTAssertEqual(CLI.exitCode(.init(ok: true, message: "", code: "pending"), invocation: .init(cmd: "result")), 1)
        XCTAssertEqual(CLI.exitCode(.init(ok: true, message: "", code: "finished"), invocation: .init(cmd: "result")), 0)
    }

    func testResizeRejectsNonFiniteAndMalformedAmounts() {
        for value in ["nan", "inf", "-inf", "1e999", "wide"] {
            for axis in ["width", "height", "smart"] {
                XCTAssertNil(EditCommand.parse("resize-\(axis) \(value)"))
                guard case .error? = CLI.parse(["resize", axis, value]) else {
                    return XCTFail("Invalid resize amount accepted: \(value)")
                }
            }
        }
    }

    func testTextRenderingOfStatus() {
        var s = sampleStatus()
        s.mode = "service"
        s.modes = ["main", "service"]
        let text = CLI.statusText(s)
        XCTAssertTrue(text.contains(CLI.padded("Mode:", to: 24) + "service (available modes: main, service)"))
        XCTAssertTrue(text.contains("Manual Arrangement Only"))
        XCTAssertTrue(text.contains(CLI.padded("Open at Login:", to: 24) + "Off"))
        let json = CLI.render(ControlPort.Response(ok: true, message: "", status: s), invocation: CLI.Invocation(cmd: "status", json: true))
        XCTAssertTrue(json.contains("\"mode\" : \"service\""))
    }

    func testOperationResultMustMatchRequestedID() {
        var status = sampleStatus()
        let previous = OperationResult.note(id: "previous", kind: "arrange", spaceID: 7, message: "old success", ok: true)
        status.lastResult = previous
        let pending = ControlPort.Response(ok: true, message: "Working…", status: status)
        XCTAssertNil(CLI.completedResult(in: pending, operationID: "requested"))
        let mismatched = ControlPort.Response(ok: true, message: "", status: status, operationID: "requested", result: previous)
        XCTAssertNil(CLI.completedResult(in: mismatched, operationID: "requested"))
        let nestedOnly = ControlPort.Response(ok: true, message: "", status: status, operationID: "previous")
        XCTAssertNil(CLI.completedResult(in: nestedOnly, operationID: "previous"))
        let refused = ControlPort.Response(ok: false, message: "Another operation is in progress, so the request was not accepted.", status: status)
        XCTAssertFalse(CLI.render(refused, invocation: .init(cmd: "arrange.v3")).contains("old success"))
        let completed = ControlPort.Response(ok: true, message: "", status: status, operationID: "previous", result: previous)
        XCTAssertEqual(CLI.completedResult(in: completed, operationID: "previous")?.id, "previous")
        XCTAssertTrue(CLI.render(completed, invocation: .init(cmd: "arrange.v3")).contains("old success"))
        let wrongIdentity = ControlPort.Response(ok: true, message: "", operationID: "previous", result: OperationResult.note(id: "other", kind: "arrange", spaceID: 7, message: "other", ok: true))
        XCTAssertNil(CLI.completedResult(in: wrongIdentity, operationID: "previous"))
    }

    private func sampleStatus() -> AppStatus {
        AppStatus(availability: .manualOnly, availabilityReason: "Manual arrangement only", manualAvailable: true, manualReason: "Available", autoAvailable: false, autoReason: "Not checked",
                  currentSpaceManaged: false, trusted: true, spaceObservation: true, inputObservation: "none", paused: false, progress: .idle, progressText: "",
                  waiting: [], floating: [], zoomed: nil, lastRefusal: nil, configPath: "/tmp/config.toml", configError: nil,
                  focusedWindow: nil, lastResult: nil, version: "0.2.0", mode: "main", modes: ["main"], loginItem: "Off", loginItemEnabled: false)
    }
}
