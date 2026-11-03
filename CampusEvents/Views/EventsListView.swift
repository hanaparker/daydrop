import SwiftUI
import SwiftData

struct EventsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedEvent.startDate) private var events: [SavedEvent]
    @State private var showPast = false

    private var visible: [SavedEvent] {
        let today = Calendar.campus.startOfDay(for: .now)
        if showPast { return Array(events.filter { $0.endDate < today }.reversed()) }
        return events.filter { $0.endDate >= today }
    }

    private var days: [(day: Date, events: [SavedEvent])] {
        let calendar = Calendar.campus
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.startDate) }
        let ascending = grouped.keys.sorted()
        let ordered = showPast ? Array(ascending.reversed()) : ascending
        return ordered.map { day in (day, (grouped[day] ?? []).sorted { $0.startDate < $1.startDate }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty {
                    ContentUnavailableView(
                        showPast ? "No past events" : "No upcoming events",
                        systemImage: "calendar",
                        description: Text("Scan a flyer or check Discover to add events.")
                    )
                } else {
                    List {
                        ForEach(days, id: \.day) { group in
                            Section(group.day.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                                ForEach(group.events) { event in
                                    NavigationLink(value: event) { EventRow(event: event) }
                                        .swipeActions(edge: .leading) { statusAction(for: event) }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                Task { await EventSaver.delete(event, context: context) }
                                            } label: { Label("Remove", systemImage: "trash") }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(showPast ? "Past Events" : "My Events")
            .navigationDestination(for: SavedEvent.self) { EventDetailView(event: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showPast ? "Upcoming" : "Past") { showPast.toggle() }
                }
            }
        }
    }

    @ViewBuilder
    private func statusAction(for event: SavedEvent) -> some View {
        if event.status == .maybe {
            Button { Task { await EventSaver.setStatus(.going, for: event) } } label: {
                Label("Going", systemImage: "checkmark.circle.fill")
            }
            .tint(Theme.navy)
        } else {
            Button { Task { await EventSaver.setStatus(.maybe, for: event) } } label: {
                Label("Maybe", systemImage: "questionmark.circle")
            }
            .tint(.gray)
        }
    }
}

struct EventDetailView: View {
    @Bindable var event: SavedEvent
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \EventCategory.sortOrder) private var categories: [EventCategory]
    @State private var hasChanges = false
    @State private var isSyncing = false
    @State private var showFlyer = false

    var body: some View {
        Form {
            if let data = event.flyerImageData, let image = UIImage(data: data) {
                Section {
                    Button { showFlyer = true } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).frame(maxWidth: .infinity)
                    }
                }
            }

            Section {
                Picker("I'm…", selection: $event.statusRaw) {
                    ForEach(RSVPStatus.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Section("Event") {
                TextField("Event name", text: $event.title)
                DatePicker("Starts", selection: $event.startDate)
                DatePicker("Ends", selection: $event.endDate, in: event.startDate...)
                TextField("Location", text: $event.location)
                TextField("Details", text: $event.details, axis: .vertical).lineLimit(2...8)
                if let link = event.linkString.flatMap(URL.init(string:)) {
                    Link(destination: link) { Label("Open link", systemImage: "link") }
                }
            }

            Section("Category") {
                Picker("Category", selection: $event.category) {
                    Text("None").tag(nil as EventCategory?)
                    ForEach(categories) { category in
                        CategoryLabel(name: category.name, colorHex: category.colorHex).tag(category as EventCategory?)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section("Google Calendar") {
                if isSyncing {
                    ProgressView()
                } else if let error = event.syncError {
                    Label(error, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                    Button("Try again") { Task { await sync() } }
                } else if event.googleEventId != nil {
                    Label("On your Google Calendar", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Remove event", role: .destructive) {
                    let doomed = event
                    hasChanges = false
                    dismiss()
                    Task { await EventSaver.delete(doomed, context: context) }
                }
            }
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: event.statusRaw) { hasChanges = true }
        .onChange(of: event.title) { hasChanges = true }
        .onChange(of: event.startDate) { hasChanges = true }
        .onChange(of: event.endDate) { hasChanges = true }
        .onChange(of: event.location) { hasChanges = true }
        .onChange(of: event.details) { hasChanges = true }
        .onChange(of: event.category) { hasChanges = true }
        .onDisappear {
            // Push edits to Google Calendar when leaving the screen.
            if hasChanges, !event.isDeleted { Task { await sync() } }
        }
        .sheet(isPresented: $showFlyer) {
            if let data = event.flyerImageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().padding()
            }
        }
    }

    private func sync() async {
        isSyncing = true
        await EventSaver.sync(event)
        try? context.save()
        hasChanges = false
        isSyncing = false
    }
}
