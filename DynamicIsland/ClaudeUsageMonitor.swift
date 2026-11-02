import Foundation
import Combine

/// Claude Code token usage read from its local transcripts (~/.claude/projects/**/*.jsonl),
/// plus whether a Claude Code session is working right now (for the notch live activity).
///
/// Plan limits come from the Claude Code status line: ~/.claude/dynamic-island-statusline.sh saves
/// the status JSON, whose `rate_limits` hold the 5-hour and weekly usage of a Pro or Max plan.
class ClaudeUsageMonitor: ObservableObject {
    @Published private(set) var snapshot = ClaudeUsageSnapshot()

    private let scanner = ClaudeLogScanner()
    private var scanTask: Task<Void, Never>?

    init() {
        scanTask = Task { [weak self, scanner] in
            while !Task.isCancelled {
                let snapshot = await scanner.scan()
                self?.snapshot = snapshot
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    deinit {
        scanTask?.cancel()
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

    /// Nil when the plan has no limits in the status JSON (only Pro and Max plans have them).
    /// The script keeps the last known windows, so they stay visible between prompts.
    private func rateLimits(now: Date) -> (fiveHour: ClaudeRateLimit?, weekly: ClaudeRateLimit?) {
        guard let data = try? Data(contentsOf: statusURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return (nil, nil) }

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
