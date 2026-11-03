import SwiftUI
import SwiftData

struct DepartmentsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DepartmentSubscription.name) private var subscriptions: [DepartmentSubscription]
    @State private var isAdding = false
    @State private var editing: DepartmentSubscription?

    var body: some View {
        List {
            Section {
                ForEach(subscriptions) { subscription in
                    Button { editing = subscription } label: { row(subscription) }
                        .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    offsets.map { subscriptions[$0] }.forEach(context.delete)
                    try? context.save()
                }
                Button { isAdding = true } label: { Label("Add Department", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Paste a department's calendar feed (iCal/webcal or RSS) or its events page. Look for a \"Subscribe\", \"iCal\" or \"RSS\" link on the department's events calendar.")
            }
        }
        .navigationTitle("Departments")
        .sheet(isPresented: $isAdding) { DepartmentEditor(subscription: nil) }
        .sheet(item: $editing) { DepartmentEditor(subscription: $0) }
    }

    private func row(_ subscription: DepartmentSubscription) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(subscription.name).font(.headline)
                Spacer()
                if !subscription.isEnabled { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            }
            if !subscription.keywords.isEmpty {
                Text("Interests: " + subscription.keywords.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = subscription.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let checked = subscription.lastCheckedAt {
                Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DepartmentEditor: View {
    let subscription: DepartmentSubscription?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \EventCategory.sortOrder) private var categories: [EventCategory]

    @State private var name = ""
    @State private var url = ""
    @State private var keywords = ""
    @State private var isEnabled = true
    @State private var autoAdd = false
    @State private var categoryUUID: UUID?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Computer Science)", text: $name)
                    TextField("Feed or events page URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await test() }
                    } label: {
                        if isTesting { ProgressView() } else { Text("Test link") }
                    }
                    .disabled(url.isEmpty || isTesting)
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    TextField("e.g. machine learning, careers, poetry", text: $keywords)
                } header: {
                    Text("Interests")
                } footer: {
                    Text("Only events mentioning one of these will invite you. Leave blank for everything.")
                }

                Section {
                    if !categories.isEmpty {
                        Picker("Category", selection: $categoryUUID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(categories) { category in
                                CategoryLabel(name: category.name, colorHex: category.colorHex).tag(category.uuid as UUID?)
                            }
                        }
                    }
                    Toggle("Add new events as Maybe automatically", isOn: $autoAdd)
                    Toggle("Active", isOn: $isEnabled)
                } footer: {
                    Text("With auto-add on, matching events go straight onto your calendar as maybes and you get a notification.")
                }
            }
            .navigationTitle(subscription == nil ? "Add Department" : "Edit Department")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.isEmpty)
                }
            }
            .onAppear {
                guard let subscription else { return }
                name = subscription.name
                url = subscription.feedURLString
                keywords = subscription.keywordsRaw
                isEnabled = subscription.isEnabled
                autoAdd = subscription.autoAddAsMaybe
                categoryUUID = subscription.defaultCategoryUUID
            }
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        let probe = DepartmentSubscription(name: name, feedURLString: url)
        probe.keywordsRaw = keywords
        guard let feedURL = probe.feedURL else { testResult = FeedError.badURL.localizedDescription; return }
        do {
            let events = try await FeedFetcher.fetchEvents(from: feedURL)
            let matching = EventFeedService.shared.relevant(events, for: probe)
            testResult = events.isEmpty
                ? "No events found at this link. Try the department's iCal or RSS link instead."
                : "Found \(events.count) events — \(matching.count) upcoming match your interests."
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func save() {
        let target = subscription ?? DepartmentSubscription(name: "", feedURLString: "")
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.feedURLString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        target.keywordsRaw = keywords
        target.isEnabled = isEnabled
        target.autoAddAsMaybe = autoAdd
        target.defaultCategoryUUID = categoryUUID
        if subscription == nil { context.insert(target) }
        try? context.save()
        Task {
            await NotificationService.requestPermission()
            await EventFeedService.shared.refreshAll(context: context)
        }
        dismiss()
    }
}
