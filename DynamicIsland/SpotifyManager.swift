import AppKit
import Combine

/// Polls Spotify, Apple Music and YouTube in Chrome via AppleScript for the current track.
class SpotifyManager: ObservableObject {
    @Published var currentTrack: String = "No Track"
    @Published var currentArtist: String = ""
    @Published var currentAlbum: String = ""
    @Published var isPlaying = false
    @Published var progressPercentage: CGFloat = 0
    /// Playback position in seconds when it was last read, at `positionDate`.
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()
    /// Track length in seconds.
    @Published private(set) var duration: Double = 0
    @Published var sourceApp: MediaPlayerApp?
    /// False for YouTube while Chrome won't run JavaScript from Apple Events: no position or controls.
    @Published private(set) var canControl = true
    /// The YouTube video shown, for mirroring it in the Media tab.
    @Published private(set) var youTubeVideoID: String?
    /// Players with something loaded, for switching between them in the Media tab.
    @Published private(set) var availableSources: [MediaPlayerApp] = []
    @Published var artwork: NSImage?

    private var pollTask: Task<Void, Never>?
    private var artworkTrackKey: String?
    /// When the island last changed the playback itself; polls that began earlier are stale.
    private var lastLocalChange = Date.distantPast
    /// The Chrome tab of the YouTube video shown, for bringing it to the front and controlling it.
    private(set) var youTubeTab: String?
    /// The player on screen. It stays after pausing and only changes when another player starts
    /// or the user picks one, like Now Playing in macOS.
    private var shownSource: MediaPlayerApp?
    /// Players that were playing at the last poll, to tell when one starts.
    private var wasPlaying: Set<MediaPlayerApp> = []
    private var latestSnapshots: [MediaPlayerApp: Snapshot] = [:]

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    func refresh() async {
        let started = Date()
        var snapshots: [(MediaPlayerApp, Snapshot)] = []
        for app in MediaPlayerApp.runningApps {
            if let snapshot = await fetchSnapshot(from: app) {
                snapshots.append((app, snapshot))
            }
        }
        latestSnapshots = Dictionary(snapshots, uniquingKeysWith: { first, _ in first })
        availableSources = snapshots.map(\.0)

        let playing = Set(snapshots.filter { $0.1.isPlaying }.map(\.0))
        // A player that just started takes over; otherwise the one on screen stays, even paused.
        if let justStarted = snapshots.map(\.0).first(where: { playing.contains($0) && !wasPlaying.contains($0) }) {
            shownSource = justStarted
        } else if shownSource.map({ latestSnapshots[$0] == nil }) ?? true {
            shownSource = snapshots.first(where: { $0.1.isPlaying })?.0 ?? snapshots.first?.0
        }
        wasPlaying = playing

        guard let app = shownSource, let snapshot = latestSnapshots[app] else {
            reset()
            return
        }
        await show(app, snapshot, isCurrent: started > lastLocalChange)
    }

    /// Shows another player that has something loaded, from the switcher in the Media tab.
    func select(_ app: MediaPlayerApp) {
        guard app != shownSource, let snapshot = latestSnapshots[app] else { return }
        shownSource = app
        Task { await show(app, snapshot, isCurrent: true) }
    }

    /// `isCurrent` is false for a poll that began before the island changed the playback itself.
    private func show(_ app: MediaPlayerApp, _ snapshot: Snapshot, isCurrent: Bool) async {
        let switched = sourceApp != app
        sourceApp = app
        canControl = snapshot.isControllable
        youTubeTab = snapshot.youTubeTab
        if youTubeVideoID != snapshot.youTubeVideoID {
            youTubeVideoID = snapshot.youTubeVideoID
        }
        currentTrack = snapshot.track
        currentArtist = snapshot.artist
        currentAlbum = snapshot.album
        duration = snapshot.duration
        if isCurrent || switched {
            isPlaying = snapshot.isPlaying
            progressPercentage = snapshot.duration > 0 ? CGFloat(min(snapshot.position / snapshot.duration, 1)) : 0
            position = snapshot.position
            positionDate = Date()
        }

        let trackKey = "\(app.rawValue)|\(snapshot.track)|\(snapshot.artist)"
        if trackKey != artworkTrackKey {
            artworkTrackKey = trackKey
            artwork = nil
            await loadArtwork(from: app, url: snapshot.artworkURL, trackKey: trackKey)
        }
    }

