import SwiftUI
import Shared

public struct ContentView: View {
    @Environment(\.authService) var authService

    public init() {}

    public var body: some View {
        Group {
            if authService.isLoading {
                loadingView
            } else if authService.isAuthenticated {
                MainTabView()
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
        .environment(\.authService, MockAuthService.signedIn)
}

#Preview("Signed Out") {
    ContentView()
        .environment(\.authService, MockAuthService.signedOut)
}

#Preview("Loading") {
    ContentView()
        .environment(\.authService, MockAuthService.loading)
}
