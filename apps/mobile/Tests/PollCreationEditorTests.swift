import XCTest
@testable import Shared

@MainActor
private final class MemoryCreationDraftStore: PollCreationDraftStore {
    var data: [UUID: Data] = [:]
    var failWrites = false
    func read(accountId: UUID) throws -> Data? { data[accountId] }
    func write(_ value: Data?, accountId: UUID) throws {
        if failWrites { throw PollCreationError.draftStorage }
        data[accountId] = value
    }
}

@MainActor
final class PollCreationEditorTests: XCTestCase {
    private let account = UUID()
    private func payload(title: String = "Planning", usePass: Bool = false) -> PollCreationPayload {
        PollCreationPayload(title: title, timezone: "America/Chicago", timeOptions: [
            PollCreationOption(startTime: Date(timeIntervalSince1970: 100), endTime: Date(timeIntervalSince1970: 200), isAllDay: false)
        ], useEventPass: usePass)
    }
    private func saved(_ request: CreatePollRequest, replayed: Bool = false) -> PollCreationResult {
        let poll = Poll(creatorId: account, title: "Authoritative title", status: .active, isPremium: true, maxParticipants: 50, shareCode: "SERVER")
        return PollCreationResult(poll: poll, timeOptions: request.payload.timeOptions.map {
            PollTimeOption(pollId: poll.id, startTime: $0.startTime, endTime: $0.endTime, isAllDay: $0.isAllDay)
        }, redeemedPassId: UUID(), entitlement: .eventPass, replayed: replayed)
    }

    func testInvalidOptionsNeverDispatchOrCreatePartialPoll() async {
        let store = MemoryCreationDraftStore(); let editor = PollCreationEditor(store: store)
        editor.selectAccount(account)
        let service = MockPollService.empty
        var calls = 0
        service.creator = { _ in calls += 1; throw PollCreationError.transport }
        await editor.submit(PollCreationPayload(title: "Test", timezone: "UTC", timeOptions: [
            PollCreationOption(startTime: Date(timeIntervalSince1970: 200), endTime: Date(timeIntervalSince1970: 100), isAllDay: false)
        ]), using: service)
        XCTAssertEqual(calls, 0); XCTAssertNil(editor.result); XCTAssertNotNil(editor.errorMessage)
    }

