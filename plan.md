# Plan: SwiftData Local Persistence Layer

## Goals
- Cache data locally so views render instantly without waiting for network
- Resolve conflicts between local cache and remote server state
- Keep the persistence layer modular so previews and tests never need a real database
- Preserve existing testability of all services and preview-friendliness of all views

## Architecture Overview

```
Views
  ↓ (read via @Environment)
Service Protocols (unchanged)
  ↓ (implemented by)
Real Services (modified to use persistence internally)
  ├── Remote: Supabase (existing, unchanged)
  └── Local: PersistenceProvider (NEW, injected)

Mocks (unchanged — previews and tests bypass persistence entirely)
```

The persistence layer is an **implementation detail inside the real services**. It does not leak into service protocols, views, or mocks. This means:
- **No changes** to `PollServiceProtocol`, `AuthServiceProtocol`, or any other protocol
- **No changes** to any mock service or SwiftUI preview
- **No changes** to any view
- Tests using mocks continue to work identically

---

## Step 1: SwiftData Model Classes

**New directory:** `Sources/Shared/Persistence/SwiftDataModels/`

Create `@Model` classes that mirror the existing Codable structs. These are purely for local storage and never exposed to views or service protocols.

### Files to create:

**`PersistedPoll.swift`** — `@Model` class with all `Poll` fields plus `lastSyncedAt: Date`
- Relationships: `timeOptions: [PersistedTimeOption]`, `participants: [PersistedParticipant]`
- Uses `@Relationship(deleteRule: .cascade)` so deleting a poll cleans up children

**`PersistedTimeOption.swift`** — `@Model` class with all `PollTimeOption` fields plus `lastSyncedAt: Date`
- Inverse relationship to `PersistedPoll`
- Relationship: `responses: [PersistedAvailabilityResponse]`

**`PersistedParticipant.swift`** — `@Model` class with all `PollParticipant` fields plus `lastSyncedAt: Date`
- Stores `displayName` directly (flattened from `ParticipantProfile`)
- Inverse relationship to `PersistedPoll`
- Relationship: `responses: [PersistedAvailabilityResponse]`

**`PersistedAvailabilityResponse.swift`** — `@Model` class with all `AvailabilityResponse` fields plus `lastSyncedAt: Date`
- Inverse relationships to `PersistedTimeOption` and `PersistedParticipant`

**`PersistedProfile.swift`** — `@Model` class with all `Profile` fields plus `lastSyncedAt: Date`

Each `@Model` class gets:
- A `toModel()` method that converts to the corresponding Codable struct (e.g., `PersistedPoll → Poll`)
- A static `from(_:)` or `update(from:)` method that populates from the Codable struct
- A `lastSyncedAt: Date` field for cache staleness tracking
- `@Attribute(.unique)` on the `id` field so upserts work via SwiftData's built-in support

### Why separate model classes?

The existing structs (`Poll`, `PollTimeOption`, etc.) are value types with `Codable` + `CodingKeys` tuned for Supabase's snake_case JSON. SwiftData requires `@Model` reference types. Keeping them separate means:
- Network serialization stays clean — no SwiftData annotations cluttering Codable structs
- SwiftData schema can evolve independently (add indexes, relationships, migration)
- Views never import SwiftData — they continue using the lightweight structs

---

## Step 2: PersistenceProvider Protocol

**New file:** `Sources/Shared/Persistence/PersistenceProviderProtocol.swift`

```swift
@MainActor
public protocol PersistenceProviderProtocol: Sendable {
    // MARK: - Polls
    func savePolls(_ polls: [Poll]) throws
    func fetchAllPolls() throws -> [Poll]
    func fetchPoll(id: UUID) throws -> Poll?
    func deletePoll(id: UUID) throws

    // MARK: - Poll Detail (composite)
    func savePollDetail(_ detail: PollDetail) throws
    func fetchPollDetail(id: UUID) throws -> PollDetail?

    // MARK: - Poll Metadata (participant counts, time ranges)
    func savePollParticipantCount(_ count: Int, for pollId: UUID) throws
    func fetchPollParticipantCounts() throws -> [UUID: Int]
    func savePollTimeRange(earliest: Date, latest: Date, for pollId: UUID) throws
    func fetchPollTimeRanges() throws -> [UUID: (earliest: Date, latest: Date)]

    // MARK: - Time Options
    func saveTimeOptions(_ options: [PollTimeOption], for pollId: UUID) throws
    func fetchTimeOptions(for pollId: UUID) throws -> [PollTimeOption]

    // MARK: - Participants
    func saveParticipants(_ participants: [PollParticipant], for pollId: UUID) throws
    func fetchParticipants(for pollId: UUID) throws -> [PollParticipant]

    // MARK: - Availability Responses
    func saveResponses(_ responses: [AvailabilityResponse]) throws
    func fetchResponses(for participantIds: [UUID]) throws -> [AvailabilityResponse]

    // MARK: - Profile
    func saveProfile(_ profile: Profile) throws
    func fetchProfile(id: UUID) throws -> Profile?

    // MARK: - Cache Management
    func isFresh(_ entityId: UUID, maxAge: TimeInterval) -> Bool
    func clearAll() throws
}
```

