import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if auth.isRestoring {
                ProgressView()
            } else if !auth.isSignedIn {
                SignInView()
            } else if !hasCompletedOnboarding {
                NavigationStack { CategoriesView(isOnboarding: true) }
            } else {
                MainTabView()
            }
        }
        .animation(.default, value: auth.isSignedIn)
        .animation(.default, value: hasCompletedOnboarding)
    }
}

struct MainTabView: View {
    @Query(filter: #Predicate<SuggestedEvent> { $0.stateRaw == "new" })
    private var newSuggestions: [SuggestedEvent]

    var body: some View {
        TabView {
            EventsListView()
                .tabItem { Label("My Events", systemImage: "calendar") }
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
                .badge(newSuggestions.count)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
