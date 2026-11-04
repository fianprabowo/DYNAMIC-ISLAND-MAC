import Foundation

/// The words of a song, timed line by line when the source has timings.
nonisolated struct Lyrics: Sendable {
    nonisolated struct Line: Sendable, Identifiable {
        let id: Int
        let time: TimeInterval
        let text: String
    }

    /// Lines with their start times; empty when only plain lyrics exist.
    var syncedLines: [Line] = []
    var plainText: String?
    var isInstrumental = false

    /// The line being sung at `position`, nil before the first line.
    func lineIndex(at position: TimeInterval) -> Int? {
        syncedLines.lastIndex { $0.time <= position }
    }
}

/// Fetches lyrics from LRCLIB (lrclib.net), a free lyrics database that needs no account or key.
/// Only the track's title, artist, album and length are sent, and only while the Media tab is open.
enum LyricsProvider {
    nonisolated struct Track: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
    }

    /// Nil values are tracks LRCLIB has no lyrics for, so they aren't asked for again.
    private static var cache: [Track: Lyrics?] = [:]
    private static let userAgent = "DynamicIsland (https://github.com/fianprabowo/DYNAMIC-ISLAND-MAC)"

    static func lyrics(for track: Track) async throws -> Lyrics? {
        if let cached = cache[track] {
            return cached
        }
        // The exact match needs the length within a couple of seconds; search is the fallback.
        var lyrics = try await fetchExact(track)
        if lyrics == nil {
            lyrics = try await search(track)
        }
        cache[track] = lyrics
        return lyrics
    }

    private nonisolated struct Record: Decodable {
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        let duration: Double?
    }

    private static func fetchExact(_ track: Track) async throws -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try lyrics(from: JSONDecoder().decode(Record.self, from: data))
    }

    private static func search(_ track: Track) async throws -> Lyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let records = try JSONDecoder().decode([Record].self, from: data)
        // Prefer timed lyrics from a recording of about the same length.
        let sameLength = records.filter { abs(($0.duration ?? 0) - track.duration) < 5 }
        let best = sameLength.first { $0.syncedLyrics != nil } ?? sameLength.first ?? records.first
        return best.flatMap(lyrics(from:))
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func lyrics(from record: Record) -> Lyrics? {
        var lyrics = Lyrics(plainText: record.plainLyrics, isInstrumental: record.instrumental ?? false)
        if let synced = record.syncedLyrics {
            lyrics.syncedLines = parseLRC(synced)
        }
        guard lyrics.isInstrumental || !lyrics.syncedLines.isEmpty || !(lyrics.plainText ?? "").isEmpty else { return nil }
        return lyrics
    }

    /// Reads "[mm:ss.xx] words" lines; a line may carry several timestamps when it repeats.
    static func parseLRC(_ text: String) -> [Lyrics.Line] {
        let pattern = /\[(\d+):(\d+(?:\.\d+)?)\]/
        var timed: [(TimeInterval, String)] = []
        for line in text.split(separator: "\n") {
            let stamps = line.matches(of: pattern)
            guard let last = stamps.last else { continue }
            let words = line[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                let time = (Double(stamp.output.1) ?? 0) * 60 + (Double(stamp.output.2) ?? 0)
                timed.append((time, words))
            }
        }
        return timed.sorted { $0.0 < $1.0 }.enumerated().map { Lyrics.Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
