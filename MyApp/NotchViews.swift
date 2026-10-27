import SwiftUI
import AppKit

/// The island attached to the MacBook notch, modeled after NotchNook: notch-sized while idle,
/// growing wings for live activity, and opening into a wide panel with Nook / System tabs.
struct NotchIslandView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var claudeUsage: ClaudeUsageMonitor
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager

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
    }

    private var island: some View {
        let size = layout.isExpanded ? IslandLayout.notchExpandedSize : layout.notchCollapsedSize

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
            } else {
                collapsedBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        // Only the bottom corners are rounded, so it looks like the notch itself grew.
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: layout.isExpanded ? 24 : 10, bottomTrailingRadius: layout.isExpanded ? 24 : 10))
        .foregroundColor(.white)
    }

    private var hasActivity: Bool {
        spotifyManager.isPlaying || notificationManager.unreadCount > 0 || claudeUsage.snapshot.isWorking
    }

    /// Black bar around the notch with a "wing" on each side for status icons. The bar always has
    /// its full width; while idle the island is only notch-wide, so the wings are clipped away and
    /// slide into view as the island widens.
    ///
    /// Claude and music can be live at the same time: Claude takes the left wing and the music bars
    /// the right one, so both animations stay visible. Unread notifications come last.
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
                if spotifyManager.isPlaying {
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

// MARK: - Expanded Panel
private struct NotchExpandedView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var systemMonitor: SystemMonitor
    @EnvironmentObject var temperatureMonitor: TemperatureMonitor
    @EnvironmentObject var notificationManager: NotificationManager
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
                case .system:
                    HStack(alignment: .top, spacing: 20) {
                        StatsTabView(systemMonitor: systemMonitor, themeManager: themeManager)
                            .frame(width: 170)
                        TemperatureTabView(temperatureMonitor: temperatureMonitor, themeManager: themeManager)
                            .frame(width: 170)
                        ScrollView {
                            NotificationsTabView(notificationManager: notificationManager, themeManager: themeManager)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity)
        }
    }

    /// Tab pills on the left of the notch, settings on the right.
    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases, id: \.self) { tab in
                    Button(action: { layout.selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(layout.selectedTab == tab ? .white : .gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(layout.selectedTab == tab ? Color.white.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        Menu {
            Toggle("Open on Hover", isOn: $layout.openOnHover)
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
