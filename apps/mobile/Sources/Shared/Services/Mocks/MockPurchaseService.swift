import Foundation
import RevenueCat

/// Mock implementation of PurchaseServiceProtocol for SwiftUI previews and testing.
@MainActor
@Observable
public final class MockPurchaseService: PurchaseServiceProtocol {
    public var isLoading: Bool
    public var hasProAccess: Bool
    public var hasTeamAccess: Bool
    public var currentOffering: Offering?

    public init(
        isLoading: Bool = false,
        hasProAccess: Bool = false,
        hasTeamAccess: Bool = false,
        currentOffering: Offering? = nil
    ) {
        self.isLoading = isLoading
        self.hasProAccess = hasProAccess
        self.hasTeamAccess = hasTeamAccess
        self.currentOffering = currentOffering
    }

    // MARK: - Static Factories

    public static var free: MockPurchaseService {
        MockPurchaseService()
    }

    public static var pro: MockPurchaseService {
        MockPurchaseService(hasProAccess: true)
    }

    // MARK: - No-op / Throwing Methods

    public func loadOfferings() async {}

    public func purchase(package: Package) async throws -> CustomerInfo {
        throw MockPurchaseError.notAvailableInPreview
    }

    public func restorePurchases() async throws -> CustomerInfo {
        throw MockPurchaseError.notAvailableInPreview
    }
}

private enum MockPurchaseError: LocalizedError {
    case notAvailableInPreview

    var errorDescription: String? {
        "Purchases are not available in preview mode."
    }
}
