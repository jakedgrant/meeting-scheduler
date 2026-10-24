# Web F12/F22 lifecycle evidence

Source/test commit: `c5b6538e26f066515e2cdaf95db9ddc700181238`, based on the agreed session contract `483ca17` and verified main `d51f45a366cbd4a9ecd30e774d8b50441a938894` (PR #71). Work was isolated in `/private/tmp/meeting-scheduler-session-web`, branch `codex/f12-f22-web`. The original checkout and `.claude/worktrees/` were untouched.

## Changes delivered

The root layout mounts the production `mountClientSession` composition synchronously, so unmount can dispose its auth observer, calendar/subscription listeners and deferred timers even while SDK restoration is pending. Repeated owners share one external observer; old owner cleanup cannot reset a newer owner. Server rendering installs no browser observer or provider.

Auth registers its observer before restoration. Callbacks remain synchronous. Every event schedules a later SDK-session check: the pinned SDK forwards BroadcastChannel hints directly to observers, including stale sessions that disagree with current SDK storage. A cross-account hint clears visible account state immediately and keeps commands unavailable until SDK verification. A same-account hint retains visible state and the session generation while verifying the current token, expiry and user object. Realtime credentials are reconciled to verified SDK storage before accepting the session. An older restoration/check, including its failure, cannot overtake a later event. Same-account token refresh does not reload profiles, reset drafts or replace calendar/list listeners.

A shared identity/generation and cancellation signal fence profile edits/reads, subscription and offering loads, poll list/detail/child reads, commands, calendar operations, callback navigation and pending screen work. Account replacement, external/explicit sign-out, expiry and A → B → A all clear old projections. Read cancellation supplements generation checks; old failures and `finally` blocks cannot change the current session. Detail routes have ownership leases, so a previous route's cleanup cannot clear the next route's state. Settings, dashboard, response detail, creation, auth and purchase components use the lifecycle boundaries.

RevenueCat configures once per owned SDK lifetime, uses the pinned Web SDK's non-aliasing `changeUser` API for account replacement and `close` on logout. One worker serializes identity side effects and provider operations and reconciles the latest desired account after delayed success or failure. A stale queued logout cannot close the new identity. Clearing entitlement visibility and observing later auth events do not wait for profile or provider I/O. A failed provider read cannot erase a successful current-account subscription-table read.

The expiry timer hides account-owned state if offline SDK refresh retries retain an expired session. A subsequent valid authentication creates a new generation; ordinary pre-expiry refresh retains the current generation. Timers from an old account cannot expire a later account.

Creation keeps the merged durable, exact-payload account envelope and ambiguous-result edit lock. Switching accounts never deletes A's unresolved operation. The response editor now retains account/poll/participant recovery records, including its original save UUID/version, across account replacement and screen recreation. B receives an empty editor or its own draft. Returning to A can replay its original operation. No command, server entitlement rule, guest capability, RLS/grant or migration changed.

## Deterministic validation

On the source/test commit above:

```bash
node --test tests/web-session-lifecycle.test.mjs tests/web-availability.test.mjs tests/web-creation.test.mjs tests/web-guest-capability.test.mjs
# 111 tests passed: 55 new lifecycle/SDK tests plus 56 existing regressions.

cd apps/web
npm run check
# 0 errors, 5 existing warnings (Paywall accessibility and dashboard line-clamp).
VITE_SUPABASE_URL=https://session.test.invalid VITE_SUPABASE_ANON_KEY=test-anon-key npm run build
# Production client/SSR build passed; adapter-auto reported no deployment target.
```

`git diff --check` passed. Node was `v26.5.0`; installed and lockfile-pinned SDKs were `@supabase/supabase-js`/`@supabase/auth-js` `2.89.0` and `@revenuecat/purchases-js` `1.23.0`. Dependencies were copied into this isolated clone from the existing local installation; no package version or lockfile changed. Build environment values above are non-secret test placeholders.

The new suite bundles the actual auth/poll/subscription/calendar stores, provider worker, callback/expiry/editor controllers, root composition and Svelte SSR. Only transport, platform environment and provider SDK are injected. It covers:

- Delayed successful and failed restoration and auth verification; old profile/subscription/calendar/list/detail completions over A → B, A → logout → A and A → B → A; failed replacement while offline; request cancellation and stale cleanup/finally.
- Repeated profile/user changes, same-account token refresh, disposal during restoration, duplicate mounts, remount, SSR without browser listeners and expiry/reauthentication.
- Provider identity side effects followed by success or failure, ordered A → B → A reconciliation, stale logout, delayed customer-info/offerings/purchase results and prompt observation of B while provider work is pending.
- Current and obsolete callback success/failure, callback unmount, account-owned creation recovery and exact operation/payload replay, and availability retry identity across account replacement/recreation.

Eight tests use the **real pinned Supabase SDK** with an injected Fetch transport and an owned SDK lock. They prove that actual profile/subscription/calendar HTTP requests occur after the auth callback releases its lock, that delayed A logout/refresh completes before queued B installation, and that final SDK credentials and app state agree on B. The same SDK method used by its BroadcastChannel handler replays stale cross-account SIGNED_IN/TOKEN_REFRESHED/SIGNED_OUT hints and stale same-account SIGNED_IN/TOKEN_REFRESHED/USER_UPDATED tokens/expiry/metadata. These checks prove that A's recovery envelope cannot become visible or dispatch a creation while SDK B is current, and that Realtime's token is repaired to current storage. No private SDK method is used in production code.

The final local logs are `/private/tmp/web-session-all.log`, `/private/tmp/web-session-check.log` and `/private/tmp/web-session-build.log`. A transient fixture JWT-format error was fixed before final validation. A timer-sensitive assertion was replaced with explicit macrotask draining; final tests have no skipped or cancelled cases.

## Review, resources and owner actions

The web worker self-reviewed the final source and fixed stale broadcast verification (including same-account expiry/metadata), Realtime credential reconciliation, stale route cleanup and dashboard read cancellation. Independent review of the combined platform tree and relevant CI belong to the coordinator and are not claimed by this platform record.

No simulator, emulator, local server, listening port, Supabase/Docker instance or existing service was started or reused. All Fetch traffic was injected in-process; no test reached the placeholder host or a hosted account. Test-created temporary bundle directories were removed by teardown. Disposable dependencies, build output and text logs remain in the isolated clone or `/private/tmp`; no runtime reservation remains.

No hosted redirect allowlist, Google/Apple/Supabase login, real RevenueCat identity/purchase, mounted browser UI journey, deployed SSR adapter or live calendar consent was verified. The owner must supply an approved test account/environment, confirm the deployed `/auth/callback` redirect and calendar return origin allowlists, and exercise sign-in, sign-out, refresh/expiry, account replacement, real purchase cancellation and calendar consent/disconnect there before claiming provider validation. SDK purchase UI and non-cancellable provider work can remain in flight until the SDK completes; generation checks prevent its results from entering the next account and identity reconciliation remains ordered. No hosted configuration or development/beta data was changed.

## Coordinator dispatch follow-up

Integration source `b1e311a60025252aa68a171370ea060739b81141` attaches the account cancellation signal to every poll RPC mutation (creation, joining, finalization and availability) and status writes. Successful/failed completion guards alone did not prevent an A creation from waiting behind SDK B installation, then obtaining B's token before HTTP dispatch. The original creation path **fails** the new real-SDK regression; cancellation prevents the request from reaching transport under the replacement identity. A's durable exact-payload recovery record remains intact and is never copied to B.

Test follow-up `d0a7e82` additionally exercises the existing production calendar disconnect cancellation through the same real SDK lock/credential race. No A disconnect reaches transport under B. The integrated suite passes **113 tests** (57 lifecycle/SDK, 56 existing regressions). Integrated type checking passes with zero errors/five existing warnings, and the production client/SSR build passes. No SDK version or command/backend contract changed. Logs are `/private/tmp/session-integration-web-tests3.log`, `/private/tmp/session-integration-web-check2.log`, `/private/tmp/session-integration-web-build2.log`; expected failure of the original dispatch path is `/private/tmp/session-web-dispatch-regression-before.log`.

Coordinator source `6aeb9a1` also makes explicit sign-out local/device scoped. The real SDK logout test asserts `scope=local`, so an old A logout cannot revoke a newly authenticated A session globally. Final rerun: 113 tests pass, type check has zero errors/five existing warnings, production client/SSR build passes. Logs: `/private/tmp/session-integration-web-tests4.log`, `/private/tmp/session-integration-web-check4.log`, `/private/tmp/session-integration-web-build4.log`.
