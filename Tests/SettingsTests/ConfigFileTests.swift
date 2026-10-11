import Copy
import XCTest
@testable import Settings

final class ConfigFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        Copy.language = .english
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lazyspace-configfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSameUTF8ComparesBytesNotCanonicalEquivalence() {
        let composed = "e\u{0301}"
        let single = "\u{00e9}"
        XCTAssertEqual(composed, single)
        XCTAssertFalse(ConfigFile.sameUTF8(composed, single))
        XCTAssertTrue(ConfigFile.sameUTF8("gap = 1\n", "gap = 1\n"))
    }

    func testMissingFileWritesAndUnchangedFileDoesNot() throws {
        let url = directory.appendingPathComponent("config.toml")
        let file = ConfigFile(url: url)
        XCTAssertEqual(file.read(), .missing)
        let created = file.save(Config(), baseline: Config())
        XCTAssertEqual(created, .written)
        let written = try String(contentsOf: url, encoding: .utf8)
        let loaded = try Config.load(toml: written)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(file.save(loaded, baseline: loaded), .unchanged)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testEnsureExistsWritesTheTemplateOnlyWhenMissing() throws {
        let url = directory.appendingPathComponent("config.toml")
        ConfigFile(url: url).ensureExists()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Config.template)
        try "gap = 4\n".write(to: url, atomically: true, encoding: .utf8)
        ConfigFile(url: url).ensureExists()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "gap = 4\n")
    }

    func testEnsureExistsDoesNotReplaceADanglingConfigurationLink() throws {
        let url = directory.appendingPathComponent("config.toml")
        let destination = "missing/config.toml"
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        ConfigFile(url: url).ensureExists()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), destination)
        XCTAssertEqual(ConfigFile(url: url).read(), .unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(destination).path))
    }

    /// Even when the configuration file points at its own backup (.bak), making the backup never deletes the real file. Saving is refused and the file stays.
    func testALinkToItsOwnBackupIsNeverDeleted() throws {
        let url = directory.appendingPathComponent("config.toml")
        let backup = url.appendingPathExtension("bak")
        try "gap = 4\n".write(to: backup, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: backup.lastPathComponent)
        let baseline = try Config.load(toml: "gap = 4\n")
        var draft = baseline
        draft.gap = 8
        let result = ConfigFile(url: url).save(draft, baseline: baseline)
        guard case .refused = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "gap = 4\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), backup.lastPathComponent)
    }

    func testInvalidUnreadableAndStaleBaselineAreRefused() throws {
        let url = directory.appendingPathComponent("config.toml")
        try "[[[broken".write(to: url, atomically: true, encoding: .utf8)
        let invalid = ConfigFile(url: url).save(Config(), baseline: Config())
        guard case .refused(let invalidMessage) = invalid else { return XCTFail("\(invalid)") }
        XCTAssertTrue(invalidMessage.contains("has errors"), invalidMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[[[broken")

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let unreadable = ConfigFile(url: url).save(Config(), baseline: Config())
        guard case .refused(let unreadableMessage) = unreadable else { return XCTFail("\(unreadable)") }
        XCTAssertTrue(unreadableMessage.contains("can't be read"), unreadableMessage)

        try FileManager.default.removeItem(at: url)
        let missingTarget = directory.appendingPathComponent("missing.toml")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: missingTarget)
        let broken = ConfigFile(url: url).save(Config(), baseline: Config())
        guard case .refused(let brokenMessage) = broken else { return XCTFail("\(broken)") }
        XCTAssertTrue(brokenMessage.contains("can't be read"), brokenMessage)

        try FileManager.default.removeItem(at: url)
        try "gap = 8\n".write(to: url, atomically: true, encoding: .utf8)
        let loaded = try Config.load(toml: "gap = 8\n")
        var draft = loaded
        draft.gap = 12
        let stale = ConfigFile(url: url).save(draft, baseline: Config())
        guard case .refused(let staleMessage) = stale else { return XCTFail("\(stale)") }
        XCTAssertTrue(staleMessage.contains("Choose Reload"), staleMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "gap = 8\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testSymlinkRewritesTheTargetAndKeepsTheBackupBesideTheLink() throws {
        let real = directory.appendingPathComponent("real.toml")
        let link = directory.appendingPathComponent("link.toml")
        try "gap = 8\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let loaded = try Config.load(toml: "gap = 8\n")
        var draft = loaded
        draft.gap = 12
        XCTAssertEqual(ConfigFile(url: link).save(draft, baseline: loaded), .written)
        let saved = try String(contentsOf: real, encoding: .utf8)
        XCTAssertTrue(saved.contains("gap = 12"), saved)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), saved)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.appendingPathExtension("bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.deletingLastPathComponent().appendingPathComponent("real.toml.bak").path))
        let backup = try String(contentsOf: link.appendingPathExtension("bak"), encoding: .utf8)
        XCTAssertEqual(backup, "gap = 8\n")
    }

    func testExternalChangeBetweenReadAndWriteRefusesTheSave() throws {
        let url = directory.appendingPathComponent("config.toml")
        try "gap = 8\n".write(to: url, atomically: true, encoding: .utf8)
        let loaded = try Config.load(toml: "gap = 8\n")
        var draft = loaded
        draft.gap = 12
        var file = ConfigFile(url: url)
        file.beforeSecondRead = {
            try? "gap = 99\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let result = file.save(draft, baseline: loaded)
        guard case .refused(let message) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(message, "The file changed while saving. Nothing was written.")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "gap = 99\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testCanonicalRewriteBetweenReadsRefusesByBytes() throws {
        let url = directory.appendingPathComponent("config.toml")
        let nfc = "gap = 8 # caf\u{00e9}\n"
        let nfd = "gap = 8 # cafe\u{0301}\n"
        XCTAssertEqual(nfc, nfd)
        XCTAssertFalse(ConfigFile.sameUTF8(nfc, nfd))
        try nfc.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try Config.load(toml: nfc)
        var draft = loaded
        draft.gap = 12
        var file = ConfigFile(url: url)
        file.beforeSecondRead = {
            try? nfd.write(to: url, atomically: true, encoding: .utf8)
        }
        let result = file.save(draft, baseline: loaded)
        guard case .refused(let message) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(message, "The file changed while saving. Nothing was written.")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), nfd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

}
