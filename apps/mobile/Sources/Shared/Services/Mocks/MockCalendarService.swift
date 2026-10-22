import Foundation

/// Mock implementation of CalendarServiceProtocol for SwiftUI previews and testing.
@MainActor
@Observable
public final class MockCalendarService: CalendarServiceProtocol {
    public var appleCalendarEnabled: Bool
    public var googleCalendarEnabled: Bool
    public var googleCalendarLoading: Bool
    public var googleCalendarError: String?
    public var googleCalendarAccountEmail: String?

    public var isEnabled: Bool {
        appleCalendarEnabled || googleCalendarEnabled
    }

    public init(
        appleCalendarEnabled: Bool = false,
        googleCalendarEnabled: Bool = false,
        googleCalendarLoading: Bool = false
    ) {
        self.appleCalendarEnabled = appleCalendarEnabled
        self.googleCalendarEnabled = googleCalendarEnabled
        self.googleCalendarLoading = googleCalendarLoading
    }

    // MARK: - Static Factories

    public static var disabled: MockCalendarService {
        MockCalendarService()
    }

    public static var appleEnabled: MockCalendarService {
        MockCalendarService(appleCalendarEnabled: true)
    }

    public static var allEnabled: MockCalendarService {
        MockCalendarService(appleCalendarEnabled: true, googleCalendarEnabled: true)
    }

    // MARK: - No-op Methods

    public func setAppleCalendarEnabled(_ enabled: Bool) async {
        appleCalendarEnabled = enabled
    }

    public func setGoogleCalendarEnabled(_ enabled: Bool) async {
        googleCalendarEnabled = enabled
    }

    public func refreshGoogleCalendarConnection() async {}

    public func checkConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        Set()
    }

    public func addEventToCalendar(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String?,
        location: String?
    ) async -> Bool {
        true
    }
}
