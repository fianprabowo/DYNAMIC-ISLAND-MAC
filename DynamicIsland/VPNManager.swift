import Foundation
import Combine
import Security

/// The Pritunl VPN client's profiles, connected and disconnected from the notch through the
/// client's command-line tool. Pritunl's own service does the connecting, so the Pritunl app shows
/// the same state, and connections started there show here too.
///
/// Profiles that ask for a PIN get it from the keychain. The PIN is asked once, in the VPN tab, and
/// then used for every profile (a Pritunl PIN belongs to the user, not the profile); a profile whose
/// server turns it down asks for its own.
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

    func hasSavedPIN(_ profile: Profile) -> Bool {
        VPNPINStore.pin(for: profile.id) != nil
    }

    /// Connects with the saved PIN, or asks for it first.
    func connect(_ profile: Profile) {
        error = nil
        guard let pin = VPNPINStore.pin(for: profile.id) else {
            askingPIN = profile.id
            return
        }
        start(profile, pin: pin)
    }

    /// The PIN typed in the VPN tab; it's kept in the keychain once the connection comes up.
    func connect(_ profile: Profile, pin: String) {
        let pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else { return }
        askingPIN = nil
        start(profile, pin: pin, saveOnSuccess: true)
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

    func forgetPIN(_ profile: Profile) {
        VPNPINStore.remove(for: profile.id)
        VPNPINStore.remove(for: VPNPINStore.defaultAccount)
        objectWillChange.send()
    }

    private func start(_ profile: Profile, pin: String, saveOnSuccess: Bool = false) {
        busy.insert(profile.id)
        Task {
            defer { busy.remove(profile.id) }
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
                    if saveOnSuccess {
                        VPNPINStore.save(pin, for: profile.id)
                        VPNPINStore.save(pin, for: VPNPINStore.defaultAccount)
                    }
                    return
                }
                // It stopped trying: most likely the PIN was turned down.
                if !current.isActive && Date().timeIntervalSince(started) > 3 {
                    VPNPINStore.remove(for: profile.id)
                    error = "Couldn't connect to \(profile.name). Check the PIN and try again."
                    askingPIN = profile.id
                    return
                }
            }
        }
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

/// Pritunl PINs in the login keychain: one per profile that needed its own, and a default for the rest.
nonisolated enum VPNPINStore {
    private static let service = "Dynamic Island · Pritunl PIN"
    static let defaultAccount = "default"

    /// The profile's own PIN, otherwise the default one.
    static func pin(for profileID: String) -> String? {
        storedPIN(for: profileID) ?? storedPIN(for: defaultAccount)
    }

    private static func storedPIN(for profileID: String) -> String? {
        var query = baseQuery(profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ pin: String, for profileID: String) {
        let data = Data(pin.utf8)
        let query = baseQuery(profileID)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = service
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(for profileID: String) {
        SecItemDelete(baseQuery(profileID) as CFDictionary)
    }

    private static func baseQuery(_ profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
    }
}
