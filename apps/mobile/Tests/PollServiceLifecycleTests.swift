import XCTest
@testable import Shared

@MainActor
final class PollServiceLifecycleTests: XCTestCase {
    private final class Identity {
        var id: UUID?
        init(_ id: UUID?) { self.id = id }
    }
    private enum Failure: Error { case offline }

    func testSignOutThenOtherAccountNetworkFailureCannotShowPreviousAccount() async throws {
        let accountA = UUID()
        let identity = Identity(accountA)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: accountA, title: "Account A")
        let service = PollService(persistence: cache, currentUserId: { identity.id }, listLoader: {
            guard identity.id == accountA else { throw Failure.offline }
            return ([poll], [])
        })
        await service.loadMyPolls()
        XCTAssertEqual(service.myPolls.map(\.id), [poll.id])
        identity.id = nil
        service.accountDidChange(to: nil)
        XCTAssertTrue(service.myPolls.isEmpty)
        identity.id = UUID()
        service.accountDidChange(to: identity.id)
        await service.loadMyPolls()
        XCTAssertTrue(service.myPolls.isEmpty)
        XCTAssertTrue(service.createdPolls.isEmpty)
        XCTAssertTrue(service.joinedPolls.isEmpty)
        XCTAssertTrue(service.pollTimeRanges.isEmpty)
        XCTAssertTrue(service.pollParticipantCounts.isEmpty)
        XCTAssertTrue(try cache.fetchAllPolls().isEmpty)
    }

    func testLateAccountAListCompletionCannotPopulateAccountB() async throws {
        let accountA = UUID()
        let identity = Identity(accountA)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: accountA, title: "Old account")
        var continuation: CheckedContinuation<(created: [Poll], joined: [Poll]), Error>?
        let service = PollService(persistence: cache, currentUserId: { identity.id }, listLoader: {
            if identity.id != accountA { throw Failure.offline }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let oldLoad = Task { await service.loadMyPolls() }
        while continuation == nil { await Task.yield() }
        identity.id = nil
        service.accountDidChange(to: nil)
        identity.id = UUID()
        service.accountDidChange(to: identity.id)
        await service.loadMyPolls()
        continuation?.resume(returning: ([poll], []))
        await oldLoad.value
        XCTAssertTrue(service.myPolls.isEmpty)
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(try cache.fetchAllPolls().isEmpty)
    }

    func testSuccessfulEmptyListThenOfflineCannotResurrectDeletedPoll() async throws {
        let account = UUID()
        let identity = Identity(account)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: account, title: "Deleted remotely")
        var loadNumber = 0
        let service = PollService(persistence: cache, currentUserId: { identity.id }, listLoader: {
            loadNumber += 1
            if loadNumber == 1 { return ([poll], []) }
            if loadNumber == 2 { return ([], []) }
            throw Failure.offline
        }, detailLoader: { _ in throw Failure.offline })
        await service.loadMyPolls()
        try cache.savePollDetail(PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        await service.loadMyPolls()
        await service.loadMyPolls()
        let offlineDetail = await service.loadPollDetail(id: poll.id)
        XCTAssertTrue(service.myPolls.isEmpty)
        XCTAssertNil(offlineDetail)
        XCTAssertNil(try cache.fetchPoll(id: poll.id))
    }

    func testLateAccountADetailCannotPopulateAccountB() async throws {
        let accountA = UUID()
        let identity = Identity(accountA)
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: accountA, title: "Private detail")
        var continuation: CheckedContinuation<PollDetail, Error>?
        let service = PollService(persistence: cache, currentUserId: { identity.id }, detailLoader: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let oldLoad = Task { await service.loadPollDetail(id: poll.id) }
        while continuation == nil { await Task.yield() }
        identity.id = nil
        service.accountDidChange(to: nil)
        identity.id = UUID()
        service.accountDidChange(to: identity.id)
        continuation?.resume(returning: PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        let result = await oldLoad.value
        XCTAssertNil(result)
        XCTAssertNil(try cache.fetchPollDetail(id: poll.id))
    }
    func testMutationInvalidatesDetailAndRejectsOlderInflightDetail() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: account, title: "Changed", status: .active)
        var continuation: CheckedContinuation<PollDetail, Error>?
        let service = PollService(persistence: cache, currentUserId: { account }, detailLoader: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, statusUpdater: { _, _ in })
        service.accountDidChange(to: account)
        let oldLoad = Task { await service.loadPollDetail(id: poll.id) }
        while continuation == nil { await Task.yield() }
        try await service.updatePollStatus(pollId: poll.id, status: .closed)
        continuation?.resume(returning: PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        let result = await oldLoad.value
        XCTAssertNil(result)
        XCTAssertNil(try cache.fetchPollDetail(id: poll.id))
        try cache.savePollDetail(PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        XCTAssertTrue(cache.isDetailFresh(poll.id, maxAge: 300))
        try await service.updatePollStatus(pollId: poll.id, status: .closed)
        XCTAssertFalse(cache.isDetailFresh(poll.id, maxAge: 300))
        XCTAssertNil(try cache.fetchPollDetail(id: poll.id))
    }

    func testCachedInvitationDoesNotInventOfflineJoinedMembership() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let invitation = Poll(creatorId: UUID(), title: "Not joined")
        let service = PollService(persistence: cache, currentUserId: { account }, listLoader: { throw Failure.offline })
        service.accountDidChange(to: account)
        try cache.savePollDetail(PollDetail(poll: invitation, timeOptions: [], participants: [], responses: []))
        await service.loadMyPolls()
        XCTAssertTrue(service.myPolls.isEmpty)
        XCTAssertTrue(service.joinedPolls.isEmpty)
        XCTAssertNotNil(try cache.fetchPollDetail(id: invitation.id))
    }

    func testOlderListCannotResurrectPollRemovedByNewerCompleteList() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: account, title: "Deleted")
        var calls = 0
        var first: CheckedContinuation<(created: [Poll], joined: [Poll]), Error>?
        let service = PollService(persistence: cache, currentUserId: { account }, listLoader: {
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
            if calls == 2 { return ([], []) }
            throw Failure.offline
        })
        let oldLoad = Task { await service.loadMyPolls() }
        while first == nil { await Task.yield() }
        await service.loadMyPolls()
        first?.resume(returning: ([poll], []))
        await oldLoad.value
        await service.loadMyPolls()
        XCTAssertTrue(service.myPolls.isEmpty)
        XCTAssertNil(try cache.fetchPoll(id: poll.id))
    }

    func testOlderDetailCannotRestoreChildrenRemovedByNewerSnapshot() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: account, title: "Changed")
        let participant = PollParticipant(pollId: poll.id, userId: account)
        var calls = 0
        var first: CheckedContinuation<PollDetail, Error>?
        let service = PollService(persistence: cache, currentUserId: { account }, detailLoader: { _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { first = $0 } }
            return PollDetail(poll: poll, timeOptions: [], participants: [], responses: [])
        })
        let oldLoad = Task { await service.loadPollDetail(id: poll.id) }
        while first == nil { await Task.yield() }
        _ = await service.loadPollDetail(id: poll.id)
        first?.resume(returning: PollDetail(poll: poll, timeOptions: [], participants: [participant], responses: []))
        let stale = await oldLoad.value
        XCTAssertNil(stale)
        XCTAssertTrue(try cache.fetchPollDetail(id: poll.id)?.participants.isEmpty == true)
    }

    func testCompleteListEvictionRejectsPreviouslyStartedDetail() async throws {
        let account = UUID()
        let cache = SwiftDataPersistenceProvider(inMemory: true)
        let poll = Poll(creatorId: account, title: "Removed")
        var first: CheckedContinuation<PollDetail, Error>?
        let service = PollService(persistence: cache, currentUserId: { account }, listLoader: { ([], []) }, detailLoader: { _ in
            try await withCheckedThrowingContinuation { first = $0 }
        })
        let oldLoad = Task { await service.loadPollDetail(id: poll.id) }
        while first == nil { await Task.yield() }
        await service.loadMyPolls()
        first?.resume(returning: PollDetail(poll: poll, timeOptions: [], participants: [], responses: []))
        let stale = await oldLoad.value
        XCTAssertNil(stale)
        XCTAssertNil(try cache.fetchPollDetail(id: poll.id))
    }

}
