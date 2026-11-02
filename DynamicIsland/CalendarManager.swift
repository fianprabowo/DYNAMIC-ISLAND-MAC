import AppKit
import Combine
import EventKit

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    /// The video call link (Zoom, Google Meet, Teams…) in the event's URL, location or notes.
    let joinURL: URL?
    let isDeclined: Bool

    var timeRange: String {
        if isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

/// Events around today (the notch shows a one-week strip) from the user's calendars (EventKit),
/// and the next meeting: counted down beside the notch, with a banner shortly before it starts.
class CalendarManager: ObservableObject {
    /// Events keyed by the start of their day, for `daysBefore` days before today to `daysAfter` after.
    @Published private(set) var eventsByDay: [Date: [CalendarEvent]] = [:]
    @Published private(set) var hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    /// A meeting starting within `countdownLead`, or one that started up to `countdownTail` ago.
    @Published private(set) var upcomingMeeting: CalendarEvent?

    static let daysBefore = 3
    static let daysAfter = 3
    static let countdownLead: TimeInterval = 10 * 60
    static let countdownTail: TimeInterval = 5 * 60
    static let reminderLead: TimeInterval = 5 * 60

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var meetingTask: Task<Void, Never>?
    /// Reminders already shown ("<event id>.soon" / ".start") and when their event starts.
    private var shownReminders: [String: Date] = [:]

    init() {
        meetingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkMeetings()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        changeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                self?.reload()
            }
        }
        // Periodic refresh also rolls "today" over at midnight.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        changeTask?.cancel()
        meetingTask?.cancel()
    }

    var canRequestAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    func requestAccess() async {
        if canRequestAccess {
            hasAccess = (try? await store.requestFullAccessToEvents()) ?? false
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            // Access was denied earlier; macOS only lets the user change it in System Settings.
            NSWorkspace.shared.open(url)
        }
        reload()
    }

    func events(on date: Date) -> [CalendarEvent] {
        eventsByDay[Calendar.current.startOfDay(for: date)] ?? []
    }

    func reload() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else {
            eventsByDay = [:]
            return
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        var byDay: [Date: [CalendarEvent]] = [:]
        for offset in -Self.daysBefore...Self.daysAfter {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            byDay[day] = events(from: day, to: nextDay)
        }
        eventsByDay = byDay
        checkMeetings()
    }

    /// Updates the countdown, and shows a banner 5 minutes before a meeting and as it starts.
    private func checkMeetings() {
        let now = Date()
        let candidates = [now, now.addingTimeInterval(Self.countdownLead)]
            .map { events(on: $0) }
            .reduce([], +)
            .filter { !$0.isAllDay && !$0.isDeclined }
        // The same event is in both days' lists when the lead time reaches past midnight.
        var seen = Set<String>()
        let meetings = candidates
            .filter { seen.insert($0.id).inserted }
            .filter { $0.start.timeIntervalSince(now) <= Self.countdownLead && now.timeIntervalSince($0.start) <= Self.countdownTail }
            .sorted { $0.start < $1.start }

        let next = meetings.first
        if next?.id != upcomingMeeting?.id || next?.start != upcomingMeeting?.start {
            upcomingMeeting = next
        }

        for meeting in meetings {
            let untilStart = meeting.start.timeIntervalSince(now)
            if untilStart > 0 && untilStart <= Self.reminderLead {
                remind(meeting, key: "soon", body: "In \(Int((untilStart / 60).rounded(.up))) min · \(meeting.timeRange)")
            } else if untilStart <= 0 && untilStart > -60 {
                remind(meeting, key: "start", body: "Starting now · \(meeting.timeRange)")
            }
        }
        shownReminders = shownReminders.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
    }

    private func remind(_ meeting: CalendarEvent, key: String, body: String) {
        let id = "\(meeting.id).\(key)"
        guard shownReminders[id] == nil else { return }
        shownReminders[id] = meeting.start
        // Clicking joins the call, or opens Calendar when there is no link.
        let notification = AppNotification(
            type: .meeting,
            title: meeting.title,
            body: body,
            appName: "Calendar",
            appBundleID: "com.apple.iCal",
            url: meeting.joinURL,
            actionTitle: meeting.joinURL == nil ? nil : "Join"
        )
        // During a Focus there's no banner, so the reminder waits in the Alerts tab.
        NotificationManager.shared.postActivity(notification, keepInFeed: FocusStatus.isActive)
    }

    private func events(from start: Date, to end: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map {
                CalendarEvent(
                    id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)",
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    color: $0.calendar.color ?? .systemBlue,
                    joinURL: Self.joinURL(of: $0),
                    isDeclined: $0.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
                )
            }
    }

    /// Hosts of video call services; subdomains count too (like company.zoom.us).
    private static let meetingHosts = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "webex.com", "facetime.apple.com", "whereby.com", "gotomeeting.com", "meet.jit.si", "chime.aws"]
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func joinURL(of event: EKEvent) -> URL? {
        for text in [event.url?.absoluteString, event.location, event.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkDetector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, url.scheme == "https" || url.scheme == "http",
                      let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }
}
