import EventKit
import Foundation
import Supabase

/// Calendar source options
public enum CalendarSource: String, Codable {
    case appleCalendar = "apple"
    case googleCalendar = "google"
}

/// Service for managing calendar integration and conflict detection
/// Supports both Apple Calendar (EventKit) and Google Calendar APIs
@MainActor
@Observable
public final class CalendarService: CalendarServiceProtocol {
    public static let shared = CalendarService()

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
    private let clientFactory: @MainActor () -> SupabaseClient
    private let requestCredentials: @MainActor () -> AccountRequestCredentials?
    private let accessRequest: (@MainActor () async -> Bool)?

    // Overall enabled state (true if any source is enabled)
    public var isEnabled: Bool {
        appleCalendarEnabled || googleCalendarEnabled
    }

    private convenience init() {
        self.init(preferences: .standard, clientFactory: { SupabaseService.shared.client })
    }

    convenience init(preferences: UserDefaults, client: SupabaseClient, accessRequest: (@MainActor () async -> Bool)? = nil) {
        self.init(preferences: preferences, clientFactory: { client }, accessRequest: accessRequest, requestCredentials: { nil })
    }

    init(
        preferences: UserDefaults, clientFactory: @escaping @MainActor () -> SupabaseClient,
        accessRequest: (@MainActor () async -> Bool)? = nil,
        requestCredentials: @escaping @MainActor () -> AccountRequestCredentials? = { SupabaseService.shared.requestCredentials }
    ) {
        self.requestCredentials = requestCredentials
        self.preferences = preferences
        self.clientFactory = clientFactory
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
                print("Calendar access request failed: \(error)")
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
            let client = clientFactory()
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
            let client = clientFactory()
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

    /// Check all time options for calendar conflicts from enabled sources
    /// - Parameter timeOptions: Array of poll time options to check
    /// - Returns: Set of option IDs that have calendar conflicts
    public func checkConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let account = accountId
            let generation = connectionGeneration
            guard account != nil, isEnabled else { return Set() }
            guard !timeOptions.isEmpty else { return Set() }

            var allConflictingIds = Set<UUID>()

            // Check Apple Calendar if enabled
            if appleCalendarEnabled {
                let appleConflicts = await checkAppleCalendarConflicts(for: timeOptions)
                guard account == accountId, generation == connectionGeneration, !Task.isCancelled else { return [] }
                allConflictingIds.formUnion(appleConflicts)
            }

            // Check Google Calendar if enabled
            if googleCalendarEnabled {
                let googleConflicts = await checkGoogleCalendarConflicts(for: timeOptions)
                guard account == accountId, generation == connectionGeneration, !Task.isCancelled else { return [] }
                allConflictingIds.formUnion(googleConflicts)
            }

            return allConflictingIds
        }
    }

    /// Check Apple Calendar for conflicts
    private func checkAppleCalendarConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        updateAuthorizationStatus()

        // Check if we have permission
        guard authorizationStatus == .fullAccess else {
            // Permission was revoked
            await setAppleCalendarEnabled(false)
            return Set()
        }

        // Find the overall date range to query
        let allDates = timeOptions.flatMap { [$0.startTime, $0.endTime] }
        guard let minDate = allDates.min(), let maxDate = allDates.max() else {
            return Set()
        }

        // Single EventKit query for entire date range (batched for performance)
        let predicate = eventStore.predicateForEvents(
            withStart: minDate,
            end: maxDate,
            calendars: nil  // Check all calendars
        )

        let events = eventStore.events(matching: predicate)

        // Filter out events that don't count as busy:
        // - All-day events
        // - Transparent events (don't block time)
        let busyEvents = events.filter { event in
            !event.isAllDay && event.availability != .free
        }

        // Check each time option for conflicts
        var conflictingIds = Set<UUID>()

        for option in timeOptions {
            let hasConflict = busyEvents.contains { event in
                overlaps(event: event, start: option.startTime, end: option.endTime)
            }

            if hasConflict {
                conflictingIds.insert(option.id)
            }
        }

        return conflictingIds
    }

    /// Check Google Calendar for conflicts via Edge Function
    private func checkGoogleCalendarConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        let client = clientFactory()
        guard let userId = accountId else { return Set() }
        let generation = connectionGeneration
        do {
            googleCalendarLoading = true
            defer { if generation == connectionGeneration { googleCalendarLoading = false } }

            // Build the request payload
            let timeOptionsArray = timeOptions.map { option in
                [
                    "id": option.id.uuidString,
                    "start_time": ISO8601DateFormatter().string(from: option.startTime),
                    "end_time": ISO8601DateFormatter().string(from: option.endTime),
                ]
            }

            let requestBody = ["timeOptions": timeOptionsArray]

            // Invoke the Edge Function
            let response: GoogleCalendarConflictResponse =
                try await client
                .functions
                .invoke(
                    "check-calendar-conflicts",
                    options: FunctionInvokeOptions(body: requestBody)
                )

            guard accountId == userId, generation == connectionGeneration, !Task.isCancelled else { return Set() }
            guard response.success else { throw CalendarConnectionError.unavailable }
            googleCalendarError = nil
            let conflictIds = Set(response.conflictingIds.compactMap { UUID(uuidString: $0) })
            return conflictIds
        } catch {
            if accountId == userId, generation == connectionGeneration {
                googleCalendarError = "Google Calendar could not be checked. Review your availability before saving."
            }
            return Set()
        }
    }

    /// Get conflicting events for a specific time range (Apple Calendar only)
    /// - Parameters:
    ///   - start: Start time for the range
    ///   - end: End time for the range
    /// - Returns: Array of conflicting events
    public func getConflictingEvents(start: Date, end: Date) async -> [EKEvent] {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            guard appleCalendarEnabled else { return [] }

            updateAuthorizationStatus()

            guard authorizationStatus == .fullAccess else {
                await setAppleCalendarEnabled(false)
                return []
            }

            let predicate = eventStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: nil
            )

            let events = eventStore.events(matching: predicate)

            return events.filter { !$0.isAllDay && $0.availability != .free }
        }
    }

    // MARK: - Add to Calendar

    /// Add an event to the user's calendar
    /// - Parameters:
    ///   - title: Event title
    ///   - startDate: Event start date
    ///   - endDate: Event end date
    ///   - notes: Optional event notes/description
    ///   - location: Optional event location
    /// - Returns: true if event was successfully added
    public func addEventToCalendar(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        notes: String? = nil,
        location: String? = nil
    ) async -> Bool {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {

            updateAuthorizationStatus()

            // check permission
            switch authorizationStatus {
            case .notDetermined:

                let _ = await requestAccess()
                return false  //

            case .restricted, .denied:
                return false

            case .fullAccess, .writeOnly:
                break

            case .authorized:  // (Deprecated) This application is authorized to access the service.
                break

            @unknown default:
                return false
            }

            // Create the event
            let event = EKEvent(eventStore: eventStore)
            event.title = title
            event.isAllDay = isAllDay
            event.startDate = startDate
            event.endDate = endDate
            event.notes = notes
            event.location = location
            event.calendar = eventStore.defaultCalendarForNewEvents

            do {
                try eventStore.save(event, span: .thisEvent)
                return true
            } catch {
                print("Failed to save event to calendar: \(error)")
                return false
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
    private func overlaps(event: EKEvent, start: Date, end: Date) -> Bool {
        event.startDate < end && event.endDate > start
    }
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
    let conflictingIds: [String]
}
