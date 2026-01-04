import SwiftUI
import Shared

#if os(iOS)
import UIKit
#endif

struct PollDetailView: View {
    let pollId: UUID

    @State var poll: Poll?
    @State var timeOptions: [PollTimeOption] = []
    @State var participants: [PollParticipant] = []
    @State var responses: [AvailabilityResponse] = []
    @State var myParticipant: PollParticipant?
    @State var localResponses: [UUID: AvailabilityStatus] = [:]
    @State var calendarConflicts: Set<UUID> = []
    @State var isLoading = true
    @State var isSaving = false
    @State var showClosePollAlert = false
    @State var showSelectFinalDateAlert = false
    @State var selectedTimeOption: PollTimeOption?
    @State var isSelectingFinalDate = false

    private var isCreator: Bool {
        poll?.creatorId == AuthService.shared.currentUser?.id
    }

    private var sortedTimeOptions: [PollTimeOption] {
        timeOptions.sorted { optionA, optionB in
            let statsA = responsesForOption(optionA.id)
            let statsB = responsesForOption(optionB.id)

            // First, sort by available count (descending)
            if statsB.available != statsA.available {
                return statsB.available < statsA.available
            }

            // If available counts are equal, sort by maybe count (descending)
            return statsB.maybe < statsA.maybe
        }
    }

