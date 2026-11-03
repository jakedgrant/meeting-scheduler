import SwiftUI
import Shared

/// The application's root. Requiring `services` makes it a compile error to launch
/// without them; everything below reads the same instances from the environment.
public struct AppRootView: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        ContentView()
            .appServices(services)
            .onOpenURL { url in
                // Handle OAuth callback deep links
                Task {
                    await services.handleDeepLink(url: url)
                }
            }
    }
}
