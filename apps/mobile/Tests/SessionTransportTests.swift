import Supabase
import Synchronization
import XCTest

@testable import Shared

private final class LifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    static let waiting = Mutex<[LifecycleURLProtocol]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.waiting.withLock { $0.append(self) } }
    override func stopLoading() {}
    static func count(path: String, method: String? = nil) -> Int {
        waiting.withLock {
            $0.filter { $0.request.url?.path == path && (method == nil || $0.request.httpMethod == method) }.count
        }
    }
    static func reply(path: String, method: String? = nil, status: Int = 200, data: Data) {
        let item = waiting.withLock { items -> LifecycleURLProtocol in
            items.remove(
                at: items.firstIndex { $0.request.url?.path == path && (method == nil || $0.request.httpMethod == method) }!)
        }
        let response = HTTPURLResponse(
            url: item.request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
        item.client?.urlProtocol(item, didLoad: data)
        item.client?.urlProtocolDidFinishLoading(item)
    }
}

final class LifecycleAuthStorage: AuthLocalStorage, Sendable {
    let values = Mutex<[String: Data]>([:])
    let rejectRemoval = Mutex(false)
    func store(key: String, value: Data) throws { values.withLock { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { values.withLock { $0[key] } }
    func remove(key: String) throws {
        if rejectRemoval.withLock({ $0 }) { throw URLError(.cannotRemoveFile) }
        values.withLock { $0.removeValue(forKey: key) }
    }
}

@MainActor
private final class AdaptationGate {
    var waiting: [CheckedContinuation<Void, Never>] = []
    func pause() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.removeFirst().resume() }
}

@MainActor
final class SessionTransportTests: XCTestCase {
    private func client() -> SupabaseClient {
        LifecycleURLProtocol.waiting.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        return SupabaseClient(
            supabaseURL: URL(string: "https://session-transport.invalid")!, supabaseKey: "test-only",
            options: .init(
                auth: .init(storage: LifecycleAuthStorage(), autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))))
    }
    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<5000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Transport checkpoint not reached", file: file, line: line)
    }
    private func signIn(_ id: UUID, client: SupabaseClient) async throws {
        try await signIn(id, auth: client.auth)
    }
    private func signIn(_ id: UUID, auth: AuthClient) async throws {
        let user = User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let token =
            "e30."
            + Data("{\"exp\":4102444800,\"sub\":\"\(id.uuidString)\",\"session_id\":\"\(UUID())\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".signature"
        let task = Task { try await auth.setSession(accessToken: token, refreshToken: id.uuidString) }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/user", method: "GET") == 1 }
        LifecycleURLProtocol.reply(path: "/auth/v1/user", method: "GET", data: try encoder.encode(user))
        _ = try await task.value
    }

    func testQueuedCommandsCaptureACredentialsBeforeSDKTokenResolution() async throws {
        for returningToA in [false, true] {
            for command in ["create", "save", "status", "join"] {
                LifecycleURLProtocol.waiting.withLock { $0 = [] }
                let gate = AdaptationGate()
                let a = UUID()
                let b = UUID()
                let poll = UUID()
                var account: UUID? = a
                var credentials = AccountRequestCredentials(accountId: a, generation: 1, accessToken: "A-original")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [LifecycleURLProtocol.self]
                let api = SupabaseService.apiClient(
                    url: URL(string: "https://session-transport.invalid")!, key: "test-only",
                    transport: URLSession(configuration: configuration), beforeToken: { await gate.pause() })
                let service = PollService(
                    persistence: InMemoryPersistenceProvider(), currentUserId: { account }, client: api,
                    requestCredentials: { credentials })
                let task = Task {
                    switch command {
                    case "create":
                        _ = try await service.createPoll(
                            CreatePollRequest(
                                payload: PollCreationPayload(
                                    title: "A draft", timezone: "UTC",
                                    timeOptions: [
                                        PollCreationOption(
                                            startTime: Date(), endTime: Date().addingTimeInterval(3600), isAllDay: false)
                                    ])))
                    case "save":
                        _ = try await service.saveAvailability(
                            SaveAvailabilityRequest(
                                pollId: poll, responses: [], comment: "A comment", expectedVersion: 1, participantId: UUID()))
                    case "join": _ = try await service.joinPoll(pollId: poll, anonymousName: nil)
                    default: try await service.updatePollStatus(pollId: poll, status: .closed)
                    }
                }
                await settle { gate.waiting.count == 1 }
                account = b
                service.accountDidChange(to: b)
                credentials = AccountRequestCredentials(accountId: b, generation: 2, accessToken: "B-current")
                if returningToA {
                    account = nil
                    service.accountDidChange(to: nil)
                    account = a
                    service.accountDidChange(to: a)
                    credentials = AccountRequestCredentials(accountId: a, generation: 4, accessToken: "A-new-session")
                }
                gate.release()
                await settle { LifecycleURLProtocol.waiting.withLock { $0.count == 1 } }
                let request = LifecycleURLProtocol.waiting.withLock { $0[0].request }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A-original", command)
                XCTAssertEqual(request.allHTTPHeaderFields?.filter { $0.key.lowercased() == "authorization" }.count, 1)
                LifecycleURLProtocol.reply(
                    path: request.url!.path, status: 400,
                    data: Data("{\"code\":\"42501\",\"message\":\"rejected\"}".utf8))
                do {
                    try await task.value
                    XCTFail("Old command must not publish")
                } catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    func testQueuedBodyOnlyCalendarDisconnectCannotAcquireBCredentials() async {
        LifecycleURLProtocol.waiting.withLock { $0 = [] }
        let gate = AdaptationGate()
        let a = UUID()
        let b = UUID()
        var credentials = AccountRequestCredentials(accountId: a, generation: 1, accessToken: "A-original")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let api = SupabaseService.apiClient(
            url: URL(string: "https://session-transport.invalid")!, key: "test-only",
            transport: URLSession(configuration: configuration), beforeToken: { await gate.pause() })
        let suite = "calendar-queued-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = CalendarService(preferences: preferences, clientFactory: { api }, requestCredentials: { credentials })
        service.accountDidChange(to: a)
        let old = Task { await service.setGoogleCalendarEnabled(false) }
        await settle { gate.waiting.count == 1 }
        service.accountDidChange(to: b)
        credentials = AccountRequestCredentials(accountId: b, generation: 2, accessToken: "B-current")
        gate.release()
        await settle { LifecycleURLProtocol.waiting.withLock { $0.count == 1 } }
        let request = LifecycleURLProtocol.waiting.withLock { $0[0].request }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A-original")
        XCTAssertEqual(request.allHTTPHeaderFields?.filter { $0.key.lowercased() == "authorization" }.count, 1)
        LifecycleURLProtocol.reply(
            path: request.url!.path,
            data: Data("{\"connected\":false,\"accountEmail\":null,\"requiresReconnect\":false,\"revocationPending\":false}".utf8)
        )
        await old.value
        XCTAssertFalse(service.googleCalendarLoading)
        XCTAssertNil(service.googleCalendarError)
    }

    func testPinnedSDKDelayedRemoteLogoutCannotEraseNewSessionOnSuccessOrFailure() async throws {
        for returnsToA in [false, true] {
            for fails in [false, true] {
                let sdk = client()
                let a = UUID()
                let b = returnsToA ? a : UUID()
                var dependencies = AuthService.Dependencies.live(client: sdk)
                dependencies.accountChanged = { _ in }
                dependencies.refreshCalendar = {}
                dependencies.refreshProviderIdentity = {}
                dependencies.loadProfile = { Profile(id: $0, email: "test@example.invalid", timezone: "UTC") }
                let service = AuthService(persistence: InMemoryPersistenceProvider(), dependencies: dependencies, client: sdk)
                await service.initialize()
                try await signIn(a, client: sdk)
                await settle { service.currentUserId == a }
                let originalToken = sdk.auth.currentSession?.accessToken
                let logout = Task { try? await service.signOut() }
                await settle { LifecycleURLProtocol.count(path: "/auth/v1/logout") == 1 }
                let query = LifecycleURLProtocol.waiting.withLock { $0.first!.request.url!.query }
                XCTAssertEqual(query, "scope=local")
                let header = LifecycleURLProtocol.waiting.withLock {
                    $0.first!.request.value(forHTTPHeaderField: "Authorization")
                }
                XCTAssertEqual(header, "Bearer " + originalToken!)
                XCTAssertNil(sdk.auth.currentUser)
                XCTAssertNil(service.currentUserId)
                try await signIn(b, client: sdk)
                await settle { service.currentUserId == b }
                LifecycleURLProtocol.reply(
                    path: "/auth/v1/logout", status: fails ? 400 : 204,
                    data: fails ? Data("{\"msg\":\"offline logout\"}".utf8) : Data())
                await logout.value
                XCTAssertEqual(sdk.auth.currentUser?.id, b)
                XCTAssertEqual(service.currentUserId, b)
                service.dispose()
            }
        }
    }

    func testPinnedSDKRefreshRaceIsFencedBeforeCredentialStorageAndAPIRequests() async throws {
        for protected in [false, true] {
            let sdk = client()
            let a = UUID()
            let b = UUID()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LifecycleURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            let adapter = SessionAuthAdapter(
                url: URL(string: "https://session-transport.invalid")!, key: "test-only",
                storage: LifecycleAuthStorage(), fetch: { try await transport.data(for: $0) }, autoRefreshToken: false)
            let auth = protected ? adapter.auth : sdk.auth
            try await signIn(a, auth: auth)
            let refresh = Task { try? await auth.refreshSession() }
            await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 1 }
            try await signIn(b, auth: auth)
            let old = Session(
                accessToken: "old-A-refreshed", tokenType: "bearer", expiresIn: 3600,
                expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: "old-A-refresh",
                user: User(id: a, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            LifecycleURLProtocol.reply(path: "/auth/v1/token", data: try encoder.encode(old))
            _ = await refresh.value
            // Demonstrates the pinned SDK defect, then the production adapter fix.
            XCTAssertEqual(auth.currentUser?.id, protected ? b : a)
            if protected {
                let api = SupabaseClient(
                    supabaseURL: URL(string: "https://session-transport.invalid")!, supabaseKey: "test-only",
                    options: .init(
                        auth: .init(autoRefreshToken: false, accessToken: { auth.currentSession?.accessToken }),
                        global: .init(session: transport)))
                let request = Task { _ = try await api.from("profiles").select().execute() }
                await settle { LifecycleURLProtocol.count(path: "/rest/v1/profiles") == 1 }
                let token = LifecycleURLProtocol.waiting.withLock { $0.first!.request.value(forHTTPHeaderField: "Authorization") }
                XCTAssertEqual(token, "Bearer \(auth.currentSession!.accessToken)")
                LifecycleURLProtocol.reply(path: "/rest/v1/profiles", data: Data("[]".utf8))
                _ = try await request.value
            }
        }
    }

    private func adapter() -> SessionAuthAdapter {
        LifecycleURLProtocol.waiting.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        return SessionAuthAdapter(
            url: URL(string: "https://session-transport.invalid")!, key: "test-only",
            storage: LifecycleAuthStorage(), fetch: { try await transport.data(for: $0) }, autoRefreshToken: false)
    }
    private func wireSession(_ id: UUID, token: String) throws -> Data {
        let user = User(id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
        let session = Session(
            accessToken: token, tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: token + "-refresh", user: user)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(session)
    }

    func testNativeIDTokenAndUserUpdateLateSuccessAndFailureCannotInstallAOverB() async throws {
        for native in [true, false] {
            for fails in [false, true] {
                let adapter = adapter()
                let a = UUID()
                let b = UUID()
                try await signIn(a, auth: adapter.auth)
                let revision = adapter.revision
                let pending = Task {
                    try await AuthAttemptContext.$revision.withValue(revision) {
                        if native {
                            _ = try await adapter.auth.signInWithIdToken(
                                credentials: .init(provider: .apple, idToken: "test-only", nonce: "nonce"))
                        } else {
                            _ = try await adapter.auth.update(user: .init(data: ["name": .string("A name")]))
                        }
                    }
                }
                let path = native ? "/auth/v1/token" : "/auth/v1/user"
                await settle { LifecycleURLProtocol.count(path: path, method: native ? "POST" : "PUT") == 1 }
                try await signIn(b, auth: adapter.auth)
                let data: Data
                if native {
                    data = try wireSession(a, token: "obsolete-A")
                } else {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    data = try encoder.encode(
                        User(
                            id: a, appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date()
                        ))
                }
                LifecycleURLProtocol.reply(
                    path: path, method: native ? "POST" : "PUT", status: fails ? 400 : 200,
                    data: fails ? Data("{\"msg\":\"expired\"}".utf8) : data)
                do {
                    try await pending.value
                    XCTFail("Obsolete auth request should fail")
                } catch {}
                XCTAssertEqual(adapter.auth.currentUser?.id, b)
            }
        }
    }

    func testOAuthBrowserResultKeepsOriginalAttemptOwnershipBeforePKCEExchange() async throws {
        let adapter = adapter()
        let a = UUID()
        let b = UUID()
        let browser = AdaptationGate()
        try await signIn(a, auth: adapter.auth)
        let revision = adapter.revision
        let pending = Task {
            try await AuthAttemptContext.$revision.withValue(revision) {
                try await adapter.auth.signInWithOAuth(
                    provider: .google, redirectTo: URL(string: "meetingscheduler://auth/callback")
                ) { _ in
                    await browser.pause()
                    return URL(string: "meetingscheduler://auth/callback?code=old-A-code")!
                }
            }
        }
        await settle { browser.waiting.count == 1 }
        try await signIn(b, auth: adapter.auth)
        browser.release()
        do {
            _ = try await pending.value
            XCTFail("Old browser completion must be rejected")
        } catch {}
        XCTAssertEqual(LifecycleURLProtocol.count(path: "/auth/v1/token"), 0)
        XCTAssertEqual(adapter.auth.currentUser?.id, b)
    }

    func testColdCallbackRestoresOwnedIntentAndRejectsDuplicateAndObsoleteLink() async throws {
        let adapter = adapter()
        let sdk = client()
        _ = try adapter.auth.getOAuthSignInURL(provider: .google, redirectTo: URL(string: "meetingscheduler://auth/callback"))
        let suite = "callback-cold-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AuthCallbackIntentStore(defaults: defaults).begin(session: nil)
        var dependencies = AuthService.Dependencies.live(client: sdk, auth: adapter.auth)
        dependencies.accountChanged = { _ in adapter.accountDidChange() }
        dependencies.authRevision = { adapter.revision }
        dependencies.refreshCalendar = {}
        dependencies.refreshProviderIdentity = {}
        dependencies.loadProfile = { Profile(id: $0, email: "test@example.invalid") }
        dependencies.callbackIntents = AuthCallbackIntentStore(defaults: defaults)
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(), dependencies: dependencies, client: sdk, auth: adapter.auth)
        let link = URL(string: "meetingscheduler://auth/callback?code=cold-code")!
        let callback = Task { await service.handleDeepLink(url: link) }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 1 }
        let a = UUID()
        LifecycleURLProtocol.reply(path: "/auth/v1/token", data: try wireSession(a, token: "cold-A"))
        await callback.value
        await settle { service.currentUserId == a }
        await service.handleDeepLink(url: link)
        XCTAssertEqual(LifecycleURLProtocol.count(path: "/auth/v1/token"), 0)
        dependencies.callbackIntents?.begin(session: adapter.auth.currentSession)
        let b = UUID()
        try await signIn(b, auth: adapter.auth)
        await settle { service.currentUserId == b }
        await service.handleDeepLink(url: link)
        XCTAssertEqual(LifecycleURLProtocol.count(path: "/auth/v1/token"), 0)
        XCTAssertEqual(adapter.auth.currentUser?.id, b)
        service.dispose()
    }

    func testOrdinarySDKRefreshKeepsSessionBoundaryWhileReauthenticationAdvancesIt() async throws {
        let adapter = adapter()
        let sdk = client()
        let a = UUID()
        try await signIn(a, auth: adapter.auth)
        var dependencies = AuthService.Dependencies.live(client: sdk, auth: adapter.auth)
        dependencies.accountChanged = { _ in adapter.accountDidChange() }
        dependencies.authRevision = { adapter.revision }
        dependencies.refreshCalendar = {}
        dependencies.refreshProviderIdentity = {}
        dependencies.loadProfile = { Profile(id: $0, email: "test@example.invalid") }
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(), dependencies: dependencies, client: sdk, auth: adapter.auth)
        await service.initialize()
        await settle { service.currentUserId == a }
        let generation = service.sessionGeneration
        let revision = adapter.revision
        var refreshed = adapter.auth.currentSession!
        refreshed.accessToken += ".refreshed"  // same stable session_id in JWT payload
        refreshed.refreshToken = "rotated"
        let pending = Task { try await adapter.auth.refreshSession() }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 1 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        LifecycleURLProtocol.reply(path: "/auth/v1/token", data: try encoder.encode(refreshed))
        _ = try await pending.value
        await settle { service.currentSession?.accessToken == refreshed.accessToken }
        XCTAssertEqual(adapter.revision, revision)
        XCTAssertEqual(service.sessionGeneration, generation)
        try await signIn(a, auth: adapter.auth)  // new session_id, same account
        await settle { service.sessionGeneration > generation }
        XCTAssertEqual(service.currentUserId, a)
        service.dispose()
    }

    func testOldCallbackCleanupCannotClearOrBlockANewerAttempt() async throws {
        let adapter = adapter()
        let sdk = client()
        let a = UUID()
        let b = UUID()
        try await signIn(a, auth: adapter.auth)
        let suite = "callback-cleanup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let intents = AuthCallbackIntentStore(defaults: defaults)
        var dependencies = AuthService.Dependencies.live(client: sdk, auth: adapter.auth)
        dependencies.accountChanged = { _ in adapter.accountDidChange() }
        dependencies.authRevision = { adapter.revision }
        dependencies.callbackIntents = intents
        dependencies.refreshCalendar = {}
        dependencies.refreshProviderIdentity = {}
        dependencies.loadProfile = { Profile(id: $0, email: "test@example.invalid") }
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(), dependencies: dependencies, client: sdk, auth: adapter.auth)
        await service.initialize()
        intents.begin(session: adapter.auth.currentSession)
        let url = URL(string: "meetingscheduler://auth/callback?code=old")!
        let old = Task { await service.handleDeepLink(url: url) }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 1 }
        try await signIn(b, auth: adapter.auth)
        await settle { service.currentUserId == b }
        intents.begin(session: adapter.auth.currentSession)
        let current = Task { await service.handleDeepLink(url: url) }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 2 }
        LifecycleURLProtocol.reply(path: "/auth/v1/token", status: 400, data: Data("{\"msg\":\"expired\"}".utf8))
        await old.value
        intents.begin(session: adapter.auth.currentSession)
        await service.handleDeepLink(url: url)  // duplicate while the current attempt is in flight
        XCTAssertEqual(LifecycleURLProtocol.count(path: "/auth/v1/token"), 1)
        LifecycleURLProtocol.reply(path: "/auth/v1/token", data: try wireSession(b, token: "current-B"))
        await current.value
        XCTAssertEqual(adapter.auth.currentUser?.id, b)
        service.dispose()
    }

    func testProfileEditCancelsOlderSameAccountReadBeforeItCanRestoreCachedValues() async throws {
        let sdk = client()
        let a = UUID()
        let read = AdaptationGate()
        try await signIn(a, client: sdk)
        let initial = sdk.auth.currentSession!
        let (events, _) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { events }, restore: { initial },
                loadProfile: { id in
                    await read.pause()
                    return Profile(id: id, email: "test@example.invalid", displayName: "old")
                }, signOut: {}, accountChanged: { _ in }, refreshCalendar: {}), client: sdk)
        await service.initialize()
        await settle { read.waiting.count == 1 }
        let update = Task { try await service.updateProfile(displayName: "new", avatarUrl: nil, timezone: nil) }
        await settle { LifecycleURLProtocol.count(path: "/rest/v1/profiles") == 1 }
        let changed = Profile(id: a, email: "test@example.invalid", displayName: "new")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        LifecycleURLProtocol.reply(path: "/rest/v1/profiles", data: try encoder.encode(changed))
        try await update.value
        XCTAssertEqual(service.profile?.displayName, "new")
        read.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.profile?.displayName, "new")
        service.dispose()
    }

    func testOwnedLogoutPreservesNewStorageAtRemoveGapAndRevokesOnlyCapturedLocalSession() async throws {
        for fails in [false, true] {
            let adapter = adapter()
            let a = UUID()
            let b = UUID()
            try await signIn(a, auth: adapter.auth)
            let original = adapter.auth.currentSession!
            let revision = adapter.revision
            try await signIn(b, auth: adapter.auth)  // new SDK write wins before old remove enters
            let pending = Task { try await adapter.signOut(session: original, revision: revision) }
            await settle { LifecycleURLProtocol.count(path: "/auth/v1/logout") == 1 }
            let request = LifecycleURLProtocol.waiting.withLock { $0.first!.request }
            XCTAssertEqual(request.url?.query, "scope=local")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + original.accessToken)
            XCTAssertEqual(adapter.auth.currentUser?.id, b)
            LifecycleURLProtocol.reply(path: "/auth/v1/logout", status: fails ? 400 : 204, data: Data())
            _ = try? await pending.value
            XCTAssertEqual(adapter.auth.currentUser?.id, b)
        }
    }

    func testProductionSDKObserverRejectsSignedOutWhenSDKStorageStillBelongsToB() async throws {
        LifecycleURLProtocol.waiting.withLock { $0 = [] }
        let storage = LifecycleAuthStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let sdk = SupabaseClient(
            supabaseURL: URL(string: "https://session-transport.invalid")!, supabaseKey: "test-only",
            options: .init(
                auth: .init(storage: storage, autoRefreshToken: false),
                global: .init(session: URLSession(configuration: configuration))))
        let b = UUID()
        try await signIn(b, client: sdk)
        var dependencies = AuthService.Dependencies.live(client: sdk)
        dependencies.accountChanged = { _ in }
        dependencies.refreshCalendar = {}
        dependencies.refreshProviderIdentity = {}
        dependencies.loadProfile = { Profile(id: $0, email: "test@example.invalid") }
        let service = AuthService(persistence: InMemoryPersistenceProvider(), dependencies: dependencies, client: sdk)
        await service.initialize()
        XCTAssertEqual(service.currentUserId, b)
        storage.rejectRemoval.withLock { $0 = true }
        let pending = Task { try await sdk.auth.signOut(scope: .local) }  // pinned SDK swallows remove error and emits nil
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/logout") == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.currentUserId, b)
        LifecycleURLProtocol.reply(path: "/auth/v1/logout", status: 204, data: Data())
        try await pending.value
        XCTAssertEqual(service.currentUserId, b)
        service.dispose()
    }

    func testRefreshAcrossLogoutAndReturnToACannotReplaceNewCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        let adapter = SessionAuthAdapter(
            url: URL(string: "https://session-transport.invalid")!, key: "test-only",
            storage: LifecycleAuthStorage(), fetch: { try await transport.data(for: $0) }, autoRefreshToken: false)
        let a = UUID()
        try await signIn(a, auth: adapter.auth)
        let refresh = Task { try? await adapter.auth.refreshSession() }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/token") == 1 }
        let logout = Task { try await adapter.auth.signOut(scope: .local) }
        await settle { LifecycleURLProtocol.count(path: "/auth/v1/logout") == 1 }
        LifecycleURLProtocol.reply(path: "/auth/v1/logout", status: 204, data: Data())
        try await logout.value
        try await signIn(a, auth: adapter.auth)
        let currentToken = adapter.auth.currentSession!.accessToken
        let old = Session(
            accessToken: "old-A-after-logout", tokenType: "bearer", expiresIn: 3600,
            expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: "obsolete",
            user: adapter.auth.currentUser!)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        LifecycleURLProtocol.reply(path: "/auth/v1/token", data: try encoder.encode(old))
        _ = await refresh.value
        XCTAssertEqual(adapter.auth.currentSession?.accessToken, currentToken)
    }

    func testRefreshStorageCommitAtomicallyRejectsBoundaryAfterTransportReturns() throws {
        let storage = RevisionedAuthStorage(LifecycleAuthStorage())
        let user = User(
            id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated", createdAt: Date(), updatedAt: Date())
        let session = Session(
            accessToken: "A-token", tokenType: "bearer", expiresIn: 3600, expiresAt: 4_102_444_800, refreshToken: "A-refresh",
            user: user)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let a = try encoder.encode(session)
        let b = Data("{\"accessToken\":\"B-token\",\"refreshToken\":\"B-refresh\"}".utf8)
        storage.authorizeRefresh(data: a, revision: storage.revision)
        try storage.store(key: "session", value: b)
        storage.advance()
        XCTAssertThrowsError(try storage.store(key: "session", value: a))
        XCTAssertEqual(try storage.retrieve(key: "session"), b)
    }

    func testCalendarStatusSuccessAndFailureCannotOverwriteReplacementOrReturningAccount() async {
        for failure in [false, true] {
            let sdk = client()
            let a = UUID()
            let b = UUID()
            let suite = "calendar-transport-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = CalendarService(preferences: defaults, client: sdk)
            service.accountDidChange(to: a)
            let old = Task { await service.refreshGoogleCalendarConnection() }
            await settle { LifecycleURLProtocol.count(path: "/functions/v1/calendar-connection") == 1 }
            service.accountDidChange(to: b)
            service.accountDidChange(to: a)
            LifecycleURLProtocol.reply(
                path: "/functions/v1/calendar-connection", status: failure ? 400 : 200,
                data: failure
                    ? Data("{}".utf8)
                    : Data(
                        "{\"connected\":true,\"accountEmail\":\"old@example.invalid\",\"requiresReconnect\":false,\"revocationPending\":false}"
                            .utf8))
            await old.value
            XCTAssertFalse(service.googleCalendarEnabled)
            XCTAssertNil(service.googleCalendarAccountEmail)
            XCTAssertNil(service.googleCalendarError)
        }
    }
}