    func testLostReplyRestartsRecoverExactOperationAndAuthoritativeResult() async throws {
        let store = MemoryCreationDraftStore(); let editor = PollCreationEditor(store: store)
        editor.selectAccount(account)
        let service = MockPollService.empty
        var requests: [CreatePollRequest] = []
        var committed: PollCreationResult?
        service.creator = { request in
            requests.append(request)
            if committed == nil { committed = self.saved(request); throw PollCreationError.transport }
            return try XCTUnwrap(committed)
        }
        await editor.submit(payload(usePass: true), using: service)
        XCTAssertTrue(editor.mustResolvePending); XCTAssertNil(editor.result)
        let recovered = PollCreationEditor(store: store)
        recovered.selectAccount(account)
        XCTAssertEqual(recovered.pending?.operationId, requests.first?.operationId)
        XCTAssertEqual(recovered.pending?.payload, requests.first?.payload)
        XCTAssertTrue(recovered.mustResolvePending)
        await recovered.submit(try XCTUnwrap(recovered.pending?.payload), using: service)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].operationId, requests[1].operationId)
        XCTAssertEqual(requests[0].payload, requests[1].payload)
        XCTAssertEqual(recovered.result?.poll.id, committed?.poll.id)
        XCTAssertEqual(recovered.result?.poll.maxParticipants, 50)
        XCTAssertEqual(recovered.result?.poll.title, "Authoritative title")
        XCTAssertNil(recovered.pending); XCTAssertNil(store.data[account])
    }

    func testUncertainCreationCannotBecomeAnotherPollWhenDraftChanges() async {
        let editor = PollCreationEditor(store: MemoryCreationDraftStore()); editor.selectAccount(account)
        let service = MockPollService.empty
        var calls = 0
        service.creator = { _ in calls += 1; throw PollCreationError.transport }
        await editor.submit(payload(), using: service)
        let operation = editor.pending?.operationId
        await editor.submit(payload(title: "Edited"), using: service)
        XCTAssertEqual(calls, 1); XCTAssertEqual(editor.pending?.operationId, operation)
        XCTAssertEqual(editor.pending?.payload.title, "Planning"); XCTAssertTrue(editor.mustResolvePending)
    }

    func testDefiniteRejectionRetainsDraftAndEditsStartNewIdentity() async {
        let store = MemoryCreationDraftStore(); let editor = PollCreationEditor(store: store); editor.selectAccount(account)
        let service = MockPollService.empty
        var requests: [CreatePollRequest] = []
        service.creator = { request in requests.append(request); throw PollCreationError.quota }
        await editor.submit(payload(), using: service)
        XCTAssertFalse(editor.mustResolvePending); XCTAssertNotNil(editor.errorMessage)
        await editor.submit(payload(), using: service)
        XCTAssertEqual(requests[0].operationId, requests[1].operationId)
        await editor.submit(payload(title: "Changed", usePass: true), using: service)
        XCTAssertNotEqual(requests[1].operationId, requests[2].operationId)
        let reopened = PollCreationEditor(store: store); reopened.selectAccount(account)
        XCTAssertEqual(reopened.pending?.payload.title, "Changed")
        XCTAssertFalse(reopened.mustResolvePending)
    }

    func testQueuedSubmissionAfterSuccessNeverDispatchesAnotherPoll() async {
        let editor = PollCreationEditor(store: MemoryCreationDraftStore()); editor.selectAccount(account)
        let service = MockPollService.empty
        var sends = 0
        service.creator = { request in sends += 1; return self.saved(request) }
        await editor.submit(payload(), using: service)
        let savedId = editor.result?.poll.id
        await editor.submit(payload(title: "Queued second tap"), using: service)
        XCTAssertEqual(sends, 1); XCTAssertEqual(editor.result?.poll.id, savedId)
        XCTAssertNil(editor.pending)
    }

    func testPayloadMismatchRetainsLockedOperationRatherThanStartingAnotherPoll() async {
        let editor = PollCreationEditor(store: MemoryCreationDraftStore()); editor.selectAccount(account)
        let service = MockPollService.empty
        var calls = 0
        service.creator = { _ in calls += 1; throw PollCreationError.changedOperation }
        await editor.submit(payload(), using: service)
        let original = editor.pending?.operationId
        XCTAssertTrue(editor.mustResolvePending)
        await editor.submit(payload(title: "Different"), using: service)
        XCTAssertEqual(calls, 1); XCTAssertEqual(editor.pending?.operationId, original)
    }

    func testStorageFailurePreventsDispatchBeforeRetryIdentityIsDurable() async {
        let store = MemoryCreationDraftStore(); store.failWrites = true
        let editor = PollCreationEditor(store: store); editor.selectAccount(account)
        let service = MockPollService.empty
        var calls = 0
        service.creator = { request in calls += 1; return self.saved(request) }
        await editor.submit(payload(), using: service)
        XCTAssertEqual(calls, 0); XCTAssertNotNil(editor.errorMessage); XCTAssertNil(editor.result)
    }

    func testAtomicFileDraftSurvivesNewEditorAndKeepsAccountsSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "creation-test-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = PollCreationEditor(store: FilePollCreationDraftStore(directory: directory))
        editor.selectAccount(account)
        let service = MockPollService.empty
        service.creator = { _ in throw PollCreationError.transport }
        await editor.submit(payload(usePass: true), using: service)
        let recovered = PollCreationEditor(store: FilePollCreationDraftStore(directory: directory))
        recovered.selectAccount(UUID())
        XCTAssertNil(recovered.pending)
        recovered.selectAccount(account)
        XCTAssertEqual(recovered.pending?.operationId, editor.pending?.operationId)
        XCTAssertEqual(recovered.pending?.payload, editor.pending?.payload)
        XCTAssertTrue(recovered.mustResolvePending)
    }

    func testLateSuccessDoesNotPublishAcrossAccountsAndOriginalCanRecover() async throws {
        let store = MemoryCreationDraftStore(); let editor = PollCreationEditor(store: store); editor.selectAccount(account)
        let service = MockPollService.empty
        var continuation: CheckedContinuation<PollCreationResult, Error>?
        var original: CreatePollRequest?
        service.creator = { request in
            original = request
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let task = Task { await editor.submit(payload(), using: service) }
        while continuation == nil { await Task.yield() }
        editor.selectAccount(UUID())
        XCTAssertNil(editor.pending)
        continuation?.resume(returning: saved(try XCTUnwrap(original)))
        await task.value
        XCTAssertNil(editor.result); XCTAssertNil(editor.errorMessage); XCTAssertFalse(editor.isSubmitting)
        editor.selectAccount(account)
        XCTAssertTrue(editor.mustResolvePending)
        XCTAssertEqual(editor.pending?.operationId, original?.operationId)
    }

    func testLateRejectionDoesNotRestoreOtherAccountsDraftOrError() async {
        let store = MemoryCreationDraftStore(); let editor = PollCreationEditor(store: store); editor.selectAccount(account)
        let service = MockPollService.empty
        var continuation: CheckedContinuation<PollCreationResult, Error>?
        service.creator = { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let task = Task { await editor.submit(payload(), using: service) }
        while continuation == nil { await Task.yield() }
        editor.selectAccount(UUID())
        continuation?.resume(throwing: PollCreationError.passUnavailable)
        await task.value
        XCTAssertNil(editor.result); XCTAssertNil(editor.pending); XCTAssertNil(editor.errorMessage)
    }
}
