import Foundation

/// A link to one poll: the web page `https://meetful.app/polls/<UUID>`, which iOS hands to the
/// app as a universal link, or `meetingscheduler://polls/<UUID>` on the app's own scheme.
///
/// The web's `apple-app-site-association` file claims only that path shape, so other pages on
/// the site keep opening in the browser. Opening a link grants nothing: the poll screen still
/// loads through the server, which shows the poll only to its creator and participants.
public struct PollLink: Equatable, Sendable {
    public let pollId: UUID

    /// Returns nil for any other URL, including auth callbacks, so the caller can pass it on.
    public init?(url: URL) {
        guard url.user == nil, url.password == nil, url.port == nil else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        let idText: String
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host?.lowercased() == Self.webHost, segments.count == 2, segments[0] == "polls" else {
                return nil
            }
            idText = segments[1]
        case Config.appScheme:
            guard url.host == "polls", segments.count == 1 else { return nil }
            idText = segments[0]
        default:
            return nil
        }
        // Rejects `/polls/new` and any other segment that isn't a UUID.
        guard let pollId = UUID(uuidString: idText) else { return nil }
        self.pollId = pollId
    }

    private static let webHost = URL(string: Config.webURL)!.host!.lowercased()
}
