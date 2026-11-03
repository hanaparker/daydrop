import Foundation

/// One event read from a department feed or events page.
struct FeedEvent: Hashable {
    var uid: String
    var title: String
    var start: Date
    var end: Date?
    var location: String
    var details: String
    var url: URL?
    var registrationURL: URL?
}

enum FeedError: LocalizedError {
    case badURL
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That link doesn't look like a web address."
        case .badResponse(let code): return "The site responded with an error (\(code))."
        }
    }
}

/// Downloads a department's events and reads them, whatever format the site publishes:
/// an iCal feed, an RSS/Atom feed, or an events web page with schema.org event markup.
enum FeedFetcher {
    static func fetchEvents(from url: URL) async throws -> [FeedEvent] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("CampusEvents/1.0 (student events app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.badResponse(http.statusCode)
        }
        let text = String(decoding: data, as: UTF8.self)

        if text.contains("BEGIN:VCALENDAR") {
            return ICSParser.parse(text)
        }
        let head = text.prefix(1000).lowercased()
        if head.contains("<rss") || head.contains("<feed") || head.contains("<rdf") {
            return RSSEventParser.parse(data)
        }
        return JSONLDEventExtractor.extract(fromHTML: text, baseURL: url)
    }
}

// MARK: - iCal (.ics)

enum ICSParser {
    private typealias Property = (params: [String: String], value: String)

    static func parse(_ text: String) -> [FeedEvent] {
        // Long lines are "folded" onto the next line with a leading space; join them back.
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(raw)
            }
        }

        var events: [FeedEvent] = []
        var current: [String: Property]?
        for line in lines {
            if line == "BEGIN:VEVENT" { current = [:]; continue }
            if line == "END:VEVENT" {
                if let props = current, let event = makeEvent(props) { events.append(event) }
                current = nil
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let nameAndParams = line[..<colon].split(separator: ";").map(String.init)
            guard let name = nameAndParams.first?.uppercased(), current?[name] == nil else { continue }
            var params: [String: String] = [:]
            for param in nameAndParams.dropFirst() {
                let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { params[pair[0].uppercased()] = pair[1].replacingOccurrences(of: "\"", with: "") }
            }
            current?[name] = (params, String(line[line.index(after: colon)...]))
        }
        return events
    }

    private static func makeEvent(_ props: [String: Property]) -> FeedEvent? {
        guard let summary = props["SUMMARY"].map({ unescape($0.value) }), !summary.isEmpty,
              let startProp = props["DTSTART"], let start = parseDate(startProp) else { return nil }
        if props["STATUS"]?.value.uppercased() == "CANCELLED" { return nil }
        let details = props["DESCRIPTION"].map { unescape($0.value) } ?? ""
        let url = props["URL"].flatMap { URL(string: $0.value.trimmingCharacters(in: .whitespaces)) }
        return FeedEvent(
            uid: props["UID"]?.value ?? "\(summary)-\(start.timeIntervalSince1970)",
            title: summary,
            start: start,
            end: props["DTEND"].flatMap(parseDate),
            location: props["LOCATION"].map { unescape($0.value) } ?? "",
            details: details,
            url: url,
            registrationURL: RegistrationLinkFinder.find(in: details)
        )
    }

    private static func parseDate(_ prop: Property) -> Date? {
        let value = prop.value.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if prop.params["VALUE"] == "DATE" || value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .campus
        } else if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = prop.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .campus
        }
        return formatter.date(from: value)
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - RSS / Atom

/// RSS items rarely have a structured event date, so the date is read from the
/// item's text; items without a recognizable date are skipped.
enum RSSEventParser {
    static func parse(_ data: Data, now: Date = .now) -> [FeedEvent] {
        FeedXMLReader().read(data).compactMap { item in
            let body = HTML.plainText(item.description)
            guard let dates = TextDateExtractor.extract(from: item.title + "\n" + body, now: now) else { return nil }
            let link = URL(string: item.link.trimmingCharacters(in: .whitespacesAndNewlines))
            return FeedEvent(
                uid: item.guid.isEmpty ? (item.link.isEmpty ? item.title : item.link) : item.guid,
                title: HTML.plainText(item.title),
                start: dates.start,
                end: dates.end,
                location: "",
                details: String(body.prefix(1000)),
                url: link,
                registrationURL: RegistrationLinkFinder.find(in: item.description)
            )
        }
    }
}

