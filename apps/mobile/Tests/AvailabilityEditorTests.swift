import XCTest
@testable import Shared

@MainActor
final class AvailabilityEditorTests: XCTestCase {
    private let pollId = UUID()
    private let participantId = UUID()
    private let optionId = UUID()
    private func snapshot(version: Int64 = 1, comment: String? = "saved", answers: [SavedAvailabilityAnswer] = []) -> AvailabilitySnapshot {
        AvailabilitySnapshot(participantId: participantId, pollId: pollId, version: version, comment: comment, responses: answers)
    }
    private func loadedEditor(_ service: MockPollService, initial: AvailabilitySnapshot? = nil) async -> AvailabilityEditor {
        let value = initial ?? snapshot()
        service.availabilityLoader = { _, _, _ in value }
        let editor = AvailabilityEditor()
        await editor.load(pollId: pollId, participantId: participantId, using: service)
        return editor
    }

    func testFailureKeepsDraftAndSavedStateAndRetryUsesSameRequestId() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        editor.responses[optionId] = .maybe
        editor.comment = "my draft"
        var operations: [SaveAvailabilityRequest] = []
        let persisted = snapshot(version: 7, comment: "server-normalized", answers: [SavedAvailabilityAnswer(timeOptionId: optionId, status: .available)])
        service.availabilitySaver = { request in
            operations.append(request)
            if operations.count == 1 { throw AvailabilityCommandError.transport }
            return persisted
        }
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(editor.comment, "my draft")
        XCTAssertEqual(editor.responses[optionId], .maybe)
        XCTAssertEqual(editor.saved?.version, 1)
        XCTAssertFalse(editor.didSave)
        XCTAssertFalse(editor.isSaved)
        XCTAssertNotNil(editor.errorMessage)
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].requestId, operations[1].requestId)
        XCTAssertEqual(operations[1].expectedVersion, 1)
        XCTAssertEqual(editor.saved?.version, 7)
        XCTAssertEqual(editor.comment, "server-normalized")
        XCTAssertEqual(editor.responses[optionId], .available)
        XCTAssertTrue(editor.didSave)
        XCTAssertTrue(editor.isSaved)
    }

    func testLostReplyRetriesCommittedOperationWithoutSecondWrite() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        editor.responses[optionId] = .available
        var committed: [UUID: AvailabilitySnapshot] = [:]
        var writes = 0
        service.availabilitySaver = { request in
            if let previous = committed[request.requestId] { return previous }
            writes += 1
            committed[request.requestId] = self.snapshot(version: 8, comment: request.comment,
                answers: [SavedAvailabilityAnswer(timeOptionId: self.optionId, status: .available)])
            throw URLError(.timedOut)
        }
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertFalse(editor.didSave)
        XCTAssertEqual(editor.saved?.version, 1)
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(editor.saved?.version, 8)
        XCTAssertTrue(editor.isSaved)
    }

    func testChangedDraftAfterFailureGetsNewOperationId() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        var operations: [SaveAvailabilityRequest] = []
        service.availabilitySaver = { request in operations.append(request); throw AvailabilityCommandError.transport }
        editor.comment = "one"
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        editor.comment = "two"
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertNotEqual(operations[0].requestId, operations[1].requestId)
    }

    func testConflictRequiresReloadRetainsDraftAndRetriesWithNewVersionAndId() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        editor.comment = "retained draft"
        var operations: [SaveAvailabilityRequest] = []
        service.availabilitySaver = { request in operations.append(request); throw AvailabilityCommandError.conflict }
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertTrue(editor.needsConflictReview)
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(operations.count, 1)
        let latest = snapshot(version: 22, comment: "other device")
        service.availabilityLoader = { _, _, _ in latest }
        await editor.load(pollId: pollId, participantId: participantId, preservingDraft: true, using: service)
        XCTAssertEqual(editor.saved?.comment, "other device")
        XCTAssertEqual(editor.comment, "retained draft")
        XCTAssertFalse(editor.needsConflictReview)
        service.availabilitySaver = { request in
            operations.append(request)
            return self.snapshot(version: 23, comment: request.comment)
        }
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(operations[1].expectedVersion, 22)
        XCTAssertNotEqual(operations[0].requestId, operations[1].requestId)
        XCTAssertEqual(editor.comment, "retained draft")
        XCTAssertTrue(editor.isSaved)
    }

    func testInitialReadFailureBlocksSaveAndRetryAdoptsCompleteServerSet() async {
        let service = MockPollService()
        service.availabilityLoader = { _, _, _ in throw URLError(.notConnectedToInternet) }
        var saves = 0
        service.availabilitySaver = { _ in saves += 1; throw AvailabilityCommandError.transport }
        let editor = AvailabilityEditor()
        await editor.load(pollId: pollId, participantId: participantId, using: service)
        XCTAssertNil(editor.saved)
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(saves, 0)
        let loaded = snapshot(answers: [SavedAvailabilityAnswer(timeOptionId: optionId, status: .maybe, note: "keep note")])
        service.availabilityLoader = { _, _, _ in loaded }
        await editor.load(pollId: pollId, participantId: participantId, preservingDraft: true, using: service)
        XCTAssertEqual(editor.responses[optionId], .maybe)
        XCTAssertEqual(editor.comment, "saved")
        XCTAssertTrue(editor.isSaved)
    }

    func testClosedPollKeepsDraftAndStopsFurtherSaves() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        editor.comment = "keep me"
        var saves = 0
        service.availabilitySaver = { _ in saves += 1; throw AvailabilityCommandError.closed }
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        await editor.save(pollId: pollId, participantId: participantId, using: service)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(editor.comment, "keep me")
        XCTAssertTrue(editor.isClosed)
        XCTAssertFalse(editor.didSave)
    }

    func testIdentityResetRejectsLateLoadAndClearsAllDraftState() async {
        let service = MockPollService()
        var continuation: CheckedContinuation<AvailabilitySnapshot, Error>?
        service.availabilityLoader = { _, _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let editor = AvailabilityEditor()
        let load = Task { await editor.load(pollId: pollId, participantId: participantId, using: service) }
        while continuation == nil { await Task.yield() }
        editor.reset()
        continuation?.resume(returning: snapshot())
        await load.value
        XCTAssertNil(editor.saved)
        XCTAssertTrue(editor.comment.isEmpty)
        XCTAssertTrue(editor.responses.isEmpty)
        XCTAssertFalse(editor.isLoading)
    }

    func testIdentityResetRejectsLateSuccessfulSave() async {
        let service = MockPollService()
        let editor = await loadedEditor(service)
        editor.comment = "A draft"
        var continuation: CheckedContinuation<AvailabilitySnapshot, Error>?
        service.availabilitySaver = { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let save = Task { await editor.save(pollId: pollId, participantId: participantId, using: service) }
        while continuation == nil { await Task.yield() }
        editor.reset()
        continuation?.resume(returning: snapshot(version: 8, comment: "A draft"))
        await save.value
        XCTAssertNil(editor.saved)
        XCTAssertTrue(editor.comment.isEmpty)
        XCTAssertFalse(editor.didSave)
        XCTAssertFalse(editor.isSaving)
    }

    func testEditWhileSavingRemainsUnsavedDraftAndNotesArePreserved() async {
        let service = MockPollService()
        let initial = snapshot(answers: [SavedAvailabilityAnswer(timeOptionId: optionId, status: .maybe, note: "original note")])
        let editor = await loadedEditor(service, initial: initial)
        editor.comment = "submitted"
        var request: SaveAvailabilityRequest?
        var continuation: CheckedContinuation<AvailabilitySnapshot, Error>?
        service.availabilitySaver = { operation in
            request = operation
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let save = Task { await editor.save(pollId: pollId, participantId: participantId, using: service) }
        while continuation == nil { await Task.yield() }
        editor.comment = "new edit"
        continuation?.resume(returning: snapshot(version: 3, comment: "submitted", answers: initial.responses))
        await save.value
        XCTAssertEqual(request?.responses.first?.note, "original note")
        XCTAssertEqual(editor.saved?.comment, "submitted")
        XCTAssertEqual(editor.comment, "new edit")
        XCTAssertFalse(editor.isSaved)
    }

    func testGuestCapabilityReachesReadAndSaveAndReturnedSnapshotBecomesSavedState() async {
        let service = MockPollService()
        let editor = AvailabilityEditor()
        let initial = snapshot()
        var readToken: String?
        var writeToken: String?
        service.availabilityLoader = { _, _, token in readToken = token; return initial }
        await editor.load(pollId: pollId, participantId: participantId, guestToken: "test-capability", using: service)
        service.availabilitySaver = { request in writeToken = request.guestToken; return self.snapshot(version: 9, comment: request.comment) }
        editor.comment = "guest draft"
        await editor.save(pollId: pollId, participantId: participantId, guestToken: "test-capability", using: service)
        XCTAssertEqual(readToken, "test-capability")
        XCTAssertEqual(writeToken, "test-capability")
        XCTAssertEqual(editor.saved?.version, 9)
        XCTAssertTrue(editor.isSaved)
    }
}
