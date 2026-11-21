import CoreGraphics
import XCTest
import Settings
@testable import LazySpaceApp

/// When the shortcut list opens: the decision alone, without the panel.
final class CheatsheetHoldTests: XCTestCase {
    private let main = Config.mainModeName
    private var defaults: [HotkeyBinding] { HotkeyBinding.from(Config(), mode: Config.mainModeName) }

    private func held(_ flags: CGEventFlags) -> UInt32 { CheatsheetHold.carbonModifiers(flags) }

    func testTheDefaultsOpenForExactlyTheirModifierSets() {
        for flags: CGEventFlags in [[.maskAlternate], [.maskAlternate, .maskShift], [.maskAlternate, .maskControl], [.maskAlternate, .maskCommand]] {
            XCTAssertTrue(CheatsheetHold.applies(held: held(flags), mode: main, bindings: defaults), "\(flags)")
        }
    }

    func testModifiersNoShortcutUsesDoNotOpenIt() {
        for flags: CGEventFlags in [[.maskCommand], [.maskShift], [.maskControl], [.maskCommand, .maskShift], [.maskAlternate, .maskShift, .maskCommand], []] {
            XCTAssertFalse(CheatsheetHold.applies(held: held(flags), mode: main, bindings: defaults), "\(flags)")
        }
    }

    func testACustomShortcutOpensItForItsOwnSet() throws {
        let config = try Config.load(toml: """
        [keys]
        arrange = "cmd-shift-a"
        """)
        let bindings = HotkeyBinding.from(config, mode: main)
        XCTAssertTrue(CheatsheetHold.applies(held: held([.maskCommand, .maskShift]), mode: main, bindings: bindings))
        XCTAssertFalse(CheatsheetHold.applies(held: held([.maskCommand]), mode: main, bindings: bindings))
    }

    /// A mode's keys may have no modifier at all, so any held modifier opens its list, as before.
    func testAnotherModeOpensForAnyModifier() throws {
        let config = try Config.load(toml: """
        [mode.resize.keys]
        focus-left = "h"
        """)
        let bindings = HotkeyBinding.from(config, mode: "resize")
        XCTAssertTrue(CheatsheetHold.applies(held: held([.maskCommand]), mode: "resize", bindings: bindings))
        XCTAssertFalse(CheatsheetHold.applies(held: 0, mode: "resize", bindings: bindings), "no modifier held")
    }

    func testOtherInputDuringTheWaitCancelsIt() {
        var hold = CheatsheetHold()
        XCTAssertEqual(hold.modifiersChanged(to: held([.maskShift, .maskAlternate]), inputCount: 7, mode: main, bindings: defaults), .wait)
        XCTAssertTrue(hold.showsAfterWait(inputCount: 7, mode: main, bindings: defaults), "nothing else was pressed")
        XCTAssertFalse(hold.showsAfterWait(inputCount: 8, mode: main, bindings: defaults), "a key, click, drag, or scroll came in the wait")
    }

    func testTheRuleIsCheckedAgainWhenTheWaitEnds() {
        var hold = CheatsheetHold()
        XCTAssertEqual(hold.modifiersChanged(to: held([.maskAlternate]), inputCount: 3, mode: main, bindings: defaults), .wait)
        XCTAssertFalse(hold.showsAfterWait(inputCount: 3, mode: main, bindings: []), "the shortcuts changed meanwhile")
    }

    /// Going from a set that opens it to one that does not hides a visible list at once, and releasing every modifier does too.
    func testAChangeToASetThatDoesNotOpenItHides() {
        var hold = CheatsheetHold()
        XCTAssertEqual(hold.modifiersChanged(to: held([.maskAlternate]), inputCount: 1, mode: main, bindings: defaults), .wait)
        XCTAssertEqual(hold.modifiersChanged(to: held([.maskAlternate, .maskShift, .maskCommand]), inputCount: 1, mode: main, bindings: defaults), .hide)
        XCTAssertEqual(hold.modifiersChanged(to: 0, inputCount: 1, mode: main, bindings: defaults), .hide)
        XCTAssertFalse(hold.showsAfterWait(inputCount: 1, mode: main, bindings: defaults), "the last change does not open it")
    }
}
