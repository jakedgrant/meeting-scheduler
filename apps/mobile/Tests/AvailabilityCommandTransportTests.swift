import XCTest
import Supabase
import Synchronization
@testable import Shared

private final class AvailabilityURLProtocol: URLProtocol {
    struct Reply: Sendable { let status: Int; let data: Data }
    static let replies = Mutex<[Reply]>([])
    static let requests = Mutex<[URLRequest]>([])
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
    private func service(replies: [(Int, Data)]) -> PollService {
        AvailabilityURLProtocol.requests.withLock { $0 = [] }
        AvailabilityURLProtocol.replies.withLock { $0 = replies.map { AvailabilityURLProtocol.Reply(status: $0.0, data: $0.1) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AvailabilityURLProtocol.self]
        let client = SupabaseClient(supabaseURL: URL(string: "https://availability-tests.invalid")!, supabaseKey: "test-only",
            options: .init(auth: .init(autoRefreshToken: false, accessToken: { "test-only" }),
                           global: .init(session: URLSession(configuration: config))))
        return PollService(client: client)
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
}
