import SwiftUI
import AppKit

/// The island attached to the MacBook notch, modeled after NotchNook: notch-sized while idle,
/// growing wings for live activity, dropping down with other apps' notifications, and opening
/// into a wide panel with Nook / Alerts / System tabs.
struct NotchIslandView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var meet: MeetController
    @EnvironmentObject var claudeUsage: ClaudeUsageMonitor
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var calendarManager: CalendarManager
    @EnvironmentObject var timerManager: TimerManager
    @EnvironmentObject var hud: HUDMonitor
    @EnvironmentObject var vpnManager: VPNManager
    /// Shakes of the island for friends' pokes; each poke adds one.
    @State private var pokeShakes: CGFloat = 0
    /// A notification came in: the island squishes for a moment.
    @State private var isSquished = false

    var body: some View {
        // The island is an overlay on a flexible clear base, so its size never becomes the hosting
        // view's minimum size. Otherwise the spring's overshoot (island briefly larger than the
        // window) made AppKit resize the window mid-animation, looping layout until it crashed.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                island
                    .modifier(ShakeEffect(shakes: pokeShakes))
                    .scaleEffect(x: isSquished ? 0.93 : 1, y: 1, anchor: .top)
            }
            // The eyes live in the wings, so with them on the wings stay out.
            .onChange(of: hasActivity || layout.showsEyes, initial: true) { _, show in
                layout.setShowsWings(show)
            }
            .onChange(of: notificationManager.banner?.id) {
                layout.setShowsBanner(notificationManager.banner != nil)
                if layout.showsEyes, notificationManager.banner?.pokeSenderID != nil {
                    FaceMood.shared.surprise()
                }
                if layout.pokeEffects, let banner = notificationManager.banner, banner.pokeSenderID != nil {
                    // After the banner has dropped down.
                    withAnimation(.linear(duration: 0.55).delay(0.25)) {
                        pokeShakes += 1
                    }
                }
            }
            .onChange(of: notificationManager.unreadCount) { previous, count in
                if layout.showsEyes && count > previous {
                    FaceMood.shared.lookAtBadge()
                }
                guard layout.bouncyOpen, count > previous, !layout.isExpanded, !layout.showsBanner else { return }
                withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) { isSquished = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.35)) { isSquished = false }
                }
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
        let size = layout.isExpanded ? layout.notchExpandedSize
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
        .clipShape(IslandShape(
            barHeight: layout.notchSize.height + 8,
            bodyWidth: layout.isExpanded && layout.panelStyle == .video ? IslandLayout.videoBodyWidth : size.width,
            bodyRadius: cornerRadius
        ))
        .foregroundColor(.white)
    }

    private var cornerRadius: CGFloat {
        layout.isExpanded ? 24 : layout.showsHUD ? 10 : layout.showsBanner ? 20 : 10
    }

    private var hasActivity: Bool {
        spotifyManager.isPlaying || notificationManager.unreadCount > 0 || claudeUsage.snapshot.isWorking
            || timerManager.isActive || calendarManager.upcomingMeeting != nil || vpnManager.isConnected || isInMeet
    }

    private var isInMeet: Bool {
        meet.meeting?.isInCall == true
    }

    /// Nothing running: no music, Claude, timer, meeting, VPN or call. Unread notifications don't
    /// count; they only show their number.
    private var isStandingBy: Bool {
        !(spotifyManager.isPlaying || claudeUsage.snapshot.isWorking || timerManager.isActive
          || calendarManager.upcomingMeeting != nil || vpnManager.isConnected || isInMeet)
    }

    /// The face peeks out of the left wing while standing by, in place of the bell; anything
    /// running takes its place.
    private var showsFace: Bool {
        layout.showsEyes && isStandingBy
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
    /// A Google Meet call comes before everything: a camera on the left (a crossed-out microphone
    /// while muted), how long it has run on the right.
    private var collapsedBar: some View {
        HStack(spacing: 0) {
            Group {
                if showsFace {
                    NotchEyes()
                } else if isInMeet {
                    Image(systemName: meet.meeting?.isMicrophoneOn == false ? "mic.slash.fill" : "video.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(meet.meeting?.isMicrophoneOn == false ? .red : .green)
                } else if claudeUsage.snapshot.isWorking {
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
                } else if !spotifyManager.isPlaying && notificationManager.unreadCount == 0 && vpnManager.isConnected {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vpnColor)
                        .help("VPN connected")
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
                if isInMeet, let startedAt = meet.callStartedAt {
                    CallDuration(since: startedAt)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                } else if let meeting = calendarManager.upcomingMeeting {
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
/// A friend's poke is answered right on the banner: Reply turns it into a message field.
private struct NotchBannerView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.controlActiveState) private var controlActiveState
    let notification: AppNotification
    var isInPanel = false
    @State private var isReplying = false
    @State private var reply = ""
    @FocusState private var isReplyFocused: Bool

    private var appName: String {
        notification.appName ?? ""
    }

    /// A friend's poke, not the notch confirming one of yours.
    private var isFriendsPoke: Bool {
        notification.pokeSenderID != nil
    }

    var body: some View {
        Group {
            if isReplying {
                replyRow
            } else {
                notificationRow
            }
        }
        .padding(.horizontal, isInPanel ? 12 : 18)
        // The top of the island sits behind the physical notch.
        .padding(.top, isInPanel ? 8 : layout.notchSize.height + 4)
        .padding(.bottom, 8)
        // The poke's little weather, behind the text and buttons and as big as the banner. It's
        // faint (see PokeSkyEffect), since it still shows through Reply's see-through background.
        .background {
            if isFriendsPoke && layout.pokeEffects {
                PokeSkyEffect()
            }
        }
        .contentShape(Rectangle())
        // While replying the banner stays wherever the pointer goes.
        .onHover { hovering in
            if !isReplying {
                notificationManager.holdBanner(hovering)
            }
        }
        .onTapGesture {
            if !isReplying {
                open()
            }
        }
        // Clicking elsewhere before typing anything lets the banner go.
        .onChange(of: controlActiveState) { previous, state in
            if previous == .key && state != .key && reply.isEmpty {
                cancelReply()
            }
        }
    }

    private var notificationRow: some View {
        HStack(spacing: 10) {
            NotificationIcon(notification: notification, symbolSize: 20)
                .frame(width: 34, height: 34)
                .modifier(PokeHandEntrance(isActive: isFriendsPoke && layout.pokeEffects))

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

            if notification.pokeSenderID != nil {
                Button(action: startReply) {
                    Text("Reply")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Write \(senderName) a message")
            }

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
                .pointingHandCursor()
                .help(notification.url?.absoluteString ?? "")
            }

            // In the open panel the toast has it in its corner instead.
            if notification.type == .poke && !isInPanel {
                BannerCloseButton()
            }
        }
    }

    /// The poke being answered above a message field; Enter sends it, Escape cancels.
    private var replyRow: some View {
        HStack(spacing: 10) {
            NotificationIcon(notification: notification, symbolSize: 20)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(notification.body.isEmpty ? notification.title : "\(senderName): \(notification.body)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                TextField("Reply to \(senderName)", text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focused($isReplyFocused)
                    .onSubmit(sendReply)
                    .onExitCommand(perform: cancelReply)
            }

            Button(action: sendReply) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(pokeColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Send to \(senderName)")

            if !isInPanel {
                BannerCloseButton()
            }
        }
    }

    private var senderName: String {
        notification.pokeSenderName ?? "them"
    }

    /// A friend's poke is replied to on the banner; anything else opens.
    private func open() {
        if notification.pokeSenderID != nil {
            startReply()
        } else if notification.type == .poke {
            layout.selectedTab = .poke
            layout.expand()
            notificationManager.dismissBanner()
        } else {
            notification.open()
            notificationManager.dismissBanner()
        }
    }

    private func performAction() {
        if let friendID = notification.pokeSenderID {
            PokeService.shared.poke(friendID, name: senderName, confirmOnNotch: true)
        } else {
            notification.open()
        }
        notificationManager.dismissBanner()
    }

    private func startReply() {
        notificationManager.holdBanner(true)
        isReplying = true
        Task {
            // Once the field is on screen.
            try? await Task.sleep(for: .milliseconds(50))
            isReplyFocused = true
        }
    }

    private func sendReply() {
        guard let friendID = notification.pokeSenderID else { return }
        PokeService.shared.poke(friendID, name: senderName, message: reply, confirmOnNotch: true)
        notificationManager.dismissBanner()
    }

    private func cancelReply() {
        guard isReplying else { return }
        isReplying = false
        reply = ""
        notificationManager.holdBanner(false)
    }
}

/// Puts a poke's banner away at once; the poke stays in the Alerts tab. `compact` is the small one
/// in the corner of the toast in the open panel.
private struct BannerCloseButton: View {
    @EnvironmentObject var notificationManager: NotificationManager
    var compact = false

    var body: some View {
        Button {
            notificationManager.dismissBanner()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: compact ? 7 : 9, weight: .bold))
                .foregroundColor(.white.opacity(compact ? 0.9 : 0.7))
                .frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
                .background(Circle().fill(compact ? Color(white: 0.3) : Color.white.opacity(0.15)))
                .overlay(Circle().stroke(Color.black.opacity(compact ? 0.5 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Close")
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
private let vpnColor = Color.green

private func notificationTint(_ type: NotificationType, _ themeManager: ThemeManager) -> Color {
    switch type {
    case .claude: return claudeOrange
    case .meeting: return .red
    case .power: return .green
    case .audio: return .white
    case .timer: return timerColor
    case .poke: return pokeColor
    case .vpn: return vpnColor
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

/// The island's outline: a bar along the top as wide as the island, and a body below it. The body
/// is as wide as the island too, except in the YouTube video panel, where it narrows to the video
/// while the tab bar keeps its width. Only the bottom corners are rounded, so it looks like the
/// notch itself grew.
private struct IslandShape: Shape {
    var barHeight: CGFloat
    var bodyWidth: CGFloat
    var bodyRadius: CGFloat
    var barRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bodyWidth, bodyRadius) }
        set {
            bodyWidth = newValue.first
            bodyRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let width = min(bodyWidth, rect.width)
        var path = Path()
        if width < rect.width {
            let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(barHeight, rect.height))
            path.addPath(UnevenRoundedRectangle(bottomLeadingRadius: barRadius, bottomTrailingRadius: barRadius).path(in: bar))
        }
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        path.addPath(UnevenRoundedRectangle(bottomLeadingRadius: bodyRadius, bottomTrailingRadius: bodyRadius).path(in: body))
        return path
    }
}

// MARK: - Expanded Panel
private struct NotchExpandedView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var notificationManager: NotificationManager

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: layout.notchSize.height)

            Group {
                switch layout.selectedTab {
                case .nook:
                    NookView()
                case .media:
                    MediaTabView()
                case .alerts:
                    AlertsView()
                case .poke:
                    PokeView()
                case .vpn:
                    VPNView()
                case .timer:
                    TimerView()
                }
            }
            .padding(.horizontal, IslandLayout.expandedHorizontalPadding)
            .padding(.top, IslandLayout.expandedTopPadding)
            .padding(.bottom, IslandLayout.expandedBottomPadding)
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
                .overlay(alignment: .topTrailing) {
                    if banner.type == .poke {
                        BannerCloseButton(compact: true)
                            .offset(x: 5, y: -5)
                    }
                }
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
                ForEach(NotchTab.allCases.filter { !$0.isBesideSettings }, id: \.self, content: tabButton)
            }
            .padding(.leading, 16)

            Spacer(minLength: layout.notchSize.width + 20)

            HStack(spacing: 12) {
                ForEach(NotchTab.allCases.filter(\.isBesideSettings), id: \.self, content: tabButton)
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

    private func tabButton(_ tab: NotchTab) -> some View {
        Button(action: { layout.selectedTab = tab }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    // Beside the pin and the gear, a tab's icon on its own is as big as theirs.
                    .font(.system(size: tab.isBesideSettings && layout.selectedTab != tab ? 13 : 10, weight: .semibold))
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
        .pointingHandCursor()
        .help(tab.rawValue)
    }

}

// MARK: - VPN
/// Pritunl's profiles: each connects or disconnects with a click. A profile's PIN comes from
/// PRITUNL_PIN in the zsh config, or is typed for one connection.
private struct VPNView: View {
    @EnvironmentObject var vpn: VPNManager

    /// Square tiles side by side, as many to a row as fit, spread evenly across the width.
    static let tileSize: CGFloat = 112
    private let tileSpacing: CGFloat = 10

    private func columns(for width: CGFloat) -> [GridItem] {
        let fit = max(1, Int((width + tileSpacing) / (Self.tileSize + tileSpacing)))
        let count = min(max(vpn.profiles.count, 1), fit)
        return Array(repeating: GridItem(.flexible(), spacing: tileSpacing, alignment: .center), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !vpn.isInstalled {
                emptyMessage("Install the Pritunl client to connect to a VPN from here.")
            } else if vpn.profiles.isEmpty {
                emptyMessage("No profiles yet. Import one in the Pritunl app.")
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVGrid(columns: columns(for: geometry.size.width), spacing: tileSpacing) {
                            ForEach(vpn.profiles) { profile in
                                VPNProfileTile(profile: profile)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            if let error = vpn.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One profile as a square tile: clicking it connects, or disconnects while it's connected. A green
/// border shows it's connected, how long for underneath; the address it got shows on hover.
private struct VPNProfileTile: View {
    @EnvironmentObject var vpn: VPNManager
    let profile: VPNManager.Profile
    @State private var pin = ""
    @State private var isHovered = false
    @FocusState private var isPINFocused: Bool

    private var isBusy: Bool { vpn.busy.contains(profile.id) }
    private var isAskingPIN: Bool { vpn.askingPIN == profile.id }
    private var isDisconnecting: Bool { vpn.disconnecting.contains(profile.id) }
    private var isConnecting: Bool { !isDisconnecting && (profile.isConnecting || (isBusy && !profile.isConnected)) }

    /// Green while connected, orange while connecting, red while disconnecting, none when off.
    private var borderColor: Color {
        if isDisconnecting { return .red }
        if profile.isConnected { return vpnColor }
        return isConnecting ? Color.orange.opacity(0.7) : .clear
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: profile.isConnected ? "lock.shield.fill" : "lock.open")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isDisconnecting ? .red : profile.isConnected ? vpnColor : isConnecting ? .orange : .gray)
                .frame(height: 24)

            Text(profile.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if isAskingPIN {
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .focused($isPINFocused)
                    .onSubmit(submitPIN)
                    .onExitCommand { vpn.askingPIN = nil }
                    .onAppear { isPINFocused = true }
            } else if profile.isConnected {
                // Counts every second between Pritunl's reads, like Pritunl's own "Online For".
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatUptime(profile.uptime + Int(context.date.timeIntervalSince(vpn.refreshedAt))))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(vpnColor)
                        .monospacedDigit()
                }
            } else if isBusy || isConnecting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(height: 13)
            } else {
                Text("Off")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding(8)
        .frame(width: VPNView.tileSize, height: VPNView.tileSize)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isHovered ? 0.1 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.2), value: profile.isConnected)
        .animation(.easeInOut(duration: 0.15), value: isDisconnecting)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: toggle)
        .pointingHandCursor(!isAskingPIN && !isBusy)
        .onHover { isHovered = $0 }
        .help(help)
    }

    private var help: String {
        if profile.isConnected {
            let address = profile.clientAddress.isEmpty ? "" : " · \(profile.clientAddress)"
            return "\(profile.name)\(address)\nClick to disconnect"
        }
        return isConnecting ? "\(profile.name)\nConnecting…" : "\(profile.name)\nClick to connect"
    }

    private func toggle() {
        guard !isAskingPIN, !isBusy else { return }
        if profile.isActive {
            vpn.disconnect(profile)
        } else {
            vpn.connect(profile)
        }
    }

    private func submitPIN() {
        vpn.connect(profile, pin: pin)
        pin = ""
    }

    /// 45 → "45s", 601 → "10m 01s", 3930 → "1h 05m 30s".
    private func formatUptime(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let rest = seconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, rest)
        }
        return minutes > 0 ? String(format: "%dm %02ds", minutes, rest) : "\(rest)s"
    }
}

// MARK: - Pointing hand cursor
extension View {
    /// A pointing-hand cursor while the pointer is over the view, for buttons and other things to
    /// click; `active` false keeps the arrow, for something that can't be clicked right now.
    func pointingHandCursor(_ active: Bool = true) -> some View {
        modifier(PointingHandCursor(isActive: active))
    }
}

/// SwiftUI's own hover tells when the pointer is on the view: it knows what's clipped, scrolled away
/// or covered, and it notices a view appearing under a pointer that stays still. A disabled control
/// keeps the arrow.
private struct PointingHandCursor: ViewModifier {
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active = phase {
                    isHovering = true
                } else {
                    isHovering = false
                }
                PointingHandCoordinator.set(id, hovering: isHovering && isEnabled && isActive)
            }
            .onChange(of: isEnabled && isActive) { _, clickable in
                PointingHandCoordinator.set(id, hovering: isHovering && clickable)
            }
            .onDisappear {
                PointingHandCoordinator.set(id, hovering: false)
            }
    }
}

/// Shows the hand while any marked view is hovered, and puts the arrow back once none is.
///
/// The notch's app is rarely the active one when the pointer is on it. macOS ignores cursor changes
/// from an inactive app, so the window server's private "sets cursor in background" property is
/// turned on (looked up at run time, skipped if it's gone); and since the system may still put the
/// arrow back as the pointer moves, the hand is set again on every move while it's wanted.
enum PointingHandCoordinator {
    private static var hovered: Set<UUID> = []
    private static var showsHand = false
    private static var monitors: [Any] = []

    static func set(_ id: UUID, hovering: Bool) {
        if hovering {
            hovered.insert(id)
        } else {
            hovered.remove(id)
        }
        startIfNeeded()
        apply()
    }

    private static func apply() {
        if !hovered.isEmpty {
            NSCursor.pointingHand.set()
            showsHand = true
        } else if showsHand {
            NSCursor.arrow.set()
            showsHand = false
        }
    }

    private static func startIfNeeded() {
        guard monitors.isEmpty else { return }
        allowCursorWhileInactive()
        // Only does something while the hand is wanted; otherwise a move costs one check of a set.
        let reassert: () -> Void = {
            if !hovered.isEmpty {
                NSCursor.pointingHand.set()
            }
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated(reassert)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated(reassert)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private static func allowCursorWhileInactive() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let defaultSymbol = dlsym(everywhere, "_CGSDefaultConnection"),
              let setSymbol = dlsym(everywhere, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(defaultSymbol, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSymbol, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
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
                    .pointingHandCursor()
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
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var poke: PokeService
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
            .pointingHandCursor()
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(isHovered ? 0.12 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .pointingHandCursor()
        // Clicking a poke opens the chat with whoever sent it, where the pokes are, so they leave
        // the list; a notification from another app opens that app.
        .onTapGesture {
            if notification.type == .poke {
                if let sender = notification.pokeSenderID {
                    poke.selectedFriendID = sender
                }
                layout.selectedTab = .poke
                notificationManager.dismissAll(of: .poke)
            } else {
                notification.open()
            }
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
        .pointingHandCursor()
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
            Menu("Animations") {
                Toggle("Eyes Beside the Notch", isOn: $layout.showsEyes)
                Toggle("Poke Effects", isOn: $layout.pokeEffects)
                Toggle("Bouncy Opening", isOn: $layout.bouncyOpen)
            }
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
        .pointingHandCursor()
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
    private static let presetColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        HStack(spacing: 20) {
            ring
                .frame(width: 104, height: 104)

            if choosingSound {
                soundList
            } else {
                Group {
                    if timerManager.isActive {
                        activeControls
                    } else {
                        quickStart
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    pomodoroCard
                    soundButton
                }
                .frame(width: 196)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The presets as tiles; a tap starts a plain timer.
    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Quick Start")
            LazyVGrid(columns: Self.presetColumns, spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button { timerManager.start(minutes: minutes) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(minutes == 60 ? "1" : "\(minutes)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(minutes == 60 ? "hr" : "min")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    }
                    .buttonStyle(TimerCardStyle())
                    .pointingHandCursor()
                }
            }
        }
    }

    /// Pause, +1 min and Stop while a countdown runs; only Stop once it rings.
    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(statusTitle)
            Text(statusDetail)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            HStack(spacing: 14) {
                if timerManager.isRinging {
                    controlButton("Stop", systemImage: "stop.fill", prominent: true, action: timerManager.stop)
                } else {
                    if timerManager.isRunning {
                        controlButton("Pause", systemImage: "pause.fill", action: timerManager.pause)
                    } else {
                        controlButton("Resume", systemImage: "play.fill", prominent: true, action: timerManager.resume)
                    }
                    controlButton("+1 min", systemImage: "plus", action: timerManager.addMinute)
                    controlButton("Stop", systemImage: "stop.fill", action: timerManager.stop)
                }
            }
            .padding(.top, 6)
        }
    }

    private var statusTitle: String {
        if timerManager.isRinging { return "Time's Up" }
        let phase = timerManager.phase.title
        return timerManager.isRunning ? phase : "\(phase) · Paused"
    }

    private var statusDetail: String {
        if timerManager.isRinging { return "Stop the alarm when you're ready" }
        if let endDate = timerManager.endDate {
            return "Ends at \(endDate.formatted(date: .omitted, time: .shortened))"
        }
        return "\(formatCountdown(timerManager.remaining(), compact: false)) left"
    }

    private var pomodoroCard: some View {
        VStack(spacing: 4) {
            Button(action: timerManager.startPomodoro) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(timerColor)
                        .frame(width: 26, height: 26)
                        .background(timerColor.opacity(0.18))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pomodoro")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(TimerManager.focusMinutes) min focus · \(TimerManager.restMinutes) min break")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                }
                .padding(8)
            }
            .buttonStyle(TimerCardStyle())
            .pointingHandCursor()

            HStack(spacing: 6) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                Text("Turn On Focus")
                    .font(.system(size: 10))
                Spacer(minLength: 0)
                Toggle("Turn On Focus", isOn: $timerManager.turnsOnFocus)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .foregroundColor(.gray)
            .padding(.horizontal, 8)
            .help("During Pomodoro focus, runs the shortcuts “\(TimerManager.focusOnShortcut)” and “\(TimerManager.focusOffShortcut)”")
        }
    }

    private var soundButton: some View {
        Button { choosingSound = true } label: {
            HStack(spacing: 8) {
                Image(systemName: timerManager.soundName.isEmpty ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
                    .frame(width: 26)
                Text("Sound")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Spacer(minLength: 0)
                Text(soundLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .buttonStyle(TimerCardStyle())
        .pointingHandCursor()
    }

    private var soundLabel: String {
        timerManager.soundName.isEmpty ? "None" : TimerManager.displayName(timerManager.soundName)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundColor(.gray)
    }

    private func controlButton(_ title: String, systemImage: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(TimerCardStyle(prominent: prominent, cornerRadius: 20))
            .pointingHandCursor()
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.gray)
        }
    }

    /// Every sound with a play button to hear it and a Select button to save it.
    private var soundList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timer Sound")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer()
                if timerManager.isRinging {
                    pill("Stop", systemImage: "stop.fill", prominent: true, action: timerManager.stop)
                }
                pill("Done") {
                    timerManager.stopPreview()
                    choosingSound = false
                }
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach([""] + TimerManager.tones, id: \.self) { name in
                        soundRow(name)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func soundRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Button { timerManager.preview(name) } label: {
                Image(systemName: timerManager.previewingTone == name ? "stop.fill" : "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
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
                    .stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: ringFraction(at: context.date))
                    .stroke(
                        AngularGradient(colors: [timerColor.opacity(0.55), timerColor], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: timerColor.opacity(timerManager.isRunning || timerManager.isRinging ? 0.5 : 0), radius: 4)
                    .animation(.linear(duration: 1), value: context.date)

                VStack(spacing: 1) {
                    Text(timerManager.isActive ? formatCountdown(timerManager.remaining(at: context.date), compact: false) : "0:00")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .opacity(timerManager.isActive && !timerManager.isRunning && !timerManager.isRinging ? 0.5 : 1)
                    Text(timerManager.isRinging ? "Time's Up" : timerManager.isActive ? timerManager.phase.title : "Ready")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(timerManager.isRinging ? timerColor : .gray)
                }
            }
        }
    }

    /// Time left as a share of the countdown; a full ring while the alarm rings.
    private func ringFraction(at date: Date) -> Double {
        if timerManager.isRinging { return 1 }
        return timerManager.isActive ? 1 - timerManager.progress(at: date) : 0
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
        .pointingHandCursor()
    }
}

/// A rounded tile that lights up on hover and shrinks a little when pressed.
private struct TimerCardStyle: ButtonStyle {
    var prominent = false
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration, prominent: prominent, cornerRadius: cornerRadius)
    }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let cornerRadius: CGFloat
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundColor(.white)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Color.white.opacity(isHovering ? 0.14 : 0.05)))
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }

        private var fill: Color {
            if prominent {
                return timerColor.opacity(isHovering ? 1 : 0.85)
            }
            return Color.white.opacity(isHovering ? 0.14 : 0.07)
        }
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
            .pointingHandCursor()
            .onTapGesture {
                spotifyManager.revealSource()
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

                if hasTrack && spotifyManager.canControl {
                    HStack(spacing: 8) {
                        controlButton("backward.fill", size: 11) {
                            mediaControlManager.previousTrack()
                            spotifyManager.refreshSoon()
                        }
                        controlButton(spotifyManager.isPlaying ? "pause.fill" : "play.fill", size: 14) {
                            mediaControlManager.playPause()
                            spotifyManager.showPlaybackToggled()
                            spotifyManager.refreshSoon()
                        }
                        controlButton("forward.fill", size: 11) {
                            mediaControlManager.nextTrack()
                            spotifyManager.refreshSoon()
                        }
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
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaButtonStyle())
        .pointingHandCursor()
    }
}

/// Media buttons light up on hover and shrink a little when pressed, so a click shows.
private struct MediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.85 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

/// Elapsed and remaining time of the track; drag or click the bar to jump within the song.
private struct MediaProgressBar: View {
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var mediaControlManager: MediaControlManager
    var tint: Color = .white
    var showsTimes = true
    /// Where the bar is being dragged to, as a share of the track; nil when it isn't.
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        if spotifyManager.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let duration = spotifyManager.duration
                let fraction = dragFraction ?? min(spotifyManager.currentPosition(at: context.date) / duration, 1)
                let position = fraction * duration
                let isActive = isHovering || dragFraction != nil

                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(height: isActive ? 6 : 4)
                            Capsule()
                                .fill(tint)
                                .frame(width: geometry.size.width * fraction, height: isActive ? 6 : 4)
                            if isActive {
                                Circle()
                                    .fill(tint)
                                    .frame(width: 12, height: 12)
                                    .shadow(color: .black.opacity(0.4), radius: 2)
                                    .offset(x: geometry.size.width * fraction - 6)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragFraction = max(0, min(1, value.location.x / geometry.size.width))
                                }
                                .onEnded { value in
                                    let target = max(0, min(1, value.location.x / geometry.size.width)) * duration
                                    mediaControlManager.seek(to: target)
                                    spotifyManager.showPosition(target)
                                    dragFraction = nil
                                }
                        )
                        .onHover { isHovering = $0 }
                    }
                    .frame(height: 12)
                    .animation(.easeOut(duration: 0.12), value: isActive)

                    if showsTimes {
                        HStack {
                            Text(formatTrackTime(position))
                            Spacer()
                            Text("-" + formatTrackTime(duration - position))
                        }
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(dragFraction != nil ? .white : .gray)
                    }
                }
            }
        }
    }
}

