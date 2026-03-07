import SwiftUI
import Shared

struct AppleCalendarToggle: View {
    @Environment(\.calendarService) var calendarService

    var body: some View {
        CalendarToggle(
            isOn: Binding(
                get: { calendarService.appleCalendarEnabled },
                set: { enabled in
                    Task {
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
