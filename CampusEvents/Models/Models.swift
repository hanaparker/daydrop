import Foundation
import SwiftData

enum RSVPStatus: String, Codable, CaseIterable, Identifiable {
    case going
    case maybe

    var id: String { rawValue }
    var label: String { self == .going ? "Going" : "Maybe" }
}

/// A color-coded category the student defines (e.g. red = Sports).
@Model
final class EventCategory {
    var uuid: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#1D4F91"
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \SavedEvent.category)
    var events: [SavedEvent] = []

    init(name: String, colorHex: String, sortOrder: Int) {
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

/// An event the student said they're going (or maybe going) to.
@Model
final class SavedEvent {
    var title: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var location: String = ""
    var details: String = ""
    var statusRaw: String = RSVPStatus.going.rawValue
    var category: EventCategory?
    var linkString: String?
    var googleEventId: String?
    var syncError: String?
    var createdAt: Date = Date()

    /// The flyer photo, always kept inside the app (separately from the Photos library).
    @Attribute(.externalStorage) var flyerImageData: Data?

    var status: RSVPStatus {
        get { RSVPStatus(rawValue: statusRaw) ?? .going }
        set { statusRaw = newValue.rawValue }
    }

    var draft: CalendarEventDraft {
        CalendarEventDraft(
            title: title, start: startDate, end: endDate,
            location: location, details: details,
            link: linkString.flatMap(URL.init(string:))
        )
    }

    init(draft: CalendarEventDraft, status: RSVPStatus, category: EventCategory?, flyerImageData: Data?) {
        self.title = draft.title
        self.startDate = draft.start
        self.endDate = draft.end
        self.location = draft.location
        self.details = draft.details
        self.linkString = draft.link?.absoluteString
        self.statusRaw = status.rawValue
        self.category = category
        self.flyerImageData = flyerImageData
    }
}

/// A department (or any group) whose events feed the student follows.
@Model
final class DepartmentSubscription {
    var name: String = ""
    /// An iCal (.ics / webcal), RSS/Atom, or events web page URL.
    var feedURLString: String = ""
    /// Comma-separated interests; empty means "everything from this department".
    var keywordsRaw: String = ""
    var isEnabled: Bool = true
    /// Put new matching events straight on the calendar as "maybe".
    var autoAddAsMaybe: Bool = false
    var defaultCategoryUUID: UUID?
    var lastCheckedAt: Date?
    var lastError: String?

    var keywords: [String] {
        keywordsRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    var feedURL: URL? {
        var string = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.lowercased().hasPrefix("webcal://") {
            string = "https://" + string.dropFirst("webcal://".count)
        }
        return URL(string: string)
    }

    init(name: String, feedURLString: String) {
        self.name = name
        self.feedURLString = feedURLString
    }
}

/// An event found in a subscribed department's feed, waiting for the student to respond.
@Model
final class SuggestedEvent {
    enum State: String { case new, going, maybe, dismissed }

    @Attribute(.unique) var externalId: String = ""
    var title: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var location: String = ""
    var details: String = ""
    var eventURLString: String?
    var registrationURLString: String?
    var departmentName: String = ""
    var categoryUUID: UUID?
    var stateRaw: String = State.new.rawValue
    var discoveredAt: Date = Date()

    var state: State {
        get { State(rawValue: stateRaw) ?? .new }
        set { stateRaw = newValue.rawValue }
    }

    var registrationURL: URL? { registrationURLString.flatMap(URL.init(string:)) }
    var eventURL: URL? { eventURLString.flatMap(URL.init(string:)) }

    var draft: CalendarEventDraft {
        var notes = details
        if let registrationURL { notes = "Register: \(registrationURL.absoluteString)\n\n" + notes }
        return CalendarEventDraft(
            title: title, start: startDate, end: endDate,
            location: location, details: notes, link: eventURL
        )
    }

    init(externalId: String, feedEvent: FeedEvent, departmentName: String, categoryUUID: UUID?) {
        self.externalId = externalId
        self.title = feedEvent.title
        self.startDate = feedEvent.start
        self.endDate = feedEvent.end ?? feedEvent.start.addingTimeInterval(3600)
        self.location = feedEvent.location
        self.details = feedEvent.details
        self.eventURLString = feedEvent.url?.absoluteString
        self.registrationURLString = feedEvent.registrationURL?.absoluteString
        self.departmentName = departmentName
        self.categoryUUID = categoryUUID
    }
}
