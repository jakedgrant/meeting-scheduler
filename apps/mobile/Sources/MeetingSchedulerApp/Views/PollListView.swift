import SwiftUI
import Shared

struct PollListView: View {
    @State var pollService = PollService.shared
    @State var showCreatePoll = false
    @State var showPaywall = false
    @State var showJoinByCode = false
    @State var joinCode = ""
    @State var joinError: String?
    @State var isJoining = false
    @State var navigateToPoll: UUID?
    @State var participantCounts: [UUID: Int] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if pollService.isLoading && pollService.createdPolls.isEmpty && pollService.joinedPolls.isEmpty {
                    ProgressView("Loading polls...")
                } else if pollService.createdPolls.isEmpty && pollService.joinedPolls.isEmpty {
                    emptyState
                } else {
                    pollList
                }
            }
            .navigationTitle("My Polls")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Join Poll", systemImage: "arrow.down.circle") {
                        showJoinByCode = true
                    }

                    Button("Create Poll", systemImage: "plus") {
                        handleCreatePoll()
                    }
                }
            }
            .sheet(isPresented: $showCreatePoll) {
                CreatePollView()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showJoinByCode) {
                JoinByCodeSheet(
                    joinCode: $joinCode,
                    joinError: $joinError,
                    isJoining: $isJoining,
                    onJoin: handleJoinByCode,
                    onDismiss: dismissJoinSheet
                )
            }
            .navigationDestination(item: $navigateToPoll) { pollId in
                PollDetailView(pollId: pollId)
            }
            .refreshable {
                await pollService.loadMyPolls()
                await loadAllParticipantCounts()
            }
            .task {
                await pollService.loadMyPolls()
                await loadAllParticipantCounts()
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Polls Yet", systemImage: "calendar")
        } description: {
            Text("Create your first poll to start scheduling meetings.")
        } actions: {
            Button("Create Poll") {
                handleCreatePoll()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var pollList: some View {
        List {
            if !pollService.createdPolls.isEmpty {
                Section("My Polls") {
                    ForEach(pollService.createdPolls) { poll in
                        NavigationLink(destination: PollDetailView(pollId: poll.id)) {
                            PollRowView(poll: poll, participantCount: participantCounts[poll.id] ?? 0, isOwner: true)
                        }
                    }
                }
            }

            if !pollService.joinedPolls.isEmpty {
                Section("Polls I Joined") {
                    ForEach(pollService.joinedPolls) { poll in
                        NavigationLink(destination: PollDetailView(pollId: poll.id)) {
                            PollRowView(poll: poll, participantCount: participantCounts[poll.id] ?? 0, isOwner: false)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func dismissJoinSheet() {
        showJoinByCode = false
        joinCode = ""
        joinError = nil
    }

    private func handleJoinByCode() {
        Task {
            isJoining = true
            joinError = nil

            let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            guard code.count == 6 else {
                joinError = "Code must be 6 characters"
                isJoining = false
                return
            }

            guard let poll = await pollService.loadPollByCode(code) else {
                joinError = "Poll not found. Please check the code."
                isJoining = false
                return
            }

            if poll.status == .closed || poll.status == .archived {
                joinError = "This poll is closed and cannot accept new participants."
                isJoining = false
                return
            }

            showJoinByCode = false
            joinCode = ""
            joinError = nil
            isJoining = false
            navigateToPoll = poll.id
        }
    }

    private func handleCreatePoll() {
        Task {
            let canCreate = await pollService.canCreatePoll()
            if canCreate {
                showCreatePoll = true
            } else {
                showPaywall = true
            }
        }
    }

    private func loadAllParticipantCounts() async {
        let allPolls = pollService.myPolls
        var newCounts: [UUID: Int] = [:]

        for poll in allPolls {
            do {
                let participants = await pollService.loadParticipants(pollId: poll.id)
                newCounts[poll.id] = participants.count
            } catch {
                print("Failed to load participants for poll \(poll.id): \(error)")
                newCounts[poll.id] = participantCounts[poll.id] ?? 0
            }
        }

        participantCounts = newCounts
    }
}

// MARK: - JoinByCodeSheet

struct JoinByCodeSheet: View {
    @Binding var joinCode: String
    @Binding var joinError: String?
    @Binding var isJoining: Bool
    let onJoin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABC123", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Share Code")
                } footer: {
                    Text("Enter the 6-character code shared by the poll creator")
                }

                if let error = joinError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: onJoin) {
                        if isJoining {
                            ProgressView()
                        } else {
                            Text("Join Poll")
                        }
                    }
                    .disabled(isJoining || joinCode.count != 6)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Join by Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - PollRowView

struct PollRowView: View {
    let poll: Poll
    let participantCount: Int
    var isOwner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Text(poll.title)
                        .font(.headline)

                    if isOwner {
                        OwnerBadge()
                    }
                }

                Spacer()

                StatusBadge(status: poll.status)
            }

            if let description = poll.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(poll.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Text("^[\(participantCount) participant](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: PollStatus

    private var backgroundColor: Color {
        switch status {
        case .draft: return Color.gray.opacity(0.2)
        case .active: return Color.green.opacity(0.2)
        case .closed: return Color.orange.opacity(0.2)
        case .archived: return Color.gray.opacity(0.3)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .draft: return .secondary
        case .active: return .green
        case .closed: return .orange
        case .archived: return .secondary
        }
    }

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
    }
}

// MARK: - OwnerBadge

struct OwnerBadge: View {
    var body: some View {
        Text("Owner")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(Capsule())
    }
}

#Preview {
    PollListView()
}
