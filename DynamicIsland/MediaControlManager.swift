import Foundation
import Combine

/// Sends playback and volume commands to Spotify, Apple Music or YouTube in Chrome via AppleScript.
class MediaControlManager: ObservableObject {
    @Published var volume: Int = 50

    private var lastCommandDate = Date.distantPast
    private let debounceInterval: TimeInterval = 0.3
    /// The player shown in the island; commands go to it so the buttons act on what's on screen.
    private weak var nowPlaying: SpotifyManager?

    init(nowPlaying: SpotifyManager? = nil) {
        self.nowPlaying = nowPlaying
        Task { await refreshVolume() }
    }

    func playPause() {
        send(.playPause)
    }

    func nextTrack() {
        send(.next)
    }

    func previousTrack() {
        send(.previous)
    }

    func seekForward(seconds: Double = 10) {
        send(.skip(seconds))
    }

    func seekBackward(seconds: Double = 10) {
        send(.skip(-seconds))
    }

    func volumeUp() {
        setVolume(volume + 10)
    }

    func volumeDown() {
        setVolume(volume - 10)
    }

    func toggleMute() {
        Task { _ = await AppleScriptRunner.run("set volume output muted (not (output muted of (get volume settings)))") }
    }

    func setVolume(_ newValue: Int) {
        volume = max(0, min(100, newValue))
        let source = "set volume output volume \(volume)"
        Task { _ = await AppleScriptRunner.run(source) }
    }

    private func refreshVolume() async {
        if let value = await AppleScriptRunner.run("output volume of (get volume settings)")?.int32Value {
            volume = Int(value)
        }
    }

    /// Jumps to `seconds` into the track. Unlike the buttons it isn't debounced: a drag sends one seek.
    func seek(to seconds: Double) {
        Task { await perform(.seek(seconds)) }
    }

    private enum Command {
        case playPause, next, previous
        case skip(Double)
        case seek(Double)

        /// The command for Spotify and Music.
        var appleScript: String {
            switch self {
            case .playPause: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            case .skip(let seconds): return "set player position to (player position + \(Int(seconds)))"
            case .seek(let seconds): return "set player position to \(max(0, seconds))"
            }
        }
    }

    private enum Player {
        case app(MediaPlayerApp)
        case youTube(tab: String)
    }

    private func send(_ command: Command) {
        guard Date().timeIntervalSince(lastCommandDate) > debounceInterval else { return }
        lastCommandDate = Date()
        Task { await perform(command) }
    }

    private func perform(_ command: Command) async {
        switch await activePlayer() {
        case .app(let app):
            await AppleScriptRunner.run("tell application \"\(app.scriptName)\" to \(command.appleScript)")
        case .youTube(let tab):
            switch command {
            case .playPause: await YouTubeBridge.playPause(tab: tab)
            case .next: await YouTubeBridge.next(tab: tab)
            case .previous: await YouTubeBridge.previous(tab: tab)
            case .skip(let seconds): await YouTubeBridge.skip(by: seconds, tab: tab)
            case .seek(let seconds): await YouTubeBridge.seek(to: seconds, tab: tab)
            }
        case nil:
            break
        }
    }

    /// The player on screen; without one, the player that is playing, otherwise the first one with
    /// something loaded. YouTube tabs count only when Chrome runs JavaScript from Apple Events.
    private func activePlayer() async -> Player? {
        if let nowPlaying, let app = nowPlaying.sourceApp {
            if app != .chrome {
                return .app(app)
            }
            if nowPlaying.canControl, let tab = nowPlaying.youTubeTab {
                return .youTube(tab: tab)
            }
        }
        var fallback: Player?
        for app in MediaPlayerApp.runningApps {
            if app == .chrome {
                let tabs = await YouTubeBridge.tabs().filter(\.isScriptable)
                if let playing = tabs.first(where: \.isPlaying) {
                    return .youTube(tab: playing.id)
                }
                if fallback == nil, let first = tabs.first {
                    fallback = .youTube(tab: first.id)
                }
            } else {
                let state = await AppleScriptRunner.run("tell application \"\(app.scriptName)\" to player state as string")?.stringValue
                if state == "playing" {
                    return .app(app)
                }
                if fallback == nil, let state, state != "stopped" {
                    fallback = .app(app)
                }
            }
        }
        return fallback
    }
}
