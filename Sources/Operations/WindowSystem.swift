import Copy
import CoreGraphics
import Foundation
import LayoutCore

/// Evidence for whether one window may enter the dialog region. Built only when every needed attribute is known.
/// A missing attribute (unsupported, no value) counts as known; an unreadable one means no evidence (unknown: neither dialog nor standard).
public struct DialogEvidence: Equatable {
    public enum Button: Equatable { case absent, enabled, disabled }
    public var role: String
    /// nil means no value.
    public var subrole: String?
    public var minimized: Bool
    public var fullscreen: Bool
    public var fullscreenButton: Button
    public var zoomButton: Button
    public var sizeSettable: Bool
    /// Used only to match rules; never recorded.
    public var title: String

    public init(role: String, subrole: String?, minimized: Bool, fullscreen: Bool, fullscreenButton: Button, zoomButton: Button, sizeSettable: Bool, title: String) {
        self.role = role; self.subrole = subrole; self.minimized = minimized; self.fullscreen = fullscreen
        self.fullscreenButton = fullscreenButton; self.zoomButton = zoomButton; self.sizeSettable = sizeSettable; self.title = title
    }

    /// Standard by the same test as `ObservedWindow.Kind.observed` (full-screen button enabled, or resizable).
    public var isStandard: Bool {
        guard role == "AXWindow", !minimized, !fullscreen else { return false }
        let zoomable = subrole == "AXStandardWindow" || (subrole == "AXDialog" && zoomButton != .absent)
        guard zoomable else { return false }
        return fullscreenButton == .enabled || (sizeSettable && zoomButton == .enabled)
    }

    /// A dialog for the region. `AXSystemDialog` is not one: apps use it for panels that follow their own window (such as a preview kept beside it),
    /// so moving it into the strip only makes the app pull it back.
    public var isDialog: Bool {
        guard role == "AXWindow", !minimized, !fullscreen else { return false }
        switch subrole {
        case "AXStandardWindow": return !isStandard
        case "AXDialog": return !isStandard
        default: return false
        }
    }
}

/// One window as observed from the OS. No guesses.
public struct ObservedWindow: Equatable, Codable {
    public enum Membership: String, Codable {
        case current
        case other
        /// On the current Space, but several displays share one Space and the window is mostly on a display without the menu bar.
        case otherDisplay
        /// On all Spaces (sticky).
        case allSpaces
        case unknown
    }

    public enum Kind: String, Codable {
        case standard
        case dialog
        case sheet
        case palette
        case minimized
        case hiddenApp
        case fullscreen
        case nonNormalLayer
        case unknownRole

        /// Decides the kind from observed roles. Some apps, like Xcode, report document windows as AXDialog.
        /// An AXDialog with a zoom button counts as a document window; system dialogs and dialogs without zoom stay excluded.
        /// Windows without an enabled full-screen button are still arranged if resizable (size writable and zoom button enabled) (`resizable`).
        public static func observed(hiddenApp: Bool, minimized: Bool, fullscreen: Bool, layer: Int, role: String, subrole: String, dialogHasZoomButton: Bool, fullscreenButtonEnabled: Bool = true, resizable: Bool = false, onFullscreenSpace: Bool = false) -> Kind {
            if hiddenApp { return .hiddenApp }
            if minimized { return .minimized }
            if fullscreen || onFullscreenSpace { return .fullscreen }
            if layer != 0 { return .nonNormalLayer }
            if role == "AXSheet" { return .sheet }
            if subrole == "AXStandardWindow" || (subrole == "AXDialog" && dialogHasZoomButton) {
                // Without an enabled full-screen button and not resizable: floated as a dialog.
                return fullscreenButtonEnabled || resizable ? .standard : .dialog
            }
            if subrole == "AXDialog" || subrole == "AXSystemDialog" { return .dialog }
            if subrole == "AXFloatingWindow" || subrole == "AXSystemFloatingWindow" { return .palette }
            return .unknownRole
        }
    }

