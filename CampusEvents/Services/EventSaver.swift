import Foundation
import SwiftData

/// Keeps the app's saved events and Google Calendar in step.
/// Events are always saved locally first, so nothing is lost if the network is down;
/// a failed sync is recorded and can be retried from the event screen.
@MainActor
enum EventSaver {
    @discardableResult
    static func save(
        draft: CalendarEventDraft,
        status: RSVPStatus,
        category: EventCategory?,
        flyerImageData: Data? = nil,
        context: ModelContext
    ) async -> SavedEvent {
        let event = SavedEvent(draft: draft, status: status, category: category, flyerImageData: flyerImageData)
        context.insert(event)
        try? context.save()
        await sync(event)
        try? context.save()
        return event
    }

    static func sync(_ event: SavedEvent) async {
        do {
            if let id = event.googleEventId {
                try await GoogleCalendarService.shared.updateEvent(
                    id: id, draft: event.draft, status: event.status, colorHex: event.category?.colorHex
                )
            } else {
                event.googleEventId = try await GoogleCalendarService.shared.createEvent(
                    event.draft, status: event.status, colorHex: event.category?.colorHex
                )
            }
            event.syncError = nil
        } catch {
            event.syncError = error.localizedDescription
        }
    }

    static func setStatus(_ status: RSVPStatus, for event: SavedEvent) async {
        event.status = status
        await sync(event)
    }

    static func delete(_ event: SavedEvent, context: ModelContext) async {
        if let id = event.googleEventId {
            try? await GoogleCalendarService.shared.deleteEvent(id: id)
        }
        context.delete(event)
        try? context.save()
    }
}
