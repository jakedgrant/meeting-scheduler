import Auth
import AuthenticationServices
import CryptoKit
import Foundation
import Supabase

@MainActor
@Observable
public final class AuthService: NSObject, AuthServiceProtocol {
    public static let shared = AuthService()

    public private(set) var currentUser: User?
    public private(set) var currentSession: Session?
    public private(set) var profile: Profile?
    public private(set) var isLoading = true

    public var isAuthenticated: Bool {
        currentUser != nil
    }

    public var currentUserId: UUID? { currentUser?.id }
    public var currentUserEmail: String? { currentUser?.email }

    private let clientFactory: @MainActor () -> SupabaseClient
    private var supabase: SupabaseClient { clientFactory() }
    private let auth: AuthClient
    private let dependencies: Dependencies
    private let persistence: any PersistenceProviderProtocol
    public private(set) var sessionGeneration: UInt64 = 0
    private var authEventRevision: UInt64 = 0
    private var observerTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var initialized = false
    private var expiryTask: Task<Void, Never>?
    private var currentNonce: String?
    private var appleController: ASAuthorizationController?
    private var appleAttemptGeneration: UInt64?
    private let authBrowser = OAuthBrowserSession(errorMapper: { error in
        if case .cancelled = error { return CancellationError() }
        return AuthError.browserSignInFailed
    })
    private var callbackAttemptId: UUID?
    private var observedAuthRevision: UInt64?
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []
    private var appleSignInContinuation: CheckedContinuation<AppleCredentials, Error>?
    private var appleOperationId: UUID?

    struct AppleCredentials: Sendable {
        var identityToken: String
        var nonce: String
        var displayName: String?
    }

    /// Inject the same boundaries used by the application, including observer disposal.
    struct Dependencies {
        var events: @MainActor () -> AsyncStream<(event: AuthChangeEvent, session: Session?)>
        var restore: @MainActor () async throws -> Session
        var loadProfile: @MainActor (UUID) async throws -> Profile
        var signOut: @MainActor () async throws -> Void
        var accountChanged: @MainActor (UUID?) -> Void
        var refreshCalendar: @MainActor () async -> Void
        var refreshProviderIdentity: @MainActor () -> Void = {}
        var sessionAccepted: @MainActor (Session?) -> Void = { _ in }
        var authRevision: @MainActor () -> UInt64? = { nil }
        var invalidateAuthAttempts: @MainActor () -> Void = {}
        var signOutSession: (@MainActor (Session?, UInt64?) async throws -> Void)?
        var callbackIntents: AuthCallbackIntentStore?
        var beginAuthAttempt: @MainActor (UUID) -> Void = { _ in }
        var endAuthAttempt: @MainActor (UUID) -> Void = { _ in }
        var launchOAuth: (@MainActor (URL) async throws -> URL)?
        var launchApple: (@MainActor () async throws -> AppleCredentials)?
        var isStoredSession: @MainActor (Session?) -> Bool = { _ in true }
        var now: @MainActor () -> Date = { Date() }
        var waitForExpiry: @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }

