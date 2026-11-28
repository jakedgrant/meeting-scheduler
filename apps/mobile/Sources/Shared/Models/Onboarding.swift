import Foundation

/// Whether the signed-in account still has to see onboarding.
public enum OnboardingStatus: Sendable, Equatable {
    /// The profile has not loaded yet, so it is not known.
    case undetermined
    /// The server profile has no completion and this device has none recorded.
    case required
    /// Completed or skipped on any device, or the profile could not be loaded. Onboarding never
    /// blocks the app, so an unreachable profile shows the app and asks again on a later launch.
    case notRequired
}

/// The rules for the display name typed during onboarding.
public enum DisplayNameInput {
    public static let maxLength = 40

    /// `text` cut to `maxLength` characters, so typing past the limit does nothing.
    public static func limited(_ text: String) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) : text
    }

    /// The name to store: trimmed, with an empty name stored as nil so others see "Anonymous".
    public static func stored(_ text: String) -> String? {
        let trimmed = limited(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
