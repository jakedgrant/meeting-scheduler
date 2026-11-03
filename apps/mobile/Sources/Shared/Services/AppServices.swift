import Foundation

/// The application's composition root: one API transport, one persistence provider, one clock,
/// and the auth, poll, calendar and purchase services. Auth and polls share the provider so
/// identity changes apply to one context synchronously.
@MainActor
public final class AppServices {
    let auth: AuthService
    let polls: PollService
    let calendar: CalendarService
    let purchases: PurchaseService
    let clock: AppClock

    /// Builds the production services. Call this once per launch: it creates the SwiftData
    /// provider, configures the process-wide RevenueCat SDK and starts auth initialization.
    public static func live() -> AppServices {
        let url = URL(string: Config.supabaseURL)!
        let key = Config.supabaseAnonKey
        let clock = AppClock.system
        let services = AppServices(
            supabase: SupabaseService(
                client: SupabaseService.apiClient(url: url, key: key),
                sessionAdapter: SessionAuthAdapter(url: url, key: key)),
            makePersistence: { clock in SwiftDataPersistenceProvider(now: { clock.now }) },
            preferences: .standard,
            purchases: .live(),
            clock: clock)
        Task { await services.auth.initialize() }
        return services
    }

    init(
        supabase: SupabaseService,
        makePersistence: (AppClock) -> any PersistenceProviderProtocol,
        preferences: UserDefaults, purchases: PurchaseService, clock: AppClock
    ) {
        // Built from this clock, which the factory passes to the provider as `now`.
        let persistence = makePersistence(clock)
        let identity: @MainActor () -> AccountRequestCredentials = { supabase.requestCredentials }
        let polls = PollService(
            persistence: persistence, currentUserId: { identity().accountId }, client: supabase.client,
            requestCredentials: identity)
        let calendar = CalendarService(preferences: preferences, client: supabase.client, requestCredentials: identity)
        self.polls = polls
        self.calendar = calendar
        self.purchases = purchases
        self.clock = clock
        self.auth = AuthService(
            supabase: supabase, persistence: persistence, preferences: preferences, clock: clock,
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
