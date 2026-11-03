import SwiftUI
import SwiftData

/// Lets the student make as many color-coded categories as they want.
struct CategoriesView: View {
    var isOnboarding = false

    @Environment(\.modelContext) private var context
    @Query(sort: \EventCategory.sortOrder) private var categories: [EventCategory]
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var editing: EventCategory?
    @State private var isAdding = false

    var body: some View {
        List {
            if isOnboarding {
                Section {
                    Text("Pick a color for each kind of event you go to — like red for sports and green for clubs. Add as many as you like; you can change them later in Settings.")
                        .font(.subheadline)
                }
            }

            Section {
                ForEach(categories) { category in
                    Button { editing = category } label: {
                        CategoryLabel(name: category.name, colorHex: category.colorHex)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: delete)
                .onMove(perform: move)

                Button { isAdding = true } label: {
                    Label("Add Category", systemImage: "plus.circle.fill")
                }
            }

            if categories.isEmpty {
                Section {
                    Button("Add suggested categories", action: addStarters)
                } footer: {
                    Text(Theme.starterCategories.map(\.name).joined(separator: ", "))
                }
            }
        }
        .navigationTitle(isOnboarding ? "Color-Code Events" : "Categories")
        .toolbar {
            if isOnboarding {
                ToolbarItem(placement: .confirmationAction) {
                    Button(categories.isEmpty ? "Skip" : "Done") {
                        hasCompletedOnboarding = true
                        Task { await NotificationService.requestPermission() }
                    }
                }
            } else if !categories.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(isPresented: $isAdding) {
            CategoryEditor(category: nil, nextSortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1)
        }
        .sheet(item: $editing) { category in
            CategoryEditor(category: category, nextSortOrder: category.sortOrder)
        }
    }

    private func addStarters() {
        for (index, starter) in Theme.starterCategories.enumerated() {
            context.insert(EventCategory(name: starter.name, colorHex: starter.hex, sortOrder: index))
        }
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { categories[$0] }.forEach(context.delete)
        try? context.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in reordered.enumerated() { category.sortOrder = index }
        try? context.save()
    }
}

struct CategoryEditor: View {
    let category: EventCategory?
    let nextSortOrder: Int

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = Theme.navy

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Sports)", text: $name)
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
                Section("Preview") {
                    CategoryLabel(name: name.isEmpty ? "Category" : name, colorHex: color.hexString)
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let category {
                    name = category.name
                    color = Color(hex: category.colorHex)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let category {
            let colorChanged = category.colorHex != color.hexString
            category.name = trimmed
            category.colorHex = color.hexString
            if colorChanged {
                // Recolor this category's events in Google Calendar too.
                let events = category.events
                Task { for event in events { await EventSaver.sync(event) } }
            }
        } else {
            context.insert(EventCategory(name: trimmed, colorHex: color.hexString, sortOrder: nextSortOrder))
        }
        try? context.save()
        dismiss()
    }
}

struct CategoryLabel: View {
    let name: String
    let colorHex: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: colorHex)).frame(width: 16, height: 16)
            Text(name)
        }
    }
}
