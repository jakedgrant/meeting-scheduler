import SwiftUI

/// Every service a view can read. The fields have no defaults, so adding one stops
/// `appServices(_:)` and `previewServices(auth:polls:calendar:purchases:)` compiling until
/// both supply it.
private struct ServiceSet {
    let auth: any AuthServiceProtocol
    let polls: any PollServiceProtocol
    let calendar: any CalendarServiceProtocol
    let purchases: any PurchaseServiceProtocol
}

private struct ServiceSetKey: EnvironmentKey {
    // Not a trap: applying `environment(_:_:)` also reads this default.
    static let defaultValue: ServiceSet? = nil
}

// The accessors are read-only and the key is private to this file, so the two modifiers below
// are the only ways to bind services, and they always bind all of them.
extension EnvironmentValues {
    fileprivate var boundServices: ServiceSet? {
        get { self[ServiceSetKey.self] }
        set { self[ServiceSetKey.self] = newValue }
    }

    private var serviceSet: ServiceSet {
        guard let boundServices else {
            fatalError("No services bound. Apply appServices(_:) at the root, or previewServices() in a preview.")
        }
        return boundServices
    }

    public var authService: any AuthServiceProtocol { serviceSet.auth }
    public var pollService: any PollServiceProtocol { serviceSet.polls }
    public var calendarService: any CalendarServiceProtocol { serviceSet.calendar }
    public var purchaseService: any PurchaseServiceProtocol { serviceSet.purchases }
}

extension View {
    /// Binds the production services in `services`.
    public func appServices(_ services: AppServices) -> some View {
        environment(
            \.boundServices,
            ServiceSet(
                auth: services.auth, polls: services.polls, calendar: services.calendar,
                purchases: services.purchases))
    }

    /// Binds mocks for a preview. Pass only the services the preview cares about.
    public func previewServices(
        auth: any AuthServiceProtocol = MockAuthService.signedOut,
        polls: any PollServiceProtocol = MockPollService.empty,
        calendar: any CalendarServiceProtocol = MockCalendarService.disabled,
        purchases: any PurchaseServiceProtocol = MockPurchaseService.free
    ) -> some View {
        environment(\.boundServices, ServiceSet(auth: auth, polls: polls, calendar: calendar, purchases: purchases))
    }
}
