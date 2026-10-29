import AppKit
import Combine

/// A countdown on the notch: a plain timer, or Pomodoro (focus, then a short break that starts on
/// its own). When it ends, a sound plays and a banner shows, even during a Focus.
///
/// Pomodoro can also turn a Focus on for the focus part. macOS has no API for that, so it runs two
/// shortcuts the user makes in the Shortcuts app with the "Set Focus" action (see the README).
class TimerManager: ObservableObject {
    enum Phase {
        case timer, focus, rest

        var title: String {
            switch self {
            case .timer: return "Timer"
            case .focus: return "Focus"
            case .rest: return "Break"
            }
        }
    }

    @Published private(set) var phase: Phase = .timer
    /// When the running countdown ends; nil while paused or stopped.
    @Published private(set) var endDate: Date?
    /// Time left while paused.
    @Published private(set) var pausedRemaining: TimeInterval?
    /// Length of the current countdown, for the progress ring.
    @Published private(set) var duration: TimeInterval = 0
    @Published var turnsOnFocus: Bool {
        didSet {
            UserDefaults.standard.set(turnsOnFocus, forKey: Self.turnsOnFocusKey)
            if turnsOnFocus {
                Task { await checkFocusShortcuts() }
            }
        }
    }

    static let focusMinutes = 25
    static let restMinutes = 5
    static let focusOnShortcut = "Dynamic Island Focus On"
    static let focusOffShortcut = "Dynamic Island Focus Off"
    private static let turnsOnFocusKey = "timerTurnsOnFocus"

    private let notificationManager: NotificationManager
    private var finishTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
        turnsOnFocus = UserDefaults.standard.bool(forKey: Self.turnsOnFocusKey)
    }

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isRunning: Bool { endDate != nil }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate {
            return max(0, endDate.timeIntervalSince(date))
        }
        return pausedRemaining ?? 0
    }

    /// 0 at the start, 1 when the countdown ends.
    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    func start(minutes: Int) {
        begin(.timer, seconds: TimeInterval(minutes * 60))
    }

    func startPomodoro() {
        begin(.focus, seconds: TimeInterval(Self.focusMinutes * 60))
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        finishTask?.cancel()
    }

    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        run(until: Date().addingTimeInterval(pausedRemaining))
    }

    func addMinute() {
        guard isActive else { return }
        duration += 60
        if let endDate {
            run(until: endDate.addingTimeInterval(60))
        } else if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + 60
        }
    }

    func stop() {
        if phase == .focus {
            setFocus(false)
        }
        finishTask?.cancel()
        endDate = nil
        pausedRemaining = nil
        duration = 0
        phase = .timer
    }

    private func begin(_ newPhase: Phase, seconds: TimeInterval) {
        if phase == .focus && newPhase != .focus {
            setFocus(false)
        }
        phase = newPhase
        duration = seconds
        pausedRemaining = nil
        if newPhase == .focus {
            setFocus(true)
        }
        run(until: Date().addingTimeInterval(seconds))
    }

    private func run(until date: Date) {
        endDate = date
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        let finished = phase
        let minutes = Int((duration / 60).rounded())
        NSSound(named: "Glass")?.play()

        switch finished {
        case .timer:
            stop()
            announce("Timer Done", "\(minutes) min timer")
        case .focus:
            // Also turns the Focus off.
            begin(.rest, seconds: TimeInterval(Self.restMinutes * 60))
            announce("Focus Done", "Time for a \(Self.restMinutes)-minute break")
        case .rest:
            stop()
            announce("Break Over", "Ready for the next focus session")
        }
    }

    private func announce(_ title: String, _ body: String) {
        notificationManager.postActivity(AppNotification(type: .timer, title: title, body: body), duringFocus: true)
    }

    private func setFocus(_ on: Bool) {
        guard turnsOnFocus else { return }
        let shortcut = on ? Self.focusOnShortcut : Self.focusOffShortcut
        // One at a time: a quick Stop after starting must not turn the Focus off before it's on.
        let previous = focusTask
        focusTask = Task {
            await previous?.value
            await CommandRunner.run("/usr/bin/shortcuts", ["run", shortcut])
        }
    }

    /// Turns the Focus off before the app quits in the middle of Pomodoro focus.
    func prepareForQuit() {
        guard turnsOnFocus, isActive, phase == .focus else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", Self.focusOffShortcut]
        try? process.run()
        process.waitUntilExit()
    }

    /// Tells the user which shortcuts to make when they turn the option on.
    private func checkFocusShortcuts() async {
        guard let data = await CommandRunner.run("/usr/bin/shortcuts", ["list"]),
              let list = String(data: data, encoding: .utf8) else { return }
        let names = Set(list.split(separator: "\n").map { String($0) })
        let missing = [Self.focusOnShortcut, Self.focusOffShortcut].filter { !names.contains($0) }
        guard !missing.isEmpty else { return }
        notificationManager.post(
            .system,
            title: "Focus Shortcuts Missing",
            body: "In Shortcuts, make " + missing.map { "“\($0)”" }.joined(separator: " and ") + " with the Set Focus action."
        )
    }
}
