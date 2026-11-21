import SwiftUI
import Shared

/// The application's root. Requiring `services` makes it a compile error to launch
/// without them; everything below reads the same instances from the environment.
public struct AppRootView: View {
    private let services: AppServices
    /// A poll link waiting for the Meets tab. It is kept here, above sign-in, so a link opened
    /// while signed out opens once someone signs in.
    @State private var pendingPollLink: PollLink?

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        ContentView(pendingPollLink: $pendingPollLink)
            .appServices(services)
            .onOpenURL { url in
                if let link = PollLink(url: url) {
                    pendingPollLink = link
                } else {
                    // Auth callbacks; the service ignores any other URL.
                    Task { await services.handleDeepLink(url: url) }
                }
            }
    }
}
