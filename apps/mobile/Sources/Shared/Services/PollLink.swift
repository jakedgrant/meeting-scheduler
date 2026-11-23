import Foundation

/// Code invitations require confirmation before joining. Older UUID links still open detail.
public struct PollLink: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case poll(UUID)
        case invitation(String)
    }

    public let target: Target

    public static func shareURL(code: String) -> URL {
        URL(string: Config.webURL)!.appendingPathComponent("join").appendingPathComponent(code.uppercased())
    }

    /// Returns nil for unrelated or malformed URLs, including authentication callbacks.
    public init?(url: URL) {
        guard url.user == nil, url.password == nil, url.port == nil else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        let route: String
        let value: String
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host?.lowercased() == Self.webHost, segments.count == 2 else { return nil }
            route = segments[0]
            value = segments[1]
        case Config.appScheme:
            guard let host = url.host, segments.count == 1 else { return nil }
            route = host
            value = segments[0]
        default:
            return nil
        }
        if route == "polls", let id = UUID(uuidString: value) {
            target = .poll(id)
        } else if route == "join", value.utf8.count == 6,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            target = .invitation(value.uppercased())
        } else {
            return nil
        }
    }

    private static let webHost = URL(string: Config.webURL)!.host!.lowercased()
}
