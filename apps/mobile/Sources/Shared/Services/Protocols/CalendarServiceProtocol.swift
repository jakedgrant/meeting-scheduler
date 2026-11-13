import Foundation

/// Protocol describing the public interface of CalendarService for dependency injection and testing.
@MainActor
public protocol CalendarServiceProtocol: AnyObject, Observable, Sendable {
    // MARK: - Properties

    var appleCalendarEnabled: Bool { get }
    var googleCalendarEnabled: Bool { get }
    var googleCalendarLoading: Bool { get }
    var googleCalendarError: String? { get }
    var googleCalendarAccountEmail: String? { get }
    var isEnabled: Bool { get }

    // MARK: - Settings

    func setAppleCalendarEnabled(_ enabled: Bool) async
    func setGoogleCalendarEnabled(_ enabled: Bool) async
    func refreshGoogleCalendarConnection() async

    // MARK: - Conflict Checking

    func checkConflicts(for timeOptions: [PollTimeOption], pollTimeZone: String?) async -> CalendarCheckResult
    func deviceConflicts(for option: PollTimeOption, pollTimeZone: String?) async -> [CalendarConflict]

    // MARK: - Add to Calendar

    func addEventToCalendar(_ event: DeviceCalendarEvent) async -> DeviceCalendarAddResult
}
