import SwiftUI
import AppKit
import ServiceManagement

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem?
    var panel: FloatingPanel?

    let spotifyManager = SpotifyManager()
    let systemMonitor = SystemMonitor()
    let temperatureMonitor = TemperatureMonitor()
    let notificationManager = NotificationManager.shared
    let themeManager = ThemeManager()
    let mediaControlManager = MediaControlManager()
    let islandLayout = IslandLayout()
    let calendarManager = CalendarManager()
    let claudeUsageMonitor = ClaudeUsageMonitor()
    let systemNotificationMonitor = SystemNotificationMonitor(notificationManager: .shared)
    let dockBadgeWatcher = DockBadgeWatcher(notificationManager: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        themeManager.loadPreference()
        enableLaunchAtLoginOnFirstRun()
    }

    /// Turns on Launch at Login once, the first time the installed copy in /Applications runs.
    /// Builds run from Xcode are skipped so the login item never points at DerivedData.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetUpLaunchAtLogin"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        LaunchAtLogin.isEnabled = true
    }

    @objc func toggleLaunchAtLogin() {
        LaunchAtLogin.isEnabled.toggle()
    }

    func setupMenuBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem?.button {
            button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Dynamic Island")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hostingView = NSHostingView(
            rootView: AnyView(
                DynamicIslandViewFull()
                    .environmentObject(spotifyManager)
                    .environmentObject(systemMonitor)
                    .environmentObject(temperatureMonitor)
                    .environmentObject(notificationManager)
                    .environmentObject(themeManager)
                    .environmentObject(mediaControlManager)
                    .environmentObject(islandLayout)
                    .environmentObject(calendarManager)
                    .environmentObject(claudeUsageMonitor)
            )
        )

        panel = FloatingPanel(hostingView: hostingView, layout: islandLayout)
        panel?.orderFrontRegardless()
        panel?.reposition()
    }

    /// Left click shows/hides the island; right click opens a menu with settings and Quit.
    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let pinItem = menu.addItem(withTitle: "Pin to Notch", action: #selector(togglePinnedToNotch), keyEquivalent: "")
            pinItem.target = self
            pinItem.state = islandLayout.isPinnedToNotch ? .on : .off
            let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Dynamic Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusBarItem?.menu = menu
            statusBarItem?.button?.performClick(nil)
            statusBarItem?.menu = nil
            return
        }

        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc func togglePinnedToNotch() {
        islandLayout.isPinnedToNotch.toggle()
    }
}

/// Registers the app as a login item (System Settings → General → Login Items).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NotificationManager.shared.post(.system, title: "Launch at Login", body: error.localizedDescription)
            }
        }
    }
}

struct DynamicIslandViewFull: View {
    @EnvironmentObject var spotifyManager: SpotifyManager
    @EnvironmentObject var systemMonitor: SystemMonitor
    @EnvironmentObject var temperatureMonitor: TemperatureMonitor
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var mediaControlManager: MediaControlManager
    @EnvironmentObject var layout: IslandLayout

    @State private var selectedTab: String = "music"

