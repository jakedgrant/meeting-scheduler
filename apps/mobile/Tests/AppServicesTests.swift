import MeetingSchedulerApp
import Supabase
import SwiftUI
import Synchronization
import XCTest

@testable import Shared

/// Records each API request's bearer token and fails it, so the tests observe which
/// account a service used without needing response fixtures.
private final class RecordingURLProtocol: URLProtocol {
    static let requests = Mutex<[(path: String, token: String?)]>([])

    static func tokens(forPathSuffix suffix: String) -> [String?] {
        requests.withLock { $0.filter { $0.path.hasSuffix(suffix) }.map(\.token) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        Self.requests.withLock { $0.append((request.url?.path ?? "", bearer)) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class AppServicesTests: XCTestCase {
    private final class Provider {
        var logins: [String] = []
        var logouts = 0
        var current = "anonymous"
    }

    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not settle", file: file, line: line)
    }

    func testIdentityTransitionsReachEveryAccountScopedServiceAndTransport() async throws {
        RecordingURLProtocol.requests.withLock { $0 = [] }
        let a = UUID()
        let b = UUID()
        let suite = "app-services-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "calendar.\(a.uuidString).appleEnabled")

        // The auth endpoint echoes the subject of whichever session is being installed.
        let signingIn = Mutex(a)
        let url = URL(string: "https://app-services.invalid")!
        let adapter = SessionAuthAdapter(
            url: url, key: "test-only", storage: LifecycleAuthStorage(),
            fetch: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                guard request.url?.path.hasSuffix("/user") == true else { return (Data("{}".utf8), response) }
                let user = User(
                    id: signingIn.withLock { $0 }, appMetadata: [:], userMetadata: [:], aud: "authenticated",
                    createdAt: Date(), updatedAt: Date())
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return (try encoder.encode(user), response)
            }, autoRefreshToken: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let supabase = SupabaseService(
            client: SupabaseService.apiClient(url: url, key: "test-only", transport: session), sessionAdapter: adapter)

        let provider = Provider()
        let purchases = PurchaseService(
            dependencies: .init(
                login: {
                    provider.logins.append($0)
                    provider.current = $0
                    return nil
                },
                logout: {
                    provider.logouts += 1
                    provider.current = "anonymous"
                }, currentUserId: { provider.current }, customerInfo: { nil }, offerings: { nil }))
        let services = AppServices(
            supabase: supabase, persistence: InMemoryPersistenceProvider(), preferences: preferences, purchases: purchases)
        await services.auth.initialize()
        XCTAssertFalse(services.auth.isLoading)
        XCTAssertNil(supabase.requestCredentials.accountId)

        let tokenA = unsignedAccessToken(for: a)
        _ = try await adapter.auth.setSession(accessToken: tokenA, refreshToken: "a")
        await settle { services.auth.currentUserId == a }
        XCTAssertEqual(supabase.requestCredentials.accountId, a)
        XCTAssertTrue(services.calendar.appleCalendarEnabled)
        await settle { provider.logins == [a.uuidString] }
        await settle { RecordingURLProtocol.tokens(forPathSuffix: "/calendar-connection") == [tokenA] }
        await services.polls.loadMyPolls()
        XCTAssertNotNil(services.polls.listLoadError)
        XCTAssertEqual(RecordingURLProtocol.tokens(forPathSuffix: "/rpc/list_poll_summaries"), [tokenA])

        signingIn.withLock { $0 = b }
        let revisionBeforeB = adapter.revision
        let tokenB = unsignedAccessToken(for: b)
        _ = try await adapter.auth.setSession(accessToken: tokenB, refreshToken: "b")
        await settle { services.auth.currentUserId == b }
        // Storing B's session advances the revision once; the identity fan-out must advance it again.
        XCTAssertGreaterThanOrEqual(adapter.revision, revisionBeforeB + 2)
        XCTAssertEqual(supabase.requestCredentials.accountId, b)
        XCTAssertFalse(services.calendar.appleCalendarEnabled)
        XCTAssertNil(services.polls.listLoadError)
        await settle { provider.logins == [a.uuidString, b.uuidString] }
        await settle { RecordingURLProtocol.tokens(forPathSuffix: "/calendar-connection").last == .some(tokenB) }

        try await services.auth.signOut()
        XCTAssertNil(services.auth.currentUserId)
        XCTAssertNil(supabase.requestCredentials.accountId)
        await settle { provider.logouts == 1 }
    }

    private func offlineServices(preferences: UserDefaults) -> AppServices {
        let url = URL(string: "https://app-services.invalid")!
        let adapter = SessionAuthAdapter(
            url: url, key: "test-only", storage: LifecycleAuthStorage(),
            fetch: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }, autoRefreshToken: false)
        return AppServices(
            supabase: SupabaseService(
                client: SupabaseService.apiClient(url: url, key: "test-only"), sessionAdapter: adapter),
            persistence: InMemoryPersistenceProvider(), preferences: preferences,
            purchases: PurchaseService(
                dependencies: .init(
                    login: { _ in nil }, logout: {}, currentUserId: { "anonymous" }, customerInfo: { nil },
                    offerings: { nil })))
    }

    func testAppServicesModifierBindsEveryServiceIntoTheEnvironment() throws {
        let suite = "app-services-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let services = offlineServices(preferences: preferences)

        var rendered: EnvironmentProbe.Values?
        let renderer = ImageRenderer(content: EnvironmentProbe { rendered = $0 }.appServices(services))
        _ = renderer.uiImage

        let values = try XCTUnwrap(rendered)
        XCTAssertTrue(values.auth === services.auth)
        XCTAssertTrue(values.polls === services.polls)
        XCTAssertTrue(values.calendar === services.calendar)
        XCTAssertTrue(values.purchases === services.purchases)
    }

    func testPreviewServicesBindsTheOverrideAndMocksForTheRest() throws {
        let auth = MockAuthService.signedIn

        var rendered: EnvironmentProbe.Values?
        let renderer = ImageRenderer(content: EnvironmentProbe { rendered = $0 }.previewServices(auth: auth))
        _ = renderer.uiImage

        let values = try XCTUnwrap(rendered)
        XCTAssertTrue(values.auth === auth)
        XCTAssertTrue(values.polls is MockPollService)
        XCTAssertTrue(values.calendar is MockCalendarService)
        XCTAssertTrue(values.purchases is MockPurchaseService)
    }

    /// Reading an unbound service traps, so this crashes the run if `AppRootView` stops binding.
    func testAppRootBindsServicesForTheViewsBelowIt() throws {
        let suite = "app-services-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let renderer = ImageRenderer(content: AppRootView(services: offlineServices(preferences: preferences)))
        _ = renderer.uiImage
    }
}

/// Reports the services a view actually receives once SwiftUI evaluates its body.
private struct EnvironmentProbe: View {
    struct Values {
        let auth: any AuthServiceProtocol
        let polls: any PollServiceProtocol
        let calendar: any CalendarServiceProtocol
        let purchases: any PurchaseServiceProtocol
    }

    @Environment(\.authService) private var auth
    @Environment(\.pollService) private var polls
    @Environment(\.calendarService) private var calendar
    @Environment(\.purchaseService) private var purchases
    let report: @MainActor (Values) -> Void

    var body: some View {
        let _ = report(Values(auth: auth, polls: polls, calendar: calendar, purchases: purchases))
        Color.clear.frame(width: 1, height: 1)
    }
}
