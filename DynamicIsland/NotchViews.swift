import SwiftUI
import AppKit

/// The island attached to the MacBook notch, modeled after NotchNook: notch-sized while idle,
/// growing wings for live activity, dropping down with other apps' notifications, and opening
/// into a wide panel with Nook / Alerts / System tabs.
struct NotchIslandView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var claudeUsage: ClaudeUsageMonitor
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var calendarManager: CalendarManager
    @EnvironmentObject var timerManager: TimerManager
    @EnvironmentObject var hud: HUDMonitor

    var body: some View {
        // The island is an overlay on a flexible clear base, so its size never becomes the hosting
        // view's minimum size. Otherwise the spring's overshoot (island briefly larger than the
        // window) made AppKit resize the window mid-animation, looping layout until it crashed.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { island }
            .onChange(of: hasActivity, initial: true) { _, active in
                layout.setShowsWings(active)
            }
            .onChange(of: notificationManager.banner?.id) {
                layout.setShowsBanner(notificationManager.banner != nil)
            }
            // Initial too: after floating mode the level may have gone while this view was away.
            .onChange(of: showsHUD, initial: true) { _, shows in
                layout.setShowsHUD(shows)
            }
    }

    /// A banner isn't covered by the level: it would run out unseen underneath.
    private var showsHUD: Bool {
        hud.level != nil && notificationManager.banner == nil
    }

    private var island: some View {
        let size = layout.isExpanded ? IslandLayout.notchExpandedSize
            : layout.showsHUD ? layout.notchHUDSize
            : layout.showsBanner ? layout.notchBannerSize : layout.notchCollapsedSize

        return ZStack(alignment: .top) {
            if layout.isExpanded {
                NotchExpandedView()
                    .transition(.asymmetric(
                        // Content fades in just after the black shape starts growing out of the notch.
                        insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .top))
                            .animation(IslandLayout.expandAnimation.delay(0.08)),
                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                            .animation(.easeOut(duration: 0.15))
                    ))
            } else if layout.showsHUD, let level = hud.level {
                NotchHUDView(level: level)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            } else if layout.showsBanner, let banner = notificationManager.banner {
                NotchBannerView(notification: banner)
                    // The next banner in line fades in over this one.
                    .id(banner.id)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            } else {
                collapsedBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        // Only the bottom corners are rounded, so it looks like the notch itself grew.
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
        .foregroundColor(.white)
    }

    private var cornerRadius: CGFloat {
        layout.isExpanded ? 24 : layout.showsHUD ? 10 : layout.showsBanner ? 20 : 10
    }

    private var hasActivity: Bool {
        spotifyManager.isPlaying || notificationManager.unreadCount > 0 || claudeUsage.snapshot.isWorking
            || timerManager.isActive || calendarManager.upcomingMeeting != nil
    }

    /// The meeting's icon is on the left only when nothing else is live.
    private var leftWingShowsMeeting: Bool {
        !claudeUsage.snapshot.isWorking && !spotifyManager.isPlaying && !timerManager.isActive && calendarManager.upcomingMeeting != nil
    }

    /// Black bar around the notch with a "wing" on each side for status icons. The bar always has
    /// its full width; while idle the island is only notch-wide, so the wings are clipped away and
    /// slide into view as the island widens.
    ///
    /// Claude and music can be live at the same time: Claude takes the left wing and the music bars
    /// the right one, so both animations stay visible. A meeting's countdown, then a timer, take the
    /// right wing before anything else, since they're about time. Unread notifications come last.
    private var collapsedBar: some View {
        HStack(spacing: 0) {
            Group {
                if claudeUsage.snapshot.isWorking {
                    ClaudeWorkingIcon()
                } else if spotifyManager.isPlaying, let artwork = spotifyManager.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else if timerManager.isActive && !spotifyManager.isPlaying {
                    Image(systemName: "timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(timerColor)
                } else if leftWingShowsMeeting, let meeting = calendarManager.upcomingMeeting {
                    Image(systemName: meeting.joinURL == nil ? "calendar" : "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(meeting.color))
                } else {
                    // Music without album art yet, or only notifications.
                    Image(systemName: spotifyManager.isPlaying ? "music.note" : "bell.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(themeManager.currentTheme.accentColor))
                }
            }
            .frame(width: IslandLayout.notchWing)

            // The physical notch covers this part.
            Spacer(minLength: layout.notchSize.width)

            Group {
                if let meeting = calendarManager.upcomingMeeting {
                    MeetingCountdown(meeting: meeting, showsIcon: !leftWingShowsMeeting)
                } else if timerManager.isActive {
                    TimerCountdown(compact: true)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(timerColor)
                } else if spotifyManager.isPlaying {
                    EqualizerBars(color: themeManager.currentTheme.accentColor)
                        .frame(width: 18, height: 12)
                } else if claudeUsage.snapshot.isWorking {
                    ThinkingDots(color: claudeOrangeNS)
                        .frame(width: 24, height: 12)
                } else if notificationManager.unreadCount > 0 {
                    Badge(count: notificationManager.unreadCount)
                }
            }
            .frame(width: IslandLayout.notchWing)
        }
        .frame(width: layout.notchSize.width + IslandLayout.notchWing * 2, height: layout.notchSize.height)
        .opacity(layout.showsWings ? 1 : 0)
        .overlay(WindowDragArea(onClick: { layout.expand() }))
    }
}

// MARK: - Notification Banner
/// Another app's notification, or one of the island's own activities, below the notch. Clicking it
/// opens its link or its app. While the panel is open it shows inside it instead (`isInPanel`).
private struct NotchBannerView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager
    let notification: AppNotification
    var isInPanel = false

    private var appName: String {
        notification.appName ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            NotificationIcon(notification: notification, symbolSize: 20)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                if !appName.isEmpty && appName != notification.title {
                    Text(appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                }
                Text(notification.title)
                    .font(.system(size: 12, weight: .semibold))
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.75))
                }
                if let progress = notification.progress {
                    LevelBar(value: progress, color: notificationTint(notification.type, themeManager))
                        .frame(width: 140, height: 4)
                        .padding(.top, 3)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if let actionTitle = notification.actionTitle {
                Button(action: performAction) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.green)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(notification.url?.absoluteString ?? "")
            }
        }
        .padding(.horizontal, isInPanel ? 12 : 18)
        // The top of the island sits behind the physical notch.
        .padding(.top, isInPanel ? 8 : layout.notchSize.height + 4)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onHover { notificationManager.holdBanner($0) }
        .onTapGesture(perform: open)
    }

    private func open() {
        if notification.type == .poke {
            layout.selectedTab = .poke
            layout.expand()
        } else {
            notification.open()
        }
        notificationManager.dismissBanner()
    }

    private func performAction() {
        if let friendID = notification.pokeSenderID {
            PokeService.shared.poke(friendID, name: notification.pokeSenderName ?? "", confirmOnNotch: true)
        } else {
            notification.open()
        }
        notificationManager.dismissBanner()
    }
}

