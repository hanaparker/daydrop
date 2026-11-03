import SwiftUI
import UIKit

/// Filled = going, dashed outline = maybe.
struct StatusMarker: View {
    let color: Color
    let status: RSVPStatus

    var body: some View {
        Group {
            if status == .going {
                RoundedRectangle(cornerRadius: 4).fill(color)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .frame(width: 8)
        .accessibilityLabel(status.label)
    }
}

struct EventRow: View {
    let title: String
    let start: Date
    let end: Date
    let location: String
    let color: Color
    let status: RSVPStatus
    var subtitle: String?
    var warning: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusMarker(color: color, status: status)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline).lineLimit(2)
                    if status == .maybe {
                        Text("Maybe")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(color))
                            .foregroundStyle(color)
                    }
                }
                Text("\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension EventRow {
    init(event: SavedEvent) {
        self.init(
            title: event.title, start: event.startDate, end: event.endDate,
            location: event.location,
            color: event.category.map { Color(hex: $0.colorHex) } ?? Theme.navy,
            status: event.status,
            subtitle: event.category?.name,
            warning: event.syncError.map { _ in "Not synced to Google Calendar" }
        )
    }
}

/// The swipe card: swipe right for Going, left for Maybe. Buttons do the same thing.
struct SwipeDecisionCard: View {
    let title: String
    let subtitle: String
    let onDecision: (RSVPStatus) -> Void

    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                HStack {
                    hint("Maybe", systemImage: "questionmark.circle", visible: offset < -20)
                    Spacer()
                    hint("Going", systemImage: "checkmark.circle.fill", visible: offset > 20)
                }
                .padding(.horizontal)

                card
                    .offset(x: offset)
                    .rotationEffect(.degrees(Double(offset / 25)))
                    .gesture(
                        DragGesture()
                            .onChanged { offset = $0.translation.width }
                            .onEnded { _ in finishDrag() }
                    )
            }

            HStack {
                Button { decide(.maybe) } label: {
                    Label("Maybe", systemImage: "questionmark.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { decide(.going) } label: {
                    Label("Going", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    private var card: some View {
        VStack(spacing: 6) {
            Text(title.isEmpty ? "Untitled event" : title).font(.headline).lineLimit(2)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Text("← Maybe · Going →").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(offset > 20 ? Theme.navy : offset < -20 ? Color.gray : Theme.columbiaBlue, lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe right if you're going, left for maybe.")
        .accessibilityAction(named: "Going") { decide(.going) }
        .accessibilityAction(named: "Maybe") { decide(.maybe) }
    }

    private func hint(_ text: String, systemImage: String, visible: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(text == "Going" ? Theme.navy : .gray)
            .opacity(visible ? 1 : 0)
    }

    private func finishDrag() {
        if offset > threshold { decide(.going) }
        else if offset < -threshold { decide(.maybe) }
        else { withAnimation(.spring()) { offset = 0 } }
    }

    private func decide(_ status: RSVPStatus) {
        withAnimation(.easeOut(duration: 0.25)) { offset = status == .going ? 600 : -600 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onDecision(status)
            offset = 0
        }
    }
}

/// Wraps the system camera.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
