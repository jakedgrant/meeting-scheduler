# iOS account/session isolation evidence

Latest verified source: `ed8c8a4af92cdff40c6c7fd615b390a9a96452d9`: **109 tests passed**, package and tracked-wrapper builds passed. The callback follow-up below records exact commands, results and cleanup. Earlier evidence remains historical.

Initial verified source: `8cf58a12c516d5816dbc2872fe4a46a7a66ea2f3`, after `2f2bf8200e8b088875f361b94be0e04f8e1121a9` and `1385e1afb1b2cc92dc0c844f6fd6e3f4848ddaba`. Tests finished October 24, 2026 at 13:53:56 UTC. This tranche preserves the merged SwiftData/account-cache, availability command, creation envelope, and backend billing contracts. It changes no database schema, hosted configuration, or dependency lockfile.

## What changed

`AuthService` owns one cancellable observer, registers before restoration, and rejects obsolete restoration and buffered events. Profile and calendar work run independently of auth observation and billing identity reconciliation. Account identity, JWT session identity, and an increasing generation distinguish refresh from replacement, logout, expiry, and reauthentication. An expiry deadline clears visible state even when an offline SDK refresh produces no sign-out event. A refreshed token replaces its deadline without discarding drafts. The signed-in root view is keyed by generation, and queued screen actions check their captured generation before dispatch.

Every poll operation, dependent batch read, calendar request, and profile request captures immutable account credentials before SDK suspension. A task-local request context survives the SDK's asynchronous authorization lookup. An A command cannot acquire B's token while queued; child tasks keep the same context. The application has one API SDK client, with SDK auth listeners and automatic refresh disabled on that API client. A separate owned auth adapter retains the existing persisted SDK auth key and manages refresh. Its API token resolver reads the captured request context, so it does not reenter `AuthService.shared` during singleton initialization.

The pinned Supabase Swift 2.39.0 SDK can install an older refresh response after another sign-in. The transport regression demonstrates this on the unprotected SDK, then verifies the production adapter prevents it. `SessionAuthAdapter` rejects obsolete token/user/verification responses before decode, checks original auth-attempt ownership at storage writes/removals, and uses one bounded token-pair ticket for the SDK's coalesced refresh task. The storage check also closes the actor hop between transport return and SDK commit. Stored-session validation occurs both when events are produced and when the application consumes them. A stale SDK event cannot select an account whose credentials were rejected.

Logout captures the original session before clearing application state. The adapter removes only the matching storage revision and revokes the captured JWT with `POST /auth/v1/logout?scope=local`, using the same route and status handling as the pinned SDK. Its remote completion performs no SDK cleanup. This avoids both a stale local remove and a remote global revoke affecting a newly authenticated session. Tests cover the remove gap, delayed success/failure, return to A, original Authorization header, and the pinned SDK emitting `signedOut(nil)` after a failed remove while another session remains stored.

Native Apple and browser OAuth requests carry their original auth-attempt revision through SDK work. Apple delegate callbacks are matched to their original controller. Magic-link callback intent is persisted with its originating account and JWT `session_id`, restored on cold launch, invalidated at account/session boundaries, and consumed once. The SDK still performs PKCE, state, and server expiry handling. A callback is accepted only at `meetingscheduler://auth/callback`; calendar routing stays separate. Old callback cleanup cannot clear or block the next attempt. A same-account profile edit also cancels a suspended older profile read before it can restore its previous values.

