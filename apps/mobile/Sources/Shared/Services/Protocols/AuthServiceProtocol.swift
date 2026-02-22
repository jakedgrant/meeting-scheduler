import Foundation

/// Protocol describing the public interface of AuthService for dependency injection and testing.
@MainActor
public protocol AuthServiceProtocol: AnyObject, Observable, Sendable {
    // MARK: - Properties

    var profile: Profile? { get }
    var isLoading: Bool { get }
    var isAuthenticated: Bool { get }

    /// Convenience accessor for the current user's ID (avoids exposing Supabase User type).
    var currentUserId: UUID? { get }

    /// Convenience accessor for the current user's email.
    var currentUserEmail: String? { get }

    // MARK: - Auth Lifecycle

    func initialize() async
    func handleDeepLink(url: URL) async

    // MARK: - Sign In

    func signInWithGoogle() async throws
    func authorizeGoogleCalendar() async throws -> Bool
    func signInWithApple() async throws
    func signInWithMagicLink(email: String) async throws

    // MARK: - Sign Out

    func signOut() async throws

    // MARK: - Profile

    func updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) async throws
}
