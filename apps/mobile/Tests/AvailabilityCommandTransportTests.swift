import XCTest
import Supabase
import Synchronization
@testable import Shared

private final class AvailabilityURLProtocol: URLProtocol {
    struct Reply: Sendable { let status: Int; let data: Data }
    static let replies = Mutex<[Reply]>([])
    static let requests = Mutex<[URLRequest]>([])
    static let beforeResponse = Mutex<(@Sendable () -> Void)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.requests.withLock { $0.append(captured) }
        let reply = Self.replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.beforeResponse.withLock { $0 }?()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AvailabilityCommandTransportTests: XCTestCase {
    private let pollId = UUID()
    private let participantId = UUID()
    private let optionId = UUID()
    private func service(replies: [(Int, Data)], persistence: (any PersistenceProviderProtocol)? = nil,
                         currentUserId: @escaping @MainActor () -> UUID? = { nil }) -> PollService {
        AvailabilityURLProtocol.beforeResponse.withLock { $0 = nil }
        AvailabilityURLProtocol.requests.withLock { $0 = [] }
        AvailabilityURLProtocol.replies.withLock { $0 = replies.map { AvailabilityURLProtocol.Reply(status: $0.0, data: $0.1) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvailabilityURLProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://availability-tests.invalid")!, supabaseKey: "test-only",
            options: .init(auth: .init(autoRefreshToken: false, accessToken: { "test-only" }),
                           global: .init(session: URLSession(configuration: config))))
        return PollService(persistence: persistence ?? InMemoryPersistenceProvider(), currentUserId: currentUserId, client: client)
    }
    private func body() throws -> [String: Any] {
        let requests = AvailabilityURLProtocol.requests.withLock { $0 }
        let data = try XCTUnwrap(requests.last?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func snapshotData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "participant_id": participantId.uuidString, "poll_id": pollId.uuidString, "version": 7,
            "comment": NSNull(), "responses": [["id": UUID().uuidString, "time_option_id": optionId.uuidString,
                "status": "maybe", "note": "server note", "updated_at": "2026-10-23T07:00:00.123456+00:00"]],
            "saved_at": "2026-10-23T07:00:01Z", "replayed": true
        ])
    }

    func testSaveUsesOneRpcWithCompleteSetExplicitNullAndRetryIdentity() async throws {
        let data = try snapshotData()
        let service = service(replies: [(200, data)])
        let operation = SaveAvailabilityRequest(pollId: pollId, responses: [], comment: nil, expectedVersion: 4,
                                                 participantId: participantId, guestToken: "test-guest-capability")
        let result = try await service.saveAvailability(operation)
        let requests = AvailabilityURLProtocol.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/rest/v1/rpc/save_availability")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        let payload = try body()
        XCTAssertEqual(payload["request_id"] as? String, operation.requestId.uuidString)
        XCTAssertEqual(payload["expected_version"] as? Int, 4)
        XCTAssertEqual(payload["guest_token"] as? String, "test-guest-capability")
        XCTAssertEqual(payload["participant_uuid"] as? String, participantId.uuidString)
        XCTAssertTrue(payload["comment"] is NSNull)
        XCTAssertEqual((payload["responses"] as? [Any])?.count, 0)
        XCTAssertEqual(result.version, 7)
        XCTAssertEqual(result.replayed, true)
        XCTAssertEqual(result.responses.first?.note, "server note")
        XCTAssertEqual(result.availabilityResponses.first?.participantId, participantId)
    }

    func testMemberReadOmitsGuestCredentialAndUsesPersistedVersion() async throws {
        let service = service(replies: [(200, try snapshotData())])
        let result = try await service.getAvailability(pollId: pollId, participantId: participantId)
        XCTAssertEqual(AvailabilityURLProtocol.requests.withLock { $0.last?.url?.path }, "/rest/v1/rpc/get_availability")
        let payload = try body()
        XCTAssertNil(payload["guest_token"])
        XCTAssertEqual(payload["poll_uuid"] as? String, pollId.uuidString)
        XCTAssertEqual(result.version, 7)
    }

    func testConflictAndClosedErrorsAreActionable() async throws {
        let conflict = Data(#"{"code":"PT409","message":"Responses changed since the expected version","details":"current_version=8","hint":null}"#.utf8)
        let closed = Data(#"{"code":"42501","message":"Poll is not accepting responses","details":null,"hint":null}"#.utf8)
        let service = service(replies: [(409, conflict), (403, closed)])
        let request = SaveAvailabilityRequest(pollId: pollId, responses: [], comment: nil, expectedVersion: 1, participantId: participantId)
        do { _ = try await service.saveAvailability(request); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? AvailabilityCommandError, .conflict) }
        do { _ = try await service.saveAvailability(request); XCTFail("Expected closed poll") }
        catch { XCTAssertEqual(error as? AvailabilityCommandError, .closed) }
    }

    func testFinalizeUsesOptionIdentityAndReturnsAuthoritativeClosedPoll() async throws {
        let finalized = Poll(id: pollId, creatorId: UUID(), title: "Final", status: .closed,
                             selectedStartTime: Date(timeIntervalSince1970: 100), selectedEndTime: Date(timeIntervalSince1970: 200))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let service = service(replies: [(200, try encoder.encode(finalized))])
        let result = try await service.finalizePoll(pollId: pollId, timeOptionId: optionId)
        let payload = try body()
        XCTAssertEqual(AvailabilityURLProtocol.requests.withLock { $0.last?.url?.path }, "/rest/v1/rpc/finalize_poll")
        XCTAssertEqual(payload["time_option_uuid"] as? String, optionId.uuidString)
        XCTAssertNil(payload["selected_start_time"])
        XCTAssertEqual(result.status, .closed)
        XCTAssertEqual(result.selectedStartTime, finalized.selectedStartTime)
    }
    func testSuccessfulSaveInvalidatesOldDetailWithoutRenewingOtherParticipants() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let service = service(replies: [(200, try snapshotData())], persistence: cache, currentUserId: { account })
        service.accountDidChange(to: account)
        let poll = Poll(id: pollId, creatorId: account, title: "Cached")
        try cache.savePollDetail(PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        XCTAssertTrue(cache.isDetailFresh(pollId, maxAge: 300))
        let request = SaveAvailabilityRequest(pollId: pollId, responses: [], comment: nil, expectedVersion: 1, participantId: participantId)
        let result = try await service.saveAvailability(request)
        XCTAssertEqual(result.version, 7)
        XCTAssertNil(try cache.fetchPollDetail(id: pollId))
        XCTAssertFalse(cache.isDetailFresh(pollId, maxAge: 300))
    }

    func testFinalizationInvalidatesDetailAndCachesReturnedPoll() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let finalized = Poll(id: pollId, creatorId: account, title: "Final", status: .closed,
            selectedStartTime: Date(timeIntervalSince1970: 100), selectedEndTime: Date(timeIntervalSince1970: 200))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let service = service(replies: [(200, try encoder.encode(finalized))], persistence: cache, currentUserId: { account })
        service.accountDidChange(to: account)
        try cache.saveListedPolls([Poll(id: pollId, creatorId: account, title: "Final", status: .active, updatedAt: Date(timeIntervalSince1970: 1))])
        try cache.savePollDetail(PollDetail(poll: Poll(id: pollId, creatorId: account, title: "Final", status: .active, updatedAt: Date(timeIntervalSince1970: 1)), timeOptions: [], participants: [], responses: []))
        _ = try await service.finalizePoll(pollId: pollId, timeOptionId: optionId)
        XCTAssertEqual(try cache.fetchPoll(id: pollId)?.status, .closed)
        XCTAssertEqual(try cache.fetchListedPolls().first?.selectedStartTime, finalized.selectedStartTime)
        XCTAssertNil(try cache.fetchPollDetail(id: pollId))
    }

    func testServiceRejectsSuccessfulCommandThatCompletesAfterAccountChanges() async throws {
        let first = UUID()
        let second = UUID()
        let identity = Mutex<UUID?>(first)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let service = service(replies: [(200, try snapshotData())], persistence: cache,
                              currentUserId: { identity.withLock { $0 } })
        service.accountDidChange(to: first)
        AvailabilityURLProtocol.beforeResponse.withLock { callback in
            callback = { identity.withLock { $0 = second } }
        }
        let request = SaveAvailabilityRequest(pollId: pollId, responses: [], comment: nil, expectedVersion: 1, participantId: participantId)
        do { _ = try await service.saveAvailability(request); XCTFail("A result must not return under B") }
        catch { XCTAssertTrue(error is CancellationError) }
        service.accountDidChange(to: second)
        XCTAssertTrue(try cache.fetchAllPolls().isEmpty)
    }

    func testFailedSaveInvalidatesDetailBecauseCommitMayBeUncertain() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let error = Data(#"{"code":"42501","message":"Poll is not accepting responses","details":null,"hint":null}"#.utf8)
        let service = service(replies: [(403, error)], persistence: cache, currentUserId: { account })
        service.accountDidChange(to: account)
        try cache.savePollDetail(PollDetail(poll: Poll(id: pollId, creatorId: account, title: "Cached"), timeOptions: [], participants: [], responses: []))
        let operation = SaveAvailabilityRequest(pollId: pollId, responses: [], comment: nil, expectedVersion: 1, participantId: participantId)
        do { _ = try await service.saveAvailability(operation); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? AvailabilityCommandError, .closed) }
        XCTAssertNil(try cache.fetchPollDetail(id: pollId))
    }

