import Foundation
import RevenueCat

@MainActor
@Observable
public final class PurchaseService: PurchaseServiceProtocol {
    public static let shared = PurchaseService()

    public private(set) var customerInfo: CustomerInfo?
    public private(set) var offerings: Offerings?
    public private(set) var isLoading = false

    public var hasProAccess: Bool {
        customerInfo?.entitlements["pro_access"]?.isActive == true || customerInfo?.entitlements["team_access"]?.isActive == true
    }

    public var hasTeamAccess: Bool {
        customerInfo?.entitlements["team_access"]?.isActive == true
    }

    public var currentOffering: Offering? {
        offerings?.current
    }

    private var accountGeneration: UInt64 = 0
    private var accountUserId: String?
    private var reconciledGeneration: UInt64?
    private var identityTask: Task<Void, Never>?
    private var identityReady = false
    private var providerTail: Task<Void, Never>?
    private let dependencies: Dependencies

    struct Dependencies {
        var login: @MainActor (String) async throws -> CustomerInfo?
        var logout: @MainActor () async throws -> Void
        var currentUserId: @MainActor () -> String
        var customerInfo: @MainActor () async throws -> CustomerInfo?
        var offerings: @MainActor () async throws -> Offerings?
        var purchase: @MainActor (Package) async throws -> CustomerInfo = { _ in throw AuthError.notAuthenticated }
        var restore: @MainActor () async throws -> CustomerInfo = { throw AuthError.notAuthenticated }

        static var live: Self {
            Self(
                login: { try await Purchases.shared.logIn($0).customerInfo },
                logout: { if !Purchases.shared.isAnonymous { _ = try await Purchases.shared.logOut() } },
                currentUserId: { Purchases.shared.appUserID },
                customerInfo: { try await Purchases.shared.customerInfo() },
                offerings: { try await Purchases.shared.offerings() },
                purchase: { try await Purchases.shared.purchase(package: $0).customerInfo },
                restore: { try await Purchases.shared.restorePurchases() })
        }
    }

    /// Clear visibility now; a single ordered worker reconciles provider side effects.
    public func resetAccountState(userId: String?) {
        accountUserId = userId
        accountGeneration &+= 1
        identityReady = false
        customerInfo = nil
        offerings = nil
        isLoading = false
        startReconciliation()
    }

    private init() {
        dependencies = .live
        #if DEBUG
            Purchases.logLevel = .debug
        #else
            Purchases.logLevel = .warn
        #endif
        Purchases.configure(withAPIKey: Config.revenueCatAPIKey)
        // Remove a persisted provider identity even when auth restores signed out.
        startReconciliation()
    }

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    private func startReconciliation() {
        guard identityTask == nil else { return }
        identityTask = Task { [weak self] in await self?.reconcileIdentity() }
    }

    /// Receipt-affecting commands and identity changes share an ordered provider
    /// queue. An A purchase/restore must finish under A before reconciliation logs B in.
    private func orderedProvider<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = providerTail
        let result = Task {
            await previous?.value
            return try await operation()
        }
        providerTail = Task { _ = try? await result.value }
        return try await result.value
    }

    private func reconcileIdentity() async {
        // Never cancel a provider identity mutation: cancellation cannot undo an
        // SDK side effect. Finish it, then reconcile directly to the latest target.
        while reconciledGeneration != accountGeneration {
            let generation = accountGeneration
            let target = accountUserId
            do {
                if let target {
                    let info = try await orderedProvider {
                        guard generation == self.accountGeneration else { return nil as CustomerInfo? }
                        return try await self.dependencies.login(target)
                    }
                    if generation == accountGeneration, dependencies.currentUserId() == target {
                        customerInfo = info
                        identityReady = true
                    }
                } else {
                    try await orderedProvider {
                        guard generation == self.accountGeneration else { return }
                        try await self.dependencies.logout()
                    }
                    if generation == accountGeneration { identityReady = true }
                }
            } catch {
                // No stale error or cleanup publishes into the next account. A
                // current failure leaves paid access hidden; login/refresh retries.
            }
            reconciledGeneration = generation
        }
        identityTask = nil
    }

    // MARK: - User Management

    public func login(userId: String) async {
        guard accountUserId == userId else { return }
        reconciledGeneration = nil
        startReconciliation()
        await identityTask?.value
    }

    public func logout() async {
        guard accountUserId == nil else { return }
        reconciledGeneration = nil
        startReconciliation()
        await identityTask?.value
    }

    /// Ordinary credential refresh may retry an offline identity failure without
    /// resetting visible drafts or the auth generation.
    func retryAccountIdentity() {
        guard !identityReady else { return }
        reconciledGeneration = nil
        startReconciliation()
    }

    func waitForIdentityReconciliation() async { await identityTask?.value }

    // MARK: - Customer Info

    public func refreshCustomerInfo() async {
        let generation = accountGeneration
        guard let userId = accountUserId, dependencies.currentUserId() == userId else { return }
        do {
            let info = try await dependencies.customerInfo()
            guard generation == accountGeneration,
                accountUserId == userId, dependencies.currentUserId() == userId
            else { return }
            customerInfo = info
        } catch {
            print("Failed to get customer info: \(error)")
        }
    }

    // MARK: - Offerings

    public func loadOfferings() async {
        let generation = accountGeneration
        guard let userId = accountUserId else { return }
        isLoading = true
        defer { if generation == accountGeneration { isLoading = false } }

        do {
            await identityTask?.value
            guard generation == accountGeneration, identityReady, dependencies.currentUserId() == userId, !Task.isCancelled else {
                return
            }
            let result = try await dependencies.offerings()
            guard generation == accountGeneration, !Task.isCancelled else { return }
            offerings = result
        } catch {
            print("Failed to load offerings: \(error)")
        }
    }

    // MARK: - Purchases

    public func purchase(package: Package) async throws -> CustomerInfo {
        let generation = accountGeneration
        guard let userId = accountUserId, dependencies.currentUserId() == userId else { throw AuthError.notAuthenticated }
        let result: CustomerInfo
        do {
            result = try await orderedProvider {
                guard generation == self.accountGeneration, self.accountUserId == userId,
                    self.dependencies.currentUserId() == userId
                else { throw CancellationError() }
                return try await self.dependencies.purchase(package)
            }
        } catch {
            guard generation == accountGeneration, accountUserId == userId else { throw CancellationError() }
            throw error
        }
        guard generation == accountGeneration, accountUserId == userId, dependencies.currentUserId() == userId else {
            throw CancellationError()
        }
        customerInfo = result
        return result
    }

    public func restorePurchases() async throws -> CustomerInfo {
        let generation = accountGeneration
        guard let userId = accountUserId, dependencies.currentUserId() == userId else { throw AuthError.notAuthenticated }
        let customerInfo: CustomerInfo
        do {
            customerInfo = try await orderedProvider {
                guard generation == self.accountGeneration, self.accountUserId == userId,
                    self.dependencies.currentUserId() == userId
                else { throw CancellationError() }
                return try await self.dependencies.restore()
            }
        } catch {
            guard generation == accountGeneration, accountUserId == userId else { throw CancellationError() }
            throw error
        }
        guard generation == accountGeneration, accountUserId == userId, dependencies.currentUserId() == userId else {
            throw CancellationError()
        }
        self.customerInfo = customerInfo
        return customerInfo
    }
}
