import Foundation

/// Finds a date and time typed into a new todo, like "Kirim laporan besok jam 10" or "Call Budi
/// tomorrow 3pm", so the todo gets that time and its title loses the words.
///
/// Indonesian words are read here: hari ini, nanti, besok, lusa, the weekdays (Senin…Minggu), with
/// "jam"/"pukul" and a time like 9, 09.30 or 14:00, and pagi/siang/sore/malam. Anything else goes to
/// NSDataDetector, which reads English ("tomorrow at 3pm", "next friday").
enum TodoDateParser {
    struct Match: Equatable {
        let date: Date
        /// The title without the date's words.
        let title: String
    }

    static func parse(_ text: String, now: Date = Date()) -> Match? {
        if let match = parseIndonesian(text, now: now) {
            return match
        }
        return parseWithDetector(text, now: now)
    }

    // MARK: Indonesian

    private static let weekdays: [String: Int] = [
        "minggu": 1, "senin": 2, "selasa": 3, "rabu": 4, "kamis": 5, "jumat": 6, "jum'at": 6, "sabtu": 7,
    ]

    private static let dayPattern = #"(hari ini|nanti|besok|lusa|(?:hari )?(?:senin|selasa|rabu|kamis|jum'?at|sabtu|minggu)(?: depan)?)"#
    private static let timePattern = #"(?:jam|pukul|pkl\.?)\s*(\d{1,2})(?:[.:](\d{2}))?(?:\s*(pagi|siang|sore|malam))?"#
    private static let partPattern = #"(pagi|siang|sore|malam)"#

    private static func parseIndonesian(_ text: String, now: Date) -> Match? {
        let calendar = Calendar.current
        var ranges: [Range<String.Index>] = []
        var day: Date?
        var hour: Int?
        var minute = 0
        var part: String?

        if let match = text.firstMatch(of: try! Regex(#"\b"# + dayPattern + #"\b"#).ignoresCase()) {
            let word = String(match.output[1].substring ?? "").lowercased()
            ranges.append(match.range)
            let today = calendar.startOfDay(for: now)
            switch word {
            case "hari ini", "nanti": day = today
            case "besok": day = calendar.date(byAdding: .day, value: 1, to: today)
            case "lusa": day = calendar.date(byAdding: .day, value: 2, to: today)
            default:
                let name = word.replacingOccurrences(of: "hari ", with: "").replacingOccurrences(of: " depan", with: "")
                if let weekday = weekdays[name] {
                    var next = calendar.nextDate(after: today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
                    if word.hasSuffix(" depan"), let date = next, calendar.dateComponents([.day], from: today, to: date).day ?? 0 < 7 {
                        next = calendar.date(byAdding: .day, value: 7, to: date)
                    }
                    day = next
                }
            }
        }

        if let match = text.firstMatch(of: try! Regex(#"\b"# + timePattern + #"\b"#).ignoresCase()) {
            ranges.append(match.range)
            hour = Int(match.output[1].substring ?? "")
            minute = Int(match.output[2].substring ?? "") ?? 0
            part = match.output[3].substring.map { $0.lowercased() }
        } else if let match = text.firstMatch(of: try! Regex(#"\b"# + partPattern + #"\b"#).ignoresCase()), day != nil {
            // "besok pagi": a usual hour for that part of the day.
            ranges.append(match.range)
            part = String(match.output[1].substring ?? "").lowercased()
            hour = ["pagi": 9, "siang": 12, "sore": 16, "malam": 19][part ?? ""]
            part = nil
        }

        guard day != nil || hour != nil else { return nil }
        // "hari ini" or "nanti" alone: the next full hour; another day alone: 09.00.
        if hour == nil, let day, calendar.isDate(day, inSameDayAs: now) {
            let next = calendar.date(byAdding: .hour, value: 1, to: calendar.dateInterval(of: .hour, for: now)?.start ?? now) ?? now
            return Match(date: next, title: removing(ranges, from: text))
        }
        var hourValue = hour ?? 9
        guard hourValue < 24, minute < 60 else { return nil }
        switch part {
        case "siang" where hourValue < 11, "sore" where hourValue < 12, "malam" where hourValue < 12:
            hourValue += 12
        default:
            break
        }

        var base = day ?? calendar.startOfDay(for: now)
        guard var date = calendar.date(bySettingHour: hourValue, minute: minute, second: 0, of: base) else { return nil }
        // "jam 9" when it's already past 9 today means tomorrow; "hari ini" keeps today.
        if day == nil, date <= now, let next = calendar.date(byAdding: .day, value: 1, to: base) {
            base = next
            date = calendar.date(bySettingHour: hourValue, minute: minute, second: 0, of: base) ?? date
        }
        return Match(date: date, title: removing(ranges, from: text))
    }

    // MARK: English

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func parseWithDetector(_ text: String, now: Date) -> Match? {
        let range = NSRange(text.startIndex..., in: text)
        guard let result = detector?.firstMatch(in: text, options: [], range: range),
              var date = result.date,
              let matched = Range(result.range, in: text) else { return nil }
        // Without a time ("friday"), the morning of that day.
        let calendar = Calendar.current
        let hasTime = text[matched].rangeOfCharacter(from: .decimalDigits) != nil
            || ["noon", "evening", "morning", "afternoon", "tonight", "hour", "minute"].contains { text[matched].lowercased().contains($0) }
        if !hasTime, let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) {
            date = morning
        }
        guard date > now.addingTimeInterval(-60) else { return nil }
        return Match(date: date, title: removing([matched], from: text))
    }

    /// The text without the date's words, and without a dangling "at", "on" or "by" before them.
    private static func removing(_ ranges: [Range<String.Index>], from text: String) -> String {
        var result = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.removeSubrange(range)
        }
        result = result.replacingOccurrences(of: #"\s+(at|on|by|di|pada)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "?!"))))
    }
}
