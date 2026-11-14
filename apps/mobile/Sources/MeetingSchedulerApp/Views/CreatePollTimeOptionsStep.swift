import SwiftUI
import Shared

/// Step 2: all-day days, a date range, or individually edited options.
struct TimeOptionsStep: View {
    @Bindable var model: PollCreationModel

    var body: some View {
        Form {
            StepIntro(step: .timeOptions)

            Section {
                Toggle("All-day events", isOn: $model.isAllDay)

                if !model.isAllDay {
                    DisclosureGroup(isExpanded: $model.useDateRange) {
                        dateRangePicker
                    } label: {
                        Text("Add Date Range")
                            .font(.headline)
                    }
                }
            }

            if model.isAllDay {
                allDaySection
            } else {
                optionsSection
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Sections

    private var optionsSection: some View {
        let count = model.options.count
        let heading: LocalizedStringKey = switch count {
        case 0: "No options yet"
        case 1: "1 option"
        default: "\(count) options"
        }
        return Section {
            ForEach($model.options) { $option in
                TimeOptionView(
                    option: $option,
                    number: (model.options.firstIndex { $0.id == option.id } ?? 0) + 1,
                    now: model.now,
                    calendar: model.calendar,
                    onRemove: count > 1 ? { model.removeOption(id: option.id) } : nil)
                    .swipeActions(edge: .trailing) {
                        if count > 1 {
                            Button(role: .destructive) {
                                model.removeOption(id: option.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }

            Button(action: model.addOption) {
                Label("Add Time Option", systemImage: "plus.circle")
            }
        } header: {
            Text(heading)
        }
    }

    private var allDaySection: some View {
        let count = model.selectedDates.count
        let summary: LocalizedStringKey = switch count {
        case 0: "No days selected"
        case 1: "1 day selected"
        default: "\(count) days selected"
        }
        return Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select Days")
                    .font(.headline)

                MultiDatePicker("Days", selection: $model.selectedDates, in: model.startOfToday...)
            }
            .padding(.vertical, 8)
        } footer: {
            Text(summary)
        }
    }

    private var dateRangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                DayPicker(title: "Start", selection: $model.rangeStartDate, range: model.startOfToday..., calendar: model.calendar, layout: .stacked)

                DayPicker(title: "End", selection: $model.rangeEndDate, range: model.startOfToday..., calendar: model.calendar, layout: .stacked)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Time")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    DatePicker("Start Time", selection: $model.rangeStartTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()

                    Text("-")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    DatePicker("End Time", selection: $model.rangeEndTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }

            Button(action: model.addDateRange) {
                // Not a `Label`: inside a `Form` it tints the icon with the accent color, which
                // matches the prominent button's background and hides the icon.
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .accessibilityHidden(true)
                    Text("Add Date Range")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - TimeOptionView

struct TimeOptionView: View {
    @Binding var option: PollCreationModel.Option
    let number: Int
    let now: Date
    let calendar: Calendar
    /// Shows a remove button when set.
    var onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Option \(number)")
                    .font(.headline)

                Spacer()

                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove option \(number)", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            // These values carry wall times on arbitrary dates. Date bounds would clamp a
            // range's copied times to another day; the model validates the combined interval.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Starts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DayPicker(title: "Start Date", selection: $option.date, range: startOfToday()..., calendar: calendar, layout: .chip)
                    DatePicker("Start Time", selection: $option.startTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }

                GridRow {
                    Text("Ends")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DayPicker(title: "End Date", selection: endDate, range: calendar.startOfDay(for: option.date)..., calendar: calendar, layout: .chip)
                    DatePicker("End Time", selection: $option.endTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Helpers

    /// The end date, stored as whole days after the start date so moving the start keeps the span.
    private var endDate: Binding<Date> {
        Binding(
            get: { calendar.date(byAdding: .day, value: option.endDayOffset, to: option.date) ?? option.date },
            set: { newValue in
                let days = calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: option.date), to: calendar.startOfDay(for: newValue)).day
                option.endDayOffset = max(0, days ?? 0)
            })
    }

    private func startOfToday() -> Date {
        calendar.startOfDay(for: now)
    }
}
