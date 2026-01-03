import SwiftUI
import Shared

struct TimeOptionResponsesView: View {
    let pollId: UUID
    let timeOption: PollTimeOption

    @State var participants: [PollParticipant] = []
    @State var responses: [AvailabilityResponse] = []
    @State var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading responses...")
            } else {
                responsesList
            }
        }
        .navigationTitle("Responses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadData()
        }
    }

    @ViewBuilder
    private var responsesList: some View {
        List {
            // Time option info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(timeOption.startTime, style: .date)
                        .font(.headline)
                    if timeOption.isAllDay {
                        Text("All day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(timeOption.startTime, style: .time) - \(timeOption.endTime, style: .time)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            let grouped = groupedResponses

            if responses.isEmpty {
                Section {
                    Text("No responses yet for this time option")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Available
                if !grouped.available.isEmpty {
                    Section {
                        ForEach(grouped.available) { item in
                            ResponseRow(item: item)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Available (\(grouped.available.count))")
                        }
                        .foregroundStyle(.green)
                    }
                }

                // Tentative (Maybe)
                if !grouped.maybe.isEmpty {
                    Section {
                        ForEach(grouped.maybe) { item in
                            ResponseRow(item: item)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "questionmark")
                            Text("Tentative (\(grouped.maybe.count))")
                        }
                        .foregroundStyle(.orange)
                    }
                }

                // Not Available
                if !grouped.unavailable.isEmpty {
                    Section {
                        ForEach(grouped.unavailable) { item in
                            ResponseRow(item: item)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "xmark")
                            Text("Not Available (\(grouped.unavailable.count))")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var groupedResponses: GroupedResponses {
        // Get responses for this time option
        let optionResponses = responses.filter { $0.timeOptionId == timeOption.id }

        // Map to response items with participant info
        let items = optionResponses.compactMap { response -> ResponseItem? in
            guard let participant = participants.first(where: { $0.id == response.participantId }) else {
                return nil
            }
            return ResponseItem(
                id: response.id,
                participantName: participant.displayName,
                status: response.status,
                note: response.note
            )
        }

        // Sort alphabetically within each group
        let sortedItems = items.sorted { $0.participantName < $1.participantName }

        // Group by status
        return GroupedResponses(
            available: sortedItems.filter { $0.status == .available },
            maybe: sortedItems.filter { $0.status == .maybe },
            unavailable: sortedItems.filter { $0.status == .unavailable }
        )
    }

    private func loadData() async {
        isLoading = true

        // Load participants
        participants = await PollService.shared.loadParticipants(pollId: pollId)

        // Load all responses for these participants
        let participantIds = participants.map { $0.id }
        responses = await PollService.shared.loadResponses(participantIds: participantIds)

        isLoading = false
    }
}

struct ResponseItem: Identifiable {
    let id: UUID
    let participantName: String
    let status: AvailabilityStatus
    let note: String?
}

struct GroupedResponses {
    let available: [ResponseItem]
    let maybe: [ResponseItem]
    let unavailable: [ResponseItem]
}

struct ResponseRow: View {
    let item: ResponseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.participantName)
                .font(.body)
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
}

#Preview {
    NavigationStack {
        TimeOptionResponsesView(
            pollId: UUID(),
            timeOption: PollTimeOption(
                id: UUID(),
                pollId: UUID(),
                startTime: Date(),
                endTime: Date().addingTimeInterval(3600),
                isAllDay: false,
                createdAt: Date()
            )
        )
    }
}
