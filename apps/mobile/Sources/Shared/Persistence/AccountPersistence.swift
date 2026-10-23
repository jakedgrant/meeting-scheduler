import Foundation

/// Auth and poll services use the same context so identity changes are synchronous.
@MainActor
enum AccountPersistence {
    static let shared: any PersistenceProviderProtocol = SwiftDataPersistenceProvider()
}
