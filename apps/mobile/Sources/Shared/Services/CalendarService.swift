import EventKit
import Foundation
import Supabase

/// Calendar source options
public enum CalendarSource: String, Codable, Sendable {
    case appleCalendar = "apple"
    case googleCalendar = "google"
}

/// Service for managing calendar integration and conflict detection
/// Supports both Apple Calendar (EventKit) and Google Calendar APIs
@MainActor
@Observable
public final class CalendarService: CalendarServiceProtocol {
    private let eventStore = EKEventStore()

    // Apple Calendar properties
    public private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    public private(set) var appleCalendarEnabled = false

    // Google Calendar properties
    public private(set) var googleCalendarEnabled = false
    public private(set) var googleCalendarLoading = false
    public private(set) var googleCalendarError: String?
    public private(set) var googleCalendarAccountEmail: String?
    private let oauthSession = OAuthBrowserSession()
    private var connectionGeneration = 0
    private var accountId: UUID?
    private var accountGeneration: UInt64 = 0
    private let preferences: UserDefaults
    private let client: SupabaseClient
    private let requestCredentials: @MainActor () -> AccountRequestCredentials?
    private let accessRequest: (@MainActor () async -> Bool)?

    // Overall enabled state (true if any source is enabled)
    public var isEnabled: Bool {
        appleCalendarEnabled || googleCalendarEnabled
    }

    init(
        preferences: UserDefaults, client: SupabaseClient,
        accessRequest: (@MainActor () async -> Bool)? = nil,
        requestCredentials: @escaping @MainActor () -> AccountRequestCredentials? = { nil }
    ) {
        self.requestCredentials = requestCredentials
        self.preferences = preferences
        self.client = client
        self.accessRequest = accessRequest
        updateAuthorizationStatus()
        // Never import unowned legacy device preferences into an account.
    }

    public func accountDidChange(to id: UUID?) {
        accountId = id
        accountGeneration &+= 1
        resetGoogleCalendarState()
        appleCalendarEnabled = id.map { preferences.bool(forKey: applePreferenceKey($0)) } ?? false
    }

    private func applePreferenceKey(_ id: UUID) -> String {
        "calendar.\(id.uuidString).appleEnabled"
    }

    // MARK: - Authorization Status

    private func updateAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Permission Management