private func formatTrackTime(_ seconds: TimeInterval) -> String {
    let total = seconds.isFinite ? Int(min(max(seconds, 0), 360_000)) : 0
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Spotify and Music show the player with lyrics; YouTube gets its own look around the video.
private struct MediaTabView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var spotifyManager: SpotifyManager

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                // The YouTube video panel is narrower; the video shows the switcher itself.
                if spotifyManager.availableSources.count > 1 && layout.panelStyle != .video {
                    SourceSwitcher()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if spotifyManager.sourceApp == .chrome {
            YouTubeMediaView()
        } else {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    MediaWidget()
                    MediaProgressBar()
                }
                .frame(width: 230, alignment: .leading)
                ColumnSeparator()
                LyricsView()
            }
        }
    }
}

private let youTubeRed = Color(red: 1, green: 0, blue: 0.2)

/// Small YouTube logo: a red rounded rectangle with a white play triangle.
private struct YouTubeLogo: View {
    var width: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: width / 5, style: .continuous)
            .fill(youTubeRed)
            .frame(width: width, height: width * 0.7)
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: width * 0.35))
                    .foregroundColor(.white)
            )
    }
}

/// Icons of the players that have something loaded; a click shows that player in the Media tab.
private struct SourceSwitcher: View {
    @EnvironmentObject var spotifyManager: SpotifyManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(spotifyManager.availableSources, id: \.self) { app in
                let isSelected = spotifyManager.sourceApp == app
                Button { spotifyManager.select(app) } label: {
                    icon(app)
                        .frame(width: 22, height: 22)
                        .opacity(isSelected ? 1 : 0.45)
                        .background(Circle().fill(Color.white.opacity(isSelected ? 0.15 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(app == .chrome ? "YouTube" : app.scriptName)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .animation(.easeOut(duration: 0.15), value: spotifyManager.sourceApp)
    }

    @ViewBuilder
    private func icon(_ app: MediaPlayerApp) -> some View {
        if app == .chrome {
            YouTubeLogo(width: 15)
        } else if let image = app.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

/// YouTube's own look. The whole video, 16:9 and centered, in a somewhat taller panel, with the title on top and a YouTube-style control bar below shown on hover and while paused; a click on
/// the picture plays or pauses.
/// When the video can't be shown, its thumbnail sits on the left with the title beside it.
private struct YouTubeMediaView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var mediaControlManager: MediaControlManager
    @State private var isBlocked = false
    @State private var isHovering = false

    private var showsVideo: Bool {
        spotifyManager.canControl && spotifyManager.youTubeVideoID != nil && !isBlocked
    }

    var body: some View {
        Group {
            if showsVideo {
                player
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    player
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    details
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onChange(of: spotifyManager.youTubeVideoID) {
            isBlocked = false
        }
        .onChange(of: showsVideo, initial: true) { _, shows in
            if shows {
                layout.setPanelStyle(.video)
            } else {
                layout.resetPanelStyle(from: .video)
            }
        }
        .onDisappear {
            layout.resetPanelStyle(from: .video)
        }
    }

    private var player: some View {
        ZStack(alignment: .bottom) {
            picture
            if showsVideo && (isHovering || !spotifyManager.isPlaying) {
                titleBar
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
            if spotifyManager.canControl && (isHovering || !spotifyManager.isPlaying) {
                controlBar
                    .transition(.opacity)
            }
            if showsVideo && spotifyManager.availableSources.count > 1 && (isHovering || !spotifyManager.isPlaying) {
                SourceSwitcher()
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: spotifyManager.isPlaying)
    }

    @ViewBuilder
    private var picture: some View {
        if spotifyManager.canControl, let videoID = spotifyManager.youTubeVideoID, !isBlocked {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                YouTubeMirrorView(
                    videoID: videoID,
                    position: spotifyManager.currentPosition(at: context.date),
                    isPlaying: spotifyManager.isPlaying,
                    onBlocked: { isBlocked = $0 }
                )
            }
            .overlay(Color.clear.contentShape(Rectangle()).onTapGesture(perform: togglePlayback))
        } else {
            ZStack {
                Color.black
                if let image = spotifyManager.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                if isBlocked {
                    VStack {
                        Text("This video can't play outside YouTube")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.75))
                            .clipShape(Capsule())
                            .padding(6)
                        Spacer()
                    }
                }
            }
            .pointingHandCursor()
            .onTapGesture { spotifyManager.revealSource() }
        }
    }

    /// Red scrubber on top, then play or pause, next and the time, like YouTube's own player.
    private var controlBar: some View {
        VStack(spacing: 2) {
            MediaProgressBar(tint: youTubeRed, showsTimes: false)
            HStack(spacing: 10) {
                barButton(spotifyManager.isPlaying ? "pause.fill" : "play.fill", help: spotifyManager.isPlaying ? "Pause" : "Play", action: togglePlayback)
                barButton("forward.end.fill", help: "Next") {
                    mediaControlManager.nextTrack()
                    spotifyManager.refreshSoon()
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("\(formatTrackTime(spotifyManager.currentPosition(at: context.date))) / \(formatTrackTime(spotifyManager.duration))")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
                barButton("arrow.up.forward.square", help: "Show in Chrome") { spotifyManager.revealSource() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }

    /// The title over the top of the video.
    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                YouTubeLogo(width: 16)
                Text(spotifyManager.currentTrack)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            Text(spotifyManager.currentArtist)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.leading, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .padding(.trailing, spotifyManager.availableSources.count > 1 ? 80 : 10)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                YouTubeLogo()
                Text("YouTube")
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.bottom, 4)

            Text(spotifyManager.currentTrack)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
            Text(spotifyManager.currentArtist)
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !spotifyManager.canControl {
                Text("To play the video here and control it, turn on View › Developer › Allow JavaScript from Apple Events in Chrome.")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func togglePlayback() {
        mediaControlManager.playPause()
        spotifyManager.showPlaybackToggled()
        spotifyManager.refreshSoon()
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaButtonStyle())
        .pointingHandCursor()
        .help(help)
    }
}

/// Lyrics of the playing track from LRCLIB, following the song line by line when they are timed.
private struct LyricsView: View {
    @EnvironmentObject var spotifyManager: SpotifyManager
    @State private var lyrics: Lyrics?
    @State private var loadState = LoadState.idle

    private enum LoadState {
        case idle, loading, loaded, failed
    }

    private var track: LyricsProvider.Track? {
        guard spotifyManager.currentTrack != "No Track", spotifyManager.duration > 0 else { return nil }
        return LyricsProvider.Track(
            title: spotifyManager.currentTrack,
            artist: spotifyManager.currentArtist,
            album: spotifyManager.currentAlbum,
            duration: spotifyManager.duration
        )
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: track) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            message("music.note", "Play a song to see its lyrics")
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .failed:
            message("wifi.exclamationmark", "Couldn't load lyrics")
        case .loaded:
            if let lyrics, lyrics.isInstrumental {
                message("pianokeys", "Instrumental")
            } else if let lyrics, !lyrics.syncedLines.isEmpty {
                SyncedLyricsView(lines: lyrics.syncedLines)
            } else if let text = lyrics?.plainText, !text.isEmpty {
                ScrollView(showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                message("text.badge.xmark", "No lyrics found")
            }
        }
    }

    private func load() async {
        lyrics = nil
        guard let track else {
            loadState = .idle
            return
        }
        loadState = .loading
        do {
            let result = try await LyricsProvider.lyrics(for: track)
            guard !Task.isCancelled else { return }
            lyrics = result
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }

    private func message(_ systemImage: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundColor(.gray)
    }
}

/// Timed lyrics with the current line large and centered; the list scrolls as the song plays.
private struct SyncedLyricsView: View {
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var mediaControlManager: MediaControlManager
    let lines: [Lyrics.Line]

    /// Shows each line a moment early, since the player's position is read every 1.5 seconds.
    private static let lead: TimeInterval = 0.3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let current = Lyrics(syncedLines: lines).lineIndex(at: spotifyManager.currentPosition(at: context.date) + Self.lead)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            Button {
                                mediaControlManager.seek(to: line.time)
                                spotifyManager.showPosition(line.time)
                            } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.system(size: line.id == current ? 15 : 12, weight: .bold))
                                    .foregroundColor(.white.opacity(opacity(of: line.id, current: current)))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(LyricLineStyle())
                            .pointingHandCursor()
                            .help("Play from here")
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 50)
                    .animation(.easeOut(duration: 0.25), value: current)
                }
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onAppear {
                    if let current { proxy.scrollTo(current, anchor: .center) }
                }
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private func opacity(of id: Int, current: Int?) -> Double {
        guard let current else { return 0.45 }
        if id == current { return 1 }
        return id < current ? 0.3 : 0.45
    }
}

/// A lyric line brightens on hover to show it can be clicked to play from there.
private struct LyricLineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(isHovering ? 0.08 : 0)))
                .brightness(isHovering ? 0.3 : 0)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { isHovering = $0 }
        }
    }
}

/// The thin line between columns in the Nook and Media tabs.
private struct ColumnSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 6)
    }
}

