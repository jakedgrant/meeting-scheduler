import SwiftUI
import Shared

struct GoogleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService
    @Environment(\.authService) private var authService

    var body: some View {
        CalendarToggle(
            isOn: Binding(
                get: { calendarService.googleCalendarEnabled },
                set: { enabled in
                    authService.performSessionTask(operation: { _ in
                        await calendarService.setGoogleCalendarEnabled(enabled)
                    })
                }
            ),
            icon: "globe",
            iconColor: .red,
            title: "Google Calendar",
            subtitle: calendarService.googleCalendarEnabled
                ? (calendarService.googleCalendarAccountEmail ?? "Connected") : "Not connected",
            subtitleColor: calendarService.googleCalendarEnabled ? .green : .secondary
        )
        .disabled(calendarService.googleCalendarLoading)
    }
}
