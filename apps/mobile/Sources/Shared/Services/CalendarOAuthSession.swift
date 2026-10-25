import Foundation

#if os(iOS)
    import AuthenticationServices
    import UIKit
#endif

enum CalendarConnectionError: LocalizedError {
    case unavailable, cancelled, authorizationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Google Calendar is temporarily unavailable. Try again."
        case .cancelled: "Google Calendar connection was cancelled."
        case .authorizationFailed: "Google Calendar could not be connected. Try again from Settings."
        }
    }
}

#if os(iOS)
    /// Owns one browser session and its continuation on the main actor. Callers
    /// validate the returned URL for their auth or calendar flow.
    @MainActor
    final class OAuthBrowserSession {
        private let errorMapper: @MainActor (CalendarConnectionError) -> any Error
        init(errorMapper: @escaping @MainActor (CalendarConnectionError) -> any Error = { $0 }) { self.errorMapper = errorMapper }
        private var session: ASWebAuthenticationSession?
        private var continuation: CheckedContinuation<URL, any Error>?
        private var attemptId: UUID?
        private var presentationContext: CalendarPresentationContext?

        func authenticate(url: URL) async throws -> URL {
            guard session == nil else { throw errorMapper(.authorizationFailed) }
            guard
                let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })?.keyWindow
            else {
                throw errorMapper(.unavailable)
            }
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.attemptId = id
                    self.continuation = continuation
                    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Config.appScheme) {
                        [weak self] url, error in
                        Task { @MainActor in
                            if let url {
                                self?.finish(.success(url), id: id)
                            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                                self?.finish(.failure(self?.errorMapper(.cancelled) ?? CancellationError()), id: id)
                            } else {
                                self?.finish(.failure(self?.errorMapper(.authorizationFailed) ?? CancellationError()), id: id)
                            }
                        }
                    }
                    let context = CalendarPresentationContext(window: window)
                    self.presentationContext = context
                    session.presentationContextProvider = context
                    session.prefersEphemeralWebBrowserSession = false
                    self.session = session
                    if Task.isCancelled {
                        cancel(id: id)
                    } else if !session.start() {
                        finish(.failure(errorMapper(.unavailable)), id: id)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id: id) }
            }
        }

        func cancel() {
            guard let id = attemptId else { return }
            cancel(id: id)
        }

        private func cancel(id: UUID) {
            guard attemptId == id else { return }
            session?.cancel()
            finish(.failure(errorMapper(.cancelled)), id: id)
        }

        private func finish(_ result: Result<URL, any Error>, id: UUID) {
            guard attemptId == id else { return }
            let pending = continuation
            continuation = nil
            attemptId = nil
            session = nil
            presentationContext = nil
            pending?.resume(with: result)
        }
    }

    @MainActor
    private final class CalendarPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let window: UIWindow

        init(window: UIWindow) { self.window = window }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            window
        }
    }
#else
    @MainActor
    final class OAuthBrowserSession {
        private let errorMapper: @MainActor (CalendarConnectionError) -> any Error
        init(errorMapper: @escaping @MainActor (CalendarConnectionError) -> any Error = { $0 }) { self.errorMapper = errorMapper }
        func authenticate(url: URL) async throws -> URL { throw errorMapper(.unavailable) }
        func cancel() {}
    }
#endif
