# Android F12/F14 evidence

Source: `b7277a62e24b6c016d9f59010dc2fc3c4fc928ac`, followed by the ActivityScenario test-harness correction `0b1a2cbe20ac042faf0d7bea1aa361e4dd86dec8` and originating-credential dispatch correction **`50933caff3bd8e84b8053c102cce2a5b85ee3212`** on branch `codex/f12-f14-android`. This branch starts from the coordinator's verified-main session contract, `483ca17`. No backend authorization, command, billing funding or hosted configuration was changed.

## Client integration

`AuthService` owns one process-lifetime SDK observer. Profile loading and the ordered RevenueCat worker run independently. Initialization, external/explicit sign-out, offline expired restoration, expiry timers and reauthentication establish account/generation boundaries. Ordinary token refresh retains the generation. Old profile success/failure, expiry cleanup and native sign-in cannot publish across A → B or A → logout → A.

`AppContainer` synchronously resets poll and calendar projections at boundaries. The authenticated Compose subtree is keyed by generation, so its navigation, remembered detail/response state and screen coroutine scopes are disposed together. Poll reads and commands fence successful and failed results. List loading also checks request order and creation invalidation before cleanup.

RevenueCat identity changes serialize and reconcile toward the newest desired account. Failure retries independently of the auth observer. Customer information and personalized offerings clear immediately; provider reads wait for the matching identity. Offering success/failure/cleanup checks account, generation and request order. Tests use populated A/B entitlements and identified offering fixtures.

Calendar connection/conflict reads and errors are generation-fenced. Device preferences use account keys. Old reads/writes cannot affect B's preference. Existing unscoped device preferences are not assigned to a different account. Preference failure cannot terminate the application scope.

Availability retry records now persist the original snapshot, request UUID, expected version and draft under account/poll keys. Returning to A or recreating a screen restores them. Failed creation retains its existing account-scoped exact envelope. A production PollService/editor regression simulates a committed creation with a lost reply, changes accounts, then recovers the original poll with one receipt and one pass redemption.

Authentication callback configuration, attempt ownership, exact routes, SDK persistence scheduling and immediate local sign-out are described in [Android authentication callbacks](../../../android-auth-callbacks.md). Calendar routing remains separate. Native Google is preserved and a browser fallback is wired into AuthView.

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

No live Google/OTP/RevenueCat sign-in, email delivery, real purchase or hosted redirect configuration was verified. [Owner actions](../../../android-auth-callbacks.md#required-external-configuration) list the required test environment checks. F21/F16 and F19 → F18 → F20 remain queued. This tranche adds no database migrations or hosted rollout.

Final runtime result and cleanup are recorded below.

## Final source result and resource release

The final source tree is `50933caff3bd8e84b8053c102cce2a5b85ee3212`. The validation command above completed successfully on this source with **55 tests, zero failures**, and both APKs built. Final Activity instrumentation on those APKs returned **OK (2 tests)** in 1.799 seconds. The final process-cold run reported 949 ms; UI hierarchy and the screenshot show the cancellation message and browser fallback. The saved attempt XML was an empty `<map />` afterward. The malformed auth path failed implicit intent resolution, and the calendar route was delivered warm to the existing Activity.

At **2026-10-24 08:48 UTC**, `adb -s emulator-5582 emu kill` returned OK. Both task-owned AVDs (`session-f12-f14-resume` and the stopped earlier `session-f12-f14`) were deleted with avdmanager. Ports 5582/5583 had no listener afterward. The task-owned Gradle cache reported no running Gradle daemons. The isolated downloaded SDK image and copied build cache remain under `/private/tmp` for review; no emulator, localhost server, database or provider session remains reserved.

Retained local logs: `/private/tmp/android-session-dispatch-final2-build.log`, `/private/tmp/android-session-final-runtime.log`, `/private/tmp/android-session-final-cold.log`, `/private/tmp/android-session-final-calendar.log`, `/private/tmp/android-session-final-invalid.log`, and `/private/tmp/android-session-final-consumed.xml`. The previous interrupted run and test-harness failures are not counted as passing evidence. The final runtime result supersedes them.
