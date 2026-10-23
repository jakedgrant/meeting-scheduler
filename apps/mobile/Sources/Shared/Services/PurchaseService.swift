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
        customerInfo?.entitlements["pro_access"]?.isActive == true ||
        customerInfo?.entitlements["team_access"]?.isActive == true
    }

    public var hasTeamAccess: Bool {
        customerInfo?.entitlements["team_access"]?.isActive == true
    }

    public var currentOffering: Offering? {
        offerings?.current
    }

    private var accountGeneration: UInt64 = 0
    private var accountUserId: String?

    /// Remove entitlements immediately; failed provider logout/login cannot expose another account.
    public func resetAccountState(userId: String?) {
        accountUserId = userId
        accountGeneration &+= 1
        customerInfo = nil
        isLoading = false
    }

    private init() {
        configure()
    }

    private func configure() {
        Purchases.logLevel = .debug
        Purchases.configure(withAPIKey: Config.revenueCatAPIKey)

        // Get initial customer info
        Task {
            await refreshCustomerInfo()
            await loadOfferings()
        }
    }

    // MARK: - User Management

    public func login(userId: String) async {
        let generation = accountGeneration
        guard accountUserId == userId else { return }
        do {
            let (customerInfo, _) = try await Purchases.shared.logIn(userId)
            guard generation == accountGeneration, Purchases.shared.appUserID == userId else { return }
            self.customerInfo = customerInfo
            print("RevenueCat logged in: \(customerInfo.originalAppUserId)")
        } catch {
            print("RevenueCat login failed: \(error)")
        }
    }

    public func logout() async {
        let generation = accountGeneration
        do {
            guard accountUserId == nil else { return }
            _ = try await Purchases.shared.logOut()
            guard generation == accountGeneration else { return }
            self.customerInfo = nil
        } catch {
            print("RevenueCat logout failed: \(error)")
        }
    }

    // MARK: - Customer Info

    public func refreshCustomerInfo() async {
        let generation = accountGeneration
        guard let userId = accountUserId, Purchases.shared.appUserID == userId else { return }
        do {
            let info = try await Purchases.shared.customerInfo()
            guard generation == accountGeneration,
                  accountUserId == userId, Purchases.shared.appUserID == userId else { return }
            customerInfo = info
        } catch {
            print("Failed to get customer info: \(error)")
        }
    }

    // MARK: - Offerings

    public func loadOfferings() async {
        isLoading = true
        defer { isLoading = false }

        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            print("Failed to load offerings: \(error)")
        }
    }

    // MARK: - Purchases

    public func purchase(package: Package) async throws -> CustomerInfo {
        let generation = accountGeneration
        guard let userId = accountUserId, Purchases.shared.appUserID == userId else { throw AuthError.notAuthenticated }
        let result = try await Purchases.shared.purchase(package: package)
        guard generation == accountGeneration, accountUserId == userId, Purchases.shared.appUserID == userId else { throw CancellationError() }
        customerInfo = result.customerInfo
        return result.customerInfo
    }

    public func restorePurchases() async throws -> CustomerInfo {
        let generation = accountGeneration
        guard let userId = accountUserId, Purchases.shared.appUserID == userId else { throw AuthError.notAuthenticated }
        let customerInfo = try await Purchases.shared.restorePurchases()
        guard generation == accountGeneration, accountUserId == userId, Purchases.shared.appUserID == userId else { throw CancellationError() }
        self.customerInfo = customerInfo
        return customerInfo
    }
}
