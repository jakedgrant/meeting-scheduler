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
            .scrollDismissesKeyboard(.immediately)
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
                DayPicker(title: "Due Date", selection: Binding(
                    get: { model.dueDate ?? model.now },
                    set: { model.dueDate = $0 }
                ), range: model.now..., calendar: model.calendar)
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

            if !model.isAllDay {
                ForEach($model.options) { $option in
                    TimeOptionView(
                        option: $option,
                        number: (model.options.firstIndex { $0.id == option.id } ?? 0) + 1,
                        now: model.now,
                        calendar: model.calendar)
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

            MultiDatePicker("Days", selection: $model.selectedDates, in: model.startOfToday...)
        }
        .padding(.vertical, 8)
    }

    private var dateRangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Date Range")
                .font(.headline)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Option \(number)")
                .font(.headline)

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

#Preview {
    CreatePollView()
        .previewServices(polls: MockPollService.empty)
}
