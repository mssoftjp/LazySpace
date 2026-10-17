import XCTest
@testable import MacSupport

final class SpaceObserverTests: XCTestCase {
    func testManagedDisplayRecordsAndUniqueUUIDs() {
        let display = SpaceObserver.ManagedDisplay.parse([
            "Display Identifier": "Main",
            "Current Space": ["id64": NSNumber(value: 2)],
            "Spaces": [
                ["id64": NSNumber(value: 1), "type": NSNumber(value: 0), "uuid": "A"],
                ["id64": NSNumber(value: 2), "uuid": "B"],
                ["id64": NSNumber(value: 3), "type": NSNumber(value: 4), "uuid": ""],
                ["id64": NSNumber(value: 4), "type": NSNumber(value: 0), "uuid": "D"],
            ],
        ])
        XCTAssertEqual(display.spaces, [1, 2, 3, 4])
        XCTAssertEqual(display.records.map(\.type), [0, nil, 4, 0], "types stay with their Space")
        XCTAssertEqual(display.records.map(\.uuid), ["A", "B", nil, "D"])
        XCTAssertEqual(display.spaceTypes.count, 3, "an incomplete type list stays shorter, as before")
        XCTAssertEqual(display.currentSpace, 2)
        let other = SpaceObserver.ManagedDisplay(display: "Side", currentSpace: 5, records: [.init(id: 5, type: 0, uuid: "D"), .init(id: 6, type: 0, uuid: "F")])
        XCTAssertEqual(SpaceObserver.uniqueUUIDs([display, other]), [1: "A", 2: "B", 6: "F"], "missing and duplicated uuids cannot identify a destination")
        // JSON without the required records field is rejected.
        let old = try? JSONDecoder().decode(SpaceObserver.ManagedDisplay.self, from: Data(#"{"display":"x","spaces":[1,2],"spaceTypes":[0,4]}"#.utf8))
        XCTAssertNil(old)
    }

    /// While displays share one Space, a window counts as the current Space's only when centered on the menu-bar display,
    /// whether it was first seen in the window list or only through Accessibility (both use this).
    func testMembershipOnSharedSpacesFollowsTheWindowCenter() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let here = CGRect(x: 100, y: 100, width: 800, height: 600)
        let beside = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertEqual(MacWindowSystem.membership([7], active: 7, frame: beside, sharedDisplay: main), .otherDisplay)
        XCTAssertEqual(MacWindowSystem.membership([7], active: 7, frame: here, sharedDisplay: main), .current)
        XCTAssertEqual(MacWindowSystem.membership([7], active: 7, frame: beside, sharedDisplay: nil), .current, "separate Spaces")
        XCTAssertEqual(MacWindowSystem.membership([7, 8], active: 7, frame: beside, sharedDisplay: main), .allSpaces)
        XCTAssertEqual(MacWindowSystem.membership([8], active: 7, frame: here, sharedDisplay: main), .other)
        XCTAssertEqual(MacWindowSystem.membership([], active: 7, frame: here, sharedDisplay: main), .unknown)
    }
}
