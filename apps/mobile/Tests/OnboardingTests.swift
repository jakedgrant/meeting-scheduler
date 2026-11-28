import Foundation
import Supabase
import Testing

@testable import Shared

@Suite("Display name input")
struct DisplayNameInputTests {
    @Test("Typing stops at 40 characters")
    func limitsLength() {
        let long = String(repeating: "a", count: 45)
        #expect(DisplayNameInput.limited(long).count == DisplayNameInput.maxLength)
        #expect(DisplayNameInput.limited("Jake") == "Jake")
    }

    @Test("Stored names are trimmed, and a blank name is stored as none")
    func storesTrimmedNames() {
        #expect(DisplayNameInput.stored("  Jake Grant \n") == "Jake Grant")
        #expect(DisplayNameInput.stored("   ") == nil)
        #expect(DisplayNameInput.stored("") == nil)
    }
}

/// Answers each call when the test says so.
@MainActor
private final class Pending<Value: Sendable> {
    var waiting: [CheckedContinuation<Value, any Error>] = []
    var calls = 0
    func call() async throws -> Value {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func finish(_ result: Result<Value, any Error>) { waiting.removeFirst().resume(with: result) }
}

@MainActor
@Suite("Onboarding status")
struct OnboardingStatusTests {
    private struct Offline: Error {}

    /// Builds a signed-in service whose profile load and completion write the test answers.
    @MainActor
    private final class Harness {
        let account = UUID()
        let load = Pending<Profile>()
        let complete = Pending<Void>()
        var mirrored: Set<UUID> = []
        var retries: [Int] = []
        let events: AsyncStream<(event: AuthChangeEvent, session: Session?)>
        let emit: AsyncStream<(event: AuthChangeEvent, session: Session?)>.Continuation
        var service: AuthService!

        @MainActor
        init(mirrored: Bool = false) {
            (events, emit) = AsyncStream.makeStream()
            if mirrored { self.mirrored = [account] }
            let session = Self.session(account)
            var dependencies = AuthService.Dependencies(
                events: { [events] in events }, restore: { session },
                loadProfile: { [load] _ in try await load.call() }, signOut: {}, accountChanged: { _ in },
                refreshCalendar: {})
            dependencies.completeOnboarding = { [complete] in try await complete.call() }
            dependencies.isOnboardingMirrored = { [unowned self] in self.mirrored.contains($0) }
            dependencies.mirrorOnboarding = { [unowned self] in self.mirrored.insert($0) }
            dependencies.waitForRetry = { [unowned self] in self.retries.append($0) }
            service = AuthService(
                persistence: InMemoryPersistenceProvider(), dependencies: dependencies,
                client: SupabaseClient(
                    supabaseURL: URL(string: "https://onboarding-tests.invalid")!, supabaseKey: "test-only",
                    options: .init(auth: .init(storage: LifecycleAuthStorage(), autoRefreshToken: false))))
        }

        static func session(_ id: UUID) -> Session {
            Session(
                accessToken: "token", tokenType: "bearer", expiresIn: 3600,
                expiresAt: Date().timeIntervalSince1970 + 3600, refreshToken: "refresh",
                user: User(
                    id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated",
                    createdAt: Date(), updatedAt: Date()))
        }

        func profile(completedAt: Date?) -> Profile {
            Profile(id: account, email: "test@example.invalid", displayName: "Jake", onboardingCompletedAt: completedAt)
        }

        func signIn() async {
            await service.initialize()
            await settle { load.calls == 1 }
        }
    }

    private static func settle(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Expected asynchronous work to reach its checkpoint", sourceLocation: sourceLocation)
    }

    private func settle(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        await Self.settle(condition, sourceLocation: sourceLocation)
    }

    @Test("A first sign-in waits for the server profile, then requires onboarding")
    func firstSignInRequiresOnboarding() async {
        let harness = Harness()
        await harness.signIn()
        #expect(harness.service.onboardingStatus == .undetermined)
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        await settle { harness.service.onboardingStatus == .required }
        harness.service.dispose()
    }

    @Test("Completion stored on the server skips onboarding and is mirrored on this device")
    func serverCompletionIsMirrored() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.success(harness.profile(completedAt: Date())))
        await settle { harness.service.onboardingStatus == .notRequired }
        #expect(harness.mirrored == [harness.account])
        #expect(harness.complete.calls == 0)
        harness.service.dispose()
    }

    @Test("A mirrored completion skips onboarding offline and resends it when the server lacks it")
    func mirroredCompletionResends() async {
        let harness = Harness(mirrored: true)
        await harness.signIn()
        #expect(harness.service.onboardingStatus == .notRequired)
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        await settle { harness.complete.calls == 1 }
        #expect(harness.service.onboardingStatus == .notRequired)
        harness.complete.finish(.success(()))
        harness.service.dispose()
    }

    @Test("An unreachable profile shows the app instead of blocking it")
    func unreachableProfileDoesNotBlock() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.failure(Offline()))
        await settle { harness.service.onboardingStatus == .notRequired }
        #expect(harness.mirrored.isEmpty)
        harness.service.dispose()
    }

    @Test("Completing records it on the device at once and retries the server until it succeeds")
    func completionRetries() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        await settle { harness.service.onboardingStatus == .required }

        harness.service.completeOnboarding()
        #expect(harness.service.onboardingStatus == .notRequired)
        #expect(harness.mirrored == [harness.account])
        await settle { harness.complete.calls == 1 }
        harness.complete.finish(.failure(Offline()))
        await settle { harness.complete.calls == 2 }
        harness.complete.finish(.success(()))
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.complete.calls == 2)
        #expect(harness.retries == [0])
        harness.service.dispose()
    }

    @Test("Completion writes give up after the attempt limit")
    func completionGivesUp() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        harness.service.completeOnboarding()
        for attempt in 1...AuthService.onboardingWriteAttempts {
            await settle { harness.complete.calls == attempt }
            harness.complete.finish(.failure(Offline()))
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.complete.calls == AuthService.onboardingWriteAttempts)
        #expect(harness.service.onboardingStatus == .notRequired)
        harness.service.dispose()
    }

    @Test("Another account starts undetermined, and the old account's retry stops")
    func accountChangeResets() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        harness.service.completeOnboarding()
        await settle { harness.complete.calls == 1 }

        let other = UUID()
        harness.emit.yield((.signedIn, Harness.session(other)))
        await settle { harness.service.currentUserId == other }
        #expect(harness.service.onboardingStatus == .undetermined)
        harness.complete.finish(.failure(Offline()))
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.complete.calls == 1)
        harness.service.dispose()
    }

    @Test("Saving a name shows it at once, and a blank name shows as no name")
    func nameIsShownAtOnce() async {
        let harness = Harness()
        await harness.signIn()
        harness.load.finish(.success(harness.profile(completedAt: nil)))
        await settle { harness.service.profile != nil }
        harness.service.saveOnboardingName("  Jacob  ")
        #expect(harness.service.profile?.displayName == "Jacob")
        harness.service.saveOnboardingName("   ")
        #expect(harness.service.profile?.displayName == nil)
        harness.service.dispose()
    }
}
