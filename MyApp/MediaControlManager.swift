import Foundation
import Combine

/// Sends playback and volume commands to Spotify / Apple Music via AppleScript.
class MediaControlManager: ObservableObject {
    @Published var volume: Int = 50

    private var lastCommandDate = Date.distantPast
    private let debounceInterval: TimeInterval = 0.3

    init() {
        refreshVolume()
    }

    func playPause() {
        sendToPlayer("playpause")
    }

    func nextTrack() {
        sendToPlayer("next track")
    }

    func previousTrack() {
        sendToPlayer("previous track")
    }

    func seekForward(seconds: Double = 10) {
        sendToPlayer("set player position to (player position + \(Int(seconds)))")
    }

    func seekBackward(seconds: Double = 10) {
        sendToPlayer("set player position to (player position - \(Int(seconds)))")
    }

    func volumeUp() {
        setVolume(volume + 10)
    }

    func volumeDown() {
        setVolume(volume - 10)
    }

    func toggleMute() {
        AppleScriptRunner.run("set volume output muted (not (output muted of (get volume settings)))")
    }

    func setVolume(_ newValue: Int) {
        volume = max(0, min(100, newValue))
        AppleScriptRunner.run("set volume output volume \(volume)")
    }

    private func refreshVolume() {
        if let value = AppleScriptRunner.run("output volume of (get volume settings)")?.int32Value {
            volume = Int(value)
        }
    }

    private func sendToPlayer(_ command: String) {
        guard Date().timeIntervalSince(lastCommandDate) > debounceInterval else { return }
        lastCommandDate = Date()

        guard let app = activePlayer() else { return }
        AppleScriptRunner.run("tell application \"\(app.scriptName)\" to \(command)")
    }

    /// The player that is currently playing, otherwise the first one that is running.
    private func activePlayer() -> MediaPlayerApp? {
        let running = MediaPlayerApp.runningApps
        let playing = running.first { app in
            AppleScriptRunner.run("tell application \"\(app.scriptName)\" to player state as string")?.stringValue == "playing"
        }
        return playing ?? running.first
    }
}
