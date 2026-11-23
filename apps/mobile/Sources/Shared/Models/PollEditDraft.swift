import Foundation

/// Editable details of an existing poll, without replacing its time options or votes.
public struct PollEditDraft: Equatable, Sendable {
    public let pollId: UUID
    public let creatorId: UUID
    public var title: String
    public var description: String
    public var location: String
    public var closesAt: Date?
    let originalTitle: String
    let originalDescription: String
    let originalLocation: String
    let originalClosesAt: Date?

    public init(poll: Poll) {
        pollId = poll.id
        creatorId = poll.creatorId
        title = poll.title
        description = poll.description ?? ""
        location = poll.location ?? ""
        closesAt = poll.closesAt
        originalTitle = title
        originalDescription = description
        originalLocation = location
        originalClosesAt = closesAt
    }

    public var hasChanges: Bool {
        title != originalTitle || description != originalDescription || location != originalLocation
            || closesAt != originalClosesAt
    }

    public func validationError(now: Date) -> String? {
        let titleCount = title.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard (1...200).contains(titleCount) else {
            return String(localized: "Enter a title of 1 to 200 characters.")
        }
        guard description.count <= 10_000 else {
            return String(localized: "Description must be 10,000 characters or less.")
        }
        guard location.count <= 1_000 else {
            return String(localized: "Location must be 1,000 characters or less.")
        }
        if closesAt != originalClosesAt, let closesAt, closesAt <= now {
            return String(localized: "Choose a response deadline in the future.")
        }
        return nil
    }
}
