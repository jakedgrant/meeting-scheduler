import SwiftUI
import Shared

public struct ContentView: View {
    @State var authService: any AuthServiceProtocol

    public init(authService: any AuthServiceProtocol = AuthService.shared) {
        self.authService = authService
    }

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
                    Label("Polls", systemImage: "list.bullet")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#Preview("Signed In") {
    ContentView(authService: MockAuthService.signedIn)
}

#Preview("Signed Out") {
    ContentView(authService: MockAuthService.signedOut)
}

#Preview("Loading") {
    ContentView(authService: MockAuthService.loading)
}
