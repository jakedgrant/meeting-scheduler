import Foundation
import EventKit
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
    private let oauthSession = CalendarOAuthSession()
    private var connectionGeneration = 0

    // Overall enabled state (true if any source is enabled)
    public var isEnabled: Bool {
        appleCalendarEnabled || googleCalendarEnabled
    }

    private init() {
        updateAuthorizationStatus()
        loadPreferences()
    }

    // MARK: - Authorization Status

    private func updateAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Permission Management

    /// Request calendar access from the user
    /// - Returns: true if access was granted
    public func requestAccess() async -> Bool {
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

    // MARK: - Settings Persistence

    /// Load calendar integration preferences from UserDefaults
    private func loadPreferences() {
        appleCalendarEnabled = UserDefaults.standard.bool(forKey: "appleCalendarEnabled")
        UserDefaults.standard.removeObject(forKey: "googleCalendarEnabled")
    }

    /// Enable/disable Apple Calendar
    public func setAppleCalendarEnabled(_ enabled: Bool) async {
        // If enabling, check and request permission if needed
        if enabled {
            updateAuthorizationStatus()

            // Check for full access
            let hasAccess = authorizationStatus == .fullAccess

            if !hasAccess {
                let granted = await requestAccess()
                if !granted {
                    appleCalendarEnabled = false
                    return
                }
            }
        }

        // Update local state
        appleCalendarEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "appleCalendarEnabled")
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
        guard !googleCalendarLoading else { return }
        guard let userId = AuthService.shared.currentUserId else {
            resetGoogleCalendarState()
            return
        }
        let generation = connectionGeneration
        do {
            let status: CalendarConnectionStatus = try await SupabaseService.shared.client.functions.invoke(
                "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            googleCalendarEnabled = status.connected
            googleCalendarAccountEmail = status.accountEmail
            googleCalendarError = status.requiresReconnect ? "Reconnect Google Calendar in Settings." : nil
            if status.revocationPending {
                googleCalendarError = "Disconnected. Google access revocation is being retried."
            }
        } catch {
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            googleCalendarEnabled = false
            googleCalendarAccountEmail = nil
            googleCalendarError = "Google Calendar connection could not be checked."
        }
    }

    public func setGoogleCalendarEnabled(_ enabled: Bool) async {
        guard let userId = AuthService.shared.currentUserId else { return }
        oauthSession.cancel()
        connectionGeneration += 1
        let generation = connectionGeneration
        googleCalendarLoading = true
        googleCalendarError = nil
        defer { if generation == connectionGeneration { googleCalendarLoading = false } }
        do {
            if !enabled {
                let status: CalendarConnectionStatus = try await SupabaseService.shared.client.functions.invoke(
                    "calendar-connection", options: FunctionInvokeOptions(body: ["action": "disconnect"]))
                guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
                googleCalendarEnabled = status.connected
                googleCalendarAccountEmail = status.accountEmail
                if status.revocationPending { googleCalendarError = "Disconnected. Google access revocation is being retried." }
                return
            }
            let initialStatus: CalendarConnectionStatus = try await SupabaseService.shared.client.functions.invoke(
                "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            googleCalendarEnabled = initialStatus.connected
            googleCalendarAccountEmail = initialStatus.accountEmail
            if googleCalendarEnabled { return }
            let result: CalendarAuthorizationStart = try await SupabaseService.shared.client.functions.invoke(
                "calendar-connection", options: FunctionInvokeOptions(body: ["action": "start", "target": "ios"]))
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            guard let url = URL(string: result.authorizationURL), url.scheme == "https",
                  url.host == "accounts.google.com", url.path == "/o/oauth2/v2/auth" else {
                throw CalendarConnectionError.authorizationFailed
            }
            let callback = try await oauthSession.authenticate(url: url)
            guard callback.scheme == Config.appScheme, callback.host == "calendar", callback.path == "/callback",
                  URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "calendar" })?.value == "connected" else {
                throw CalendarConnectionError.authorizationFailed
            }
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            let finalStatus: CalendarConnectionStatus = try await SupabaseService.shared.client.functions.invoke(
                "calendar-connection", options: FunctionInvokeOptions(body: ["action": "status"]))
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            googleCalendarEnabled = finalStatus.connected
            googleCalendarAccountEmail = finalStatus.accountEmail
            if !googleCalendarEnabled { throw CalendarConnectionError.authorizationFailed }
        } catch {
            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return }
            googleCalendarError = (error as? CalendarConnectionError)?.localizedDescription
                ?? "Google Calendar could not be updated. Try again."
        }
    }

    // MARK: - Conflict Checking

    /// Check all time options for calendar conflicts from enabled sources
    /// - Parameter timeOptions: Array of poll time options to check
    /// - Returns: Set of option IDs that have calendar conflicts
    public func checkConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        guard isEnabled else { return Set() }
        guard !timeOptions.isEmpty else { return Set() }

        var allConflictingIds = Set<UUID>()

        // Check Apple Calendar if enabled
        if appleCalendarEnabled {
            let appleConflicts = await checkAppleCalendarConflicts(for: timeOptions)
            allConflictingIds.formUnion(appleConflicts)
        }

        // Check Google Calendar if enabled
        if googleCalendarEnabled {
            let googleConflicts = await checkGoogleCalendarConflicts(for: timeOptions)
            allConflictingIds.formUnion(googleConflicts)
        }

        return allConflictingIds
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
        guard let userId = AuthService.shared.currentUserId else { return Set() }
        let generation = connectionGeneration
        do {
            googleCalendarLoading = true
            defer { if generation == connectionGeneration { googleCalendarLoading = false } }

            // Build the request payload
            let timeOptionsArray = timeOptions.map { option in
                [
                    "id": option.id.uuidString,
                    "start_time": ISO8601DateFormatter().string(from: option.startTime),
                    "end_time": ISO8601DateFormatter().string(from: option.endTime)
                ]
            }

            let requestBody = ["timeOptions": timeOptionsArray]

            // Invoke the Edge Function
            let response: GoogleCalendarConflictResponse = try await SupabaseService.shared.client
                .functions
                .invoke(
                    "check-calendar-conflicts",
                    options: FunctionInvokeOptions(body: requestBody)
                )

            guard AuthService.shared.currentUserId == userId, generation == connectionGeneration else { return Set() }
            guard response.success else { throw CalendarConnectionError.unavailable }
            googleCalendarError = nil
            let conflictIds = Set(response.conflictingIds.compactMap { UUID(uuidString: $0) })
            return conflictIds
        } catch {
            if AuthService.shared.currentUserId == userId, generation == connectionGeneration {
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
        notes: String? = nil,
        location: String? = nil
    ) async -> Bool {
        
        updateAuthorizationStatus()
        
        // check permission
        switch authorizationStatus {
        case .notDetermined:
            
            let _ = await requestAccess()
            return false //
            
        case .restricted, .denied:
            return false
            
        case .fullAccess, .writeOnly:
            break
            
        case .authorized: // (Deprecated) This application is authorized to access the service.
            break
            
        @unknown default:
            return false
        }

        // Create the event
        let event = EKEvent(eventStore: eventStore)
        event.title = title
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

    // MARK: - Backwards Compatibility

    /// Legacy method for backwards compatibility
    /// Enables Apple Calendar (the default)
    public func setEnabled(_ enabled: Bool) async {
        await setAppleCalendarEnabled(enabled)
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