// MARK: - Nook
/// The calendar on the left, the picked meeting in the middle, and Claude usage on the right.
private struct NookView: View {
    @EnvironmentObject var calendarManager: CalendarManager
    @EnvironmentObject var meet: MeetController
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// The event clicked in the list; nil shows the meeting happening now or next.
    @State private var selectedEventID: String?
    /// The call shown big, in place of the calendar and Claude usage, after its expand button.
    @State private var isCallExpanded = false

    var body: some View {
        Group {
            if let meeting = meet.meeting, meeting.isInCall, isCallExpanded {
                MeetCallView(meeting: meeting, eventTitle: eventTitle(for: meeting)) {
                    isCallExpanded = false
                }
            } else {
                calendarAndUsage
            }
        }
        .onChange(of: meet.meeting?.isInCall == true) { _, isInCall in
            if !isInCall {
                isCallExpanded = false
            }
        }
    }

    private var calendarAndUsage: some View {
        let events = calendarManager.events(on: selectedDay)
        let shown = events.first { $0.id == selectedEventID } ?? focusEvent(in: events)

        return HStack(spacing: 14) {
            CalendarWidget(selectedDay: $selectedDay, highlightedEventID: shown?.id) { event in
                selectedEventID = event.id
            }
            .frame(width: 228, alignment: .leading)

            Group {
                // A Meet call shows here live; a meeting open in Chrome, not joined yet, turns the
                // card into its controller.
                if let meeting = meet.meeting, meeting.isInCall {
                    MeetLiveCard(meeting: meeting, eventTitle: eventTitle(for: meeting)) {
                        isCallExpanded = true
                    }
                } else if let meeting = meet.meeting {
                    MeetControlCard(meeting: meeting, eventTitle: eventTitle(for: meeting))
                } else {
                    MeetingCard(event: shown, hasEvents: !events.isEmpty, hasAccess: calendarManager.hasAccess)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ColumnSeparator()
            ClaudeUsageWidget()
                .frame(width: 140, alignment: .leading)
        }
        .onChange(of: selectedDay) {
            selectedEventID = nil
        }
    }

    /// Today's calendar event with the same Meet link, for a better name than the tab's.
    private func eventTitle(for meeting: MeetController.Meeting) -> String? {
        calendarManager.events(on: Date())
            .first { $0.joinURL.flatMap(MeetController.meetingCode(in:)) == meeting.code }?
            .title
    }

    /// Today: the meeting going on or the next one; another day: its first meeting.
    private func focusEvent(in events: [CalendarEvent]) -> CalendarEvent? {
        let meetings = events.filter { !$0.isAllDay && !$0.isDeclined }
        if Calendar.current.isDateInToday(selectedDay) {
            let now = Date()
            return meetings.first { $0.end > now } ?? meetings.last ?? events.first
        }
        return meetings.first ?? events.first
    }
}

/// A Google Meet tab in Chrome before joining: the microphone and camera to set up, and Join now.
/// A click on the name shows the tab.
private struct MeetControlCard: View {
    @EnvironmentObject var meet: MeetController
    let meeting: MeetController.Meeting
    /// The calendar event's name, when one has this meeting's link.
    let eventTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text(meeting.isScriptable ? "Ready to join" : "Google Meet")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
                Spacer(minLength: 0)
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }

            Button(action: meet.reveal) {
                Text(eventTitle ?? meeting.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Show the meeting in Chrome")

            Text(meeting.code)
                .font(.system(size: 9))
                .foregroundColor(.gray)

            Spacer(minLength: 4)

            if meeting.isScriptable {
                HStack(spacing: 8) {
                    MeetToggle(isOn: meeting.isMicrophoneOn, on: "mic.fill", off: "mic.slash.fill", name: "microphone", action: meet.toggleMicrophone)
                    MeetToggle(isOn: meeting.isCameraOn, on: "video.fill", off: "video.slash.fill", name: "camera", action: meet.toggleCamera)
                    if meeting.canJoin {
                        Button(action: meet.join) {
                            Text("Join now")
                                .font(.system(size: 11, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(Capsule().fill(Color.green))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            } else {
                Text("To control it here, turn on View › Developer › Allow JavaScript from Apple Events in this Chrome profile.")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// A Google Meet call in Chrome, live, between the calendar and Claude usage: the Chrome window's
/// picture (the shared screen and the cameras) with the name and length on top and the microphone,
/// camera and Leave below. The expand button, or a click on the picture, shows it bigger.
private struct MeetLiveCard: View {
    @EnvironmentObject var meet: MeetController
    let meeting: MeetController.Meeting
    let eventTitle: String?
    let onExpand: () -> Void
    @State private var problem: MeetWindowCapture.Problem?

    var body: some View {
        ZStack {
            Color.black
            MeetWindowView(tabTitle: meeting.tabTitle, browserBarHeight: meeting.browserBarHeight) { problem = $0 }
                .overlay(Color.clear.contentShape(Rectangle()).onTapGesture(perform: onExpand))
            if let problem {
                MeetCaptureNote(problem: problem, isCompact: true)
            }
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                controls
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(eventTitle ?? meeting.title)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 2)
            if let startedAt = meet.callStartedAt {
                CallDuration(since: startedAt)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MediaButtonStyle())
            .pointingHandCursor()
            .help("Show the call bigger")
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.top, 3)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if meeting.isScriptable {
                MeetToggle(isOn: meeting.isMicrophoneOn, on: "mic.fill", off: "mic.slash.fill", name: "microphone", action: meet.toggleMicrophone, size: 24)
                MeetToggle(isOn: meeting.isCameraOn, on: "video.fill", off: "video.slash.fill", name: "camera", action: meet.toggleCamera, size: 24)
                MeetLeaveButton(height: 24)
            }
            Spacer(minLength: 0)
            Button(action: meet.reveal) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MediaButtonStyle())
            .pointingHandCursor()
            .help("Show in Chrome")
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    }
}

/// A Google Meet call in Chrome, shown big after the live card's expand button: the Chrome window's
/// picture in the YouTube-sized panel, with the name, length and a button back to the Nook on top,
/// and the microphone, camera and Leave below on hover. A click on the picture shows the tab.
private struct MeetCallView: View {
    @EnvironmentObject var layout: IslandLayout
    @EnvironmentObject var meet: MeetController
    let meeting: MeetController.Meeting
    let eventTitle: String?
    let onCollapse: () -> Void
    @State private var problem: MeetWindowCapture.Problem?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            MeetWindowView(tabTitle: meeting.tabTitle, browserBarHeight: meeting.browserBarHeight) { problem = $0 }
                .overlay(Color.clear.contentShape(Rectangle()).onTapGesture(perform: meet.reveal))
            if let problem {
                MeetCaptureNote(problem: problem, isCompact: false)
            }
            titleBar
                .frame(maxHeight: .infinity, alignment: .top)
            if isHovering || problem != nil {
                controlBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { layout.setPanelStyle(.video) }
        .onDisappear { layout.resetPanelStyle(from: .video) }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(eventTitle ?? meeting.title)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
            if let startedAt = meet.callStartedAt {
                CallDuration(since: startedAt)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Button(action: onCollapse) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MediaButtonStyle())
            .pointingHandCursor()
            .help("Back to the calendar and Claude usage")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            if meeting.isScriptable {
                MeetToggle(isOn: meeting.isMicrophoneOn, on: "mic.fill", off: "mic.slash.fill", name: "microphone", action: meet.toggleMicrophone)
                MeetToggle(isOn: meeting.isCameraOn, on: "video.fill", off: "video.slash.fill", name: "camera", action: meet.toggleCamera)
                MeetLeaveButton(height: 28)
            }
            Spacer(minLength: 0)
            Button(action: meet.reveal) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MediaButtonStyle())
            .pointingHandCursor()
            .help("Show in Chrome")
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    }
}

/// Why the call's picture can't show, in place of it.
private struct MeetCaptureNote: View {
    let problem: MeetWindowCapture.Problem
    /// Shorter words for the Nook's card.
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 3 : 6) {
            switch problem {
            case .noPermission:
                Text(isCompact ? "To see the call here:" : "Allow Screen Recording for Dynamic Island to see the call here.")
                Button("Allow Screen Recording") {
                    // The first time this asks; after that macOS only offers System Settings.
                    if !CGRequestScreenCaptureAccess(),
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                .controlSize(isCompact ? .small : .regular)
            case .windowNotFound:
                Text(isCompact ? "Show the Meet tab in Chrome to see the call here." : "Show the Meet tab in its Chrome window (not minimized) to see the call here.")
            case .failed(let message):
                Text(isCompact ? "Couldn't show the call." : "Couldn't show the call: \(message)")
            }
        }
        .font(.system(size: isCompact ? 9 : 10, weight: .medium))
        .foregroundColor(.gray)
        .multilineTextAlignment(.center)
        .padding(.horizontal, isCompact ? 10 : 20)
    }
}

/// Meet's red Leave button.
private struct MeetLeaveButton: View {
    @EnvironmentObject var meet: MeetController
    let height: CGFloat

    var body: some View {
        Button(action: meet.leave) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: height * 0.43, weight: .bold))
                .frame(width: height * 1.55, height: height)
                .background(Capsule().fill(Color.red))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Leave the call")
    }
}

/// A round Meet button that is red while its device is off; hidden when Meet doesn't show it.
private struct MeetToggle: View {
    let isOn: Bool?
    let on: String
    let off: String
    let name: String
    let action: () -> Void
    var size: CGFloat = 28

    var body: some View {
        if let isOn {
            Button(action: action) {
                Image(systemName: isOn ? on : off)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(Circle().fill(isOn ? Color.white.opacity(0.14) : Color.red))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isOn ? "Turn off the \(name)" : "Turn on the \(name)")
        }
    }
}

/// How long a call has run, "4:05" or "1:02:10", ticking every second.
private struct CallDuration: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatCountdown(context.date.timeIntervalSince(since), compact: false))
                .monospacedDigit()
        }
    }
}

