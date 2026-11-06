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
        /// When the recipient's app got it; nil until then (or before supabase/poke.sql added it).
        var deliveredAt: Date?
        /// When the recipient opened the chat with it; nil until then (or before supabase/poke.sql
        /// added it).
        var seenAt: Date?
        /// A picture sent with it, in the poke-images bucket.
        let imagePath: String?

        enum CodingKeys: String, CodingKey {
            case id, message
            case senderID = "sender_id"
            case recipientID = "recipient_id"
            case senderName = "sender_name"
            case createdAt = "created_at"
            case deliveredAt = "delivered_at"
            case seenAt = "seen_at"
            case imagePath = "image_path"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            senderID = try container.decode(UUID.self, forKey: .senderID)
            recipientID = try container.decodeIfPresent(UUID.self, forKey: .recipientID)
            senderName = try container.decode(String.self, forKey: .senderName)
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            createdAt = Self.date(in: container, forKey: .createdAt)
            deliveredAt = Self.date(in: container, forKey: .deliveredAt)
            seenAt = Self.date(in: container, forKey: .seenAt)
            imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        }

        /// Realtime and the REST API format times differently, like `2026-11-06T08:20:34.027432+00:00`
        /// and `2026-11-06 08:20:34.027432+00`; a poke is shown either way, without the time if unreadable.
        private static func date(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
            if let date = try? container.decodeIfPresent(Date.self, forKey: key) { return date }
            guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            var normalized = text.replacingOccurrences(of: " ", with: "T")
            // "+00" → "+00:00"
            if let sign = normalized.lastIndex(where: { $0 == "+" || $0 == "-" }),
               normalized.distance(from: sign, to: normalized.endIndex) == 3 {
                normalized += ":00"
            }
            let formatter = ISO8601DateFormatter()
            // Without an offset, the time is UTC.
            for candidate in [normalized, normalized + "Z"] {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: candidate) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: candidate) { return date }
            }
            return nil
        }
    }

    private nonisolated struct NewPoke: Encodable, Sendable {
        let recipientID: UUID
        let message: String
        /// Left out without a picture, so pokes work before supabase/poke.sql added the column.
        let imagePath: String?

        enum CodingKeys: String, CodingKey {
            case recipientID = "recipient_id"
            case message
            case imagePath = "image_path"
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
    /// Those of them whose app says they're in a meeting (on any of their Macs).
    @Published private(set) var inMeetingUserIDs: Set<UUID> = []
    /// What friends are listening to, by who's listening.
    @Published private(set) var songs: [UUID: Song] = [:]

    /// A song playing: "Song — Artist", and Spotify's id for it when it plays in Spotify.
    nonisolated struct Song: Equatable, Sendable {
        let text: String
        let spotifyURI: String?
    }
    /// Each connected app, by its presence key: whose it is, and whether they're in a meeting.
    /// One person can have several Macs.
    private var presences: [String: Presence] = [:] {
        didSet {
            let online = Set(presences.values.map(\.userID))
            if online != onlineUserIDs {
                onlineUserIDs = online
            }
            let inMeeting = Set(presences.values.filter(\.isInMeeting).map(\.userID))
            if inMeeting != inMeetingUserIDs {
                inMeetingUserIDs = inMeeting
            }
            var playing: [UUID: Song] = [:]
            for presence in presences.values {
                if let song = presence.song {
                    playing[presence.userID] = song
                }
            }
            if playing != songs {
                songs = playing
            }
        }
    }
    private struct Presence {
        /// The server's id for this report; a later report replaces it.
        let ref: String
        let userID: UUID
        let isInMeeting: Bool
        let song: Song?
    }
    /// Whether this Mac's user is in a meeting now, told to friends through presence.
    @Published private(set) var isInMeeting = false
    /// The song playing on this Mac, told to friends while `sharesNowPlaying` is on.
    @Published private(set) var nowPlaying: Song?
    /// The song friends see under your name now; nil when nothing plays or sharing is off.
    var sharedSong: Song? {
        sharesNowPlaying ? nowPlaying : nil
    }
    /// Friends see the song you're listening to under your name (gear menu).
    @Published var sharesNowPlaying: Bool = UserDefaults.standard.object(forKey: PokeService.sharesNowPlayingKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sharesNowPlaying, forKey: Self.sharesNowPlayingKey)
            if nowPlaying != nil {
                trackPresence()
            }
        }
    }
    private static let sharesNowPlayingKey = "pokeSharesNowPlaying"

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
    /// The Supabase project and this Mac's sign-in; the Todo tab keeps its todos there too.
    private(set) var client: SupabaseClient?
    private var channel: RealtimeChannelV2?
    private var presenceChannel: RealtimeChannelV2?
    private var presenceTasks: [Task<Void, Never>] = []
    private var markingSeen: Set<UUID> = []
    /// The open notch shows the Poke tab: a new poke then appears in the chat and the friend list,
    /// with its sound but without a banner.
    var isPokeTabVisible = false
    private var isMarkingDelivered = false
    private var markDeliveredAgain = false
    private var listenTasks: [Task<Void, Never>] = []
    private var retryTask: Task<Void, Never>?
    /// Pokes shown since launch; Realtime and catching up can both bring the same one.
    private var shownPokeIDs: Set<Int> = []


    /// Per friend, the newest poke cleared from the chat on this Mac; the friend's chat keeps it.
    private var chatClearedUpTo: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Self.chatClearedKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.chatClearedKey) }
    }

    /// The longest song text shown, so an odd one can't stretch the list.
    private static let songLimit = 120
    private static let chatClearedKey = "pokeChatClearedUpTo"
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
        chatClearedUpTo = [:]
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
                    deleteOldImages()
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

    func isInMeeting(_ friend: Friend) -> Bool {
        inMeetingUserIDs.contains(friend.id)
    }

    func song(of friend: Friend) -> Song? {
        songs[friend.id]
    }

    /// Tells friends whether you're in a meeting: only yes or no, never which meeting.
    func setInMeeting(_ value: Bool) {
        guard value != isInMeeting else { return }
        isInMeeting = value
        trackPresence()
    }

    /// Tells friends the song playing now; nil when nothing plays.
    func setNowPlaying(_ song: Song?) {
        guard song != nowPlaying else { return }
        nowPlaying = song
        if sharesNowPlaying {
            trackPresence()
        }
    }

    /// Says this app's state again, which friends' apps take as an update.
    private func trackPresence() {
        guard let presenceChannel, presenceChannel.status == .subscribed, let userID = profile?.id else { return }
        let state = presenceState(userID: userID)
        Task { await presenceChannel.track(state: state) }
    }

    private func presenceState(userID: UUID) -> JSONObject {
        var state: JSONObject = ["user_id": .string(userID.uuidString.lowercased()), "in_meeting": .bool(isInMeeting)]
        if sharesNowPlaying, let nowPlaying {
            state["song"] = .string(nowPlaying.text)
            if let uri = nowPlaying.spotifyURI {
                state["song_uri"] = .string(uri)
            }
        }
        return state
    }

    /// Fetches the latest pokes you and a friend sent each other. Supabase keeps a week of pokes.
    func loadHistory(with friendID: UUID) async {
        guard state == .ready, let client, let userID = profile?.id else { return }
        do {
            let between = "and(sender_id.eq.\(userID),recipient_id.eq.\(friendID)),and(sender_id.eq.\(friendID),recipient_id.eq.\(userID))"
            var query = client.from("pokes").select().or(between)
            if let cleared = chatClearedUpTo[friendID.uuidString] {
                query = query.gt("id", value: cleared)
            }
            let pokes: [Poke] = try await query.order("id", ascending: false).limit(Self.historyLimit).execute().value
            history[friendID] = pokes
        } catch {
            log.error("Loading the chat failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Empties the chat with a friend on this Mac only: the pokes stay in Supabase, so the friend
    /// still sees them, and newer ones show up as usual.
    func clearChat(with friendID: UUID) {
        guard let newest = history[friendID]?.first?.id else { return }
        chatClearedUpTo[friendID.uuidString] = newest
        history[friendID] = []
    }

    /// Puts a new poke at the top of an open chat, dropping the oldest past the limit.
    private func addToHistory(_ poke: Poke, friendID: UUID) {
        guard var pokes = history[friendID], !pokes.contains(where: { $0.id == poke.id }) else { return }
        pokes.insert(poke, at: 0)
        pokes.sort { $0.id > $1.id }
        history[friendID] = Array(pokes.prefix(Self.historyLimit))
    }

    /// A poke in an open chat changed, like being seen.
    private func updateInHistory(_ poke: Poke) {
        guard let friendID = poke.recipientID, var pokes = history[friendID],
              let index = pokes.firstIndex(where: { $0.id == poke.id }) else { return }
        pokes[index] = poke
        history[friendID] = pokes
    }

    /// Tells senders their pokes reached this Mac (two grey ticks in their chat). Pokes arriving
    /// together are marked in one go.
    private func markDelivered() async {
        guard let client else { return }
        guard !isMarkingDelivered else {
            markDeliveredAgain = true
            return
        }
        isMarkingDelivered = true
        repeat {
            markDeliveredAgain = false
            do {
                try await client.rpc("mark_pokes_delivered").execute()
            } catch {
                // Before supabase/poke.sql added it, there's no such function; nothing is marked.
                log.error("Marking pokes delivered failed: \(String(describing: error), privacy: .public)")
            }
        } while markDeliveredAgain
        isMarkingDelivered = false
    }

    /// Marks a friend's pokes in the open chat as seen, which their app shows under yours.
    func markSeen(from friendID: UUID) async {
        guard let client, let pokes = history[friendID], !markingSeen.contains(friendID),
              pokes.contains(where: { $0.senderID == friendID && $0.seenAt == nil }) else { return }
        markingSeen.insert(friendID)
        defer { markingSeen.remove(friendID) }
        do {
            try await client.rpc("mark_pokes_seen", params: ["friend": friendID.uuidString.lowercased()]).execute()
            let now = Date()
            history[friendID] = history[friendID]?.map { poke in
                var poke = poke
                if poke.senderID == friendID && poke.seenAt == nil {
                    poke.seenAt = now
                    poke.deliveredAt = poke.deliveredAt ?? now
                }
                return poke
            }
        } catch {
            // Before supabase/poke.sql added it, there's no such function; nothing is marked.
            log.error("Marking pokes seen failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Pictures

    static let imageBucket = "poke-images"
    /// Pictures in chats, by path, once downloaded or sent from here.
    private var images: [String: Data] = [:]

    /// A chat's picture, downloaded the first time.
    func image(at path: String) async -> Data? {
        if let image = images[path] { return image }
        guard let client else { return nil }
        do {
            let data = try await client.storage.from(Self.imageBucket).download(path: path)
            images[path] = data
            return data
        } catch {
            log.error("Downloading a picture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Keeps all pictures under 50 MB together: when this one would bring them past 48 MB, all of
    /// them are deleted first, so older chats show "Picture no longer available".
    private func makeRoom(for bytes: Int) async {
        guard let client else { return }
        do {
            let paths: [String] = try await client.rpc("poke_images_to_clear", params: ["adding": bytes]).execute().value
            guard !paths.isEmpty else { return }
            try await client.storage.from(Self.imageBucket).remove(paths: paths)
            log.info("Deleted all \(paths.count) pictures to stay under 48 MB")
        } catch {
            // Before supabase/poke.sql added it, nothing is deleted; the picture is sent anyway.
            log.error("Making room for a picture failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Opens a chat's picture in Preview, from a copy in the temporary folder.
    func openImage(at path: String) {
        guard let data = images[path] else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "Poke \((path as NSString).lastPathComponent)")
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            log.error("Opening a picture failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes pictures you sent more than a day ago; their pokes are gone by then.
    private func deleteOldImages() {
        guard let client, let userID = profile?.id else { return }
        Task {
            do {
                let bucket = client.storage.from(Self.imageBucket)
                let files = try await bucket.list(path: userID.uuidString.lowercased(), options: SearchOptions(limit: 100, sortBy: SortBy(column: "created_at", order: .ascending)))
                let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
                let old = files.filter { ($0.createdAt ?? .distantFuture) < dayAgo }.map { "\(userID.uuidString.lowercased())/\($0.name)" }
                if !old.isEmpty {
                    try await bucket.remove(paths: old)
                    log.info("Deleted \(old.count) old pictures")
                }
            } catch {
                // Before supabase/poke.sql added the bucket, there's nothing to delete.
                log.error("Deleting old pictures failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func isFromMe(_ poke: Poke) -> Bool {
        poke.senderID == profile?.id
    }

    // MARK: Poking

    /// Pokes a friend. From a banner's Poke Back the notch confirms it once sent; the Poke tab marks
    /// the friend from the click until Supabase answers, and shows an error if it didn't go through.
    /// With `image` (a JPEG from `PokeImage`), the picture is uploaded first.
    func poke(_ friendID: UUID, name: String, message: String = "", image: Data? = nil, confirmOnNotch: Bool = false) {
        guard let client, let userID = profile?.id else { return }
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
                var imagePath: String?
                if let image {
                    await makeRoom(for: image.count)
                    let path = "\(userID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                    try await client.storage.from(Self.imageBucket).upload(path, data: image, options: FileOptions(contentType: "image/jpeg"))
                    images[path] = image
                    imagePath = path
                }
                let sent: Poke = try await client.from("pokes").insert(NewPoke(recipientID: friendID, message: message, imagePath: imagePath), returning: .representation).select().single().execute().value
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
        // A friend opening the chat marks your pokes seen.
        let updates = channel.postgresChange(UpdateAction.self, table: "pokes", filter: .eq("sender_id", value: userID))
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
            for await update in updates {
                do {
                    let poke = try update.decodeRecord(as: Poke.self, decoder: PostgrestClient.Configuration.jsonDecoder)
                    self?.log.info("Poke \(poke.id, privacy: .public) updated: delivered \(poke.deliveredAt != nil, privacy: .public), seen \(poke.seenAt != nil, privacy: .public)")
                    self?.updateInHistory(poke)
                } catch {
                    self?.log.error("Couldn't read a poke update from Realtime: \(String(describing: error), privacy: .public)")
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
                await self?.rejoinOnlineIfDropped()
            }
        })
        showOnline(client: client, userID: userID)
    }

    /// Every connected app joins one shared Realtime channel and says whose it is (only the user
    /// ID, which only friends can put a name to, whether they're in a meeting and the song they
    /// play, unless they turned that off). An app that
    /// quits, sleeps or loses the network leaves it, so a friend in it is online.
    private func showOnline(client: SupabaseClient, userID: UUID) {
        presenceTasks.forEach { $0.cancel() }
        let channel = client.channel("poke-online")
        let changes = channel.presenceChange()
        presenceChannel = channel

        presenceTasks.append(Task { [weak self] in
            for await status in channel.statusChange {
                if status == .subscribed {
                    // Joining again, after a reconnect, needs saying so again.
                    if let state = self?.presenceState(userID: userID) {
                        await channel.track(state: state)
                    }
                } else {
                    // Not connected, so who's online isn't known; joining again brings everyone back.
                    self?.presences = [:]
                }
            }
        })
        presenceTasks.append(Task { [weak self] in
            for await change in changes {
                // An app that says something new (a song, a meeting) leaves with its old report
                // and joins with the new one. Only the report it left with goes, so it stays
                // online even when the join comes first.
                for (key, presence) in change.leaves where self?.presences[key]?.ref == presence.ref {
                    self?.presences[key] = nil
                }
                for (key, presence) in change.joins {
                    if let id = presence.state["user_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                        // An app from before meetings were shared doesn't say; it counts as not in one.
                        let isInMeeting = presence.state["in_meeting"]?.boolValue ?? false
                        let text = presence.state["song"]?.stringValue.map { String($0.prefix(Self.songLimit)) } ?? ""
                        let uri = presence.state["song_uri"]?.stringValue.flatMap(SongPlayer.validSpotifyURI)
                        let song = text.isEmpty ? nil : Song(text: text, spotifyURI: uri)
                        self?.presences[key] = Presence(ref: presence.ref, userID: id, isInMeeting: isInMeeting, song: song)
                    }
                }
                self?.log.info("Online: \(self?.onlineUserIDs.count ?? 0) people")
            }
        })
        presenceTasks.append(Task { [weak self] in
            do {
                try await channel.subscribeWithError()
            } catch {
                self?.log.error("Online channel subscribe failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    /// The online channel can drop on its own (a failed join, a network change) while pokes still
    /// arrive; then this Mac and its friends would look offline to each other until a relaunch.
    private func rejoinOnlineIfDropped() async {
        guard let client, let userID = profile?.id, let channel = presenceChannel,
              channel.status == .unsubscribed else { return }
        log.info("Online channel dropped; joining again")
        await client.removeChannel(channel)
        presences = [:]
        showOnline(client: client, userID: userID)
    }

    private func stopListening() {
        listenTasks.forEach { $0.cancel() }
        listenTasks = []
        presenceTasks.forEach { $0.cancel() }
        presenceTasks = []
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
        Task { await markDelivered() }
        addToHistory(poke, friendID: poke.senderID)
        if !friends.contains(where: { $0.id == poke.senderID }) {
            refreshFriends()
        }

        if isPokeTabVisible {
            if !FocusStatus.isActive {
                AlertSound.poke.play()
            }
            return
        }

        let title = "\(poke.senderName) poked you"
        // A poke without a message shows only "… poked you".
        let body = poke.imagePath == nil || !poke.message.isEmpty ? poke.message : "📷 Picture"
        if let createdAt = poke.createdAt, Date().timeIntervalSince(createdAt) > bannerMaxAge {
            notificationManager.post(.poke, title: title, body: body)
            return
        }
        let notification = AppNotification(type: .poke, title: title, body: body, actionTitle: "Poke Back", pokeSenderID: poke.senderID, pokeSenderName: poke.senderName)
        notificationManager.postActivity(notification, keepInFeed: true)
        // The poke sound (Ping unless another is picked in Settings), so it's heard even when
        // you're not looking at the notch.
        if !FocusStatus.isActive {
            AlertSound.poke.play()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? PostgrestError {
            return error.message
        }
        if let error = error as? StorageError {
            // Row level security turns down a picture past the day's 50.
            if error.message.localizedCaseInsensitiveContains("row-level security") {
                return "That's 50 pictures today; try again tomorrow"
            }
            if error.message.localizedCaseInsensitiveContains("bucket not found") {
                return "Pictures need the latest supabase/poke.sql"
            }
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
