import Foundation
import Supabase
import Auth
import AuthenticationServices
import CryptoKit

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

    private let supabase = SupabaseService.shared.client
    private var currentNonce: String?
    private var appleSignInContinuation: CheckedContinuation<Void, Error>?

    private override init() {
        super.init()
        Task {
            await initialize()
        }
    }

    public func initialize() async {
        // Get initial session
        do {
            let session = try await supabase.auth.session
            currentSession = session
            currentUser = session.user
            if let userId = currentUser?.id {
                await loadProfile(userId: userId)
                await PurchaseService.shared.login(userId: userId.uuidString)
            }
        } catch {
            print("No existing session: \(error)")
        }

        isLoading = false

        // Listen for auth changes
        Task {
            for await (event, session) in supabase.auth.authStateChanges {
                await handleAuthChange(event: event, session: session)
            }
        }
    }

    private func handleAuthChange(event: AuthChangeEvent, session: Session?) async {
        currentSession = session
        currentUser = session?.user

        switch event {
        case .signedIn:
            if let userId = session?.user.id {
                await loadProfile(userId: userId)
                await PurchaseService.shared.login(userId: userId.uuidString)
            }
        case .signedOut:
            profile = nil
            await PurchaseService.shared.logout()
        default:
            break
        }
    }

    private func loadProfile(userId: UUID) async {
        do {
            let response: Profile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value

            profile = response
        } catch {
            print("Failed to load profile: \(error)")
        }
    }

    // MARK: - Sign In Methods

    public func signInWithGoogle() async throws {
        try await supabase.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "\(Config.appScheme)://auth/callback")
        )
    }

    /// Sign in with Google and request calendar access
    /// Returns true if calendar tokens were successfully obtained
    public func authorizeGoogleCalendar() async throws -> Bool {
        let session = try await supabase.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "\(Config.appScheme)://auth/callback"),
            scopes: "openid email profile https://www.googleapis.com/auth/calendar.readonly",
            queryParams: [
                (name: "access_type", value: "offline"),
                (name: "prompt", value: "consent")
            ]
        )

        // Persist calendar tokens if present
        if let providerToken = session.providerToken,
           let providerRefreshToken = session.providerRefreshToken {
            await persistCalendarTokens(
                accessToken: providerToken,
                refreshToken: providerRefreshToken,
                userId: session.user.id
            )
            return true
        }

        return false
    }

    public func signInWithApple() async throws {
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
        try await supabase.auth.signInWithOTP(
            email: email,
            redirectTo: URL(string: "\(Config.appScheme)://auth/callback")
        )
    }

    public func signOut() async throws {
        try await supabase.auth.signOut()
    }

    // MARK: - Profile Updates

    public func updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) async throws {
        guard let userId = currentUser?.id else {
            throw AuthError.notAuthenticated
        }

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

        let response: Profile = try await supabase
            .from("profiles")
            .update(updates)
            .eq("id", value: userId.uuidString)
            .select()
            .single()
            .execute()
            .value

        profile = response
    }

    // MARK: - Handle OAuth Callback

    public func handleDeepLink(url: URL) async {
        do {
            let session = try await supabase.auth.session(from: url)

            // If OAuth callback includes provider tokens (Google Calendar), persist them
            if let providerToken = session.providerToken,
               let providerRefreshToken = session.providerRefreshToken {
                await persistCalendarTokens(
                    accessToken: providerToken,
                    refreshToken: providerRefreshToken,
                    userId: session.user.id
                )
            }
        } catch {
            print("Failed to handle deep link: \(error)")
        }
    }

    private func persistCalendarTokens(accessToken: String, refreshToken: String, userId: UUID) async {
        do {
            let expiresAt = Date.now.addingTimeInterval(3600).ISO8601Format()

            var updates: [String: AnyJSON] = [:]
            updates["google_calendar_access_token"] = .string(accessToken)
            updates["google_calendar_refresh_token"] = .string(refreshToken)
            updates["google_calendar_token_expires_at"] = .string(expiresAt)
            updates["calendar_integration_enabled"] = .bool(true)

            try await supabase
                .from("profiles")
                .update(updates)
                .eq("id", value: userId.uuidString)
                .execute()

            print("✓ Calendar tokens persisted successfully")
        } catch {
            print("Failed to persist calendar tokens: \(error)")
        }
    }
}

public enum AuthError: Error {
    case notAuthenticated
    case appleSignInFailed(String)
}

// MARK: - ASAuthorizationControllerDelegate
extension AuthService: ASAuthorizationControllerDelegate {
    nonisolated public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                appleSignInContinuation?.resume(throwing: AuthError.appleSignInFailed("Missing credentials"))
                appleSignInContinuation = nil
                return
            }

            do {
                try await supabase.auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: nonce
                    )
                )

                // Apple only provides full name on first sign-in, so capture it
                if let fullName = appleIDCredential.fullName {
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
        Task { @MainActor in
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
            currentNonce = nil
        }
    }
}
