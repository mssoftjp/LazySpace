import Foundation
import XCTest
@testable import MacSupport

final class AppNamesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AppNamesTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bundle(identifier: String, info: [String: String]) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = identifier
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: url))
    }

    func testBundleNamePrefersDisplayNameThenBundleName() throws {
        let both = try bundle(identifier: "com.example.both", info: ["CFBundleDisplayName": "Both Display", "CFBundleName": "Both"])
        XCTAssertEqual(AppNames.bundleName(both, for: "com.example.both"), "Both Display")
        let nameOnly = try bundle(identifier: "com.example.name", info: ["CFBundleName": "Name Only"])
        XCTAssertEqual(AppNames.bundleName(nameOnly, for: "com.example.name"), "Name Only")
        let none = try bundle(identifier: "com.example.none", info: [:])
        XCTAssertNil(AppNames.bundleName(none, for: "com.example.none"))
    }

    func testBundleNameRequiresTheExactIdentifier() throws {
        let app = try bundle(identifier: "com.apple.Stickies", info: ["CFBundleName": "Stickies"])
        XCTAssertEqual(AppNames.bundleName(app, for: "com.apple.Stickies"), "Stickies")
        XCTAssertNil(AppNames.bundleName(app, for: "com.apple.stickies"))
    }

    func testResolverOrderIsRunningThenInstalledThenNil() {
        XCTAssertEqual(AppNames.knownName("a", running: { _ in "Running" }, installed: { _ in "Installed" }), "Running")
        XCTAssertEqual(AppNames.knownName("a", running: { _ in nil }, installed: { _ in "Installed" }), "Installed")
        XCTAssertEqual(AppNames.knownName("a", running: { _ in "" }, installed: { _ in "Installed" }), "Installed")
        XCTAssertNil(AppNames.knownName("a", running: { _ in nil }, installed: { _ in nil }))
        let missing = "com.example.not.installed.\(UUID().uuidString)"
        XCTAssertEqual(AppNames.localized(missing), missing)
    }
}
