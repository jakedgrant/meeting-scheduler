import SwiftUI
import Shared

struct CreatePollView: View {
    @Environment(\.pollService) private var pollService
    @Environment(\.authService) private var authService
    @Environment(\.appClock) private var clock

    var body: some View {
        // The form keeps the first model it receives.
        CreatePollForm(model: PollCreationModel(auth: authService, polls: pollService, clock: clock))
    }
}

/// A button label whose icon follows the button's foreground style. A `Label` inside a `Form`
/// tints its icon with the accent color, which matches a prominent button's background and
/// hides the icon.
private struct ProminentButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

private struct CreatePollForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PollCreationModel

    init(model: PollCreationModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                pollDetailsSection
                    .disabled(model.isFormLocked)
                timeOptionsSection
                    .disabled(model.isFormLocked)
                eventPassSection
                    .disabled(model.isFormLocked)
                errorSection
                createPollButtonSection
            }
            .navigationTitle("New Poll")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                    .disabled(model.isSubmitting)
                }
            }
            .interactiveDismissDisabled(model.isSubmitting)
        }
        .task(id: model.currentAccountId) {
            model.selectCurrentAccount()
        }
        .onAppear {
            UIDatePicker.appearance().minuteInterval = 15
        }
        .onDisappear {
            UIDatePicker.appearance().minuteInterval = 1
        }
    }

    // MARK: - Sections

    private var pollDetailsSection: some View {
        Section("Poll Details") {
            TextField("Title", text: $model.title)
            TextField("Description (optional)", text: $model.description, axis: .vertical)
                .lineLimit(3...6)
            TextField("Location (optional)", text: $model.location)

            Toggle("Set response deadline", isOn: $model.hasDueDate)
            if model.hasDueDate {
                DatePicker("Due Date", selection: Binding(
                    get: { model.dueDate ?? model.now },
                    set: { model.dueDate = $0 }
                ), in: model.now..., displayedComponents: .date)
                .datePickerStyle(.compact)
            }

            Toggle("All-day events", isOn: $model.isAllDay)
        }
    }

    private var timeOptionsSection: some View {
        Section("Time Options") {
            if model.isAllDay {
                allDayDatePicker
            } else {
                Toggle("Use date range selector", isOn: $model.useDateRange)
                if model.useDateRange {
                    dateRangePicker
                }
            }

            ForEach($model.options) { $option in
                TimeOptionView(option: $option, isAllDay: model.isAllDay, now: model.now, calendar: model.calendar)
                    .swipeActions(edge: .trailing) {
                        if model.options.count > 1 {
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
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = model.errorMessage {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    private var createPollButtonSection: some View {
        Section {
            Button(action: { model.create { dismiss() } }) {
                HStack {
                    Spacer()
                    if model.isSubmitting {
                        ProgressView()
                    } else {
                        Text(model.mustResolvePending ? "Retry Creation" : "Create Poll")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(!model.canSubmit)
        }
    }

    private var eventPassSection: some View {
        Section {
            Toggle("Use Event Pass", isOn: $model.useEventPass)
        } footer: {
            Text("Use the oldest available event pass for this poll. An active Pro or Team subscription takes priority and keeps your pass. Your plan and participant limit are checked when the poll is created.")
        }
    }

    // MARK: - Subviews

    private var allDayDatePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Days")
                .font(.headline)

            MultiDatePicker("Days", selection: $model.selectedDates)

            Button {
                model.addSelectedDates()
            } label: {
                ProminentButtonLabel(title: "Add Selected Days", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedDates.isEmpty)
        }
        .padding(.vertical, 8)
    }

    private var dateRangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Date Range")
                .font(.headline)

            DatePicker("Start Date", selection: $model.rangeStartDate, in: model.startOfToday..., displayedComponents: .date)

            DatePicker("End Date", selection: $model.rangeEndDate, in: model.startOfToday..., displayedComponents: .date)

            DatePicker("Start Time", selection: $model.rangeStartTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)

            DatePicker("End Time", selection: $model.rangeEndTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)

            Button(action: model.addDateRange) {
                ProminentButtonLabel(title: "Add Date Range", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - TimeOptionView

struct TimeOptionView: View {
    @Binding var option: PollCreationModel.Option
    let isAllDay: Bool
    let now: Date
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Date", selection: $option.date, in: startOfToday()..., displayedComponents: .date)

            if !isAllDay {
                DatePicker("Start", selection: $option.startTime, in: getStartTimeRange(for: option.date), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                DatePicker("End", selection: $option.endTime, in: getEndTimeRange(for: option.startTime), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
            }
        }
    }

    // MARK: - Helpers

    private func startOfToday() -> Date {
        calendar.startOfDay(for: now)
    }

    private func getStartTimeRange(for date: Date) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let selectedDay = calendar.startOfDay(for: date)

        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date

        if selectedDay == today {
            let components = calendar.dateComponents([.hour, .minute], from: now)
            let currentMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let roundedMinutes = ((currentMinutes / 15) + 1) * 15
            let roundedHour = roundedMinutes / 60
            let roundedMinute = roundedMinutes % 60

            if let roundedTime = calendar.date(bySettingHour: roundedHour, minute: roundedMinute, second: 0, of: date) {
                return roundedTime...dayEnd
            }
        }

        return dayStart...dayEnd
    }

    private func getEndTimeRange(for startTime: Date) -> ClosedRange<Date> {
        let minEndTime = calendar.date(byAdding: .minute, value: 15, to: startTime) ?? startTime
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: startTime) ?? startTime

        return minEndTime...dayEnd
    }
}

#Preview {
    CreatePollView()
        .previewServices(polls: MockPollService.empty)
}
