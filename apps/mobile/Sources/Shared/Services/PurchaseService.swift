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
        do {
            let (customerInfo, _) = try await Purchases.shared.logIn(userId)
            self.customerInfo = customerInfo
            print("RevenueCat logged in: \(customerInfo.originalAppUserId)")
        } catch {
            print("RevenueCat login failed: \(error)")
        }
    }

    public func logout() async {
        do {
            let customerInfo = try await Purchases.shared.logOut()
            self.customerInfo = customerInfo
        } catch {
            print("RevenueCat logout failed: \(error)")
        }
    }

    // MARK: - Customer Info

    public func refreshCustomerInfo() async {
        do {
            customerInfo = try await Purchases.shared.customerInfo()
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
        let result = try await Purchases.shared.purchase(package: package)
        customerInfo = result.customerInfo
        return result.customerInfo
    }

    public func restorePurchases() async throws -> CustomerInfo {
        let customerInfo = try await Purchases.shared.restorePurchases()
        self.customerInfo = customerInfo
        return customerInfo
    }
}
