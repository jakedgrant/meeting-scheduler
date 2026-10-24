import Foundation
import Supabase

/// Immutable credentials belong to the operation that captured them, including
/// while the SDK suspends before applying its Authorization header.
public struct AccountRequestCredentials: Sendable {
    let accountId: UUID?
    let generation: UInt64
    let accessToken: String?
}

enum AccountRequestContext {
    @TaskLocal static var credentials: AccountRequestCredentials?
}

@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()
    public let client: SupabaseClient
    let sessionAdapter: SessionAuthAdapter
    private(set) var requestCredentials = AccountRequestCredentials(accountId: nil, generation: 0, accessToken: nil)

    static func apiClient(
        url: URL, key: String, transport: URLSession = .shared,
        beforeToken: @escaping @Sendable () async -> Void = {}
    ) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url, supabaseKey: key,
            options: .init(
                auth: .init(
                    storageKey: "scheduler-api-unused", autoRefreshToken: false,
                    emitLocalSessionAsInitialSession: true,
                    accessToken: {
                        await beforeToken()
                        return AccountRequestContext.credentials?.accessToken
                    }), global: .init(session: transport)))
    }

    func acceptSession(_ session: Session?) {
        let generation = requestCredentials.generation &+ (requestCredentials.accountId == session?.user.id ? 0 : 1)
        requestCredentials = AccountRequestCredentials(
            accountId: session?.user.id, generation: generation, accessToken: session?.accessToken)
    }

    private init() {
        let url = URL(string: Config.supabaseURL)!
        sessionAdapter = SessionAuthAdapter(url: url, key: Config.supabaseAnonKey)
        client = Self.apiClient(url: url, key: Config.supabaseAnonKey)
    }
}
