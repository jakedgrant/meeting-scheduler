# F05/F09 creation, limits and pass evidence

The combined implementation is `1cfb5f06a5f5f1c998aa62d9897b29298b07ed1e`, based on verified main `5b9c5e46a1fc7f023339a755297774e60f0c5806`. Documentation correction `53f092cdfeeebe776ce94b293d7a1d5cc913c370` clarifies recovery after a changed-payload retry. Subsequent evidence/tracker changes do not change implementation. [Manifest](manifest.json) records source identities and every migration hash.

## Pull request and CI

[PR #71](https://github.com/jakedgrant/meeting-scheduler/pull/71) targets main directly and contains the migration and all three client integrations. The PR description records the exact CI head and final six-workflow results; its Checks tab is the current source for subsequent runs. No stacking, merge or hosted deployment is part of this delivery.

## Baseline and review

`git fetch origin main` succeeded. GitHub confirms #70 merged as `5b9c5e46a1fc7f023339a755297774e60f0c5806`. `git merge-base --is-ancestor` passed for its exact head `040f9ee480f7ad2f1beb41e6d27b7f46cc363ba6` and all five previously missing deliveries:

| PR | Head included in main |
| --- | --- |
| #64 | `4530d462bdbfb91faba34237884357787a7ea09a` |
| #66 | `0c02a0817f865113b2963f371accfa0bfcf103ab` |
| #67 | `d0711ba9739387a66e413c8987686f00d0f52189` |
| #68 | `e8a4740abc15c65dc5909763d73e597c9af4f0ee` |
| #69 | `2cd63ab000f3f0b787e2dc27500876a0f08f3c96` |

An independent reviewer inspected the entire combined implementation at `1cfb5f0` and documentation correction `53f092c`, including migration, client services/editors/screens, shared configuration, CI and regression/race tests. No actionable findings remained. The reviewer separately ran `node --test tests/creation-commands.test.mjs` (48/48) and `node --test tests/web-creation.test.mjs` (31/31), plus `git diff --check`. They reviewed the supplied native/concurrency evidence without rerunning those runtimes. Earlier review findings—clock freshness after waits, UTC encoding, repeated successful submission, capacity presentation, stale account lists and late list results—were fixed before this final review.

## Tested sources and commands

| Area | Exact source | Result |
| --- | --- | --- |
| Combined database replay | `1cfb5f06a5f5f1c998aa62d9897b29298b07ed1e` | `npm run test:database`: 142 checks, zero failures, including 48 new creation checks. [Output](combined-database-results.txt) |
| Real PostgreSQL | Backend `5f9d118d35b64b067715b2daf00ffb291683fe21`; migration/tests identical in combined tree | PostgreSQL 18.4: 24 new creation races with observed `Lock` waits; 17 existing races. Runner totals include one parent per suite (25 and 18). [New output](creation-race-results.txt), [existing output](existing-race-results.txt) |
| Web | `c8a352df47ca3634e7018b1dbd89dff6296458a8`; files identical in combined tree | 56 tests, Svelte check: zero errors/five existing warnings; production build. [Tests](web-test-results.txt) |
| iOS | `ec31397128593352532e5e47441faf9ca8242993`; files identical in combined tree | 71 tests, package build-for-testing and tracked app-wrapper Debug build. [Summary](ios-test-summary.txt), [commands and source details](../../ios-creation-client-evidence.md) |
| Android | `9b9ca3cb54b204e745de9f4f3f09d61e86e00c1b`; files identical in combined tree | Debug APK and 26 JVM tests, zero failures. [Build summary](android-build-summary.txt) |
| Existing billing/calendar | Combined tree | 38 offline Edge tests; seven entry points type-check; billing lint passes. [Type checks](entrypoint-check-results.txt) |

Web commands, run in `/private/tmp/meeting-scheduler-f05-f09-integration`:

```bash
node --test tests/web-guest-capability.test.mjs tests/web-availability.test.mjs tests/web-creation.test.mjs
npm --prefix apps/web run check
VITE_SUPABASE_URL=https://example.supabase.co VITE_SUPABASE_ANON_KEY=test-public-key npm --prefix apps/web run build -- --configLoader runner
```

Android used JDK 21.0.12.1, SDK 36 and a dedicated copied Gradle cache. A placeholder Firebase file came from the existing CI fixture and is ignored, never a distribution credential. From `apps/android`:

```bash
JAVA_HOME=/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home \
ANDROID_HOME=/private/tmp/meeting-fix-android-sdk \
GRADLE_USER_HOME=/private/tmp/f05-f09-gradle \
./gradlew --no-daemon --offline -PdisableCrashlyticsMappingUpload=true :app:assembleDebug :app:testDebugUnitTest
```

The Android tests include actual `PollService` calls with injected transports: account A's loaded lists cannot remain after B creates; A→B→A late results and malformed options never publish; a pre-creation list reply cannot erase authoritative success. Session tests cover durable exact request recovery after a lost reply, storage failure before dispatch, definitive rejection/correction, changed-operation blocking, late errors and repeated successful submission. The join screen displays capacity errors and retains its retry action.

Existing offline commands also passed:

```bash
npm run test:billing:edge
npm run test:calendar:edge
deno check --frozen --config supabase/functions/deno.json supabase/functions/revenuecat-webhook/index.ts supabase/functions/billing-worker/index.ts supabase/functions/calendar-connection/index.ts supabase/functions/check-calendar-conflicts/index.ts supabase/functions/calendar-oauth-callback/index.ts supabase/functions/calendar-maintenance/index.ts supabase/functions/store-calendar-token/index.ts
deno lint --config supabase/functions/deno.json supabase/functions/_shared/billing supabase/functions/revenuecat-webhook supabase/functions/billing-worker
```

The role tests replay every migration and exercise `anon`, `authenticated`, an inherited API role and service privileges, including direct table bypass attempts. Invalid later options and injected option/receipt failures leave no poll, options, spent pass, funding record or operation receipt. Same-ID replay, changed payloads, stale entitlements, missing/expired/revoked/spent/legacy passes, explicit oldest-pass selection, subscription priority, historical receipt transfer and reactivation are covered.

Real independent-session races assert an observed `pg_stat_activity.wait_event_type='Lock'` before releasing the first transaction. They cover competing free creates, same-ID recovery and mismatch, pass competition and changed ownership/eligibility, natural subscription/pass/deadline expiry while blocked, reactivation, direct and command guest/member capacity, full-place retries and the option-count boundary. CI runs both real race suites in separate empty databases on PostgreSQL 17 and 18.

Exact final PostgreSQL commands, run from `/private/tmp/f05-f09-backend`, used two newly created empty databases:

```bash
TEST_DATABASE_URL='postgresql://jake@localhost:56519/scheduler_test_f05_final?host=%2Fprivate%2Ftmp%2Ff05-f09-backend-pg%2Fsocket' node --test tests/concurrent-creation.test.mjs > /private/tmp/f05-race-final-results.txt 2>&1
TEST_DATABASE_URL='postgresql://jake@localhost:56519/scheduler_test_commands_f05?host=%2Fprivate%2Ftmp%2Ff05-f09-backend-pg%2Fsocket' node --test tests/concurrent-commands.test.mjs > /private/tmp/f05-old-race-results.txt 2>&1
```

The backend created those databases through a Node `pg` admin connection to `postgres` on the same private socket, with `CREATE DATABASE scheduler_test_f05_final` and `CREATE DATABASE scheduler_test_commands_f05`. The final cleanup command was `/private/tmp/meeting-scheduler-backend-pg-deps-20261023/package/native/bin/pg_ctl -D /private/tmp/f05-f09-backend-pg/data -m fast stop`, followed by removal of that disposable directory.

## Resources, cleanup and prelaunch limits

All implementation took place in isolated clones. The original checkout and untracked `.claude/worktrees/` were preserved. Archive was requested for the initially created unused managed worktree; the app returned a queued cleanup operation. No implementation was written there, and the original checkout was not changed.

The backend used only its reserved new PostgreSQL data/socket directory `/private/tmp/f05-f09-backend-pg`, Unix socket port 56519 with TCP disabled. It stayed idle during an account-usage interruption; on resumption `pg_ctl -m fast stop` reported `server stopped`, and that new directory alone was removed. The coordinator verified the directory no longer exists. Existing PostgreSQL binaries and services were not changed.

The new iOS simulator `526D05E1-3CF3-45B5-A6B2-F3034FA48A72` was shut down and deleted after its final tests. No prior device or permission was reused. Android used temporary single-use Gradle processes and no emulator. Web tests/builds opened no server or listening port. Temporary dependency caches, build outputs and test artifacts remain available under `/private/tmp` for inspection; they are not running services.

These are source, local role, real PostgreSQL and SDK-transport checks. They do not establish hosted PostgREST/grants/provider configuration, a mounted signed-in native UI journey, physical-device behavior, real store purchase validation or distribution-signed archives. Those remain prelaunch work. No hosted environment, product/pricing configuration or real development/beta data was mutated.

Remaining F12/F14/F22 lifecycle work, F21/F16 dates/calendar and F19 → F18 → F20 reads/realtime stay in the follow-up queue.
