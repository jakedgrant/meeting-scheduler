import Foundation

public enum Config {
    // MARK: - Supabase
    public static let supabaseURL = "https://jaymsvyddyvvozzrgfpg.supabase.co"
    public static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY5NjE1NjMsImV4cCI6MjA4MjUzNzU2M30.2_N53weaaa0L-hZ11NXNatbhGyPWOyW57PERQDmvmTM"

    // MARK: - RevenueCat
    public static let revenueCatAPIKey = "appl_IjDPPTTLISbUsrRUeNXXBGrlLMt"

    // MARK: - App
    public static let appName = "Meetful"
    public static let appScheme = "meetingscheduler"
    public static let webURL = "https://meetful.app"

    // MARK: - App Review
    /// The account App Review signs in with. It's the only account with a password, so the
    /// sign-in screen asks for one only when this email is entered.
    public static let appReviewEmail = "appreview@meetful.app"

    /// Whether `email` names the App Review account, ignoring case and surrounding whitespace.
    public static func isAppReviewAccount(_ email: String) -> Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == appReviewEmail
    }
}