This protocol uses only the existing Codable struct types — no SwiftData types leak through. All conversion happens inside the implementations.

The `PollDetail` composite type (introduced in the latest main branch) bundles a poll with its time options, participants, and responses. The persistence layer supports saving and fetching this as a unit so that `loadPollDetail` can return cached detail views instantly.

The `pollParticipantCounts` and `pollTimeRanges` metadata (also from main) are persisted alongside polls so `PollRowView` can render complete list items from cache without additional fetches.

---

## Step 3: SwiftData Implementation

**New file:** `Sources/Shared/Persistence/SwiftDataPersistenceProvider.swift`

```swift
@MainActor
public final class SwiftDataPersistenceProvider: PersistenceProviderProtocol {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    public init(inMemory: Bool = false) {
        let schema = Schema([
            PersistedPoll.self,
            PersistedTimeOption.self,
            PersistedParticipant.self,
            PersistedAvailabilityResponse.self,
            PersistedProfile.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        self.modelContainer = try! ModelContainer(for: schema, configurations: [config])
        self.modelContext = modelContainer.mainContext
    }
    // ... CRUD implementations using modelContext
}
```

Each method:
1. Converts incoming Codable structs → `@Model` objects (or updates existing via `@Attribute(.unique)` on id)
2. Performs SwiftData operations
3. Converts `@Model` objects → Codable structs on reads
4. Sets `lastSyncedAt = Date()` on every save

The `inMemory: Bool` parameter enables creating lightweight instances for integration tests without touching disk.

---

## Step 4: InMemory Implementation (for Previews & Tests)

**New file:** `Sources/Shared/Persistence/InMemoryPersistenceProvider.swift`

A simple dictionary-backed implementation with no SwiftData dependency at all:

```swift
@MainActor
public final class InMemoryPersistenceProvider: PersistenceProviderProtocol {
    private var polls: [UUID: Poll] = [:]
    private var timeOptions: [UUID: [PollTimeOption]] = [:]  // keyed by pollId
    private var participants: [UUID: [PollParticipant]] = [:] // keyed by pollId
    private var responses: [UUID: [AvailabilityResponse]] = [:] // keyed by participantId
    private var profiles: [UUID: Profile] = [:]
    private var syncTimestamps: [UUID: Date] = [:]
    // ... implementations using dictionaries
}
```

This implementation:
- Has zero external dependencies (no SwiftData, no Supabase)
- Works in any context including previews and unit tests
- Can be pre-populated with test data
- Is what the default `ServiceEnvironment` uses for previews if needed

---

## Step 5: Inject PersistenceProvider into Real Services

### Modify `PollService`

**File:** `Sources/Shared/Services/PollService.swift`

Add a `persistence` dependency:

```swift
@MainActor
@Observable
public final class PollService: PollServiceProtocol {
    public static let shared = PollService()

    private let supabase = SupabaseService.shared.client
    private let persistence: PersistenceProviderProtocol

    private init(persistence: PersistenceProviderProtocol = SwiftDataPersistenceProvider()) {
        self.persistence = persistence
    }

    // Test-friendly initializer
    public init(persistence: PersistenceProviderProtocol) {
        self.persistence = persistence
    }
}
```

Modify load methods to follow the **cache-then-network** pattern:

```swift
public func loadMyPolls() async {
    // 1. Return cached data immediately (polls + metadata)
    if let cached = try? persistence.fetchAllPolls(), !cached.isEmpty {
        createdPolls = cached.filter { $0.creatorId == AuthService.shared.currentUserId }
        joinedPolls = cached.filter { $0.creatorId != AuthService.shared.currentUserId }
        myPolls = createdPolls + joinedPolls
        pollParticipantCounts = (try? persistence.fetchPollParticipantCounts()) ?? [:]
        pollTimeRanges = (try? persistence.fetchPollTimeRanges()) ?? [:]
    }

    // 2. Fetch from server
    isLoading = myPolls.isEmpty  // only show spinner on first load
    defer { isLoading = false }

    do {
        let response = try await supabase.rpc("get_user_participated_polls").execute().value
        // 3. Persist polls + metadata and update state
        let allPolls = response.created_polls + response.joined_polls
        try? persistence.savePolls(allPolls)
        for (pollId, count) in response.participant_counts {
            try? persistence.savePollParticipantCount(count, for: pollId)
        }
        for (pollId, range) in response.time_ranges {
            try? persistence.savePollTimeRange(earliest: range.earliest, latest: range.latest, for: pollId)
        }
        createdPolls = response.created_polls
        joinedPolls = response.joined_polls
        myPolls = createdPolls + joinedPolls
        pollParticipantCounts = response.participant_counts
        pollTimeRanges = response.time_ranges
    } catch {
        print("Failed to load polls: \(error)")
        // Cache still displayed — user sees stale data rather than nothing
    }
}

public func loadPollDetail(id: UUID) async -> PollDetail? {
    // 1. Return cached detail if fresh
    if let cached = try? persistence.fetchPollDetail(id: id),
       persistence.isFresh(id, maxAge: 300) {
        return cached
    }

    // 2. Fetch from server
    guard let response = try? await supabase.from("polls")
        .select("*, poll_time_options(*), poll_participants(*, profiles(*))")
        .eq("id", value: id).single().execute().value else {
        // Fall back to stale cache on network failure
        return try? persistence.fetchPollDetail(id: id)
    }

    // 3. Persist and return
    let detail = PollDetail(poll: response.poll, ...)
    try? persistence.savePollDetail(detail)
    return detail
}
```

Modify write methods to persist on success:

```swift
public func createPoll(...) async throws -> Poll {
    // 1. Write to server (source of truth)
    let response: Poll = try await supabase.from("polls").insert(...).select().single().execute().value
    // 2. Persist locally
    try? persistence.savePolls([response])
    // 3. Update in-memory state
    myPolls.insert(response, at: 0)
    return response
}
```

### Modify `AuthService`

**File:** `Sources/Shared/Services/AuthService.swift`

Cache the user's `Profile`:

```swift
private let persistence: PersistenceProviderProtocol

func loadProfile() async {
    // Return cached profile immediately
    if let userId = currentUser?.id,
       let cached = try? persistence.fetchProfile(id: userId) {
        self.profile = cached
    }

    // Then refresh from server
    // ... existing Supabase fetch ...
    if let fresh = fetchedProfile {
        try? persistence.saveProfile(fresh)
        self.profile = fresh
    }
}
```

---

## Step 6: Conflict Resolution Strategy

### Approach: **Server-Authoritative with Local Cache**

The Supabase server is the **single source of truth**. Local storage is a read-through cache. This is the right choice because:
- Multiple users modify the same polls (collaborative scheduling)
- Server enforces business rules (RLS policies, subscription limits)
- `updatedAt` timestamps are server-managed

### Read Conflicts (cache vs fresh fetch)

When fetched data arrives and differs from cached data:

```swift
func mergePolls(cached: [Poll], remote: [Poll]) -> [Poll] {
    var merged = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
    for remotePoll in remote {
        if let local = merged[remotePoll.id] {
            // Server wins if its updatedAt is >= local
            if remotePoll.updatedAt >= local.updatedAt {
                merged[remotePoll.id] = remotePoll
            }
        } else {
            // New from server — add it
            merged[remotePoll.id] = remotePoll
        }
    }
    return Array(merged.values)
}
```

In practice, since we always fetch the full list from the server, the merge is simple: **replace local with remote for any record where remote `updatedAt` >= local `updatedAt`**. Records that exist locally but not remotely (deleted on server) get removed.

### Write Conflicts

Writes always go to the server first. If the server rejects (e.g., poll was closed by another user), the error propagates to the UI. On success, the server response (with its canonical timestamps) replaces the local version. This avoids split-brain scenarios entirely.

### Cache Invalidation

- **On app launch:** Background refresh of all polls
- **Pull-to-refresh:** Full refresh, replace local cache
- **After mutation:** Update the specific record from the server response
- **On sign-out:** Call `persistence.clearAll()` to wipe cached data
- **Staleness check:** `isFresh(entityId, maxAge: 300)` (5-minute default TTL) — services can skip network calls for fresh data

---

## Step 7: Environment & DI Wiring

### Add PersistenceProvider to `ServiceEnvironment`