/// The app's icon for other apps' notifications, otherwise the notification's symbol.
private struct NotificationIcon: View {
    @EnvironmentObject var themeManager: ThemeManager
    let notification: AppNotification
    let symbolSize: CGFloat

    var body: some View {
        if notification.type == .app, let appURL = notification.appURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
        } else {
            Image(systemName: notification.icon)
                .font(.system(size: symbolSize))
                .foregroundColor(notificationTint(notification.type, themeManager))
                .symbolEffect(.wiggle, options: .repeat(3), isActive: notification.type == .poke)
        }
    }
}

private let timerColor = Color.orange
private let pokeColor = Color.pink

private func notificationTint(_ type: NotificationType, _ themeManager: ThemeManager) -> Color {
    switch type {
    case .claude: return claudeOrange
    case .meeting: return .red
    case .power: return .green
    case .audio: return .white
    case .timer: return timerColor
    case .poke: return pokeColor
    default: return Color(themeManager.currentTheme.accentColor)
    }
}

private extension AppNotification {
    var appURL: URL? {
        appBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Opens the notification's link (like a meeting's call), otherwise its app.
    func open() {
        if let url {
            NSWorkspace.shared.open(url)
        } else if let appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// A level from 0 to 1 as a filled capsule.
private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
    }
}