        static func live(
            client: SupabaseClient, auth suppliedAuth: AuthClient? = nil, clientFactory: (@MainActor () -> SupabaseClient)? = nil
        ) -> Self {
            let auth = suppliedAuth ?? client.auth
            return Self(
                events: {
                    AsyncStream { continuation in
                        let task = Task {
                            for await (event, session) in auth.authStateChanges {
                                // Rejected refresh storage can still cause the pinned
                                // SDK to emit its old response. Only stored credentials
                                // may become the application's current refresh session.
                                if session != auth.currentSession { continue }
                                continuation.yield((event, session))
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                },
                restore: {
                    let session = try await auth.session
                    guard session == auth.currentSession else { throw CancellationError() }
                    return session
                },
                loadProfile: { id in
                    try await (clientFactory?() ?? client).from("profiles").select().eq("id", value: id.uuidString).single()
                        .execute().value
                }, signOut: { try await auth.signOut(scope: .local) },
                accountChanged: { id in
                    SupabaseService.shared.sessionAdapter.accountDidChange()
                    PollService.shared.accountDidChange(to: id)
                    CalendarService.shared.accountDidChange(to: id)
                    PurchaseService.shared.resetAccountState(userId: id?.uuidString)
                }, refreshCalendar: { await CalendarService.shared.refreshGoogleCalendarConnection() },
                refreshProviderIdentity: { PurchaseService.shared.retryAccountIdentity() },
                isStoredSession: { $0 == auth.currentSession })
        }
    }

    private override init() {
        let client = SupabaseService.shared.client
        self.clientFactory = { SupabaseService.shared.client }
        self.auth = SupabaseService.shared.sessionAdapter.auth
        var dependencies = Dependencies.live(client: client, auth: auth, clientFactory: { SupabaseService.shared.client })
        dependencies.sessionAccepted = { SupabaseService.shared.acceptSession($0) }
        dependencies.authRevision = { SupabaseService.shared.sessionAdapter.revision }
        dependencies.invalidateAuthAttempts = { SupabaseService.shared.sessionAdapter.accountDidChange() }
        dependencies.signOutSession = { session, revision in
            let adapter = SupabaseService.shared.sessionAdapter
            try await adapter.signOut(session: session, revision: revision ?? adapter.revision)
        }
        dependencies.callbackIntents = AuthCallbackIntentStore(defaults: .standard)
        dependencies.beginAuthAttempt = { SupabaseService.shared.sessionAdapter.beginAuthAttempt($0) }
        dependencies.endAuthAttempt = { SupabaseService.shared.sessionAdapter.endAuthAttempt($0) }
        dependencies.launchOAuth = { [authBrowser] in try await authBrowser.authenticate(url: $0) }
        self.dependencies = dependencies
        self.persistence = AccountPersistence.shared
        super.init()
        Task { await initialize() }
    }

    public init(persistence: any PersistenceProviderProtocol) {
        let client = SupabaseService.shared.client
        self.clientFactory = { SupabaseService.shared.client }
        self.auth = SupabaseService.shared.sessionAdapter.auth
        var dependencies = Dependencies.live(client: client, auth: auth, clientFactory: { SupabaseService.shared.client })
        dependencies.sessionAccepted = { SupabaseService.shared.acceptSession($0) }
        dependencies.authRevision = { SupabaseService.shared.sessionAdapter.revision }
        dependencies.invalidateAuthAttempts = { SupabaseService.shared.sessionAdapter.accountDidChange() }
        dependencies.signOutSession = { session, revision in
            let adapter = SupabaseService.shared.sessionAdapter
            try await adapter.signOut(session: session, revision: revision ?? adapter.revision)
        }
        dependencies.callbackIntents = AuthCallbackIntentStore(defaults: .standard)
        dependencies.beginAuthAttempt = { SupabaseService.shared.sessionAdapter.beginAuthAttempt($0) }
        dependencies.endAuthAttempt = { SupabaseService.shared.sessionAdapter.endAuthAttempt($0) }
        dependencies.launchOAuth = { [authBrowser] in try await authBrowser.authenticate(url: $0) }
        self.dependencies = dependencies
        self.persistence = persistence
        super.init()
    }

    init(
        persistence: any PersistenceProviderProtocol, dependencies: Dependencies, client: SupabaseClient, auth: AuthClient? = nil
    ) {
        self.persistence = persistence
        self.dependencies = dependencies
        self.clientFactory = { client }
        self.auth = auth ?? client.auth
        super.init()
    }

    isolated deinit {
        observerTask?.cancel()
        profileTask?.cancel()
        calendarTask?.cancel()
        expiryTask?.cancel()
        authBrowser.cancel()
    }

    public func initialize() async {
        if initialized {
            if isLoading { await withCheckedContinuation { initializationWaiters.append($0) } }
            return
        }
        initialized = true
        let revision = authEventRevision
        let events = dependencies.events()
        observerTask = Task { [weak self] in
            for await (event, session) in events {
                guard !Task.isCancelled, let self else { return }
                self.authEventRevision &+= 1
                self.handleAuthChange(event: event, session: session)
                self.finishInitialization()
            }
        }
        do {
            let session = try await dependencies.restore()
            guard initialized, revision == authEventRevision else { return }
            handleAuthChange(event: .initialSession, session: session)
        } catch {
            guard initialized, revision == authEventRevision else { return }
            applySession(nil)
        }
        finishInitialization()
    }

    private func finishInitialization() {
        isLoading = false
        let waiters = initializationWaiters
        initializationWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Stops the owned stream and invalidates work even if cancellation is ignored.
    public func dispose() {
        initialized = false
        authEventRevision &+= 1
        observerTask?.cancel()
        observerTask = nil
        dependencies.invalidateAuthAttempts()
        dependencies.callbackIntents?.clear()
        callbackAttemptId = nil
        authBrowser.cancel()
        profileTask?.cancel()
        calendarTask?.cancel()
        applySession(nil)
        finishInitialization()
    }

    private func handleAuthChange(event: AuthChangeEvent, session: Session?) {
        guard dependencies.isStoredSession(session) else { return }
        if currentUserId != nil, currentUserId == session?.user.id,
            let previous = observedAuthRevision, let revision = dependencies.authRevision(), previous != revision
        {
            // SDK can finish B→A before its observer runs. A stable account UUID
            // does not erase those intervening credential boundaries.
            applySession(nil)
        }
        let changed = currentUserId != session?.user.id
        applySession(session)
        observedAuthRevision = dependencies.authRevision()
        // Token refresh is not an account boundary. Repeated sign-in/profile events
        // refresh profile without resetting drafts or enqueuing provider identity work.
        guard let userId = currentUserId else { return }
        if changed || event == .initialSession || event == .signedIn || event == .userUpdated {
            profileTask?.cancel()
            profileTask = Task { [weak self] in await self?.loadProfile(userId: userId) }
        }
        if !changed { dependencies.refreshProviderIdentity() }
        if changed {
            calendarTask = Task { [weak self] in await self?.dependencies.refreshCalendar() }
        }
    }

    private func applySession(_ candidate: Session?) {
        let session = candidate.flatMap { $0.expiresAt > dependencies.now().timeIntervalSince1970 ? $0 : nil }
        expiryTask?.cancel()
        expiryTask = nil
        let changed = currentUser?.id != session?.user.id
        currentSession = session
        dependencies.sessionAccepted(session)
        currentUser = session?.user
        if let session {
            let delay = max(0, session.expiresAt - dependencies.now().timeIntervalSince1970)
            let waitForExpiry = dependencies.waitForExpiry
            expiryTask = Task { [weak self] in
                do { try await waitForExpiry(delay) } catch { return }
                guard let self, !Task.isCancelled, self.currentSession?.accessToken == session.accessToken,
                    self.currentSession?.expiresAt == session.expiresAt
                else { return }
                self.applySession(nil)
            }
        }
        guard changed else { return }
        sessionGeneration &+= 1
        authBrowser.cancel()
        callbackAttemptId = nil
        if dependencies.callbackIntents?.matches(session: session) == false { dependencies.callbackIntents?.clear() }
        profileTask?.cancel()
        calendarTask?.cancel()
        profile = nil
        try? persistence.selectAccount(session?.user.id)
        // Provider reconciliation starts synchronously, independently of profile I/O.
        dependencies.accountChanged(session?.user.id)
    }

    private func loadProfile(userId: UUID) async {
        let credentials = AccountRequestCredentials(
            accountId: currentUserId, generation: sessionGeneration, accessToken: currentSession?.accessToken)
        return await AccountRequestContext.$credentials.withValue(credentials) {
            let generation = sessionGeneration
            guard currentUserId == userId, !Task.isCancelled else { return }
            // Return cached profile immediately
            if let cached = try? persistence.fetchProfile(id: userId) {
                profile = cached
            }

            // Then refresh from server
            do {
                let response = try await dependencies.loadProfile(userId)
                guard generation == sessionGeneration, currentUserId == userId, !Task.isCancelled else { return }
                try? persistence.saveProfile(response)
                profile = response
            } catch {
                print("Failed to load profile: \(error)")
            }
        }
    }

    // MARK: - Sign In Methods

    public func signInWithGoogle() async throws {
        guard let intents = dependencies.callbackIntents, let launch = dependencies.launchOAuth else {
            throw AuthError.browserSignInFailed
        }
        let intent = intents.begin(session: currentSession)
        callbackAttemptId = nil
        dependencies.beginAuthAttempt(intent)
        authBrowser.cancel()
        let revision = dependencies.authRevision()
        do {
            try await AuthAttemptContext.$intentId.withValue(intent) {
                try await AuthAttemptContext.$revision.withValue(revision) {
                    let session = try await auth.signInWithOAuth(
                        provider: .google,
                        redirectTo: AuthCallbackIntentStore.redirectURL(attempt: intent)
                    ) { url in
                        guard intents.current?.id == intent, intents.matches(session: self.currentSession) else {
                            throw CancellationError()
                        }
                        let callback = try await launch(url)
                        guard intents.current?.id == intent, intents.matches(session: self.currentSession) else {
                            throw CancellationError()
                        }
                        guard intents.accepts(url: callback, session: self.currentSession) else {
                            throw AuthCallbackRejection.unmatchedLink
                        }
                        intents.clear(id: intent)
                        return callback
                    }
                    guard auth.currentSession == session else { throw CancellationError() }
                }
            }
        } catch AuthCallbackRejection.unmatchedLink {
            // A scheme-routed URL from another attempt must not consume this
            // browser's pending intent/verifier. Its genuine link can still finish.
            throw AuthError.browserSignInFailed
        } catch {
            intents.clear(id: intent)
            dependencies.endAuthAttempt(intent)
            throw error
        }
        intents.clear(id: intent)
        dependencies.endAuthAttempt(intent)
    }

    public func signInWithApple() async throws {
        guard appleOperationId == nil else { throw AuthError.appleSignInFailed("Sign-in is already in progress") }
        // Native sign-in supersedes pending browser/email attempts before its first await.
        dependencies.callbackIntents?.clear()
        callbackAttemptId = nil
        authBrowser.cancel()
        let intent = UUID()
        appleOperationId = intent
        dependencies.beginAuthAttempt(intent)
        let revision = dependencies.authRevision()
        let generation = sessionGeneration
        defer {
            if appleOperationId == intent { appleOperationId = nil }
            dependencies.endAuthAttempt(intent)
        }
        let credentials: AppleCredentials
        if let launch = dependencies.launchApple {
            credentials = try await launch()
        } else {
            appleAttemptGeneration = generation
            credentials = try await withCheckedThrowingContinuation { continuation in
                appleSignInContinuation = continuation
                let nonce = randomNonceString()
                currentNonce = nonce
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email, .fullName]
                request.nonce = sha256(nonce)
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                appleController = controller
                controller.performRequests()
            }
        }
        guard sessionGeneration == generation else { throw CancellationError() }
        let session = try await AuthAttemptContext.$intentId.withValue(intent) {
            try await AuthAttemptContext.$revision.withValue(revision) {
                try await auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: credentials.identityToken, nonce: credentials.nonce))
            }
        }
        guard auth.currentSession == session else { throw CancellationError() }
        // Apple returns the name only on the first authorization.
        if currentUserId == session.user.id, let displayName = credentials.displayName, !displayName.isEmpty {
            try? await updateProfile(displayName: displayName, avatarUrl: nil, timezone: nil)
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }

    public func signInWithMagicLink(email: String) async throws {
        guard let intents = dependencies.callbackIntents else { throw AuthError.browserSignInFailed }
        let intent = intents.begin(session: currentSession)
        callbackAttemptId = nil
        dependencies.beginAuthAttempt(intent)
        let revision = dependencies.authRevision()
        do {
            try await AuthAttemptContext.$intentId.withValue(intent) {
                try await AuthAttemptContext.$revision.withValue(revision) {
                    try await auth.signInWithOTP(email: email, redirectTo: AuthCallbackIntentStore.redirectURL(attempt: intent))
                }
            }
        } catch {
            intents.clear(id: intent)
            dependencies.endAuthAttempt(intent)
            throw error
        }
    }

    public func signOut() async throws {
        let originalSession = currentSession
        dependencies.callbackIntents?.clear()
        authBrowser.cancel()
        callbackAttemptId = nil
        dependencies.invalidateAuthAttempts()
        applySession(nil)
        let generation = sessionGeneration
        let revision = dependencies.authRevision()
        do {
            if let signOutSession = dependencies.signOutSession {
                try await signOutSession(originalSession, revision)
            } else {
                try await AuthAttemptContext.$revision.withValue(revision) { try await dependencies.signOut() }
            }
        } catch {
            guard generation == sessionGeneration else { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Profile Updates

    public func updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) async throws {
        let credentials = AccountRequestCredentials(
            accountId: currentUserId, generation: sessionGeneration, accessToken: currentSession?.accessToken)
        return try await AccountRequestContext.$credentials.withValue(credentials) {
            guard let userId = currentUser?.id else {
                throw AuthError.notAuthenticated
            }

            let generation = sessionGeneration
            // A profile read started before this edit cannot restore its older row.
            profileTask?.cancel()
            let supabase = self.supabase
            var updates: [String: AnyJSON] = [:]
            if let displayName = displayName {
                updates["display_name"] = .string(displayName)
            }
            if let avatarUrl = avatarUrl {
                updates["avatar_url"] = .string(avatarUrl)
            }
            if let timezone = timezone {
                updates["timezone"] = .string(timezone)
            }

            let response: Profile
            do {
                response =
                    try await supabase
                    .from("profiles")
                    .update(updates)
                    .eq("id", value: userId.uuidString)
                    .select()
                    .single()
                    .execute()
                    .value
            } catch {
                guard generation == sessionGeneration, currentUserId == userId, !Task.isCancelled else {
                    throw CancellationError()
                }
                throw error
            }

            guard generation == sessionGeneration, currentUserId == userId, !Task.isCancelled else { throw CancellationError() }
            try? persistence.saveProfile(response)
            profile = response
        }
    }

    // MARK: - Handle OAuth Callback

    public func handleDeepLink(url: URL) async {
        guard url.scheme == Config.appScheme, url.host == "auth", url.path == "/callback" else { return }
        await initialize()
        guard callbackAttemptId == nil, let intents = dependencies.callbackIntents,
            intents.accepts(url: url, session: currentSession), let intent = intents.current
        else { return }
        let callbackId = UUID()
        callbackAttemptId = callbackId
        dependencies.beginAuthAttempt(intent.id)
        intents.clear(id: intent.id)
        defer {
            if callbackAttemptId == callbackId { callbackAttemptId = nil }
            dependencies.endAuthAttempt(intent.id)
        }
        let revision = dependencies.authRevision()
        do {
            _ = try await AuthAttemptContext.$intentId.withValue(intent.id) {
                try await AuthAttemptContext.$revision.withValue(revision) { try await auth.session(from: url) }
            }
        } catch {
            // SDK verifies PKCE and server expiry. Consumed attempts are not replayed.
        }
    }

}

private enum AuthCallbackRejection: Error { case unmatchedLink }

public enum AuthError: Error {
    case notAuthenticated
    case browserSignInFailed
    case appleSignInFailed(String)
}

// MARK: - ASAuthorizationControllerDelegate
extension AuthService: ASAuthorizationControllerDelegate {
    nonisolated public func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let controllerId = ObjectIdentifier(controller)
        Task { @MainActor in
            guard appleController.map(ObjectIdentifier.init) == controllerId else { return }
            defer {
                appleController = nil
                appleAttemptGeneration = nil
            }
            guard appleAttemptGeneration == sessionGeneration else {
                appleSignInContinuation?.resume(throwing: CancellationError())
                appleSignInContinuation = nil
                currentNonce = nil
                return
            }
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityTokenData = appleIDCredential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                appleSignInContinuation?.resume(throwing: AuthError.appleSignInFailed("Missing credentials"))
                appleSignInContinuation = nil
                return
            }

            let displayName = appleIDCredential.fullName.map { name in
                [name.givenName ?? "", name.familyName ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            }
            appleSignInContinuation?.resume(
                returning: AppleCredentials(
                    identityToken: identityToken, nonce: nonce, displayName: displayName))
            appleSignInContinuation = nil
            currentNonce = nil
        }
    }

    nonisolated public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let controllerId = ObjectIdentifier(controller)
        Task { @MainActor in
            guard appleController.map(ObjectIdentifier.init) == controllerId else { return }
            appleController = nil
            appleAttemptGeneration = nil
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
            currentNonce = nil
        }
    }
}
