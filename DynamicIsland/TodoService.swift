import AppKit
import Combine
import Foundation
import OSLog
import Supabase

/// The Todo tab's lists, kept in the Supabase project Poke uses (its table and rules are in
/// supabase/todo.sql), under the same anonymous sign-in: your own todos, and the ones you share
/// with a friend, which you both can add to, tick off and delete. A change to either list reaches
/// the other Mac at once through Realtime, and the lists are read again then.
///
/// Ticking off and deleting show at once and are undone if Supabase turns them down; a new todo
/// shows once Supabase has given it its id.
///
/// When an open todo's time comes, yours or one shared with any friend, the notch drops down with
/// it and the todo sound plays (picked in Settings), once, also during a Focus, and it's kept in the Alerts tab.
class TodoService: ObservableObject {
    static let shared = TodoService()

    nonisolated struct Todo: Identifiable, Decodable, Equatable, Sendable {
        let id: Int
        var title: String
        var isDone: Bool
        /// Who added it.
        let userID: UUID
        /// The friend it's shared with; nil for your own.
        let friendID: UUID?
        /// When it's due, if it has a date and time.
        var dueAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, title
            case isDone = "is_done"
            case userID = "user_id"
            case friendID = "friend_id"
            case dueAt = "due_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            isDone = try container.decode(Bool.self, forKey: .isDone)
            userID = try container.decode(UUID.self, forKey: .userID)
            friendID = try container.decodeIfPresent(UUID.self, forKey: .friendID)
            // Postgres sends a timestamptz like "2026-11-06T07:00:00+00:00", read here as text so
            // it doesn't depend on the client's date decoding.
            dueAt = (try container.decodeIfPresent(String.self, forKey: .dueAt)).flatMap(TodoService.date(from:))
        }

