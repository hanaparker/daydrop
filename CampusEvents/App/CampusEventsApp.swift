import SwiftUI
import SwiftData
import GoogleSignIn
import UserNotifications

@main
struct CampusEventsApp: App {
    @StateObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: EventCategory.self, SavedEvent.self, DepartmentSubscription.self, SuggestedEvent.self
            )
        } catch {
            fatalError("Could not create the local data store: \(error)")
        }
        // Show notification banners even while the app is open.
        UNUserNotificationCenter.current().delegate = NotificationService.delegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .tint(Theme.navy)
                .onOpenURL { url in
                    // Completes the Google sign-in redirect.
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                EventFeedService.shared.scheduleBackgroundRefresh()
            }
        }
        // Periodically checks subscribed department feeds while the app is closed.
        .backgroundTask(.appRefresh(EventFeedService.refreshTaskID)) {
            await EventFeedService.shared.handleBackgroundRefresh(container: container)
        }
    }
}
