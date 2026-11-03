import SwiftUI
import Shared

struct ContentView: View {
    @Environment(\.authService) var authService

    var body: some View {
        Group {
            if authService.isLoading {
                loadingView
            } else if authService.isAuthenticated {
                MainTabView()
                    .id(authService.sessionGeneration)
            } else {
                AuthView()
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        ProgressView("Loading...")
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    var body: some View {
        TabView {
            PollListView()
                .tabItem {
                    Label("Meets", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#Preview("Signed In") {
    ContentView()
        .previewServices(auth: MockAuthService.signedIn)
}

#Preview("Signed Out") {
    ContentView()
        .previewServices(auth: MockAuthService.signedOut)
}

#Preview("Loading") {
    ContentView()
        .previewServices(auth: MockAuthService.loading)
}
