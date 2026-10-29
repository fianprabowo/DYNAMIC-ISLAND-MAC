import AppKit

/// Shows on the notch when Claude Code needs you (a permission prompt, or waiting for input) and
/// when it has finished its turn. Claude Code's hooks run scripts/claude-hook.sh, which appends
/// each event as a JSON line to ~/Library/Application Support/DynamicIsland/claude-events.jsonl.
///
/// Nothing shows while the terminal Claude Code runs in is the frontmost app: you see it already.
class ClaudeEventMonitor {
    private let notificationManager: NotificationManager
    private var pollTask: Task<Void, Never>?
    /// How far the log has been read; nil until the first read, so events from before launch
    /// aren't shown.
    private var offset: UInt64?

    static let eventsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DynamicIsland/claude-events.jsonl")

    /// TERM_PROGRAM values of common terminals, for when the hook doesn't know the app's bundle id.
    private static let terminalBundleIDs = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "WarpTerminal": "dev.warp.Warp-Stable",
    ]

    /// Apps Claude Code runs in. Any process of the user's can write to the log, so a banner only
    /// ever opens one of these, never an app the log names.
    private static let knownTerminals: Set<String> = Set(terminalBundleIDs.values).union([
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.anthropic.claudefordesktop",
    ])

    /// Longer text is cut; Claude Code's messages are a short sentence.
    private static let maxMessageLength = 200
    private static let maxFolderLength = 60
    /// More new data than this at once isn't the hook's doing; it's skipped instead of read.
    private static let maxReadSize: UInt64 = 1024 * 1024

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readNewEvents()
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    private func readNewEvents() {
        guard let handle = try? FileHandle(forReadingFrom: Self.eventsURL) else {
            // No log yet: once the hook creates it, read it from the start.
            offset = 0
            return
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard let previous = offset else {
            offset = size
            return
        }
        // The hook empties the log once it gets long.
        let start = size < previous ? 0 : previous
        guard size > start, size - start <= Self.maxReadSize else {
            offset = size
            return
        }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)),
              // A line still being written is read next time.
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            offset = start
            return
        }
        offset = start + UInt64(lastNewline - data.startIndex + 1)

        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            if let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                post(event)
            }
        }
    }

    private func post(_ event: [String: Any]) {
        let appID = terminalBundleID(event)
        if let appID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.caseInsensitiveCompare(appID) == .orderedSame {
            return
        }

        // An empty path would resolve to the app's own working directory.
        let cwd = event["cwd"] as? String ?? ""
        let folder = cwd.isEmpty ? "" : String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(Self.maxFolderLength))
        let title = folder.isEmpty || folder == "/" ? "Claude Code" : folder
        let message = String((event["message"] as? String ?? "").prefix(Self.maxMessageLength))

        switch event["event"] as? String {
        case "Notification":
            // Permission prompts, waiting for input and questions; not "logged in".
            guard event["type"] as? String != "auth_success" else { return }
            let body = message.isEmpty ? "Needs your attention" : message
            let notification = AppNotification(type: .claude, title: title, body: body, appName: "Claude Code", appBundleID: appID)
            notificationManager.postActivity(notification, keepInFeed: true)
        case "Stop":
            let notification = AppNotification(type: .claude, title: title, body: "Finished · your turn", appName: "Claude Code", appBundleID: appID)
            notificationManager.postActivity(notification)
        default:
            break
        }
    }

    /// The app Claude Code runs in (clicking the banner opens it), if it's a known one and installed.
    private func terminalBundleID(_ event: [String: Any]) -> String? {
        let candidates = [event["app"] as? String, (event["terminal"] as? String).flatMap { Self.terminalBundleIDs[$0] }]
        return candidates.compactMap { $0 }.first { appID in
            (Self.knownTerminals.contains(appID) || appID.hasPrefix("com.jetbrains."))
                && NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) != nil
        }
    }
}
