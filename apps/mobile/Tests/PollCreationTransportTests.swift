import XCTest
import Supabase
import Synchronization
@testable import Shared

private final class CreationURLProtocol: URLProtocol {
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

private final class CreationTestIdentity: Sendable {
    let value: Mutex<UUID?>
    init(_ id: UUID) { value = Mutex(id) }
    func read() -> UUID? { value.withLock { $0 } }
    func set(_ id: UUID) { value.withLock { $0 = id } }
}

@MainActor
final class PollCreationTransportTests: XCTestCase {
    private let account = UUID()
    private func payload() -> PollCreationPayload {
        PollCreationPayload(title: "Planning", timezone: "UTC", timeOptions: [
            PollCreationOption(startTime: Date(timeIntervalSince1970: 100), endTime: Date(timeIntervalSince1970: 200), isAllDay: false)
        ], useEventPass: true)
    }
    private func service(replies: [(Int, Data)], persistence: (any PersistenceProviderProtocol)? = nil,
                         currentUserId: (@MainActor () -> UUID?)? = nil,
                         listLoader: (@MainActor () async throws -> (created: [Poll], joined: [Poll]))? = nil) -> PollService {
        CreationURLProtocol.beforeResponse.withLock { $0 = nil }
        CreationURLProtocol.requests.withLock { $0 = [] }
        CreationURLProtocol.replies.withLock { $0 = replies.map { CreationURLProtocol.Reply(status: $0.0, data: $0.1) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CreationURLProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://creation-tests.invalid")!, supabaseKey: "test-only",
            options: .init(auth: .init(autoRefreshToken: false, accessToken: { "test-only" }),
                           global: .init(session: URLSession(configuration: config))))
        return PollService(persistence: persistence ?? InMemoryPersistenceProvider(), currentUserId: currentUserId ?? { self.account },
                           listLoader: listLoader, client: client)
    }
    private func result() -> PollCreationResult {
        let poll = Poll(creatorId: account, title: "Server title", status: .active, isPremium: true, maxParticipants: 50, shareCode: "SERVER")
        return PollCreationResult(poll: poll, timeOptions: payload().timeOptions.map {
            PollTimeOption(pollId: poll.id, startTime: $0.startTime, endTime: $0.endTime, isAllDay: $0.isAllDay)
        }, redeemedPassId: UUID(), entitlement: .eventPass, replayed: true)
    }
    private func data(_ result: PollCreationResult) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(result)
    }

    func testOneRpcIncludesCompletePayloadNoClientAuthorityAndAppliesReturnedStateOnce() async throws {
        let saved = result(); let cache = SwiftDataPersistenceProvider(inMemory: true)
        let service = service(replies: [(200, try data(saved)), (200, try data(saved))], persistence: cache)
        let request = CreatePollRequest(payload: payload())
        let first = try await service.createPoll(request)
        let retry = try await service.createPoll(request)
        let requests = CreationURLProtocol.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/rest/v1/rpc/create_poll" && $0.httpMethod == "POST" })
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["operation_id", "payload"])
        XCTAssertEqual(body["operation_id"] as? String, request.operationId.uuidString)
        let draft = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(Set(draft.keys), ["title", "description", "location", "timezone", "closes_at", "time_options", "use_event_pass"])
        XCTAssertTrue(draft["description"] is NSNull); XCTAssertTrue(draft["location"] is NSNull); XCTAssertTrue(draft["closes_at"] is NSNull)
        XCTAssertEqual(draft["use_event_pass"] as? Bool, true)
        let option = try XCTUnwrap((draft["time_options"] as? [[String: Any]])?.first)
        XCTAssertEqual(option["start_time"] as? String, "1970-01-01T00:01:40Z")
        XCTAssertEqual(option["end_time"] as? String, "1970-01-01T00:03:20Z")
        XCTAssertEqual(first.poll.id, retry.poll.id); XCTAssertEqual(retry.replayed, true)
        XCTAssertEqual(service.myPolls.count, 1); XCTAssertEqual(service.createdPolls.count, 1)
        XCTAssertEqual(service.createdPolls.first?.maxParticipants, 50)
        XCTAssertEqual(try cache.fetchListedPolls().first?.title, "Server title")
        XCTAssertEqual(try cache.fetchTimeOptions(for: saved.poll.id).first?.id, saved.timeOptions.first?.id)
    }

    func testSqlErrorsAreActionableAndLeaveLocalPollsUntouched() async throws {
        let failures: [(String, PollCreationError)] = [("42501", .authentication), ("P0001", .quota), ("P0002", .passUnavailable),
            ("22023", .invalidPayload), ("22000", .changedOperation), ("54000", .shareCodeUnavailable)]
        let replies = try failures.map { code, _ in
            (400, try JSONSerialization.data(withJSONObject: ["code": code, "message": "server rejection", "details": NSNull(), "hint": NSNull()]))
        }
        let service = service(replies: replies)
        for (_, expected) in failures {
            do { _ = try await service.createPoll(CreatePollRequest(payload: payload())); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? PollCreationError, expected) }
        }
        XCTAssertTrue(service.myPolls.isEmpty); XCTAssertTrue(service.createdPolls.isEmpty)
    }

    func testLateAccountResultIsRejectedWithoutCaching() async throws {
        let saved = result(); let identity = Mutex<UUID?>(account)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let service = service(replies: [(200, try data(saved))], persistence: cache, currentUserId: { identity.withLock { $0 } })
        CreationURLProtocol.beforeResponse.withLock { callback in callback = { identity.withLock { $0 = UUID() } } }
        do { _ = try await service.createPoll(CreatePollRequest(payload: payload())); XCTFail("Expected account cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.myPolls.isEmpty); XCTAssertTrue(try cache.fetchAllPolls().isEmpty)
    }

    func testAccountAToBToARejectsOriginalCommandEpoch() async throws {
        let saved = result(); let identity = CreationTestIdentity(account)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let service = service(replies: [(200, try data(saved))], persistence: cache, currentUserId: { identity.read() })
        let originalAccount = account
        CreationURLProtocol.beforeResponse.withLock { callback in
            callback = {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let other = UUID()
                        identity.set(other); service.accountDidChange(to: other)
                        identity.set(originalAccount); service.accountDidChange(to: originalAccount)
                    }
                }
            }
        }
        do { _ = try await service.createPoll(CreatePollRequest(payload: payload())); XCTFail("Expected obsolete epoch rejection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.myPolls.isEmpty); XCTAssertTrue(try cache.fetchAllPolls().isEmpty)
    }

    func testCapacityErrorProvidesActionableJoinFailure() async throws {
        let error = Data(#"{"code":"P0003","message":"Participant limit reached","details":null,"hint":null}"#.utf8)
        let service = service(replies: [(409, error)])
        do { _ = try await service.joinPoll(pollId: UUID()); XCTFail("Expected capacity rejection") }
        catch { XCTAssertNotNil(error as? PollError); XCTAssertTrue(error.localizedDescription.contains("participant limit")) }
    }

    func testOlderListReplyCannotEraseSuccessfulCreation() async throws {
        var continuation: CheckedContinuation<(created: [Poll], joined: [Poll]), Error>?
        let saved = result()
        let service = service(replies: [(200, try data(saved))], listLoader: {
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let loading = Task { await service.loadMyPolls() }
        while continuation == nil { await Task.yield() }
        _ = try await service.createPoll(CreatePollRequest(payload: payload()))
        continuation?.resume(returning: ([], [])); await loading.value
        XCTAssertEqual(service.createdPolls.first?.id, saved.poll.id); XCTAssertFalse(service.isLoading)
    }
}
