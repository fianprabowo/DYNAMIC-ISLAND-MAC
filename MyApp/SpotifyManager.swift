import AppKit
import Combine

/// Polls Spotify (or Apple Music as a fallback) via AppleScript for the current track.
class SpotifyManager: ObservableObject {
    @Published var currentTrack: String = "No Track"
    @Published var currentArtist: String = ""
    @Published var currentAlbum: String = ""
    @Published var isPlaying = false
    @Published var progressPercentage: CGFloat = 0
    @Published var sourceApp: MediaPlayerApp?
    @Published var artwork: NSImage?

    private var pollTask: Task<Void, Never>?
    private var artworkTrackKey: String?

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
        // Prefer whichever player is actually playing; otherwise show the first one with a track loaded.
        var snapshots: [(MediaPlayerApp, Snapshot)] = []
        for app in MediaPlayerApp.runningApps {
            if let snapshot = await fetchSnapshot(from: app) {
                snapshots.append((app, snapshot))
            }
        }
        guard let (app, snapshot) = snapshots.first(where: { $0.1.isPlaying }) ?? snapshots.first else {
            reset()
            return
        }

        if snapshot.track != currentTrack && snapshot.isPlaying {
            NotificationManager.shared.post(.music, title: snapshot.track, body: snapshot.artist)
        }

        sourceApp = app
        currentTrack = snapshot.track
        currentArtist = snapshot.artist
        currentAlbum = snapshot.album
        isPlaying = snapshot.isPlaying
        progressPercentage = snapshot.duration > 0 ? CGFloat(min(snapshot.position / snapshot.duration, 1)) : 0

        let trackKey = "\(app.rawValue)|\(snapshot.track)|\(snapshot.artist)"
        if trackKey != artworkTrackKey {
            artworkTrackKey = trackKey
            artwork = nil
            await loadArtwork(from: app, trackKey: trackKey)
        }
    }

    private func loadArtwork(from app: MediaPlayerApp, trackKey: String) async {
        let data: Data?
        switch app {
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
        currentTrack = "No Track"
        currentArtist = ""
        currentAlbum = ""
        isPlaying = false
        progressPercentage = 0
    }

    private struct Snapshot {
        let track: String
        let artist: String
        let album: String
        let position: Double
        let duration: Double
        let isPlaying: Bool
    }

    private func fetchSnapshot(from app: MediaPlayerApp) async -> Snapshot? {
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
}

enum MediaPlayerApp: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var scriptName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music: return "Music"
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
