import Foundation

/// Wire payloads remain raw until the service validates counts, identity and page progress.
enum PollReadError: Error { case incomplete }

struct PollSummaryRow: Decodable, Sendable {
    let poll: Poll
    let role: String
    let participantCount: Int
    let timeOptionCount: Int
    let earliestStart: Date?
    let latestStart: Date?

    var hasValidRange: Bool {
        if timeOptionCount == 0 { return earliestStart == nil && latestStart == nil }
        guard let earliestStart, let latestStart else { return false }
        return earliestStart <= latestStart
    }

    enum CodingKeys: String, CodingKey {
        case poll, role
        case participantCount = "participant_count"
        case timeOptionCount = "time_option_count"
        case earliestStart = "earliest_start"
        case latestStart = "latest_start"
    }
}

struct PollSummaryPage: Decodable, Sendable {
    let items: [PollSummaryRow]
    let hasMore: Bool
    let nextCursor: String?
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case totalCount = "total_count"
    }

    func validate(accountId: UUID, isFirstPage: Bool, previousCursors: Set<String>) throws {
        try validatePageProgress(hasMore: hasMore, nextCursor: nextCursor, count: items.count,
                                 limit: 50, previousCursors: previousCursors)
        guard !isFirstPage || hasMore == (totalCount > items.count) else { throw PollReadError.incomplete }
        guard totalCount >= items.count, Set(items.map { $0.poll.id }).count == items.count,
            items.allSatisfy({ item in
                item.role == (item.poll.creatorId == accountId ? "owner" : "member")
                    && item.participantCount >= 0 && item.timeOptionCount >= 0
                    && item.hasValidRange
            }) else { throw PollReadError.incomplete }
    }

    static func fixture(created: [Poll], joined: [Poll]) -> Self {
        Self(items: created.map { PollSummaryRow(poll: $0, role: "owner", participantCount: 0,
                                                timeOptionCount: 0, earliestStart: nil, latestStart: nil) }
            + joined.map { PollSummaryRow(poll: $0, role: "member", participantCount: 0,
                                          timeOptionCount: 0, earliestStart: nil, latestStart: nil) },
             hasMore: false, nextCursor: nil, totalCount: created.count + joined.count)
    }
}

struct PollDetailPage: Decodable, Sendable {
    let poll: Poll
    let timeOptions: [PollTimeOption]
    let participants: [PollParticipant]
    let timeOptionCount: Int
    let participantCount: Int

    enum CodingKeys: String, CodingKey {
        case poll, participants
        case timeOptions = "time_options"
        case timeOptionCount = "time_option_count"
        case participantCount = "participant_count"
    }

    func validate(pollId: UUID) throws {
        guard poll.id == pollId, timeOptions.count == timeOptionCount, participants.count == participantCount,
            timeOptionCount <= 500, participantCount <= 500,
            Set(timeOptions.map(\.id)).count == timeOptionCount,
            Set(participants.map(\.id)).count == participantCount,
            timeOptions.allSatisfy({ $0.pollId == pollId }), participants.allSatisfy({ $0.pollId == pollId })
        else { throw PollReadError.incomplete }
    }

    func validate(responses: [AvailabilityResponse]) throws {
        let participantIds = Set(participants.map(\.id))
        let optionIds = Set(timeOptions.map(\.id))
        var pairs: Set<ResponseKey> = []
        var ids: Set<UUID> = []
        for row in responses {
            guard participantIds.contains(row.participantId), optionIds.contains(row.timeOptionId),
                ids.insert(row.id).inserted,
                pairs.insert(ResponseKey(participant: row.participantId, option: row.timeOptionId)).inserted
            else { throw PollReadError.incomplete }
        }
    }
}

private struct ResponseKey: Hashable {
    let participant: UUID
    let option: UUID
}

struct PollResponsePage: Decodable, Sendable {
    let items: [AvailabilityResponse]
    let hasMore: Bool
    let nextCursor: String?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case totalCount = "total_count"
    }

    func validate(previousCursors: Set<String>) throws {
        try validatePageProgress(hasMore: hasMore, nextCursor: nextCursor, count: items.count,
                                 limit: 500, previousCursors: previousCursors)
    }
}

private func validatePageProgress(
    hasMore: Bool, nextCursor: String?, count: Int, limit: Int, previousCursors: Set<String>
) throws {
    guard hasMore == (nextCursor != nil), count <= limit else { throw PollReadError.incomplete }
    if let cursor = nextCursor {
        guard !cursor.isEmpty, count > 0, !previousCursors.contains(cursor) else { throw PollReadError.incomplete }
    }
}
