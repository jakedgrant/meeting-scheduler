import Foundation

/// Mock implementation of AuthServiceProtocol for SwiftUI previews and testing.
@MainActor
@Observable
public final class MockAuthService: AuthServiceProtocol {
    public var profile: Profile?
    public var isLoading: Bool
    public var isAuthenticated: Bool
    public var currentUserId: UUID?
    public var currentUserEmail: String?

    public init(
        profile: Profile? = nil,
        isLoading: Bool = false,
        isAuthenticated: Bool = false,
        currentUserId: UUID? = nil,
        currentUserEmail: String? = nil
    ) {
        self.profile = profile
        self.isLoading = isLoading
        self.isAuthenticated = isAuthenticated
        self.currentUserId = currentUserId
        self.currentUserEmail = currentUserEmail
    }

    // MARK: - Static Factories

    public static var signedIn: MockAuthService {
        let userId = UUID()
        return MockAuthService(
            profile: Profile(
                id: userId,
                email: "jane@example.com",
                displayName: "Jane Doe",
                avatarUrl: nil,
                timezone: "America/New_York"
            ),
            isLoading: false,
            isAuthenticated: true,
            currentUserId: userId,
            currentUserEmail: "jane@example.com"
        )
    }

    public static var signedOut: MockAuthService {
        MockAuthService(
            profile: nil,
            isLoading: false,
            isAuthenticated: false,
            currentUserId: nil,
            currentUserEmail: nil
        )
    }

    public static var loading: MockAuthService {
        MockAuthService(
            profile: nil,
            isLoading: true,
            isAuthenticated: false,
            currentUserId: nil,
            currentUserEmail: nil
        )
    }

    // MARK: - No-op Methods

    public func initialize() async {}
    public func handleDeepLink(url: URL) async {}
    public func signInWithGoogle() async throws {}
    public func authorizeGoogleCalendar() async throws -> Bool { false }
    public func signInWithApple() async throws {}
    public func signInWithMagicLink(email: String) async throws {}
    public func signOut() async throws {}
    public func updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) async throws {}
}
