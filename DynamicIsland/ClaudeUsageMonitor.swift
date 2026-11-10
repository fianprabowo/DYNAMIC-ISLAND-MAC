import Foundation
import Combine
import OSLog

/// Claude Code token usage read from its local transcripts (~/.claude/projects/**/*.jsonl),
/// plus whether a Claude Code session is working right now (for the notch live activity).
///
/// The 5-hour and weekly limits of a Pro or Max plan come from Anthropic, read with Claude Code's
/// own sign-in (see `ClaudePlanUsage`). When that can't be read, they come from the Claude Code
/// status line: ~/.claude/dynamic-island-statusline.sh saves the status JSON, whose `rate_limits`
/// hold the same windows, but only while Claude Code runs in a terminal.
class ClaudeUsageMonitor: ObservableObject {
    @Published private(set) var snapshot = ClaudeUsageSnapshot()

    private let scanner = ClaudeLogScanner()
    private let weekEndReminder = ClaudeWeekEndReminder()
    private var scanTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    /// The latest scan of the transcripts, before the live limits are put in.
    private var scanned = ClaudeUsageSnapshot()
    private var liveLimits: ClaudePlanUsage.Limits?

    /// How often the limits are read from Anthropic, and again after a failed read.
    private static let limitsInterval: TimeInterval = 120
    private static let limitsRetryInterval: TimeInterval = 300
    /// Live limits older than this give way to the status line's, or to none.
    private static let liveLimitsMaxAge: TimeInterval = 600

    init() {
        scanTask = Task { [weak self, scanner] in
            while !Task.isCancelled {
                let snapshot = await scanner.scan()
                self?.scanned = snapshot
                self?.publish()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        limitsTask = Task { [weak self] in
            while !Task.isCancelled {
                let limits = await ClaudePlanUsage.fetch()
                if let limits {
                    self?.liveLimits = limits
                    self?.publish()
                }
                try? await Task.sleep(for: .seconds(limits == nil ? Self.limitsRetryInterval : Self.limitsInterval))
            }
        }
    }

    deinit {
        scanTask?.cancel()
        limitsTask?.cancel()
    }

    private func publish() {
        var snapshot = scanned
        let now = Date()
        if let live = liveLimits, now.timeIntervalSince(live.readAt) < Self.liveLimitsMaxAge {
            snapshot.fiveHourLimit = live.fiveHour.current(at: now)
            snapshot.weeklyLimit = live.weekly.current(at: now)
        }
        self.snapshot = snapshot
        weekEndReminder.check(snapshot.weeklyLimit, at: now)
    }
}

/// On the last day of the plan's week, a banner every hour from 9:00 until the weekly limit
/// resets, while some of it is left: what isn't used by then is gone. When the week resets
/// before 9:00, the reminders start at 9:00 the day before.
///
/// It's checked on every scan (every few seconds), so an hour the Mac slept through is reminded
/// about once it wakes, and the next hour on the hour.
final class ClaudeWeekEndReminder {
    private static let firstHour = 9
    /// With less of the week left than this (in percent) there's nothing worth using up.
    private static let minimumLeft = 1.0
    /// The start of the hour last reminded about, so a relaunch doesn't remind twice in an hour.
    private static let lastHourKey = "claudeWeekEndReminderHour"

    /// The reminder kept in the Alerts tab during a Focus, replaced by the next one.
    private var keptNotificationID: UUID?

    func check(_ weekly: ClaudeRateLimit?, at now: Date) {
        let calendar = Calendar.current
        guard let weekly, let resetsAt = weekly.resetsAt, now < resetsAt,
              100 - weekly.usedPercentage >= Self.minimumLeft,
              let start = Self.firstReminder(before: resetsAt, calendar: calendar), start <= now,
              let hour = calendar.dateInterval(of: .hour, for: now)?.start,
              UserDefaults.standard.double(forKey: Self.lastHourKey) != hour.timeIntervalSince1970 else { return }
        UserDefaults.standard.set(hour.timeIntervalSince1970, forKey: Self.lastHourKey)
        remind(weekly, resetsAt: resetsAt, calendar: calendar)
    }

    /// 9:00 on the day the week resets, or on the day before when it resets earlier than that.
    static func firstReminder(before resetsAt: Date, calendar: Calendar) -> Date? {
        guard let sameDay = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: resetsAt) else { return nil }
        return sameDay < resetsAt ? sameDay : calendar.date(byAdding: .day, value: -1, to: sameDay)
    }

    private func remind(_ weekly: ClaudeRateLimit, resetsAt: Date, calendar: Calendar) {
        let time = resetsAt.formatted(.dateTime.hour().minute())
        let when = calendar.isDateInToday(resetsAt) ? "at \(time)" : "tomorrow at \(time)"
        let left = Int((weekly.remainingFraction * 100).rounded())
        let notification = AppNotification(
            type: .claude,
            title: "Weekly limit resets \(when)",
            body: "\(left)% left · use it up before then",
            appName: "Claude",
            progress: weekly.remainingFraction,
            symbol: "hourglass"
        )

        let notificationManager = NotificationManager.shared
        if let keptNotificationID {
            notificationManager.dismiss(id: keptNotificationID)
        }
        // During a Focus there's no banner, so the reminder waits in the Alerts tab.
        let keepInFeed = FocusStatus.isActive
        keptNotificationID = keepInFeed ? notification.id : nil
        notificationManager.postActivity(notification, keepInFeed: keepInFeed)
    }
}

/// The plan's 5-hour and weekly limits from Anthropic's usage endpoint, the one Claude Code's
/// /usage reads, so they're right however Claude Code is used (terminal, desktop app, IDE).
///
/// It signs in with Claude Code's own token from the login keychain, read through `security` the
/// way Claude Code reads it, and sends it to api.anthropic.com only. The token is never logged or
/// kept, and never refreshed here: Claude Code refreshes it, and an expired one is skipped.
/// The endpoint isn't documented, so any answer it doesn't understand counts as no limits.
nonisolated enum ClaudePlanUsage {
    struct Limits: Sendable {
        let fiveHour: ClaudeRateLimit
        let weekly: ClaudeRateLimit
        let readAt: Date
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "ClaudeUsage")

    static func fetch() async -> Limits? {
        guard let token = await accessToken() else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DynamicIsland", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            log.info("Usage: no answer")
            return nil
        }
        guard status == 200 else {
            log.info("Usage: HTTP \(status, privacy: .public)")
            return nil
        }
        guard let limits = parse(data, readAt: Date()) else {
            log.info("Usage: answer not understood")
            return nil
        }
        log.info("Usage: 5-hour \(limits.fiveHour.usedPercentage, privacy: .public)%, week \(limits.weekly.usedPercentage, privacy: .public)%")
        return limits
    }

