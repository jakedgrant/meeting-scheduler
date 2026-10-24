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
    private var appleAttemptRevision: UInt64?
    private var appleAttemptGeneration: UInt64?
    private var callbackAttemptId: UUID?
    private var observedAuthRevision: UInt64?
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []
    private var appleSignInContinuation: CheckedContinuation<Void, Error>?

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
        let intent = dependencies.callbackIntents?.begin(session: currentSession)
        let revision = dependencies.authRevision()
        do {
            try await AuthAttemptContext.$revision.withValue(revision) {
                let session = try await auth.signInWithOAuth(
                    provider: .google,
                    redirectTo: URL(string: "\(Config.appScheme)://auth/callback"))
                guard auth.currentSession == session else { throw CancellationError() }
            }
        } catch {
            if let intent { dependencies.callbackIntents?.clear(id: intent) }
            throw error
        }
        if let intent { dependencies.callbackIntents?.clear(id: intent) }
    }

    public func signInWithApple() async throws {
        guard appleSignInContinuation == nil else { throw AuthError.appleSignInFailed("Sign-in is already in progress") }
        appleAttemptRevision = dependencies.authRevision()
        appleAttemptGeneration = sessionGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.appleSignInContinuation = continuation

            let nonce = randomNonceString()
            currentNonce = nonce

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]
            request.nonce = sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            appleController = controller
            controller.performRequests()
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
        let intent = dependencies.callbackIntents?.begin(session: currentSession)
        do {
            try await auth.signInWithOTP(
                email: email,
                redirectTo: URL(string: "\(Config.appScheme)://auth/callback"))
        } catch {
            if let intent { dependencies.callbackIntents?.clear(id: intent) }
            throw error
        }
    }

    public func signOut() async throws {
        let originalSession = currentSession
        dependencies.callbackIntents?.clear()
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
            intents.matches(session: currentSession), let intent = intents.current
        else { return }
        let callbackId = UUID()
        callbackAttemptId = callbackId
        intents.clear(id: intent.id)
        defer { if callbackAttemptId == callbackId { callbackAttemptId = nil } }
        let revision = dependencies.authRevision()
        do {
            _ = try await AuthAttemptContext.$revision.withValue(revision) { try await auth.session(from: url) }
        } catch {
            // SDK verifies PKCE and server expiry. Consumed attempts are not replayed.
        }
    }

}

public enum AuthError: Error {
    case notAuthenticated
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
                appleAttemptRevision = nil
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

            do {
                let signedInSession = try await AuthAttemptContext.$revision.withValue(appleAttemptRevision) {
                    try await auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: identityToken, nonce: nonce))
                }

                guard auth.currentSession == signedInSession else { throw CancellationError() }
                // Apple only provides full name on first sign-in, so capture it
                if currentUserId == signedInSession.user.id, let fullName = appleIDCredential.fullName {
                    let givenName = fullName.givenName ?? ""
                    let familyName = fullName.familyName ?? ""
                    let displayName = [givenName, familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")

                    if !displayName.isEmpty {
                        try? await updateProfile(displayName: displayName, avatarUrl: nil, timezone: nil)
                    }
                }

                appleSignInContinuation?.resume()
            } catch {
                appleSignInContinuation?.resume(throwing: error)
            }
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
            appleAttemptRevision = nil
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
            currentNonce = nil
        }
    }
}
