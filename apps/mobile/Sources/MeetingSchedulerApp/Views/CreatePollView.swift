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

    @State var title = ""
    @State var description = ""
    @State var location = ""
    @State var isAllDay = false
    @State var useDateRange = false
    @State var timeOptions: [TimeOption] = [TimeOption()]
    @State var isLoading = false
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
                
                Section("Poll Details") {
                    TextField("Title", text: $title)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Location (optional)", text: $location)

                    Toggle("All-day events", isOn: $isAllDay)
                }
                .onChange(of: isAllDay) { _, _ in
                    // Reset time options when toggling all-day mode
                    // This ensures the UI updates properly
                }

                Section("Time Options") {
                    if isAllDay {
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
                    } else {
                        Toggle("Use date range selector", isOn: $useDateRange)

                        if useDateRange {
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

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
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

                ToolbarItem(placement: .primaryAction) {
                    Button("Create Poll", systemImage: "checkmark") {
                        createPoll()
                    }
                    #if os(iOS)
                    .buttonStyle(.glassProminent)
                    #endif
                    .disabled(title.isEmpty || isLoading)
                }
            }
            .interactiveDismissDisabled(isLoading)
        }
        .onAppear {
            UIDatePicker.appearance().minuteInterval = 15
        }
        
        .onDisappear {
            UIDatePicker.appearance().minuteInterval = 1
        }
    }

    

    // Helper function for date ranges
    private func startOfToday() -> Date {
        let calendar = Calendar.current
        return calendar.startOfDay(for: Date())
    }

    private func addTimeOption() {
        timeOptions.append(TimeOption())
    }

    private func addSelectedDates() {
        let calendar = Calendar.current

        // Convert DateComponents to Date objects and create TimeOptions
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

        // Sort chronologically by date and start time
        timeOptions.sort { option1, option2 in
            let date1 = calendar.startOfDay(for: option1.date)
            let date2 = calendar.startOfDay(for: option2.date)
            if date1 != date2 {
                return date1 < date2
            }
            return option1.startTime < option2.startTime
        }

        // Clear selected dates
        selectedDates.removeAll()
        errorMessage = nil
    }

    private func addDateRange() {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: rangeStartDate)
        let endDay = calendar.startOfDay(for: rangeEndDate)

        // Validate date range
        guard startDay <= endDay else {
            errorMessage = "Start date must be before or equal to end date"
            return
        }

        // Validate time range if not all-day
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

        // Generate time options for each date in the range
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

        // Sort chronologically by date and start time
        timeOptions.sort { option1, option2 in
            let date1 = calendar.startOfDay(for: option1.date)
            let date2 = calendar.startOfDay(for: option2.date)
            if date1 != date2 {
                return date1 < date2
            }
            return option1.startTime < option2.startTime
        }

        // Reset the range fields
        rangeStartDate = Date()
        rangeEndDate = Date()
        rangeStartTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        rangeEndTime = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        errorMessage = nil
    }

    private func createPoll() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Create the poll
                let poll = try await PollService.shared.createPoll(
                    title: title,
                    description: description.isEmpty ? nil : description,
                    location: location.isEmpty ? nil : location
                )

                // Add time options
                let options = timeOptions.map { option -> (start: Date, end: Date, isAllDay: Bool) in
                    let calendar = Calendar.current

                    let start: Date
                    let end: Date

                    if isAllDay {
                        // For all-day events, use 00:00 as start and 23:59 as end
                        start = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: option.date) ?? option.date
                        end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: option.date) ?? option.date
                    } else {
                        // Combine date with start time
                        let startComponents = calendar.dateComponents([.hour, .minute], from: option.startTime)
                        start = calendar.date(bySettingHour: startComponents.hour ?? 9,
                                              minute: startComponents.minute ?? 0,
                                              second: 0,
                                              of: option.date) ?? option.date

                        // Combine date with end time
                        let endComponents = calendar.dateComponents([.hour, .minute], from: option.endTime)
                        end = calendar.date(bySettingHour: endComponents.hour ?? 10,
                                            minute: endComponents.minute ?? 0,
                                            second: 0,
                                            of: option.date) ?? option.date
                    }

                    return (start: start, end: end, isAllDay: isAllDay)
                }

                // Validate that end time is after start time for all options (only if not all-day)
                if !isAllDay {
                    for option in options {
                        if option.end <= option.start {
                            await MainActor.run {
                                errorMessage = "End time must be after start time for all time options"
                                isLoading = false
                            }
                            return
                        }
                    }
                }

                _ = try await PollService.shared.addTimeOptions(pollId: poll.id, options: options)

                await MainActor.run {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }
    }
}

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
    
    // Helper functions for date ranges
    private func startOfToday() -> Date {
        let calendar = Calendar.current
        return calendar.startOfDay(for: Date())
    }
    
    private func getStartTimeRange(for date: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: date)
        
        // Create a date representing the start of the day (00:00)
        let dayStart = calendar.startOfDay(for: date)
        
        // Create a date representing the end of the day (23:59)
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
        
        // If the selected date is today, start from current time
        if selectedDay == today {
            let now = Date()
            // Round up to next 15-minute interval
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
        
        // End time must be at least 15 minutes after start time
        let minEndTime = calendar.date(byAdding: .minute, value: 15, to: startTime) ?? startTime
        
        // End of the same day as start time
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: startTime) ?? startTime
        
        return minEndTime...dayEnd
    }
}

#Preview {
    CreatePollView()
}
