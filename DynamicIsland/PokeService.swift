import AppKit
import Combine
import OSLog
import Supabase

/// Poke: friends who also run Dynamic Island nudge each other's notch. Pokes go through a Supabase
/// project the friends share (its tables and rules are in supabase/poke.sql). Each Mac signs in
/// anonymously, and entering a friend's code makes both of you friends.
///
/// The project's URL and anon key are entered in the Poke tab and kept in the user defaults. The
/// anon key is meant to ship in apps; row level security keeps each person to their own data.
class PokeService: ObservableObject {
    static let shared = PokeService()

    enum State: Equatable {
        case notConfigured
        case connecting
        case needsName
        case ready
        case failed(String)
    }

    nonisolated struct Profile: Decodable, Sendable {
        let id: UUID
        let name: String
        let friendCode: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case friendCode = "friend_code"
        }
    }

    nonisolated struct Friend: Identifiable, Decodable, Hashable, Sendable {
        let id: UUID
        let name: String
    }

    nonisolated struct Poke: Identifiable, Decodable, Sendable {
        let id: Int
        let senderID: UUID
        let recipientID: UUID?
        let senderName: String
        let message: String
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, message
            case senderID = "sender_id"
            case recipientID = "recipient_id"
            case senderName = "sender_name"
            case createdAt = "created_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            senderID = try container.decode(UUID.self, forKey: .senderID)
            recipientID = try container.decodeIfPresent(UUID.self, forKey: .recipientID)
            senderName = try container.decode(String.self, forKey: .senderName)
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            // Realtime and the REST API format times differently; a poke is shown either way.
            createdAt = try? container.decode(Date.self, forKey: .createdAt)
        }
    }

    private nonisolated struct NewPoke: Encodable, Sendable {
        let recipientID: UUID
        let message: String

        enum CodingKeys: String, CodingKey {
            case recipientID = "recipient_id"
            case message
        }
    }

    @Published private(set) var state: State = .notConfigured
    @Published private(set) var profile: Profile?
    @Published private(set) var friends: [Friend] = []
    /// Whether new pokes arrive right away.
    @Published private(set) var isListening = false
    /// The last action's error, like an unknown friend code.
    @Published var actionError: String?
    /// The friend being poked from the Poke tab, until Supabase answers.
    @Published private(set) var justPoked: UUID?
    private var justPokedSending: UUID?
    /// The friend picked in the Poke tab; nil picks the first one.
    @Published var selectedFriendID: UUID?
    /// The pokes between you and each friend whose chat was opened, newest first.
    @Published private(set) var history: [UUID: [Poke]] = [:]
    /// How many pokes a chat keeps; an older one makes way for a newer one.
    static let historyLimit = 20
    /// Everyone with Dynamic Island open and connected to Poke right now; empty while this Mac
    /// isn't connected, since then it can't tell.
    @Published private(set) var onlineUserIDs: Set<UUID> = []
    /// Each connected app, by its presence key, and whose it is. One person can have several Macs.
    private var presences: [String: UUID] = [:] {
        didSet {
            let online = Set(presences.values)
            if online != onlineUserIDs {
                onlineUserIDs = online
            }
        }
    }

    private(set) var projectURL: String {
        get { UserDefaults.standard.string(forKey: Self.urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.urlKey) }
    }
    private(set) var anonKey: String {
        get { UserDefaults.standard.string(forKey: Self.keyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.keyKey) }
    }
    /// The newest poke already shown; older ones aren't shown again when catching up.
    private var lastPokeID: Int? {
        get { UserDefaults.standard.object(forKey: Self.lastPokeKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastPokeKey) }
    }

    /// Pokes older than this, caught up after being offline, go to the feed without a banner.
    private let bannerMaxAge: TimeInterval = 10 * 60
    /// How long to wait before connecting again when the network was down, like right after login.
    private let retryDelay: TimeInterval = 30
    /// Realtime doesn't promise delivery (a dropped socket, sleep), so new pokes are also checked
    /// for this often.
    private let pollInterval: TimeInterval = 20
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Poke")
    private let notificationManager = NotificationManager.shared
    private var client: SupabaseClient?
    private var channel: RealtimeChannelV2?
    private var presenceChannel: RealtimeChannelV2?
    private var listenTasks: [Task<Void, Never>] = []
    private var retryTask: Task<Void, Never>?
    /// Pokes shown since launch; Realtime and catching up can both bring the same one.
    private var shownPokeIDs: Set<Int> = []


    private static let urlKey = "pokeProjectURL"
    private static let keyKey = "pokeAnonKey"
    private static let lastPokeKey = "pokeLastID"
    private static let sessionDirectory = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "DynamicIsland", directoryHint: .isDirectory)
        .appending(path: "Poke", directoryHint: .isDirectory)

    private init() {
        if !projectURL.isEmpty && !anonKey.isEmpty {
            connect()
        }
        // The socket died while asleep; check for pokes as soon as the network is likely back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.log.info("Woke from sleep, checking for pokes")
                await self?.fetchMissed()
            }
        }
    }

    // MARK: Setup

    func configure(projectURL: String, anonKey: String) {
        let projectURL = projectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: projectURL), url.scheme == "https", url.host() != nil else {
            state = .failed("The project URL looks like https://abcd.supabase.co")
            return
        }
        guard !anonKey.isEmpty else {
            state = .failed("Paste the project's anon key")
            return
        }
        self.projectURL = projectURL
        self.anonKey = anonKey
        connect()
    }

    /// Forgets the project and this Mac's sign-in; friends see you only after setting up again.
    func disconnect() {
        retryTask?.cancel()
        stopListening()
        client = nil
        projectURL = ""
        anonKey = ""
        lastPokeID = nil
        try? FileManager.default.removeItem(at: Self.sessionDirectory)
        profile = nil
        friends = []
        history = [:]
        actionError = nil
        state = .notConfigured
    }

    func connect() {
        guard let url = URL(string: projectURL) else {
            state = .notConfigured
            return
        }
        retryTask?.cancel()
        stopListening()
        let client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(storage: FileAuthStorage(directory: Self.sessionDirectory), emitLocalSessionAsInitialSession: true))
        )
        self.client = client
        state = .connecting

        Task {
            do {
                // Only a Mac without a session signs up; one whose token can't refresh right now
                // (offline) keeps its identity and fails instead.
                if client.auth.currentSession == nil {
                    try await client.auth.signInAnonymously()
                }
                let userID = try await client.auth.session.user.id
                let profiles: [Profile] = try await client.from("profiles").select("id, name, friend_code").eq("id", value: userID).execute().value
                // A newer connect, or Change Project, took over meanwhile.
                guard self.client === client else { return }
                profile = profiles.first
                if profile == nil {
                    state = .needsName
                } else {
                    try await loadFriends()
                    guard self.client === client else { return }
                    state = .ready
                    listen()
                }
            } catch {
                guard self.client === client else { return }
                state = .failed(Self.describe(error))
                if Self.isOffline(error) {
                    retryLater()
                }
            }
        }
    }

    /// The app often starts at login before the network is up; it connects again by itself.
    private func retryLater() {
        retryTask?.cancel()
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: .seconds(retryDelay))
            guard !Task.isCancelled, let self, case .failed = state else { return }
            connect()
        }
    }

    func setName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !name.isEmpty else { return }
        Task {
            do {
                let profile: Profile = try await client.rpc("set_profile", params: ["new_name": Self.limited(name, to: 40)]).single().execute().value
                let wasReady = state == .ready
                self.profile = profile
                actionError = nil
                if !wasReady {
                    try await loadFriends()
                    state = .ready
                    listen()
                }
            } catch {
                actionError = Self.describe(error)
            }
        }
    }

    // MARK: Friends

    func addFriend(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let client, !code.isEmpty else { return }
        Task {
            do {
                let friend: Friend = try await client.rpc("add_friend", params: ["code": code]).single().execute().value
                if !friends.contains(friend) {
                    friends.append(friend)
                    friends.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                actionError = nil
            } catch {
                actionError = Self.describe(error)
            }
        }
    }

    func removeFriend(_ friend: Friend) {
        guard let client else { return }
        Task {
            do {
                try await client.rpc("remove_friend", params: ["friend": friend.id.uuidString]).execute()
                friends.removeAll { $0.id == friend.id }
                actionError = nil
            } catch {
                actionError = Self.describe(error)
            }
        }
    }

    /// Friends add and remove you from their own Mac, so the list is fetched again when the Poke tab
    /// opens, after reconnecting, and when someone new pokes.
    func refreshFriends() {
        guard state == .ready else { return }
        Task { try? await loadFriends() }
    }

    private func loadFriends() async throws {
        guard let client else { return }
        friends = try await client.rpc("list_friends").execute().value
    }

    func isOnline(_ friend: Friend) -> Bool {
        onlineUserIDs.contains(friend.id)
    }

    /// Fetches the latest pokes you and a friend sent each other. Supabase keeps a week of pokes.
    func loadHistory(with friendID: UUID) async {
        guard state == .ready, let client, let userID = profile?.id else { return }
        do {
            let between = "and(sender_id.eq.\(userID),recipient_id.eq.\(friendID)),and(sender_id.eq.\(friendID),recipient_id.eq.\(userID))"
            let pokes: [Poke] = try await client.from("pokes").select().or(between).order("id", ascending: false).limit(Self.historyLimit).execute().value
            history[friendID] = pokes
        } catch {
            log.error("Loading the chat failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Puts a new poke at the top of an open chat, dropping the oldest past the limit.
    private func addToHistory(_ poke: Poke, friendID: UUID) {
        guard var pokes = history[friendID], !pokes.contains(where: { $0.id == poke.id }) else { return }
        pokes.insert(poke, at: 0)
        pokes.sort { $0.id > $1.id }
        history[friendID] = Array(pokes.prefix(Self.historyLimit))
    }

    func isFromMe(_ poke: Poke) -> Bool {
        poke.senderID == profile?.id
    }

    // MARK: Poking

    /// Pokes a friend. From a banner's Poke Back the notch confirms it once sent; the Poke tab marks
    /// the friend from the click until Supabase answers, and shows an error if it didn't go through.
    func poke(_ friendID: UUID, name: String, message: String = "", confirmOnNotch: Bool = false) {
        guard let client else { return }
        let message = Self.limited(message.trimmingCharacters(in: .whitespacesAndNewlines), to: 100)
        // A newer poke to the same friend keeps the mark until its own answer.
        let sending = UUID()
        if !confirmOnNotch {
            justPoked = friendID
            justPokedSending = sending
        }
        Task {
            defer {
                if justPokedSending == sending {
                    justPoked = nil
                    justPokedSending = nil
                }
            }
            do {
                let sent: Poke = try await client.from("pokes").insert(NewPoke(recipientID: friendID, message: message), returning: .representation).select().single().execute().value
                actionError = nil
                addToHistory(sent, friendID: friendID)
                if confirmOnNotch {
                    notificationManager.postActivity(AppNotification(type: .poke, title: "Poked \(name)", body: message))
                }
            } catch {
                // Row level security turns down a poke to someone who removed you.
                let description: String
                if let error = error as? PostgrestError, error.code == "42501" {
                    description = "\(name) isn't your friend anymore"
                    refreshFriends()
                } else {
                    description = Self.describe(error)
                }
                actionError = description
                if confirmOnNotch {
                    notificationManager.postActivity(AppNotification(type: .poke, title: "Couldn't poke \(name)", body: description))
                }
            }
        }
    }

    /// New pokes arrive through Realtime right away. Since Realtime can miss some, the ones not seen
    /// yet are also fetched after (re)connecting, after waking and every `pollInterval`.
    private func listen() {
        guard let client, let userID = profile?.id else { return }
        stopListening()
        let channel = client.channel("pokes:\(userID.uuidString.lowercased())")
        let inserts = channel.postgresChange(InsertAction.self, table: "pokes", filter: .eq("recipient_id", value: userID))
        self.channel = channel

        listenTasks.append(Task { [weak self] in
            for await status in channel.statusChange {
                self?.log.info("Realtime: \(String(describing: status), privacy: .public)")
                self?.isListening = status == .subscribed
                if status == .subscribed {
                    await self?.catchUp()
                }
            }
        })
        listenTasks.append(Task { [weak self] in
            for await insert in inserts {
                do {
                    let poke = try insert.decodeRecord(as: Poke.self, decoder: PostgrestClient.Configuration.jsonDecoder)
                    self?.receive(poke, via: "Realtime")
                } catch {
                    // It's fetched by the next check instead.
                    self?.log.error("Couldn't read a poke from Realtime: \(String(describing: error), privacy: .public)")
                }
            }
        })
        listenTasks.append(Task { [weak self] in
            do {
                try await channel.subscribeWithError()
            } catch {
                self?.log.error("Realtime subscribe failed: \(String(describing: error), privacy: .public)")
            }
        })
        listenTasks.append(Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                await self?.fetchMissed()
            }
        })
        showOnline(client: client, userID: userID)
    }

    /// Every connected app joins one shared Realtime channel and says whose it is (only the user
    /// ID, which only friends can put a name to). An app that quits, sleeps or loses the network
    /// leaves it, so a friend in it is online.
    private func showOnline(client: SupabaseClient, userID: UUID) {
        let channel = client.channel("poke-online")
        let changes = channel.presenceChange()
        presenceChannel = channel

        listenTasks.append(Task { [weak self] in
            for await status in channel.statusChange {
                if status == .subscribed {
                    // Joining again, after a reconnect, needs saying so again.
                    await channel.track(state: ["user_id": .string(userID.uuidString.lowercased())])
                } else {
                    // Not connected, so who's online isn't known; joining again brings everyone back.
                    self?.presences = [:]
                }
            }
        })
        listenTasks.append(Task { [weak self] in
            for await change in changes {
                // An app that says so again leaves and joins in one change; it stays online.
                for key in change.leaves.keys {
                    self?.presences[key] = nil
                }
                for (key, presence) in change.joins {
                    if let id = presence.state["user_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                        self?.presences[key] = id
                    }
                }
                self?.log.info("Online: \(self?.onlineUserIDs.count ?? 0) people")
            }
        })
        listenTasks.append(Task { [weak self] in
            do {
                try await channel.subscribeWithError()
            } catch {
                self?.log.error("Online channel subscribe failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    private func stopListening() {
        listenTasks.forEach { $0.cancel() }
        listenTasks = []
        if let client {
            for channel in [channel, presenceChannel].compactMap({ $0 }) {
                Task { await client.removeChannel(channel) }
            }
        }
        channel = nil
        presenceChannel = nil
        presences = [:]
        isListening = false
    }

    private func catchUp() async {
        try? await loadFriends()
        await fetchMissed()
    }

    /// Fetches the pokes not seen yet.
    private func fetchMissed() async {
        guard state == .ready, let client, let userID = profile?.id else { return }
        do {
            guard let lastPokeID else {
                // First time: start after the newest poke, without showing older ones.
                let newest: [Poke] = try await client.from("pokes").select().eq("recipient_id", value: userID).order("id", ascending: false).limit(1).execute().value
                self.lastPokeID = max(self.lastPokeID ?? 0, newest.first?.id ?? 0)
                return
            }
            let missed: [Poke] = try await client.from("pokes").select().eq("recipient_id", value: userID).gt("id", value: lastPokeID).order("id").limit(20).execute().value
            for poke in missed {
                receive(poke, via: "check")
            }
        } catch {
            log.error("Checking for pokes failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func receive(_ poke: Poke, via source: String) {
        // A poke both Realtime and a check brought isn't shown twice.
        guard shownPokeIDs.insert(poke.id).inserted else { return }
        log.info("Poke \(poke.id) from \(source, privacy: .public)")
        lastPokeID = max(lastPokeID ?? 0, poke.id)
        addToHistory(poke, friendID: poke.senderID)
        if !friends.contains(where: { $0.id == poke.senderID }) {
            refreshFriends()
        }

        let title = "\(poke.senderName) poked you"
        // A poke without a message shows only "… poked you".
        let body = poke.message
        if let createdAt = poke.createdAt, Date().timeIntervalSince(createdAt) > bannerMaxAge {
            notificationManager.post(.poke, title: title, body: body)
            return
        }
        let notification = AppNotification(type: .poke, title: title, body: body, actionTitle: "Poke Back", pokeSenderID: poke.senderID, pokeSenderName: poke.senderName)
        notificationManager.postActivity(notification, keepInFeed: true)
        // Ping rings on for a moment, so it's heard even when you're not looking at the notch.
        if !FocusStatus.isActive {
            NSSound(named: "Ping")?.play()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? PostgrestError {
            return error.message
        }
        if let error = error as? AuthError {
            return error.message
        }
        if isOffline(error) {
            return "Can't reach Supabase. If the project is paused, restore it in the Supabase dashboard."
        }
        return error.localizedDescription
    }

    private static func isOffline(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    /// The database counts characters as Unicode scalars, so an emoji can count as several.
    private static func limited(_ text: String, to length: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(length)))
    }
}

/// Keeps the Supabase sign-in in a file only the user can read. The keychain would ask for access
/// again after every build of an ad hoc signed app.
nonisolated struct FileAuthStorage: AuthLocalStorage {
    let directory: URL

    func store(key: String, value: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(for: key)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: value, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func retrieve(key: String) throws -> Data? {
        try? Data(contentsOf: file(for: key))
    }

    func remove(key: String) throws {
        try? FileManager.default.removeItem(at: file(for: key))
    }

    private func file(for key: String) -> URL {
        directory.appending(path: key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "session")
    }
}
