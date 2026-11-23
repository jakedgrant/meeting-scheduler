import Foundation
import Testing
@testable import Shared

@Suite("Poll detail edits")
struct PollEditDraftTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func initializesFromSavedDetailsAndAllowsAnUnchangedExpiredDeadline() {
        let poll = Poll(creatorId: UUID(), title: "Saved", description: "Agenda", location: "Room",
                        closesAt: now.addingTimeInterval(-60))
        var draft = PollEditDraft(poll: poll)
        #expect(draft.title == poll.title)
        #expect(draft.description == "Agenda")
        #expect(draft.location == "Room")
        #expect(draft.closesAt == poll.closesAt)
        #expect(!draft.hasChanges)
        draft.title = "Edited"
        #expect(draft.hasChanges)
        #expect(draft.validationError(now: now) == nil)
        draft.closesAt = now
        #expect(draft.validationError(now: now) != nil)
        draft.closesAt = nil
        #expect(draft.validationError(now: now) == nil)
    }

    @Test func validatesServerFieldLimitsAndOptionalDetails() {
        var draft = PollEditDraft(poll: Poll(creatorId: UUID(), title: "Saved"))
        #expect(draft.description.isEmpty)
        #expect(draft.location.isEmpty)
        draft.title = " \n "
        #expect(draft.validationError(now: now) != nil)
        draft.title = String(repeating: "a", count: 201)
        #expect(draft.validationError(now: now) != nil)
        draft.title = String(repeating: "a", count: 200)
        draft.description = String(repeating: "a", count: 10_001)
        #expect(draft.validationError(now: now) != nil)
        draft.description = String(repeating: "a", count: 10_000)
        draft.location = String(repeating: "a", count: 1_001)
        #expect(draft.validationError(now: now) != nil)
        draft.location = String(repeating: "a", count: 1_000)
        #expect(draft.validationError(now: now) == nil)
    }
}
