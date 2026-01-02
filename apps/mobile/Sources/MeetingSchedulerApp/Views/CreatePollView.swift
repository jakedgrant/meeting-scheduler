import SwiftUI
import Shared

struct CreatePollView: View {
    @Environment(\.dismiss) var dismiss

    @State var title = ""
    @State var description = ""
    @State var location = ""
    @State var timeOptions: [TimeOption] = [TimeOption()]
    @State var isLoading = false
    @State var errorMessage: String?

    struct TimeOption: Identifiable {
        let id = UUID()
        var date = Date()
        var startTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        var endTime = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Poll Details") {
                    TextField("Title", text: $title)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Location (optional)", text: $location)
                }

                Section("Time Options") {
                    ForEach($timeOptions) { $option in
                        VStack(alignment: .leading, spacing: 8) {
                            DatePicker("Date", selection: $option.date, displayedComponents: .date)
                            DatePicker("Start", selection: $option.startTime, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                                .environment(\.minuteInterval, 15)
                                .onChange(of: option.startTime) { oldValue, newValue in
                                    // Auto-adjust end time if start time becomes >= end time
                                    let calendar = Calendar.current
                                    let startHour = calendar.component(.hour, from: newValue)
                                    let startMinute = calendar.component(.minute, from: newValue)
                                    let endHour = calendar.component(.hour, from: option.endTime)
                                    let endMinute = calendar.component(.minute, from: option.endTime)

                                    let startMinutes = startHour * 60 + startMinute
                                    let endMinutes = endHour * 60 + endMinute

                                    if endMinutes <= startMinutes {
                                        // Set end time to start time + 15 minutes
                                        if let newEndTime = calendar.date(byAdding: .minute, value: 15, to: newValue) {
                                            option.endTime = newEndTime
                                        }
                                    }
                                }
                            DatePicker("End", selection: $option.endTime, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                                .environment(\.minuteInterval, 15)
                        }
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
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isLoading)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createPoll()
                    }
                    .disabled(title.isEmpty || isLoading)
                }
            }
            .interactiveDismissDisabled(isLoading)
        }
    }

    private func addTimeOption() {
        timeOptions.append(TimeOption())
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
                let options = timeOptions.map { option -> (start: Date, end: Date) in
                    let calendar = Calendar.current

                    // Combine date with start time
                    let startComponents = calendar.dateComponents([.hour, .minute], from: option.startTime)
                    let start = calendar.date(bySettingHour: startComponents.hour ?? 9,
                                              minute: startComponents.minute ?? 0,
                                              second: 0,
                                              of: option.date) ?? option.date

                    // Combine date with end time
                    let endComponents = calendar.dateComponents([.hour, .minute], from: option.endTime)
                    let end = calendar.date(bySettingHour: endComponents.hour ?? 10,
                                            minute: endComponents.minute ?? 0,
                                            second: 0,
                                            of: option.date) ?? option.date

                    return (start: start, end: end)
                }

                // Validate that end time is after start time for all options
                for option in options {
                    if option.end <= option.start {
                        await MainActor.run {
                            errorMessage = "End time must be after start time for all time options"
                            isLoading = false
                        }
                        return
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

#Preview {
    CreatePollView()
}
