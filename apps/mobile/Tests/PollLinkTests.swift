import Foundation
import Testing
@testable import Shared

@Suite("Poll links")
struct PollLinkTests {
    private static let id = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

    @Test("Opens the poll from its web page or the app's scheme", arguments: [
        "https://meetful.app/polls/3F2504E0-4F89-41D3-9A0C-0305E82C3301",
        "https://meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "https://MEETFUL.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "https://meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301?ref=qr#top",
        "meetingscheduler://polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
    ])
    func opensPoll(_ text: String) throws {
        let link = try #require(PollLink(url: URL(string: text)!))
        #expect(link.target == .poll(Self.id))
    }

    @Test("Code invitations resolve to confirmation, including lowercase codes", arguments: [
        "https://meetful.app/join/ABC123",
        "https://meetful.app/join/abc123",
        "https://MEETFUL.app/join/ABC123?ref=qr",
        "meetingscheduler://join/ABC123",
    ])
    func opensInvitation(_ text: String) throws {
        let link = try #require(PollLink(url: URL(string: text)!))
        #expect(link.target == .invitation("ABC123"))
    }

    @Test("Every new shared URL carries only its code")
    func shareURL() throws {
        let url = PollLink.shareURL(code: "abc123")
        #expect(url.absoluteString == "https://meetful.app/join/ABC123")
        #expect(PollLink(url: url)?.target == .invitation("ABC123"))
        #expect(url.query == nil)
    }

    @Test("Leaves every other URL alone", arguments: [
        "https://meetful.app/polls",
        "https://meetful.app/polls/new",
        "https://meetful.app/polls/not-a-uuid",
        "https://meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301/times/3f2504e0-4f89-41d3-9a0c-0305e82c3302",
        "https://meetful.app/join/ABCDE",
        "https://meetful.app/join/ABCDEFG",
        "https://meetful.app/join/ABC!23",
        "https://meetful.app/join/ABC123/extra",
        "https://meetful.app.example/join/ABC123",
        "https://user@meetful.app/join/ABC123",
        "http://meetful.app/join/ABC123",
        "https://meetful.app.example/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "https://www.meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "https://meetful.app:8443/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "https://someone@meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "http://meetful.app/polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "meetingscheduler://polls",
        "meetingscheduler://auth/callback?attempt=3f2504e0-4f89-41d3-9a0c-0305e82c3301&code=abc",
        "otherapp://polls/3f2504e0-4f89-41d3-9a0c-0305e82c3301",
    ])
    func ignoresOtherURLs(_ text: String) {
        #expect(PollLink(url: URL(string: text)!) == nil)
    }

    @Test("Leaves auth callbacks to the auth service")
    @MainActor
    func ignoresAuthCallbacks() {
        #expect(PollLink(url: AuthCallbackIntentStore.redirectURL(attempt: Self.id)) == nil)
    }
}