    var body: some View {
        if layout.isPinnedToNotch {
            NotchIslandView()
        } else {
            // The window doesn't size itself to SwiftUI content, so the island reports its size.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    floatingIsland
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                            layout.floatingContentSize = size
                        }
                }
        }
    }

    private var floatingIsland: some View {
        VStack(spacing: 0) {
            floatingHeader
                // Drag the header to move the island; click it to expand/collapse.
                .overlay(WindowDragArea(onClick: layout.toggleExpanded))

            if layout.isExpanded {
                Divider()

                VStack(spacing: 12) {
                    // Tab Selection
                    HStack(spacing: 8) {
                        TabButton(title: "🎵", tab: "music", selectedTab: $selectedTab, themeManager: themeManager)
                        TabButton(title: "📊", tab: "stats", selectedTab: $selectedTab, themeManager: themeManager)
                        TabButton(title: "🌡️", tab: "temp", selectedTab: $selectedTab, themeManager: themeManager)
                        TabButton(title: "🔔", tab: "notify", selectedTab: $selectedTab, themeManager: themeManager)
                        TabButton(title: "🎨", tab: "theme", selectedTab: $selectedTab, themeManager: themeManager)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    Divider()

                    // Tab Content
                    Group {
                        if selectedTab == "music" {
                            MusicTabView(
                                spotifyManager: spotifyManager,
                                mediaControlManager: mediaControlManager,
                                themeManager: themeManager
                            )
                        } else if selectedTab == "stats" {
                            StatsTabView(
                                systemMonitor: systemMonitor,
                                themeManager: themeManager
                            )
                        } else if selectedTab == "temp" {
                            TemperatureTabView(
                                temperatureMonitor: temperatureMonitor,
                                themeManager: themeManager
                            )
                        } else if selectedTab == "notify" {
                            NotificationsTabView(
                                notificationManager: notificationManager,
                                themeManager: themeManager
                            )
                        } else if selectedTab == "theme" {
                            ThemeTabView(
                                themeManager: themeManager
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(width: 320)
        .background(Color(themeManager.currentTheme.backgroundColor))
        .cornerRadius(themeManager.currentTheme.cornerRadius)
    }

    // MARK: - Floating Header
    private var floatingHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(themeManager.currentTheme.primaryColor))

            VStack(alignment: .leading, spacing: 2) {
                Text("Dynamic Island")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(themeManager.currentTheme.textColor))

                Text(selectedTab.capitalized)
                    .font(.system(size: 9))
                    .foregroundColor(Color(themeManager.currentTheme.secondaryTextColor))
            }

            Spacer()

            if notificationManager.unreadCount > 0 {
                Badge(count: notificationManager.unreadCount)
            }

            Image(systemName: layout.isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(themeManager.currentTheme.primaryColor))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(themeManager.currentTheme.backgroundColor))
    }
}

// MARK: - Tab Components
struct TabButton: View {
    let title: String
    let tab: String
    @Binding var selectedTab: String
    let themeManager: ThemeManager

    var body: some View {
        Button(action: { selectedTab = tab }) {
            Text(title)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(selectedTab == tab ? Color(themeManager.currentTheme.accentColor).opacity(0.2) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct Badge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(Color.red)
            .cornerRadius(8)
    }
}

// MARK: - Music Tab
struct MusicTabView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @ObservedObject var mediaControlManager: MediaControlManager
    let themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 12) {
            if spotifyManager.currentTrack != "No Track" {
                VStack(alignment: .leading, spacing: 8) {
                    Text(spotifyManager.currentTrack)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(themeManager.currentTheme.textColor))
                        .lineLimit(1)

                    Text(spotifyManager.currentArtist)
                        .font(.system(size: 10))
                        .foregroundColor(Color(themeManager.currentTheme.secondaryTextColor))
                        .lineLimit(1)
                }

                // Progress Bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .foregroundColor(Color(themeManager.currentTheme.borderColor))

                        RoundedRectangle(cornerRadius: 2)
                            .foregroundColor(Color(themeManager.currentTheme.accentColor))
                            .frame(width: geometry.size.width * spotifyManager.progressPercentage)
                    }
                }
                .frame(height: 4)

                // Media Controls
                HStack(spacing: 12) {
                    Button(action: { mediaControlManager.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12))
                    }

                    Button(action: { mediaControlManager.playPause() }) {
                        Image(systemName: spotifyManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                    }
                    .frame(maxWidth: .infinity)

                    Button(action: { mediaControlManager.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12))
                    }
                }
                .foregroundColor(Color(themeManager.currentTheme.accentColor))
            } else {
                Text("No Music Playing")
                    .font(.system(size: 11))
                    .foregroundColor(Color(themeManager.currentTheme.secondaryTextColor))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            }
        }
    }
}