private final class FeedXMLReader: NSObject, XMLParserDelegate {
    struct Item { var title = "", link = "", description = "", guid = "" }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""

    func read(_ data: Data) -> [Item] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" { current = Item() }
        if name == "link", current != nil, current?.link.isEmpty == true, let href = attributeDict["href"] {
            current?.link = href // Atom puts the link in an attribute
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "title": if current?.title.isEmpty == true { current?.title = value }
        case "link": if current?.link.isEmpty == true, !value.isEmpty { current?.link = value }
        case "description", "summary", "content", "content:encoded":
            if !value.isEmpty, var item = current {
                item.description += (item.description.isEmpty ? "" : "\n") + value
                current = item
            }
        case "guid", "id": current?.guid = value
        case "item", "entry":
            if let item = current { items.append(item) }
            current = nil
        default: break
        }
        text = ""
    }
}

// MARK: - Events web pages (schema.org JSON-LD)

/// Many university event pages (and most event platforms) embed machine-readable
/// schema.org "Event" data in the page, which is far more reliable than scraping the layout.
enum JSONLDEventExtractor {
    private static let scriptPattern = try! NSRegularExpression(
        pattern: #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    static func extract(fromHTML html: String, baseURL: URL) -> [FeedEvent] {
        let ns = html as NSString
        var objects: [[String: Any]] = []
        for match in scriptPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            collectEvents(parsed, into: &objects)
        }
        var seen = Set<String>()
        return objects.compactMap { makeEvent($0, baseURL: baseURL) }.filter { seen.insert($0.uid).inserted }
    }

    private static func collectEvents(_ value: Any, into result: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if isEvent(dict["@type"]) { result.append(dict) }
            for child in dict.values where child is [String: Any] || child is [Any] {
                collectEvents(child, into: &result)
            }
        } else if let array = value as? [Any] {
            array.forEach { collectEvents($0, into: &result) }
        }
    }

    private static func isEvent(_ type: Any?) -> Bool {
        if let type = type as? String { return type.hasSuffix("Event") }
        if let types = type as? [String] { return types.contains { $0.hasSuffix("Event") } }
        return false
    }

    private static func makeEvent(_ dict: [String: Any], baseURL: URL) -> FeedEvent? {
        guard let name = dict["name"] as? String,
              let start = (dict["startDate"] as? String).flatMap(FeedDates.parse) else { return nil }
        if let status = dict["eventStatus"] as? String, status.contains("Cancelled") { return nil }

        let details = HTML.plainText(dict["description"] as? String ?? "")
        let url = (dict["url"] as? String).flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        var registration: URL?
        let offers = (dict["offers"] as? [String: Any]).map { [$0] } ?? (dict["offers"] as? [[String: Any]]) ?? []
        if let offerURL = offers.compactMap({ $0["url"] as? String }).first {
            registration = URL(string: offerURL, relativeTo: baseURL)?.absoluteURL
        }
        return FeedEvent(
            uid: url?.absoluteString ?? "\(name)-\(start.timeIntervalSince1970)",
            title: HTML.plainText(name),
            start: start,
            end: (dict["endDate"] as? String).flatMap(FeedDates.parse),
            location: locationText(dict["location"]),
            details: String(details.prefix(1000)),
            url: url,
            registrationURL: registration ?? RegistrationLinkFinder.find(in: dict["description"] as? String ?? "")
        )
    }

    private static func locationText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let array = value as? [Any] { return locationText(array.first) }
        guard let dict = value as? [String: Any] else { return "" }
        let name = dict["name"] as? String ?? ""
        var address = dict["address"] as? String ?? ""
        if let parts = dict["address"] as? [String: Any] {
            address = [parts["streetAddress"], parts["addressLocality"]].compactMap { $0 as? String }.joined(separator: ", ")
        }
        return [name, address].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum FeedDates {
    static func parse(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        // No time zone given: assume New York.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .campus
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

enum HTML {
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")

    static func plainText(_ html: String) -> String {
        let stripped = tags.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " "
        )
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&rsquo;", with: "’")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
