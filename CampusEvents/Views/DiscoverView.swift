import SwiftUI
import SwiftData

/// Events found in subscribed departments' feeds — "invitations" the student can swipe on.
struct DiscoverView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var feed = EventFeedService.shared
    @Query(filter: #Predicate<SuggestedEvent> { $0.stateRaw == "new" }, sort: \SuggestedEvent.startDate)
    private var suggestions: [SuggestedEvent]
    @Query private var subscriptions: [DepartmentSubscription]
    @Query(sort: \EventCategory.sortOrder) private var categories: [EventCategory]

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label("Follow departments", systemImage: "building.columns")
                    } description: {
                        Text("Subscribe to departments and we'll invite you to their talks and events automatically.")
                    } actions: {
                        NavigationLink("Add a department") { DepartmentsView() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if suggestions.isEmpty {
                    ContentUnavailableView {
                        Label("You're all caught up", systemImage: "checkmark.seal")
                    } description: {
                        Text("Pull down to check for new events.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(suggestions) { suggestion in
                                SuggestionRow(suggestion: suggestion, color: color(for: suggestion))
                                    .swipeActions(edge: .leading) {
                                        Button { respond(suggestion, .going) } label: {
                                            Label("Going", systemImage: "checkmark.circle.fill")
                                        }
                                        .tint(Theme.navy)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button { dismissSuggestion(suggestion) } label: {
                                            Label("Not interested", systemImage: "xmark")
                                        }
                                        .tint(.red)
                                        Button { respond(suggestion, .maybe) } label: {
                                            Label("Maybe", systemImage: "questionmark.circle")
                                        }
                                        .tint(.gray)
                                    }
                            }
                        } footer: {
                            Text("Swipe right for Going, left for Maybe or Not interested.")
                        }
                    }
                    .refreshable { await feed.refreshAll(context: context) }
                }
            }
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { DepartmentsView() } label: { Label("Departments", systemImage: "building.columns") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if feed.isRefreshing {
                        ProgressView()
                    } else {
                        Button { Task { await feed.refreshAll(context: context) } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(subscriptions.isEmpty)
                    }
                }
            }
            .task {
                // Check feeds when the tab opens if they haven't been checked in the last hour.
                let stale = subscriptions.contains { ($0.lastCheckedAt ?? .distantPast) < .now.addingTimeInterval(-3600) }
                if stale { await feed.refreshAll(context: context) }
            }
        }
    }

    private func category(for suggestion: SuggestedEvent) -> EventCategory? {
        categories.first { $0.uuid == suggestion.categoryUUID }
    }

    private func color(for suggestion: SuggestedEvent) -> Color {
        category(for: suggestion).map { Color(hex: $0.colorHex) } ?? Theme.navy
    }

    private func respond(_ suggestion: SuggestedEvent, _ status: RSVPStatus) {
        suggestion.state = status == .going ? .going : .maybe
        let category = category(for: suggestion)
        let draft = suggestion.draft
        Task { await EventSaver.save(draft: draft, status: status, category: category, context: context) }
    }

    private func dismissSuggestion(_ suggestion: SuggestedEvent) {
        suggestion.state = .dismissed
        try? context.save()
    }
}

private struct SuggestionRow: View {
    let suggestion: SuggestedEvent
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.departmentName.uppercased())
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(suggestion.title).font(.headline)
            Text(suggestion.startDate.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                .font(.subheadline).foregroundStyle(.secondary)
            if !suggestion.location.isEmpty {
                Label(suggestion.location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                if let registration = suggestion.registrationURL {
                    Link(destination: registration) {
                        Label("Register", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let url = suggestion.eventURL {
                    Link(destination: url) { Label("Details", systemImage: "safari") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
