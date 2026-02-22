import SwiftUI
import Shared

#if os(iOS)
import UIKit
#endif

struct PollDetailView: View {
    let pollId: UUID
    @Environment(\.authService) var authService
    @Environment(\.pollService) var pollService
    @Environment(\.calendarService) var calendarService

    @State var poll: Poll?
    @State var timeOptions: [PollTimeOption] = []
    @State var participants: [PollParticipant] = []
    @State var responses: [AvailabilityResponse] = []
    @State var myParticipant: PollParticipant?
    @State var localResponses: [UUID: AvailabilityStatus] = [:]
    @State var localComment: String = ""
    @State var commentError: String = ""
    @State var calendarConflicts: Set<UUID> = []

    private let MAX_COMMENT_LENGTH = 500
    @State var isLoading = true
    @State var isSaving = false
    @State var showClosePollAlert = false
    @State var showSelectFinalDateAlert = false
    @State var finalTimeOption: PollTimeOption?
    @State var isSelectingFinalDate = false
    @State var selectedTimeOption: PollTimeOption?

    private var isCreator: Bool {
        poll?.creatorId == authService.currentUserId
    }

    private var sortedTimeOptions: [PollTimeOption] {
        timeOptions.sorted { optionA, optionB in
            let statsA = responsesForOption(optionA.id)
            let statsB = responsesForOption(optionB.id)

            if statsB.available != statsA.available {
                return statsB.available < statsA.available
            }
            return statsB.maybe < statsA.maybe
        }
    }

