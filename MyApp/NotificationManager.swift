import Foundation
import Combine
import UserNotifications

struct AppNotification: Identifiable, Codable {
    var id = UUID()
    let type: NotificationType
    let title: String
    let body: String
    /// Set for notifications from other apps (see SystemNotificationMonitor).
    var appName: String? = nil
    var appBundleID: String? = nil
    var date = Date()
    var isRead = false
    /// A banner shown as soon as an app's Dock badge went up, before the notification's details
    /// arrive (see DockBadgeWatcher). It isn't added to the feed.
    var isPending = false

    var icon: String { type.icon }
}

enum NotificationType: String, CaseIterable, Codable {
    case system, message, warning, reminder, network, app

    var icon: String {
        switch self {
        case .system: return "gearshape.fill"
        case .message: return "message.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .reminder: return "bell.fill"
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
/// Notifications stay until removed, also across launches; only the oldest beyond the limit drop off.
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()

    @Published private(set) var notifications: [AppNotification] = [] {
        didSet { save() }
    }
    /// Another app's notification, shown on the notch for a few seconds.
    @Published private(set) var banner: AppNotification?

    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    private let bannerDuration: TimeInterval = 5
    /// Banners are shorter while more notifications wait their turn.
    private let queuedBannerDuration: TimeInterval = 3
    /// How long a pending banner waits for its notification's details.
    private let pendingBannerDuration: TimeInterval = 8
    /// This many notifications from one app waiting at once show as one banner.
    private let summaryThreshold = 3
    /// After this many Dock badge rises in a row without a notification (like an app counting
    /// muted chats), the app's badge no longer announces one.
    private let maxUnconfirmedBadgeRises = 2
    private var bannerQueue: [AppNotification] = []
    private var bannerTimer: Task<Void, Never>?
    private var heldBannerID: UUID?
    /// Apps whose notifications reach Notification Center (lowercased bundle identifiers); nil
    /// until its database is read, so badges still announce notifications without Full Disk Access.
    private var notifyingApps: Set<String>?
    /// Per app (lowercased bundle identifier): the badge rise still waiting for its notification,
    /// and how many before it brought none.
    private var awaitedBadgeRises: [String: UUID] = [:]
    private var unconfirmedBadgeRises: [String: Int] = [:]
    private let maxNotifications = 50
    private var hasRequestedAuthorization = false

    private static let storeURL = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "DynamicIsland", directoryHint: .isDirectory)
        .appending(path: "notifications.json")

    private init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([AppNotification].self, from: data) {
            notifications = saved
        }
    }

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
        if let app = bundleID?.lowercased() {
            notifyingApps?.insert(app)
            awaitedBadgeRises[app] = nil
            unconfirmedBadgeRises[app] = 0
        }

        // During a Focus it's only added to the feed.
        guard !FocusStatus.isActive else { return }
        if let banner, !banner.isPending {
            bannerQueue.append(notification)
        } else {
            // Replaces a pending banner, if any, in place.
            showBanner(notification, for: bannerDuration)
        }
    }

    /// Apps found in Notification Center's database (lowercased bundle identifiers).
    func addNotifyingApps(_ apps: Set<String>) {
        // The feed also remembers apps whose notifications were cleared from Notification Center.
        let appsInFeed = notifications.compactMap { $0.appBundleID?.lowercased() }
        notifyingApps = (notifyingApps ?? []).union(apps).union(appsInFeed)
    }

    /// Shows a banner for another app the moment its Dock badge goes up. Notification Center
    /// records the notification itself about five seconds later; then `post(fromApp:…)` fills it in.
    func announce(appBundleID: String, appName: String) {
        let app = appBundleID.lowercased()
        // Apps that badge without notifying (like System Settings for updates) aren't announced.
        guard !FocusStatus.isActive,
              notifyingApps?.contains(app) ?? true,
              unconfirmedBadgeRises[app, default: 0] < maxUnconfirmedBadgeRises else { return }

        let rise = UUID()
        awaitedBadgeRises[app] = rise
        Task { [weak self, pendingBannerDuration] in
            try? await Task.sleep(for: .seconds(pendingBannerDuration))
            guard let self, awaitedBadgeRises[app] == rise else { return }
            awaitedBadgeRises[app] = nil
            unconfirmedBadgeRises[app, default: 0] += 1
        }

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
        hideBanner(after: duration)
    }

    private func hideBanner(after duration: TimeInterval) {
        bannerTimer?.cancel()
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, heldBannerID == nil else { return }
            showNextBanner()
        }
    }

    /// Shows the next waiting notification, or hides the banner. Several waiting from one app
    /// show as one banner.
    private func showNextBanner() {
        guard let next = bannerQueue.first else {
            banner = nil
            return
        }
        let fromSameApp = bannerQueue.filter { $0.appBundleID == next.appBundleID }
        if fromSameApp.count >= summaryThreshold {
            bannerQueue.removeAll { $0.appBundleID == next.appBundleID }
            let appName = next.appName ?? next.title
            let summary = AppNotification(type: .app, title: appName, body: "\(fromSameApp.count) new notifications", appName: appName, appBundleID: next.appBundleID)
            showBanner(summary, for: bannerQueue.isEmpty ? bannerDuration : queuedBannerDuration)
        } else {
            bannerQueue.removeFirst()
            showBanner(next, for: bannerQueue.isEmpty ? bannerDuration : queuedBannerDuration)
        }
    }

    func dismissBanner() {
        heldBannerID = nil
        showNextBanner()
    }

    /// While the pointer rests on the banner it stays; it goes a few seconds after the pointer leaves.
    func holdBanner(_ hold: Bool) {
        heldBannerID = hold ? banner?.id : nil
        if !hold, banner != nil {
            hideBanner(after: 3)
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
        bannerQueue.removeAll { $0.id == id }
    }

    func markAllAsRead() {
        guard unreadCount > 0 else { return }
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearAll() {
        notifications.removeAll()
        bannerQueue.removeAll()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(notifications).write(to: Self.storeURL, options: .atomic)
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
