import XCTest
@testable import MacSupport
import LayoutCore
import Operations

final class WindowCensusTests: XCTestCase {
    func testExistenceRequiresAValidListBeforeDeclaringAWindowGone() {
        XCTAssertTrue(WindowList.mayExist(99, in: nil))
        XCTAssertTrue(WindowList.mayExist(99, in: [99]))
        XCTAssertFalse(WindowList.mayExist(99, in: []))
        XCTAssertFalse(WindowList.mayExist(99, in: [100]))
    }

    /// A window fully faded while closing counts as gone even if still listed.
    func testFadedWindowsAreNotCounted() {
        XCTAssertTrue(WindowCensus.isVisible(alpha: 1))
        XCTAssertTrue(WindowCensus.isVisible(alpha: 0.7))
        XCTAssertTrue(WindowCensus.isVisible(alpha: WindowCensus.vanishingAlpha))
        XCTAssertFalse(WindowCensus.isVisible(alpha: 0.004))
        XCTAssertFalse(WindowCensus.isVisible(alpha: 0))
    }
}

/// The window-list readers look up only the fields they use on the entries macOS returns, without converting them. Results must match
/// readers that convert entries to `[[String: Any]]` (`Old` below), including missing and mistyped fields.
final class WindowListReaderTests: XCTestCase {
    private enum Old {
        static func census(_ raw: [[String: Any]]?, spaceID: UInt64?, me: pid_t, frontmostPID: pid_t?, isRegularApp: (pid_t) -> Bool) -> Census {
            var windows: [WindowID: Int32] = [:]
            var bounds: [WindowID: CGRect] = [:]
            var frontWindow: WindowID?
            if let raw {
                for d in raw {
                    guard let num = d[kCGWindowNumber as String] as? NSNumber,
                          let pidNum = d[kCGWindowOwnerPID as String] as? NSNumber,
                          (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                          WindowCensus.isVisible(alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) else { continue }
                    let pid = pidNum.int32Value
                    guard pid != me, isRegularApp(pid) else { continue }
                    var rect = CGRect.zero
                    if let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { rect = r }
                    if rect.width < 60 || rect.height < 40 { continue }
                    windows[WindowID(num.uint32Value)] = pid
                    bounds[WindowID(num.uint32Value)] = rect
                    if frontWindow == nil, pid == frontmostPID { frontWindow = WindowID(num.uint32Value) }
                }
            }
            return Census(windows: windows, frontmostPID: frontmostPID, spaceID: spaceID, bounds: bounds, frontWindow: frontWindow)
        }

        static func owners(_ raw: [[String: Any]]?) -> Set<pid_t> {
            guard let raw else { return [] }
            return Set(raw.compactMap { d in (d[kCGWindowLayer as String] as? Int) == 0 ? (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value : nil })
        }

        static func records(_ raw: [[String: Any]]?) -> [CGWindowID: CGWindowRecord]? {
            guard let raw else { return nil }
            var out: [CGWindowID: CGWindowRecord] = [:]
            for d in raw {
                guard let num = d[kCGWindowNumber as String] as? NSNumber,
                      let pid = d[kCGWindowOwnerPID as String] as? NSNumber else { continue }
                var bounds = CGRect.zero
                if let b = d[kCGWindowBounds as String] as? NSDictionary {
                    bounds = CGRect(dictionaryRepresentation: b) ?? .zero
                }
                out[num.uint32Value] = CGWindowRecord(
                    id: num.uint32Value, pid: pid.int32Value,
                    layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                    bounds: bounds,
                    alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                    onScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
            }
            return out
        }

        static func order(_ raw: [[String: Any]]?) -> [CGWindowID: Int] {
            guard let raw else { return [:] }
            var out: [CGWindowID: Int] = [:]
            var order = 0
            for d in raw {
                defer { order += 1 }
                guard let num = d[kCGWindowNumber as String] as? NSNumber else { continue }
                out[num.uint32Value] = order
            }
            return out
        }

        static func ids(_ raw: [[String: Any]]?) -> Set<CGWindowID>? {
            guard let raw else { return nil }
            var ids = Set<CGWindowID>()
            for entry in raw {
                if let num = entry[kCGWindowNumber as String] as? NSNumber { ids.insert(num.uint32Value) }
            }
            return ids
        }
    }

    private static func bounds(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSDictionary {
        CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation
    }

    private static func entry(_ fields: [CFString: Any]) -> NSDictionary {
        let d = NSMutableDictionary()
        for (key, value) in fields { d[key] = value }
        return d
    }

    private static let me: pid_t = 99
    private static let front: pid_t = 10

    /// Front to back. Includes missing fields, mistyped fields, fractional layers, faint windows, tiny windows, our own windows, non-regular apps, and duplicate numbers.
    private static let fixture: [NSDictionary] = [
        entry([kCGWindowNumber: 1, kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600), kCGWindowAlpha: 1, kCGWindowIsOnscreen: true]),
        entry([kCGWindowNumber: 2, kCGWindowOwnerPID: front, kCGWindowLayer: 0, kCGWindowBounds: bounds(10, 10, 500, 400)]),
        entry([kCGWindowNumber: 3, kCGWindowOwnerPID: front, kCGWindowLayer: 0, kCGWindowBounds: bounds(20, 20, 500, 400), kCGWindowAlpha: 0.7]),
        entry([kCGWindowNumber: 4, kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600), kCGWindowAlpha: 0.004]),
        entry([kCGWindowNumber: 5, kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 50, 600)]),
        entry([kCGWindowNumber: 6, kCGWindowOwnerPID: 20, kCGWindowLayer: 0]),
        entry([kCGWindowNumber: 7, kCGWindowOwnerPID: 20, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 8, kCGWindowOwnerPID: 20, kCGWindowLayer: 25, kCGWindowBounds: bounds(0, 0, 800, 25)]),
        entry([kCGWindowNumber: 9, kCGWindowOwnerPID: 21, kCGWindowLayer: 0.5, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 10, kCGWindowOwnerPID: me, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 11, kCGWindowOwnerPID: 30, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 12, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: "13", kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 14, kCGWindowOwnerPID: "20", kCGWindowLayer: "0", kCGWindowBounds: "bounds", kCGWindowAlpha: "1"]),
        entry([kCGWindowNumber: 15, kCGWindowOwnerPID: 20, kCGWindowLayer: 0, kCGWindowBounds: ["X": 0] as NSDictionary, kCGWindowIsOnscreen: 0]),
        entry([kCGWindowNumber: 1, kCGWindowOwnerPID: 22, kCGWindowLayer: 3, kCGWindowBounds: bounds(5, 5, 100, 100), kCGWindowAlpha: 0.5, kCGWindowIsOnscreen: false]),
        entry([kCGWindowNumber: 16, kCGWindowOwnerPID: 23, kCGWindowLayer: Int64(1) << 40, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([kCGWindowNumber: 17, kCGWindowOwnerPID: 24, kCGWindowLayer: 0, kCGWindowBounds: bounds(0, 0, 800, 600), kCGWindowAlpha: -1]),
        entry([kCGWindowNumber: -5, kCGWindowOwnerPID: 25, kCGWindowLayer: 0.0, kCGWindowBounds: bounds(0, 0, 800, 600)]),
        entry([:]),
    ]

    private static func old(_ entries: [NSDictionary]?) -> [[String: Any]]? {
        entries.flatMap { ($0 as NSArray) as? [[String: Any]] }
    }

    private static func check(_ entries: [NSDictionary]?, frontmostPID: pid_t? = front, file: StaticString = #filePath, line: UInt = #line) {
        let isRegular = { (pid: pid_t) in pid != 30 }
        let new = WindowCensus.census(entries, spaceID: 7, me: me, frontmostPID: frontmostPID, isRegular: isRegular)
        XCTAssertEqual(new, Old.census(old(entries), spaceID: 7, me: me, frontmostPID: frontmostPID, isRegularApp: isRegular), file: file, line: line)
        XCTAssertEqual(FrontmostApp.owners(entries), Old.owners(old(entries)), file: file, line: line)
        XCTAssertEqual(WindowList.records(entries), Old.records(old(entries)), file: file, line: line)
        XCTAssertEqual(WindowList.order(entries), Old.order(old(entries)), file: file, line: line)
        XCTAssertEqual(WindowList.ids(entries), Old.ids(old(entries)), file: file, line: line)
    }

    func testReadersGiveTheSameResultsAsTheBridgedReaders() {
        Self.check(Self.fixture)
        Self.check(Array(Self.fixture.reversed()))
        Self.check([])
        Self.check(nil)
        for frontmostPID in [nil, 30, Self.me, 20] as [pid_t?] {
            Self.check(Self.fixture, frontmostPID: frontmostPID)
        }
    }

    /// A single non-dictionary entry makes the whole list unavailable, as with `Old` (the same conversion as `WindowList.entries`).
    func testAListWithANonDictionaryElementIsUnavailableAsBefore() {
        let raw: NSArray = [Self.fixture[0], "not a dictionary"]
        XCTAssertNil(raw as? [NSDictionary])
        XCTAssertNil(raw as? [[String: Any]])
        XCTAssertNotNil(NSArray(array: Self.fixture) as? [NSDictionary])
    }

    /// Expected values written out, so a copying mistake cannot make both readers wrong the same way.
    func testReadersPinTheirResults() {
        let census = WindowCensus.census(Self.fixture, spaceID: 7, me: Self.me, frontmostPID: Self.front, isRegular: { $0 != 30 })
        XCTAssertEqual(Set(census.windows.keys.map(\.raw)), [1, 2, 3, 9, 4294967291], "a fractional layer passes `intValue == 0` in the census")
        XCTAssertEqual(census.frontWindow, WindowID(2), "the first kept window of the front app")
        XCTAssertEqual(census.bounds[WindowID(1)], CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(WindowCensus.census(Self.fixture, spaceID: 7, me: Self.me, frontmostPID: 30, isRegular: { $0 != 30 }).frontWindow,
                     "a front app without a kept window has no front window")
        XCTAssertEqual(FrontmostApp.owners(Self.fixture), [20, 10, 99, 30, 24, 25],
                       "a fractional layer fails `as? Int` in the owners; a missing or text layer is not 0")
        let records = WindowList.records(Self.fixture)
        XCTAssertEqual(records?[1], CGWindowRecord(id: 1, pid: 22, layer: 3, bounds: CGRect(x: 5, y: 5, width: 100, height: 100), alpha: 0.5, onScreen: false),
                       "a later duplicate wins")
        XCTAssertEqual(records?[2], CGWindowRecord(id: 2, pid: Self.front, layer: 0, bounds: CGRect(x: 10, y: 10, width: 500, height: 400), alpha: 1, onScreen: false))
        XCTAssertEqual(records?[7]?.layer, 0, "a missing layer is 0 in the records")
        XCTAssertEqual(records?[15]?.bounds, .zero, "malformed bounds are zero")
        XCTAssertNil(records?[12], "no owner")
        XCTAssertEqual(WindowList.order(Self.fixture)[3], 2)
        XCTAssertEqual(WindowList.order(Self.fixture)[12], 12, "entries without a number still count for the position")
        XCTAssertEqual(WindowList.ids(Self.fixture)?.contains(13), false, "a number that is not a number is skipped")
        XCTAssertNil(WindowList.ids(nil))
        XCTAssertEqual(WindowList.ids([]), [], "an empty list is not an unavailable list")
        XCTAssertNil(WindowList.records(nil))
        XCTAssertEqual(WindowList.order(nil), [:])
        XCTAssertEqual(FrontmostApp.owners(nil), [])
        XCTAssertEqual(WindowCensus.census(nil, spaceID: 7, me: Self.me, frontmostPID: Self.front, isRegular: { _ in true }).windows, [:])
    }
}
