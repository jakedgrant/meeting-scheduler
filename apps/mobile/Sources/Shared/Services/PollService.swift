import Foundation
import Supabase

@MainActor
@Observable
public final class PollService: PollServiceProtocol {
    public static let shared = PollService()

    public private(set) var myPolls: [Poll] = []
    public private(set) var createdPolls: [Poll] = []
    public private(set) var joinedPolls: [Poll] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var listLoadError: String?
    public private(set) var listTotalCount: Int?
    public var hasMorePolls: Bool { nextListCursor != nil }
    private var nextListCursor: String?
    private var listCursors: Set<String> = []
    private var retryLoadsMore = false
    public private(set) var pollDetailErrors: [UUID: String] = [:]

    /// Participant counts keyed by poll ID — returned by the bounded summary RPC.
    public private(set) var pollParticipantCounts: [UUID: Int] = [:]

    /// Time ranges keyed by poll ID — returned by the bounded summary RPC.
    public private(set) var pollTimeRanges: [UUID: (earliest: Date, latest: Date)] = [:]

    var supabase: SupabaseClient { injectedClient ?? SupabaseService.shared.client }
    private let injectedClient: SupabaseClient?
    let requestCredentials: @MainActor () -> AccountRequestCredentials?
    private let currentUserId: @MainActor () -> UUID?
    private let listLoader: (@MainActor () async throws -> (created: [Poll], joined: [Poll]))?
    private let detailLoader: (@MainActor (UUID) async throws -> PollDetail)?
    private let statusUpdater: (@MainActor (UUID, PollStatus) async throws -> Void)?
    private var accountId: UUID?
    private var accountGeneration: UInt64 = 0
    private var listGeneration: UInt64 = 0
    private var detailGenerations: [UUID: UInt64] = [:]
    private let persistence: any PersistenceProviderProtocol
    private let timeRangeFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    private init() {
        self.injectedClient = nil
        self.requestCredentials = { SupabaseService.shared.requestCredentials }
        self.persistence = AccountPersistence.shared
        self.currentUserId = { AuthService.shared.currentUserId }
        self.listLoader = nil
        self.detailLoader = nil
        self.statusUpdater = nil
    }

    public init(
        persistence: any PersistenceProviderProtocol,
        currentUserId: @escaping @MainActor () -> UUID? = { AuthService.shared.currentUserId },
        listLoader: (@MainActor () async throws -> (created: [Poll], joined: [Poll]))? = nil,
        detailLoader: (@MainActor (UUID) async throws -> PollDetail)? = nil,
        statusUpdater: (@MainActor (UUID, PollStatus) async throws -> Void)? = nil,
        client: SupabaseClient? = nil,
        requestCredentials: (@MainActor () -> AccountRequestCredentials?)? = nil
    ) {
        self.injectedClient = client
        self.requestCredentials = requestCredentials ?? { nil }
        self.persistence = persistence
        self.currentUserId = currentUserId
        self.listLoader = listLoader
        self.detailLoader = detailLoader
        self.statusUpdater = statusUpdater
    }

    /// Uses an isolated cache and identity for intercepted-transport tests.
    public convenience init(client: SupabaseClient) {
        self.init(persistence: InMemoryPersistenceProvider(), currentUserId: { nil }, client: client)
    }

    /// Called synchronously at every auth identity boundary, before any new account work.
    public func accountDidChange(to userId: UUID?) {
        guard accountId != userId else { return }
        accountGeneration &+= 1
        accountId = userId
        myPolls = []
        createdPolls = []
        joinedPolls = []
        pollParticipantCounts = [:]
        pollTimeRanges = [:]
        detailGenerations = [:]
        isLoading = false
        isLoadingMore = false
        listLoadError = nil
        listTotalCount = nil
        nextListCursor = nil
        listCursors = []
        retryLoadsMore = false
        pollDetailErrors = [:]
        try? persistence.selectAccount(userId)
    }

