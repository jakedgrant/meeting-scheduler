import Foundation
import RevenueCat

/// Protocol describing the public interface of PurchaseService for dependency injection and testing.
@MainActor
public protocol PurchaseServiceProtocol: AnyObject, Observable, Sendable {
    // MARK: - Properties

    var isLoading: Bool { get }
    var hasProAccess: Bool { get }
    var hasTeamAccess: Bool { get }
    var currentOffering: Offering? { get }

    // MARK: - Offerings

    func loadOfferings() async

    // MARK: - Purchases

    func purchase(package: Package) async throws -> CustomerInfo
    func restorePurchases() async throws -> CustomerInfo
}
