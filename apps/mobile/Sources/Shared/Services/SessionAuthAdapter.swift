import Auth
import Foundation
import Synchronization

/// Fences the pinned SDK's refresh transport before it can install an obsolete
/// session. UI generation checks alone cannot undo an SDK credential overwrite.
final class SessionAuthAdapter: Sendable {
    let auth: AuthClient
    private let storage: RevisionedAuthStorage

    init(
        url: URL, key: String, storage: any AuthLocalStorage = AuthClient.Configuration.defaultLocalStorage,
        fetch: @escaping AuthClient.FetchHandler = { try await URLSession.shared.data(for: $0) },
        autoRefreshToken: Bool = true
    ) {
        let revisioned = RevisionedAuthStorage(storage)
        self.storage = revisioned
        let project = url.host?.split(separator: ".").first.map(String.init) ?? "scheduler"
        auth = AuthClient(
            configuration: .init(
                url: url.appendingPathComponent("auth/v1"),
                headers: ["apikey": key, "Authorization": "Bearer \(key)"],
                storageKey: "sb-\(project)-auth-token", localStorage: revisioned,
                fetch: { request in
                    let revision = revisioned.revision
                    if let attempt = AuthAttemptContext.revision, attempt != revision { throw CancellationError() }
                    let result = try await fetch(request)
                    let path = request.url?.path ?? ""
                    let installsSession = path.hasSuffix("/token") || path.hasSuffix("/verify") || path.hasSuffix("/user")
                    if installsSession {
                        guard revision == revisioned.revision else { throw CancellationError() }
                        // The SDK awaits SessionManager after transport returns; check
                        // the same ownership atomically when credentials are stored.
                        let isRefresh =
                            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                            .contains(where: { $0.name == "grant_type" && $0.value == "refresh_token" }) == true
                        if isRefresh { revisioned.authorizeRefresh(data: result.0, revision: revision) }
                    }
                    return result
                }, autoRefreshToken: autoRefreshToken))
    }

    /// Also reject refreshes suspended across app-owned expiry boundaries, which
    /// do not themselves remove the SDK's offline credential record.
    var revision: UInt64 { storage.revision }
    func accountDidChange() { storage.advance() }
}

final class RevisionedAuthStorage: AuthLocalStorage, Sendable {
    private let underlying: any AuthLocalStorage
    private struct State {
        var revision: UInt64 = 0
        var refreshTicket: (token: String, revision: UInt64)?
    }
    private let state = Mutex(State())
    init(_ underlying: any AuthLocalStorage) { self.underlying = underlying }
    var revision: UInt64 { state.withLock { $0.revision } }
    func advance() { state.withLock { $0.revision &+= 1 } }
    func authorizeRefresh(data: Data, revision: UInt64) {
        // Pinned SDK coalesces refresh through one task until decode/store ends.
        // One complete-response ticket bounds storage even on decoding failures.
        guard (try? AuthClient.Configuration.jsonDecoder.decode(Session.self, from: data)) != nil,
            let token = Self.tokenKey(data)
        else { return }
        state.withLock { $0.refreshTicket = (token, revision) }
    }
    private static func tokenKey(_ data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = (value["access_token"] ?? value["accessToken"]) as? String,
            let refresh = (value["refresh_token"] ?? value["refreshToken"]) as? String
        else { return nil }
        return access + "|" + refresh
    }
    private static func owner(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let owner = ((json["user"] as? [String: Any])?["id"] ?? json["id"]) as? String else { return nil }
        let token = (json["access_token"] ?? json["accessToken"]) as? String
        return owner + "|" + (SessionTokenIdentity.sessionId(token) ?? "")
    }
    func store(key: String, value: Data) throws {
        try state.withLock { state in
            if let attempt = AuthAttemptContext.revision, attempt != state.revision { throw CancellationError() }
            if let token = Self.tokenKey(value), let ticket = state.refreshTicket, ticket.token == token {
                state.refreshTicket = nil
                guard ticket.revision == state.revision else { throw CancellationError() }
            }
            let previous = try underlying.retrieve(key: key).flatMap(Self.owner)
            try underlying.store(key: key, value: value)
            if let owner = Self.owner(value), owner != previous { state.revision &+= 1 }
        }
    }
    func retrieve(key: String) throws -> Data? { try underlying.retrieve(key: key) }
    func remove(key: String) throws {
        try state.withLock { state in
            if let attempt = AuthAttemptContext.revision, attempt != state.revision { throw CancellationError() }
            let hadOwner = try underlying.retrieve(key: key).flatMap(Self.owner) != nil
            try underlying.remove(key: key)
            if hadOwner { state.revision &+= 1 }
        }
    }
}