    func beginRequest() -> UInt64 {
        accountDidChange(to: currentUserId())
        return accountGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == accountGeneration && currentUserId() == accountId && !Task.isCancelled
            && (AccountRequestContext.credentials == nil || AccountRequestContext.credentials?.accountId == accountId)
    }

    func invalidateDetail(_ pollId: UUID) {
        detailGenerations[pollId, default: 0] &+= 1
        try? persistence.invalidatePollDetail(pollId)
    }

    func acceptFinalizedPoll(_ poll: Poll) {
        // A list read started before finalization cannot restore the old active row.
        listGeneration &+= 1
        if isLoading && listTotalCount == nil {
            retryLoadsMore = false
            listLoadError = String(localized: "Refresh to load your poll history.")
        }
        isLoading = false
        isLoadingMore = false
        invalidateDetail(poll.id)
        try? persistence.savePolls([poll])
        myPolls = myPolls.map { $0.id == poll.id ? poll : $0 }
        createdPolls = createdPolls.map { $0.id == poll.id ? poll : $0 }
        joinedPolls = joinedPolls.map { $0.id == poll.id ? poll : $0 }
    }

    // MARK: - Formatting

    public func formatTimeRange(earliest: Date, latest: Date) -> String {
        "\(timeRangeFormatter.string(from: earliest)) - \(timeRangeFormatter.string(from: latest))"
    }

    // MARK: - Load Polls

    /// Refreshes the first summary page. Later pages are requested explicitly by the list.
    public func loadMyPolls() async {
        await loadPollPage(refresh: true)
    }

    public func loadMorePolls() async {
        await loadPollPage(refresh: false)
    }

    public func retryPollLoad() async {
        await loadPollPage(refresh: !retryLoadsMore)
    }

    private func loadPollPage(refresh: Bool) async {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        await AccountRequestContext.$credentials.withValue(credentials) {
            let generation = beginRequest()
            guard let userId = accountId else { return }
            if !refresh && (isLoading || isLoadingMore || nextListCursor == nil) { return }
            let cursor = refresh ? nil : nextListCursor
            listGeneration &+= 1
            let request = listGeneration
            if refresh {
                isLoadingMore = false
                if myPolls.isEmpty, let cached = try? persistence.fetchListedPolls() {
                    myPolls = Array(cached.sorted { $0.createdAt > $1.createdAt }.prefix(50))
                    createdPolls = myPolls.filter { $0.creatorId == userId }
                    joinedPolls = myPolls.filter { $0.creatorId != userId }
                    pollParticipantCounts = (try? persistence.fetchPollParticipantCounts()) ?? [:]
                    pollTimeRanges = (try? persistence.fetchPollTimeRanges()) ?? [:]
                }
                isLoading = true
            } else {
                isLoadingMore = true
            }
            listLoadError = nil
            defer {
                if isCurrent(generation) && request == listGeneration {
                    isLoading = false
                    isLoadingMore = false
                }
            }
            do {
                let page: PollSummaryPage
                if let listLoader {
                    // Existing deterministic lifecycle fixtures supply a complete list.
                    let result = try await listLoader()
                    page = PollSummaryPage.fixture(created: result.created, joined: result.joined)
                } else {
                    var params: [String: AnyJSON] = ["page_size": .integer(50)]
                    if let cursor { params["page_cursor"] = .string(cursor) }
                    page = try await supabase.rpc("list_poll_summaries", params: params).execute().value
                }
                guard isCurrent(generation), request == listGeneration else { return }
                try page.validate(accountId: userId, isFirstPage: refresh, previousCursors: refresh ? [] : listCursors)
                let rows = page.items.map(\.poll)
                let existingIds = Set(refresh ? [] : myPolls.map(\.id))
                guard existingIds.isDisjoint(with: rows.map(\.id)) else { throw PollReadError.incomplete }
                myPolls = (refresh ? [] : myPolls) + rows
                createdPolls = myPolls.filter { $0.creatorId == userId }
                joinedPolls = myPolls.filter { $0.creatorId != userId }
                nextListCursor = page.nextCursor
                if refresh { listCursors = [] }
                if let next = page.nextCursor { listCursors.insert(next) }
                listTotalCount = page.totalCount
                if refresh { pollParticipantCounts = [:]; pollTimeRanges = [:] }
                for item in page.items {
                    pollParticipantCounts[item.poll.id] = item.participantCount
                    if let earliest = item.earliestStart, let latest = item.latestStart {
                        pollTimeRanges[item.poll.id] = (earliest, latest)
                        try? persistence.savePollTimeRange(earliest: earliest, latest: latest, for: item.poll.id)
                    }
                    try? persistence.savePollParticipantCount(item.participantCount, for: item.poll.id)
                }
                // Only a single complete page authorizes deletion reconciliation. A paged
                // traversal is not a snapshot: new rows can appear ahead of its cursor.
                if refresh && !page.hasMore {
                    let accessible = Set(myPolls.map(\.id))
                    for id in detailGenerations.keys.filter({ !accessible.contains($0) }) { invalidateDetail(id) }
                    try? persistence.replacePollsSnapshot(myPolls)
                } else if refresh {
                    try? persistence.replaceListedPollsPage(rows)
                } else {
                    try? persistence.saveListedPolls(rows)
                }
            } catch {
                guard isCurrent(generation), request == listGeneration else { return }
                if Task.isCancelled { return }
                retryLoadsMore = !refresh
                listLoadError = String(localized: "Polls could not be loaded completely. Please retry.")
            }
        }
    }

