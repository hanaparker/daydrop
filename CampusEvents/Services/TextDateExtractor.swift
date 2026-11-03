import Foundation

/// Finds an event's date and time in free text (flyer OCR or a feed description).
/// Flyers often put the date and time on separate lines ("Thursday, Nov 6" / "7–9 PM"),
/// so a day and a time found apart are combined.
enum TextDateExtractor {
    struct Result {
        var start: Date
        var end: Date?
        var hasTime: Bool
    }

    private static let dayPattern = try! NSRegularExpression(
        pattern: #"\b(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?|mon(day)?|tue(s(day)?)?|wed(nesday)?|thu(r(s(day)?)?)?|fri(day)?|sat(urday)?|sun(day)?|today|tomorrow|tonight)\b|\b\d{1,2}/\d{1,2}\b"#,
        options: .caseInsensitive
    )
    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b\d{1,2}(:\d{2})?\s*(a\.?m\.?|p\.?m\.?)|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b"#,
        options: .caseInsensitive
    )
    private static let yearPattern = try! NSRegularExpression(pattern: #"\b20\d{2}\b"#)
    private static let rangePattern = try! NSRegularExpression(
        pattern: #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\s*(?:-|–|—|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)"#,
        options: .caseInsensitive
    )

    static func containsDay(_ text: String) -> Bool { matches(dayPattern, text) }
    static func containsTime(_ text: String) -> Bool { matches(timePattern, text) }

    static func extract(from text: String, now: Date = .now) -> Result? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let calendar = Calendar.campus
        let ns = text as NSString
        let found = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var day: (date: Date, text: String, duration: TimeInterval, hasTime: Bool)?
        var timeOnly: Date?
        for match in found {
            guard let date = match.date else { continue }
            let snippet = ns.substring(with: match.range)
            let hasDay = containsDay(snippet)
            let hasTime = containsTime(snippet)
            if hasDay, day == nil {
                day = (date, snippet, match.duration, hasTime)
            } else if !hasDay, hasTime, timeOnly == nil {
                timeOnly = date
            }
        }
        // A time with no day isn't enough to put something on a calendar.
        guard let day else { return nil }

        var start = day.date
        var hasTime = day.hasTime
        if !day.hasTime, let timeOnly {
            var parts = calendar.dateComponents([.year, .month, .day], from: day.date)
            let time = calendar.dateComponents([.hour, .minute], from: timeOnly)
            parts.hour = time.hour
            parts.minute = time.minute
            start = calendar.date(from: parts) ?? start
            hasTime = true
        }

        // "Nov 6" with no year on a flyer means the next Nov 6, not one in the past.
        if start < now.addingTimeInterval(-86_400), !matches(yearPattern, day.text),
           let nextYear = calendar.date(byAdding: .year, value: 1, to: start) {
            start = nextYear
        }

        var end: Date? = day.duration > 0 ? start.addingTimeInterval(day.duration) : nil
        if end == nil { end = rangeEnd(in: text, start: start, calendar: calendar) }
        return Result(start: start, end: end, hasTime: hasTime)
    }

    /// The end of a time range like "7–9 PM" or "6:30 to 8pm".
    private static func rangeEnd(in text: String, start: Date, calendar: Calendar) -> Date? {
        let ns = text as NSString
        guard let m = rangePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }
        guard var hour = group(4).flatMap(Int.init), hour <= 12 else { return nil }
        let minute = group(5).flatMap(Int.init) ?? 0
        let isPM = group(6)?.hasPrefix("p") ?? false
        if isPM, hour != 12 { hour += 12 }
        if !isPM, hour == 12 { hour = 0 }

        var parts = calendar.dateComponents([.year, .month, .day], from: start)
        parts.hour = hour
        parts.minute = minute
        guard let end = calendar.date(from: parts), end > start else { return nil }
        return end
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Picks out a sign-up link: a QR code on a flyer, or a link near words like "register" or "RSVP".
enum RegistrationLinkFinder {
    private static let hints = [
        "register", "registration", "rsvp", "sign up", "signup", "sign-up", "tickets",
        "eventbrite", "forms.gle", "docs.google.com/forms", "apply", "reserve"
    ]

    static func find(in text: String, qrPayloads: [String] = []) -> URL? {
        // A QR code on a flyer almost always points to the sign-up form.
        for payload in qrPayloads {
            if let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
            let lower = max(0, match.range.location - 60)
            let upper = min(ns.length, match.range.location + match.range.length + 20)
            let context = ns.substring(with: NSRange(location: lower, length: upper - lower)).lowercased()
            if hints.contains(where: { context.contains($0) }) { return url }
        }
        return nil
    }
}
