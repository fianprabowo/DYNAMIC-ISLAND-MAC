import AppKit
import Combine

/// A shelf for files dropped on the notch: they stay here until dragged out into another app.
/// Only references are kept (the files are not copied) and they survive relaunches.
class TrayManager: ObservableObject {
    @Published private(set) var items: [URL] = []

    private static let storageKey = "trayItemPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        let newItems = urls.filter { $0.isFileURL && !items.contains($0) }
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func sendViaAirDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.storageKey)
    }
}
