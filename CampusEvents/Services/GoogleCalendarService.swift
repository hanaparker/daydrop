import Foundation

struct CalendarEventDraft {
    var title: String
    var start: Date
    var end: Date
    var location: String
    var details: String
    var link: URL?
}

enum CalendarSyncError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, _): return "Google Calendar returned an error (\(code))."
        case .invalidResponse: return "Google Calendar sent an unexpected response."
        }
    }
}

/// Google Calendar only supports 11 event colors, so each custom category color
/// is matched to the closest one. Inside the app the exact color is used.
enum GoogleEventColor {
    static let palette: [(id: String, hex: String)] = [
        ("1", "#7986CB"), ("2", "#33B679"), ("3", "#8E24AA"), ("4", "#E67C73"),
        ("5", "#F6BF26"), ("6", "#F4511E"), ("7", "#039BE5"), ("8", "#616161"),
        ("9", "#3F51B5"), ("10", "#0B8043"), ("11", "#D50000")
    ]

    static func nearestId(to hex: String) -> String {
        let target = HexColor.components(hex)
        func distance(_ other: String) -> Double {
            let c = HexColor.components(other)
            // Weighted RGB distance; close enough to human perception for 11 choices.
            return 2 * pow(c.r - target.r, 2) + 4 * pow(c.g - target.g, 2) + 3 * pow(c.b - target.b, 2)
        }
        return palette.min { distance($0.hex) < distance($1.hex) }?.id ?? "9"
    }
}

/// Talks to the Google Calendar REST API on the student's primary calendar.
final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private let eventsURL = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .campus
        return formatter
    }()

    /// Returns the new Google event id.
    func createEvent(_ draft: CalendarEventDraft, status: RSVPStatus, colorHex: String?) async throws -> String {
        var request = URLRequest(url: eventsURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(draft, status: status, colorHex: colorHex))
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else { throw CalendarSyncError.invalidResponse }
        return id
    }

    func updateEvent(id: String, draft: CalendarEventDraft, status: RSVPStatus, colorHex: String?) async throws {
        var request = URLRequest(url: eventsURL.appendingPathComponent(id))
        request.httpMethod = "PATCH"
        var body = payload(draft, status: status, colorHex: colorHex)
        if colorHex == nil { body["colorId"] = NSNull() } // category removed → calendar default color
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request)
    }

    func deleteEvent(id: String) async throws {
        var request = URLRequest(url: eventsURL.appendingPathComponent(id))
        request.httpMethod = "DELETE"
        do {
            _ = try await send(request)
        } catch CalendarSyncError.http(let code, _) where code == 404 || code == 410 {
            // Already deleted in Google Calendar; nothing to do.
        }
    }

    private func payload(_ draft: CalendarEventDraft, status: RSVPStatus, colorHex: String?) -> [String: Any] {
        var description = draft.details
        if let link = draft.link {
            description += (description.isEmpty ? "" : "\n\n") + link.absoluteString
        }
        var body: [String: Any] = [
            "summary": draft.title,
            "location": draft.location,
            "description": description,
            "start": ["dateTime": iso.string(from: draft.start), "timeZone": TimeZone.campus.identifier],
            "end": ["dateTime": iso.string(from: draft.end), "timeZone": TimeZone.campus.identifier],
            // You can't RSVP "maybe" to an event you own, so a maybe is saved as
            // tentative and shown as free so it doesn't block the student's time.
            "status": status == .maybe ? "tentative" : "confirmed",
            "transparency": status == .maybe ? "transparent" : "opaque",
            "extendedProperties": ["private": ["campusEventsStatus": status.rawValue]]
        ]
        if let colorHex { body["colorId"] = GoogleEventColor.nearestId(to: colorHex) }
        return body
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        let token = try await AuthService.shared.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarSyncError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