    private var formattedSelectedOption: String {
        guard let option = finalTimeOption else { return "" }

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

            ToolbarItem(placement: .principal) {
                HStack {
                    Text(poll?.title ?? "Poll")
                    StatusBadge(status: poll?.status ?? .archived)
                }
            }

            if let poll = poll, poll.status == .active {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        sharePoll()
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
        .navigationDestination(item: $selectedTimeOption) { timeOption in
            TimeOptionResponsesView(pollId: pollId, timeOption: timeOption)
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func pollContent(_ poll: Poll) -> some View {
        List {
            pollInfoSection(poll)
            shareCodeSection(poll)
            joinButtonSection(poll)
            finalDateSection(poll)
            timeOptionsSection(poll)
            commentSection(poll)
            saveButtonSection(poll)
            participantsSection
            closePollButtonSection(poll)
        }
    }

    // MARK: - Sections

    private func pollInfoSection(_ poll: Poll) -> some View {
        Section {
            if let description = poll.description {
                Text(description)
                    .font(.subheadline)
            }
            if let location = poll.location {
                Label(location, systemImage: "mappin")
                    .font(.subheadline)
            }
            if let closesAt = poll.closesAt {
                let isPastDue = closesAt < Date()
                let isClosingSoon = !isPastDue && closesAt.timeIntervalSinceNow < 24 * 60 * 60

                HStack {
                    Label("Response deadline", systemImage: isPastDue ? "exclamationmark.triangle.fill" : "calendar")
                        .font(.subheadline)
                    Spacer()
                    Text(closesAt, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(isPastDue ? .red : (isClosingSoon ? .orange : .secondary))
                }
                if isPastDue {
                    Text("Past due")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if isClosingSoon {
                    Text("Closes soon!")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func shareCodeSection(_ poll: Poll) -> some View {
        if poll.status == .active {
            Section("Share") {
                VStack(spacing: 12) {
                    // Share Link
                    VStack(spacing: 8) {
                        HStack {
                            Text("Share Link")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: {
                                #if os(iOS)
                                let pollURL = "\(Config.webURL)/polls/\(poll.id)"
                                UIPasteboard.general.string = pollURL
                                #endif
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("\(Config.webURL)/polls/\(poll.id)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    // Share Code
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
                }
            }
        }
    }

    @ViewBuilder
    private func finalDateSection(_ poll: Poll) -> some View {
        if let selectedStart = poll.selectedStartTime,
           let selectedEnd = poll.selectedEndTime {
            Section {
                FinalDateDisplay(
                    selectedStart: selectedStart,
                    selectedEnd: selectedEnd,
                    isAllDay: timeOptions.first(where: { $0.isAllDay }) != nil,
                    pollTitle: poll.title,
                    pollDescription: poll.description,
                    pollLocation: poll.location
                )
            }
        } else if isCreator && poll.status == .closed {
            Section {
                FinalDateSelectionView(
                    sortedTimeOptions: sortedTimeOptions,
                    isSelectingFinalDate: isSelectingFinalDate,
                    responsesForOption: responsesForOption,
                    onSelectOption: { option in
                        finalTimeOption = option
                        showSelectFinalDateAlert = true
                    }
                )
            }
        }
    }

    private func timeOptionsSection(_ poll: Poll) -> some View {
        Section("Time Options") {
            ForEach(timeOptions) { option in
                Button {
                    selectedTimeOption = option
                } label: {
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
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func commentSection(_ poll: Poll) -> some View {
        if myParticipant != nil && poll.status == .active {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Add a comment (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(localComment.count)/\(MAX_COMMENT_LENGTH)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "e.g., I'm flexible on timing, or I can only attend virtually...",
                        text: Binding(
                            get: { localComment },
                            set: { newValue in
                                if newValue.count <= MAX_COMMENT_LENGTH {
                                    localComment = newValue
                                    commentError = ""
                                } else {
                                    commentError = "Comment must be \(MAX_COMMENT_LENGTH) characters or less"
                                }
                            }
                        ),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    if !commentError.isEmpty {
                        Text(commentError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func saveButtonSection(_ poll: Poll) -> some View {
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
    }

    @ViewBuilder
    private func joinButtonSection(_ poll: Poll) -> some View {
        if myParticipant == nil && poll.status == .active {
            Section {
                Button("Join This Poll") {
                    joinPoll()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var participantsSection: some View {
        Section("Participants (\(participants.count))") {
            if participants.isEmpty {
                Text("No participants yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(participants) { participant in
                    ParticipantRow(
                        participant: participant,
                        isCurrentUser: participant.userId == authService.currentUserId
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func closePollButtonSection(_ poll: Poll) -> some View {
        if isCreator && poll.status == .active {
            Section {
                Button(action: { showClosePollAlert = true }) {
                    HStack {
                        Spacer()
                        Text("Close Poll")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func responsesForOption(_ optionId: UUID) -> ResponseSummary {
        let optionResponses = responses.filter { $0.timeOptionId == optionId }
        return ResponseSummary(
            available: optionResponses.filter { $0.status == .available }.count,
            maybe: optionResponses.filter { $0.status == .maybe }.count,
            unavailable: optionResponses.filter { $0.status == .unavailable }.count
        )
    }

    // MARK: - Data Loading

    private func loadPollData() async {
        isLoading = true

        poll = await pollService.loadPoll(id: pollId)

        if poll != nil {
            timeOptions = await pollService.loadTimeOptions(pollId: pollId)
            participants = await pollService.loadParticipants(pollId: pollId)

            if let userId = authService.currentUserId {
                myParticipant = participants.first { $0.userId == userId }
            }

            let participantIds = participants.map { $0.id }
            responses = await pollService.loadResponses(participantIds: participantIds)

            if let myParticipant = myParticipant {
                let myResponses = responses.filter { $0.participantId == myParticipant.id }
                for response in myResponses {
                    localResponses[response.timeOptionId] = response.status
                }
                localComment = myParticipant.comment ?? ""
            }

            if calendarService.isEnabled && !timeOptions.isEmpty {
                calendarConflicts = await calendarService.checkConflicts(for: timeOptions)

                for conflictId in calendarConflicts {
                    if localResponses[conflictId] == nil {
                        localResponses[conflictId] = .unavailable
                    }
                }
            }
        }

        isLoading = false
    }

    // MARK: - Actions

    private func updateStatus(_ status: PollStatus) {
        Task {
            do {
                try await pollService.updatePollStatus(pollId: pollId, status: status)
                poll?.status = status
            } catch {
                print("Failed to update status: \(error)")
            }
        }
    }

    private func joinPoll() {
        Task {
            do {
                myParticipant = try await pollService.joinPoll(pollId: pollId, anonymousName: nil)
                participants.append(myParticipant!)
            } catch {
                print("Failed to join poll: \(error)")
            }
        }
    }

    private func validateComment() -> Bool {
        if localComment.count > MAX_COMMENT_LENGTH {
            commentError = "Comment must be \(MAX_COMMENT_LENGTH) characters or less"
            return false
        }
        commentError = ""
        return true
    }

    private func saveResponses() {
        guard let myParticipant = myParticipant else { return }

        // Validate comment
        guard validateComment() else { return }

        isSaving = true

        Task {
            for (optionId, status) in localResponses {
                do {
                    try await pollService.submitAvailability(
                        participantId: myParticipant.id,
                        timeOptionId: optionId,
                        status: status,
                        note: nil
                    )
                } catch {
                    print("Failed to save response: \(error)")
                }
            }

            // Save comment (trimmed, nil if empty)
            do {
                let trimmedComment = localComment.trimmingCharacters(in: .whitespacesAndNewlines)
                try await pollService.updateParticipantComment(
                    participantId: myParticipant.id,
                    comment: trimmedComment.isEmpty ? nil : trimmedComment
                )
            } catch {
                print("Failed to save comment: \(error)")
            }

            let participantIds = participants.map { $0.id }
            responses = await pollService.loadResponses(participantIds: participantIds)
            participants = await pollService.loadParticipants(pollId: pollId)

            isSaving = false
        }
    }

    private func selectFinalDate() {
        guard let option = finalTimeOption else { return }

        isSelectingFinalDate = true

        Task {
            do {
                try await pollService.setSelectedFinalDate(
                    pollId: pollId,
                    startTime: option.startTime,
                    endTime: option.endTime
                )
                poll = await pollService.loadPoll(id: pollId)
            } catch {
                print("Failed to set final date: \(error)")
            }
            isSelectingFinalDate = false
        }
    }

    private func sharePoll() {
        guard let poll = poll else { return }

        let pollURLString = "\(Config.webURL)/polls/\(poll.id)"
        let shareText = """
        Join my poll: \(poll.title)

        \(pollURLString)

        Share Code: \(poll.shareCode)
        """

        #if os(iOS)
        var activityItems: [Any] = [shareText]
        if let pollURL = URL(string: pollURLString) {
            activityItems.append(pollURL)
        }
        let activityViewController = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {

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

// MARK: - Supporting Types

struct ResponseSummary {
    let available: Int
    let maybe: Int
    let unavailable: Int
}

// MARK: - ParticipantRow

struct ParticipantRow: View {
    let participant: PollParticipant
    let isCurrentUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(participant.displayName)
                if isCurrentUser {
                    Text("You")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            if let comment = participant.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
}

// MARK: - FinalDateDisplay

struct FinalDateDisplay: View {
    let selectedStart: Date
    let selectedEnd: Date
    let isAllDay: Bool
    let pollTitle: String
    let pollDescription: String?
    let pollLocation: String?
    @Environment(\.calendarService) var calendarService

    @State private var showAddToCalendarAlert = false
    @State private var addingToCalendar = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Final Meeting Time Selected")
                    .font(.headline)

                Spacer()

                Button(action: { showAddToCalendarAlert = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.plus")
                        Text("Add to Calendar")
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.white)
                    Text(selectedStart, style: .date)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }

                if !isAllDay {
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
        .alert("Add to Calendar", isPresented: $showAddToCalendarAlert) {
            Button("Add Event", role: nil) {
                Task {
                    await addToCalendar()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add this meeting to your calendar?")
        }
        .alert("Success", isPresented: .init(get: { addingToCalendar }, set: { _ in })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Event added to your calendar successfully!")
        }
    }

    private func addToCalendar() async {
        let success = await calendarService.addEventToCalendar(
            title: pollTitle,
            startDate: selectedStart,
            endDate: selectedEnd,
            notes: pollDescription,
            location: pollLocation
        )

        if success {
            addingToCalendar = true
        }
    }
}

// MARK: - FinalDateSelectionView

struct FinalDateSelectionView: View {
    let sortedTimeOptions: [PollTimeOption]
    let isSelectingFinalDate: Bool
    let responsesForOption: (UUID) -> ResponseSummary
    let onSelectOption: (PollTimeOption) -> Void

    var body: some View {
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
                    onSelectOption(option)
                } label: {
                    FinalDateOptionRow(
                        option: option,
                        stats: responsesForOption(option.id)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSelectingFinalDate)
            }
        }
    }
}

// MARK: - FinalDateOptionRow

struct FinalDateOptionRow: View {
    let option: PollTimeOption
    let stats: ResponseSummary

    var body: some View {
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
}

// MARK: - TimeOptionRow

struct TimeOptionRow: View {
    let option: PollTimeOption
    let responses: ResponseSummary
    let myResponse: AvailabilityStatus?
    let hasCalendarConflict: Bool
    let canRespond: Bool
    let onResponseChange: (AvailabilityStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dateTimeHeader
            if canRespond {
                responseButtons
            }
        }
        .padding(.vertical, 4)
    }

    private var dateTimeHeader: some View {
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

            HStack(spacing: 8) {
                ResponseCount(count: responses.available, status: .available)
                ResponseCount(count: responses.maybe, status: .maybe)
                ResponseCount(count: responses.unavailable, status: .unavailable)
            }
        }
    }

    private var responseButtons: some View {
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

// MARK: - ResponseCount

struct ResponseCount: View {
    let count: Int
    let status: AvailabilityStatus

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

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .fontWeight(.medium)
            .frame(width: 24, height: 24)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Circle())
    }
}

// MARK: - ResponseButton

struct ResponseButton: View {
    let status: AvailabilityStatus
    let isSelected: Bool
    let action: () -> Void

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
}

#Preview("Loading") {
    NavigationStack {
        PollDetailView(pollId: UUID())
    }
    .environment(\.authService, MockAuthService.signedIn)
    .environment(\.pollService, MockPollService.empty)
    .environment(\.calendarService, MockCalendarService.disabled)
}

#Preview("With Data") {
    let mock = MockPollService.withSamplePolls
    return NavigationStack {
        PollDetailView(pollId: mock.myPolls.first?.id ?? UUID())
    }
    .environment(\.authService, MockAuthService.signedIn)
    .environment(\.pollService, mock)
    .environment(\.calendarService, MockCalendarService.disabled)
}
