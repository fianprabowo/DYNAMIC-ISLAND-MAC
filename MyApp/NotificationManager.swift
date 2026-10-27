import Foundation
import Combine
import UserNotifications

struct AppNotification: Identifiable {
    let id = UUID()
    let type: NotificationType
    let title: String
    let body: String
    /// Set for notifications from other apps (see SystemNotificationMonitor).
    var appName: String? = nil
    var appBundleID: String? = nil
    let date = Date()
    var isRead = false
    /// A banner shown as soon as an app's Dock badge went up, before the notification's details
    /// arrive (see DockBadgeWatcher). It isn't added to the feed.
    var isPending = false

    var icon: String { type.icon }
}

enum NotificationType: CaseIterable {
    case system, message, warning, reminder, music, network, app

    var icon: String {
        switch self {
        case .system: return "gearshape.fill"
        case .message: return "message.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .reminder: return "bell.fill"
        case .music: return "music.note"
        case .network: return "wifi"
        case .app: return "app.badge.fill"
        }
    }

    /// Types that are also forwarded to macOS Notification Center.
    var postsToSystem: Bool {
        self == .warning || self == .reminder
    }
}

/// In-app notification feed (newest first) with optional Notification Center delivery.
/// Notifications stay until removed (or the app quits); only the oldest beyond the limit drop off.
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var notifications: [AppNotification] = []
    /// The latest notification from another app, shown on the notch for a few seconds.
    @Published private(set) var banner: AppNotification?

    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    private let bannerDuration: TimeInterval = 5
    /// How long a pending banner waits for its notification's details.
    private let pendingBannerDuration: TimeInterval = 8
    private var heldBannerID: UUID?
    private let maxNotifications = 50
    private var hasRequestedAuthorization = false

    private init() {}

    func post(_ type: NotificationType, title: String, body: String) {
        let notification = AppNotification(type: type, title: title, body: body)
        add(notification)

        if type.postsToSystem {
            sendSystemNotification(notification)
        }
    }

    /// A notification another app posted to Notification Center.
    func post(fromApp bundleID: String?, appName: String, title: String, body: String) {
        let notification = AppNotification(type: .app, title: title.isEmpty ? appName : title, body: body, appName: appName, appBundleID: bundleID)
        add(notification)
        // Replaces the app's pending banner, if any, in place.
        showBanner(notification, for: bannerDuration)
    }

    /// Shows a banner for another app the moment its Dock badge goes up. Notification Center
    /// records the notification itself about five seconds later; then `post(fromApp:…)` fills it in.
    func announce(appBundleID: String, appName: String) {
        // Don't cut short a banner that's showing a notification's details.
        if let banner, !banner.isPending {
            return
        }
        let notification = AppNotification(type: .app, title: appName, body: "New notification", appName: appName, appBundleID: appBundleID, isPending: true)
        showBanner(notification, for: pendingBannerDuration)
    }

    private func showBanner(_ notification: AppNotification, for duration: TimeInterval) {
        // A pending banner filled in under the pointer stays held.
        if heldBannerID != nil {
            heldBannerID = notification.id
        }
        banner = notification
        Task { [weak self, id = notification.id] in
            try? await Task.sleep(for: .seconds(duration))
            if self?.banner?.id == id && self?.heldBannerID != id {
                self?.banner = nil
            }
        }
    }

    func dismissBanner() {
        banner = nil
    }

    /// While the pointer rests on the banner it stays; it goes a few seconds after the pointer leaves.
    func holdBanner(_ hold: Bool) {
        heldBannerID = hold ? banner?.id : nil
        if !hold, let banner {
            showBanner(banner, for: 3)
        }
    }

    private func add(_ notification: AppNotification) {
        notifications.insert(notification, at: 0)
        if notifications.count > maxNotifications {
            notifications.removeLast(notifications.count - maxNotifications)
        }
    }

    func dismiss(id: UUID) {
        notifications.removeAll { $0.id == id }
    }

    func markAllAsRead() {
        guard unreadCount > 0 else { return }
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearAll() {
        notifications.removeAll()
    }

    private func sendSystemNotification(_ notification: AppNotification) {
        Task {
            let center = UNUserNotificationCenter.current()
            if !hasRequestedAuthorization {
                hasRequestedAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            let request = UNNotificationRequest(identifier: notification.id.uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
