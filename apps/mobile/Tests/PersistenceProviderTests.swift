import XCTest
@testable import Shared

/// Tests both InMemoryPersistenceProvider and SwiftDataPersistenceProvider against
/// the same PersistenceProviderProtocol contract.
@MainActor
final class PersistenceProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeProviders() -> [any PersistenceProviderProtocol] {
        [
            InMemoryPersistenceProvider(),
            SwiftDataPersistenceProvider(inMemory: true),
        ]
    }

    private func makeSamplePoll(
        id: UUID = UUID(),
        creatorId: UUID = UUID(),
        title: String = "Test Poll",
        updatedAt: Date = Date()
    ) -> Poll {
        Poll(
            id: id,
            creatorId: creatorId,
            title: title,
            status: .active,
            updatedAt: updatedAt,
            shareCode: "ABC123"
        )
    }

    private func makeSampleProfile(id: UUID = UUID()) -> Profile {
        Profile(id: id, email: "test@example.com", displayName: "Test User")
    }

    // MARK: - Poll CRUD

    func testSaveAndFetchPolls() throws {
        for provider in makeProviders() {
            let poll = makeSamplePoll()
            try provider.savePolls([poll])
            let fetched = try provider.fetchAllPolls()
            XCTAssertEqual(fetched.count, 1)
            XCTAssertEqual(fetched.first?.id, poll.id)
            XCTAssertEqual(fetched.first?.title, "Test Poll")
        }
    }

    func testFetchPollById() throws {
        for provider in makeProviders() {
            let poll = makeSamplePoll()
            try provider.savePolls([poll])
            let fetched = try provider.fetchPoll(id: poll.id)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.id, poll.id)
        }
    }

    func testFetchPollByIdReturnsNilForMissing() throws {
        for provider in makeProviders() {
            let fetched = try provider.fetchPoll(id: UUID())
            XCTAssertNil(fetched)
        }
    }

    func testDeletePoll() throws {
        for provider in makeProviders() {
            let poll = makeSamplePoll()
            try provider.savePolls([poll])
            try provider.deletePoll(id: poll.id)
            let fetched = try provider.fetchPoll(id: poll.id)
            XCTAssertNil(fetched)
        }
    }

    // MARK: - Conflict Resolution (updatedAt)

    func testSavePollServerWinsWhenNewer() throws {
        for provider in makeProviders() {
            let id = UUID()
            let older = makeSamplePoll(id: id, title: "Old Title", updatedAt: Date(timeIntervalSince1970: 1000))
            let newer = makeSamplePoll(id: id, title: "New Title", updatedAt: Date(timeIntervalSince1970: 2000))

            try provider.savePolls([older])
            try provider.savePolls([newer])

            let fetched = try provider.fetchPoll(id: id)
            XCTAssertEqual(fetched?.title, "New Title")
        }
    }

    func testSavePollLocalPreservedWhenServerOlder() throws {
        for provider in makeProviders() {
            let id = UUID()
            let newer = makeSamplePoll(id: id, title: "Newer Title", updatedAt: Date(timeIntervalSince1970: 2000))
            let older = makeSamplePoll(id: id, title: "Older Title", updatedAt: Date(timeIntervalSince1970: 1000))

            try provider.savePolls([newer])
            try provider.savePolls([older])

            let fetched = try provider.fetchPoll(id: id)
            XCTAssertEqual(fetched?.title, "Newer Title")
        }
    }

    // MARK: - Poll Detail (composite)

    func testSaveAndFetchPollDetail() throws {
        for provider in makeProviders() {
            let pollId = UUID()
            let poll = makeSamplePoll(id: pollId)
            let timeOption = PollTimeOption(pollId: pollId, startTime: Date(), endTime: Date().addingTimeInterval(3600))
            let participant = PollParticipant(pollId: pollId, userId: UUID())
            let response = AvailabilityResponse(participantId: participant.id, timeOptionId: timeOption.id, status: .available)

            let detail = PollDetail(poll: poll, timeOptions: [timeOption], participants: [participant], responses: [response])
            try provider.savePollDetail(detail)

            let fetched = try provider.fetchPollDetail(id: pollId)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.poll.id, pollId)
            XCTAssertEqual(fetched?.timeOptions.count, 1)
            XCTAssertEqual(fetched?.participants.count, 1)
            XCTAssertEqual(fetched?.responses.count, 1)
        }
    }

    // MARK: - Poll Metadata

    func testSaveAndFetchParticipantCounts() throws {
        for provider in makeProviders() {
            let pollId = UUID()
            try provider.savePollParticipantCount(5, for: pollId)
            let counts = try provider.fetchPollParticipantCounts()
            XCTAssertEqual(counts[pollId], 5)
        }
    }

    func testSaveAndFetchTimeRanges() throws {
        for provider in makeProviders() {
            let pollId = UUID()
            let earliest = Date(timeIntervalSince1970: 1000)
            let latest = Date(timeIntervalSince1970: 2000)
            try provider.savePollTimeRange(earliest: earliest, latest: latest, for: pollId)
            let ranges = try provider.fetchPollTimeRanges()
            XCTAssertEqual(ranges[pollId]?.earliest, earliest)
            XCTAssertEqual(ranges[pollId]?.latest, latest)
        }
    }

    // MARK: - Time Options

    func testSaveAndFetchTimeOptions() throws {
        for provider in makeProviders() {
            let pollId = UUID()
            let poll = makeSamplePoll(id: pollId)
            try provider.savePolls([poll])

            let option = PollTimeOption(pollId: pollId, startTime: Date(), endTime: Date().addingTimeInterval(3600))
            try provider.saveTimeOptions([option], for: pollId)

            let fetched = try provider.fetchTimeOptions(for: pollId)
            XCTAssertEqual(fetched.count, 1)
            XCTAssertEqual(fetched.first?.id, option.id)
        }
    }

    // MARK: - Participants

    func testSaveAndFetchParticipants() throws {
        for provider in makeProviders() {
            let pollId = UUID()
            let poll = makeSamplePoll(id: pollId)
            try provider.savePolls([poll])

            let participant = PollParticipant(
                pollId: pollId,
                userId: UUID(),
                profiles: PollParticipant.ParticipantProfile(displayName: "Jane")
            )
            try provider.saveParticipants([participant], for: pollId)

            let fetched = try provider.fetchParticipants(for: pollId)
            XCTAssertEqual(fetched.count, 1)
            XCTAssertEqual(fetched.first?.displayName, "Jane")
        }
    }

    // MARK: - Availability Responses

    func testSaveAndFetchResponses() throws {
        for provider in makeProviders() {
            let participantId = UUID()
            let response = AvailabilityResponse(
                participantId: participantId,
                timeOptionId: UUID(),
                status: .available
            )
            try provider.saveResponses([response])

            let fetched = try provider.fetchResponses(for: [participantId])
            XCTAssertEqual(fetched.count, 1)
            XCTAssertEqual(fetched.first?.status, .available)
        }
    }

    func testFetchResponsesReturnsEmptyForNoIds() throws {
        for provider in makeProviders() {
            let fetched = try provider.fetchResponses(for: [])
            XCTAssertTrue(fetched.isEmpty)
        }
    }

    // MARK: - Profile

    func testSaveAndFetchProfile() throws {
        for provider in makeProviders() {
            let profile = makeSampleProfile()
            try provider.saveProfile(profile)

            let fetched = try provider.fetchProfile(id: profile.id)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.email, "test@example.com")
            XCTAssertEqual(fetched?.displayName, "Test User")
        }
    }

    func testProfileConflictResolution() throws {
        for provider in makeProviders() {
            let id = UUID()
            let older = Profile(id: id, email: "old@test.com", displayName: "Old", updatedAt: Date(timeIntervalSince1970: 1000))
            let newer = Profile(id: id, email: "new@test.com", displayName: "New", updatedAt: Date(timeIntervalSince1970: 2000))

            try provider.saveProfile(older)
            try provider.saveProfile(newer)

            let fetched = try provider.fetchProfile(id: id)
            XCTAssertEqual(fetched?.displayName, "New")
        }
    }

    // MARK: - Cache Management

    func testIsFreshReturnsFalseForUnknownId() {
        for provider in makeProviders() {
            XCTAssertFalse(provider.isFresh(UUID(), maxAge: 300))
        }
    }

    func testClearAll() throws {
        for provider in makeProviders() {
            let poll = makeSamplePoll()
            let profile = makeSampleProfile()
            try provider.savePolls([poll])
            try provider.saveProfile(profile)
            try provider.savePollParticipantCount(3, for: poll.id)

            try provider.clearAll()

            XCTAssertTrue(try provider.fetchAllPolls().isEmpty)
            XCTAssertNil(try provider.fetchProfile(id: profile.id))
            XCTAssertTrue(try provider.fetchPollParticipantCounts().isEmpty)
        }
    }
}
