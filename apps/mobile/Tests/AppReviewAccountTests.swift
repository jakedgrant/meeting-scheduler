import Testing
@testable import Shared

@Suite("App Review account")
struct AppReviewAccountTests {
    @Test("Matches the review email however it is typed", arguments: [
        "appreview@meetful.app", "AppReview@Meetful.app", "  appreview@meetful.app\n",
    ])
    func matchesReviewEmail(_ email: String) {
        #expect(Config.isAppReviewAccount(email))
    }

    @Test("Doesn't ask anyone else for a password", arguments: [
        "", "appreview@meetful.ap", "appreview@meetful.app.example", "someone@meetful.app",
    ])
    func rejectsOtherEmails(_ email: String) {
        #expect(!Config.isAppReviewAccount(email))
    }
}
