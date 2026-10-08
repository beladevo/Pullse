import AppKit
import PullseCore
import UserNotifications

/// Posts macOS notifications and opens the linked page when one is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// More new events than this in one poll become a single summary notification.
    static let burstLimit = 5

    private var center: UNUserNotificationCenter { .current() }

    /// Whether macOS will actually show our notifications, in words, or nil when it will.
    func problem() async -> String? {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return "Pullse hasn't been allowed to send notifications yet."
        case .denied: return "Notifications are turned off for Pullse."
        default: break
        }
        if settings.alertSetting != .enabled || settings.alertStyle == .none {
            return "Pullse's notifications are allowed but set to show no banners or alerts."
        }
        return nil
    }

    func activate() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ events: [PREvent]) {
        if events.count > Self.burstLimit {
            let lines = events.prefix(4).map { "\($0.prLabel): \($0.headline)" }
            let more = events.count > 4 ? "\n+\(events.count - 4) more" : ""
            send(
                id: "summary-\(UUID().uuidString)",
                title: "\(events.count) updates on your pull requests",
                subtitle: nil,
                body: lines.joined(separator: "\n") + more,
                url: "https://github.com/pulls",
                thread: "summary"
            )
            return
        }
        for event in events.reversed() {  // oldest first, so the newest ends up on top
            send(
                id: event.replacementKey ?? event.id,
                title: "\(event.prLabel) · \(event.headline)",
                subtitle: event.prTitle,
                body: event.snippet,
                url: event.url,
                thread: event.prURL
            )
        }
    }

    func sendUpdated(to version: String, notesURL: String) {
        send(
            id: "updated-\(version)",
            title: "Pullse updated to \(version)",
            subtitle: nil,
            body: "Click to see what's new.",
            url: notesURL,
            thread: "updates"
        )
    }

    func sendTest(_ event: PREvent) {
        send(
            id: event.id,
            title: "Pullse is working",
            subtitle: nil,
            body: event.snippet,
            url: event.url,
            thread: "test"
        )
    }

    /// Asks for permission if macOS hasn't asked yet. Once someone has answered, macOS
    /// never asks again; only System Settings can change it.
    func requestPermissionIfNeeded() async {
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// System Settings → Notifications, on Pullse's page when macOS supports that.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let page = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
        if let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }

    private func send(
        id: String, title: String, subtitle: String?, body: String, url: String, thread: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.userInfo = ["url": url]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even while the app is "frontmost" (e.g. the popover is open).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let link = response.notification.request.content.userInfo["url"] as? String,
           GitHubLink.isSafe(link), let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
