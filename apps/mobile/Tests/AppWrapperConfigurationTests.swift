import Foundation
import Testing
@testable import Shared

/// The app wrapper's Info.plist and entitlements are only read at run time, so a missing key
/// builds cleanly and fails on a device. These tests read the files the wrapper target ships.
@Suite("App wrapper configuration")
struct AppWrapperConfigurationTests {
    private static let wrapper = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MeetingScheduler/MeetingScheduler")

    private static func propertyList(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: wrapper.appendingPathComponent(name))
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Registers the URL scheme that auth callbacks use")
    @MainActor
    func registersAuthCallbackScheme() throws {
        let info = try Self.propertyList("Info.plist")
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(Config.appScheme))
        let redirect = AuthCallbackIntentStore.redirectURL(attempt: UUID())
        #expect(redirect.scheme == Config.appScheme)
    }

    /// `CalendarService` asks for full access to read busy times and save the final meeting.
    /// Without this key, iOS 17 and later deny that request.
    @Test("Describes full calendar access")
    func describesFullCalendarAccess() throws {
        let info = try Self.propertyList("Info.plist")
        let description = try #require(info["NSCalendarsFullAccessUsageDescription"] as? String)
        #expect(!description.isEmpty)
    }

    @Test("Enables Sign in with Apple")
    func enablesSignInWithApple() throws {
        let entitlements = try Self.propertyList("MeetingScheduler.entitlements")
        #expect(entitlements["com.apple.developer.applesignin"] as? [String] == ["Default"])
    }
}
