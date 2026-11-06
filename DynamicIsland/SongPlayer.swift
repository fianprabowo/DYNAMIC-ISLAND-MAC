import AppKit

/// Plays a friend's song on this Mac: the same track in Spotify when their Spotify said which one,
/// otherwise a search for it in Spotify, or in Apple Music without Spotify.
enum SongPlayer {
    /// Only a real Spotify track id, so nothing else ever reaches the AppleScript below.
    nonisolated static func validSpotifyURI(_ uri: String) -> String? {
        uri.range(of: #"^spotify:track:[A-Za-z0-9]{10,40}$"#, options: .regularExpression) != nil ? uri : nil
    }

    static func play(_ song: PokeService.Song) {
        let hasSpotify = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MediaPlayerApp.spotify.rawValue) != nil
        let query = song.text.replacingOccurrences(of: " — ", with: " ")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if hasSpotify, let uri = song.spotifyURI.flatMap(validSpotifyURI) {
            Task { _ = await AppleScriptRunner.run("tell application \"Spotify\" to play track \"\(uri)\"") }
        } else if hasSpotify, let url = URL(string: "spotify:search:\(query)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://music.apple.com/search?term=\(query)") {
            NSWorkspace.shared.open(url)
        }
    }
}
