import AppKit
import Copy
import Darwin
import Foundation

/// Whether the keyboard shortcut settings file was saved after the current Dock started (read-only; changes no behavior).
///
/// Compares the modification time of `~/Library/Preferences/com.apple.symbolichotkeys.plist` (metadata only, contents unread) with
/// the launch time (`kinfo_proc`) of this login session's Dock (`com.apple.dock`, `NSRunningApplication`), checking the Dock pid is
/// the same before and after sampling. Unreadable time, no Dock, no launch time, another user's Dock, or a changed pid -> `unknown` (nothing shown).
/// Equal times are "not newer".
///
/// It means only "the file was saved after the Dock started". Unrelated changes or delayed `cfprefsd` writes (including a flush after a Dock restart)
/// can trigger it, and unflushed changes do not. No warning does not mean the Dock has registered the shortcuts.
/// Never syncs settings, elevates privileges, or parses `ps` output.
public enum DockShortcutFreshness: Equatable {
    case current
    case preferencesNewer
    case unknown

    /// The decision alone (pure function).
    public static func evaluate(preferencesModified: Date?, dockStarted: Date?, dockBefore: pid_t?, dockAfter: pid_t?) -> DockShortcutFreshness {
        guard let modified = preferencesModified, let started = dockStarted, let before = dockBefore, before == dockAfter else { return .unknown }
        return modified > started ? .preferencesNewer : .current
    }

    /// Replaceable readers for tests. The product uses the defaults.
    public struct Readers {
        public var preferencesModified: () -> Date?
        public var dockPID: () -> pid_t?
        /// Launch time of the process with that pid; nil unless it belongs to this login user.
        public var startTime: (pid_t) -> Date?

        public init(preferencesModified: @escaping () -> Date?, dockPID: @escaping () -> pid_t?, startTime: @escaping (pid_t) -> Date?) {
            self.preferencesModified = preferencesModified; self.dockPID = dockPID; self.startTime = startTime
        }

        public static let system = Readers(preferencesModified: {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
            // No permission or no file: nil (unknown).
            return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }, dockPID: {
            // The Dock running in this login session.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first { $0.processIdentifier > 0 }?.processIdentifier
        }, startTime: { pid in
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
            // Another user's Dock (another fast-user-switching session, for example) does not count.
            guard info.kp_eproc.e_ucred.cr_uid == getuid() else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        })
    }

    /// Reads and decides. The Dock pid is read before and after; if it differs, unknown.
    public static func read(_ readers: Readers = .system) -> DockShortcutFreshness {
        let before = readers.dockPID()
        let started = before.flatMap(readers.startTime)
        let modified = readers.preferencesModified()
        let after = readers.dockPID()
        return evaluate(preferencesModified: modified, dockStarted: started, dockBefore: before, dockAfter: after)
    }

    /// The line shown in `lazyspace status` and Settings › Shortcuts (only for `preferencesNewer`).
    public static var message: String {
        L(.dockShortcutFreshnessMessage)
    }
}
