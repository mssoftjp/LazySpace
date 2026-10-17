import Copy
import Foundation

/// What macOS says about LazySpace's notifications.
enum NotificationPermission: Equatable {
    case notDetermined
    case denied
    /// Includes provisional delivery and any alert style the user chose, None too: how it shows is macOS's choice.
    case allowed
}

/// One notification. A later notice with the same identifier replaces it.
struct Notice: Equatable {
    var identifier: String
    var title: String
    var body: String
    /// `AttentionReason.Kind` raw value, handed back when the notice is clicked.
    var reason: String
}

/// What the app sees of macOS notifications. Main thread; completions arrive on main. Only `MacNotifier` (created by `main.swift`)
/// talks to the notification center, so tests and the regression checks never touch it (it aborts in a process without a bundle).
protocol Notifying: AnyObject {
    /// The `reason` of a clicked notice.
    var onActivate: ((String) -> Void)? { get set }
    /// Asks macOS only while it has not been asked; otherwise answers with the stored choice.
    func requestAuthorization(_ completion: @escaping (NotificationPermission) -> Void)
    func permission(_ completion: @escaping (NotificationPermission) -> Void)
    func post(_ notice: Notice)
    func withdraw(identifier: String)
    /// System Settings › Notifications.
    func openSettings()
}

/// A problem that stops LazySpace until the user acts. Identity is the case, never text, so a language change or a different
/// configuration error is not a new problem.
enum AttentionReason: Equatable {
    case accessibility
    case configuration
    case automaticArrangement(AutoGateCause)

    enum Kind: String {
        case accessibility
        case configuration
        case automaticArrangement = "automatic-arrangement"
    }

    var kind: Kind {
        switch self {
        case .accessibility: .accessibility
        case .configuration: .configuration
        case .automaticArrangement: .automaticArrangement
        }
    }
}

/// What the coordinator publishes: the current problem, and whether the configuration in use asks for a notification.
struct AttentionState: Equatable {
    var reason: AttentionReason?
    var notify: Bool
}

/// Notification text. Fixed sentences only: nothing from the configuration file, its path, or windows.
enum NotificationCopy {
    static func notice(for reason: AttentionReason) -> Notice {
        Notice(identifier: AttentionNotifier.identifier, title: title(reason), body: body(reason), reason: reason.kind.rawValue)
    }

    static func title(_ reason: AttentionReason) -> String {
        switch reason {
        case .accessibility: L("Allow LazySpace in \(AccessPane.name())", "「\(AccessPane.name())」でLazySpaceを許可")
        case .configuration: L("The configuration file could not be applied", "設定ファイルを適用できません")
        case .automaticArrangement: L("Automatic arrangement stopped", "自動整列を止めました")
        }
    }

    static func body(_ reason: AttentionReason) -> String {
        switch reason {
        case .accessibility:
            L("LazySpace stopped arranging windows because it is no longer allowed. Turn on LazySpace in Privacy & Security › \(AccessPane.name()).",
              "許可がオフになったため、LazySpaceはウインドウの整列を止めています。プライバシーとセキュリティ › \(AccessPane.name())でLazySpaceをオンにしてください。")
        case .configuration:
            L("LazySpace keeps using the last valid configuration. Click to see the errors.",
              "LazySpaceは直前の有効な設定を使い続けています。クリックすると誤りを確認できます。")
        case .automaticArrangement(let cause): Coordinator.AutoGate.reason(for: cause)
        }
    }
}

/// Posts, withdraws, or leaves alone the one `needs-attention` notification, from the published problem, the checkbox, and
/// the macOS permission. Main thread.
final class AttentionNotifier {
    static let identifier = "needs-attention"

    private let notifier: Notifying
    private(set) var reason: AttentionReason?
    /// The checkbox of the configuration in use; changes only with a published state, so it always comes with a fresh reason.
    private(set) var enabled = false
    /// The last accepted answer from macOS; nil until one is read.
    private(set) var permission: NotificationPermission?
    /// Posted and not withdrawn. A post is attempted only while macOS allows it, so a refused one is never counted.
    private var delivered: AttentionReason?
    /// One question to macOS at a time, so the last answer is always the newest; asks that arrive meanwhile run once after it.
    private var asking = false
    private var requestWaiting = false
    private var readWaiting = false
    /// Called when the accepted permission changes.
    var onPermissionChange: (() -> Void)?

    init(notifier: Notifying) {
        self.notifier = notifier
        // A crash may have left one behind; whatever holds now is posted again.
        notifier.withdraw(identifier: Self.identifier)
    }

    func update(_ state: AttentionState) {
        let turnedOn = state.notify && !enabled
        reason = state.reason
        enabled = state.notify
        // Turned off: a request still waiting must not make macOS ask.
        if !enabled { requestWaiting = false }
        if turnedOn { requestAuthorization() }
        else if wanted == nil { reconcile() } // withdrawing needs no permission
        else { refreshPermission() } // macOS may have changed since the last read; read before posting
    }

    /// Asks macOS (it prompts only the first time). The answer is checked against the values current when it arrives.
    func requestAuthorization() {
        if asking { requestWaiting = true; return }
        ask(request: true)
    }

    func refreshPermission() {
        if asking { readWaiting = true; return }
        ask(request: false)
    }

    private func ask(request: Bool) {
        asking = true
        let answered: (NotificationPermission) -> Void = { [weak self] answer in
            guard let self else { return }
            asking = false
            store(answer)
            // A request also reads the current answer, so it covers a waiting read. It runs only while the box is on.
            if requestWaiting, enabled { requestWaiting = false; readWaiting = false; ask(request: true) }
            else if readWaiting { requestWaiting = false; readWaiting = false; ask(request: false) }
            else { requestWaiting = false }
        }
        if request { notifier.requestAuthorization(answered) } else { notifier.permission(answered) }
    }

    func openSettings() { notifier.openSettings() }

    /// At quit, so a stale notice never relaunches LazySpace when clicked.
    func withdraw() {
        notifier.withdraw(identifier: Self.identifier)
        delivered = nil
    }

    private var wanted: AttentionReason? { enabled ? reason : nil }

    private func store(_ answer: NotificationPermission) {
        let changed = answer != permission
        permission = answer
        reconcile()
        if changed { onPermissionChange?() }
    }

    private func reconcile() {
        let target = permission == .allowed ? wanted : nil
        guard target != delivered else { return }
        if let target { notifier.post(NotificationCopy.notice(for: target)) } else { notifier.withdraw(identifier: Self.identifier) }
        delivered = target
    }
}
