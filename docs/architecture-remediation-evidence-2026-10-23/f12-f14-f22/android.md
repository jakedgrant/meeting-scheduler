# Android F12/F14 evidence

Source: `b7277a62e24b6c016d9f59010dc2fc3c4fc928ac`, followed by the ActivityScenario test-harness correction `0b1a2cbe20ac042faf0d7bea1aa361e4dd86dec8` and originating-credential dispatch correction **`50933caff3bd8e84b8053c102cce2a5b85ee3212`** on branch `codex/f12-f14-android`. This branch starts from the coordinator's verified-main session contract, `483ca17`. No backend authorization, command, billing funding or hosted configuration was changed.

## Client integration

`AuthService` owns one process-lifetime SDK observer. Profile loading and the ordered RevenueCat worker run independently. Initialization, external/explicit sign-out, offline expired restoration, expiry timers and reauthentication establish account/generation boundaries. Ordinary token refresh retains the generation. Old profile success/failure, expiry cleanup and native sign-in cannot publish across A → B or A → logout → A.

`AppContainer` synchronously resets poll and calendar projections at boundaries. The authenticated Compose subtree is keyed by generation, so its navigation, remembered detail/response state and screen coroutine scopes are disposed together. Poll reads and commands fence successful and failed results. List loading also checks request order and creation invalidation before cleanup.

RevenueCat identity changes serialize and reconcile toward the newest desired account. Failure retries independently of the auth observer. Customer information and personalized offerings clear immediately; provider reads wait for the matching identity. Offering success/failure/cleanup checks account, generation and request order. Tests use populated A/B entitlements and identified offering fixtures.

Calendar connection/conflict reads and errors are generation-fenced. Device preferences use account keys. Old reads/writes cannot affect B's preference. Existing unscoped device preferences are not assigned to a different account. Preference failure cannot terminate the application scope.

Availability retry records now persist the original snapshot, request UUID, expected version and draft under account/poll keys. Returning to A or recreating a screen restores them. Failed creation retains its existing account-scoped exact envelope. A production PollService/editor regression simulates a committed creation with a lost reply, changes accounts, then recovers the original poll with one receipt and one pass redemption.

Authentication callback configuration, attempt ownership, exact routes, SDK persistence scheduling and immediate local sign-out are described in [Android authentication callbacks](../../android-auth-callbacks.md). Calendar routing remains separate. Native Google is preserved and a browser fallback is wired into AuthView.

## Deterministic validation

Toolchain: Temurin 21.0.12.1, Gradle 8.11.1, Android SDK/platform/build-tools 36. Existing JDK/SDK were read only. Builds used a copied, task-owned Gradle cache at `/private/tmp/session-android-gradle`. `google-services.json` was a local ignored placeholder with the debug application ID; no real Firebase account was used.

From the repository root:

```bash
JAVA_HOME=/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home \
ANDROID_HOME=/private/tmp/meeting-fix-android-sdk \
GRADLE_USER_HOME=/private/tmp/session-android-gradle \
apps/android/gradlew -p apps/android --no-daemon \
  :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest --offline
```

Result: **55 JVM tests**, debug APK and instrumentation APK pass. Suite counts: 14 production session-service tests, seven callback-router tests, eight real SDK transport tests, 11 creation tests, six availability tests, six lifetime tests, two model tests and one existing example test. Deprecation warnings remain in existing Compose/date APIs and pinned SDK test constructors.

The eight transport tests execute Supabase 3.3.0 with injected Ktor MockEngine and the production AtomicSessionManager. They cover PKCE without automatic import; OTP/browser redirect and native Google nonce; persisted restore/legacy migration; stale import refusal; delayed old refresh success and failure with B and returning A; delayed remote logout success and failure with signed-out, B and new A states. SDK credential state and stored credential state are asserted together. Additional transport races suspend the actual SDK in initialization before resolving Authorization, then install B or a new A session. Creation, join and availability RPCs each send exactly one original-A Authorization value. A separate calendar disconnect test starts with SDK B and an app-owned A snapshot, then observes B before the delayed reply; the request still contains exactly one A credential. This caught and fixed the pinned Functions body/Headers overload appending its default Authorization; the request-builder overload now assigns the captured token after the SDK default.

The first transport test draft hung because Android platform initialization was disabled in a unit JVM while the test awaited the platform's initial signed-out event. The final harness explicitly supplies that event and bounds new tests to 15 seconds. No provider network is used by these tests.

## Android runtime

