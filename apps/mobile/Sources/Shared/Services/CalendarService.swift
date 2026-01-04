import Foundation
import EventKit
import Supabase

/// Service for managing calendar integration and conflict detection
/// Uses native EventKit for iOS to check user's calendar for conflicts
@MainActor
@Observable
public final class CalendarService {
    public static let shared = CalendarService()

    private let eventStore = EKEventStore()
    public private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    public private(set) var isEnabled = false

    private init() {
        updateAuthorizationStatus()
        loadPreference()
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

    /// Load calendar integration preference from UserDefaults
    private func loadPreference() {
        isEnabled = UserDefaults.standard.bool(forKey: "calendarIntegrationEnabled")
    }

    /// Save calendar integration preference and sync to Supabase
    public func setEnabled(_ enabled: Bool) async {
        // If enabling, check and request permission if needed
        if enabled {
            updateAuthorizationStatus()

            // Check for full access or authorized
            let hasAccess = authorizationStatus == .fullAccess || authorizationStatus == .authorized
            if !hasAccess {
                let granted = await requestAccess()
                if !granted {
                    isEnabled = false
                    return
                }
            }
        }

        // Update local state
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "calendarIntegrationEnabled")

        // Sync to Supabase profile
        do {
            var updates: [String: AnyJSON] = [:]
            updates["calendar_integration_enabled"] = .bool(enabled)
            if !enabled {
                updates["google_calendar_refresh_token"] = .null
                updates["google_calendar_token_expires_at"] = .null
            }
            try await SupabaseService.shared.client
                .from("profiles")
                .update(updates)
                .eq("id", value: AuthService.shared.currentUser?.id.uuidString ?? "")
                .execute()
        } catch {
            print("Failed to sync calendar preference to Supabase: \(error)")
            // Don't revert local state - still update UserDefaults
        }
    }

    // MARK: - Conflict Checking

    /// Check all time options for calendar conflicts
    /// - Parameter timeOptions: Array of poll time options to check
    /// - Returns: Set of option IDs that have calendar conflicts
    public func checkConflicts(for timeOptions: [PollTimeOption]) async -> Set<UUID> {
        guard isEnabled else { return Set() }

        updateAuthorizationStatus()

        // Check if we have permission
        guard authorizationStatus == .fullAccess || authorizationStatus == .authorized else {
            // Permission was revoked
            await setEnabled(false)
            return Set()
        }

        guard !timeOptions.isEmpty else { return Set() }

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

    /// Get conflicting events for a specific time range
    /// - Parameters:
    ///   - start: Start time for the range
    ///   - end: End time for the range
    /// - Returns: Array of conflicting events
    public func getConflictingEvents(start: Date, end: Date) async -> [EKEvent] {
        guard isEnabled else { return [] }

        updateAuthorizationStatus()

        guard authorizationStatus == .fullAccess || authorizationStatus == .authorized else {
            await setEnabled(false)
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

    // MARK: - Helper Methods

    /// Check if an event overlaps with a time range
    private func overlaps(event: EKEvent, start: Date, end: Date) -> Bool {
        event.startDate < end && event.endDate > start
    }
}
