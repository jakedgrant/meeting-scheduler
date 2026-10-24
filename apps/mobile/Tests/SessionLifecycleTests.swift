@_spi(Internal) import RevenueCat
import Supabase
import XCTest

@testable import Shared

@MainActor
private final class Suspended<Value: Sendable> {
    var pending: [CheckedContinuation<Value, any Error>] = []
    func call() async throws -> Value {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ result: Result<Value, any Error>) { pending.removeFirst().resume(with: result) }
}

@MainActor
final class SessionLifecycleTests: XCTestCase {
    private func session(_ id: UUID, token: String = "token") -> Session {
        Session(
            accessToken: token, tokenType: "bearer", expiresIn: 3600, expiresAt: Date().timeIntervalSince1970 + 3600,
            refreshToken: "refresh",
            user: User(
                id: id, appMetadata: [:], userMetadata: [:], aud: "authenticated",
                createdAt: Date(), updatedAt: Date()))
    }
    private func client() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: URL(string: "https://session-tests.invalid")!, supabaseKey: "test-only",
            options: .init(auth: .init(storage: LifecycleAuthStorage(), autoRefreshToken: false)))
    }
    private func profile(_ id: UUID) -> Profile {
        Profile(id: id, email: "test@example.invalid", displayName: id.uuidString, avatarUrl: nil, timezone: "UTC")
    }
    private func customer(_ id: String) throws -> CustomerInfo {
        CustomerInfo(entitlements: EntitlementInfos(), requestDate: Date(), firstSeen: Date(), originalAppUserId: id)
    }
    private func offerings(_ id: String) -> Offerings {
        .preview(
            offerings: [Offering(identifier: id, serverDescription: id, availablePackages: [], webCheckoutUrl: nil)],
            currentOfferingID: id)
    }

    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous production work to reach checkpoint", file: file, line: line)
    }

    func testObserverWinsRestorationSameAccountRefreshAndDisposesExactlyOnce() async {
        let a = UUID()
        let b = UUID()
        let restore = Suspended<Session>()
        let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        var registrations = 0
        var transitions: [UUID?] = []
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: {
                    registrations += 1
                    return events
                }, restore: { try await restore.call() },
                loadProfile: { self.profile($0) }, signOut: {}, accountChanged: { transitions.append($0) }, refreshCalendar: {}),
            client: client())
        let start = Task { await service.initialize() }
        await settle { restore.pending.count == 1 }
        emit.yield((.signedIn, session(b)))
        await settle { service.currentUserId == b }
        let generation = service.sessionGeneration
        emit.yield((.tokenRefreshed, session(b, token: "fresh")))
        await settle { service.currentSession?.accessToken == "fresh" }
        restore.finish(.success(session(a)))
        await start.value
        XCTAssertEqual(service.currentUserId, b)
        XCTAssertEqual(service.sessionGeneration, generation)
        await service.initialize()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(transitions.count, 1)
        service.dispose()
        emit.yield((.signedIn, session(a)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(service.currentUserId)
        XCTAssertNil(service.profile)
    }

    func testOfflineExpiryRefreshAndReauthenticationUseSessionOwnership() async {
        let a = UUID()
        let b = UUID()
        let expiry = Suspended<Void>()
        let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { events }, restore: { self.session(a) }, loadProfile: { self.profile($0) }, signOut: {},
                accountChanged: { _ in }, refreshCalendar: {}, waitForExpiry: { _ in try await expiry.call() }), client: client())
        await service.initialize()
        await settle { expiry.pending.count == 1 }
        let initial = service.sessionGeneration
        emit.yield((.tokenRefreshed, session(a, token: "refreshed")))
        await settle { expiry.pending.count == 2 }
        expiry.finish(.success(()))  // cancelled old deadline must not expire refreshed A
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.currentUserId, a)
        XCTAssertEqual(service.sessionGeneration, initial)
        expiry.finish(.success(()))  // SDK emits no event when offline refresh cannot finish
        await settle { service.currentUserId == nil }
        emit.yield((.signedIn, session(a, token: "reauthenticated")))
        await settle { expiry.pending.count == 1 }
        XCTAssertGreaterThan(service.sessionGeneration, initial)
        emit.yield((.signedIn, session(b)))
        await settle { expiry.pending.count == 2 }
        expiry.finish(.success(()))  // old A expiry cannot clear B
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.currentUserId, b)
        service.dispose()
        expiry.finish(.success(()))
    }

    func testExpiredRestorationNeverExposesAccountOwnedState() async {
        let a = UUID()
        var expired = session(a)
        expired.expiresAt = 1
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { AsyncStream { $0.finish() } }, restore: { expired },
                loadProfile: { _ in
                    XCTFail("Expired session must not load a profile")
                    return self.profile(a)
                },
                signOut: {}, accountChanged: { _ in }, refreshCalendar: {}), client: client())
        await service.initialize()
        XCTAssertNil(service.currentUserId)
        XCTAssertNil(service.profile)
        service.dispose()
    }

    func testBufferedAuthEventIsValidatedAgainAtControllerConsumption() async {
        let a = UUID()
        let b = UUID()
        let initial = session(a)
        var stored: Session? = initial
        let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { events }, restore: { initial }, loadProfile: { self.profile($0) }, signOut: {},
                accountChanged: { _ in }, refreshCalendar: {}, isStoredSession: { $0 == stored }), client: client())
        await service.initialize()
        XCTAssertEqual(service.currentUserId, a)
        // Events passed the producer's validation earlier, then storage advanced.
        stored = session(b)
        emit.yield((.signedOut, nil))
        emit.yield((.signedIn, session(a)))
        emit.yield((.signedIn, stored))
        await settle { service.currentUserId == b }
        XCTAssertEqual(service.profile?.id == a, false)
        service.dispose()
    }

    func testSlowProfileDoesNotBlockProviderOrLaterAccountAndLateFailureCannotReturnA() async {
        let a = UUID()
        let b = UUID()
        let profiles = Suspended<Profile>()
        let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        var transitions: [UUID?] = []
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { events }, restore: { throw URLError(.notConnectedToInternet) },
                loadProfile: { _ in try await profiles.call() }, signOut: {}, accountChanged: { transitions.append($0) },
                refreshCalendar: {}), client: client())
        await service.initialize()
        emit.yield((.signedIn, session(a)))
        await settle { profiles.pending.count == 1 }
        XCTAssertEqual(transitions.last!, a)
        emit.yield((.signedIn, session(b)))
        await settle { profiles.pending.count == 2 }
        profiles.finish(.failure(URLError(.notConnectedToInternet)))
        profiles.finish(.success(profile(b)))
        await settle { service.profile?.id == b }
        emit.yield((.signedOut, nil))  // external expiry/logout
        await settle { service.currentUserId == nil }
        XCTAssertNil(service.profile)
        service.dispose()
    }

    func testRapidAToBToARejectsOldSuccessfulProfileAndFailedInitialization() async {
        let a = UUID()
        let b = UUID()
        let restore = Suspended<Session>()
        let profiles = Suspended<Profile>()
        let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
        let service = AuthService(
            persistence: InMemoryPersistenceProvider(),
            dependencies: .init(
                events: { events }, restore: { try await restore.call() }, loadProfile: { _ in try await profiles.call() },
                signOut: {}, accountChanged: { _ in }, refreshCalendar: {}), client: client())
        let start = Task { await service.initialize() }
        await settle { restore.pending.count == 1 }
        emit.yield((.signedIn, session(a)))
        await settle { profiles.pending.count == 1 }
        emit.yield((.signedIn, session(b)))
        await settle { profiles.pending.count == 2 }
        emit.yield((.signedIn, session(a)))
        await settle { profiles.pending.count == 3 }
        let generation = service.sessionGeneration
        restore.finish(.failure(URLError(.notConnectedToInternet)))
        await start.value
        profiles.finish(.success(profile(a)))
        profiles.finish(.failure(URLError(.timedOut)))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(service.profile)
        profiles.finish(.success(profile(a)))
        await settle { service.profile?.id == a }
        XCTAssertEqual(service.sessionGeneration, generation)
        service.dispose()
    }

    func testOldExplicitSignoutSuccessAndFailureCannotClearNewAccount() async {
        for fails in [false, true] {
            let a = UUID()
            let b = UUID()
            let logout = Suspended<Void>()
            let (events, emit) = AsyncStream<(event: AuthChangeEvent, session: Session?)>.makeStream()
            let service = AuthService(
                persistence: InMemoryPersistenceProvider(),
                dependencies: .init(
                    events: { events }, restore: { self.session(a) }, loadProfile: { self.profile($0) },
                    signOut: { try await logout.call() }, accountChanged: { _ in }, refreshCalendar: {}), client: client())
            await service.initialize()
            let task = Task { try? await service.signOut() }
            await settle { logout.pending.count == 1 }
            XCTAssertNil(service.currentUserId)
            emit.yield((.signedIn, session(b)))
            await settle { service.currentUserId == b }
            logout.finish(fails ? .failure(URLError(.timedOut)) : .success(()))
            await task.value
            XCTAssertEqual(service.currentUserId, b)
            service.dispose()
        }
    }

    func testProviderIdentitySerializesDelayedLoginSuccessAndFailureTowardLatestTarget() async throws {
        for fails in [false, true] {
            let old = Suspended<CustomerInfo?>()
            var externalIdentity = "anonymous"
            var calls: [String] = []
            let service = PurchaseService(
                dependencies: .init(
                    login: { target in
                        calls.append("login:\(target)")
                        if calls.count == 1 {
                            let info = try await old.call()
                            externalIdentity = target  // SDK side effect happens after suspension
                            return info
                        }
                        externalIdentity = target
                        return try self.customer(target)
                    },
                    logout: {
                        calls.append("logout")
                        externalIdentity = "anonymous"
                    }, currentUserId: { externalIdentity }, customerInfo: { nil }, offerings: { nil }))
            service.resetAccountState(userId: "A")
            await settle { old.pending.count == 1 }
            service.resetAccountState(userId: nil)
            service.resetAccountState(userId: "B")
            XCTAssertEqual(calls, ["login:A"])
            old.finish(fails ? .failure(URLError(.timedOut)) : .success(try customer("A")))
            await service.waitForIdentityReconciliation()
            XCTAssertEqual(calls, ["login:A", "login:B"])
            XCTAssertEqual(externalIdentity, "B")
            XCTAssertEqual(service.customerInfo?.originalAppUserId, "B")
        }
    }

    func testProviderLateCustomerInfoCannotReplaceBAndOfflineIdentityCanRetry() async throws {
        let information = Suspended<CustomerInfo?>()
        let oldInfo = try customer("A")
        var external = "A"
        var attempts = 0
        let service = PurchaseService(
            dependencies: .init(
                login: { target in
                    attempts += 1
                    if attempts == 1 { throw URLError(.notConnectedToInternet) }
                    external = target
                    return try self.customer(target)
                }, logout: {}, currentUserId: { external }, customerInfo: { try await information.call() }, offerings: { nil }))
        service.resetAccountState(userId: "A")
        await service.waitForIdentityReconciliation()
        service.retryAccountIdentity()
        await service.waitForIdentityReconciliation()
        XCTAssertEqual(attempts, 2)
        let read = Task { await service.refreshCustomerInfo() }
        await settle { information.pending.count == 1 }
        service.resetAccountState(userId: "B")
        await service.waitForIdentityReconciliation()
        information.finish(.success(oldInfo))
        await read.value
        XCTAssertEqual(service.customerInfo?.originalAppUserId, "B")
        XCTAssertEqual(external, "B")
    }

    func testOldProviderLogoutCannotUndoReauthenticatedA() async {
        for fails in [false, true] {
            let logout = Suspended<Void>()
            var externalIdentity = "A"
            var calls: [String] = []
            let service = PurchaseService(
                dependencies: .init(
                    login: { target in
                        calls.append(target)
                        externalIdentity = target
                        return nil
                    },
                    logout: {
                        calls.append("logout")
                        try await logout.call()
                        externalIdentity = "anonymous"
                    },
                    currentUserId: { externalIdentity }, customerInfo: { nil }, offerings: { nil }))
            service.resetAccountState(userId: nil)
            await settle { logout.pending.count == 1 }
            service.resetAccountState(userId: "A")
            logout.finish(fails ? .failure(URLError(.timedOut)) : .success(()))
            await service.waitForIdentityReconciliation()
            XCTAssertEqual(externalIdentity, "A")
            XCTAssertEqual(calls, ["logout", "A"])
        }
    }

    func testOldOfferingCleanupCannotStopNewAccountLoading() async {
        let offerings = Suspended<Offerings?>()
        var external = "A"
        let service = PurchaseService(
            dependencies: .init(
                login: {
                    external = $0
                    return nil
                }, logout: {}, currentUserId: { external }, customerInfo: { nil }, offerings: { try await offerings.call() }))
        service.resetAccountState(userId: "A")
        let first = Task { await service.loadOfferings() }
        await settle { offerings.pending.count == 1 }
        service.resetAccountState(userId: "B")
        let second = Task { await service.loadOfferings() }
        await settle { offerings.pending.count == 2 }
        offerings.finish(.failure(URLError(.timedOut)))
        await first.value
        XCTAssertTrue(service.isLoading)
        offerings.finish(.success(self.offerings("B")))
        await second.value
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.currentOffering?.identifier, "B")
    }

    func testLatePopulatedOfferingsCannotReplaceCurrentB() async {
        let reads = Suspended<Offerings?>()
        var external = "A"
        let service = PurchaseService(
            dependencies: .init(
                login: {
                    external = $0
                    return nil
                }, logout: {}, currentUserId: { external }, customerInfo: { nil }, offerings: { try await reads.call() }))
        service.resetAccountState(userId: "A")
        let old = Task { await service.loadOfferings() }
        await settle { reads.pending.count == 1 }
        service.resetAccountState(userId: "B")
        let current = Task { await service.loadOfferings() }
        await settle { reads.pending.count == 2 }
        reads.pending.removeLast().resume(returning: offerings("B"))
        await current.value
        XCTAssertEqual(service.currentOffering?.identifier, "B")
        reads.finish(.success(offerings("A")))
        await old.value
        XCTAssertEqual(service.currentOffering?.identifier, "B")
    }

    func testRestoreFinishesUnderAThenReconcilesBOnSuccessAndFailure() async throws {
        for fails in [false, true] {
            let restore = Suspended<CustomerInfo>()
            var external = "A"
            var calls: [String] = []
            let service = PurchaseService(
                dependencies: .init(
                    login: { target in
                        calls.append("login:" + target)
                        external = target
                        return try self.customer(target)
                    }, logout: {}, currentUserId: { external }, customerInfo: { nil }, offerings: { nil },
                    restore: {
                        calls.append("restore:" + external)
                        let info = try await restore.call()
                        calls.append("restored:" + external)
                        return info
                    }))
            service.resetAccountState(userId: "A")
            await service.waitForIdentityReconciliation()
            let pending = Task { try await service.restorePurchases() }
            await settle { restore.pending.count == 1 }
            service.resetAccountState(userId: "B")
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(external, "A")
            XCTAssertNil(service.customerInfo)
            restore.finish(fails ? .failure(URLError(.timedOut)) : .success(try customer("A")))
            do {
                _ = try await pending.value
                XCTFail("A restore must not publish into B")
            } catch { XCTAssertTrue(error is CancellationError) }
            await service.waitForIdentityReconciliation()
            XCTAssertEqual(external, "B")
            XCTAssertEqual(service.customerInfo?.originalAppUserId, "B")
            XCTAssertEqual(calls.first, "login:A")
            XCTAssertEqual(calls.last, "login:B")
            if !fails { XCTAssertTrue(calls.contains("restored:A")) }
        }
    }

    func testBOfferingsWaitForProviderIdentityRatherThanLoadingUnderA() async throws {
        let login = Suspended<CustomerInfo?>()
        var external = "A"
        var offerOwners: [String] = []
        let service = PurchaseService(
            dependencies: .init(
                login: { target in
                    if target == "B" { _ = try await login.call() }
                    external = target
                    return try self.customer(target)
                }, logout: {}, currentUserId: { external }, customerInfo: { nil },
                offerings: {
                    offerOwners.append(external)
                    return self.offerings(external)
                }))
        service.resetAccountState(userId: "B")
        await settle { login.pending.count == 1 }
        let pending = Task { await service.loadOfferings() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(offerOwners, [])
        login.finish(.success(try customer("B")))
        await pending.value
        XCTAssertEqual(offerOwners, ["B"])
        XCTAssertEqual(service.currentOffering?.identifier, "B")
    }

    func testCalendarDevicePreferenceIsPartitionedAndLatePermissionCannotEnableB() async {
        let suite = "session-tests-\(UUID())"
        let access = Suspended<Bool>()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "appleCalendarEnabled")  // legacy unowned preference is ignored
        let service = CalendarService(preferences: defaults, client: client(), accessRequest: { try! await access.call() })
        let a = UUID()
        let b = UUID()
        service.accountDidChange(to: a)
        XCTAssertFalse(service.appleCalendarEnabled)
        let pending = Task { await service.setAppleCalendarEnabled(true) }
        await settle { access.pending.count == 1 }
        service.accountDidChange(to: b)
        access.finish(.success(true))
        await pending.value
        XCTAssertFalse(service.appleCalendarEnabled)
        service.accountDidChange(to: a)
        let enabled = Task { await service.setAppleCalendarEnabled(true) }
        await settle { access.pending.count == 1 }
        access.finish(.success(true))
        await enabled.value
        XCTAssertTrue(service.appleCalendarEnabled)
        service.accountDidChange(to: nil)
        XCTAssertFalse(service.appleCalendarEnabled)
        service.accountDidChange(to: b)
        XCTAssertFalse(service.appleCalendarEnabled)
        service.accountDidChange(to: a)
        XCTAssertTrue(service.appleCalendarEnabled)
    }
}
