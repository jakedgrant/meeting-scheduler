import SwiftUI

// MARK: - AuthService

private struct AuthServiceKey: EnvironmentKey {
    static var defaultValue: any AuthServiceProtocol {
        MainActor.assumeIsolated { AuthService.shared }
    }
}

// MARK: - PollService

private struct PollServiceKey: EnvironmentKey {
    static var defaultValue: any PollServiceProtocol {
        MainActor.assumeIsolated { PollService.shared }
    }
}

// MARK: - CalendarService

private struct CalendarServiceKey: EnvironmentKey {
    static var defaultValue: any CalendarServiceProtocol {
        MainActor.assumeIsolated { CalendarService.shared }
    }
}

// MARK: - PurchaseService

private struct PurchaseServiceKey: EnvironmentKey {
    static var defaultValue: any PurchaseServiceProtocol {
        MainActor.assumeIsolated { PurchaseService.shared }
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
