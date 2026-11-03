import SwiftUI
import SwiftData
import PhotosUI

struct FlyerReview: Identifiable {
    let id = UUID()
    let image: UIImage
    let scanned: ScannedFlyer
    /// Library photos are already in Photos, so only camera shots get the "save to Photos" option.
    let fromCamera: Bool
}

struct ScanView: View {
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var review: FlyerReview?
    @State private var errorMessage: String?
    @State private var confirmation: String?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 80))
                    .foregroundStyle(Theme.navy)
                Text("Scan a flyer")
                    .font(.title2.bold())
                Text("Take a photo of any event flyer. We'll pull out the event, date and place so you can add it in one swipe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.navy)
                        .transition(.opacity)
                }
                Spacer()

                if isScanning {
                    ProgressView("Reading flyer…")
                } else {
                    VStack(spacing: 12) {
                        Button { showCamera = true } label: {
                            Label("Take Photo", systemImage: "camera.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!cameraAvailable)

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Choose from Library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.horizontal)
                }
            }
            .padding(.bottom)
            .navigationTitle("Scan")
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in process(image, fromCamera: true) }
                    .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        process(image, fromCamera: false)
                    } else {
                        errorMessage = "That photo couldn't be opened."
                    }
                    photoItem = nil
                }
            }
            .sheet(item: $review) { review in
                EventReviewView(review: review) { message in
                    withAnimation { confirmation = message }
                }
            }
            .alert("Scan failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func process(_ image: UIImage, fromCamera: Bool) {
        confirmation = nil
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                let scanned = try await FlyerScanner.scan(image)
                review = FlyerReview(image: image, scanned: scanned, fromCamera: fromCamera)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Shows what was read off the flyer; the student fixes anything, picks a category, and swipes.
struct EventReviewView: View {
    let review: FlyerReview
    let onFinish: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \EventCategory.sortOrder) private var categories: [EventCategory]

    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var details: String
    @State private var category: EventCategory?
    @State private var saveToPhotos: Bool
    @State private var isSaving = false

    init(review: FlyerReview, onFinish: @escaping (String) -> Void) {
        self.review = review
        self.onFinish = onFinish
        let scanned = review.scanned
        _title = State(initialValue: scanned.title)
        _start = State(initialValue: scanned.start)
        _end = State(initialValue: scanned.end)
        _location = State(initialValue: scanned.location)
        _details = State(initialValue: scanned.details)
        _saveToPhotos = State(initialValue: UserDefaults.standard.object(forKey: "saveFlyersToPhotos") as? Bool ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image(uiImage: review.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity)
                    if !review.scanned.foundDate {
                        Label("We couldn't find a date on this flyer — please set it below.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section("Event") {
                    TextField("Event name", text: $title)
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end, in: start...)
                    TextField("Location", text: $location)
                    TextField("Details", text: $details, axis: .vertical).lineLimit(2...6)
                    if let url = review.scanned.registrationURL {
                        Link(destination: url) {
                            Label("Registration link found — open", systemImage: "link")
                        }
                    }
                }

                if !categories.isEmpty {
                    Section("Category") {
                        Picker("Category", selection: $category) {
                            Text("None").tag(nil as EventCategory?)
                            ForEach(categories) { category in
                                CategoryLabel(name: category.name, colorHex: category.colorHex)
                                    .tag(category as EventCategory?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                Section {
                    if review.fromCamera {
                        Toggle("Also save flyer to Photos", isOn: $saveToPhotos)
                    }
                } footer: {
                    Text("The flyer is always kept with the event in this app.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if isSaving {
                        ProgressView("Adding to your calendar…").padding()
                    } else {
                        SwipeDecisionCard(
                            title: title,
                            subtitle: start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())
                        ) { status in
                            Task { await commit(status) }
                        }
                        .padding()
                    }
                }
                .background(.bar)
            }
            .navigationTitle("Add Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } }
            }
            .onChange(of: start) { oldStart, newStart in
                // Keep the same length when the start moves.
                end = newStart.addingTimeInterval(max(end.timeIntervalSince(oldStart), 0))
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func commit(_ status: RSVPStatus) async {
        isSaving = true
        let draft = CalendarEventDraft(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Campus event" : title,
            start: start,
            end: max(end, start.addingTimeInterval(15 * 60)),
            location: location,
            details: details,
            link: review.scanned.registrationURL
        )
        let saved = await EventSaver.save(
            draft: draft, status: status, category: category,
            flyerImageData: review.image.jpegForStorage(), context: context
        )

        var message = status == .going ? "Added to your calendar" : "Added as maybe"
        if saved.syncError != nil { message = "Saved in the app — will sync to Google Calendar when you retry" }
        if review.fromCamera, saveToPhotos {
            do { try await PhotoLibrarySaver.save(review.image) }
            catch { message += " (flyer not saved to Photos)" }
        }
        isSaving = false
        onFinish(message)
        dismiss()
    }
}
