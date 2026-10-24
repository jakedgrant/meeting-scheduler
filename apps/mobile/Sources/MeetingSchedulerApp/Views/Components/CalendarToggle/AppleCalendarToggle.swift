import SwiftUI
import Shared

struct AppleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService
    @Environment(\.authService) private var authService

    var body: some View {
        CalendarToggle(
            isOn: Binding(
                get: { calendarService.appleCalendarEnabled },
                set: { enabled in
                    let session = authService.sessionGeneration
                    Task {
                        guard session == authService.sessionGeneration, !Task.isCancelled else { return }
                        await calendarService.setAppleCalendarEnabled(enabled)
                    }
                }
            ),
            icon: "calendar",
            iconColor: .blue,
            title: "Apple Calendar",
            subtitle: "Local device calendar"
        )
    }
}
