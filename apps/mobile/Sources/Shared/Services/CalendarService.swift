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
public final class CalendarService {
    public static let shared = CalendarService()

    private let eventStore = EKEventStore()

    // Apple Calendar properties
    public private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    public private(set) var appleCalendarEnabled = false

    // Google Calendar properties
    public private(set) var googleCalendarEnabled = false
    public private(set) var googleCalendarLoading = false

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
        googleCalendarEnabled = UserDefaults.standard.bool(forKey: "googleCalendarEnabled")
    }

    /// Enable/disable Apple Calendar
    public func setAppleCalendarEnabled(_ enabled: Bool) async {
        // If enabling, check and request permission if needed
        if enabled {
            updateAuthorizationStatus()

            // Check for full access or authorized
            let hasAccess = authorizationStatus == .fullAccess || authorizationStatus == .authorized
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

        // Sync to Supabase
        await syncPreferencesToSupabase()
    }

    /// Enable/disable Google Calendar
    public func setGoogleCalendarEnabled(_ enabled: Bool) async {
        if enabled {
            // For now, Google Calendar is disabled until token is set
            // User should authenticate through OAuth first
            googleCalendarEnabled = false
            return
        }

        // Disable Google Calendar
        googleCalendarEnabled = false
        UserDefaults.standard.set(false, forKey: "googleCalendarEnabled")

        // Clear tokens from Supabase
        do {
            var updates: [String: AnyJSON] = [:]
            updates["google_calendar_refresh_token"] = .null
            updates["google_calendar_token_expires_at"] = .null
            updates["google_calendar_access_token"] = .null
            try await SupabaseService.shared.client
                .from("profiles")
                .update(updates)
                .eq("id", value: AuthService.shared.currentUser?.id.uuidString ?? "")
                .execute()
        } catch {
            print("Failed to clear Google Calendar tokens: \(error)")
        }

        await syncPreferencesToSupabase()
    }

    /// Check if Google Calendar has a valid token in Supabase
    public func hasGoogleCalendarToken() async -> Bool {
        do {
            guard let userId = AuthService.shared.currentUser?.id else { return false }

            let response = try await SupabaseService.shared.client
                .from("profiles")
                .select("google_calendar_refresh_token, google_calendar_token_expires_at")
                .eq("id", value: userId.uuidString)
                .single()
                .execute()

            let profile = try response.decoded(to: GoogleCalendarProfile.self)

            // Check if refresh token exists and access token isn't expired
            if let refreshToken = profile.google_calendar_refresh_token,
               !refreshToken.isEmpty {
                // Token exists, mark Google Calendar as available
                if !googleCalendarEnabled {
                    googleCalendarEnabled = true
                    UserDefaults.standard.set(true, forKey: "googleCalendarEnabled")
                }
                return true
            }

            return false
        } catch {
            print("Failed to check Google Calendar token: \(error)")
            return false
        }
    }

    /// Sync preferences to Supabase
    private func syncPreferencesToSupabase() async {
        do {
            var updates: [String: AnyJSON] = [:]
            updates["calendar_integration_enabled"] = .bool(isEnabled)
            try await SupabaseService.shared.client
                .from("profiles")
                .update(updates)
                .eq("id", value: AuthService.shared.currentUser?.id.uuidString ?? "")
                .execute()
        } catch {
            print("Failed to sync calendar preferences to Supabase: \(error)")
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
        guard authorizationStatus == .fullAccess || authorizationStatus == .authorized else {
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
        do {
            googleCalendarLoading = true
            defer { googleCalendarLoading = false }

            let response = try await SupabaseService.shared.functions
                .invoke("check-calendar-conflicts", returning: GoogleCalendarConflictResponse.self, body: [
                    "timeOptions": timeOptions.map { option in
                        [
                            "id": option.id.uuidString,
                            "start_time": ISO8601DateFormatter().string(from: option.startTime),
                            "end_time": ISO8601DateFormatter().string(from: option.endTime)
                        ]
                    }
                ])

            let conflictIds = Set(response.conflictingIds.compactMap { UUID(uuidString: $0) })
            return conflictIds
        } catch {
            print("Failed to check Google Calendar conflicts: \(error)")
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

        guard authorizationStatus == .fullAccess || authorizationStatus == .authorized else {
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

private struct GoogleCalendarProfile: Decodable {
    let google_calendar_refresh_token: String?
    let google_calendar_token_expires_at: String?
    let google_calendar_access_token: String?
}

private struct GoogleCalendarConflictResponse: Decodable {
    let conflictingIds: [String]
}
