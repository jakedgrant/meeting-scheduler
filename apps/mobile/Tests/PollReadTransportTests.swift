import Foundation
import Supabase
import Synchronization
import XCTest
@testable import Shared

// Every test uses its own URL host and locked transport state; no network or shared session.
private final class ReadTransport: @unchecked Sendable {
    enum Reply { case json(Data), rejected(Int, Data), failure, deferred(XCTestExpectation) }
    struct State {
        var replies: [Reply] = []
        var requests: [URLRequest] = []
        var pending: ReadURLProtocol?
    }
    let state = Mutex(State())
    func enqueue(_ replies: [Reply]) { state.withLock { $0.replies += replies } }
    var requests: [URLRequest] { state.withLock { $0.requests } }
    func release(_ data: Data) {
        let pending = state.withLock { value -> ReadURLProtocol? in
            defer { value.pending = nil }
            return value.pending
        }
        pending?.reply(data)
    }
}

// No mutable subclass state; the registry and pending requests are protected by Mutex.
private final class ReadURLProtocol: URLProtocol, @unchecked Sendable {
    static let transports = Mutex<[String: ReadTransport]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let transport = Self.transports.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        var captured = request
        if let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let reply = transport.state.withLock { state -> ReadTransport.Reply in
            state.requests.append(captured)
            return state.replies.isEmpty ? .failure : state.replies.removeFirst()
        }
        switch reply {
        case .json(let data): self.reply(data)
        case .rejected(let status, let data): self.reply(data, status: status)
        case .failure: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .deferred(let ready):
            transport.state.withLock { $0.pending = self }
            ready.fulfill()
        }
    }
    override func stopLoading() {}
    func reply(_ data: Data, status: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class PollReadTransportTests: XCTestCase {
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func list(_ polls: [Poll], total: Int, next: String? = nil) throws -> Data {
        try json(["items": try polls.map { poll in
            ["poll": try object(poll), "role": "owner", "participant_count": 1200, "time_option_count": 2,
             "earliest_start": "2026-10-25T12:00:00Z", "latest_start": "2026-10-26T12:00:00Z"]
        }, "total_count": total, "has_more": next != nil, "next_cursor": next as Any? ?? NSNull()])
    }
    private struct Fixture {
        let poll: Poll
        let participants: [PollParticipant]
        let options: [PollTimeOption]
        let responses: [AvailabilityResponse]
        init(account: UUID, people: Int = 4, slots: Int = 300) {
            let poll = Poll(creatorId: account, title: "Complete poll")
            let participants = (0..<people).map { _ in PollParticipant(pollId: poll.id, userId: account) }
            let options = (0..<slots).map { _ in PollTimeOption(pollId: poll.id, startTime: Date(), endTime: Date().addingTimeInterval(3600)) }
            self.poll = poll; self.participants = participants; self.options = options
            responses = participants.flatMap { person in options.map { AvailabilityResponse(participantId: person.id, timeOptionId: $0.id, status: .available) } }
        }
    }
    private func header(_ f: Fixture, count: Int? = nil) throws -> Data {
        try json(["poll": object(f.poll), "participants": object(f.participants), "time_options": object(f.options),
                  "participant_count": f.participants.count, "time_option_count": count ?? f.options.count])
    }
    private func page(_ rows: [AvailabilityResponse], total: Int? = nil, next: String? = nil) throws -> Data {
        try json(["items": object(rows), "total_count": total as Any? ?? NSNull(),
                  "has_more": next != nil, "next_cursor": next as Any? ?? NSNull()])
    }
    private func withService(
        account: UUID, cache: any PersistenceProviderProtocol = InMemoryPersistenceProvider(),
        body: @MainActor (PollService, ReadTransport, @escaping @MainActor () -> Void) async throws -> Void
    ) async throws {
        let host = "read-\(UUID().uuidString.lowercased()).invalid"
        let transport = ReadTransport()
        ReadURLProtocol.transports.withLock { $0[host] = transport }
        defer { _ = ReadURLProtocol.transports.withLock { $0.removeValue(forKey: host) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var identity: UUID? = account
        let api = SupabaseService.apiClient(url: URL(string: "https://\(host)")!, key: "test-only", transport: session)
        let service = PollService(persistence: cache, currentUserId: { identity }, client: api,
                                  requestCredentials: { AccountRequestCredentials(accountId: identity, generation: 1, accessToken: "original-A") })
        service.accountDidChange(to: account)
        try await body(service, transport, { identity = UUID(); service.accountDidChange(to: identity) })
    }

    func testListUsesOnlySummaryPagesAndAppendsOnDemand() async throws {
        let account = UUID(); let polls = (0..<52).map { _ in Poll(creatorId: account, title: "History") }
        let cache = InMemoryPersistenceProvider()
        try await withService(account: account, cache: cache) { service, transport, _ in
            transport.enqueue([.json(try list(Array(polls.prefix(50)), total: 52, next: "opaque-microsecond-cursor")),
                               .json(try list(Array(polls.suffix(2)), total: 52))])
            await service.loadMyPolls()
            XCTAssertEqual(service.myPolls.count, 50); XCTAssertEqual(transport.requests.count, 1)
            XCTAssertTrue(service.hasMorePolls); XCTAssertEqual(service.listTotalCount, 52)
            XCTAssertEqual(service.pollParticipantCounts[polls[0].id], 1200)
            await service.loadMorePolls()
            XCTAssertEqual(service.myPolls.map(\.id), polls.map(\.id)); XCTAssertFalse(service.hasMorePolls)
            XCTAssertEqual(transport.requests.map { $0.url!.lastPathComponent }, ["list_poll_summaries", "list_poll_summaries"])
            let body = try XCTUnwrap(transport.requests.last?.httpBody)
            let params = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(params["page_cursor"] as? String, "opaque-microsecond-cursor")
            XCTAssertNil(service.listLoadError)
            XCTAssertEqual(Set(try cache.fetchListedPolls().map(\.id)), Set(polls.map(\.id)))
        }
    }

    func testRepeatedListCursorKeepsRowsAndAllowsRetry() async throws {
        let account = UUID(); let a = Poll(creatorId: account, title: "A"); let b = Poll(creatorId: account, title: "B")
        try await withService(account: account) { service, transport, _ in
            transport.enqueue([.json(try list([a], total: 3, next: "cursor")),
                               .json(try list([b], total: 3, next: "cursor")), .json(try list([b], total: 2))])
            await service.loadMyPolls(); await service.loadMorePolls()
            XCTAssertEqual(service.myPolls.map(\.id), [a.id]); XCTAssertNotNil(service.listLoadError)
            XCTAssertFalse(service.isLoadingMore)
            await service.loadMorePolls()
            XCTAssertEqual(service.myPolls.map(\.id), [a.id, b.id]); XCTAssertNil(service.listLoadError)
        }
    }

    func testPartialListPreservesUnloadedDetailAndReplacesOfflineMembership() async throws {
        let account = UUID()
        for cache: any PersistenceProviderProtocol in [InMemoryPersistenceProvider(), SwiftDataPersistenceProvider(inMemory: true)] {
            let old = Poll(creatorId: account, title: "Older history"); let current = Poll(creatorId: account, title: "First page")
            try await withService(account: account, cache: cache) { service, transport, _ in
                try cache.saveListedPolls([old])
                try cache.savePollDetail(PollDetail(poll: old, timeOptions: [], participants: [], responses: []))
                transport.enqueue([.json(try list([current], total: 2, next: "cursor"))])
                await service.loadMyPolls()
                XCTAssertNotNil(try cache.fetchPollDetail(id: old.id))
                XCTAssertEqual(try cache.fetchListedPolls().map(\.id), [current.id])
            }
        }
    }

    func testInconsistentFirstSummaryPageCannotEvictCachedDetails() async throws {
        let account = UUID(); let old = Poll(creatorId: account, title: "Cached history")
        let current = Poll(creatorId: account, title: "Truncated first page")
        let cache = InMemoryPersistenceProvider()
        try await withService(account: account, cache: cache) { service, transport, _ in
            try cache.saveListedPolls([old])
            try cache.savePollDetail(PollDetail(poll: old, timeOptions: [], participants: [], responses: []))
            transport.enqueue([.json(try list([current], total: 2))])
            await service.loadMyPolls()
            XCTAssertEqual(service.myPolls.map(\.id), [old.id]); XCTAssertNotNil(service.listLoadError)
            XCTAssertNotNil(try cache.fetchPollDetail(id: old.id))
        }
    }

    func testMutationSupersedingRefreshPreservesPagingOrExposesInitialRetry() async throws {
        let account = UUID()
        for initial in [false, true] {
            for finalize in [false, true] {
                let first = Poll(creatorId: account, title: "First")
                let saved = Poll(creatorId: account, title: "Created")
                let ready = expectation(description: "Refresh dispatched")
                try await withService(account: account) { service, transport, _ in
                    if !initial {
                        transport.enqueue([.json(try list([first], total: 2, next: "committed-cursor"))])
                        await service.loadMyPolls()
                    }
                    transport.enqueue([.deferred(ready)])
                    let oldReply = try list([], total: 0)
                    defer { transport.release(oldReply) }
                    let refresh = Task { await service.loadMyPolls() }
                    await fulfillment(of: [ready], timeout: 5)
                    if finalize {
                        var closed = first; closed.status = .closed
                        service.acceptFinalizedPoll(closed)
                    } else {
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        let option = PollTimeOption(pollId: saved.id, startTime: Date(), endTime: Date().addingTimeInterval(3600))
                        transport.enqueue([.json(try encoder.encode(PollCreationResult(poll: saved, timeOptions: [option])))])
                        let payload = PollCreationPayload(title: "New", timezone: "UTC", timeOptions: [
                            PollCreationOption(startTime: option.startTime, endTime: option.endTime, isAllDay: false)])
                        _ = try await service.createPoll(CreatePollRequest(payload: payload))
                    }
                    transport.release(oldReply)
                    await refresh.value
                    XCTAssertEqual(service.hasMorePolls, !initial)
                    XCTAssertEqual(service.listTotalCount, initial ? nil : (finalize ? 2 : 3))
                    XCTAssertEqual(service.listLoadError != nil, initial)
                    XCTAssertFalse(service.isLoading); XCTAssertFalse(service.isLoadingMore)
                    if !initial {
                        let older = Poll(creatorId: account, title: "Older")
                        transport.enqueue([.json(try list([older], total: finalize ? 2 : 3))])
                        await service.loadMorePolls()
                        XCTAssertTrue(service.myPolls.contains { $0.id == older.id })
                    }
                }
            }
        }
    }

    func testFailedRefreshRetryStartsAtFirstPageDespiteRetainedContinuation() async throws {
        let account = UUID(); let first = Poll(creatorId: account, title: "First")
        try await withService(account: account) { service, transport, _ in
            transport.enqueue([.json(try list([first], total: 2, next: "committed")), .failure, .json(try list([], total: 0))])
            await service.loadMyPolls(); await service.loadMyPolls()
            XCTAssertTrue(service.hasMorePolls); XCTAssertNotNil(service.listLoadError)
            await service.retryPollLoad()
            let body = try XCTUnwrap(transport.requests.last?.httpBody)
            let params = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(params["page_cursor"])
            XCTAssertTrue(service.myPolls.isEmpty); XCTAssertNil(service.listLoadError)
        }
    }

    func testDetailTraverses1200ResponsesBeforeCaching() async throws {
        let account = UUID(); let f = Fixture(account: account); let cache = InMemoryPersistenceProvider()
        try await withService(account: account, cache: cache) { service, transport, _ in
            transport.enqueue([.json(try header(f)), .json(try page(Array(f.responses.prefix(500)), total: 1200, next: "r1:a")),
                               .json(try page(Array(f.responses[500..<1000]), next: "r1:b")), .json(try page(Array(f.responses.suffix(200))))])
            let detail = await service.loadPollDetail(id: f.poll.id)
            XCTAssertEqual(detail?.responses.count, 1200)
            XCTAssertEqual(try cache.fetchPollDetail(id: f.poll.id)?.responses.count, 1200)
            XCTAssertEqual(transport.requests.map { $0.url!.lastPathComponent }, ["get_poll_detail", "list_poll_responses", "list_poll_responses", "list_poll_responses"])
            XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer original-A" })
            let params = try transport.requests.dropFirst().map { request in
                try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            }
            XCTAssertNil(params[0]["page_cursor"])
            XCTAssertEqual(params[1]["page_cursor"] as? String, "r1:a")
            XCTAssertEqual(params[2]["page_cursor"] as? String, "r1:b")
            XCTAssertTrue(params.allSatisfy { $0["page_size"] as? Int == 500 && ($0["poll_uuid"] as? String)?.lowercased() == f.poll.id.uuidString.lowercased() })
        }
    }

    func testIncompleteOrDuplicateResponsePagesNeverPublishOrCache() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 2)
        let foreign = AvailabilityResponse(participantId: UUID(), timeOptionId: f.options[0].id, status: .available)
        let variants = [
            try page([f.responses[0]], total: 2), // Silent truncation.
            try page([f.responses[0], f.responses[0]], total: 2), // Duplicate row.
            try page([f.responses[0], foreign], total: 2), // Foreign membership.
            try page(f.responses), // Missing first total.
        ]
        for reply in variants {
            let cache = InMemoryPersistenceProvider()
            try await withService(account: account, cache: cache) { service, transport, _ in
                transport.enqueue([.json(try header(f)), .json(reply)])
                let result = await service.loadPollDetail(id: f.poll.id)
                XCTAssertNil(result); XCTAssertNotNil(service.pollDetailErrors[f.poll.id])
                XCTAssertNil(try cache.fetchPollDetail(id: f.poll.id))
            }
        }
    }

    func testResponseCursorCycleFailsWithoutCaching() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 3)
        let cache = InMemoryPersistenceProvider()
        try await withService(account: account, cache: cache) { service, transport, _ in
            transport.enqueue([.json(try header(f)), .json(try page([f.responses[0]], total: 3, next: "repeat")),
                               .json(try page([f.responses[1]], next: "repeat"))])
            let result = await service.loadPollDetail(id: f.poll.id)
            XCTAssertNil(result); XCTAssertNotNil(service.pollDetailErrors[f.poll.id])
            XCTAssertEqual(transport.requests.count, 3)
            XCTAssertNil(try cache.fetchPollDetail(id: f.poll.id))
        }
    }

    func testInvalidDetailDoesNotFallBackToOrOverwriteStaleCompleteCache() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 2)
        var now = Date()
        let cache = InMemoryPersistenceProvider(now: { now })
        try await withService(account: account, cache: cache) { service, transport, _ in
            try cache.savePollDetail(PollDetail(poll: f.poll, timeOptions: f.options, participants: f.participants, responses: f.responses))
            now = now.addingTimeInterval(600)
            transport.enqueue([.json(try header(f)), .json(try page([f.responses[0]], total: 2))])
            let result = await service.loadPollDetail(id: f.poll.id)
            XCTAssertNil(result)
            XCTAssertEqual(try cache.fetchPollDetail(id: f.poll.id)?.responses.count, 2)
            XCTAssertNotNil(service.pollDetailErrors[f.poll.id])
        }
    }

    func testTransportFailureCanStillUseStaleCompleteDetail() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 2)
        var now = Date(); let cache = InMemoryPersistenceProvider(now: { now })
        try await withService(account: account, cache: cache) { service, transport, _ in
            try cache.savePollDetail(PollDetail(poll: f.poll, timeOptions: f.options, participants: f.participants, responses: f.responses))
            now = now.addingTimeInterval(600)
            transport.enqueue([.failure])
            let result = await service.loadPollDetail(id: f.poll.id)
            XCTAssertEqual(result?.responses.count, 2); XCTAssertNil(service.pollDetailErrors[f.poll.id])
        }
    }

    func testOversizedDetailFailureCannotFallBackToStaleCache() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 2)
        var now = Date(); let cache = InMemoryPersistenceProvider(now: { now })
        try await withService(account: account, cache: cache) { service, transport, _ in
            try cache.savePollDetail(PollDetail(poll: f.poll, timeOptions: f.options, participants: f.participants, responses: f.responses))
            now = now.addingTimeInterval(600)
            transport.enqueue([.rejected(400, try json(["code": "54000", "message": "Poll detail exceeds supported bounds"]))])
            let result = await service.loadPollDetail(id: f.poll.id)
            XCTAssertNil(result); XCTAssertNotNil(service.pollDetailErrors[f.poll.id])
            XCTAssertEqual(try cache.fetchPollDetail(id: f.poll.id)?.responses.count, 2)
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testMismatchedHeaderFailsBeforeResponseRequest() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 1, slots: 2)
        try await withService(account: account) { service, transport, _ in
            transport.enqueue([.json(try header(f, count: 3))])
            let detail = await service.loadPollDetail(id: f.poll.id)
            XCTAssertNil(detail); XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testAccountSwitchBetweenPagesStopsFurtherReadsAndCacheWrites() async throws {
        let account = UUID(); let f = Fixture(account: account, people: 2, slots: 300)
        let ready = expectation(description: "First response page requested")
        let cache = InMemoryPersistenceProvider()
        try await withService(account: account, cache: cache) { service, transport, changeAccount in
            transport.enqueue([.json(try header(f)), .deferred(ready)])
            let reply = try page(Array(f.responses.prefix(500)), total: 600, next: "old-A")
            defer { transport.release(reply) }
            let task = Task { await service.loadPollDetail(id: f.poll.id) }
            await fulfillment(of: [ready], timeout: 5)
            changeAccount()
            transport.release(reply)
            let result = await task.value
            XCTAssertNil(result); XCTAssertEqual(transport.requests.count, 2)
            XCTAssertNil(try cache.fetchPollDetail(id: f.poll.id)); XCTAssertTrue(service.pollDetailErrors.isEmpty)
        }
    }

    func testRefreshSupersedesInflightLoadMore() async throws {
        let account = UUID(); let a = Poll(creatorId: account, title: "A"); let b = Poll(creatorId: account, title: "B")
        let ready = expectation(description: "Load more requested")
        try await withService(account: account) { service, transport, _ in
            transport.enqueue([.json(try list([a], total: 2, next: "older")), .deferred(ready), .json(try list([b], total: 1))])
            await service.loadMyPolls()
            let reply = try list([a], total: 2)
            defer { transport.release(reply) }
            let more = Task { await service.loadMorePolls() }
            await fulfillment(of: [ready], timeout: 5)
            await service.loadMyPolls()
            transport.release(reply)
            await more.value
            XCTAssertEqual(service.myPolls.map(\.id), [b.id]); XCTAssertFalse(service.isLoadingMore)
        }
    }
}
