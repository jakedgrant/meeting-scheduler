# F19/F18 native read evidence

Baseline: freshly fetched `origin/main` at `d8cc2946e9fcb5f1ff8660461cd39a435c4246f2`. GitHub confirms #74 merged into main with this merge commit and exact head `29ddda0a903f32c8aa5dfe028047cffe04b21863`. Branch: `codex/f19-native-bounded-reads`.

The [read contract](../../read-contracts.md) is implemented by both native list/detail adapters. One summary request loads the first 50 polls, with database counts/ranges and a total; later pages load on demand. Both detail and response screens use bounded metadata plus complete response traversal. These changes use the existing F19 RPCs and introduce no migration or dependency update.

Source trees for the verified artifacts: `apps/mobile` `b4e35db6a03e8dcedaa9002a23f61ec4e799f59b`; `apps/android` `d9db2d7be72a825981df99ac6b0ef3bcacc2d2e1`. Supabase is unchanged at `89cc225b3f62fb5522968b91f888bc3ca972ec05`. [Extracted command results](verification.txt).

## Verification

| Check | Result |
| --- | --- |
| iOS package `build-for-testing`, then `test-without-building -only-testing:MeetingSchedulerTests` | 141 tests pass (126 baseline and 15 new transport tests) |
| Tracked iOS wrapper `xcodebuild … -scheme MeetingScheduler -destination 'generic/platform=iOS Simulator' build` | Build succeeds |
| Android `./gradlew --offline --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest` | 92 JVM tests pass (81 baseline and 11 new transport tests); both APK builds succeed |
| `npm run test:reads:db` | All 10 existing database read-contract tests pass against a fresh in-process migration replay |
| `git diff --check`; iOS package/wrapper lockfile diff | No whitespace errors; dependency pins unchanged |

The new tests use the pinned native SDKs with URLProtocol/MockEngine transport, without contacting an API. They verify a 52-poll list loaded in two requests, exact opaque cursors and request sizes, summary counts beyond the table row cap, and 1,200 responses loaded in three response pages. Regressions cover repeated list/response cursors, missing or mismatched totals, duplicate/foreign responses, truncated metadata, an account change between pages, and refresh superseding load-more. iOS also checks both cache providers preserve unloaded detail and replace visible list membership, plus stale-cache rejection after an incomplete/oversized response and the retained transport-failure fallback.

The original Android lifecycle fixture described a joined poll with the same creator as the signed-in owner. It now supplies a different creator, preserving the account-switch test while meeting the summary role contract.

## Review corrections

The delivery used Apple Platform Swift/concurrency/testing/type-modeling guidance and the universal delivery, simplification and hardening workflows. Two read-only reviewers covered correctness/concurrency and architecture/simplification. The initial review found these issues; each was fixed within the owned change:

- Refresh cleared committed pagination before its replacement validated. Creation or finalization could supersede that refresh and strand a partial list. Refresh now keeps committed cursor/total state until success; an interrupted first-ever refresh exposes retry state. Regression cases cover creation on both clients and finalization on iOS, with and without a committed first page. Failed-refresh retry starts at the first page even when an older continuation remains.
- Two iOS response-screen retries could finish in reverse order and let an obsolete failure replace a newer success. A screen request generation now guards publication and cleanup, including disappearance. This view wiring is statically reviewed and compiled; it has no simulator UI journey test.
- A first page with a larger total but no continuation could pass validation and evict unloaded iOS cache entries. Both adapters now check first-page continuation against the total before publication. Regression tests retain the prior list/detail on this malformed response.
- iOS append rewrote all accumulated cached list rows. It now persists only the new page, retaining the existing membership and off-page details. The two-page regression checks persisted membership from both pages. The focused simplification re-review found no remaining issue.

Final scoped correctness and claim re-review found no remaining actionable findings. The review used source inspection and the coordinator’s reported final check results; hosted execution and UI journeys remain pending. Passing tests are bounded evidence, not a claim of a transactionally consistent multi-page snapshot.

## Resources and limits

Xcode 27.1 compiles the unchanged Swift 6.2 package (Swift 6 language mode), with iOS 26 deployment and the installed iOS 27.1 SDK. Derived data and a private copy of locked source packages are under `/private/tmp/f19-native-ios`. The task owns fresh iPhone 17 Pro / iOS 27.0 simulator `760B5F69-356B-481F-8723-BD45F88E8FCC`; it was shut down and deleted at 2026-10-26T02:10:12Z. No existing simulator was used.

Android uses the existing JDK 21 and SDK read only, with copied Gradle cache `/private/tmp/f19-native-gradle` and the ignored CI placeholder Firebase configuration. Gradle uses `--no-daemon`. No Android emulator, device, provider, hosted database or application server was used. The SDK emits existing deprecation diagnostics; Xcode also warns about the URLProtocol Sendable conformance in transport fixtures. The new fixture has no mutable subclass state and protects its registry and queued request state with `Mutex`.

The database check uses in-process PGlite; it does not establish deployed grants, gateway behavior or query performance. No write path changes, so the PostgreSQL lock-race suites were not repeated. No backend, web, provider or hosted configuration changed.

Before release, apply the already merged F19 migration `20261025062518` in order. Guest-detail response paging, legacy RPC retirement, representative query plans/payload sizes, F16 calendar coverage and F20 realtime remain open. Older raw native read helpers remain public for compatibility, but these list/detail/response screens no longer call them. Native UI wiring is compiled, with no list/detail UI automation or screenshots claimed.
