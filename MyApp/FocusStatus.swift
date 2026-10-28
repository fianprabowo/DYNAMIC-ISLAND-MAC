import Foundation

/// Whether a Focus (like Do Not Disturb) is on. macOS has no public API for this, so it reads the
/// Focus database: turning a Focus on adds an assertion record, turning it off moves the record to
/// the invalidations. The file is undocumented and may change with a macOS update.
nonisolated enum FocusStatus {
    private static let assertionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    static var isActive: Bool {
        guard let data = try? Data(contentsOf: assertionsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = object["data"] as? [[String: Any]] else { return false }
        return stores.contains { !($0["storeAssertionRecords"] as? [Any] ?? []).isEmpty }
    }
}