    private func loadArtwork(from app: MediaPlayerApp, url: URL?, trackKey: String) async {
        let data: Data?
        switch app {
        case .chrome:
            guard let url, url.scheme == "https" else { return }
            data = try? await URLSession.shared.data(from: url).0
        case .spotify:
            guard let urlString = await AppleScriptRunner.run("tell application \"Spotify\" to artwork url of current track")?.stringValue,
                  let url = URL(string: urlString) else { return }
            data = try? await URLSession.shared.data(from: url).0
        case .music:
            data = await AppleScriptRunner.run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
        }
        // The track may have changed while the artwork loaded.
        guard artworkTrackKey == trackKey else { return }
        artwork = data.flatMap(NSImage.init(data:))
    }

    private func reset() {
        artworkTrackKey = nil
        artwork = nil
        sourceApp = nil
        canControl = true
        youTubeTab = nil
        youTubeVideoID = nil
        shownSource = nil
        availableSources = []
        currentTrack = "No Track"
        currentArtist = ""
        currentAlbum = ""
        isPlaying = false
        progressPercentage = 0
        position = 0
        duration = 0
    }

    /// Brings the player to the front; for YouTube, Chrome with the video's tab selected.
    func revealSource() {
        if sourceApp == .chrome, let youTubeTab {
            Task { await YouTubeBridge.reveal(tab: youTubeTab) }
        } else {
            sourceApp?.activate()
        }
    }

    /// Shows a seek right away instead of after the next poll.
    func showPosition(_ seconds: Double) {
        lastLocalChange = Date()
        position = seconds
        positionDate = Date()
        progressPercentage = duration > 0 ? CGFloat(min(seconds / duration, 1)) : 0
    }

    /// Shows play or pause right away instead of after the next poll.
    func showPlaybackToggled() {
        lastLocalChange = Date()
        position = currentPosition()
        positionDate = Date()
        isPlaying.toggle()
    }

    /// Reads the player again shortly after a command, once it has had time to act on it.
    func refreshSoon() {
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            await refresh()
        }
    }

    /// The playback position now, counting on from the last poll while the track plays.
    func currentPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        return duration > 0 ? min(position + elapsed, duration) : position + elapsed
    }

    private struct Snapshot {
        let track: String
        let artist: String
        let album: String
        let position: Double
        let duration: Double
        let isPlaying: Bool
        var artworkURL: URL?
        var youTubeTab: String?
        var youTubeVideoID: String?
        var isControllable = true
    }

    private func fetchSnapshot(from app: MediaPlayerApp) async -> Snapshot? {
        if app == .chrome {
            return await fetchYouTubeSnapshot()
        }
        // Spotify reports duration in milliseconds, Music in seconds.
        let durationExpression = app == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let source = """
        tell application "\(app.scriptName)"
            if player state is stopped then return {}
            return {name of current track, artist of current track, player position, \(durationExpression), player state as string, album of current track}
        end tell
        """

        guard let result = await AppleScriptRunner.run(source), result.numberOfItems == 6,
              let track = result.atIndex(1)?.stringValue, !track.isEmpty else { return nil }

        return Snapshot(
            track: track,
            artist: result.atIndex(2)?.stringValue ?? "",
            album: result.atIndex(6)?.stringValue ?? "",
            position: result.atIndex(3)?.doubleValue ?? 0,
            duration: result.atIndex(4)?.doubleValue ?? 0,
            isPlaying: result.atIndex(5)?.stringValue == "playing"
        )
    }

    /// The playing YouTube tab, otherwise the first one.
    private func fetchYouTubeSnapshot() async -> Snapshot? {
        let tabs = await YouTubeBridge.tabs()
        guard let tab = tabs.first(where: \.isPlaying) ?? tabs.first, !tab.title.isEmpty else { return nil }
        return Snapshot(
            track: tab.title,
            artist: tab.artist,
            album: tab.album,
            position: tab.position,
            duration: tab.duration,
            isPlaying: tab.isPlaying,
            artworkURL: tab.artworkURL,
            youTubeTab: tab.id,
            youTubeVideoID: tab.videoID,
            isControllable: tab.isScriptable
        )
    }
}

enum MediaPlayerApp: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"
    /// YouTube in a Chrome tab (see YouTubeBridge).
    case chrome = "com.google.Chrome"

    var scriptName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
        case .chrome: return "Google Chrome"
        }
    }

    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Brings the player to the front, e.g. when its album art is clicked.
    func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).first?.activate()
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty
    }

    /// Only running players are queried, so AppleScript never launches an app on its own.
    static var runningApps: [MediaPlayerApp] {
        allCases.filter(\.isRunning)
    }
}

/// Runs scripts one at a time on a background queue. A script waits for its target app, and for
/// the user to answer macOS's Automation prompt; on the main thread that froze the whole island.
nonisolated enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "AppleScriptRunner")

    @discardableResult
    static func run(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result : nil)
            }
        }
    }
}