// MARK: - Volume and Brightness
/// The level in wider wings beside the notch, like the iPhone's Dynamic Island.
private struct NotchHUDView: View {
    @EnvironmentObject var layout: IslandLayout
    let level: HUDMonitor.Level

    private var shownValue: Double {
        level.isMuted ? 0 : min(max(level.value, 0), 1)
    }

    private var symbol: String {
        switch level.kind {
        case .volume:
            if level.isMuted || shownValue == 0 { return "speaker.slash.fill" }
            return shownValue < 0.34 ? "speaker.wave.1.fill" : shownValue < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness:
            return shownValue < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: IslandLayout.notchHUDWing)

            // The physical notch covers this part.
            Spacer(minLength: layout.notchSize.width)

            LevelBar(value: shownValue, color: .white)
                .frame(height: 5)
                .padding(.horizontal, 12)
                .frame(width: IslandLayout.notchHUDWing)
        }
        .frame(width: layout.notchHUDSize.width, height: layout.notchSize.height)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

// MARK: - Countdowns
/// Minutes until a meeting starts, beside the notch.
private struct MeetingCountdown: View {
    let meeting: CalendarEvent
    let showsIcon: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let untilStart = meeting.start.timeIntervalSince(context.date)
            HStack(spacing: 2) {
                if showsIcon {
                    Image(systemName: meeting.joinURL == nil ? "calendar" : "video.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(untilStart > 0 ? "\(Int((untilStart / 60).rounded(.up)))m" : "now")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(untilStart <= 60 ? .red : Color(meeting.color))
        }
    }
}

/// Time left on the timer, updated every second.
private struct TimerCountdown: View {
    @EnvironmentObject var timerManager: TimerManager
    /// Beside the notch an hour or more reads "1h05".
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatCountdown(timerManager.remaining(at: context.date), compact: compact))
                .monospacedDigit()
                .opacity(timerManager.isRunning ? 1 : 0.5)
        }
    }
}

/// 125 → "2:05"; 3900 → "1:05:00", or "1h05" when compact.
private func formatCountdown(_ seconds: TimeInterval, compact: Bool) -> String {
    let total = Int(seconds.rounded(.up))
    let hours = total / 3600
    let minutes = total % 3600 / 60
    if hours > 0 {
        return compact ? String(format: "%dh%02d", hours, minutes) : String(format: "%d:%02d:%02d", hours, minutes, total % 60)
    }
    return String(format: "%d:%02d", minutes, total % 60)
}