    /// `{"five_hour": {"utilization": 24.0, "resets_at": "2026-11-06T05:00:00.123+00:00"}, "seven_day": {…}}`,
    /// utilization in percent. A window that's null or left out has nothing used yet.
    static func parse(_ data: Data, readAt: Date) -> Limits? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("five_hour") || object.keys.contains("seven_day") else { return nil }

        func window(_ key: String) -> ClaudeRateLimit {
            guard let window = object[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else {
                return ClaudeRateLimit(usedPercentage: 0, resetsAt: nil)
            }
            return ClaudeRateLimit(usedPercentage: min(max(used, 0), 100), resetsAt: date(window["resets_at"]))
        }
        return Limits(fiveHour: window("five_hour"), weekly: window("seven_day"), readAt: readAt)
    }

    /// An ISO 8601 time, whose fraction of a second (up to microseconds) is dropped first.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string.replacing(/\.\d+/, with: ""))
    }

    /// Claude Code's sign-in token, unless it has expired.
    private static func accessToken() async -> String? {
        guard let data = await CommandRunner.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 60),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            log.info("Usage: no Claude Code sign-in in the keychain")
            return nil
        }
        // Milliseconds since 1970.
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiresAt / 1000) <= Date() {
            log.info("Usage: Claude Code's sign-in has expired; it renews when Claude Code runs")
            return nil
        }
        return token
    }
}

nonisolated struct ClaudeUsageSnapshot: Sendable {
    var todayTokens = 0
    var todayOutputTokens = 0
    var todayReplies = 0
    /// Total tokens per hour for the last 24 hours, oldest first.
    var hourlyTokens = [Int](repeating: 0, count: 24)
    var isWorking = false
    var fiveHourLimit: ClaudeRateLimit?
    var weeklyLimit: ClaudeRateLimit?
}

nonisolated struct ClaudeRateLimit: Sendable {
    var usedPercentage: Double
    var resetsAt: Date?

    var remainingFraction: Double {
        max(0, min(1, 1 - usedPercentage / 100))
    }

    /// Once the window has reset, none of it is used until the next read says otherwise.
    func current(at now: Date) -> ClaudeRateLimit {
        if let resetsAt, resetsAt <= now {
            return ClaudeRateLimit(usedPercentage: 0, resetsAt: nil)
        }
        return self
    }
}

