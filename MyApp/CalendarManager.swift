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

    var timeRange: String {
        if isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

/// Events around today (the notch shows a one-week strip) from the user's calendars (EventKit).
class CalendarManager: ObservableObject {
    /// Events keyed by the start of their day, for `daysBefore` days before today to `daysAfter` after.
    @Published private(set) var eventsByDay: [Date: [CalendarEvent]] = [:]
    @Published private(set) var hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    static let daysBefore = 3
    static let daysAfter = 3

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?

    init() {
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
                    color: $0.calendar.color ?? .systemBlue
                )
            }
    }
}