    public var id: WindowID
    public var pid: Int32
    /// Bundle identifier.
    public var app: String
    /// Used only to match rules; never written to logs or the state file.
    public var title: String
    public var frame: CGRect
    public var membership: Membership
    public var kind: Kind
    /// Basis of the decision (subrole and so on), for display.
    public var detail: String
    /// Role used to remember size constraints per app kind; empty means by window ID only.
    public var subrole: String
    /// CGWindowList front-to-back order, 0 frontmost; unknown goes last.
    public var stackOrder: Int

    public init(id: WindowID, pid: Int32, app: String, frame: CGRect, membership: Membership, kind: Kind, detail: String, subrole: String = "", stackOrder: Int = Int.max, title: String = "") {
        self.id = id
        self.pid = pid
        self.app = app
        self.title = title
        self.frame = frame
        self.membership = membership
        self.kind = kind
        self.detail = detail
        self.subrole = subrole
        self.stackOrder = stackOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id, pid, app, frame, membership, kind, detail, subrole, stackOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WindowID.self, forKey: .id)
        pid = try c.decode(Int32.self, forKey: .pid)
        app = try c.decode(String.self, forKey: .app)
        frame = try c.decode(CGRect.self, forKey: .frame)
        membership = try c.decode(Membership.self, forKey: .membership)
        kind = try c.decode(Kind.self, forKey: .kind)
        detail = try c.decode(String.self, forKey: .detail)
        subrole = try c.decode(String.self, forKey: .subrole)
        stackOrder = try c.decode(Int.self, forKey: .stackOrder)
        title = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pid, forKey: .pid)
        try c.encode(app, forKey: .app)
        try c.encode(frame, forKey: .frame)
        try c.encode(membership, forKey: .membership)
        try c.encode(kind, forKey: .kind)
        try c.encode(detail, forKey: .detail)
        try c.encode(subrole, forKey: .subrole)
        try c.encode(stackOrder, forKey: .stackOrder)
    }
}

/// One observation. An operation is pinned to the snapshot taken at its start.
public struct Snapshot: Equatable, Codable {
    public var trusted: Bool
    /// Current Space; nil when unobservable.
    public var spaceID: UInt64?
    /// Work area in logical coordinates (top-left origin).
    public var workArea: CGRect
    public var windows: [ObservedWindow]
    /// Whether the means of observing Spaces is available.
    public var spaceObservationAvailable: Bool
    /// Apps (bundle IDs) that returned no window list in time, kept so targets never shrink silently.
    public var unobservedApps: [String]
    /// Whether the OS's full window list was read. Without it, an invisible window is no evidence of closing.
    public var windowListAvailable: Bool

    public init(trusted: Bool, spaceID: UInt64?, workArea: CGRect, windows: [ObservedWindow], spaceObservationAvailable: Bool, unobservedApps: [String] = [],
                windowListAvailable: Bool = true) {
        self.trusted = trusted
        self.spaceID = spaceID
        self.workArea = workArea
        self.windows = windows
        self.spaceObservationAvailable = spaceObservationAvailable
        self.unobservedApps = unobservedApps
        self.windowListAvailable = windowListAvailable
    }
}

public enum FrameRead: Equatable {
    case frame(CGRect)
    case gone
    case failed(String)
}

public enum WriteResult: Equatable {
    case issued
    case gone
    case rejected(String)
    case timedOut

    public static var interrupted: WriteResult {
        .rejected(L("The operation was interrupted before the next window change.", "次のウインドウ変更の前に操作が中断されました。"))
    }
}