/// Reads the transcripts incrementally off the main thread: each scan only parses lines added
/// since the previous one, because the logs grow by tens of megabytes a day.
actor ClaudeLogScanner {
    private nonisolated struct Reply {
        let date: Date
        let total: Int
        let output: Int
    }

    private nonisolated struct FileState {
        var offset: UInt64 = 0
        var remainder = Data()
    }

    private let projectsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    /// Rewritten by the status line script each time Claude Code refreshes its status line.
    private let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DynamicIsland/claude-status.json")
    private var files: [URL: FileState] = [:]
    /// Keyed by message id: Claude Code writes one line per content block, all with the same usage.
    private var replies: [String: Reply] = [:]
    private let dateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    /// A session counts as working if its transcript changed recently and doesn't end with a final reply.
    private static let workingWindow: TimeInterval = 180
    /// How long after a reply the status line may save its JSON before the limits count as out of date.
    private static let statusSlack: TimeInterval = 300

    func scan() -> ClaudeUsageSnapshot {
        let now = Date()
        let windowStart = now.addingTimeInterval(-24 * 3600)
        var isWorking = false

        for (url, modified) in transcripts(modifiedAfter: windowStart) {
            readNewLines(of: url)
            if !isWorking && now.timeIntervalSince(modified) < Self.workingWindow {
                isWorking = endsMidTurn(url)
            }
        }

        replies = replies.filter { $0.value.date >= windowStart }
        var snapshot = makeSnapshot(now: now, isWorking: isWorking)
        (snapshot.fiveHourLimit, snapshot.weeklyLimit) = rateLimits(now: now)
        return snapshot
    }

    /// Nil when the plan has no limits in the status JSON (only Pro and Max plans have them), or
    /// when the JSON is out of date. The script keeps the last known windows, so they stay visible
    /// between prompts.
    private func rateLimits(now: Date) -> (fiveHour: ClaudeRateLimit?, weekly: ClaudeRateLimit?) {
        guard let data = try? Data(contentsOf: statusURL),
              let saved = try? statusURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return (nil, nil) }
        // Only Claude Code in a terminal runs the status line; replies in the desktop app leave the
        // JSON behind, and its old numbers would show more of the limits left than there is.
        if let latestReply = replies.values.map(\.date).max(), latestReply > saved.addingTimeInterval(Self.statusSlack) {
            return (nil, nil)
        }

        func limit(_ key: String) -> ClaudeRateLimit {
            // A window Claude Code leaves out isn't in use yet.
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue else {
                return ClaudeRateLimit(usedPercentage: 0, resetsAt: nil)
            }
            let resetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // The file only changes while Claude Code runs; once a window has reset, none of it is used.
            if let resetsAt, resetsAt <= now {
                return ClaudeRateLimit(usedPercentage: 0, resetsAt: nil)
            }
            return ClaudeRateLimit(usedPercentage: used, resetsAt: resetsAt)
        }
        return (limit("five_hour"), limit("seven_day"))
    }

    private func makeSnapshot(now: Date, isWorking: Bool) -> ClaudeUsageSnapshot {
        var snapshot = ClaudeUsageSnapshot(isWorking: isWorking)
        let startOfToday = Calendar.current.startOfDay(for: now)

        for reply in replies.values {
            if reply.date >= startOfToday {
                snapshot.todayTokens += reply.total
                snapshot.todayOutputTokens += reply.output
                snapshot.todayReplies += 1
            }
            let hoursAgo = Int(now.timeIntervalSince(reply.date) / 3600)
            if (0..<24).contains(hoursAgo) {
                snapshot.hourlyTokens[23 - hoursAgo] += reply.total
            }
        }
        return snapshot
    }

    private func transcripts(modifiedAfter date: Date) -> [(URL, Date)] {
        guard let enumerator = FileManager.default.enumerator(at: projectsURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= date else { continue }
            result.append((url, modified))
        }
        return result
    }

    private func readNewLines(of url: URL) {
        var state = files[url] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset {
            state = FileState() // The file was replaced or truncated.
        }
        guard size > state.offset else { return }

        try? handle.seek(toOffset: state.offset)
        // Bounded chunks keep memory flat on the first scan, which reads tens of megabytes.
        while state.offset < size, let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            state.offset += UInt64(chunk.count)
            var data = state.remainder + chunk
            // Keep a trailing partial line for the next chunk or scan.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                state.remainder = data
                continue
            }
            state.remainder = Data(data[(lastNewline + 1)...])
            data = data[..<lastNewline]
            parseLines(data)
        }
        files[url] = state
    }

    private func parseLines(_ data: Data) {
        let usageMarker = Data("\"usage\"".utf8)
        // JSONSerialization autoreleases its objects; drain them per chunk instead of per scan.
        autoreleasepool {
            for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: usageMarker) != nil {
                parseReply(Data(line))
            }
        }
    }

    private func parseReply(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              message["model"] as? String != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = dateParser.date(from: timestamp) else { return }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        replies[id] = Reply(date: date, total: input + output + cacheWrite + cacheRead, output: output)
    }

    /// Whether the transcript's last turn entry is anything but a finished assistant reply
    /// (a prompt, a tool call or a tool result means Claude is still going).
    private func endsMidTurn(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailLength: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > tailLength ? size - tailLength : 0)
        guard let tail = try? handle.readToEnd() else { return false }

        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "assistant":
                let stopReason = (object["message"] as? [String: Any])?["stop_reason"] as? String
                return stopReason == "tool_use" || stopReason == nil
            case "user", "api-request":
                return true
            default:
                continue // Attachments, summaries and other bookkeeping entries.
            }
        }
        // The last line is larger than the tail we read; it was written recently, so assume working.
        return true
    }
}
