import SwiftUI
import Shared

struct GoogleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService

    var body: some View {
        CalendarToggle(
            isOn: Binding(
                get: { calendarService.googleCalendarEnabled },
                set: { enabled in
                    Task {
                        await calendarService.setGoogleCalendarEnabled(enabled)
                    }
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