/// The interface macOS integration provides. Operations touch the OS through nothing else.
public protocol WindowSystem: AnyObject {
    func snapshot() -> Snapshot
    /// Observes only the given windows; nil for all. Automatic arrangement and edits narrow to known targets.
    func snapshot(limitingTo ids: Set<WindowID>?) -> Snapshot
    /// One window's Space membership, returned only when known without a full AX observation.
    func membershipOf(_ id: WindowID) -> ObservedWindow.Membership?
    var axTrusted: Bool { get }
    /// The current Space, for gate checks; nil when unobservable.
    func currentSpaceID() -> UInt64?
    func readFrame(_ id: WindowID) -> FrameRead
    /// Recheck authorization after reads and before each individual position/size request.
    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// currentFrame is the frame just read in the same operation. Callers recheck authorization after reading.
    func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// Writes only the position (size, activation, focus, and Space untouched); used for the dialog region. Implementations without support refuse.
    func writePosition(_ id: WindowID, origin: CGPoint, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// Cumulative user input count (clicks, drags, keys). No content.
    var inputActivityCount: UInt64 { get }
    /// True while the left button is down (default false). Used to adopt mouse edits.
    var mouseButtonDown: Bool { get }
    /// The front app's focused window; nil when unconfirmed.
    func focusedWindowID() -> WindowID?
    /// After raise, the app is activated on the main thread only if `activateIf` is true, so no activation runs after the operation has ended.
    /// `activated` is always called exactly once on the main thread, whatever the return value: with the app's pid if activation was requested,
    /// nil otherwise (no element, gate false, no window, AX refusal or timeout, no app). Implementations taking `activated` must keep this.
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool, activated: ((Int32?) -> Void)?) -> WriteResult
    /// Retains AX elements of current-Space windows within the deadline (no frames, state, or titles read), for raising or writing them after they become invisible.
    func retainElements(for ids: Set<WindowID>, deadline: Date)
    /// Close by explicit user action (presses the close button; the app may show a confirmation dialog).
    func close(_ id: WindowID, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// Toggles full screen or minimize by explicit user action (one AX attribute).
    func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult
    /// Reads the attribute after writing; nil when unreadable (not counted as success).
    func readWindowState(_ id: WindowID, _ attribute: WindowStateAttribute) -> Bool?
}

/// OS-side window state (`toggleWindowState`).
public enum WindowStateAttribute: Equatable {
    case fullscreen
    case minimized
}

public extension WindowSystem {
    /// Refuses by default (the hidden-Space writer and test implementations do not write position alone).
    func writePosition(_ id: WindowID, origin: CGPoint, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        .rejected(L("Moving a window without resizing it is not supported here.", "ここでは、大きさを変えずにウインドウを動かせません。"))
    }
    /// Probe callers without an operation can explicitly use these unscoped conveniences.
    /// Product operations pass their authorization to the required gated methods.
    func focus(_ id: WindowID, timeout: TimeInterval) -> WriteResult {
        raise(id, timeout: timeout, activateIf: { true }, activated: nil)
    }
    func raise(_ id: WindowID, timeout: TimeInterval, activateIf: @escaping () -> Bool) -> WriteResult {
        raise(id, timeout: timeout, activateIf: activateIf, activated: nil)
    }
    /// Defaults to a narrowed observation (for test implementations).
    func retainElements(for ids: Set<WindowID>, deadline: Date) { _ = snapshot(limitingTo: ids) }
    func writeFrame(_ id: WindowID, frame: CGRect, timeout: TimeInterval) -> WriteResult {
        writeFrame(id, frame: frame, timeout: timeout, shouldContinue: { true })
    }
    func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval) -> WriteResult {
        writeFrame(id, frame: frame, currentFrame: currentFrame, timeout: timeout, shouldContinue: { true })
    }
    func writeFrame(_ id: WindowID, frame: CGRect, currentFrame: CGRect, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult {
        writeFrame(id, frame: frame, timeout: timeout, shouldContinue: shouldContinue)
    }
    func close(_ id: WindowID, timeout: TimeInterval) -> WriteResult {
        close(id, timeout: timeout, shouldContinue: { true })
    }
    func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval) -> WriteResult {
        toggleWindowState(id, attribute, timeout: timeout, shouldContinue: { true })
    }
    func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval) -> WriteResult {
        setWindowState(id, attribute, value: value, timeout: timeout, shouldContinue: { true })
    }
    func snapshot(limitingTo ids: Set<WindowID>?) -> Snapshot { snapshot() }
    func membershipOf(_ id: WindowID) -> ObservedWindow.Membership? { nil }
    var axTrusted: Bool { true }
    var mouseButtonDown: Bool { false }
    func toggleWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected(L("Not supported", "未対応")) }
    func setWindowState(_ id: WindowID, _ attribute: WindowStateAttribute, value: Bool, timeout: TimeInterval, shouldContinue: @escaping () -> Bool) -> WriteResult { .rejected(L("Not supported", "未対応")) }
    func readWindowState(_ id: WindowID, _ attribute: WindowStateAttribute) -> Bool? { nil }
}
