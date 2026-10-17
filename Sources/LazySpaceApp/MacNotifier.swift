import AppKit
import UserNotifications

/// The only file that imports UserNotifications; `main.swift` creates it, so tests and the regression checks never touch the
/// notification center. macOS shows LazySpace's name and icon, and the user chooses the style in System Settings. No sound.
final class MacNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let bundleIdentifier: String
    var onActivate: ((String) -> Void)?

    /// nil without a bundle identifier (`UNUserNotificationCenter.current()` aborts there) and under tests.
    static func makeIfAvailable(bundle: Bundle) -> Notifying? {
        guard let identifier = bundle.bundleIdentifier, !UpdateEligibility.runningUnderTests else { return nil }
        return MacNotifier(bundleIdentifier: identifier)
    }

    private init(bundleIdentifier: String) {
        center = UNUserNotificationCenter.current()
        self.bundleIdentifier = bundleIdentifier
        super.init()
        // Set while launching, so a click that opened LazySpace is delivered too.
        center.delegate = self
    }

    func requestAuthorization(_ completion: @escaping (NotificationPermission) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .notDetermined else {
                let answer = Self.permission(settings)
                DispatchQueue.main.async { completion(answer) }
                return
            }
            // Banners only: no sound and no badge from LazySpace.
            center.requestAuthorization(options: [.alert]) { [weak self] _, _ in
                self?.permission(completion)
            }
        }
    }

    func permission(_ completion: @escaping (NotificationPermission) -> Void) {
        center.getNotificationSettings { settings in
            let answer = Self.permission(settings)
            DispatchQueue.main.async { completion(answer) }
        }
    }

    private static func permission(_ settings: UNNotificationSettings) -> NotificationPermission {
        switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = ["reason": notice.reason]
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)) { error in
            if let error { NSLog("LazySpace: a notification was not delivered: \(error.localizedDescription)") }
        }
    }

    func withdraw(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// LazySpace's entry in System Settings › Notifications, or the pane itself if that link does not open.
    func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: pane + "?id=" + bundleIdentifier), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Shown even while Settings or the window list is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let reason = response.notification.request.content.userInfo["reason"] as? String
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            if opened, let reason { self.onActivate?(reason) }
            completionHandler()
        }
    }
}
