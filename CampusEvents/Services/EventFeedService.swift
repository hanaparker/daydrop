import BackgroundTasks
import Combine
import Foundation
import SwiftData

/// Checks every subscribed department for new events that match the student's interests,
/// turns them into invitations in Discover, and notifies the student.
@MainActor
final class EventFeedService: ObservableObject {
    static let shared = EventFeedService()
    /// Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "com.yourteam.CampusEvents.feedRefresh"

    /// How far ahead to look for events.
    private let lookahead: TimeInterval = 60 * 86_400

    @Published private(set) var isRefreshing = false

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // iOS decides when it actually runs (based on how often the app is used);
        // this is the earliest it's allowed to.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh(container: ModelContainer) async {
        scheduleBackgroundRefresh()
        await refreshAll(context: container.mainContext)
    }

    /// Returns how many new events were found.
    @discardableResult
    func refreshAll(context: ModelContext) async -> Int {
        guard !isRefreshing else { return 0 }
        isRefreshing = true
        defer { isRefreshing = false }

        let subscriptions = (try? context.fetch(
            FetchDescriptor<DepartmentSubscription>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        let categories = (try? context.fetch(FetchDescriptor<EventCategory>())) ?? []

        var newSuggestions: [SuggestedEvent] = []
        var autoAdded: [SuggestedEvent] = []

        for subscription in subscriptions {
            guard let url = subscription.feedURL else {
                subscription.lastError = FeedError.badURL.localizedDescription
                continue
            }
            do {
                let events = try await FeedFetcher.fetchEvents(from: url)
                subscription.lastError = nil
                subscription.lastCheckedAt = .now

                for event in relevant(events, for: subscription) {
                    let externalId = "\(subscription.feedURLString)#\(event.uid)"
                    let existing = try? context.fetch(
                        FetchDescriptor<SuggestedEvent>(predicate: #Predicate { $0.externalId == externalId })
                    )
                    guard existing?.isEmpty ?? true else { continue }

                    let suggestion = SuggestedEvent(
                        externalId: externalId,
                        feedEvent: event,
                        departmentName: subscription.name,
                        categoryUUID: subscription.defaultCategoryUUID
                    )
                    context.insert(suggestion)

                    if subscription.autoAddAsMaybe {
                        suggestion.state = .maybe
                        let category = categories.first { $0.uuid == subscription.defaultCategoryUUID }
                        await EventSaver.save(draft: suggestion.draft, status: .maybe, category: category, context: context)
                        autoAdded.append(suggestion)
                    } else {
                        newSuggestions.append(suggestion)
                    }
                }
            } catch {
                subscription.lastError = error.localizedDescription
            }
        }

        try? context.save()
        await NotificationService.announce(newSuggestions: newSuggestions, autoAdded: autoAdded)
        return newSuggestions.count + autoAdded.count
    }

    /// Upcoming events in the next two months that match the subscription's keywords.
    func relevant(_ events: [FeedEvent], for subscription: DepartmentSubscription) -> [FeedEvent] {
        let now = Date()
        let keywords = subscription.keywords
        return events.filter { event in
            guard event.start >= now, event.start <= now.addingTimeInterval(lookahead) else { return false }
            guard !keywords.isEmpty else { return true }
            let haystack = (event.title + " " + event.details).lowercased()
            return keywords.contains { haystack.contains($0) }
        }
    }
}
