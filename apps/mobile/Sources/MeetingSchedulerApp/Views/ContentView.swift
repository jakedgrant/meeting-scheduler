import SwiftUI
import Shared

struct ContentView: View {
    @Environment(\.authService) var authService
    @Binding var pendingPollLink: PollLink?

    var body: some View {
        Group {
            if authService.isLoading {
                loadingView
            } else if authService.isAuthenticated {
                signedInView
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

    /// Onboarding comes before the Meets tab. A poll link opened meanwhile waits for the tab.
    @ViewBuilder
    private var signedInView: some View {
        switch authService.onboardingStatus {
        case .undetermined: loadingView
        case .required: OnboardingView()
        case .notRequired: MainTabView(pendingPollLink: $pendingPollLink)
        }
    }
}

// MARK: - MainTabView

struct MainTabView: View {
    private enum MainTab { case meets, settings }

    @Binding var pendingPollLink: PollLink?
    @State private var selectedTab = MainTab.meets

    var body: some View {
        TabView(selection: $selectedTab) {
            PollListView(pendingPollLink: $pendingPollLink)
                .tabItem {
                    Label("Meets", systemImage: "list.bullet")
                }
                .tag(MainTab.meets)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(MainTab.settings)
        }
        // The Meets tab opens the poll; this only brings that tab forward.
        .onChange(of: pendingPollLink, initial: true) {
            if pendingPollLink != nil { selectedTab = .meets }
        }
    }
}

#Preview("Signed In") {
    ContentView(pendingPollLink: .constant(nil))
        .previewServices(auth: MockAuthService.signedIn)
}

#Preview("First Sign-In") {
    ContentView(pendingPollLink: .constant(nil))
        .previewServices(auth: MockAuthService.onboarding)
}

#Preview("Signed Out") {
    ContentView(pendingPollLink: .constant(nil))
        .previewServices(auth: MockAuthService.signedOut)
}

#Preview("Loading") {
    ContentView(pendingPollLink: .constant(nil))
        .previewServices(auth: MockAuthService.loading)
}
