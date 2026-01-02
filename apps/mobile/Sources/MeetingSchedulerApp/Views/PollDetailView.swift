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
    @State var isLoading = true
    @State var isSaving = false

    private var isCreator: Bool {
        poll?.creatorId == AuthService.shared.currentUser?.id
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if poll.status == .draft {
                            Button("Publish Poll") {
                                updateStatus(.active)
                            }
                        } else if poll.status == .active {
                            Button("Close Poll") {
                                updateStatus(.closed)
                            }
                        }

                        Button("Share", systemImage: "square.and.arrow.up") {
                            sharePoll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await loadPollData()
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
            if poll.status == .active || (poll.status == .draft && isCreator) {
                Section {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Share Code")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = poll.shareCode
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

            // Time Options
            Section("Time Options") {
                ForEach(timeOptions) { option in
                    TimeOptionRow(
                        option: option,
                        responses: responsesForOption(option.id),
                        myResponse: localResponses[option.id],
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
    let canRespond: Bool
    let onResponseChange: (AvailabilityStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date & Time
            HStack {
                VStack(alignment: .leading) {
                    Text(option.startTime, style: .date)
                        .font(.headline)
                    Text("\(option.startTime, style: .time) - \(option.endTime, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