    private var formattedSelectedOption: String {
        guard let option = selectedTimeOption else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"
        let dateStr = dateFormatter.string(from: option.startTime)

        if option.isAllDay {
            return dateStr
        } else {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mma"
            let startTime = timeFormatter.string(from: option.startTime)
            let endTime = timeFormatter.string(from: option.endTime)
            return "\(dateStr) \(startTime) - \(endTime)"
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading poll...")
            } else if let poll = poll {
                pollContent(poll)
            } else {
                ContentUnavailableView("Poll not found", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(poll?.title ?? "Poll")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isCreator, let poll = poll {
                
                ToolbarItemGroup(placement: .primaryAction) {

                    if poll.status == .active {
                        Button("Close Poll", systemImage: "xmark.square") {
                            showClosePollAlert = true
                        }
                    }

                    if poll.status == .active {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            sharePoll()
                        }
                    }
                }
            }
        }
        .task {
            await loadPollData()
        }
        .alert("Close Poll", isPresented: $showClosePollAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Close Poll", role: .destructive) {
                updateStatus(.closed)
            }
        } message: {
            Text("Are you sure you want to close this poll? Once closed, participants will no longer be able to submit or modify their availability.")
        }
        .alert("Select Final Date", isPresented: $showSelectFinalDateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm", role: .destructive) {
                selectFinalDate()
            }
        } message: {
            Text("Set \(formattedSelectedOption) as the final meeting time? All participants will be notified.")
        }
    }

    @ViewBuilder
    private func pollContent(_ poll: Poll) -> some View {
        List {
            // Poll Info
            Section {
                if let description = poll.description {
                    Text(description)
                        .font(.subheadline)
                }
                if let location = poll.location {
                    Label(location, systemImage: "mappin")
                        .font(.subheadline)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    StatusBadge(status: poll.status)
                }
            }

            // Share Code
            if poll.status == .active {
                Section {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Share Code")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: {
                                #if os(iOS)
                                UIPasteboard.general.string = poll.shareCode
                                #endif
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text(poll.shareCode)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("Share this code for others to join")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Share")
                }
            }

            // Final Date Display
            if let selectedStart = poll.selectedStartTime,
               let selectedEnd = poll.selectedEndTime {
                Section {
                    VStack(spacing: 12) {
                        Text("Final Meeting Time Selected")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.white)
                                Text(selectedStart, style: .date)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                            }

                            if timeOptions.first(where: { $0.isAllDay }) == nil {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.white)
                                    Text("\(selectedStart, style: .time) - \(selectedEnd, style: .time)")
                                        .font(.body)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.4, green: 0.49, blue: 0.92), Color(red: 0.46, green: 0.29, blue: 0.64)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if isCreator && poll.status == .closed {
                // Final Date Selection (for organizers only)
                Section {
                    VStack(spacing: 12) {
                        Text("Select Final Meeting Time")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Choose the best time based on availability:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(sortedTimeOptions) { option in
                            Button {
                                selectedTimeOption = option
                                showSelectFinalDateAlert = true
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(option.startTime, style: .date)
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        if option.isAllDay {
                                            Text("All day")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("\(option.startTime, style: .time) - \(option.endTime, style: .time)")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    let stats = responsesForOption(option.id)
                                    HStack(spacing: 8) {
                                        ResponseCount(count: stats.available, status: .available)
                                        ResponseCount(count: stats.maybe, status: .maybe)
                                        ResponseCount(count: stats.unavailable, status: .unavailable)
                                    }

                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSelectingFinalDate)
                        }
                    }
                }
            }

            // Time Options
            Section("Time Options") {
                ForEach(timeOptions) { option in
                    TimeOptionRow(
                        option: option,
                        responses: responsesForOption(option.id),
                        myResponse: localResponses[option.id],
                        hasCalendarConflict: calendarConflicts.contains(option.id),
                        canRespond: myParticipant != nil && poll.status == .active,
                        onResponseChange: { status in
                            localResponses[option.id] = status
                        }
                    )
                }
            }

            // Save Button
            if myParticipant != nil && poll.status == .active {
                Section {
                    Button(action: saveResponses) {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save Responses")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving)
                }
            }

            // Join Button
            if myParticipant == nil && poll.status == .active {
                Section {
                    Button("Join This Poll") {
                        joinPoll()
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Participants
            Section("Participants (\(participants.count))") {
                if participants.isEmpty {
                    Text("No participants yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(participants) { participant in
                        HStack {
                            Text(participant.displayName)
                            if participant.userId == AuthService.shared.currentUser?.id {
                                Text("You")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func responsesForOption(_ optionId: UUID) -> ResponseSummary {
        let optionResponses = responses.filter { $0.timeOptionId == optionId }
        return ResponseSummary(
            available: optionResponses.filter { $0.status == .available }.count,
            maybe: optionResponses.filter { $0.status == .maybe }.count,
            unavailable: optionResponses.filter { $0.status == .unavailable }.count
        )
    }

    private func loadPollData() async {
        isLoading = true

        poll = await PollService.shared.loadPoll(id: pollId)

        if poll != nil {
            timeOptions = await PollService.shared.loadTimeOptions(pollId: pollId)
            participants = await PollService.shared.loadParticipants(pollId: pollId)

            // Find my participant
            if let userId = AuthService.shared.currentUser?.id {
                myParticipant = participants.first { $0.userId == userId }
            }

            // Load responses
            let participantIds = participants.map { $0.id }
            responses = await PollService.shared.loadResponses(participantIds: participantIds)

            // Initialize local responses
            if let myParticipant = myParticipant {
                let myResponses = responses.filter { $0.participantId == myParticipant.id }
                for response in myResponses {
                    localResponses[response.timeOptionId] = response.status
                }
            }

            // Check calendar conflicts if enabled
            if CalendarService.shared.isEnabled && !timeOptions.isEmpty {
                calendarConflicts = await CalendarService.shared.checkConflicts(for: timeOptions)

                // Auto-mark conflicts as unavailable (only if no existing response)
                for conflictId in calendarConflicts {
                    if localResponses[conflictId] == nil {
                        localResponses[conflictId] = .unavailable
                    }
                }
            }
        }

        isLoading = false
    }

    private func updateStatus(_ status: PollStatus) {
        Task {
            do {
                try await PollService.shared.updatePollStatus(pollId: pollId, status: status)
                poll?.status = status
            } catch {
                print("Failed to update status: \(error)")
            }
        }
    }

    private func joinPoll() {
        Task {
            do {
                myParticipant = try await PollService.shared.joinPoll(pollId: pollId)
                participants.append(myParticipant!)
            } catch {
                print("Failed to join poll: \(error)")
            }
        }
    }

    private func saveResponses() {
        guard let myParticipant = myParticipant else { return }

        isSaving = true

        Task {
            for (optionId, status) in localResponses {
                do {
                    try await PollService.shared.submitAvailability(
                        participantId: myParticipant.id,
                        timeOptionId: optionId,
                        status: status
                    )
                } catch {
                    print("Failed to save response: \(error)")
                }
            }

            // Reload responses
            let participantIds = participants.map { $0.id }
            responses = await PollService.shared.loadResponses(participantIds: participantIds)

            isSaving = false
        }
    }

    private func selectFinalDate() {
        guard let option = selectedTimeOption else { return }

        isSelectingFinalDate = true

        Task {
            do {
                try await PollService.shared.setSelectedFinalDate(
                    pollId: pollId,
                    startTime: option.startTime,
                    endTime: option.endTime
                )
                // Reload poll to get updated selected dates
                poll = await PollService.shared.loadPoll(id: pollId)
            } catch {
                print("Failed to set final date: \(error)")
            }
            isSelectingFinalDate = false
        }
    }

    private func sharePoll() {
        guard let poll = poll else { return }

        let shareText = """
        Join my poll: \(poll.title)

        Share Code: \(poll.shareCode)

        Open the Meeting Scheduler app and enter the code to join!
        """

        #if os(iOS)
        let activityViewController = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {

            // For iPad, set the popover presentation controller
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            rootViewController.present(activityViewController, animated: true)
        }
        #endif
    }
}

struct ResponseSummary {
    let available: Int
    let maybe: Int
    let unavailable: Int
}

struct TimeOptionRow: View {
    let option: PollTimeOption
    let responses: ResponseSummary
    let myResponse: AvailabilityStatus?
    let hasCalendarConflict: Bool
    let canRespond: Bool
    let onResponseChange: (AvailabilityStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date & Time with Calendar Badge
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(option.startTime, style: .date)
                            .font(.headline)

                        if hasCalendarConflict {
                            Label("Busy", systemImage: "calendar.badge.exclamationmark")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    if option.isAllDay {
                        Text("All day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(option.startTime, style: .time) - \(option.endTime, style: .time)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Response counts
                HStack(spacing: 8) {
                    ResponseCount(count: responses.available, status: .available)
                    ResponseCount(count: responses.maybe, status: .maybe)
                    ResponseCount(count: responses.unavailable, status: .unavailable)
                }
            }

            // Response buttons
            if canRespond {
                HStack(spacing: 8) {
                    ResponseButton(
                        status: .available,
                        isSelected: myResponse == .available,
                        action: { onResponseChange(.available) }
                    )
                    ResponseButton(
                        status: .maybe,
                        isSelected: myResponse == .maybe,
                        action: { onResponseChange(.maybe) }
                    )
                    ResponseButton(
                        status: .unavailable,
                        isSelected: myResponse == .unavailable,
                        action: { onResponseChange(.unavailable) }
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ResponseCount: View {
    let count: Int
    let status: AvailabilityStatus

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .fontWeight(.medium)
            .frame(width: 24, height: 24)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Circle())
    }

    private var backgroundColor: Color {
        switch status {
        case .available: return .green.opacity(0.2)
        case .maybe: return .orange.opacity(0.2)
        case .unavailable: return .red.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .available: return .green
        case .maybe: return .orange
        case .unavailable: return .red
        }
    }
}

struct ResponseButton: View {
    let status: AvailabilityStatus
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .frame(width: 44, height: 36)
                .background(isSelected ? selectedBackground : Color.gray.opacity(0.15))
                .foregroundStyle(isSelected ? selectedForeground : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch status {
        case .available: return "checkmark"
        case .maybe: return "questionmark"
        case .unavailable: return "xmark"
        }
    }

    private var selectedBackground: Color {
        switch status {
        case .available: return .green.opacity(0.2)
        case .maybe: return .orange.opacity(0.2)
        case .unavailable: return .red.opacity(0.2)
        }
    }

    private var selectedForeground: Color {
        switch status {
        case .available: return .green
        case .maybe: return .orange
        case .unavailable: return .red
        }
    }
}

#Preview {
    NavigationStack {
        PollDetailView(pollId: UUID())
    }
}
