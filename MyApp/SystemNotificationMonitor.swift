import AppKit
import SQLite3

/// Brings other apps' notifications to the notch. macOS has no API for this, so it reads
/// Notification Center's own database (which needs Full Disk Access). The database is
/// undocumented and may change with a macOS update.
///
/// To see a notification only on the notch, set the app's alert style to None in System Settings →
/// Notifications and keep "Show in Notification Center" on, so it's still recorded. macOS writes a
/// notification to the database about five seconds after it arrives, whatever its style; watching
/// the database file picks it up the moment it's written.
class SystemNotificationMonitor {
    private let notificationManager: NotificationManager
    private let reader = NotificationDatabaseReader()
    private var watcher: DispatchSourceFileSystemObject?
    private var pollTask: Task<Void, Never>?
    private var hasReadNotifyingApps = false

    /// SQLite writes new records to the write-ahead log first.
    private static let walPath = NotificationDatabaseReader.path + "-wal"

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        // A slow poll backs up the file watcher: watching can only start once Full Disk Access
        // is granted, and the log file may be replaced.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.watchDatabase()
                await self?.readNotifyingApps()
                await self?.postNewNotifications()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    deinit {
        pollTask?.cancel()
        watcher?.cancel()
    }

    private func watchDatabase() {
        guard watcher == nil else { return }
        let descriptor = open(Self.walPath, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        watcher.setEventHandler { [weak self, unowned watcher] in
            if !watcher.data.isDisjoint(with: [.delete, .rename]) {
                watcher.cancel()
                self?.watcher = nil
            }
            Task { await self?.postNewNotifications() }
        }
        watcher.setCancelHandler {
            close(descriptor)
        }
        watcher.resume()
        self.watcher = watcher
    }

    /// Tells the notification manager which apps notify at all, so their Dock badges can announce
    /// notifications (see DockBadgeWatcher).
    private func readNotifyingApps() async {
        guard !hasReadNotifyingApps, let apps = await reader.appsWithNotifications() else { return }
        hasReadNotifyingApps = true
        notificationManager.addNotifyingApps(apps)
    }

    private func postNewNotifications() async {
        for record in await reader.newRecords() {
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.appID)
            let appName = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? record.appID
            notificationManager.post(fromApp: record.appID, appName: appName, title: record.title, body: record.body)
        }
    }
}

actor NotificationDatabaseReader {
    nonisolated struct Record: Sendable {
        let appID: String
        let title: String
        let body: String
    }

    nonisolated static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
    /// Delivery time of the newest notification already seen; nil until the database is first
    /// read, so notifications from before launch aren't shown again. Times rather than record ids,
    /// because a notification that replaces an earlier one (same app and identifier) keeps its record.
    private var lastDeliveryDate: Double?

    /// Bundle identifiers (lowercased, as the app table keeps them) of apps with notifications in
    /// Notification Center; nil if the database can't be read.
    func appsWithNotifications() -> Set<String>? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(Self.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT a.identifier FROM app a JOIN record r USING (app_id)", -1, &statement, nil) == SQLITE_OK else { return nil }
        var apps: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let identifier = sqlite3_column_text(statement, 0) {
                apps.insert(String(cString: identifier).lowercased())
            }
        }
        return apps
    }

    func newRecords() -> [Record] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(Self.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }

        guard let lastDeliveryDate else {
            lastDeliveryDate = newestDeliveryDate(db)
            return []
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT r.delivered_date, r.data, a.identifier FROM record r JOIN app a USING (app_id) WHERE r.delivered_date > ? ORDER BY r.delivered_date"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(statement, 1, lastDeliveryDate)

        var records: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            self.lastDeliveryDate = max(self.lastDeliveryDate ?? 0, sqlite3_column_double(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 1),
                  let fallbackAppID = sqlite3_column_text(statement, 2).map({ String(cString: $0) }) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            if let record = Self.record(from: data, fallbackAppID: fallbackAppID),
               // Our own alerts are in the feed already.
               record.appID.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") != .orderedSame {
                records.append(record)
            }
        }
        return records
    }

    private func newestDeliveryDate(_ db: OpaquePointer?) -> Double? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT IFNULL(MAX(delivered_date), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    /// Each record is a property list: "app" is the bundle identifier (the app table lowercases
    /// it), and the request under "req" holds the title, subtitle and body.
    private static func record(from data: Data, fallbackAppID: String) -> Record? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any] else { return nil }
        let title = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return Record(appID: plist["app"] as? String ?? fallbackAppID, title: title, body: [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}
