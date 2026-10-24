import Auth
import Foundation

/// A pending link belongs to the auth state that requested it, including a cold
/// launch. The SDK still validates PKCE/state and link expiry on the server.
@MainActor
final class AuthCallbackIntentStore {
    struct Intent: Codable {
        let id: UUID
        let accountId: UUID?
        let sessionId: String?
    }
    private let defaults: UserDefaults
    private let key = "auth.pending-callback.v1"
    init(defaults: UserDefaults) { self.defaults = defaults }
    var current: Intent? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Intent.self, from: $0) }
    }
    @discardableResult func begin(session: Session?) -> UUID {
        let intent = Intent(id: UUID(), accountId: session?.user.id, sessionId: Self.sessionId(session))
        defaults.set(try? JSONEncoder().encode(intent), forKey: key)
        return intent.id
    }
    func matches(session: Session?) -> Bool {
        guard let current else { return false }
        return current.accountId == session?.user.id && current.sessionId == Self.sessionId(session)
    }
    static func redirectURL(attempt id: UUID) -> URL {
        var parts = URLComponents()
        parts.scheme = Config.appScheme
        parts.host = "auth"
        parts.path = "/callback"
        parts.queryItems = [URLQueryItem(name: "attempt", value: id.uuidString)]
        return parts.url!
    }
    /// Reject stale or malformed links before consuming the current intent or
    /// allowing the SDK to touch its shared PKCE verifier/session storage.
    func accepts(url: URL, session: Session?) -> Bool {
        guard let current, matches(session: session), url.scheme == Config.appScheme,
            url.host == "auth", url.path == "/callback", url.user == nil,
            url.password == nil, url.port == nil, url.fragment == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let attempts = parts.queryItems?.filter { $0.name == "attempt" } ?? []
        guard attempts.count == 1, let value = attempts[0].value,
            UUID(uuidString: value) == current.id
        else { return false }
        let codes = parts.queryItems?.filter { $0.name == "code" } ?? []
        let errors = parts.queryItems?.filter { $0.name == "error" } ?? []
        return (codes.count == 1 && codes[0].value?.isEmpty == false && errors.isEmpty)
            || (codes.isEmpty && errors.count == 1 && errors[0].value?.isEmpty == false)
    }
    func clear(id: UUID? = nil) {
        if id == nil || current?.id == id { defaults.removeObject(forKey: key) }
    }
    static func sessionId(_ session: Session?) -> String? {
        SessionTokenIdentity.sessionId(session?.accessToken)
    }
}

enum SessionTokenIdentity {
    static func sessionId(_ accessToken: String?) -> String? {
        guard let token = accessToken?.split(separator: "."), token.count >= 2 else { return nil }
        var payload = String(token[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["session_id"] as? String
    }
}

enum AuthAttemptContext {
    @TaskLocal static var revision: UInt64?
    @TaskLocal static var intentId: UUID?
}
