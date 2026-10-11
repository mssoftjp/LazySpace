import XCTest
@testable import MacSupport

final class DisplayGroupsTests: XCTestCase {
    private func display(_ id: String, shown: UInt64?, _ spaces: [(UInt64, Int32?)]) -> SpaceObserver.ManagedDisplay {
        SpaceObserver.ManagedDisplay(display: id, currentSpace: shown, records: spaces.map { SpaceObserver.Space(id: $0.0, type: $0.1) })
    }

    func testOneDisplayHasNoGroups() {
        XCTAssertEqual(DisplayGroups.make([display("A", shown: 1, [(1, 0)])], names: ["A": "Built-in"]), [])
    }

    func testGroupsKeepSkyLightOrderNamesAndShownSpaces() {
        let groups = DisplayGroups.make([display("B", shown: 2, [(1, 0), (2, 0)]), display("A", shown: 3, [(3, 0), (4, 4), (5, 0)])],
                                        names: ["A": "LG HDR 4K", "B": "Built-in Retina Display"])
        XCTAssertEqual(groups.map(\.name), ["Built-in Retina Display", "LG HDR 4K"])
        XCTAssertEqual(groups.map(\.index), [1, 2])
        XCTAssertEqual(groups.map(\.shown), [2, 3])
        XCTAssertEqual(groups[1].desktops, [3, 5], "full-screen Spaces take no desktop number")
    }

    func testSameNamesGetANumberInDisplayOrder() {
        let groups = DisplayGroups.make([display("A", shown: 1, [(1, 0)]), display("B", shown: 2, [(2, 0)]), display("C", shown: 3, [(3, 0)])],
                                        names: ["A": "LG", "B": "Built-in", "C": "LG"])
        XCTAssertEqual(groups.map(\.name), ["LG (1)", "Built-in", "LG (2)"])
    }

    func testAnUnmatchedDisplayDropsAllGroups() {
        XCTAssertEqual(DisplayGroups.make([display("A", shown: 1, [(1, 0)]), display("B", shown: 2, [(2, 0)])], names: ["A": "LG"]), [],
                       "while a display is being connected, the list falls back to the current display")
    }
}
