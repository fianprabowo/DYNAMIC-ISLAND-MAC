import Combine
import Foundation
import OSLog
import Supabase

/// The Todo tab's list, kept in the Supabase project Poke uses (its table and rules are in
/// supabase/todo.sql), under the same anonymous sign-in. Each person sees only their own todos.
///
/// Ticking off and deleting show at once and are undone if Supabase turns them down; a new todo
/// shows once Supabase has given it its id.
class TodoService: ObservableObject {
    static let shared = TodoService()

    nonisolated struct Todo: Identifiable, Decodable, Equatable, Sendable {
        let id: Int
        var title: String
        var isDone: Bool

        enum CodingKeys: String, CodingKey {
            case id, title
            case isDone = "is_done"
        }
    }

    enum State: Equatable {
        /// Poke's Supabase project isn't set up yet.
        case needsProject
        case loading
        case ready
        /// supabase/todo.sql hasn't been run in the project.
        case needsTable
        case failed(String)
    }

    @Published private(set) var todos: [Todo] = []
    @Published private(set) var state: State = .needsProject
    /// What went wrong with the last change, shown under the list.
    @Published var actionError: String?
    /// A new todo on its way to Supabase.
    @Published private(set) var isAdding = false

    static let maxTitleLength = 200

    private let poke = PokeService.shared
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Todo")
    private var pokeState: AnyCancellable?

    private nonisolated struct NewTodo: Encodable, Sendable {
        let title: String
    }

    private init() {
        // Signed in once Poke is ready, or waiting for a name; a new project starts a new list.
        pokeState = poke.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in self?.pokeStateChanged(state) }
        }
    }

    var remainingCount: Int { todos.filter { !$0.isDone }.count }
    var hasDone: Bool { todos.contains(where: \.isDone) }

    /// Reads the list again, like when the tab opens.
    func refresh() {
        guard state == .ready || state == .needsTable || isFailed else { return }
        Task { await load() }
    }

    func add(_ title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard !title.isEmpty, let client = poke.client, state == .ready else { return }
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let todo: Todo = try await client.from("todos").insert(NewTodo(title: title)).select("id, title, is_done").single().execute().value
                actionError = nil
                todos.append(todo)
                sort()
            } catch {
                report(error, doing: "add")
            }
        }
    }

    func toggle(_ todo: Todo) {
        guard let client = poke.client, let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        let isDone = !todos[index].isDone
        todos[index].isDone = isDone
        sort()
        Task {
            do {
                try await client.from("todos").update(["is_done": isDone]).eq("id", value: todo.id).execute()
                actionError = nil
            } catch {
                if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                    todos[index].isDone = !isDone
                    sort()
                }
                report(error, doing: "change")
            }
        }
    }

    func delete(_ todo: Todo) {
        guard let client = poke.client else { return }
        todos.removeAll { $0.id == todo.id }
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

    /// Deletes every ticked-off todo.
    func clearDone() {
        guard let client = poke.client, hasDone else { return }
        todos.removeAll(where: \.isDone)
        Task {
            do {
                try await client.from("todos").delete().eq("is_done", value: true).execute()
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

    private func pokeStateChanged(_ pokeState: PokeService.State) {
        switch pokeState {
        case .notConfigured:
            todos = []
            state = .needsProject
        case .connecting:
            todos = []
            state = .loading
        case .needsName, .ready:
            Task { await load() }
        case .failed(let message):
            // Offline, say: keep what's shown, and load once Poke connects again.
            if todos.isEmpty {
                state = .failed(message)
            }
        }
    }

    private func load() async {
        guard let client = poke.client else {
            state = .needsProject
            return
        }
        if todos.isEmpty {
            state = .loading
        }
        do {
            let loaded: [Todo] = try await client.from("todos").select("id, title, is_done").order("id").execute().value
            // Change Project took over meanwhile.
            guard poke.client === client else { return }
            todos = loaded
            sort()
            state = .ready
            log.info("Loaded \(loaded.count, privacy: .public) todos")
        } catch {
            guard poke.client === client else { return }
            if Self.isMissingTable(error) {
                log.info("The todos table isn't in the project yet: \(String(describing: error), privacy: .public)")
                state = .needsTable
            } else {
                log.error("Couldn't load todos: \(String(describing: error), privacy: .public)")
                state = .failed(Self.describe(error))
            }
        }
    }

    /// Open todos first and then the ticked-off ones, each in the order they were added.
    private func sort() {
        todos.sort { ($0.isDone ? 1 : 0, $0.id) < ($1.isDone ? 1 : 0, $1.id) }
    }

    private func report(_ error: Error, doing action: String) {
        log.error("Couldn't \(action, privacy: .public) a todo: \(String(describing: error), privacy: .public)")
        if Self.isMissingTable(error) {
            state = .needsTable
        } else {
            actionError = "Couldn't \(action) the todo: \(Self.describe(error))"
        }
    }

    /// PostgREST answers PGRST205 for a table it doesn't know; Postgres itself answers 42P01.
    private static func isMissingTable(_ error: Error) -> Bool {
        guard let error = error as? PostgrestError else { return false }
        return error.code == "PGRST205" || error.code == "42P01"
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