    public func loadPoll(id: UUID) async -> Poll? {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            do {
                let response: Poll =
                    try await supabase
                    .from("polls")
                    .select()
                    .eq("id", value: id.uuidString)
                    .single()
                    .execute()
                    .value

                guard isCurrent(generation) else { return nil }
                try? persistence.savePolls([response])
                return response
            } catch {
                guard isCurrent(generation) else { return nil }
                print("Failed to load poll: \(error)")
                return try? persistence.fetchPoll(id: id)
            }
        }
    }

    public func loadPollByCode(_ code: String) async -> PollLookupResponse? {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            do {
                let response: [PollLookupResponse] =
                    try await supabase
                    .rpc("get_poll_by_code", params: ["code": AnyJSON.string(code.uppercased())])
                    .execute()
                    .value

                guard isCurrent(generation) else { return nil }
                return response.first
            } catch {
                guard isCurrent(generation) else { return nil }
                print("Failed to load poll by code: \(error)")
                return nil
            }
        }
    }

    /// Reads bounded metadata and traverses response pages before saving a complete detail.
    /// Transport failures may use an existing complete cache; invalid payloads never do.
    public func loadPollDetail(id: UUID) async -> PollDetail? {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let generation = beginRequest()
            detailGenerations[id, default: 0] &+= 1
            let detailGeneration = detailGenerations[id, default: 0]
            pollDetailErrors[id] = nil
            if persistence.isDetailFresh(id, maxAge: 300),
                let cached = try? persistence.fetchPollDetail(id: id) { return cached }
            do {
                let detail: PollDetail
                if let detailLoader {
                    detail = try await detailLoader(id)
                } else {
                    let header: PollDetailPage = try await supabase.rpc(
                        "get_poll_detail", params: ["poll_uuid": id.uuidString]).execute().value
                    try header.validate(pollId: id)
                    let responses = try await readPollResponses(id: id, header: header) {
                        self.isCurrent(generation) && detailGeneration == self.detailGenerations[id, default: 0]
                    }
                    detail = PollDetail(poll: header.poll, timeOptions: header.timeOptions,
                                        participants: header.participants, responses: responses)
                }
                guard isCurrent(generation), detailGeneration == detailGenerations[id, default: 0] else { return nil }
                try? persistence.savePollDetail(detail)
                return detail
            } catch {
                guard isCurrent(generation), detailGeneration == detailGenerations[id, default: 0] else { return nil }
                if let error = error as? PostgrestError, ["PGRST116", "42501"].contains(error.code ?? "") {
                    try? persistence.deletePoll(id: id)
                    return nil
                }
                if error is PollReadError || error is DecodingError || error is PostgrestError {
                    pollDetailErrors[id] = String(localized: "This poll could not be loaded completely. Please retry.")
                    return nil
                }
                if let cached = try? persistence.fetchPollDetail(id: id) { return cached }
                pollDetailErrors[id] = String(localized: "This poll could not be loaded. Please retry.")
                return nil
            }
        }
    }

    private func readPollResponses(
        id: UUID, header: PollDetailPage, isCurrent: () -> Bool
    ) async throws -> [AvailabilityResponse] {
        var cursor: String?
        var cursors: Set<String> = []
        var responses: [AvailabilityResponse] = []
        var expected: Int?
        repeat {
            guard isCurrent() else { throw CancellationError() }
            var params: [String: AnyJSON] = ["poll_uuid": .string(id.uuidString), "page_size": .integer(500)]
            if let cursor { params["page_cursor"] = .string(cursor) }
            let page: PollResponsePage = try await supabase.rpc("list_poll_responses", params: params).execute().value
            guard isCurrent() else { throw CancellationError() }
            try page.validate(previousCursors: cursors)
            if cursor == nil { expected = page.totalCount }
            guard let expected, expected >= 0, expected <= header.participants.count * header.timeOptions.count else {
                throw PollReadError.incomplete
            }
            responses += page.items
            guard responses.count <= expected else { throw PollReadError.incomplete }
            cursor = page.nextCursor
            if let cursor { cursors.insert(cursor) }
            if page.hasMore && responses.count >= expected { throw PollReadError.incomplete }
        } while cursor != nil
        guard responses.count == expected else { throw PollReadError.incomplete }
        try header.validate(responses: responses)
        return responses
    }

    // MARK: - Create Poll

    public func createPoll(_ request: CreatePollRequest) async throws -> PollCreationResult {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return try await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            guard let accountId else { throw PollCreationError.authentication }
            do {
                let result: PollCreationResult = try await supabase.rpc("create_poll", params: request).execute().value
                guard isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
                guard result.poll.creatorId == accountId,
                    result.timeOptions.allSatisfy({ $0.pollId == result.poll.id })
                else { throw PollCreationError.transport }
                // Invalidate older reads so an empty/pre-creation list cannot erase the returned result.
                listGeneration &+= 1
                if isLoading && listTotalCount == nil {
                    retryLoadsMore = false
                    listLoadError = String(localized: "Refresh to load your poll history.")
                }
                isLoading = false
                isLoadingMore = false
                if let total = listTotalCount, !myPolls.contains(where: { $0.id == result.poll.id }) { listTotalCount = total + 1 }
                invalidateDetail(result.poll.id)
                try? persistence.saveListedPolls([result.poll])
                try? persistence.saveTimeOptions(result.timeOptions, for: result.poll.id)
                myPolls.removeAll { $0.id == result.poll.id }
                createdPolls.removeAll { $0.id == result.poll.id }
                myPolls.insert(result.poll, at: 0)
                createdPolls.insert(result.poll, at: 0)
                if let earliest = result.timeOptions.map(\.startTime).min(),
                    let latest = result.timeOptions.map(\.startTime).max()
                {
                    pollTimeRanges[result.poll.id] = (earliest, latest)
                    try? persistence.savePollTimeRange(earliest: earliest, latest: latest, for: result.poll.id)
                }
                return result
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
                if let failure = error as? PollCreationError { throw failure }
                guard let error = error as? PostgrestError else { throw PollCreationError.transport }
                switch error.code {
                case "42501": throw PollCreationError.authentication
                case "P0001": throw PollCreationError.quota
                case "P0002": throw PollCreationError.passUnavailable
                case "22023", "23514": throw PollCreationError.invalidPayload
                case "22000": throw PollCreationError.changedOperation
                case "54000": throw PollCreationError.shareCodeUnavailable
                default: throw PollCreationError.transport
                }
            }
        }
    }

    // MARK: - Time Options

    public func loadTimeOptions(pollId: UUID) async -> [PollTimeOption] {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            do {
                let response: [PollTimeOption] =
                    try await supabase
                    .from("poll_time_options")
                    .select()
                    .eq("poll_id", value: pollId.uuidString)
                    .order("start_time", ascending: true)
                    .execute()
                    .value

                guard isCurrent(generation) else { return [] }
                try? persistence.saveTimeOptions(response, for: pollId)
                return response
            } catch {
                guard isCurrent(generation) else { return [] }
                print("Failed to load time options: \(error)")
                return (try? persistence.fetchTimeOptions(for: pollId)) ?? []
            }
        }
    }

    // MARK: - Poll Status

    public func updatePollStatus(pollId: UUID, status: PollStatus) async throws {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return try await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            do {
                if let statusUpdater {
                    try await statusUpdater(pollId, status)
                } else {
                    try await supabase
                        .from("polls")
                        .update(["status": AnyJSON.string(status.rawValue)])
                        .eq("id", value: pollId.uuidString)
                        .execute()
                }

                guard isCurrent(generation) else { throw CancellationError() }
                invalidateDetail(pollId)
                // Update local state
                if let index = myPolls.firstIndex(where: { $0.id == pollId }) {
                    myPolls[index].status = status
                }
            } catch {
                guard isCurrent(generation) else { throw CancellationError() }
                throw error
            }
        }
    }

    // MARK: - Participants

    public func loadParticipants(pollId: UUID) async -> [PollParticipant] {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            do {
                let response: [PollParticipant] =
                    try await supabase
                    .from("poll_participants")
                    .select("*, profiles(display_name)")
                    .eq("poll_id", value: pollId.uuidString)
                    .execute()
                    .value

                guard isCurrent(generation) else { return [] }
                try? persistence.saveParticipants(response, for: pollId)
                return response
            } catch {
                guard isCurrent(generation) else { return [] }
                print("Failed to load participants: \(error)")
                return (try? persistence.fetchParticipants(for: pollId)) ?? []
            }
        }
    }

    public func joinPoll(pollId: UUID, anonymousName: String? = nil) async throws -> PollParticipant {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return try await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            struct JoinResult: Decodable {
                let participant: PollParticipant
                let created: Bool
            }
            do {
                let result: JoinResult =
                    try await supabase
                    .rpc("join_poll", params: ["poll_uuid": AnyJSON.string(pollId.uuidString)])
                    .execute().value
                guard isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
                invalidateDetail(pollId)
                return result.participant
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { throw CancellationError() }
                if let error = error as? PostgrestError, error.code == "P0003" { throw PollError.capacityReached }
                throw error
            }
        }
    }

    // MARK: - Availability Responses

    public func loadResponses(participantIds: [UUID]) async -> [AvailabilityResponse] {
        let credentials = AccountRequestContext.credentials ?? requestCredentials()
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let supabase = self.supabase
            let generation = beginRequest()
            guard !participantIds.isEmpty else { return [] }

            do {
                let ids = participantIds.map { $0.uuidString }
                let response: [AvailabilityResponse] =
                    try await supabase
                    .from("availability_responses")
                    .select()
                    .in("participant_id", values: ids)
                    .execute()
                    .value

                guard isCurrent(generation) else { return [] }
                try? persistence.replaceResponsesSnapshot(response, for: participantIds)
                return response
            } catch {
                guard isCurrent(generation) else { return [] }
                print("Failed to load responses: \(error)")
                return (try? persistence.fetchResponses(for: participantIds)) ?? []
            }
        }
    }

}

public enum PollError: Error, LocalizedError {
    case notAuthenticated
    case pollNotFound
    case capacityReached
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .pollNotFound: "This poll could not be found. Reload your polls and try again."
        case .capacityReached: "This poll has reached its participant limit. Ask the organizer for help."
        }
    }
}
