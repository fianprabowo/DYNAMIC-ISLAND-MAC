import Foundation

/// YouTube and YouTube Music playing in Google Chrome, read and controlled with JavaScript sent
/// over AppleScript. Chrome only runs that JavaScript after View › Developer › Allow JavaScript
/// from Apple Events is turned on; without it, only the tab's title and video can be shown.
nonisolated enum YouTubeBridge {
    nonisolated struct Tab: Sendable {
        /// Chrome's tab id, which it reports as text.
        let id: String
        let videoID: String?
        let title: String
        let artist: String
        let album: String
        let artworkURL: URL?
        let position: Double
        let duration: Double
        let isPlaying: Bool
        /// False when Chrome refuses JavaScript from Apple Events, so there is no position or control.
        let isScriptable: Bool
    }

    /// Every YouTube video tab, in window and tab order.
    static func tabs() async -> [Tab] {
        let source = """
        tell application "Google Chrome"
            set found to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "youtube.com/watch" or u starts with "https://music.youtube.com/watch" then
                        set info to ""
                        try
                            set info to execute t javascript "\(snapshotScript)"
                        end try
                        set end of found to {id of t, title of t, u, info}
                    end if
                end repeat
            end repeat
            return found
        end tell
        """
        guard let result = await AppleScriptRunner.run(source), result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let item = result.atIndex(index), item.numberOfItems == 4 else { return nil }
            return tab(
                id: item.atIndex(1)?.stringValue ?? "",
                title: item.atIndex(2)?.stringValue ?? "",
                url: item.atIndex(3)?.stringValue ?? "",
                info: item.atIndex(4)?.stringValue ?? ""
            )
        }
    }

    static func playPause(tab: String) async {
        await run("var v = \(videoExpression); if (v) { v.paused ? v.play() : v.pause(); }", in: tab)
    }

    static func next(tab: String) async {
        await run("var b = document.querySelector('.ytp-next-button') || document.querySelector('ytmusic-player-bar .next-button'); if (b) { b.click(); }", in: tab)
    }

    /// YouTube Music has a previous button; on YouTube, restart the video or go back after a few seconds in.
    static func previous(tab: String) async {
        await run("var b = document.querySelector('ytmusic-player-bar .previous-button'); var v = \(videoExpression); if (b) { b.click(); } else if (v && v.currentTime > 3) { v.currentTime = 0; } else { history.back(); }", in: tab)
    }

    static func seek(to seconds: Double, tab: String) async {
        await run("var v = \(videoExpression); if (v) { v.currentTime = \(max(0, seconds)); }", in: tab)
    }

    static func skip(by seconds: Double, tab: String) async {
        await run("var v = \(videoExpression); if (v) { v.currentTime = Math.max(0, v.currentTime + \(seconds)); }", in: tab)
    }

    /// Brings Chrome to the front with the video's tab selected.
    static func reveal(tab: String) async {
        await AppleScriptRunner.run("""
        tell application "Google Chrome"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (id of t as text) is "\(tab)" then
                        set active tab index of w to i
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }

    // The scripts go inside AppleScript strings, so they use single quotes only.
    /// The main player's video; YouTube pages also hold an inline preview player with its own video.
    private static let videoExpression = "(document.querySelector('#movie_player video') || document.querySelector('video.html5-main-video') || document.querySelector('video'))"

    /// The page's media session has the clean title, the channel or artist, and the thumbnail.
    private static let snapshotScript = """
    (function () { var v = \(videoExpression); if (!v) { return ''; } \
    var m = navigator.mediaSession && navigator.mediaSession.metadata; \
    var art = m && m.artwork && m.artwork.length ? m.artwork[m.artwork.length - 1].src : ''; \
    return JSON.stringify({ title: m ? m.title : '', artist: m ? m.artist : '', album: m ? m.album : '', artwork: art, \
    position: v.currentTime, duration: isFinite(v.duration) ? v.duration : 0, playing: !v.paused && !v.ended }); })()
    """

    private nonisolated struct Info: Decodable {
        let title: String
        let artist: String
        let album: String
        let artwork: String
        let position: Double
        let duration: Double
        let playing: Bool
    }

    private static func tab(id: String, title: String, url: String, info: String) -> Tab {
        let pageTitle = cleanTitle(title)
        let videoID = videoID(in: url)
        let thumbnail = videoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }

        guard let data = info.data(using: .utf8), let parsed = try? JSONDecoder().decode(Info.self, from: data) else {
            return Tab(id: id, videoID: videoID, title: pageTitle, artist: "YouTube", album: "", artworkURL: thumbnail,
                       position: 0, duration: 0, isPlaying: false, isScriptable: false)
        }
        return Tab(
            id: id,
            videoID: videoID,
            title: parsed.title.isEmpty ? pageTitle : parsed.title,
            artist: parsed.artist.isEmpty ? "YouTube" : parsed.artist,
            album: parsed.album,
            artworkURL: URL(string: parsed.artwork) ?? thumbnail,
            position: parsed.position,
            duration: parsed.duration,
            isPlaying: parsed.playing,
            isScriptable: true
        )
    }

    /// "(3) Song - YouTube" → "Song".
    private static func cleanTitle(_ title: String) -> String {
        title
            .replacing(/^\(\d+\)\s*/, with: "")
            .replacing(/\s*-\s*YouTube( Music)?$/, with: "")
    }

    private static func videoID(in url: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == "v" }?.value
    }

    private static func run(_ script: String, in tab: String) async {
        await AppleScriptRunner.run("""
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as text) is "\(tab)" then
                        execute t javascript "\(script)"
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }
}
