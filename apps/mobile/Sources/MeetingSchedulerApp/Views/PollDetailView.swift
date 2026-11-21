import SwiftUI
import Shared

struct PollDetailView: View {
    let pollId: UUID
    @Environment(\.authService) private var authService
    @Environment(\.pollService) private var pollService
    @Environment(\.calendarService) private var calendarService
    @Environment(\.appClock) private var clock

    var body: some View {
        // The screen keeps the first model it receives, so a new poll gets a new screen.
        PollDetailScreen(
            model: PollDetailModel(
                pollId: pollId, auth: authService, polls: pollService, calendar: calendarService, clock: clock))
            .id(pollId)
    }
}

private struct PollDetailScreen: View {
    @State private var model: PollDetailModel
    @State private var showClosePollAlert = false
    @State private var showSelectFinalDateAlert = false
    @State private var finalTimeOption: PollTimeOption?
    @State private var selectedTimeOption: PollTimeOption?
    @State private var conflictOption: PollTimeOption?
    @State private var showParticipants = false
    @State private var showShareCode = false

    init(model: PollDetailModel) {
        _model = State(initialValue: model)
    }

    private var editor: AvailabilityEditor { model.editor }
    private var pollId: UUID { model.pollId }
    private var poll: Poll? { model.poll }

    private var formattedSelectedOption: String {
        guard let option = finalTimeOption else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"
        let dateStr = dateFormatter.string(from: option.displayDate(pollTimeZone: poll?.timezone))

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
            if model.showsLoading {
                ProgressView("Loading poll...")
            } else if let poll = poll {
                pollContent(poll)
            } else {
                ContentUnavailableView {
                    Label("Poll unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(model.loadError ?? String(localized: "This poll could not be found."))
                } actions: {
                    Button("Retry") { Task { await model.load() } }
                }
            }
        }
        // The system draws the large title and collapses it into the inline title as the list
        // scrolls under the bar.
        .navigationTitle(model.displaysCurrentAccount ? (poll?.title ?? "Poll") : "Poll")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        // The bottom toolbar holds this screen's actions, so the tab bar would stack under it.
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .toolbar { toolbarContent }
        .task(id: model.currentAccountId) {
            finalTimeOption = nil; selectedTimeOption = nil
            showClosePollAlert = false; showSelectFinalDateAlert = false
            showParticipants = false; showShareCode = false
            await model.load()
        }
        .onDisappear { model.suspend() }
        .alert("Close Poll", isPresented: $showClosePollAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Close Poll", role: .destructive) {
                model.close()
            }
        } message: {
            Text("Are you sure you want to close this poll? Once closed, participants will no longer be able to submit or modify their availability.")
        }
        .alert("Select Final Date", isPresented: $showSelectFinalDateAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm", role: .destructive) {
                if let finalTimeOption { model.finalize(with: finalTimeOption) }
            }
        } message: {
            Text("Set \(formattedSelectedOption) as the final meeting time? This closes responses for the poll.")
        }
        .sheet(item: $conflictOption) { option in
            CalendarConflictsView(
                option: option,
                pollTimeZone: poll?.timezone ?? "UTC",
                sources: model.calendarCheck.busySources[option.id] ?? [],
                loadConflicts: { await model.calendarConflicts(for: option) }
            )
        }
        .navigationDestination(item: $selectedTimeOption) { timeOption in
            TimeOptionResponsesView(pollId: pollId, timeOption: timeOption, pollTimeZone: poll?.timezone ?? "UTC")
        }
        .sheet(isPresented: $showParticipants) {
            // Built inside this body, so the sheet follows the model as participants join.
            ParticipantsSheet(participants: model.participants, isCurrentUser: model.isCurrentUser)
        }
        .sheet(isPresented: $showShareCode) {
            if let poll { ShareCodeSheet(shareCode: poll.shareCode) }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.displaysCurrentAccount, let poll {
            // The large title shows the pill under it; once the title collapses inline, the
            // subtitle placement shows it under the inline title instead.
            ToolbarItem(placement: .largeSubtitle) {
                StatusBadge(status: poll.status)
            }
            ToolbarItem(placement: .subtitle) {
                StatusBadge(status: poll.status)
            }

            if poll.status == .active {
                ToolbarItem(placement: .primaryAction) {
                    shareMenu(poll)
                }
            }

            ToolbarItem(placement: .bottomBar) {
                participantsButton
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            if model.myParticipant != nil {
                ToolbarItem(placement: .bottomBar) {
                    submitButton
                }
            } else if poll.status == .active {
                ToolbarItem(placement: .bottomBar) {
                    joinButton
                }
            }
        }
    }

    private func shareMenu(_ poll: Poll) -> some View {
        Menu {
            if let pollURL = URL(string: "\(Config.webURL)/polls/\(poll.id)") {
                // The URL is the only shared item, so AirDrop hands the receiver a link that
                // opens the poll. ShareLink presents from whichever window shows this button.
                ShareLink(item: pollURL, subject: Text(poll.title)) {
                    Label("Share Link", systemImage: "link")
                }
            }
            Button("Show Share Code", systemImage: "number") {
                showShareCode = true
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private var participantsButton: some View {
        let count = model.participants.count
        return Button {
            showParticipants = true
        } label: {
            HStack(spacing: 4) {
                Text(count, format: .number)
                    .monospacedDigit()
                Image(systemName: "person.fill")
            }
        }
        .accessibilityLabel(Text("Participants"))
        .accessibilityValue(Text("\(count)"))
    }

    private var joinButton: some View {
        Button {
            model.join()
        } label: {
            if model.isChangingPoll {
                ProgressView()
            } else {
                Label("Join Poll", systemImage: "person.badge.plus")
            }
        }
        .accessibilityLabel(Text("Join Poll"))
        .disabled(!model.canMutatePoll)
    }

    private var submitButton: some View {
        let title: LocalizedStringKey = editor.errorMessage == nil ? "Submit Response" : "Retry Submit"
        return Button {
            model.save()
        } label: {
            if editor.isSaving {
                ProgressView()
            } else {
                Label(title, systemImage: "arrow.up")
            }
        }
        .accessibilityLabel(Text(title))
        // Prominent, so the bar draws it in the accent tint.
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSave)
    }

    // MARK: - Main Content

    @ViewBuilder
    private func pollContent(_ poll: Poll) -> some View {
        List {
            descriptionRow(poll)
            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.calendarError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            calendarCoverageSection
            responseFeedbackSection
            pollInfoSection(poll)
            finalDateSection(poll)
            timeOptionsSection(poll)
            commentSection
            closedNoticeSection
            closePollButtonSection(poll)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.load(forceRefresh: true) }
    }

    // MARK: - Sections

    /// Plain text under the large title: no row background, and no inset beyond the list's
    /// margin, so it lines up with the title.
    @ViewBuilder
    private func descriptionRow(_ poll: Poll) -> some View {
        if let description = poll.description, !description.isEmpty {
            // Its own section, so the rows after it keep their own rounded group.
            Section {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func pollInfoSection(_ poll: Poll) -> some View {
        Section {
            if let location = poll.location {
                Label(location, systemImage: "mappin")
                    .font(.subheadline)
            }
            if let closesAt = poll.closesAt {
                let isPastDue = model.deadlineStatus == .pastDue
                let isClosingSoon = model.deadlineStatus == .closingSoon

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
    private func finalDateSection(_ poll: Poll) -> some View {
        if let event = model.finalEvent {
            Section {
                FinalDateDisplay(
                    event: event,
                    addState: model.calendarAdd,
                    onAdd: { model.addFinalTimeToCalendar() },
                    onAcknowledgeAdd: model.acknowledgeCalendarAdd
                )
            }
        } else if model.isCreator && poll.status == .closed {
            Section {
                FinalDateSelectionView(
                    sortedTimeOptions: model.rankedTimeOptions,
                    pollTimeZone: poll.timezone,
                    isSelectingFinalDate: model.isSelectingFinalDate || !model.canMutatePoll,
                    responsesForOption: model.responseSummary(for:),
                    onSelectOption: { option in
                        finalTimeOption = option
                        showSelectFinalDateAlert = true
                    }
                )
            }
        }
    }

    /// Names failed sources with a retry, otherwise what the last check read (F16).
    @ViewBuilder
    private var calendarCoverageSection: some View {
        if !model.calendarCheck.failedSources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(sourceNames(model.calendarCheck.failedSources)) couldn't be checked. Options marked \"Couldn't check\" may still conflict.")
                    .font(.caption)
                Button("Retry calendar check") {
                    Task { await model.retryCalendarCheck() }
                }
                .font(.caption)
                .disabled(model.isCheckingCalendar)
            }
        } else if !model.calendarCheck.checkedSources.isEmpty {
            Text("Checked \(sourceNames(model.calendarCheck.checkedSources)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceNames(_ sources: [CalendarSource]) -> String {
        sources.map { source in
            switch source {
            case .appleCalendar: String(localized: "Apple Calendar")
            case .googleCalendar: String(localized: "Google Calendar (primary calendar)")
            }
        }.formatted(.list(type: .and))
    }

    private func timeOptionsSection(_ poll: Poll) -> some View {
        Section("Time Options") {
            ForEach(model.timeOptions) { option in
                Button {
                    selectedTimeOption = option
                } label: {
                    TimeOptionRow(
                        option: option,
                        pollTimeZone: poll.timezone,
                        responses: model.responseSummary(for: option.id),
                        myResponse: editor.responses[option.id],
                        hasCalendarConflict: model.calendarCheck.busyIds.contains(option.id),
                        calendarUnchecked: model.calendarCheck.uncheckedIds.contains(option.id),
                        onShowConflicts: { conflictOption = option },
                        canRespond: model.canEditAvailability,
                        onResponseChange: { status in
                            model.setResponse(status, for: option.id)
                        }
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var commentSection: some View {
        if model.myParticipant != nil {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Add a comment (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(editor.comment.count)/\(PollDetailModel.maxCommentLength)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField(
                        "e.g., I'm flexible on timing, or I can only attend virtually...",
                        text: Binding(get: { editor.comment }, set: { model.updateComment($0) }),
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .disabled(!model.canEditAvailability)
                    if let commentError = model.commentError {
                        Text(commentError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// The submit button lives in the toolbar; this explains why it stays disabled.
    @ViewBuilder
    private var closedNoticeSection: some View {
        if model.myParticipant != nil && !model.acceptsResponses {
            Section {
                Text("This poll is closed. Your draft is retained.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var responseFeedbackSection: some View {
        if let actionError = model.actionError {
            Section { Text(actionError).foregroundStyle(.red).accessibilityIdentifier("poll-action-error") }
        }
        if let message = editor.errorMessage {
            Section {
                Text(message).foregroundStyle(.red).accessibilityIdentifier("availability-save-error")
                if model.myParticipant != nil, editor.saved == nil || editor.needsConflictReview {
                    Button(editor.needsConflictReview ? "Load Latest Saved Responses" : "Retry Loading Responses") {
                        model.reloadSavedResponses()
                    }
                    .disabled(editor.isLoading || editor.isSaving)
                }
            }
        }
        if editor.didSave && editor.isSaved {
            Section { Label("Responses saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
        }
    }

    @ViewBuilder
    private func closePollButtonSection(_ poll: Poll) -> some View {
        if model.isCreator && poll.status == .active {
            Section {
                Button(action: { showClosePollAlert = true }) {
                    HStack {
                        Spacer()
                        Text("Close Poll")
                            .foregroundStyle(.red)
                        Spacer()
                    }
                }
                .disabled(!model.canMutatePoll)
            }
        }
    }
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
    let event: DeviceCalendarEvent
    let addState: CalendarAddState
    let onAdd: () -> Void
    let onAcknowledgeAdd: () -> Void

    @State private var showAddToCalendarAlert = false

    private var addResult: DeviceCalendarAddResult? {
        if case .finished(let result) = addState { result } else { nil }
    }

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
                .disabled(addState == .adding)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.white)
                    Text(event.allDayDate?.pickerDate() ?? event.start, style: .date)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }

                if event.allDayDate == nil {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.white)
                        Text("\(event.start, style: .time) - \(event.end, style: .time)")
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
            Button("Add Event", role: nil, action: onAdd)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add this meeting to your calendar?")
        }
        .alert(
            addResultText.title,
            isPresented: .init(get: { addResult != nil }, set: { if !$0 { onAcknowledgeAdd() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addResultText.message)
        }
    }

    private var addResultText: (title: LocalizedStringKey, message: LocalizedStringKey) {
        switch addResult {
        case .added, nil: ("Success", "Event added to your calendar successfully!")
        case .accessDenied: ("Calendar Access Needed", "Allow calendar access for Meetful in Settings, then try again.")
        case .failed: ("Event Not Added", "The event couldn't be saved to your calendar. Try again.")
        }
    }
}

// MARK: - FinalDateSelectionView

struct FinalDateSelectionView: View {
    let sortedTimeOptions: [PollTimeOption]
    let pollTimeZone: String
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
                        pollTimeZone: pollTimeZone,
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
    let pollTimeZone: String
    let stats: ResponseSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.displayDate(pollTimeZone: pollTimeZone), style: .date)
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
    let pollTimeZone: String
    let responses: ResponseSummary
    let myResponse: AvailabilityStatus?
    let hasCalendarConflict: Bool
    let calendarUnchecked: Bool
    let onShowConflicts: () -> Void
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
                    Text(option.displayDate(pollTimeZone: pollTimeZone), style: .date)
                        .font(.headline)

                    if hasCalendarConflict {
                        Button(action: onShowConflicts) {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.exclamationmark")
                                Text("Busy")
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows what conflicts with this time")
                    } else if calendarUnchecked {
                        Label("Couldn't check", systemImage: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
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
    .previewServices(auth: MockAuthService.signedIn, polls: MockPollService.empty, calendar: MockCalendarService.disabled)
}

#Preview("With Data") {
    let mock = MockPollService.withSamplePolls
    return NavigationStack {
        PollDetailView(pollId: mock.myPolls.first?.id ?? UUID())
    }
    .previewServices(auth: MockAuthService.signedIn, polls: mock, calendar: MockCalendarService.disabled)
}
