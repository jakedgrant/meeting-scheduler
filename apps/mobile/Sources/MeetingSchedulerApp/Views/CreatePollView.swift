import SwiftUI
import Shared

struct TimeOption: Identifiable {
    let id = UUID()
    var date = Date()
    var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var endTime = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
}

struct CreatePollView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.pollService) var pollService

    @State var title = ""
    @State var description = ""
    @State var location = ""
    @State var dueDate: Date?
    @State var hasDueDate = false
    @State var isAllDay = false
    @State var useDateRange = false
    @State var timeOptions: [TimeOption] = [TimeOption()]
    @State private var editor = PollCreationEditor()
    @State private var useEventPass = false
    private var isLoading: Bool { editor.isSubmitting }
    @State var errorMessage: String?

    // Date range fields
    @State var rangeStartDate = Date()
    @State var rangeEndDate = Date()
    @State var rangeStartTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State var rangeEndTime = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()

    // Multi-date picker for all-day events
    @State var selectedDates = Set<DateComponents>()

    var body: some View {
        NavigationStack {
            Form {
                pollDetailsSection
                    .disabled(isLoading || editor.mustResolvePending)
                timeOptionsSection
                    .disabled(isLoading || editor.mustResolvePending)
                eventPassSection
                    .disabled(isLoading || editor.mustResolvePending)
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
                    .disabled(isLoading)
                }
            }
            .interactiveDismissDisabled(isLoading)
        }
        .task(id: AuthService.shared.currentUserId) {
            editor.selectAccount(AuthService.shared.currentUserId)
            restoreDraft(editor.pending?.payload)
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
            TextField("Title", text: $title)
            TextField("Description (optional)", text: $description, axis: .vertical)
                .lineLimit(3...6)
            TextField("Location (optional)", text: $location)

            Toggle("Set response deadline", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Due Date", selection: Binding(
                    get: { dueDate ?? Date() },
                    set: { dueDate = $0 }
                ), in: Date()..., displayedComponents: .date)
                .datePickerStyle(.compact)
            }

            Toggle("All-day events", isOn: $isAllDay)
        }
        .onChange(of: isAllDay) { _, _ in
            // Reset time options when toggling all-day mode
        }
    }

    private var timeOptionsSection: some View {
        Section("Time Options") {
            if isAllDay {
                allDayDatePicker
            } else {
                Toggle("Use date range selector", isOn: $useDateRange)
                if useDateRange {
                    dateRangePicker
                }
            }

            ForEach($timeOptions) { $option in
                TimeOptionView(option: $option, isAllDay: isAllDay)
                    .swipeActions(edge: .trailing) {
                        if timeOptions.count > 1 {
                            Button(role: .destructive) {
                                timeOptions.removeAll { $0.id == option.id }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }

            Button(action: addTimeOption) {
                Label("Add Time Option", systemImage: "plus.circle")
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = errorMessage ?? editor.errorMessage {
            Section {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
    }

    private var createPollButtonSection: some View {
        Section {
            Button(action: createPoll) {
                HStack {
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(editor.mustResolvePending ? "Retry Creation" : "Create Poll")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(title.isEmpty || isLoading)
        }
    }

    private var eventPassSection: some View {
        Section {
            Toggle("Use Event Pass", isOn: $useEventPass)
        } footer: {
            Text("Use the oldest available event pass for this poll. An active Pro or Team subscription takes priority and keeps your pass. Your plan and participant limit are checked when the poll is created.")
        }
    }

    // MARK: - Subviews

    private var allDayDatePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Days")
                .font(.headline)

            MultiDatePicker("Days", selection: $selectedDates)

            Button("Add Selected Days", systemImage: "calendar.badge.plus") {
                addSelectedDates()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedDates.isEmpty)
        }
        .padding(.vertical, 8)
    }

    private var dateRangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Date Range")
                .font(.headline)

            DatePicker("Start Date", selection: $rangeStartDate, in: startOfToday()..., displayedComponents: .date)

            DatePicker("End Date", selection: $rangeEndDate, in: startOfToday()..., displayedComponents: .date)

            DatePicker("Start Time", selection: $rangeStartTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)

            DatePicker("End Time", selection: $rangeEndTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)

            Button(action: addDateRange) {
                Label("Add Date Range", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private func addTimeOption() {
        timeOptions.append(TimeOption())
    }

    private func addSelectedDates() {
        let calendar = Calendar.current

        for dateComponents in selectedDates {
            if let date = calendar.date(from: dateComponents) {
                let newOption = TimeOption(
                    date: date,
                    startTime: calendar.date(bySettingHour: 0, minute: 0, second: 0, of: date) ?? date,
                    endTime: calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
                )
                timeOptions.append(newOption)
            }
        }

        sortTimeOptions()
        selectedDates.removeAll()
        errorMessage = nil
    }

    private func addDateRange() {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: rangeStartDate)
        let endDay = calendar.startOfDay(for: rangeEndDate)

        guard startDay <= endDay else {
            errorMessage = "Start date must be before or equal to end date"
            return
        }

        if !isAllDay {
            let startComponents = calendar.dateComponents([.hour, .minute], from: rangeStartTime)
            let endComponents = calendar.dateComponents([.hour, .minute], from: rangeEndTime)
            let startMinutes = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)
            let endMinutes = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)

            if endMinutes <= startMinutes {
                errorMessage = "End time must be after start time"
                return
            }
        }

        var currentDate = startDay
        while currentDate <= endDay {
            let newOption = TimeOption(
                date: currentDate,
                startTime: rangeStartTime,
                endTime: rangeEndTime
            )
            timeOptions.append(newOption)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        sortTimeOptions()
        resetRangeFields()
        errorMessage = nil
    }

    private func sortTimeOptions() {
        let calendar = Calendar.current
        timeOptions.sort { option1, option2 in
            let date1 = calendar.startOfDay(for: option1.date)
            let date2 = calendar.startOfDay(for: option2.date)
            if date1 != date2 {
                return date1 < date2
            }
            return option1.startTime < option2.startTime
        }
    }

    private func resetRangeFields() {
        let calendar = Calendar.current
        rangeStartDate = Date()
        rangeEndDate = Date()
        rangeStartTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        rangeEndTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }

    // MARK: - Actions

    private func createPoll() {
        errorMessage = nil
        let payload = editor.mustResolvePending ? editor.pending?.payload : PollCreationPayload(
            title: title, description: description.isEmpty ? nil : description,
            location: location.isEmpty ? nil : location, timezone: TimeZone.current.identifier,
            closesAt: hasDueDate ? dueDate : nil,
            timeOptions: buildTimeOptions().map { PollCreationOption(startTime: $0.start, endTime: $0.end, isAllDay: $0.isAllDay) },
            useEventPass: useEventPass
        )
        guard let payload else { return }
        let identity = AuthService.shared.currentUserId
        Task {
            guard AuthService.shared.currentUserId == identity, !Task.isCancelled else { return }
            await editor.submit(payload, using: pollService)
            guard AuthService.shared.currentUserId == identity, !Task.isCancelled else { return }
            if editor.result != nil { dismiss() }
        }
    }

    private func restoreDraft(_ payload: PollCreationPayload?) {
        title = payload?.title ?? ""
        description = payload?.description ?? ""
        location = payload?.location ?? ""
        dueDate = payload?.closesAt
        hasDueDate = dueDate != nil
        useEventPass = payload?.useEventPass ?? false
        isAllDay = payload?.timeOptions.first?.isAllDay ?? false
        timeOptions = payload?.timeOptions.map { TimeOption(date: $0.startTime, startTime: $0.startTime, endTime: $0.endTime) } ?? [TimeOption()]
        errorMessage = nil
    }

    private func buildTimeOptions() -> [(start: Date, end: Date, isAllDay: Bool)] {
        timeOptions.map { option -> (start: Date, end: Date, isAllDay: Bool) in
            let calendar = Calendar.current

            let start: Date
            let end: Date

            if isAllDay {
                start = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: option.date) ?? option.date
                end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: option.date) ?? option.date
            } else {
                let startComponents = calendar.dateComponents([.hour, .minute], from: option.startTime)
                start = calendar.date(bySettingHour: startComponents.hour ?? 9,
                                      minute: startComponents.minute ?? 0,
                                      second: 0,
                                      of: option.date) ?? option.date

                let endComponents = calendar.dateComponents([.hour, .minute], from: option.endTime)
                end = calendar.date(bySettingHour: endComponents.hour ?? 10,
                                    minute: endComponents.minute ?? 0,
                                    second: 0,
                                    of: option.date) ?? option.date
            }

            return (start: start, end: end, isAllDay: isAllDay)
        }
    }
}

// MARK: - TimeOptionView

struct TimeOptionView: View {
    @Binding var option: TimeOption
    let isAllDay: Bool

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
        Calendar.current.startOfDay(for: Date())
    }

    private func getStartTimeRange(for date: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: date)

        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date

        if selectedDay == today {
            let now = Date()
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
        let calendar = Calendar.current
        let minEndTime = calendar.date(byAdding: .minute, value: 15, to: startTime) ?? startTime
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: startTime) ?? startTime

        return minEndTime...dayEnd
    }
}

#Preview {
    CreatePollView()
        .environment(\.pollService, MockPollService.empty)
}