    /// Request calendar access from the user
    /// - Returns: true if access was granted
    public func requestAccess() async -> Bool {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            if let accessRequest { return await accessRequest() }
            do {
                #if os(iOS)
                    if #available(iOS 17.0, *) {
                        // iOS 17+ uses requestFullAccessToEvents
                        let granted = try await eventStore.requestFullAccessToEvents()
                        updateAuthorizationStatus()
                        return granted
                    } else {
                        // Older iOS versions use requestAccess
                        let granted = try await eventStore.requestAccess(to: .event)
                        updateAuthorizationStatus()
                        return granted
                    }
                #else
                    let granted = try await eventStore.requestAccess(to: .event)
                    updateAuthorizationStatus()
                    return granted
                #endif
            } catch {
                FailureLog.calendar.record("Calendar access request failed", error: error)
                return false
            }
        }
    }

    // MARK: - Settings Persistence

    /// Device permission is global; the user's choice to use it belongs to an account.
    public func setAppleCalendarEnabled(_ enabled: Bool) async {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            guard let account = accountId, credentials == nil || credentials?.accountId == account else { return }
            let generation = accountGeneration
            if enabled {
                updateAuthorizationStatus()
                if authorizationStatus != .fullAccess {
                    let granted = await requestAccess()
                    guard generation == accountGeneration, accountId == account, !Task.isCancelled else { return }
                    if !granted {
                        appleCalendarEnabled = false
                        return
                    }
                }
            }
            guard generation == accountGeneration, accountId == account, !Task.isCancelled else { return }
            appleCalendarEnabled = enabled
            preferences.set(enabled, forKey: applePreferenceKey(account))
        }
    }

    public func resetGoogleCalendarState() {
        connectionGeneration += 1
        oauthSession.cancel()
        googleCalendarEnabled = false
        googleCalendarLoading = false
        googleCalendarError = nil
        googleCalendarAccountEmail = nil
    }

    public func refreshGoogleCalendarConnection() async {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            guard !googleCalendarLoading else { return }
            guard let userId = accountId else {
                resetGoogleCalendarState()
                return
            }
            guard credentials == nil || credentials?.accountId == userId else { return }
            connectionGeneration += 1
            let generation = connectionGeneration
            do {
                let status: CalendarConnectionStatus = try await client.functions.invoke(
                    "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                googleCalendarEnabled = status.connected
                googleCalendarAccountEmail = status.accountEmail
                googleCalendarError = status.requiresReconnect ? "Reconnect Google Calendar in Settings." : nil
                if status.revocationPending {
                    googleCalendarError = "Disconnected. Google access revocation is being retried."
                }
            } catch {
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                googleCalendarEnabled = false
                googleCalendarAccountEmail = nil
                googleCalendarError = "Google Calendar connection could not be checked."
            }
        }
    }

    public func setGoogleCalendarEnabled(_ enabled: Bool) async {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            guard let userId = accountId, credentials == nil || credentials?.accountId == userId else { return }
            oauthSession.cancel()
            connectionGeneration += 1
            let generation = connectionGeneration
            googleCalendarLoading = true
            googleCalendarError = nil
            defer { if generation == connectionGeneration { googleCalendarLoading = false } }
            do {
                if !enabled {
                    let status: CalendarConnectionStatus = try await client.functions.invoke(
                        "calendar-connection", options: FunctionInvokeOptions(body: ["action": "disconnect"]))
                    guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                    googleCalendarEnabled = status.connected
                    googleCalendarAccountEmail = status.accountEmail
                    if status.revocationPending {
                        googleCalendarError = "Disconnected. Google access revocation is being retried."
                    }
                    return
                }
                let initialStatus: CalendarConnectionStatus = try await client.functions.invoke(
                    "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                googleCalendarEnabled = initialStatus.connected
                googleCalendarAccountEmail = initialStatus.accountEmail
                if googleCalendarEnabled { return }
                let result: CalendarAuthorizationStart = try await client.functions.invoke(
                    "calendar-connection", options: FunctionInvokeOptions(body: ["action": "start", "target": "ios"]))
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                guard let url = URL(string: result.authorizationURL), url.scheme == "https",
                    url.host == "accounts.google.com", url.path == "/o/oauth2/v2/auth"
                else {
                    throw CalendarConnectionError.authorizationFailed
                }
                let callback = try await oauthSession.authenticate(url: url)
                guard callback.scheme == Config.appScheme, callback.host == "calendar", callback.path == "/callback",
                    URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "calendar" })?.value == "connected"
                else {
                    throw CalendarConnectionError.authorizationFailed
                }
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                let finalStatus: CalendarConnectionStatus = try await client.functions.invoke(
                    "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                googleCalendarEnabled = finalStatus.connected
                googleCalendarAccountEmail = finalStatus.accountEmail
                if !googleCalendarEnabled { throw CalendarConnectionError.authorizationFailed }
            } catch {
                guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return }
                googleCalendarError =
                    (error as? CalendarConnectionError)?.localizedDescription
                    ?? "Google Calendar could not be updated. Try again."
            }
        }
    }

    // MARK: - Conflict Checking

    /// Check all time options against the enabled sources (F16; see docs/calendar-coverage.md).
    /// - Parameters:
    ///   - timeOptions: The poll's time options.
    ///   - pollTimeZone: The poll's IANA zone, which gives all-day options their dates.
    /// - Returns: Busy options, plus the options a failed source could not cover.
    public func checkConflicts(for timeOptions: [PollTimeOption], pollTimeZone: String?) async -> CalendarCheckResult {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let account = accountId
            let generation = connectionGeneration
            guard account != nil, isEnabled, !timeOptions.isEmpty else { return .none }

            var sources: [(CalendarSource, Set<UUID>?)] = []
            if appleCalendarEnabled {
                let busy = await checkAppleCalendarConflicts(for: timeOptions, pollTimeZone: pollTimeZone)
                guard account == accountId, generation == connectionGeneration, !Task.isCancelled else { return .none }
                sources.append((.appleCalendar, busy))
            }
            if googleCalendarEnabled {
                let busy = await checkGoogleCalendarConflicts(for: timeOptions)
                guard account == accountId, generation == connectionGeneration, !Task.isCancelled else { return .none }
                sources.append((.googleCalendar, busy))
            }
            return CalendarCheckResult(optionIds: Set(timeOptions.map(\.id)), sources: sources)
        }
    }

    /// Busy options from every device calendar, or nil when calendar access is missing.
    private func checkAppleCalendarConflicts(for timeOptions: [PollTimeOption], pollTimeZone: String?) async -> Set<UUID>? {
        updateAuthorizationStatus()
        guard authorizationStatus == .fullAccess else {
            await setAppleCalendarEnabled(false)
            return nil
        }
        let allDates = timeOptions.flatMap { [$0.startTime, $0.endTime] }
        guard let minDate = allDates.min(), let maxDate = allDates.max() else { return [] }

        // All-day events match by date, so pad the instant window by the widest zone difference.
        let padding: TimeInterval = 2 * 86_400
        let predicate = eventStore.predicateForEvents(
            withStart: minDate.addingTimeInterval(-padding),
            end: maxDate.addingTimeInterval(padding),
            calendars: nil
        )
        let deviceZone = TimeZone.current
        let periods = eventStore.events(matching: predicate).compactMap { busyPeriod(of: $0, in: deviceZone) }
        return DeviceBusyPeriod.busyOptionIds(timeOptions, pollTimeZone: pollTimeZone, periods: periods, deviceZone: deviceZone)
    }

    private func busyPeriod(of event: EKEvent, in deviceZone: TimeZone) -> DeviceBusyPeriod? {
        DeviceBusyPeriod.of(
            isAllDay: event.isAllDay,
            start: event.startDate,
            end: event.endDate,
            availability: event.availability,
            status: event.status,
            declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
            calendarType: event.calendar.type,
            in: deviceZone
        )
    }

    /// Busy options from the Google primary calendar, or nil when it could not be checked.
    private func checkGoogleCalendarConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID>? {
        guard let userId = accountId else { return nil }
        let generation = connectionGeneration
        do {
            googleCalendarLoading = true
            defer { if generation == connectionGeneration { googleCalendarLoading = false } }

            let timeOptionsArray = timeOptions.map { option in
                [
                    "id": option.id.uuidString,
                    "start_time": ISO8601DateFormatter().string(from: option.startTime),
                    "end_time": ISO8601DateFormatter().string(from: option.endTime),
                ]
            }
            let response: GoogleCalendarConflictResponse =
                try await client
                .functions
                .invoke(
                    "check-calendar-conflicts",
                    options: FunctionInvokeOptions(body: ["timeOptions": timeOptionsArray])
                )

            guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return nil }
            // An unrecognized coverage cannot be labelled honestly, so it counts as unchecked.
            guard response.success, response.coverage == "primary" else { throw CalendarConnectionError.unavailable }
            googleCalendarError = nil
            return Set(response.conflictingIds.compactMap { UUID(uuidString: $0) })
        } catch {
            return nil
        }
    }

    /// The device calendar events that make one option busy (Apple Calendar only).
    ///
    /// Google FreeBusy reports no event details, so Google conflicts have none to list.
    public func deviceConflicts(for option: PollTimeOption, pollTimeZone: String?) async -> [CalendarConflict] {
        guard appleCalendarEnabled else { return [] }
        updateAuthorizationStatus()
        guard authorizationStatus == .fullAccess else { return [] }

        // Pad the window as the check does, so all-day events in other zones are not missed.
        let padding: TimeInterval = 2 * 86_400
        let predicate = eventStore.predicateForEvents(
            withStart: option.startTime.addingTimeInterval(-padding),
            end: option.endTime.addingTimeInterval(padding),
            calendars: nil
        )
        let deviceZone = TimeZone.current
        return eventStore.events(matching: predicate)
            .filter { event in
                busyPeriod(of: event, in: deviceZone)?
                    .overlaps(option, pollTimeZone: pollTimeZone, deviceZone: deviceZone) ?? false
            }
            .map { event in
                CalendarConflict(
                    title: event.title ?? "",
                    calendarName: event.calendar.title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay
                )
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Add to Calendar

    /// Adds `event` to the default calendar for new events, asking for calendar access first if
    /// the person hasn't been asked yet.
    public func addEventToCalendar(_ event: DeviceCalendarEvent) async -> DeviceCalendarAddResult {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            updateAuthorizationStatus()
            switch authorizationStatus {
            case .notDetermined:
                guard await requestAccess() else { return .accessDenied }
            case .fullAccess, .writeOnly, .authorized:
                break
            case .restricted, .denied:
                return .accessDenied
            @unknown default:
                return .accessDenied
            }

            let saved = EKEvent(eventStore: eventStore)
            saved.title = event.title
            if let day = event.allDayDate {
                // An all-day event is a floating date in the device calendar.
                saved.isAllDay = true
                let date = day.pickerDate()
                saved.startDate = date
                saved.endDate = date
            } else {
                saved.startDate = event.start
                saved.endDate = event.end
            }
            saved.notes = event.notes
            saved.location = event.location
            saved.calendar = eventStore.defaultCalendarForNewEvents

            do {
                try eventStore.save(saved, span: .thisEvent)
                return .added
            } catch {
                FailureLog.calendar.record("Failed to save event to calendar", error: error)
                return .failed
            }
        }
    }

    // MARK: - Backwards Compatibility

    /// Legacy method for backwards compatibility
    /// Enables Apple Calendar (the default)
    public func setEnabled(_ enabled: Bool) async {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            await setAppleCalendarEnabled(enabled)
        }
    }

    // MARK: - Helper Methods

    /// Check if an event overlaps with a time range
}

// MARK: - Helper Types

private struct CalendarConnectionStatus: Decodable {
    let connected: Bool
    let accountEmail: String?
    let requiresReconnect: Bool
    let revocationPending: Bool
}

private struct CalendarAuthorizationStart: Decodable {
    let authorizationURL: String
}

private struct GoogleCalendarConflictResponse: Decodable {
    let success: Bool
    let coverage: String
    let conflictingIds: [String]
}
