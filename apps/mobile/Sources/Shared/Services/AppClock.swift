import Foundation

/// The wall clock that services, persistence and screen workflows read.
///
/// `AppServices` owns one clock and passes it to the persistence provider, `AuthService` and
/// the views, so a test or preview can fix the time that deadlines, freshness and session
/// expiry are judged against.
public struct AppClock: Sendable {
    private let read: @Sendable () -> Date

    /// Reads the time from `now` on every access.
    public init(now: @escaping @Sendable () -> Date) {
        read = now
    }

    /// The current time.
    public var now: Date { read() }

    /// The device's clock.
    public static let system = AppClock { Date() }

    /// A clock that always reads `date`.
    public static func fixed(_ date: Date) -> AppClock {
        AppClock { date }
    }
}