**File:** `Sources/Shared/Services/ServiceEnvironment.swift`

```swift
private struct PersistenceProviderKey: EnvironmentKey {
    static var defaultValue: any PersistenceProviderProtocol {
        MainActor.assumeIsolated { SwiftDataPersistenceProvider() }
    }
}

extension EnvironmentValues {
    public var persistenceProvider: any PersistenceProviderProtocol {
        get { self[PersistenceProviderKey.self] }
        set { self[PersistenceProviderKey.self] = newValue }
    }
}
```

This allows previews to inject `InMemoryPersistenceProvider` if needed, but since persistence is encapsulated inside services, previews using mock services won't need to inject it at all.

---

## Step 8: Testing Strategy

### Unit Tests for PersistenceProvider

**New file:** `Tests/PersistenceProviderTests.swift`

Test both implementations against the same protocol:

```swift
func testSaveAndFetchPolls_SwiftData() throws {
    let provider = SwiftDataPersistenceProvider(inMemory: true)
    let poll = Poll(creatorId: UUID(), title: "Test", shareCode: "ABC")
    try provider.savePolls([poll])
    let fetched = try provider.fetchAllPolls()
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched.first?.title, "Test")
}

func testSaveAndFetchPolls_InMemory() throws {
    let provider = InMemoryPersistenceProvider()
    // Same test logic — both conform to PersistenceProviderProtocol
}
```

### Unit Tests for Conflict Resolution

```swift
func testMerge_serverWinsWhenNewer() { ... }
func testMerge_localPreservedWhenServerOlder() { ... }
func testMerge_newRemoteRecordAdded() { ... }
func testMerge_deletedOnServerRemovedLocally() { ... }
```

### Integration Tests for Services with Persistence

```swift
func testPollService_returnsCachedDataWhenOffline() async {
    let persistence = InMemoryPersistenceProvider()
    // Pre-populate cache
    try persistence.savePolls([samplePoll])
    let service = PollService(persistence: persistence)
    // Service should return cached data even without network
}
```

### Existing Tests & Previews

- **Mock services are unchanged** — `MockPollService`, `MockAuthService`, etc. don't use persistence
- **All existing previews are unchanged** — they inject mocks via `.environment()`
- **Existing test patterns are unchanged** — tests that use mocks continue to work

---

## Step 9: Package.swift Update

No new external dependencies needed — SwiftData is a system framework (available on iOS 17+, and this project targets iOS 26+). Just add `import SwiftData` in the persistence files.

---

## New File Summary

| File | Purpose |
|------|---------|
| `Sources/Shared/Persistence/SwiftDataModels/PersistedPoll.swift` | `@Model` class for Poll |
| `Sources/Shared/Persistence/SwiftDataModels/PersistedTimeOption.swift` | `@Model` class for PollTimeOption |
| `Sources/Shared/Persistence/SwiftDataModels/PersistedParticipant.swift` | `@Model` class for PollParticipant |
| `Sources/Shared/Persistence/SwiftDataModels/PersistedAvailabilityResponse.swift` | `@Model` class for AvailabilityResponse |
| `Sources/Shared/Persistence/SwiftDataModels/PersistedProfile.swift` | `@Model` class for Profile |
| `Sources/Shared/Persistence/PersistenceProviderProtocol.swift` | Protocol for persistence abstraction |
| `Sources/Shared/Persistence/SwiftDataPersistenceProvider.swift` | Real SwiftData implementation |
| `Sources/Shared/Persistence/InMemoryPersistenceProvider.swift` | Dictionary-backed implementation for previews/tests |
| `Tests/PersistenceProviderTests.swift` | Tests for both provider implementations |
| `Tests/ConflictResolutionTests.swift` | Tests for merge/conflict logic |

## Modified Files

| File | Change |
|------|--------|
| `Sources/Shared/Services/PollService.swift` | Add persistence dependency, cache-then-network reads, persist-on-write |
| `Sources/Shared/Services/AuthService.swift` | Cache Profile locally |
| `Sources/Shared/Services/ServiceEnvironment.swift` | Add `PersistenceProviderKey` environment key |

## Files NOT Modified

| File | Why |
|------|-----|
| All service protocols | Persistence is an internal implementation detail |
| All mock services | Mocks don't use persistence |
| All views | Views consume service protocols, which are unchanged |
| All SwiftUI previews | Previews use mocks, which are unchanged |
| `Package.swift` | SwiftData is a system framework, no new dependencies |
| Existing model structs | Kept for network serialization, SwiftData uses separate `@Model` classes |
