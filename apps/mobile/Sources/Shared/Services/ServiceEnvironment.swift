import SwiftUI

// Previews and any view without `appServices(_:)` get these mocks for unset keys, so
// reading the environment never builds production services. In every build configuration,
// including Release, a missed binding silently shows a mock. Each default is stored to keep
// one observed instance.

// MARK: - AuthService

private struct AuthServiceKey: EnvironmentKey {
    @MainActor private static let fallback = MockAuthService.signedOut

    static var defaultValue: any AuthServiceProtocol {
        MainActor.assumeIsolated { fallback }
    }
}

// MARK: - PollService

private struct PollServiceKey: EnvironmentKey {
    @MainActor private static let fallback = MockPollService.empty

    static var defaultValue: any PollServiceProtocol {
        MainActor.assumeIsolated { fallback }
    }
}

// MARK: - CalendarService

private struct CalendarServiceKey: EnvironmentKey {
    @MainActor private static let fallback = MockCalendarService.disabled

    static var defaultValue: any CalendarServiceProtocol {
        MainActor.assumeIsolated { fallback }
    }
}

// MARK: - PurchaseService

private struct PurchaseServiceKey: EnvironmentKey {
    @MainActor private static let fallback = MockPurchaseService.free

    static var defaultValue: any PurchaseServiceProtocol {
        MainActor.assumeIsolated { fallback }
    }
}

// MARK: - EnvironmentValues

extension EnvironmentValues {
    public var authService: any AuthServiceProtocol {
        get { self[AuthServiceKey.self] }
        set { self[AuthServiceKey.self] = newValue }
    }

    public var pollService: any PollServiceProtocol {
        get { self[PollServiceKey.self] }
        set { self[PollServiceKey.self] = newValue }
    }

    public var calendarService: any CalendarServiceProtocol {
        get { self[CalendarServiceKey.self] }
        set { self[CalendarServiceKey.self] = newValue }
    }

    public var purchaseService: any PurchaseServiceProtocol {
        get { self[PurchaseServiceKey.self] }
        set { self[PurchaseServiceKey.self] = newValue }
    }
}

// MARK: - AppServices

extension View {
    /// Binds every service in `services`, replacing the mock defaults.
    public func appServices(_ services: AppServices) -> some View {
        environment(\.authService, services.auth)
            .environment(\.pollService, services.polls)
            .environment(\.calendarService, services.calendar)
            .environment(\.purchaseService, services.purchases)
    }
}