        /// Still open after its time.
        func isOverdue(at now: Date = Date()) -> Bool {
            guard let dueAt, !isDone else { return false }
            return dueAt < now
        }
    }

    enum State: Equatable {
        /// Poke's Supabase project isn't set up yet.
        case needsProject
        case loading
        case ready
        /// supabase/todo.sql hasn't been run in the project, or an older version of it has.
        case needsTable
        case failed(String)
    }

    /// Your own todos.
    @Published private(set) var todos: [Todo] = []
    /// The todos you share with `sharedFriend`.
    @Published private(set) var sharedTodos: [Todo] = []
    @Published private(set) var state: State = .needsProject
    /// What went wrong with the last change, shown under the list.
    @Published var actionError: String?
    /// A new todo on its way to Supabase.
    @Published private(set) var isAdding = false
    /// The friend picked for the shared list; the first friend until one is picked.
    @Published var sharedFriendID: UUID? {
        didSet {
            UserDefaults.standard.set(sharedFriendID?.uuidString, forKey: Self.sharedFriendKey)
            guard sharedFriendID != oldValue else { return }
            sharedTodos = []
            refresh()
        }
    }

    static let maxTitleLength = 200

    private static let columns = "id, title, is_done, user_id, friend_id, due_at"
    private static let sharedFriendKey = "todoSharedFriendID"

    private let poke = PokeService.shared
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Todo")
    private var cancellables: Set<AnyCancellable> = []
    private var channel: (client: SupabaseClient, channel: RealtimeChannelV2)?
    private var channelTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    /// Every open todo with a time you can see, in any list, for the reminders.
    private var dueTodos: [Todo] = []
    private var reminderTask: Task<Void, Never>?
    /// Reminders already shown, as "id@due time", so each shows once, also across launches.
    private var remindedKeys: [String] = UserDefaults.standard.stringArray(forKey: TodoService.remindedKey) ?? []

    private static let remindedKey = "todoRemindedKeys"
    /// A todo whose time passed longer ago than this, like while the Mac was off, isn't announced.
    private static let reminderGrace: TimeInterval = 15 * 60

    private nonisolated struct NewTodo: Encodable, Sendable {
        let title: String
        let friendID: UUID?
        /// ISO 8601, like "2026-11-06T07:00:00Z".
        let dueAt: String?

        enum CodingKeys: String, CodingKey {
            case title
            case friendID = "friend_id"
            case dueAt = "due_at"
        }
    }

    private init() {
        sharedFriendID = UserDefaults.standard.string(forKey: Self.sharedFriendKey).flatMap(UUID.init(uuidString:))
        // Signed in once Poke is ready, or waiting for a name; a new project starts new lists.
        poke.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in self?.pokeStateChanged(state) }
        }
        .store(in: &cancellables)
        // A friend added or removed can change whose shared list shows.
        poke.$friends.map { $0.map(\.id) }.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        .store(in: &cancellables)
    }

    /// You, as Supabase knows you.
    var userID: UUID? { poke.client?.auth.currentUser?.id }

    /// The friend whose shared list shows: the one picked, while still a friend, or the first.
    var sharedFriend: PokeService.Friend? {
        if let id = sharedFriendID, let friend = poke.friends.first(where: { $0.id == id }) { return friend }
        return poke.friends.first
    }

    func remainingCount(shared: Bool) -> Int { list(shared).filter { !$0.isDone }.count }
    func hasDone(shared: Bool) -> Bool { list(shared).contains(where: \.isDone) }

    /// The friend's name for a todo they added to a shared list; nil for one you added.
    func adderName(of todo: Todo) -> String? {
        guard todo.userID != userID else { return nil }
        return poke.friends.first(where: { $0.id == todo.userID })?.name
    }

    /// Reads the lists again, like when the tab opens.
    func refresh() {
        guard state == .ready || state == .needsTable || isFailed else { return }
        Task { await load() }
    }

    /// Adds a todo to your own list, or to the one shared with `sharedFriend`, due at `due` if given.
    func add(_ title: String, due: Date?, shared: Bool) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        let friendID = shared ? sharedFriend?.id : nil
        guard !title.isEmpty, let client = poke.client, state == .ready, !shared || friendID != nil else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let dueAt = due.map { ISO8601DateFormatter().string(from: $0) }
                let todo: Todo = try await client.from("todos").insert(NewTodo(title: title, friendID: friendID, dueAt: dueAt))
                    .select(Self.columns).single().execute().value
                actionError = nil
                if todo.friendID == nil {
                    if !todos.contains(where: { $0.id == todo.id }) { todos.append(todo) }
                } else if todo.friendID == sharedFriend?.id {
                    if !sharedTodos.contains(where: { $0.id == todo.id }) { sharedTodos.append(todo) }
                }
                if todo.dueAt != nil, !dueTodos.contains(where: { $0.id == todo.id }) {
                    dueTodos.append(todo)
                    scheduleReminder()
                }
                sort()
            } catch {
                report(error, doing: "add")
            }
        }
    }

    func toggle(_ todo: Todo) {
        guard let client = poke.client else { return }
        let isDone = !todo.isDone
        change(todo.id) { $0.isDone = isDone }
        Task {
            do {
                try await client.from("todos").update(["is_done": isDone]).eq("id", value: todo.id).execute()
                actionError = nil
            } catch {
                change(todo.id) { $0.isDone = !isDone }
                report(error, doing: "change")
            }
        }
    }

    /// Changes a todo's title, like after editing it in place.
    func rename(_ todo: Todo, to title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard let client = poke.client, !title.isEmpty, title != todo.title else { return }
        let old = todo.title
        change(todo.id) { $0.title = title }
        Task {
            do {
                try await client.from("todos").update(["title": title]).eq("id", value: todo.id).execute()
                actionError = nil
            } catch {
                change(todo.id) { $0.title = old }
                report(error, doing: "change")
            }
        }
    }

    /// Moves a todo to another time, or takes its time away; a new time is reminded of again.
    func setDue(_ todo: Todo, _ due: Date?) {
        guard let client = poke.client, due != todo.dueAt else { return }
        let old = todo.dueAt
        applyDue(todo, due)
        Task {
            do {
                let value: String? = due.map { ISO8601DateFormatter().string(from: $0) }
                try await client.from("todos").update(["due_at": value]).eq("id", value: todo.id).execute()
                actionError = nil
            } catch {
                applyDue(todo, old)
                report(error, doing: "change")
            }
        }
    }

    private func applyDue(_ todo: Todo, _ due: Date?) {
        if due == nil {
            dueTodos.removeAll { $0.id == todo.id }
        } else if !dueTodos.contains(where: { $0.id == todo.id }), !todo.isDone {
            dueTodos.append(todo)
        }
        change(todo.id) { $0.dueAt = due }
    }

    func delete(_ todo: Todo) {
        guard let client = poke.client else { return }
        todos.removeAll { $0.id == todo.id }
        sharedTodos.removeAll { $0.id == todo.id }
        dueTodos.removeAll { $0.id == todo.id }
        Task {
            do {
                try await client.from("todos").delete().eq("id", value: todo.id).execute()
                actionError = nil
            } catch {
                report(error, doing: "delete")
                await load()
            }
        }
    }

    /// Deletes every ticked-off todo in your own list, or in the shared one.
    func clearDone(shared: Bool) {
        guard let client = poke.client, hasDone(shared: shared) else { return }
        let ids = list(shared).filter(\.isDone).map(\.id)
        todos.removeAll { ids.contains($0.id) }
        sharedTodos.removeAll { ids.contains($0.id) }
        dueTodos.removeAll { ids.contains($0.id) }
        Task {
            do {
                try await client.from("todos").delete().in("id", values: ids).execute()
                actionError = nil
            } catch {
                report(error, doing: "delete")
                await load()
            }
        }
    }

    // MARK: Loading

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func list(_ shared: Bool) -> [Todo] { shared ? sharedTodos : todos }

    private func change(_ id: Int, _ update: (inout Todo) -> Void) {
        if let index = todos.firstIndex(where: { $0.id == id }) { update(&todos[index]) }
        if let index = sharedTodos.firstIndex(where: { $0.id == id }) { update(&sharedTodos[index]) }
        if let index = dueTodos.firstIndex(where: { $0.id == id }) { update(&dueTodos[index]) }
        sort()
        scheduleReminder()
    }

    private func pokeStateChanged(_ pokeState: PokeService.State) {
        switch pokeState {
        case .notConfigured:
            stopListening()
            todos = []
            sharedTodos = []
            dueTodos = []
            scheduleReminder()
            state = .needsProject
        case .connecting:
            stopListening()
            todos = []
            sharedTodos = []
            state = .loading
        case .needsName, .ready:
            Task { await load() }
        case .failed(let message):
            // Offline, say: keep what's shown, and load once Poke connects again.
            if todos.isEmpty && sharedTodos.isEmpty {
                state = .failed(message)
            }
        }
    }

    private func load() async {
        guard let client = poke.client, let me = client.auth.currentUser?.id else {
            state = .needsProject
            return
        }
        if state != .ready {
            state = .loading
        }
        let friend = sharedFriend?.id
        do {
            let mine: [Todo] = try await client.from("todos").select(Self.columns)
                .eq("user_id", value: me).filter("friend_id", operator: "is", value: "null")
                .order("id").execute().value
            var shared: [Todo] = []
            if let friend {
                let (me, friend) = (me.uuidString.lowercased(), friend.uuidString.lowercased())
                shared = try await client.from("todos").select(Self.columns)
                    .or("and(user_id.eq.\(me),friend_id.eq.\(friend)),and(user_id.eq.\(friend),friend_id.eq.\(me))")
                    .order("id").execute().value
            }
            // Row level security leaves yours and the ones shared with you, with any friend.
            let due: [Todo] = try await client.from("todos").select(Self.columns)
                .filter("due_at", operator: "not.is", value: "null").eq("is_done", value: false)
                .order("due_at").limit(400).execute().value
            // Change Project, or another friend, took over meanwhile.
            guard poke.client === client, sharedFriend?.id == friend else { return }
            todos = mine
            sharedTodos = shared
            dueTodos = due
            sort()
            scheduleReminder()
            state = .ready
            listen(client: client, userID: me)
        } catch {
            guard poke.client === client else { return }
            if Self.needsSQL(error) {
                log.info("The todos table isn't up to date: \(String(describing: error), privacy: .public)")
                state = .needsTable
            } else {
                log.error("Couldn't load todos: \(String(describing: error), privacy: .public)")
                state = .failed(Self.describe(error))
            }
        }
    }

    /// Any change to a todo you can see, yours or shared with you, reads the lists again.
    private func listen(client: SupabaseClient, userID: UUID) {
        guard channel?.client !== client else { return }
        stopListening()
        let channel = client.channel("todos:\(userID.uuidString.lowercased())")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "todos")
        self.channel = (client, channel)
        channelTask = Task { [weak self] in
            for await _ in changes {
                self?.scheduleReload()
            }
        }
        Task { [log] in
            do {
                try await channel.subscribeWithError()
            } catch {
                log.error("Todo Realtime subscribe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func stopListening() {
        channelTask?.cancel()
        channelTask = nil
        if let current = channel {
            Task { await current.client.removeChannel(current.channel) }
        }
        channel = nil
    }

    // MARK: Reminders

    /// Waits for the next open todo's time, then announces every one that's due.
    private func scheduleReminder() {
        reminderTask?.cancel()
        let now = Date()
        let next = dueTodos
            .filter { !$0.isDone && !remindedKeys.contains(Self.reminderKey($0)) }
            .compactMap(\.dueAt)
            .filter { $0 > now.addingTimeInterval(-Self.reminderGrace) }
            .min()
        guard let next else { return }
        reminderTask = Task { [weak self] in
            let wait = next.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled, let self else { return }
            announceDue()
            scheduleReminder()
        }
    }

    private func announceDue() {
        let now = Date()
        for todo in dueTodos where !todo.isDone {
            guard let dueAt = todo.dueAt, dueAt <= now, now.timeIntervalSince(dueAt) < Self.reminderGrace else { continue }
            let key = Self.reminderKey(todo)
            guard !remindedKeys.contains(key) else { continue }
            remindedKeys.append(key)
            let body = sharedName(of: todo).map { "Due now · shared with \($0)" } ?? "Due now"
            NotificationManager.shared.postActivity(AppNotification(type: .todo, title: todo.title, body: body),
                                                    keepInFeed: true, duringFocus: true)
            AlertSound.todo.play()
            log.info("Reminded of todo \(todo.id, privacy: .public)")
        }
        remindedKeys = Array(remindedKeys.suffix(200))
        UserDefaults.standard.set(remindedKeys, forKey: Self.remindedKey)
    }

    /// The friend a todo is shared with, from your side: the one who isn't you.
    private func sharedName(of todo: Todo) -> String? {
        guard let friendID = todo.friendID else { return nil }
        let other = todo.userID == userID ? friendID : todo.userID
        return poke.friends.first(where: { $0.id == other })?.name
    }

    /// A todo moved to another time is announced again.
    private static func reminderKey(_ todo: Todo) -> String {
        "\(todo.id)@\(Int(todo.dueAt?.timeIntervalSince1970 ?? 0))"
    }

    /// A few changes in a row, like Clear Done, read the lists once.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// Open todos first, the ones with a date by when they're due and then the rest; then the
    /// ticked-off ones. Otherwise in the order they were added.
    private func sort() {
        let order: (Todo, Todo) -> Bool = { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if !a.isDone, a.dueAt != b.dueAt {
                switch (a.dueAt, b.dueAt) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): break
                }
            }
            return a.id < b.id
        }
        todos.sort(by: order)
        sharedTodos.sort(by: order)
    }

    /// A timestamptz from Postgres, whose fraction of a second, if any, is dropped first.
    nonisolated static func date(from string: String) -> Date? {
        ISO8601DateFormatter().date(from: string.replacing(/\.\d+/, with: ""))
    }

    private func report(_ error: Error, doing action: String) {
        log.error("Couldn't \(action, privacy: .public) a todo: \(String(describing: error), privacy: .public)")
        if Self.needsSQL(error) {
            state = .needsTable
        } else {
            actionError = "Couldn't \(action) the todo: \(Self.describe(error))"
        }
    }

    /// PostgREST answers PGRST205 for a table it doesn't know and PGRST204 for a column; Postgres
    /// itself answers 42P01 and 42703. Either way, supabase/todo.sql needs running.
    private static func needsSQL(_ error: Error) -> Bool {
        guard let error = error as? PostgrestError, let code = error.code else { return false }
        return ["PGRST205", "PGRST204", "42P01", "42703"].contains(code)
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? PostgrestError {
            return error.message
        }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet ? "You're offline" : error.localizedDescription
        }
        return error.localizedDescription
    }
}
