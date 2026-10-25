# PR #72 owner comments: shared iOS screen tasks

The coordinator addressed both owner comments directly, without subagents, on top of published head `43a152267c84ae6de71d10e075d09d21fadedb55`. Implementation commits are `b4248739ac465a0d4fdb7c45f969fe023d7eedd8` and `90e4db3965cb9722255e3d52343b426fc2ca34a0`.

- [Common call site](https://github.com/jakedgrant/meeting-scheduler/pull/72#discussion_r4369175021): `AuthServiceProtocol.performSessionTask` captures account/generation before task scheduling, checks ownership and cancellation before dispatch and publication, and runs success, failure and completion callbacks on MainActor. Eighteen screen actions across nine view files use it: profile, auth, purchase/restore, settings, poll creation/lookup/detail/availability/finalization, and calendar toggles/addition. Creation uses the injected auth environment consistently. Services keep their existing credential, command and persistence guards.
- [Duplicate check](https://github.com/jakedgrant/meeting-scheduler/pull/72#discussion_r4369179048): the two identical adjacent guards in profile saving had no intervening operation and were redundant. Both are removed from the screen; the shared runner guards the failure callback once. Profile success/error callbacks and loading cleanup no longer repeat session tests or MainActor hops.

Completion releases loading state after cancellation only while the initiating session and screen still own it. A boundary or recreated poll screen suppresses old cleanup. Poll actions pass their existing view-generation predicate, response reload retains its displayed-account predicate, and a multi-stage join checks its shared scope before loading responses. The separate SwiftUI-owned multi-stage detail load retains its request-order checks.

Ten production-helper tests use injected auth state and controlled suspended operations. They cover current success/failure once, ownership captured before scheduling, delayed success/failure across A→B, A→logout→A and A→B→A, stable same-session updates, cancellation before dispatch and during uncooperative work, silent cancellation errors, old cleanup after screen recreation, callbacks that replace their own session, and cancellation between operation stages. The existing 109 persistence, auth/SDK, provider, creation and availability tests remain in the suite.

The coordinator reviewed the final implementation and screen integrations directly. The earlier independent review in `review.md` applies to source `7ec897a`; this later owner-requested refactor has direct coordinator review and regression/build/CI evidence. No new independent-agent review is claimed.

## Exact final validation

Source `90e4db3965cb9722255e3d52343b426fc2ca34a0`, iOS subtree `928878beebefd3b2149e92973f7ee085e41e7acf`, passed on Xcode 27.1 / Swift 6.4:

- Package `build-for-testing`: passed, 4.539 seconds.
- Full package suite: **119 tests passed, zero failures**, 18.244 seconds including orchestration (3.433 seconds in XCTest).
- Tracked app wrapper: passed, 16.034 seconds.
- Both dependency locks and generated-workspace revision map preserved; `git diff --check` passed.
- Web, Android, backend/shared configuration and command/persistence implementations are unchanged from the previously green PR head.

```bash
repo=/private/tmp/meeting-scheduler-session-integration
xcodebuild -workspace "$repo/apps/mobile/.swiftpm/xcode/package.xcworkspace" \
  -scheme MeetingScheduler-Package -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-session-ios-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-session-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO build-for-testing
xcodebuild -workspace "$repo/apps/mobile/.swiftpm/xcode/package.xcworkspace" \
  -scheme MeetingScheduler-Package -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-session-ios-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-session-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'platform=iOS Simulator,id=B18DAD0A-9055-43E7-937C-10FAD8513B28' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:MeetingSchedulerTests \
  -resultBundlePath /private/tmp/session-review-comments-final-tests.xcresult test-without-building
xcodebuild -project "$repo/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-session-ios-wrapper-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-session-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Logs: `/private/tmp/session-review-comments-final-{build,tests,wrapper}.log`; results: `/private/tmp/session-review-comments-final-tests.xcresult`. An initial `b424873` checkpoint also passed all 119 tests and wrapper compilation. Direct inspection then preserved the response-reload displayed-account predicate in `90e4db3`; the exact final validation above includes it.

## Fresh resources and cleanup

Both coordinator-owned reservations were fresh iPhone 17 Pro / iOS 27.0 devices, each limited to 30 minutes for deterministic package tests and generic wrapper compilation. Existing devices and prior reservations were not used.

| Device | Created UTC, October 25 | Shutdown/deletion UTC | Result |
| --- | --- | --- | --- |
| `FA7DC931-E189-4E83-9F86-3CA61AE148D5` | 01:16:25 | 01:18:18 | Initial 119 tests and wrapper passed; deleted |
| `B18DAD0A-9055-43E7-937C-10FAD8513B28` | 01:19:20 | 01:20:41 | Exact final 119 tests and wrapper passed; deleted |

Both IDs are absent from the final `simctl` inventory. Resource logs are `/private/tmp/session-review-comments-resource.log` and `/private/tmp/session-review-comments-final-resource.log`; inventory is `/private/tmp/session-review-comments-final-device-inventory.json`. No reservation, emulator, local server, database or live provider session remains. No hosted configuration or development/beta data changed. The existing approved-environment provider checks remain owner actions.

Exact published head and final workflow results are maintained in [PR #72](https://github.com/jakedgrant/meeting-scheduler/pull/72) and its checks; evidence-only publication commits preserve the tested implementation.

## CI follow-up: deterministic Android RPC credential coverage

The first CI run for owner-comment head `e4c10c6` failed the existing Android `commandDispatchKeepsTheOriginatingCredentialWhenSdkTokenResolutionWaitsAcrossAccountChanges` test ([run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/40150345532)). The coordinator reproduced it directly without subagents: iteration 71 failed `expected:<0> but was:<1>` at the pre-dispatch assertion. The test assumed the pinned SDK's Initializing status would prevent HTTP dispatch; it was not an explicit scheduling barrier. Log: `/private/tmp/session-review-comments-android-repeat-before.log`.

Replacing that assumption with an explicit SDK-replacement/HTTP-response ordering exposed a production problem: PostgREST RPC query headers appended the original token to the SDK's current token, yielding `[Bearer token-B, Bearer original-A]`. Earlier assertions inside MockEngine could be swallowed by `runCatching` as the expected stale-command failure. The coordinator moved exact-header assertions outside that capture and changed `accountRpc` to use the existing request-owned `AccountPostgrest` adapter, as direct reads/profile/status already did. No backend, payload, funding, idempotency, retry or authorization contract changed.

Source **`c578fd4c16e1f0a7c9bcbf906d2c2ea4a0e11f08`**, Android subtree **`8fb857bde7d1349723f5711e0cce2d16b3c6559a`**, passes all **75 JVM tests**, debug APK and instrumentation APK builds in **13 seconds** (73 tasks). The renamed test deterministically installs B or a fresh A in the actual SDK before A's app-owned request, waits for captured HTTP headers, then changes app ownership while holding the response. It covers `create_poll`, `join_poll`, `save_availability`, `get_availability` and `finalize_poll`, requires exactly one original-A Authorization value, and requires stale completion to be a cancellation rather than an arbitrary failure. All five RPC paths across both replacement cases passed **100 repeated JUnit executions** (1,000 request scenarios). Logs: `/private/tmp/session-review-comments-android-final3-build.log`, `/private/tmp/session-review-comments-android-repeat-after.log`.

An intermediate fixture using a custom SDK access-token provider with the Auth plugin was rejected by the pinned SDK and discarded. The final fixture uses its normal Auth/PostgREST plugins and no custom token provider. The initial wrong-header regression failed the exact-header assertion before the production fix; that failing run is retained in `/private/tmp/session-review-comments-android-final-build.log` and is excluded from passing evidence.

The complete current implementation snapshot is `c578fd4`; its iOS subtree is still exactly the 119-test source `90e4db3`. This follow-up was implemented and reviewed directly. It starts no device, server or provider. Prior Android callback/recreation instrumentation remains applicable to unchanged Activity/auth/router/instrumentation sources; no new emulator result is claimed for RPC transport. Current exact-head CI is maintained in PR #72.

The Android build used the same isolated offline command recorded in `android.md`:

```bash
JAVA_HOME=/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home \
ANDROID_HOME=/private/tmp/meeting-fix-android-sdk \
GRADLE_USER_HOME=/private/tmp/session-integration-gradle \
apps/android/gradlew -p apps/android --no-daemon --offline \
  -PdisableCrashlyticsMappingUpload=true \
  :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
```

The retained harness `/private/tmp/RepeatCredentialRace.java` runs `JUnitCore.run(Request.method(AuthSdkTransportTest.class, "commandDispatchKeepsTheOriginatingCredentialWhenSdkAlreadyHasReplacementSession"))` 100 times and exits on the first unsuccessful result. Its classpath points to this clone's compiled production/test artifacts and the pinned SDK dependencies:

```bash
TASK_REVIEW_FIXED_CP="$(cat /private/tmp/session-review-comments-fixed-classpath.txt)"
/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home/bin/javac \
  -cp "$TASK_REVIEW_FIXED_CP" /private/tmp/RepeatCredentialRace.java
/private/tmp/meeting-fix-jdk21/jdk-21.0.12.1+1/Contents/Home/bin/java \
  -cp "$TASK_REVIEW_FIXED_CP" RepeatCredentialRace 100
```