// MARK: - Calendar
private struct CalendarWidget: View {
    @EnvironmentObject var calendarManager: CalendarManager
    @EnvironmentObject var themeManager: ThemeManager

    @Binding var selectedDay: Date
    let highlightedEventID: String?
    let onSelectEvent: (CalendarEvent) -> Void

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// A one-week strip centered on today.
    private var days: [Date] {
        (-CalendarManager.daysBefore...CalendarManager.daysAfter).compactMap {
            Calendar.current.date(byAdding: .day, value: $0, to: today)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .pointingHandCursor()
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
            EventList(events: events, highlightedID: highlightedEventID, onSelect: onSelectEvent)
        }
    }
}

/// Every event of the day, scrolled to the one shown in the meeting card; a click shows another.
private struct EventList: View {
    let events: [CalendarEvent]
    let highlightedID: String?
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events) { event in
                        row(event)
                            .id(event.id)
                    }
                }
            }
            .onAppear {
                if let highlightedID { proxy.scrollTo(highlightedID, anchor: .top) }
            }
            .onChange(of: highlightedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func row(_ event: CalendarEvent) -> some View {
        let isHighlighted = event.id == highlightedID
        let isOver = event.end <= Date()

        return Button { onSelect(event) } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(event.color))
                    .frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 10, weight: .semibold))
                        .strikethrough(event.isDeclined)
                        .lineLimit(1)
                    Text(event.timeRange)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if event.joinURL != nil && !isOver {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .opacity(isOver && !isHighlighted ? 0.5 : 1)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(isHighlighted ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

/// The picked meeting, or the one happening now or next: when it is, where, and a big Join button
/// for its video call.
private struct MeetingCard: View {
    let event: CalendarEvent?
    let hasEvents: Bool
    let hasAccess: Bool

    var body: some View {
        Group {
            if let event {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    details(event, now: context.date)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.badge.checkmark")
                        .font(.system(size: 16))
                    Text(hasAccess ? (hasEvents ? "Pick a meeting" : "No meetings") : "Calendar is off")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func details(_ event: CalendarEvent, now: Date) -> some View {
        let status = status(of: event, now: now)
        let canJoin = event.joinURL != nil && event.end > now

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(status.text)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(status.color)
                    .lineLimit(1)
            }

            Text(event.title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(event.isAllDay ? "All day" : "\(event.timeRange) · \(duration(of: event))")
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(1)

            HStack(spacing: 4) {
                if let location = event.location {
                    Image(systemName: "mappin.and.ellipse")
                    Text(location)
                } else {
                    Circle()
                        .fill(Color(event.color))
                        .frame(width: 6, height: 6)
                    Text(event.calendarName)
                }
            }
            .font(.system(size: 9))
            .foregroundColor(.gray)
            .lineLimit(1)

            Spacer(minLength: 4)

            if canJoin, let url = event.joinURL {
                Button { join(url) } label: {
                    Label("Join \(service(of: url))", systemImage: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.green))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                // Invitations come from anyone: show where the link goes before it's clicked.
                .help(url.absoluteString)
            } else {
                Button(action: openCalendar) {
                    Label("Open in Calendar", systemImage: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func status(of event: CalendarEvent, now: Date) -> (text: String, color: Color) {
        if event.isDeclined { return ("Declined", .gray) }
        if event.isAllDay { return ("All day", .gray) }
        if event.end <= now { return ("Ended", .gray) }
        if event.start <= now {
            return ("Now · \(minutes(event.end.timeIntervalSince(now))) left", .green)
        }
        let untilStart = event.start.timeIntervalSince(now)
        if Calendar.current.isDateInToday(event.start) {
            return ("In \(minutes(untilStart))", untilStart <= 10 * 60 ? .orange : .blue)
        }
        if Calendar.current.isDateInTomorrow(event.start) {
            return ("Tomorrow", .blue)
        }
        return (event.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)), .gray)
    }

    /// "5 min", "1 h", "2 h 15 min".
    private func minutes(_ interval: TimeInterval) -> String {
        let total = max(1, Int((interval / 60).rounded(.up)))
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private func duration(of event: CalendarEvent) -> String {
        minutes(event.end.timeIntervalSince(event.start))
    }

    private func service(of url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoom.com") { return "Zoom" }
        if host == "meet.google.com" { return "Meet" }
        if host.hasPrefix("teams.") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        if host == "facetime.apple.com" { return "FaceTime" }
        return "Call"
    }

    /// Meet opens in Chrome, where this card then controls it; other calls open their app or browser.
    private func join(_ url: URL) {
        if MeetController.isMeetLink(url) {
            MeetController.open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
    @FocusState private var isMessageFocused: Bool

    /// The friend picked on the left, otherwise the first one.
    private var selectedFriend: PokeService.Friend? {
        guard let id = poke.selectedFriendID, let friend = poke.friends.first(where: { $0.id == id }) else { return poke.friends.first }
        return friend
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
                        .pointingHandCursor()
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
                                    poke.selectedFriendID = friend.id
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

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    TextField(selectedFriend.map { "Message to \($0.name) (optional)" } ?? "Pick a friend on the left", text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(2, reservesSpace: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .focused($isMessageFocused)
                        .onSubmit(send)
                        .disabled(selectedFriend == nil)

                    Button(action: send) {
                        VStack(spacing: 4) {
                            Image(systemName: "hand.point.right.fill")
                                .font(.system(size: 20))
                            Text("Poke")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(width: 84)
                        .frame(maxHeight: .infinity)
                        // Green from the click until Supabase has the poke.
                        .background(justPokedSelected ? Color.green : pokeColor)
                        .animation(.easeInOut(duration: 0.08), value: justPokedSelected)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(selectedFriend == nil)
                    .opacity(selectedFriend == nil ? 0.4 : 1)
                    .help(selectedFriend.map { "Poke \($0.name)" } ?? "")
                }
                .fixedSize(horizontal: false, vertical: true)

                if let error = poke.actionError {
                    PokeError(message: error)
                }

                if let friend = selectedFriend {
                    PokeChat(friend: friend)
                }
            }
        }
        .task(id: selectedFriend?.id) {
            if let id = selectedFriend?.id {
                await poke.loadHistory(with: id)
            }
        }
    }

    private var justPokedSelected: Bool {
        selectedFriend.map { poke.justPoked == $0.id } ?? false
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

/// The latest pokes between you and a friend, newest on top, like "jho: see you".
private struct PokeChat: View {
    @EnvironmentObject var poke: PokeService
    let friend: PokeService.Friend

    var body: some View {
        let pokes = poke.history[friend.id] ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(pokes) { item in
                    row(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .overlay {
            if pokes.isEmpty {
                Text("No pokes with \(friend.name) yet")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }

    private func row(_ item: PokeService.Poke) -> some View {
        let isMine = poke.isFromMe(item)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            (Text(isMine ? "you: " : "\(friend.name): ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isMine ? .gray : pokeColor)
             + message(item, isMine: isMine))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let date = item.createdAt {
                Text(Self.time(date))
                    .font(.system(size: 9))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
        .textSelection(.enabled)
    }

    /// A poke without a message reads "poked".
    private func message(_ item: PokeService.Poke, isMine: Bool) -> Text {
        if item.message.isEmpty {
            return Text(isMine ? "poked" : "poked you").italic().font(.system(size: 11)).foregroundColor(.gray)
        }
        return Text(item.message).font(.system(size: 11)).foregroundColor(.white)
    }

    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// A friend's name, with a green dot while they're online; clicking picks them to poke. Hovering
/// shows a button to remove them.
private struct FriendRow: View {
    @EnvironmentObject var poke: PokeService
    let friend: PokeService.Friend
    let isSelected: Bool
    let isPoked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let isOnline = poke.isOnline(friend)
        HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
                .animation(.easeInOut(duration: 0.2), value: isOnline)
                .help(isOnline ? "\(friend.name) is online" : "\(friend.name) is offline")
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
                .pointingHandCursor()
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
        .pointingHandCursor()
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
        .pointingHandCursor()
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
