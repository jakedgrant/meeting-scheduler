import SwiftUI
import Shared

public struct ContentView: View {
    @State var authService = AuthService.shared

    public init() {}

    public var body: some View {
        Group {
            if authService.isLoading {
                ProgressView("Loading...")
            } else if authService.isAuthenticated {
                MainTabView()
            } else {
                AuthView()
            }
        }
    }
}

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

#Preview {
    ContentView()
}
