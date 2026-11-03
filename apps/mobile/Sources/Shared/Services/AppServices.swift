import Foundation

/// The application's composition root: one API transport, one persistence provider, and the
/// auth, poll, calendar and purchase services. Auth and polls share the provider so identity
/// changes apply to one context synchronously.
@MainActor
public final class AppServices {
    let auth: AuthService
    let polls: PollService
    let calendar: CalendarService
    let purchases: PurchaseService

    /// Builds the production services. Call this once per launch: it creates the SwiftData
    /// provider, configures the process-wide RevenueCat SDK and starts auth initialization.
    public static func live() -> AppServices {
        let url = URL(string: Config.supabaseURL)!
        let key = Config.supabaseAnonKey
        let services = AppServices(
            supabase: SupabaseService(
                client: SupabaseService.apiClient(url: url, key: key),
                sessionAdapter: SessionAuthAdapter(url: url, key: key)),
            persistence: SwiftDataPersistenceProvider(),
            preferences: .standard,
            purchases: .live())
        Task { await services.auth.initialize() }
        return services
    }

    init(
        supabase: SupabaseService, persistence: any PersistenceProviderProtocol, preferences: UserDefaults,
        purchases: PurchaseService
    ) {
        let identity: @MainActor () -> AccountRequestCredentials = { supabase.requestCredentials }
        let polls = PollService(
            persistence: persistence, currentUserId: { identity().accountId }, client: supabase.client,
            requestCredentials: identity)
        let calendar = CalendarService(preferences: preferences, client: supabase.client, requestCredentials: identity)
        self.polls = polls
        self.calendar = calendar
        self.purchases = purchases
        self.auth = AuthService(
            supabase: supabase, persistence: persistence, preferences: preferences,
            accountChanged: { id in
                polls.accountDidChange(to: id)
                calendar.accountDidChange(to: id)
                purchases.resetAccountState(userId: id?.uuidString)
            }, refreshCalendar: { await calendar.refreshGoogleCalendarConnection() },
            refreshProviderIdentity: { purchases.retryAccountIdentity() })
    }

    public func handleDeepLink(url: URL) async {
        await auth.handleDeepLink(url: url)
    }
}
