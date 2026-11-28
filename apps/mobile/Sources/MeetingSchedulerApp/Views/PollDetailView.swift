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
    @State private var showEditPoll = false

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
            } else if model.requiresMembership {
                ContentUnavailableView {
                    Label("Join poll", systemImage: "person.badge.plus")
                } description: {
                    Text(model.actionError ?? String(localized: "Join this poll to view it and submit your availability."))
                } actions: {
                    joinButton
                }
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
            showParticipants = false; showShareCode = false; showEditPoll = false
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
        .sheet(isPresented: $showEditPoll) {
            if let poll, model.isCreator, model.displaysCurrentAccount {
                EditPollView(poll: poll, model: model)
            }
        }
        .sheet(isPresented: $showShareCode) {
            if let poll {
                let pollURL = PollLink.shareURL(code: poll.shareCode)
                ShareCodeSheet(shareCode: poll.shareCode, pollURL: pollURL)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.displaysCurrentAccount, let poll {
            // Shows the pill under the inline title once the large title collapses; the list header
            // shows it under the large title. Not `.largeSubtitle`: a custom view there makes the
            // screen open with the title already collapsed.
            ToolbarItem(placement: .subtitle) {
                StatusBadge(status: poll.status)
            }

            if poll.status == .active {
                ToolbarItem(placement: .topBarTrailing) {
                    shareMenu(poll)
                }
            }

            if model.isCreator {
                if poll.status == .active {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit Poll", systemImage: "pencil") {
                        model.clearEditError()
                        showEditPoll = true
                    }
                    .disabled(!model.canMutatePoll)
                }
            }

            // `axisBehavior` exists only in the iOS 27.1 SDK. `#available` gates it at run time, but an
            // older SDK, such as CI's Xcode 26.6, can't compile the call at all. Swift 6.4 ships with
            // Xcode 27, so the compiler check keeps the call out of older builds.
            #if compiler(>=6.4)
            if #available(iOS 27.1, *) {
                // Moves into the vertical bar on devices that have one, such as iPhone Duo, beside
                // the other bar buttons; elsewhere it stays at the leading end of the bottom bar.
                ToolbarItem(placement: .bottomBar) {
                    participantsButton
                }
                .axisBehavior(.verticalPreferred)
            } else {
                ToolbarItem(placement: .bottomBar) {
                    participantsButton
                }
            }
            #else
            ToolbarItem(placement: .bottomBar) {
                participantsButton
            }
            #endif

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
            let pollURL = PollLink.shareURL(code: poll.shareCode)
            ShareLink(item: pollURL, subject: Text(poll.title)) {
                Label("Share Link", systemImage: "link")
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
            // A plain Label with the count as a badge, not a custom HStack: the bar redraws a
            // standard item when the window resizes, while the HStack came back blank after
            // iPhone Duo folded or unfolded.
            Label("Participants", systemImage: "person.2.fill")
        }
        .badge(count)
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
            pollHeader(poll)
            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.calendarError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
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

    /// The status pill and description under the large title, with no inset beyond the list's
    /// margin so both line up with the title. A section header rather than a row: a row clips its
    /// content to its rounded shape even with a clear background, cutting off the corners.
    private func pollHeader(_ poll: Poll) -> some View {
        Section {
        } header: {
            VStack(alignment: .leading, spacing: 12) {
                StatusBadge(status: poll.status)
                if let description = poll.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        // A fixed color: the hierarchical `.secondary` would resolve against the
                        // header's own secondary style and come out a step lighter.
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
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
        Section {
            ForEach(model.timeOptions) { option in
                TimeOptionRow(
                    option: option,
                    pollTimeZone: poll.timezone,
                    now: model.now,
                    calendarStatus: calendarStatus(of: option),
                    responses: model.responseSummary(for: option.id),
                    // No poll setting hides the tally yet, so every viewer sees it as before.
                    showsResponseTallies: true,
                    response: editor.responses[option.id],
                    onRespond: model.canEditAvailability ? { model.setResponse($0, for: option.id) } : nil,
                    onShowResponses: { selectedTimeOption = option },
                    onShowConflicts: { conflictOption = option }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
            }
        } header: {
            Text("Time options")
        } footer: {
            calendarCoverageSection
        }
    }

    private func calendarStatus(of option: PollTimeOption) -> TimeOptionRow.CalendarStatus {
        if model.calendarCheck.busyIds.contains(option.id) { return .busy(model.conflictEvents[option.id] ?? []) }
        if model.calendarCheck.uncheckedIds.contains(option.id) { return .unchecked }
        return .free
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
            Group {
                if let submittedAt = participant.submittedAt {
                    Text("Submitted \(submittedAt.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Not submitted")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
