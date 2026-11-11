import SwiftUI

/// A date-only picker that always shows its value as "Tue. Dec 22, 2026".
///
/// The system compact `DatePicker` switches to a numeric "12/22/26" label when
/// space is tight, so the same list of dates can mix formats. This draws the
/// label itself and keeps the system picker on top to handle taps, with
/// `.destinationOver` so only the custom label shows. The English format is
/// deliberate: one fixed format everywhere, regardless of width or locale.
struct DayPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: Date
    let range: PartialRangeFrom<Date>
    var calendar: Calendar = .current

    var body: some View {
        LabeledContent(title) {
            Text(Self.label(for: selection, calendar: calendar))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    DatePicker(title, selection: $selection, in: range, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, calendar.timeZone)
                        .blendMode(.destinationOver)
                }
        }
    }

    nonisolated static func label(for date: Date, calendar: Calendar) -> String {
        date.formatted(.verbatim(
            "\(weekday: .abbreviated). \(month: .abbreviated) \(day: .defaultDigits), \(year: .defaultDigits)",
            locale: Locale(identifier: "en_US"), timeZone: calendar.timeZone, calendar: calendar))
    }
}
