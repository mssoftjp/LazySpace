import Copy
import Foundation

/// Reads and writes the configuration file. Applying it and calling callbacks is up to the caller.
public struct ConfigFile {
    private let url: URL
    /// Runs after building the patch, right before the second read. Only tests use it, to simulate an outside change during a save.
    var beforeSecondRead: (() -> Void)?

    public init(url: URL) { self.url = url }

    enum Snapshot: Equatable {
        case missing
        case unreadable
        case invalid
        case loaded(String, Config)
    }

    public enum SaveResult: Equatable {
        case unchanged
        case written
        case refused(String)
    }

    /// Swift string comparison treats canonically equivalent strings as equal; compare the text before saving as UTF-8 bytes.
    public static func sameUTF8(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Creates the template only when the path does not exist at all. A broken link or unreadable file is never replaced.
    public func ensureExists() {
        guard read() == .missing else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Config.template.write(to: url, atomically: true, encoding: .utf8)
    }

    func read() -> Snapshot {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil, !fm.fileExists(atPath: url.path) {
            return .unreadable
        }
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unreadable }
        do { return .loaded(text, try Config.load(toml: text)) } catch { return .invalid }
    }

    /// For a symbolic link, the real file it points to. The link itself is never replaced.
    private func writeURL() -> URL {
        var current = url
        var seen = Set<String>()
        let fm = FileManager.default
        while seen.insert(current.path).inserted, let dest = try? fm.destinationOfSymbolicLink(atPath: current.path) {
            current = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : current.deletingLastPathComponent().appendingPathComponent(dest)
            current.standardize()
        }
        return current
    }

    /// Applies only changed values to the file. Writes nothing when unchanged. Does not reload.
    public func save(_ draft: Config, baseline: Config) -> SaveResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .refused(L(.configFileCouldNotWriteTheConfiguration))
        }
        switch read() {
        case .unreadable:
            return .refused(L(.configFileTheConfigurationFileCantBe))
        case .invalid:
            return .refused(L(.configFileTheConfigurationFileHasErrors))
        case .missing:
            return writePatched(draft, original: nil, text: Config.template, previous: Config())
        case .loaded(let text, let config):
            guard config == baseline else {
                return .refused(L(.configFileTheFileChangedChooseReload))
            }
            guard draft != config else { return .unchanged }
            return writePatched(draft, original: text, text: text, previous: config)
        }
    }

    private func writePatched(_ draft: Config, original: String?, text: String, previous: Config) -> SaveResult {
        let patched: String
        do { patched = try ConfigDocument.applying(draft, to: text, replacing: previous) }
        catch let error as ConfigDocument.Problem {
            return .refused(error.message)
        } catch {
            return .refused(L(.configFileSettingsCantUpdateThisFile))
        }
        beforeSecondRead?()
        switch read() {
        case .loaded(let latest, _) where original != nil:
            guard Self.sameUTF8(latest, original!) else {
                return .refused(L(.configFileTheFileChangedWhileSaving))
            }
        case .missing where original == nil:
            break
        default:
            return .refused(L(.configFileTheFileChangedWhileSaving))
        }
        if let original, Self.sameUTF8(patched, original) { return .unchanged }
        let fm = FileManager.default
        let destination = writeURL()
        // Making the backup deletes the old one. Refuse if that backup is the write target, a folder containing it, or any folder, since that would delete the real file.
        let backup = url.appendingPathExtension("bak")
        if original != nil {
            let backupPath = backup.resolvingSymlinksInPath().standardizedFileURL.path
            let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            let backupIsDirectory = fm.fileExists(atPath: backup.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if backupPath == destinationPath || destinationPath.hasPrefix(backupPath + "/") || backupIsDirectory {
                return .refused(L(.configFileTheConfigurationFilePointsTo))
            }
        }
        do {
            if original != nil {
                if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
                try fm.copyItem(at: destination, to: backup)
            }
            try patched.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            return .refused(L(.configFileCouldNotWriteTheConfiguration))
        }
        return .written
    }
}
