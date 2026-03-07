import SwiftUI

struct CalendarToggle: View {
    @Binding var isOn: Bool
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var subtitleColor: Color = .secondary

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                }
            }
        }
    }
}

#Preview("Enabled") {
    CalendarToggle(
        isOn: .constant(true),
        icon: "calendar",
        iconColor: .blue,
        title: "Apple Calendar",
        subtitle: "Local device calendar"
    )
    .padding()
}

#Preview("Disabled") {
    CalendarToggle(
        isOn: .constant(false),
        icon: "globe",
        iconColor: .red,
        title: "Google Calendar",
        subtitle: "Not connected"
    )
    .padding()
}

#Preview("Custom Subtitle Color") {
    CalendarToggle(
        isOn: .constant(true),
        icon: "globe",
        iconColor: .red,
        title: "Google Calendar",
        subtitle: "Connected",
        subtitleColor: .green
    )
    .padding()
}