A fresh coordinator-approved reservation created AVD `session-f12-f14-resume` in `/private/tmp/session-android-avd-resume`, using the task-owned Android 36 Google APIs ARM64 image. Console/ADB ports 5582/5583 were checked unused. Serial: `emulator-5582`. Reservation began at 2026-10-24 08:08 UTC for 45 minutes. Airplane mode, disabled Wi-Fi and disabled mobile data were set before app installation.

```bash
adb -s emulator-5582 install -r app-debug.apk
adb -s emulator-5582 install -r app-debug-androidTest.apk
adb -s emulator-5582 shell am instrument -w \
  -e class com.meetingscheduler.android.SessionActivityTest \
  -e timeout_msec 20000 \
  com.meetingscheduler.android.debug.test/androidx.test.runner.AndroidJUnitRunner
```

Two Activity tests cover launch-intent handling, warm callbacks, duplicate delivery, auth/calendar route separation and recreation retaining the same application-owned AuthService. The harness restores its original launch intent before ActivityScenario cleanup because production MainActivity correctly records new callback intents. A subsequent harness correction makes the launch callback's action match the duplicate's action; asynchronous delivery otherwise confused ActivityScenario cleanup.

A separate `am force-stop` followed by implicit `am start -W -a android.intent.action.VIEW -d 'meetingscheduler://auth/callback?error=access_denied&description=cold-start'` used a saved synthetic attempt from a previous process. Android reported **COLD**, 949 ms. The visible screen displayed the cancellation/expired-link message, and the pending attempt was consumed. [Screenshot](android-cold-auth.png). `meetingscheduler://calendar/callback?status=connected` reached the existing Activity warm; `meetingscheduler://auth/other?error=access_denied` failed OS intent resolution. No synthetic code was exchanged with a provider.

## Review and limits

Self-review corrected old list/offer loading cleanup, account preference error handling, returning-account profile completion, latest-attempt ownership, callback readiness during overlapping starts, and SDK credential publication/revocation ordering. The coordinator independently flagged personalized offerings before final validation; that finding is fixed and covered. A further coordinator review identified dispatch credential resolution; the transport regressions and credential capture fix are included in the final source commit. Final combined independent review belongs to the coordinator after all platform streams are integrated.

