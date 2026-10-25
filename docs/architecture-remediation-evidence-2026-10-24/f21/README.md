# F21 date/time contract evidence

Baseline: `origin/main` at `1cb20015d70cfb6b32dcb0f7498afcd0b6b39676` (PR #72 merged). Implementation commit `09fc202ea21563de0c7ff6daac975c59fb1609d6` on `claude/f21-date-time-contract`. Every result below ran on a working tree identical to that commit. One agent did all of the work; no subagents were used.

Subtree identities at `09fc202`: `apps/web` `4e5332a`, `apps/mobile` `6426bdf`, `apps/android` `719c540`, `supabase` `40bce90`, `tests` `a60557d`, `packages` `0f6b419`.

The [contract](../../date-time-contract.md) records the rules and the owner-facing behavior changes. Expected values come from `scripts/generate-date-time-fixtures.py` (Python `zoneinfo`), independently of the four implementations.

## Reproduction

`tests/web-date-time.test.mjs` runs the pre-F21 web loop with `TZ=America/Chicago`. It still produces the reviewed defect: November 1–3, 2026 gives `11-01, 11-02`; March 7–10 gives `03-07, 03-08, 03-08, 03-09`. The new helper gives each date once in all five host zones tested.

## Results

| Area | Command | Result |
| --- | --- | --- |
| Web F21 | `node --test tests/web-date-time.test.mjs` | 9 pass; host zones Chicago, Auckland, Kolkata, Santiago, UTC |
| Web existing | `node --test tests/web-guest-capability.test.mjs tests/web-availability.test.mjs tests/web-creation.test.mjs tests/web-session-lifecycle.test.mjs` | 137 pass |
| Web check/build | `npm --prefix apps/web run check`; `npm --prefix apps/web run build -- --configLoader runner` | 0 errors, 5 existing warnings; build passes |
| Database | `npm run test:database` | 149 pass, including 7 new F21 checks (migration replayed from scratch in PGlite) |
| iOS | Package `build-for-testing`, then `test-without-building -only-testing:MeetingSchedulerTests` | 126 tests, 0 failures (119 baseline + 7 `DateTimeContractTests`) |
| iOS wrapper | `xcodebuild -project apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj -scheme MeetingScheduler -destination 'generic/platform=iOS Simulator' build` | Build succeeded |
| Android | `./gradlew --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest` | 81 JVM tests, 0 failures (75 baseline + 6 `PollDatesTest`); both APKs build |

The database suite rejects legacy 23:59 ends, UTC midnights in a non-UTC poll, two-date spans, a fixed 24 hours across fall-back, the wall midnight before Santiago's gap and a Chicago interval in a Kolkata poll. Each rejection rolls back the whole creation. Fixture intervals, all timed fixtures and an unchanged legacy row are accepted, and the timezone of a poll with all-day options cannot change.

The real-PostgreSQL race suites were not rerun. The migration keeps the existing poll row lock and lock order in the option trigger and adds no new locks.

## Toolchains and resources

- Node 26.5.0; web dependencies from `apps/web/package-lock.json`.
- Xcode 27.1. A fresh iPhone 17 Pro / iOS 27.0 simulator `092886A7-7FBD-4BA4-A557-218DD03FA3DC` was created for this run, then shut down and deleted at 02:25 UTC October 25. Derived data was kept under `/tmp/f21-ios`. No existing simulator was used. (The iOS 27.1 runtime supports only one device type here, so 27.0 was used.)
- Android: the existing JDK 21 (`/private/tmp/meeting-fix-jdk21`) and SDK (`/private/tmp/meeting-fix-android-sdk`) were used read only, with a copied Gradle cache at `/private/tmp/f21-android-gradle`. `app/google-services.json` is the ignored CI placeholder. No emulator, device or provider was used.
- No hosted project, provider, server or port was used.

## Not covered

- Instrumentation/emulator and simulator UI journeys of the creation screens. Native view wiring is covered by compilation, not UI tests.
- Hosted migration `20261025021513`, which still needs to be applied in version order after `20261023224522`.
- F16 calendar coverage policy (busy all-day events, secondary calendars), and the F18 list date range.
