# iOS persistence remediation evidence

The SwiftData PR now merges main `6f2c547dbbe51ad78c2ca6aab1bdbaa3005be3d1` without rewriting its history. The changes address the iOS cache defects in review findings 2–4 (F11 and the iOS portion of F12).

## Behavior

- Auth and poll services share one cache context. Every identity transition clears profile, poll lists, counts, ranges, calendar connection state and purchase entitlements synchronously. The auth listener continues consuming events while profile/provider requests are suspended. Account generations prevent old poll/profile/purchase completions from publishing into a later identity.
- Persistent store names contain the account UUID. Signed-out state uses an ephemeral store; switching away clears the previous account's store. The old unpartitioned `default.store` is never opened. This unreleased application deliberately discards that development cache rather than migrating unowned records.
- List upserts update only list freshness. An explicit persisted list-membership marker prevents a cached nonmember invitation from appearing as a joined poll on offline list failure. Latest-request generations prevent older same-account list/detail reads from restoring rows removed by a newer read. A separate detail timestamp is set only after a complete detail snapshot, including a legitimately empty snapshot. Partial/paginated poll reads use upserts; the complete member list uses an explicitly named replacement operation.
- Complete detail reads replace children and responses transactionally. Complete lists evict inaccessible/deleted polls, while scoped child reads reconcile missing rows. Mutations invalidate affected detail (including cached children), and a per-poll generation rejects a detail read that began before a mutation or list eviction. An authoritative not-found/permission result evicts detail rather than returning stale data.

## Verification (October 22–23, 2026)

Xcode 27.1 (27A9269), Swift 6.4. The eight package revisions came from an isolated copy of existing local checkouts, including RevenueCat 5.97.0 and Supabase 2.39.0. No provider service, hosted Supabase project or localhost server was contacted by the tests.

- Full package `build-for-testing`, generic iOS Simulator: **passed**.
- Full package `test`, dedicated iPhone 18 Pro / iOS 27 simulator: **33 tests passed**, zero failures (23 provider tests, nine service lifecycle tests, one pre-existing placeholder). The service tests use injected identity/network operations and the production SwiftData provider in memory.
- An additional dependency-free macOS harness compiling the actual production models/providers and the same provider test source: **23 tests passed**, zero failures. Core Data emitted sandbox notification registration warnings in that harness; assertions and the iOS simulator run passed.
- `git diff --check`: passed.

The service regressions cover A → sign-out → B with a failed B request; late A list/detail completions; a remotely deleted poll followed by offline loading; and mutation invalidation while an older detail request is suspended. Provider regressions cover account transitions, expired detail surviving list refresh, child/response deletion and full-list versus partial-list semantics.

Package tests can run through Xcode's generated package workspace. After opening `apps/mobile/Package.swift` once in Xcode, use:

```bash
xcodebuild -workspace apps/mobile/.swiftpm/xcode/package.xcworkspace \
  -scheme MeetingScheduler-Package -configuration Debug \
  -destination 'platform=iOS Simulator,id=<reserved-device>' \
  -derivedDataPath /tmp/meeting-scheduler-ios-tests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The simulator run is service/provider regression evidence, not a signed-in UI journey or proof that all platform account-lifecycle work in F12 is complete. Web/Android lifecycle, hosted credentials and physical-device behavior remain separately scoped. The final integration owner must rerun the suites on the integrated PR head.