No live Google/OTP/RevenueCat sign-in, email delivery, real purchase or hosted redirect configuration was verified. [Owner actions](../../android-auth-callbacks.md#required-external-configuration) list the required test environment checks. F21/F16 and F19 → F18 → F20 remain queued. This tranche adds no database migrations or hosted rollout.

Final runtime result and cleanup are recorded below.

## Final source result and resource release

The final source tree is `50933caff3bd8e84b8053c102cce2a5b85ee3212`. The validation command above completed successfully on this source with **55 tests, zero failures**, and both APKs built. Final Activity instrumentation on those APKs returned **OK (2 tests)** in 1.799 seconds. The final process-cold run reported 949 ms; UI hierarchy and the screenshot show the cancellation message and browser fallback. The saved attempt XML was an empty `<map />` afterward. The malformed auth path failed implicit intent resolution, and the calendar route was delivered warm to the existing Activity.

At **2026-10-24 08:48 UTC**, `adb -s emulator-5582 emu kill` returned OK. Both task-owned AVDs (`session-f12-f14-resume` and the stopped earlier `session-f12-f14`) were deleted with avdmanager. Ports 5582/5583 had no listener afterward. The task-owned Gradle cache reported no running Gradle daemons. The isolated downloaded SDK image and copied build cache remain under `/private/tmp` for review; no emulator, localhost server, database or provider session remains reserved.

Retained local logs: `/private/tmp/android-session-dispatch-final2-build.log`, `/private/tmp/android-session-final-runtime.log`, `/private/tmp/android-session-final-cold.log`, `/private/tmp/android-session-final-calendar.log`, `/private/tmp/android-session-final-invalid.log`, and `/private/tmp/android-session-final-consumed.xml`. The previous interrupted run and test-harness failures are not counted as passing evidence. The final runtime result supersedes them.

## Originating callback UUID follow-up

Source **`a025ca5f80bee73ee26b7b762023325186a34495`**, followed by instrumentation harness correction **`d60192c9cd11728b254d7fabe28aa7bbcd5454f5`**. These extend the earlier deliveries above; the final tested source is `d60192c9cd11728b254d7fabe28aa7bbcd5454f5`.

The coordinator identified a receipt-time ownership gap: an old URI carried only a code, so a newer pending attempt could be mistaken for its origin. OTP and browser Google now send `meetingscheduler://auth/callback?attempt=<uuid>` as their SDK redirect. The router requires exactly one canonical UUID matching persisted ownership before exchange, error reporting, replay tracking or pending-state changes. Old links received after B or A → logout → A, and links without an originating UUID, cannot borrow a newer marker. Query and error-only fragment cancellations require the same match; access-token fragments remain rejected.

SDK initiation and code exchange share one mutex. A queued obsolete initiation/exchange checks its owner before SDK entry, and an older successful exchange cannot delete a newer verifier. New native, browser and OTP requests supersede before initialization awaits. A native revision is captured before Credential Manager opens and reaches both native UI paths. Explicit sign-out invalidates pending work even when already signed out. Disposal fences delayed caller-owned native results and queued imports. Old failure and cleanup cannot report into or remove a newer attempt; UI loading cleanup checks its own request order.

The same offline Gradle command above completed on the final source: **64 JVM tests, zero failures; debug and instrumentation APKs built**. Counts: 16 production session-service tests, nine router tests, 13 real SDK transport tests, 11 creation, six availability, six lifetime, two model and one example. The existing originating-credential dispatch and creation/availability recovery tests remain passing.

New production tests cover old URI receipt after newer attempts across B and returning A; initialization races with signed-out and restored B states; a Credential Manager result superseded before its SDK call; delayed native SDK success and failure after disposal or explicit already-signed-out sign-out; delayed OTP and browser initiation success/failure during verifier rotation; a genuine callback waiting for readiness; and old exchange completion before queued new initiation. The transport tests run AuthService and the production gateway against Supabase 3.3.0/Ktor MockEngine with injected profile fixtures and AtomicSessionManager. They inspect exact redirect queries, PKCE request bodies, actual SDK credentials, persisted credentials and pending attempts. No provider network is used.

### Fresh offline runtime and cleanup

Fresh AVD `session-android-attempt`, directory `/private/tmp/session-android-attempt-avd`, serial `emulator-5584`, unused console/ADB ports 5584/5585. Coordinator approval was for 30 minutes from **2026-10-24 18:43:07 UTC**. It used the existing task-owned isolated Android 36 Google APIs ARM64 image. Airplane mode was 1 and Wi-Fi was 0 before installation; mobile data was disabled. No real account was installed or used.

The final APKs were installed and this command returned **OK (2 tests)** in **2.776 seconds**:

```bash
adb -s emulator-5584 shell am instrument -w \
  -e class com.meetingscheduler.android.SessionActivityTest \
  -e timeout_msec 20000 \
  com.meetingscheduler.android.debug.test/androidx.test.runner.AndroidJUnitRunner
```

The tests retain the application-owned AuthService and pending attempt across Activity recreation, reject an obsolete UUID delivered through `onNewIntent`, accept the matching current callback, separate calendar/other paths, and exercise launch-intent duplicate delivery. Two earlier harness runs timed out because a warm VIEW intent changed Android's Activity record before ActivityScenario recreation. The corrected harness recreates first, then delivers warm intents. Those failed runs are excluded from the final result.

A separate process-cold check seeded only a synthetic UUID/owner marker in `auth_attempt_v1` after force-stop. The obsolete UUID launched **COLD, 1064 ms**, displayed no callback error and retained the current UUID. The genuine current query cancellation then arrived warm, displayed cancellation and consumed the marker. A second seeded matching callback with an error-only fragment launched **COLD, 985 ms**, displayed cancellation and left `<map />` in pending storage. The warm calendar route reached the existing Activity; the malformed `/auth/other` route failed implicit intent resolution. [Final offline screen](android-attempt-cold.png).

These commands need quotes on the Android shell as well as the host shell so `&` is preserved:

```bash
adb -s emulator-5584 shell "am start -W -a android.intent.action.VIEW -d 'meetingscheduler://auth/callback?attempt=<uuid>&error=access_denied'"
adb -s emulator-5584 shell "am start -W -a android.intent.action.VIEW -d 'meetingscheduler://auth/callback?attempt=<uuid>#error=access_denied&error_description=cancelled'"
```

At **2026-10-24 18:50:32 UTC**, `adb -s emulator-5584 emu kill` returned OK and avdmanager deleted `session-android-attempt`. A subsequent check found no listener on 5584/5585 and no AVD remaining in its directory. The task Gradle cache reported no running daemons. The isolated image/cache and local evidence logs remain; no runtime reservation remains active.

Final logs: `/private/tmp/android-attempt-final3-build.log`, `/private/tmp/android-attempt-final3-runtime.log`, `/private/tmp/android-attempt-final-cold-check.log`, `/private/tmp/android-attempt-final-{stale-cold,current-warm,current-cold}-{ui,pending}.xml`, `/private/tmp/android-attempt-final-calendar.log`, and `/private/tmp/android-attempt-final-invalid.log`. The reproduction script is `/private/tmp/android-attempt-runtime-check.py`. A first manually unquoted ADB diagnostic dropped URL parameters at the Android shell; only the final correctly quoted script runs above count as cold/warm evidence.

The owner must configure `meetingscheduler://auth/callback\?attempt=*` under Supabase's documented glob rules and verify query preservation through real OTP/browser providers. Hosted allowlist acceptance, email delivery, Google consent/cancellation and real sign-in remain unverified. No hosted configuration changed. See the updated [external configuration actions](../../../android-auth-callbacks.md#required-external-configuration). Combined independent review remains the coordinator's integration gate.

## Pre-review integrated compile and JVM replay

The coordinator reran the pre-review integrated source at `f3df14f3328bfd051b51de61465e6d8c4b3ec78f` with the isolated JDK/SDK/cache:

```bash
JAVA_HOME=/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home \
ANDROID_HOME=/private/tmp/meeting-fix-android-sdk \
GRADLE_USER_HOME=/private/tmp/session-integration-gradle \
apps/android/gradlew -p apps/android --no-daemon --offline \
  -PdisableCrashlyticsMappingUpload=true \
  :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
```

Build succeeded in 19 seconds (73 tasks). XML results contain **64 tests, zero failures/errors/skips**. Log: `/private/tmp/session-final-android-build.log`. No emulator, server or provider was started. The earlier two emulator tests remain tied to the identical tested Android subtree in the source manifest.
## Independent-review corrections: logout ownership, dispatch and server lineage

Final source **`c0bd8126d7ae9e59c2ebcc0055e20162688d26ed`** fixes all three Android findings from the independent review of the coordinator's combined `f3df14f` tree. The preceding evidence remains historical. The coordinator owns final combined-tree re-review and CI.

- **Queued logout (P1):** AuthService captures the original UserSession before clearing UI state or suspending and passes it explicitly to the gateway. The local mutation removes credentials only when account plus JWT `session_id` match; nonstandard tokens use exact-credential identity. B and a fresh A server session survive cleanup queued behind their installation. An ordinary refresh from the original lineage is removed. The isolated `LOCAL` revoker always receives the captured original. Cleanup belongs to the application scope so disposing the settings screen cannot cancel it before local removal; the bounded local mutation survives cancellation. Further original-lineage status updates cannot resurrect signed-out UI. Replacement-session errors and old screen cleanup are fenced.
- **All authenticated dispatch (P2):** Poll detail/options/participants/responses, status changes and profile reads/updates now use their captured app credential. A first actual SDK regression exposed `[Bearer unit-key, Bearer original-A]` from the select/update query builder's appended headers. `AccountPostgrest` provides a request-owned SupabaseClient view whose `accessToken` returns the captured credential, then constructs the normal PostgREST plugin through the pinned factory with the application's existing configuration. It shares the HTTP transport and serializer and registers no client, listener or engine. Supabase 3.3.0 API declarations/bytecode confirm accessToken resolution precedes shared Auth lookup, and the plugin constructor creates its API adapter without runtime registration. The opted-in internal boundary is version-pinned and exercised by transport tests. Existing RPC and calendar builder paths retain their already-tested header assignment. Every tested header value is asserted, including absence of duplicate values. Calendar conflict work captures its owner and credential before device-calendar suspension, rechecks before backend dispatch and fences device/backend errors and results.
- **Fresh same-account session (P2):** Session identity now includes account and server `session_id`; ordinary JWT rotation in that lineage retains generation, while fresh same-account authentication advances it, clears old state and invalidates pending callbacks. Missing/malformed claim data conservatively uses exact-credential hashing. Persisted callback ownership includes lineage, so cold SDK restoration accepts the same server session with a refreshed JWT and rejects a fresh login for the same UUID. No raw credential is persisted in the attempt owner key. Supabase's current [session documentation](https://supabase.com/docs/guides/auth/sessions#access-token-jwt-claims) and [claim reference](https://supabase.com/docs/guides/auth/jwt-fields) confirm `session_id` identifies the server session. This classification partitions client work and does not authorize backend access.

### Final deterministic result

The offline Gradle command recorded above ran on the final source and passed: **75 JVM tests, zero failures; debug and instrumentation APKs built**. Log: `/private/tmp/android-review-final2-build.log`. Counts: 11 new independent-review tests, 16 session-service, 13 SDK transport, nine router, 11 creation, six availability, six lifetime, two model and one example. Earlier compiler/test-fixture failures are excluded. The final amended source changes the delayed-read fixtures to populated results; the app/instrumentation source and APKs are unchanged from the successful runtime below.

`ReviewedIsolationTest` executes production AuthService, SupabaseAuthGateway, PollService, CalendarService, AtomicSessionManager and Supabase 3.3.0 with injected MockEngine transport. Its cases cover:

- A logout held on a dispatcher while B or fresh A is installed; delayed remote success/failure; SDK and persisted credentials retained together; only the original A header reaches the `LOCAL` revoker.
- Same-lineage refreshed-token removal, and caller-screen cancellation while logout is queued. Original-lineage refresh events remain signed out; new B/A sessions remain current.
- All four populated direct read paths plus status changes with shared SDK B and app-owned A. Profile loading/updating also run against shared SDK B. Each request has exactly one A Authorization value.
- Populated delayed read/profile-write success and delayed failures across B and a fresh same-account lineage, with cancellation and current profile assertions.
- Delayed old profile success/failure, same-session refresh retaining generation/attempts, and fresh same-account authentication advancing generation and rejecting old URI receipt.
- Real SDK/AtomicSessionManager cold restoration: same-lineage refreshed JWT accepts the persisted attempt, fresh same-UUID lineage rejects it before exchange.
- Device-calendar suspension followed by B/fresh A, on success and failure: no old backend dispatch and no replacement error/state mutation. Actual delayed conflict backend responses retain A's sole credential and cannot affect replacement state.

The existing durable creation/availability recovery and originating command credential tests remain passing. Backend commands, RLS/grants, funding/idempotency and account-scoped retry storage were not changed.

### Fresh offline runtime and release

Coordinator-approved fresh AVD `session-android-review` in `/private/tmp/session-android-review-avd` used the existing task-owned Android 36 ARM64 image read only. Ports 5586/5587 were checked unused. Reservation began **2026-10-24 19:10:46 UTC** for 30 minutes; serial `emulator-5586`. Airplane mode 1, Wi-Fi 0 and disabled mobile data were confirmed before APK installation. No real provider account or hosted configuration was used.

```bash
adb -s emulator-5586 install -r app-debug.apk
adb -s emulator-5586 install -r app-debug-androidTest.apk
adb -s emulator-5586 shell am instrument -w \
  -e class com.meetingscheduler.android.SessionActivityTest \
  -e timeout_msec 20000 \
  com.meetingscheduler.android.debug.test/androidx.test.runner.AndroidJUnitRunner
```

Result: **OK (3 tests)** in **2.034 seconds**, `/private/tmp/android-review-final-runtime.log`. The existing Activity recreation/cold-intent/warm-intent/route-separation checks pass. A new synthetic test drives the actual application SDK: same-lineage JWT rotation retains generation and the pending attempt; a fresh same-account lineage advances generation, clears that attempt and rejects its old code/error URI after a newer marker exists. The test clears its synthetic SDK session locally in `finally`; it performs no provider sign-in.

A separate correctly quoted process-cold script rejected an obsolete UUID without consuming the current marker (**COLD 959 ms**), then accepted the matching cancellation warm. A matching error-fragment callback restored after force-stop (**COLD 962 ms**) and consumed its persisted marker. Calendar routing stayed warm/separate; `/auth/other` failed OS resolution. Pending storage ended as `<map />`. Script and log: `/private/tmp/android-review-runtime-check.py`, `/private/tmp/android-review-final-cold-check.log`; UI/persistence captures use `/private/tmp/android-review-final-{stale-cold,current-warm,current-cold}-{ui,pending}.xml`.

At **2026-10-24 19:19:06 UTC**, `adb -s emulator-5586 emu kill` returned OK and avdmanager deleted `session-android-review`. Subsequent checks found no listener on 5586/5587 and an empty AVD directory. The task-owned image/cache and evidence logs remain. No emulator, server, database or provider session remains reserved. Hosted redirect acceptance/query preservation and real Google/OTP/RevenueCat validation remain the documented owner actions; no hosted changes were made.
