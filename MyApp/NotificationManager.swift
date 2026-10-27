import Foundation
import Combine
import UserNotifications

struct AppNotification: Identifiable {
    let id = UUID()
    let type: NotificationType
    let title: String
    let body: String
    let date = Date()
    var isRead = false

    var icon: String { type.icon }
}

enum NotificationType: CaseIterable {
    case system, message, warning, reminder, music, network

    var icon: String {
        switch self {
        case .system: return "gearshape.fill"
        case .message: return "message.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .reminder: return "bell.fill"
        case .music: return "music.note"
        case .network: return "wifi"
        }
    }

    /// Types that are also forwarded to macOS Notification Center.
    var postsToSystem: Bool {
        self == .warning || self == .reminder
    }
}

/// In-app notification feed (newest first) with optional Notification Center delivery.
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var notifications: [AppNotification] = []

    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    var autoDismissInterval: TimeInterval = 300
    private let maxNotifications = 20
    private var hasRequestedAuthorization = false

    private init() {}

    func post(_ type: NotificationType, title: String, body: String) {
        let notification = AppNotification(type: type, title: title, body: body)
        notifications.insert(notification, at: 0)
        if notifications.count > maxNotifications {
            notifications.removeLast(notifications.count - maxNotifications)
        }

        if type.postsToSystem {
            sendSystemNotification(notification)
        }

        Task { [weak self, id = notification.id, interval = autoDismissInterval] in
            try? await Task.sleep(for: .seconds(interval))
            self?.dismiss(id: id)
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
