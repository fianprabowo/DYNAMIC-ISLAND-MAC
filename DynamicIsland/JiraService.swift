import AppKit
import Combine
import Foundation
import OSLog

/// The Jira issues assigned to you in your open sprints, beside your own todos in the Todo tab.
/// They're read from Jira Cloud's REST API with your own API token; nothing is changed in Jira.
///
/// The site, email and token come from the zsh config (see `ShellConfig`):
/// `JIRA_SITE=yoursite.atlassian.net`, `JIRA_EMAIL=you@company.com` and `JIRA_API_TOKEN=…`.
/// The token is kept in memory only and sent to that Jira Cloud site only, never logged.
class JiraService: ObservableObject {
    static let shared = JiraService()

    nonisolated struct Issue: Identifiable, Equatable, Sendable {
        enum Progress: Int, Comparable, Sendable {
            case inProgress, toDo, done

            static func < (lhs: Progress, rhs: Progress) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        let id: String
        let key: String
        let summary: String
        /// The status's own name, like "In QA".
        let status: String
        let progress: Progress
    }

    nonisolated struct Sprint: Equatable, Sendable {
        let name: String
        let endsAt: Date?
    }

    enum State: Equatable {
        /// JIRA_SITE, JIRA_EMAIL or JIRA_API_TOKEN isn't in the zsh config.
        case needsSetup
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var issues: [Issue] = []
    @Published private(set) var sprint: Sprint?
    @Published private(set) var state: State = .loading
    @Published private(set) var isRefreshing = false

    static let siteVariable = "JIRA_SITE"
    static let emailVariable = "JIRA_EMAIL"
    static let tokenVariable = "JIRA_API_TOKEN"

    /// Issues in your open sprints, the ones in progress first, then in the board's order.
    private static let jql = "assignee = currentUser() AND sprint in openSprints() ORDER BY rank ASC"
    /// Opening the tab reads Jira again when the list is older than this.
    private static let staleAfter: TimeInterval = 60

    private nonisolated struct Config: Sendable {
        let host: String
        let authorization: String
    }

    private nonisolated enum JiraError: Error {
        case unauthorized
        case forbidden
        case http(Int)
        case unreadable
    }

    private var config: Config?
    private var loadedAt: Date?
    /// The id of Jira's Sprint field, looked up once; nil while it hasn't been, "" when there's none.
    private var sprintField: String?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicIsland", category: "Jira")
    /// Ephemeral: nothing about the requests is kept on disk. Redirects aren't followed, so the
    /// token never goes to another host.
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private init() {}

    var openCount: Int { issues.filter { $0.progress != .done }.count }
    var doneCount: Int { issues.filter { $0.progress == .done }.count }

    func refreshIfStale() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.staleAfter, state == .ready { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            await load()
        }
    }

    /// Opens the issue in the browser.
    func open(_ issue: Issue) {
        guard let host = config?.host, let url = URL(string: "https://\(host)/browse/\(issue.key)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Loading

    private func load() async {
        if config == nil {
            switch await Self.readConfig() {
            case .missing:
                issues = []
                sprint = nil
                state = .needsSetup
                return
            case .badSite:
                state = .failed("\(Self.siteVariable) should be your Jira Cloud site, like yoursite.atlassian.net")
                return
            case .ready(let config):
                self.config = config
            }
        }
        guard let config else { return }
        if issues.isEmpty {
            state = .loading
        }
        do {
            if sprintField == nil {
                sprintField = (try? await findSprintField(config)) ?? ""
            }
            let (issues, sprint) = try await fetchIssues(config, sprintField: sprintField ?? "")
            self.issues = issues
            self.sprint = sprint
            loadedAt = Date()
            state = .ready
            log.info("Loaded \(issues.count, privacy: .public) Jira issues")
        } catch JiraError.unauthorized {
            // Read the config again next time, in case the token was changed.
            self.config = nil
            state = .failed("Jira turned down \(Self.emailVariable) or \(Self.tokenVariable). Check them in your zsh config.")
        } catch JiraError.forbidden {
            state = .failed("Jira doesn't let this API token search issues.")
        } catch JiraError.http(let status) {
            log.error("Jira answered HTTP \(status, privacy: .public)")
            state = .failed("Jira answered with an error (HTTP \(status)).")
        } catch JiraError.unreadable {
            state = .failed("Jira's answer couldn't be read.")
        } catch {
            log.error("Couldn't reach Jira: \(String(describing: error), privacy: .public)")
            state = .failed((error as? URLError)?.code == .notConnectedToInternet ? "You're offline" : "Couldn't reach Jira.")
        }
    }

    private nonisolated enum ConfigResult: Sendable {
        case missing
        case badSite
        case ready(Config)
    }

    private static func readConfig() async -> ConfigResult {
        let values = await ShellConfig.values([siteVariable, emailVariable, tokenVariable])
        guard let site = values[siteVariable], let email = values[emailVariable], let token = values[tokenVariable] else {
            return .missing
        }
        // "yoursite.atlassian.net", with or without https:// and a path.
        guard let host = URL(string: site.contains("://") ? site : "https://\(site)")?.host()?.lowercased(),
              site.hasPrefix("https://") || !site.contains("://"),
              host.hasSuffix(".atlassian.net") else {
            return .badSite
        }
        let credentials = Data("\(email):\(token)".utf8).base64EncodedString()
        return .ready(Config(host: host, authorization: "Basic \(credentials)"))
    }

    /// Jira's Sprint field is a custom field whose id differs from site to site.
    private func findSprintField(_ config: Config) async throws -> String {
        let data = try await get("/rest/api/3/field", query: [], config: config)
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw JiraError.unreadable }
        let sprint = fields.first {
            ($0["schema"] as? [String: Any])?["custom"] as? String == "com.pyxis.greenhopper.jira:gh-sprint"
        }
        return sprint?["id"] as? String ?? ""
    }

    private func fetchIssues(_ config: Config, sprintField: String) async throws -> ([Issue], Sprint?) {
        let fields = ["summary", "status"] + (sprintField.isEmpty ? [] : [sprintField])
        let data = try await get("/rest/api/3/search/jql", query: [
            URLQueryItem(name: "jql", value: Self.jql),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
            URLQueryItem(name: "maxResults", value: "100"),
        ], config: config)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = object["issues"] as? [[String: Any]] else { throw JiraError.unreadable }

        var issues: [(rank: Int, issue: Issue)] = []
        var sprints: [Sprint] = []
        for (rank, item) in found.enumerated() {
            guard let id = item["id"] as? String, let key = item["key"] as? String,
                  let fields = item["fields"] as? [String: Any] else { continue }
            let status = fields["status"] as? [String: Any]
            let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String
            let progress: Issue.Progress = category == "done" ? .done : category == "indeterminate" ? .inProgress : .toDo
            issues.append((rank, Issue(id: id, key: key, summary: fields["summary"] as? String ?? key,
                                       status: status?["name"] as? String ?? "", progress: progress)))
            for value in fields[sprintField] as? [[String: Any]] ?? [] where value["state"] as? String == "active" {
                if let name = value["name"] as? String {
                    sprints.append(Sprint(name: name, endsAt: Self.date(value["endDate"])))
                }
            }
        }
        issues.sort { ($0.issue.progress, $0.rank) < ($1.issue.progress, $1.rank) }
        // An issue carried over can be in more than one sprint; the active one most issues are in.
        let sprint = Dictionary(grouping: sprints, by: \.name).max { $0.value.count < $1.value.count }?.value.first
        return (issues.map(\.issue), sprint)
    }

    private func get(_ path: String, query: [URLQueryItem], config: Config) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw JiraError.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(config.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401: throw JiraError.unauthorized
        case 403: throw JiraError.forbidden
        case let status: throw JiraError.http(status)
        }
    }

    /// An ISO 8601 time like "2026-11-12T10:00:00.000Z", whose fraction of a second is dropped first.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string.replacing(/\.\d+/, with: ""))
    }
}

/// Turns down every redirect, so a request's Authorization header stays with the host it was for.
nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    // The completion handler form: the async one crashes the Swift 6.4 compiler.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
