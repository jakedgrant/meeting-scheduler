import Foundation

/// Ownership captured before a screen task can start or suspend.
@MainActor
public struct SessionTaskScope {
    private let authService: any AuthServiceProtocol
    private let accountId: UUID?
    private let generation: UInt64
    private let screenIsCurrent: @MainActor () -> Bool

    fileprivate init(authService: any AuthServiceProtocol, screenIsCurrent: @escaping @MainActor () -> Bool) {
        self.authService = authService
        accountId = authService.currentUserId
        generation = authService.sessionGeneration
        self.screenIsCurrent = screenIsCurrent
    }

    fileprivate var ownsSession: Bool {
        accountId == authService.currentUserId
            && generation == authService.sessionGeneration
            && screenIsCurrent()
    }

    /// Use between suspensions when an operation has more than one stage.
    public func checkCancellation() throws {
        try Task.checkCancellation()
        guard ownsSession else { throw CancellationError() }
    }
}

public extension AuthServiceProtocol {
    /// Runs screen work and publishes results only to its initiating session.
    /// Service-level credential/persistence guards remain authoritative.
    @discardableResult
    func performSessionTask<Value: Sendable>(
        operation: @escaping @MainActor (SessionTaskScope) async throws -> Value,
        onSuccess: @escaping @MainActor (Value) -> Void = { _ in },
        onFailure: @escaping @MainActor (any Error) -> Void = { _ in },
        onCompletion: @escaping @MainActor () -> Void = {},
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never> {
        let scope = SessionTaskScope(authService: self, screenIsCurrent: isCurrent)
        return Task { @MainActor in
            // Cancellation may finish loading in the same screen, but obsolete
            // cleanup must never clear a replacement screen/session's state.
            defer { if scope.ownsSession { onCompletion() } }
            do {
                try scope.checkCancellation()
                let value = try await operation(scope)
                try scope.checkCancellation()
                onSuccess(value)
            } catch is CancellationError {
                // Cancellation is not a user-facing failure.
            } catch {
                guard !Task.isCancelled, scope.ownsSession else { return }
                onFailure(error)
            }
        }
    }
}
