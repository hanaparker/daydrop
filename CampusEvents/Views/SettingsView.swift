import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("saveFlyersToPhotos") private var saveFlyersToPhotos = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: auth.email ?? "—")
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }

                Section("Events") {
                    NavigationLink("Categories & colors") { CategoriesView() }
                    NavigationLink("Department subscriptions") { DepartmentsView() }
                }

                Section {
                    Toggle("Save scanned flyers to Photos", isOn: $saveFlyersToPhotos)
                } header: {
                    Text("Flyers")
                } footer: {
                    Text("Flyers are always kept in the app with their event. This is the default — you can still change it for each flyer.")
                }

                Section {
                    Button("Allow notifications") { Task { await NotificationService.requestPermission() } }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified when a department you follow posts an event you'd like, or when registration is needed.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut) {
                Button("Sign out", role: .destructive) {
                    auth.signOut()
                    hasCompletedOnboarding = false
                }
            } message: {
                Text("Your saved events stay on this phone and on your Google Calendar.")
            }
        }
    }
}