// MARK: - Stats Tab
struct StatsTabView: View {
    @ObservedObject var systemMonitor: SystemMonitor
    let themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatRow(label: "Battery", value: "\(systemMonitor.batteryLevel)%", icon: "battery.100", themeManager: themeManager)
            StatRow(label: "CPU", value: "\(systemMonitor.cpuUsage)%", icon: "cpu", themeManager: themeManager)
            StatRow(label: "Memory", value: "\(systemMonitor.memoryUsage)%", icon: "memorychip", themeManager: themeManager)
            StatRow(label: "Network", value: systemMonitor.networkConnected ? "Online" : "Offline", icon: "wifi", themeManager: themeManager)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let icon: String
    let themeManager: ThemeManager

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.system(size: 10))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(themeManager.currentTheme.accentColor))
        }
        .foregroundColor(Color(themeManager.currentTheme.textColor))
    }
}

// MARK: - Temperature Tab
struct TemperatureTabView: View {
    @ObservedObject var temperatureMonitor: TemperatureMonitor
    let themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System Status")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(temperatureMonitor.systemTemp)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(temperatureMonitor.systemTempColor))
            }

            TempBar(label: "CPU", temp: temperatureMonitor.cpuTemp, themeManager: themeManager)
            TempBar(label: "GPU", temp: temperatureMonitor.gpuTemp, themeManager: themeManager)
            TempBar(label: "Battery", temp: temperatureMonitor.batteryTemp, themeManager: themeManager)
        }
        .foregroundColor(Color(themeManager.currentTheme.textColor))
    }
}

struct TempBar: View {
    let label: String
    let temp: Double
    let themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 9))
                Spacer()
                Text(String(format: "%.1f°C", temp))
                    .font(.system(size: 9, weight: .semibold))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .foregroundColor(Color(themeManager.currentTheme.borderColor))

                    let percentage = min(temp / 100.0, 1.0)
                    RoundedRectangle(cornerRadius: 2)
                        .foregroundColor(temp > 80 ? Color.red : Color.orange)
                        .frame(width: geometry.size.width * percentage)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Notifications Tab
struct NotificationsTabView: View {
    @ObservedObject var notificationManager: NotificationManager
    let themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notificationManager.notifications.isEmpty {
                Text("No notifications")
                    .font(.system(size: 11))
                    .foregroundColor(Color(themeManager.currentTheme.secondaryTextColor))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
            } else {
                ForEach(notificationManager.notifications.prefix(3)) { notification in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let url = notification.appBundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: notification.icon)
                                    .foregroundColor(Color(themeManager.currentTheme.accentColor))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notification.title)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(notification.body)
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(themeManager.currentTheme.secondaryTextColor))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundColor(Color(themeManager.currentTheme.textColor))
                    }
                    .padding(8)
                    .background(Color(themeManager.currentTheme.accentColor).opacity(0.1))
                    .cornerRadius(6)
                }
            }
        }
        .onAppear { notificationManager.markAllAsRead() }
    }
}

// MARK: - Theme Tab
struct ThemeTabView: View {
    @ObservedObject var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Theme")
                .font(.system(size: 11, weight: .semibold))

            VStack(spacing: 6) {
                ForEach(ThemeManager.ThemePreset.allCases, id: \.self) { preset in
                    HStack {
                        Button(action: { themeManager.setTheme(preset) }) {
                            Text(preset.rawValue)
                                .font(.system(size: 10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)

                        if themeManager.currentTheme.backgroundColor == preset.theme.backgroundColor {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 12))
                        }
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
            }
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    var body: some View {
        VStack {
            Text("Dynamic Island Settings")
                .font(.title2)
            Text("Configure your preferences in the menu bar widget")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    DynamicIslandViewFull()
        .environmentObject(SpotifyManager())
        .environmentObject(SystemMonitor())
        .environmentObject(TemperatureMonitor())
        .environmentObject(NotificationManager.shared)
        .environmentObject(ThemeManager())
        .environmentObject(MediaControlManager())
        .environmentObject(IslandLayout())
        .environmentObject(CalendarManager())
        .environmentObject(ClaudeUsageMonitor())
}
