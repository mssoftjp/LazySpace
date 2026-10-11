import AppKit
import Carbon
import Foundation

/// Environment details attached to field results. Never includes titles, URLs, or typed text.
public struct EnvironmentRecord: Codable, Equatable {
    public var bundleID: String
    public var version: String
    public var executable: String
    public var osVersion: String
    public var osBuild: String
    public var cpu: String
    public var displays: [Screens.Info]
    public var displaysHaveSeparateSpaces: Bool
    public var managedDisplays: [SpaceObserver.ManagedDisplay]
    public var inputSourceID: String
    public var secureInput: Bool
    public var axTrusted: Bool
    public var missingPrivateSymbols: [String]
    public var takenAt: Date

    public static func capture() -> EnvironmentRecord {
        let bundle = Bundle.main
        let observer = SpaceObserver()
        return EnvironmentRecord(
            bundleID: bundle.bundleIdentifier ?? "(none)",
            version: (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "(none)",
            executable: bundle.executablePath ?? CommandLine.arguments.first ?? "?",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: sysctlString("kern.osversion"),
            cpu: sysctlString("machdep.cpu.brand_string"),
            displays: Screens.all(),
            displaysHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces,
            managedDisplays: observer?.managedDisplays() ?? [],
            inputSourceID: currentInputSourceID(),
            secureInput: IsSecureEventInputEnabled(),
            axTrusted: AXTrust.isTrusted(),
            missingPrivateSymbols: PrivateSymbols.missing,
            takenAt: Date())
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// TIS crashes in dispatch_assert_queue when called off the main thread (seen on a real Mac).
    /// Recording an operation never waits for the main thread: it keeps the value read on main and rereads it on input-source change notifications.
    /// The first call off the main thread only schedules the observation and returns "?".
    static func currentInputSourceID() -> String {
        if Thread.isMainThread { observeInputSource() }
        inputSourceLock.lock(); defer { inputSourceLock.unlock() }
        if !inputSourceObserved { DispatchQueue.main.async { observeInputSource() } }
        return inputSourceID
    }

    private static let inputSourceLock = NSLock()
    private static var inputSourceID = "?"
    private static var inputSourceObserved = false

    /// Main thread only.
    private static func observeInputSource() {
        inputSourceLock.lock()
        let first = !inputSourceObserved
        inputSourceObserved = true
        inputSourceLock.unlock()
        if first {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                                object: nil, queue: .main) { _ in refreshInputSource() }
            refreshInputSource()
        }
    }

    private static func refreshInputSource() {
        let id: String
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        } else { id = "?" }
        inputSourceLock.lock(); inputSourceID = id; inputSourceLock.unlock()
    }
}