// MARK: - Expanded Panel
private struct NotchExpandedView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var systemMonitor: SystemMonitor
    @EnvironmentObject var temperatureMonitor: TemperatureMonitor
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: layout.notchSize.height)

            Group {
                switch layout.selectedTab {
                case .nook:
                    HStack(spacing: 16) {
                        MediaWidget()
                            .frame(width: 200, alignment: .leading)
                        separator
                        CalendarWidget()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        separator
                        ClaudeUsageWidget()
                            .frame(width: 112, alignment: .leading)
                    }
                case .alerts:
                    AlertsView()
                case .poke:
                    PokeView()
                case .timer:
                    TimerView()
                case .system:
                    HStack(alignment: .top, spacing: 20) {
                        StatsTabView(systemMonitor: systemMonitor, themeManager: themeManager)
                            .frame(width: 170)
                        TemperatureTabView(temperatureMonitor: temperatureMonitor, themeManager: themeManager)
                            .frame(width: 170)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            ZStack { bannerToast }
                .animation(.spring(duration: 0.3), value: notificationManager.banner?.id)
        }
    }

    /// A notification that arrives while the panel is open, like a friend's poke, shows over the
    /// bottom of the panel; the island can't drop down a banner then.
    @ViewBuilder
    private var bannerToast: some View {
        if let banner = notificationManager.banner, !banner.isPending {
            NotchBannerView(notification: banner, isInPanel: true)
                .frame(width: 380)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .padding(.bottom, 10)
                .id(banner.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Tab pills on the left of the notch, settings on the right. Only the selected tab shows its
    /// name, so all of them fit beside the notch.
    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases, id: \.self) { tab in
                    Button(action: { layout.selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .semibold))
                            if layout.selectedTab == tab {
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundColor(layout.selectedTab == tab ? .white : .gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(layout.selectedTab == tab ? Color.white.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tab.rawValue)
                }
            }
            .padding(.leading, 16)

            Spacer(minLength: layout.notchSize.width + 20)

            HStack(spacing: 12) {
                PinButton()
                SettingsMenu()
            }
            .padding(.trailing, 16)
        }
        // Without hover-to-open, clicking empty space in the bar (under the notch) closes it.
        .contentShape(Rectangle())
        .onTapGesture {
            if !layout.openOnHover {
                layout.collapse()
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

// MARK: - Alerts
/// Every notification: the app's own and other apps'. Each can be removed, or all at once.
private struct AlertsView: View {
    @EnvironmentObject var notificationManager: NotificationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(notificationManager.notifications.isEmpty ? "No notifications" : "\(notificationManager.notifications.count) notifications")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer()
                if !notificationManager.notifications.isEmpty {
                    Button("Clear All") {
                        withAnimation { notificationManager.clearAll() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                }
            }

            if notificationManager.notifications.isEmpty {
                Image(systemName: "bell.slash")
                    .font(.system(size: 22))
                    .foregroundColor(.gray.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(notificationManager.notifications) { notification in
                            AlertRow(notification: notification)
                                .transition(.opacity)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { notificationManager.markAllAsRead() }
        // New notifications arriving while the tab is open count as seen.
        .onChange(of: notificationManager.unreadCount) {
            notificationManager.markAllAsRead()
        }
    }
}

private struct AlertRow: View {
    @EnvironmentObject var notificationManager: NotificationManager
    let notification: AppNotification
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            NotificationIcon(notification: notification, symbolSize: 13)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(notification.title)
                    .font(.system(size: 11, weight: .semibold))
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            Text(notification.date, format: .dateTime.hour().minute())
                .font(.system(size: 10))
                .foregroundColor(.gray)

            Button {
                withAnimation { notificationManager.dismiss(id: notification.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(isHovered ? 0.12 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        // Clicking a notification from another app opens that app.
        .onTapGesture {
            notification.open()
        }
    }
}

// MARK: - Settings
/// Keeps the notch open while the pointer is elsewhere, until unpinned or closed.
private struct PinButton: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Button(action: { layout.staysOpen.toggle() }) {
            Image(systemName: layout.staysOpen ? "pin.fill" : "pin")
                .font(.system(size: 12))
                .rotationEffect(.degrees(layout.staysOpen ? 0 : 45))
                .foregroundColor(layout.staysOpen ? Color(themeManager.currentTheme.accentColor) : .gray)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layout.staysOpen ? "Unpin" : "Keep Open")
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var hud: HUDMonitor

    var body: some View {
        Menu {
            Toggle("Open on Hover", isOn: $layout.openOnHover)
            Toggle("Show Volume & Brightness", isOn: $hud.isEnabled)
            Toggle("Launch at Login", isOn: Binding(get: { LaunchAtLogin.isEnabled }, set: { LaunchAtLogin.isEnabled = $0 }))
            Picker("Theme", selection: Binding(get: { themeManager.currentPreset }, set: { themeManager.setTheme($0) })) {
                ForEach(ThemeManager.ThemePreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            Divider()
            Button("Detach from Notch") {
                layout.isPinnedToNotch = false
            }
            Button("Quit Dynamic Island") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(.gray)
    }
}

// MARK: - Timer
/// A ring with the time left, presets, and Pomodoro (focus, then a break).
private struct TimerView: View {
    @EnvironmentObject var timerManager: TimerManager
    @State private var choosingSound = false

    private static let presets = [1, 5, 10, 15, 30, 60]

    var body: some View {
        HStack(spacing: 24) {
            ring
                .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 10) {
                if choosingSound {
                    soundList
                } else {
                    if timerManager.isActive {
                        HStack(spacing: 8) {
                            if timerManager.isRinging {
                                pill("Stop", systemImage: "stop.fill", prominent: true, action: timerManager.stop)
                            } else {
                                if timerManager.isRunning {
                                    pill("Pause", systemImage: "pause.fill", action: timerManager.pause)
                                } else {
                                    pill("Resume", systemImage: "play.fill", prominent: true, action: timerManager.resume)
                                }
                                pill("+1 min", systemImage: "plus", action: timerManager.addMinute)
                                pill("Stop", systemImage: "stop.fill", action: timerManager.stop)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { minutes in
                            pill(minutes == 60 ? "1 h" : "\(minutes) m") { timerManager.start(minutes: minutes) }
                        }
                    }

                    HStack(spacing: 12) {
                        pill("Pomodoro \(TimerManager.focusMinutes) + \(TimerManager.restMinutes)", systemImage: "brain.head.profile", action: timerManager.startPomodoro)
                        Toggle("Turn On Focus", isOn: $timerManager.turnsOnFocus)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .help("During Pomodoro focus, runs the shortcuts “\(TimerManager.focusOnShortcut)” and “\(TimerManager.focusOffShortcut)”")
                    }

                    pill("Sound: \(soundLabel)", systemImage: "speaker.wave.2.fill") { choosingSound = true }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var soundLabel: String {
        timerManager.soundName.isEmpty ? "None" : TimerManager.displayName(timerManager.soundName)
    }

    /// Every sound with a play button to hear it and a Select button to save it.
    private var soundList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timer Sound")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer()
                pill("Done") { choosingSound = false }
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach([""] + TimerManager.tones, id: \.self) { name in
                        soundRow(name)
                    }
                }
            }
            .frame(height: 130)
        }
        .frame(width: 260)
    }

    private func soundRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Button { timerManager.preview(name) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(name.isEmpty)
            .opacity(name.isEmpty ? 0.3 : 1)

            Text(name.isEmpty ? "None" : TimerManager.displayName(name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            if timerManager.soundName == name {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(timerColor)
            } else {
                pill("Select") { timerManager.setSound(name) }
            }
        }
        .padding(.vertical, 2)
    }

    private var ring: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: timerManager.isActive ? 1 - timerManager.progress(at: context.date) : 0)
                    .stroke(timerColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: context.date)

                VStack(spacing: 1) {
                    Text(timerManager.isActive ? formatCountdown(timerManager.remaining(at: context.date), compact: false) : "0:00")
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .opacity(timerManager.isActive && !timerManager.isRunning ? 0.5 : 1)
                    Text(timerManager.isRinging ? "Time's Up" : timerManager.isActive ? timerManager.phase.title : "Timer")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private func pill(_ title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(prominent ? timerColor : Color.white.opacity(0.1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Media
private struct MediaWidget: View {
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var mediaControlManager: MediaControlManager

    private var hasTrack: Bool { spotifyManager.currentTrack != "No Track" }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                artwork
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Badge with the icon of the app that is playing, like NotchNook.
                if let icon = spotifyManager.sourceApp?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .offset(x: 6, y: 6)
                }
            }
            .onTapGesture {
                spotifyManager.sourceApp?.activate()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(hasTrack ? spotifyManager.currentTrack : "Not Playing")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Text(hasTrack ? spotifyManager.currentAlbum : "Spotify or Music")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                if hasTrack {
                    Text(spotifyManager.currentArtist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if hasTrack {
                    HStack(spacing: 16) {
                        controlButton("backward.fill", size: 11) { mediaControlManager.previousTrack() }
                        controlButton(spotifyManager.isPlaying ? "pause.fill" : "play.fill", size: 14) { mediaControlManager.playPause() }
                        controlButton("forward.fill", size: 11) { mediaControlManager.nextTrack() }
                    }
                }
            }
            .frame(height: 76)
        }
    }

    private var artwork: some View {
        Group {
            if let image = spotifyManager.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar
private struct CalendarWidget: View {
    @EnvironmentObject var calendarManager: CalendarManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// A one-week strip centered on today.
    private var days: [Date] {
        (-CalendarManager.daysBefore...CalendarManager.daysAfter).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: today)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(selectedDay, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 20, weight: .bold))
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                    }
                }
            }

            if calendarManager.hasAccess {
                eventsForSelectedDay
            } else {
                Button("Allow Calendar Access") {
                    Task { await calendarManager.requestAccess() }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let color: Color = isToday
            ? Color(themeManager.currentTheme.accentColor)
            : (calendar.isDateInWeekend(day) ? Color.red.opacity(0.75) : .gray)

        return VStack(spacing: 1) {
            Group {
                if isToday {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                } else {
                    Text(day, format: .dateTime.weekday(.narrow))
                }
            }
            .font(.system(size: 7.5, weight: .semibold))
            .textCase(.uppercase)

            Text(day, format: .dateTime.day(.twoDigits))
                .font(.system(size: isToday ? 15 : 12, weight: isToday ? .bold : .medium))
        }
        .foregroundColor(color)
        .frame(width: 24, height: 32)
        .background(isSelected && !isToday ? Color.white.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDay = day
        }
    }

    @ViewBuilder
    private var eventsForSelectedDay: some View {
        let events = calendarManager.events(on: selectedDay)
        if events.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                Text(Calendar.current.isDate(selectedDay, inSameDayAs: today) ? "Nothing for today" : "Nothing planned")
                    .font(.system(size: 11))
            }
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity)
        } else {
            EventList(events: events, limit: 2)
        }
    }
}

private struct EventList: View {
    let events: [CalendarEvent]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(events.prefix(limit)) { event in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(event.color))
                        .frame(width: 3, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        Text(event.timeRange)
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    if let joinURL = event.joinURL, event.end > Date() {
                        Spacer(minLength: 4)
                        Button("Join") {
                            NSWorkspace.shared.open(joinURL)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .clipShape(Capsule())
                        // Invitations come from anyone: show where the link goes before it's clicked.
                        .help(joinURL.absoluteString)
                    }
                }
            }
            if events.count > limit {
                Text("+\(events.count - limit) more")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Claude
/// Claude's brand orange.
private let claudeOrangeNS = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
private let claudeOrange = Color(nsColor: claudeOrangeNS)

/// Claude plan limits left (when the status line provides them) and today's Claude Code token
/// usage with a 24-hour sparkline, in place of NotchNook's Mirror.
private struct ClaudeUsageWidget: View {
    @EnvironmentObject var claudeUsage: ClaudeUsageMonitor

    var body: some View {
        let usage = claudeUsage.snapshot

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Group {
                    if usage.isWorking {
                        PulsingSymbol(systemName: "sparkle", color: claudeOrangeNS, pointSize: 10)
                    } else {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(claudeOrange)
                    }
                }
                .frame(width: 12, height: 12)
                Text(usage.isWorking ? "Working…" : "Claude Code")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(usage.isWorking ? claudeOrange : .gray)
            }

            if usage.fiveHourLimit != nil || usage.weeklyLimit != nil {
                limitsAndTokens(usage)
            } else {
                tokens(usage)
            }
        }
        .animation(.default, value: usage.todayTokens)
    }

    /// The limits take the room of the big token count, which shrinks to a footer.
    @ViewBuilder
    private func limitsAndTokens(_ usage: ClaudeUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let limit = usage.fiveHourLimit {
                RateLimitBar(title: "5-hour", limit: limit, showsWeekday: false)
            }
            if let limit = usage.weeklyLimit {
                RateLimitBar(title: "Week", limit: limit, showsWeekday: true)
            }
        }
        .padding(.top, 2)

        Sparkline(values: usage.hourlyTokens, color: claudeOrange, maxBarHeight: 14)
            .frame(height: 14)
            .padding(.top, 2)

        Text("\(formatTokens(usage.todayTokens)) tokens today")
            .font(.system(size: 9))
            .foregroundColor(.gray)
            .lineLimit(1)
    }

    @ViewBuilder
    private func tokens(_ usage: ClaudeUsageSnapshot) -> some View {
        Text(formatTokens(usage.todayTokens))
            .font(.system(size: 22, weight: .bold))
            .monospacedDigit()
            .contentTransition(.numericText())
        Text("tokens today")
            .font(.system(size: 9))
            .foregroundColor(.gray)

        Sparkline(values: usage.hourlyTokens, color: claudeOrange)
            .frame(height: 20)
            .padding(.vertical, 2)

        Text("\(usage.todayReplies) replies · \(formatTokens(usage.todayOutputTokens)) out")
            .font(.system(size: 9))
            .foregroundColor(.gray)
            .lineLimit(1)
    }
}

/// What's left of one plan usage window: a bar that empties as the limit is used up.
private struct RateLimitBar: View {
    let title: String
    let limit: ClaudeRateLimit
    let showsWeekday: Bool

    var body: some View {
        let remaining = limit.remainingFraction
        let isLow = remaining < 0.2

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer(minLength: 4)
                Text("\(Int((remaining * 100).rounded()))% left")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(isLow ? .red : nil)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(isLow ? Color.red : claudeOrange)
                        .frame(width: remaining > 0 ? max(5, proxy.size.width * remaining) : 0)
                }
            }
            .frame(height: 5)

            Group {
                if let resetsAt = limit.resetsAt {
                    Text("resets " + resetsAt.formatted(showsWeekday ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()))
                } else {
                    Text("not started")
                }
            }
            .font(.system(size: 8))
            .foregroundColor(.gray)
            .lineLimit(1)
        }
        .animation(.default, value: remaining)
    }
}

/// Bars for the last 24 hours, oldest on the left.
private struct Sparkline: View {
    let values: [Int]
    let color: Color
    var maxBarHeight: CGFloat = 20

    var body: some View {
        let maxValue = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(values.indices, id: \.self) { index in
                Capsule()
                    .fill(values[index] > 0 ? color.opacity(index == values.count - 1 ? 1 : 0.6) : Color.white.opacity(0.12))
                    .frame(height: max(2, CGFloat(values[index]) / CGFloat(maxValue) * maxBarHeight))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// 1234 → "1.2K", 1234567 → "1.2M".
private func formatTokens(_ value: Int) -> String {
    switch value {
    case 1_000_000_000...: return String(format: "%.1fB", Double(value) / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
    default: return "\(value)"
    }
}

/// Animated Claude mark for the collapsed notch while Claude Code is working.
private struct ClaudeWorkingIcon: View {
    var body: some View {
        PulsingSymbol(systemName: "sparkle", color: claudeOrangeNS, pointSize: 13)
            .frame(width: 20, height: 20)
    }
}

// MARK: - Poke
/// Friends who also run Dynamic Island: click one to poke their notch. Setting up takes the shared
/// Supabase project's URL and anon key, then your name; friends are added with their code.
private struct PokeView: View {
    @EnvironmentObject var poke: PokeService

    var body: some View {
        Group {
            switch poke.state {
            case .notConfigured:
                PokeSetupView()
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsName:
                PokeNameView()
            case .ready:
                PokeFriendsView()
            case .failed(let message):
                VStack(spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        PokePill(title: "Try Again", prominent: true, action: poke.connect)
                        PokePill(title: "Change Project", action: poke.disconnect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: poke.refreshFriends)
    }
}

private struct PokeSetupView: View {
    @EnvironmentObject var poke: PokeService
    @State private var projectURL = ""
    @State private var anonKey = ""

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Poke your friends")
                    .font(.system(size: 13, weight: .semibold))
                Text("Connect the Supabase project you share with them (run supabase/poke.sql there first). Everyone uses the same URL and anon key.")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 220, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                PokeTextField(placeholder: "Project URL (https://….supabase.co)", text: $projectURL)
                PokeTextField(placeholder: "Anon or publishable key", text: $anonKey)
                PokePill(title: "Connect", prominent: true) {
                    poke.configure(projectURL: projectURL, anonKey: anonKey)
                }
                .disabled(projectURL.isEmpty || anonKey.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PokeNameView: View {
    @EnvironmentObject var poke: PokeService
    @State private var name = NSFullUserName().components(separatedBy: " ").first ?? ""

    var body: some View {
        VStack(spacing: 8) {
            Text("What should friends see when you poke them?")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                PokeTextField(placeholder: "Your name", text: $name, onSubmit: save)
                    .frame(width: 200)
                PokePill(title: "Save", prominent: true, action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = poke.actionError {
                PokeError(message: error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        poke.setName(name)
    }
}

/// Your name and code, adding a friend and your friends on the left; on the right a message to the
/// friend picked on the left, sent with Enter.
private struct PokeFriendsView: View {
    @EnvironmentObject var poke: PokeService
    @State private var friendCode = ""
    @State private var message = ""
    @State private var copied = false
    @State private var selectedFriendID: UUID?
    @FocusState private var isMessageFocused: Bool

    /// The friend picked on the left, or the first one.
    private var selectedFriend: PokeService.Friend? {
        poke.friends.first { $0.id == selectedFriendID } ?? poke.friends.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let profile = poke.profile {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(poke.isListening ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                                .help(poke.isListening ? "Receiving pokes" : "Connecting…")
                            Text(profile.name)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(profile.friendCode, forType: .string)
                            copied = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(profile.friendCode)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                        .help("Your friend code: send it to a friend to add you")
                    }
                }

                HStack(spacing: 6) {
                    PokeTextField(placeholder: "Friend's code", text: $friendCode, onSubmit: addFriend)
                    PokePill(title: "Add", action: addFriend)
                        .disabled(friendCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if poke.friends.isEmpty {
                    Text("Add a friend with their code to poke them.")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(poke.friends) { friend in
                                FriendRow(friend: friend, isSelected: friend.id == selectedFriend?.id, isPoked: poke.justPoked == friend.id) {
                                    selectedFriendID = friend.id
                                    isMessageFocused = true
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(width: 190, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField(selectedFriend.map { "Message to \($0.name) (optional)" } ?? "Pick a friend on the left", text: $message)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .focused($isMessageFocused)
                        .onSubmit(send)
                        .disabled(selectedFriend == nil)
                    PokePill(title: "Poke", prominent: true, action: send)
                        .disabled(selectedFriend == nil)
                        .opacity(selectedFriend == nil ? 0.4 : 1)
                }

                if let friend = selectedFriend {
                    if poke.justPoked == friend.id {
                        Label("Poked \(friend.name)", systemImage: "hand.point.right.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(pokeColor)
                    } else {
                        Text("Press Enter to poke \(friend.name), with or without a message.")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }

                if let error = poke.actionError {
                    PokeError(message: error)
                }
            }
        }
    }

    private func send() {
        guard let friend = selectedFriend else { return }
        poke.poke(friend.id, name: friend.name, message: message)
        message = ""
    }

    private func addFriend() {
        poke.addFriend(code: friendCode)
        friendCode = ""
    }
}

/// A friend's name; clicking picks them to poke. Hovering shows a button to remove them.
private struct FriendRow: View {
    @EnvironmentObject var poke: PokeService
    let friend: PokeService.Friend
    let isSelected: Bool
    let isPoked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(friend.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isPoked {
                Image(systemName: "hand.point.right.fill")
                    .font(.system(size: 10))
                    .foregroundColor(pokeColor)
                    .symbolEffect(.wiggle, options: .nonRepeating, isActive: true)
            } else if isHovered {
                Button {
                    poke.removeFriend(friend)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("Remove \(friend.name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? pokeColor.opacity(0.35) : Color.white.opacity(isHovered ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
        .help("Poke \(friend.name)")
    }
}

private struct PokeTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onSubmit(onSubmit)
    }
}

private struct PokePill: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(prominent ? pokeColor : Color.white.opacity(0.1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PokeError: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundColor(.orange)
            .lineLimit(2)
    }
}