    func testFinalizationRejectsOlderListCompletion() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let old = Poll(id: pollId, creatorId: account, title: "Final", status: .active, updatedAt: Date(timeIntervalSince1970: 1))
        let finalized = Poll(id: pollId, creatorId: account, title: "Final", status: .closed,
            selectedStartTime: Date(timeIntervalSince1970: 100), selectedEndTime: Date(timeIntervalSince1970: 200))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let transport = service(replies: [(200, try encoder.encode(finalized))])
        var calls = 0
        var continuation: CheckedContinuation<(created: [Poll], joined: [Poll]), Error>?
        let service = PollService(persistence: cache, currentUserId: { account }, listLoader: {
            calls += 1
            if calls == 1 { return ([old], []) }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, client: transport.supabase)
        await service.loadMyPolls()
        let pending = Task { await service.loadMyPolls() }
        while continuation == nil { await Task.yield() }
        _ = try await service.finalizePoll(pollId: pollId, timeOptionId: optionId)
        continuation?.resume(returning: ([old], []))
        await pending.value
        XCTAssertEqual(service.myPolls.first?.status, .closed)
        XCTAssertEqual(service.createdPolls.first?.status, .closed)
        XCTAssertEqual(try cache.fetchPoll(id: pollId)?.status, .closed)
        XCTAssertFalse(service.isLoading)
    }

    func testMemberJoinUsesIdempotentCommandAndReturnsExistingMembership() async throws {
        let participant = PollParticipant(pollId: pollId, userId: UUID())
        struct JoinReply: Encodable { let participant: PollParticipant; let created: Bool }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(JoinReply(participant: participant, created: false))
        let service = service(replies: [(200, data), (200, data)])
        let first = try await service.joinPoll(pollId: pollId)
        let retry = try await service.joinPoll(pollId: pollId)
        XCTAssertEqual(first.id, retry.id)
        let payload = try body()
        XCTAssertEqual(AvailabilityURLProtocol.requests.withLock { $0.last?.url?.path }, "/rest/v1/rpc/join_poll")
        XCTAssertEqual(payload["poll_uuid"] as? String, pollId.uuidString)
        XCTAssertNil(payload["user_id"])
    }

}
