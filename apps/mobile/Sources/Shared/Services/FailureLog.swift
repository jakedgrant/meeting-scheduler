import Foundation
import OSLog

/// A log of failures that marks their contents private.
///
/// An error's description can hold URLs, identifiers and server responses, so
/// only the operation and the error's domain and code are public. The
/// description is logged as private.
public struct FailureLog: Sendable {
    public static let auth = FailureLog(category: "auth")
    public static let purchases = FailureLog(category: "purchases")

    static let calendar = FailureLog(category: "calendar")
    static let polls = FailureLog(category: "polls")

    private let logger: Logger

    private init(category: String) {
        logger = Logger(subsystem: "com.jacobgrant.MeetingScheduler", category: category)
    }

    /// Records a failed operation.
    ///
    /// - Parameters:
    ///   - operation: A fixed description. Requiring a `StaticString` keeps
    ///     runtime values out of the public part of the message.
    ///   - error: The failure. Only its domain and code are public.
    public func record(_ operation: StaticString, error: any Error) {
        let summary = Self.summary(of: error)
        logger.error(
            "\(operation.description, privacy: .public): \(summary, privacy: .public) \(String(describing: error), privacy: .private)"
        )
    }

    /// The error's domain and code, which omit associated values.
    static func summary(of error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain)#\(error.code)"
    }
}
