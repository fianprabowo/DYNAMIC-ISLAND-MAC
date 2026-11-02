import AppKit
import ApplicationServices

/// Shows a notch banner the moment an app's Dock badge goes up, about five seconds before its
/// notification's details can be read (see SystemNotificationMonitor). Reads the Dock's badges
/// through the Accessibility API (System Settings → Privacy & Security → Accessibility). The Dock
/// posts no accessibility notification when a badge changes, so the badges are polled.
class DockBadgeWatcher {
    private let notificationManager: NotificationManager
    private var pollTask: Task<Void, Never>?
    /// Badge per app bundle identifier, from the previous poll; nil before the first one.
    private var badges: [String: String]?
    private var bundleIDs: [URL: String] = [:]

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager

        // Shows macOS's prompt for Accessibility access (only the first time).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(0.2))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }

        var current: [String: String] = [:]
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        for list in Self.children(of: dockElement) {
            for item in Self.children(of: list) {
                guard let label = Self.attribute(item, "AXStatusLabel") as? String, !label.isEmpty,
                      let url = Self.attribute(item, kAXURLAttribute) as? URL,
                      let bundleID = bundleID(of: url) else { continue }
                current[bundleID] = label
            }
        }

        if let badges {
            for (bundleID, label) in current where Self.isIncrease(from: badges[bundleID], to: label) {
                let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
                notificationManager.announce(appBundleID: bundleID, appName: name)
            }
        }
        badges = current
    }

    private func bundleID(of url: URL) -> String? {
        if let bundleID = bundleIDs[url] {
            return bundleID
        }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        bundleIDs[url] = bundleID
        return bundleID
    }

    /// A count that went up, or a badge that appeared. Labels that aren't counts (like "•") only
    /// count when they appear.
    private static func isIncrease(from old: String?, to new: String) -> Bool {
        guard let old else { return true }
        guard let oldCount = Int(old), let newCount = Int(new) else { return false }
        return newCount > oldCount
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
