import SwiftUI
import Shared

struct TimeOptionResponsesView: View {
    let pollId: UUID
    let timeOption: PollTimeOption
    @Environment(\.pollService) var pollService

    @State var participants: [PollParticipant] = []
    @State var responses: [AvailabilityResponse] = []
    @State var isLoading = true

    private var groupedResponses: GroupedResponses {
        let optionResponses = responses.filter { $0.timeOptionId == timeOption.id }

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

        let sortedItems = items.sorted { $0.participantName < $1.participantName }

        return GroupedResponses(
            available: sortedItems.filter { $0.status == .available },
            maybe: sortedItems.filter { $0.status == .maybe },
            unavailable: sortedItems.filter { $0.status == .unavailable }
        )
    }

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

    // MARK: - Main Content

    private var responsesList: some View {
        List {
            timeOptionInfoSection
            responseSections
        }
    }

    // MARK: - Sections

    private var timeOptionInfoSection: some View {
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
    }

    @ViewBuilder
    private var responseSections: some View {
        let grouped = groupedResponses

        if responses.isEmpty {
            Section {
                Text("No responses yet for this time option")
                    .foregroundStyle(.secondary)
            }
        } else {
            availableSection(grouped.available)
            maybeSection(grouped.maybe)
            unavailableSection(grouped.unavailable)
        }
    }

    @ViewBuilder
    private func availableSection(_ items: [ResponseItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    ResponseRow(item: item)
                }
            } header: {
                HStack {
                    Image(systemName: "checkmark")
                    Text("Available (\(items.count))")
                }
                .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func maybeSection(_ items: [ResponseItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    ResponseRow(item: item)
                }
            } header: {
                HStack {
                    Image(systemName: "questionmark")
                    Text("Tentative (\(items.count))")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func unavailableSection(_ items: [ResponseItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    ResponseRow(item: item)
                }
            } header: {
                HStack {
                    Image(systemName: "xmark")
                    Text("Not Available (\(items.count))")
                }
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true

        participants = await pollService.loadParticipants(pollId: pollId)
        let participantIds = participants.map { $0.id }
        responses = await pollService.loadResponses(participantIds: participantIds)

        isLoading = false
    }
}

// MARK: - Supporting Types

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

// MARK: - ResponseRow

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
    .environment(\.pollService, MockPollService.withSamplePolls)
}