RevenueCat identity changes use one ordered worker and reconcile to the latest confirmed account independently of profile loading. Purchase/restore operations share the provider queue so an A receipt command finishes under A before the worker logs in B. Local entitlements and offerings clear immediately at a boundary. B offerings wait until the provider has identified B; generation checks reject populated A customer/offerings responses and late loading cleanup. Current offline identity failures can retry on ordinary auth refresh. Direct custom-ID switching follows the [current RevenueCat identity documentation](https://www.revenuecat.com/docs/customers/identifying-customers#switching-accounts): `logIn` can switch between custom IDs without a preceding anonymous logout. This differs from the installed identify-user skill's general account-switch advice. Explicit signed-out state still requests an anonymous logout, guarded against an already-anonymous SDK identity.

Apple Calendar preference keys now include the account UUID. Signed-out state reads no account preference, and an old permission completion cannot enable B's calendar. Google connection, conflict, error, and loading results retain generation checks. Availability recovery is held in an account-and-poll registry across screen recreation and account changes during the process; a lost reply restores the exact request UUID, payload, and expected version. The original file-backed creation envelope remains unchanged and survives process restart. No cache provider or creation persistence system was replaced.

## Initial verification (8cf58a1)

Xcode 27.1 (`27A9269`), Swift 6.4, Supabase Swift 2.39.0, RevenueCat 5.97.0. Dependencies were copied into this stream's isolated package directory. Both committed lockfiles are unchanged, and generated-workspace package revisions match `apps/mobile/Package.resolved`.

- Package `build-for-testing`: passed, 5.608 seconds.
- Package `test-without-building`: **102 tests passed, zero failures**, 6.250 seconds including Xcode orchestration.
- Tracked iOS app wrapper, generic simulator destination, signing disabled: passed, 8.007 seconds.
- `git diff --check` and pinned lockfile checks: passed.

The 102 tests comprise 23 persistence-provider, nine existing poll-service lifecycle, twelve availability-editor, ten availability transport, eleven creation-editor, six creation transport, fifteen auth/provider lifecycle, fifteen session/SDK transport, and one existing placeholder test. The original 71-test baseline remains included. The additional availability test verifies account isolation, screen recreation, exact retry reuse, and one committed write after a lost reply. The new production-controller/service tests cover delayed success and failure, A-to-B and A-to-logout-to-A transitions, initialization races, repeated refresh, offline expiry, disposal, provider reconciliation, populated customer/offerings state, receipt ordering, account calendar preferences, stale cleanup, queued credential dispatch, and original-session local logout.

Earlier results are retained as history, not final evidence. Before the SDK adapter work, 84 tests passed. The first resumed 96-test run passed 94 and exposed two stale status-command failure paths; those paths now reject with cancellation. A later exact `2f2bf82` run exposed six failures because a new context guard compared injected lifecycle-test accounts to the default signed-out application context. The injectable constructor now defaults to its supplied test context; the private live constructor captures the application's accepted credentials. The final 102-test run above supersedes those intermediate results.

Commands, with `repo=/private/tmp/meeting-scheduler-session-ios`:

```bash
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
  -destination 'platform=iOS Simulator,id=91F67496-18FE-4FE4-B657-EA32376E131C' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:MeetingSchedulerTests \
  -resultBundlePath /private/tmp/session-ios-8cf58a1-tests.xcresult test-without-building

xcodebuild -project "$repo/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-session-ios-wrapper-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-session-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Logs: `/private/tmp/session-ios-final-build.log`, `/private/tmp/session-ios-8cf58a1-tests.log`, `/private/tmp/session-ios-8cf58a1-wrapper.log`; result bundle: `/private/tmp/session-ios-8cf58a1-tests.xcresult`.

## Resource cleanup and remaining owner checks

The initial reserved simulator `0EC9E5B6-47CE-4D21-A938-3C00075E1D02` was released by the coordinator after the interrupted run. The resumed run used a newly created iPhone 17 Pro / iOS 27.0 device, `91F67496-18FE-4FE4-B657-EA32376E131C`, under a fresh 40-minute coordinator reservation. It was shut down and deleted after the final run at approximately 13:54 UTC; both commands exited zero and `simctl` inventory confirmed its absence. No existing simulator was used. No emulator, localhost server, Supabase/Docker instance, or provider test account was used.

These are simulator service/editor tests, production SDK transport tests using ephemeral URLSession/URLProtocol with `.invalid` hosts, and wrapper compilation. The wrapper was not launched with real provider configuration. No hosted allowlist, Apple/Google sign-in, RevenueCat dashboard identity, sandbox purchase, physical-device EventKit prompt, or signed-in UI journey was verified. Availability's new registry preserves recovery during the process; it does not add disk-backed availability drafts. Creation retains its existing durable recovery behavior.

Before beta release, an owner with an approved environment/account should verify Apple and Google sign-in plus magic links on cold/warm iOS launches, logout/reauthentication during offline and slow provider work, account-owned calendar choices, and unresolved creation recovery without another pass. The RevenueCat customer page should show the confirmed Supabase UUID for each account, and sandbox purchase/restore should remain attached to the account that began it. Existing redirect/provider settings are documented in the calendar and platform configuration sources; this work did not change or verify hosted configuration. The coordinator owns the separate independent review and final combined-tree/CI evidence.


## Callback correlation follow-up: final verification

Source commits `5c65fc2f42b2233fb1254513286c7362089b7b65` and `ed8c8a4af92cdff40c6c7fd615b390a9a96452d9` close an additional callback receipt gap found during coordinator review. A link received after a newer sign-in began previously lacked a correlation value, so it could consume the newer intent before SDK validation. OTP and Google browser redirects now carry `?attempt=<UUID>`. Exact URI/attempt validation happens before consuming the persisted intent or calling the SDK. A mismatched URL returned to the current browser also preserves that browser's intent so its genuine link can recover through app routing.

The adapter tracks the active originating attempt in its atomic storage fence. Obsolete SDK initiation cannot rotate or remove a newer PKCE verifier during an executor hop, even when both attempts are signed out or belong to the same account. Old transport successes, failures and cleanup cannot finish another attempt. Browser OAuth uses the pinned SDK's supported custom `launchFlow` closure with an application-owned, cancellable `ASWebAuthenticationSession`. Calendar uses the same browser ownership utility with its existing route/error behavior. PKCE exchange and server validation remain in the SDK.

Starting native Apple sign-in also supersedes older email/browser intents before suspension. Its controller and generation checks remain, while credential exchange carries the captured revision and attempt UUID. The native authorization boundary is injectable, allowing production-service tests to exercise actual SDK ID-token requests without opening Apple UI. Disposing an already-signed-out auth service now invalidates pending attempts and cancels its browser unconditionally; it does not rely on an account change to trigger cancellation.

Tests on exact source `ed8c8a4af92cdff40c6c7fd615b390a9a96452d9` finished October 24, 2026 at 18:31:23 UTC:

- Package `build-for-testing`: passed, 10.681 seconds.
- Package `test-without-building`: **109 tests passed, zero failures**, 9.232 seconds including Xcode orchestration.
- Tracked app wrapper, generic simulator destination, signing disabled: passed, 11.032 seconds.
- `git diff --check`: passed. Both tracked lockfiles remain unchanged from `48f48b4`; generated-workspace dependency identity/revision maps match the committed package lock.

The final count is 23 persistence-provider, nine poll-service lifecycle, twelve availability-editor, ten availability transport, eleven creation-editor, six creation transport, fifteen auth/provider lifecycle, twenty-two session/SDK transport, and one existing placeholder test. All 102 previous tests remain. The seven added transport tests cover: old links after a newer account/signed-out OTP initiation, before and after delayed initiation success/failure; an obsolete initiation paused before SDK verifier rotation; superseded browser completion; an old URL delivered into the current browser followed by its genuine callback; signed-out disposal during OTP/browser/PKCE work with delayed success/failure; Apple initiation superseding old email work; and late Apple ID-token success/failure after a newer email intent. The cold-restoration test additionally rejects missing, malformed, duplicate and implicit callback parameters before a genuine callback succeeds. An intermediate exact `5c65fc2` run passed all 107 tests and wrapper compilation; the 109-test result supersedes it after the Apple coverage/fix.

Commands (`repo=/private/tmp/meeting-scheduler-session-ios`):

```bash
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
  -destination 'platform=iOS Simulator,id=4AB7E492-E478-4B73-855B-3A1349DF677A' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:MeetingSchedulerTests \
  -resultBundlePath /private/tmp/session-ios-ed8c8a4-tests.xcresult test-without-building

xcodebuild -project "$repo/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-session-ios-wrapper-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-session-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Logs: `/private/tmp/session-ios-final-correlation-build.log`, `/private/tmp/session-ios-ed8c8a4-tests.log`, `/private/tmp/session-ios-ed8c8a4-wrapper.log`; result bundle: `/private/tmp/session-ios-ed8c8a4-tests.xcresult`.

The fresh dedicated iPhone 17 Pro / iOS 27.0 simulator `4AB7E492-E478-4B73-855B-3A1349DF677A` was created at 18:27:22 UTC under a new 30-minute reservation. Shutdown and deletion completed at 18:31:49 UTC, both exited zero, and the subsequent inventory confirmed absence. Only deterministic package tests ran on it. The tracked wrapper was compiled without launch. No existing device, live provider account, local server or hosted service was used.

[Native redirect configuration](../../../apps/mobile/README.md) documents the exact Supabase allowlist pattern `meetingscheduler://auth/callback\?attempt=*`, normal emitted URL, Google upstream redirect, and email-template query preservation. An approved owner must configure/verify these external settings and test real cold/warm Google/email/Apple delivery. Query preservation and hosted allowlist acceptance remain unverified. This follow-up changes no hosted configuration, schema, billing/command contract or durable creation persistence. The coordinator owns final combined-tree independent review and CI.

## Owner PR comments: shared screen task handling

The later source `90e4db3965cb9722255e3d52343b426fc2ca34a0` consolidates eighteen iOS screen actions through the production `AuthServiceProtocol.performSessionTask` helper and removes the duplicate profile guard. The coordinator implemented and reviewed this follow-up directly, without subagents. **119 tests pass**, including all 109 earlier tests and ten production-helper regressions, plus package and tracked-wrapper builds. No auth adapter, SwiftData or durable creation persistence implementation changed. [Comment evidence](review-comments.md) records exact commands, result bundle, screen integration, preserved predicates, two fresh-device cleanups and remaining hosted limitations. Current PR CI results are recorded in PR #72.
