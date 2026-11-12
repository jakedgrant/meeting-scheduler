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
    public var conflictChecker: (@MainActor ([PollTimeOption], String?) async -> CalendarCheckResult)?
    public var deviceConflictLoader: (@MainActor (PollTimeOption, String?) async -> [CalendarConflict])?
    /// Replaces the default add, which records the event in `addedEvents` and reports success.
    public var eventAdder: (@MainActor (DeviceCalendarEvent) async -> DeviceCalendarAddResult)?
    public private(set) var addedEvents: [DeviceCalendarEvent] = []

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

    public func checkConflicts(for timeOptions: [PollTimeOption], pollTimeZone: String?) async -> CalendarCheckResult {
        if let conflictChecker { return await conflictChecker(timeOptions, pollTimeZone) }
        return .none
    }

    public func deviceConflicts(for option: PollTimeOption, pollTimeZone: String?) async -> [CalendarConflict] {
        if let deviceConflictLoader { return await deviceConflictLoader(option, pollTimeZone) }
        return []
    }

    public func addEventToCalendar(_ event: DeviceCalendarEvent) async -> DeviceCalendarAddResult {
        if let eventAdder { return await eventAdder(event) }
        addedEvents.append(event)
        return .added
    }
}
