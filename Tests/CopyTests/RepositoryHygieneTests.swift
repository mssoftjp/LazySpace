import Foundation
import XCTest

/// Published files never contain paths of the machine they were written on (home directories, user names, checkouts beside this one).
final class RepositoryHygieneTests: XCTestCase {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Built from pieces so this file does not match itself. Documented per-user locations such as `~/.config/lazyspace` stay allowed.
    static let machinePathMarkers = ["/" + "Users/", "/" + "home/", "C:" + "\\Users\\",
                                     "~/" + "Projects", "$HOME/" + "Projects", "Path." + "home()"]

    static func machinePaths(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            machinePathMarkers.contains { line.contains($0) } ? "\(index + 1): \(line)" : nil
        }
    }

    /// Files Git would publish: tracked ones plus new files not ignored yet.
    static func publishedFiles() throws -> [String] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = FileHandle.nullDevice
        try git.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { throw XCTSkip("not a Git checkout") }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    func testMarkersAreDetected() {
        XCTAssertEqual(Self.machinePaths(in: "ok\nsee " + "/" + "Users/someone/Projects/app").count, 1)
        XCTAssertEqual(Self.machinePaths(in: "TOOLS=" + "$HOME/" + "Projects/tools").count, 1)
        XCTAssertTrue(Self.machinePaths(in: "~/.config/lazyspace/config.toml\n../tools").isEmpty)
    }

    func testPublishedFilesContainNoMachinePaths() throws {
        let files = try Self.publishedFiles()
        XCTAssertGreaterThan(files.count, 50, "the scan reached the repository")
        var found: [String] = []
        for path in files {
            // Deleted but still tracked, or binary (images, icons): nothing to read as text.
            guard let data = FileManager.default.contents(atPath: Self.root.appendingPathComponent(path).path),
                  !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
            found += Self.machinePaths(in: text).map { "\(path):\($0)" }
        }
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }

    /// SwiftPM generates the String Catalog symbols at build time; a committed copy would clash with them.
    func testGeneratedCatalogSymbolsAreNotPublished() throws {
        let generated = try Self.publishedFiles().filter { ($0 as NSString).lastPathComponent.hasPrefix("GeneratedStringSymbols_") }
        XCTAssertEqual(generated, [])
    }
}
