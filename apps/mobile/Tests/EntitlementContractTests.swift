import XCTest
@testable import Shared

/// F23: the client's copies of the funding tiers and their limits match
/// packages/shared-config/entitlements.json. The database suite checks the same file against
/// the creation command, so a limit can't change on one side only.
final class EntitlementContractTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Limits: Decodable {
            let max_active_polls: Int?
            let max_participants_per_poll: Int
        }
        struct Tier: Decodable { let limits: Limits }
        let entitlements: [String: Tier]
        let free_tier: Tier
        let event_pass: Tier

        /// Every funding tier by the identifier the server returns for it.
        var tiers: [String: Tier] {
            // `testSubscriptionAccessUsesTheFixtureIdentifiers` fails if a subscription reuses one of these names.
            entitlements.merging(["free": free_tier, "event_pass": event_pass]) { $1 }
        }
    }

    private static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packages/shared-config/entitlements.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    func testEveryFixtureTierHasOneClientCase() {
        XCTAssertEqual(
            Set(PollCreationEntitlement.allCases.map(\.rawValue)), Set(Self.fixture.tiers.keys))
    }

    func testParticipantLimitsMatchTheFixture() throws {
        for entitlement in PollCreationEntitlement.allCases {
            let tier = try XCTUnwrap(Self.fixture.tiers[entitlement.rawValue], entitlement.rawValue)
            XCTAssertEqual(entitlement.participantLimit, tier.limits.max_participants_per_poll, entitlement.rawValue)
        }
    }

    /// The fixture writes an unlimited active-poll count as -1. An event pass has no count
    /// because each pass funds one poll.
    func testActivePollLimitsMatchTheFixture() throws {
        for entitlement in PollCreationEntitlement.allCases {
            let tier = try XCTUnwrap(Self.fixture.tiers[entitlement.rawValue], entitlement.rawValue)
            XCTAssertEqual(entitlement.allowsUnlimitedActivePolls, tier.limits.max_active_polls == -1, entitlement.rawValue)
        }
        XCTAssertNil(Self.fixture.event_pass.limits.max_active_polls)
    }

    func testAPollWithoutServerLimitsDefaultsToTheFreeCapacity() {
        XCTAssertEqual(
            Poll(creatorId: UUID(), title: "Draft").maxParticipants,
            Self.fixture.free_tier.limits.max_participants_per_poll)
    }

    func testSubscriptionAccessUsesTheFixtureIdentifiers() {
        let user = UUID()
        func subscription(_ entitlement: String) -> Subscription {
            Subscription(userId: user, entitlement: entitlement, isActive: true)
        }
        XCTAssertTrue(subscription("pro_access").hasProAccess)
        XCTAssertFalse(subscription("pro_access").hasTeamAccess)
        XCTAssertTrue(subscription("team_access").hasProAccess)
        XCTAssertTrue(subscription("team_access").hasTeamAccess)
        XCTAssertFalse(subscription("event_pass").hasProAccess)
        XCTAssertEqual(Set(Self.fixture.entitlements.keys), ["pro_access", "team_access"])
    }
}
