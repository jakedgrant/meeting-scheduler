import SwiftUI
import Shared

struct PollListView: View {
    @Environment(\.authService) private var authService
    enum PollFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case myMeets = "My Meets"
        case active = "Active"
        case upcoming = "Upcoming"
        case past = "Past"

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All Meets"
            case .myMeets: "My Meets"
            case .active: "Active Meets"
            case .upcoming: "Upcoming Meets"
            case .past: "Past Meets"
            }
        }
    }

    @Environment(\.pollService) var pollService
    @Environment(\.appClock) private var clock
    @State var selectedFilter: PollFilter = .active
    @State var showCreatePoll = false
    @State var showJoinByCode = false
    @State var joinCode = ""
    @State private var invitationCode: String?
    @State private var joinGeneration: UInt64 = 0
    @State var joinError: String?
    @State var isJoining = false
    @State var navigateToPoll: UUID?
    /// A poll link to open. The list clears it once it starts opening the poll.
    @Binding var pendingPollLink: PollLink?

    var body: some View {
        NavigationStack {
            Group {
                if pollService.isLoading && pollService.createdPolls.isEmpty && pollService.joinedPolls.isEmpty {
                    ProgressView("Loading polls...")
                } else if pollService.myPolls.isEmpty && pollService.listLoadError == nil {
                    emptyState
                } else {
                    pollList
                }
            }
            .navigationTitle(selectedFilter.title)
            .toolbar {
                ToolbarItem(id: "filter") {
                    Menu {
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(PollFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        Label(selectedFilter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(id: "join") {
                    Button("Join Poll", systemImage: "arrow.down.circle") {
                        showJoinByCode = true
                    }
                }

                ToolbarItem(id: "new") {
                    Button("Create Poll", systemImage: "plus") {
                        handleCreatePoll()
                    }
                }
            }
            .sheet(isPresented: $showCreatePoll, onDismiss: openPendingPollLink) {
                CreatePollView { pollId in
                    navigateToPoll = pollId
                }
            }
            .sheet(isPresented: $showJoinByCode, onDismiss: {
                if !showJoinByCode { dismissJoinSheet() }
            }) {
                JoinByCodeSheet(
                    joinCode: $joinCode,
                    joinError: $joinError,
                    isJoining: $isJoining,
                    invitationCode: invitationCode,
                    onJoin: handleJoinByCode,
                    onDismiss: dismissJoinSheet
                )
            }
            .navigationDestination(item: $navigateToPoll) { pollId in
                PollDetailView(pollId: pollId)
            }
            .refreshable {
                await pollService.loadMyPolls()
            }
            .task {
                await pollService.loadMyPolls()
            }
            .onChange(of: pendingPollLink, initial: true) { openPendingPollLink() }
            .onChange(of: authService.sessionGeneration) { dismissJoinSheet() }
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

    private var filteredPolls: [Poll] {
        let now = clock.now
        let currentUserId = authService.currentUserId
        let allPolls = pollService.myPolls

        let filtered: [Poll]

        switch selectedFilter {
        case .all:
            filtered = allPolls

        case .myMeets:
            filtered = allPolls.filter { $0.creatorId == currentUserId }

        case .active:
            filtered = allPolls.filter { poll in
                poll.status == .active &&
                pollService.pollTimeRanges[poll.id].map { $0.latest >= now } ?? true
            }

        case .upcoming:
            filtered = allPolls.filter { poll in
                poll.status == .closed &&
                poll.selectedStartTime.map { $0 > now } ?? false
            }

        case .past:
            filtered = allPolls.filter { poll in
                if let range = pollService.pollTimeRanges[poll.id] {
                    return range.latest < now
                }
                return false
            }
        }

        let descending = selectedFilter == .all || selectedFilter == .myMeets || selectedFilter == .past
        return filtered.sorted { a, b in
            let dateA = pollService.pollTimeRanges[a.id]?.earliest ?? a.createdAt
            let dateB = pollService.pollTimeRanges[b.id]?.earliest ?? b.createdAt
            return descending ? dateA > dateB : dateA < dateB
        }
    }

    private var pollList: some View {
        List {
            if filteredPolls.isEmpty && !pollService.myPolls.isEmpty {
                ContentUnavailableView("No matches in loaded polls", systemImage: "calendar")
            }
            ForEach(filteredPolls) { poll in
                let isOwner = poll.creatorId == authService.currentUserId
                NavigationLink(destination: PollDetailView(pollId: poll.id)) {
                    PollRowView(
                        poll: poll,
                        participantCount: pollService.pollParticipantCounts[poll.id] ?? 0,
                        isOwner: isOwner,
                        timeRange: pollService.pollTimeRanges[poll.id]
                    )
                }
            }
            Section {
                if let total = pollService.listTotalCount {
                    Text("Loaded \(pollService.myPolls.count) of \(total) polls")
                        .foregroundStyle(.secondary)
                }
                if pollService.hasMorePolls {
                    Text("Filters apply to loaded polls.").font(.caption).foregroundStyle(.secondary)
                    Button("Load more") { Task { await pollService.loadMorePolls() } }
                        .disabled(pollService.isLoading || pollService.isLoadingMore)
                }
                if pollService.isLoadingMore { ProgressView() }
                if let error = pollService.listLoadError {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            await pollService.retryPollLoad()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func dismissJoinSheet() {
        joinGeneration &+= 1
        isJoining = false
        invitationCode = nil
        showJoinByCode = false
        joinCode = ""
        joinError = nil
    }

    private func handleJoinByCode() {
        joinError = nil
        let code = joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else {
            joinError = "Code must be 6 characters"
            return
        }
        guard !isJoining else { return }
        isJoining = true
        let generation = joinGeneration
        let openingInvitation = invitationCode != nil
        authService.performSessionTask(
            operation: { _ in
                let pollId: UUID
                if openingInvitation {
                    pollId = try await pollService.openPollInvitation(code: code, accountId: authService.currentUserId)
                } else {
                    pollId = try await pollService.joinPoll(code: code)
                }
                await pollService.loadMyPolls()
                return pollId
            },
            onSuccess: { pollId in
                dismissJoinSheet()
                navigateToPoll = pollId
            },
            onFailure: { error in
                joinError = switch error {
                case PollError.pollNotFound: "Poll not found. Please check the code."
                case let error as PollError: error.errorDescription
                default: "The poll could not be joined. Please try again."
                }
            },
            onCompletion: { isJoining = false },
            isCurrent: { generation == joinGeneration }
        )
    }

    private func openPendingPollLink() {
        guard !showCreatePoll, let link = pendingPollLink else { return }
        pendingPollLink = nil
        dismissJoinSheet()
        switch link.target {
        case .poll(let id):
            navigateToPoll = id
        case .invitation(let code):
            invitationCode = code
            joinCode = code
            showJoinByCode = true
        }
    }

    private func handleCreatePoll() {
        // The creation transaction authorizes quota and passes; a preflight can
        // become stale or prevent a retained operation from being replayed.
        showCreatePoll = true
    }

}

#Preview("With Pollss") {
    PollListView(pendingPollLink: .constant(nil))
        .previewServices(polls: MockPollService.withSamplePolls)
}

#Preview("Empty") {
    PollListView(pendingPollLink: .constant(nil))
        .previewServices(polls: MockPollService.empty)
}
