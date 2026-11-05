import Foundation
import Combine

/// The Pritunl VPN client's profiles, connected and disconnected from the notch through the
/// client's command-line tool. Pritunl's own service does the connecting, so the Pritunl app shows
/// the same state, and connections started there show here too.
///
/// Profiles that ask for a PIN get it from `PRITUNL_PIN` in the user's zsh config, used for every
/// profile (a Pritunl PIN belongs to the user, not the profile). Without it, the PIN is typed in the
/// VPN tab for each connection. The app never keeps the PIN itself: not in the keychain, not on disk.
class VPNManager: ObservableObject {
    static let shared = VPNManager()

    nonisolated struct Profile: Identifiable, Decodable, Equatable, Sendable {
        let id: String
        let name: String
        let isConnected: Bool
        /// Pritunl is connecting or connected ("Active"), or not ("Inactive").
        let isActive: Bool
        let uptime: Int
        let clientAddress: String

        enum CodingKeys: String, CodingKey {
            case id, name, uptime
            case isConnected = "connected"
            case runState = "run_state"
            case clientAddress = "client_address"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
            isActive = (try container.decodeIfPresent(String.self, forKey: .runState)) == "Active"
            uptime = try container.decodeIfPresent(Int.self, forKey: .uptime) ?? 0
            clientAddress = try container.decodeIfPresent(String.self, forKey: .clientAddress) ?? ""
        }

        var isConnecting: Bool { isActive && !isConnected }
    }

    @Published private(set) var profiles: [Profile] = []
    /// Profiles being connected or disconnected from the notch.
    @Published private(set) var busy: Set<String> = []
    /// The profile waiting for its PIN to be typed in the VPN tab.
    @Published var askingPIN: String?
    @Published var error: String?

    /// When `profiles` was read; uptimes count on from here between reads.
    private(set) var refreshedAt = Date()

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.cliPath) }
    var isConnected: Bool { profiles.contains(where: \.isConnected) }

    private static let cliPath = "/Applications/Pritunl.app/Contents/Resources/pritunl-client"
    /// How often the state is read from Pritunl; connections can start and drop on their own.
    private let refreshInterval: TimeInterval = 5
    /// How long a connection may take before the notch stops waiting for it.
    private let connectTimeout: TimeInterval = 45
    private let notificationManager = NotificationManager.shared

    private init() {
        guard isInstalled else { return }
        Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(refreshInterval))
            }
        }
    }

    /// Connects with the PIN from the zsh config, or asks for it.
    func connect(_ profile: Profile) {
        error = nil
        busy.insert(profile.id)
        Task {
            defer { busy.remove(profile.id) }
            if let pin = await Self.shellPIN() {
                await start(profile, pin: pin, from: .shell)
            } else {
                askingPIN = profile.id
            }
        }
    }

    /// The PIN typed in the VPN tab, for this connection only; it isn't kept.
    func connect(_ profile: Profile, pin: String) {
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { return }
        askingPIN = nil
        error = nil
        busy.insert(profile.id)
        Task {
            defer { busy.remove(profile.id) }
            await start(profile, pin: pin, from: .typed)
        }
    }

    func disconnect(_ profile: Profile) {
        error = nil
        busy.insert(profile.id)
        Task {
            await CommandRunner.run(Self.cliPath, ["stop", profile.id])
            await refresh()
            busy.remove(profile.id)
        }
    }

    /// Where the PIN for a connection came from.
    private enum PINSource { case shell, typed }

    private func start(_ profile: Profile, pin: String, from source: PINSource) async {
        // Typed in at Pritunl's prompt: as an argument (--password) any process could read it.
        guard await CommandRunner.run(Self.cliPath, ["start", profile.id, "--password-read"], typing: pin) != nil else {
            error = "Pritunl couldn't start \(profile.name). Is the Pritunl service running?"
            return
        }
        // Pritunl answers at once and connects in the background; wait until it's up or gave up.
        let started = Date()
        while Date().timeIntervalSince(started) < connectTimeout {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            guard let current = profiles.first(where: { $0.id == profile.id }) else { return }
            if current.isConnected {
                return
            }
            // It stopped trying: most likely the PIN was turned down.
            if !current.isActive && Date().timeIntervalSince(started) > 3 {
                switch source {
                case .shell:
                    error = "Pritunl turned down the PIN in \(Self.pinVariable) in your zsh config. Fix it there, or type the PIN."
                case .typed:
                    error = "Couldn't connect to \(profile.name). Check the PIN and try again."
                }
                askingPIN = profile.id
                return
            }
        }
    }

    /// The zsh variable that holds the PIN, e.g. `PRITUNL_PIN=123456` in `~/.zshrc`. It needn't be
    /// exported, which keeps it out of the environment of every program started from a terminal.
    static let pinVariable = "PRITUNL_PIN"

    /// The PIN from the app's own environment (when opened from a terminal), otherwise as the
    /// user's zsh sets it up: launchd opens the app, and it reads no zsh config. The shell prints
    /// the PIN between markers, so whatever its startup files print is left out, and the PIN is
    /// never in a command line.
    private static func shellPIN() async -> String? {
        if let pin = ProcessInfo.processInfo.environment[pinVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pin.isEmpty {
            return pin
        }
        let begin = "<dynamic-island-pin>", end = "</dynamic-island-pin>"
        guard let data = await CommandRunner.run("/bin/zsh", ["-l", "-i", "-c", "print -rn -- '\(begin)'\"${\(pinVariable)}\"'\(end)'"], timeout: 15),
              let output = String(data: data, encoding: .utf8),
              let opening = output.range(of: begin),
              let closing = output.range(of: end, range: opening.upperBound..<output.endIndex) else { return nil }
        let pin = output[opening.upperBound..<closing.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return pin.isEmpty ? nil : pin
    }

    private func refresh() async {
        guard let data = await CommandRunner.run(Self.cliPath, ["list", "--json"]),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        let sorted = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        announceChanges(from: profiles, to: sorted)
        refreshedAt = Date()
        if sorted != profiles {
            profiles = sorted
        }
    }

    /// Connections that came up or dropped, also ones made in the Pritunl app, show on the notch.
    private func announceChanges(from old: [Profile], to new: [Profile]) {
        // Nothing to compare with on the first read.
        guard !old.isEmpty else { return }
        for profile in new {
            let wasConnected = old.first(where: { $0.id == profile.id })?.isConnected ?? false
            if profile.isConnected && !wasConnected {
                notificationManager.postActivity(AppNotification(type: .vpn, title: "VPN connected", body: profile.name))
            } else if !profile.isConnected && wasConnected {
                notificationManager.postActivity(AppNotification(type: .vpn, title: "VPN disconnected", body: profile.name, symbol: "lock.open.fill"))
            }
        }
    }
}
