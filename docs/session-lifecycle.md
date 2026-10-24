# Client session lifecycle contract (F12/F14/F22)

All three clients use an account identity plus a monotonically increasing in-process generation. This contract supplements the existing command, cache and billing contracts; it does not change server authorization.

## Boundaries and observation

Register one owned auth observer before asynchronous restoration. Consume auth changes synchronously without waiting for profile, calendar or billing I/O. A later auth event wins over an older initialization result. Initialization, account replacement, explicit/external sign-out, expiry and reauthentication are covered. An ordinary same-account token refresh updates credentials without resetting the generation, drafts or listeners. Crossing A → signed-out → A or A → B → A creates distinct generations even when the account UUID repeats.

At each account boundary, advance the generation and synchronously clear account-owned visible state and errors: profile, poll lists/detail/children, response editor, subscription/pass projections and calendar connections/conflicts/preferences. Cancel obsolete requests, deferred tasks and screen work; dispose listeners. Cancellation is cooperative, so every success, failure and cleanup also checks its captured generation and identity before publishing. Old cleanup must not clear a newer session. Same-account competing reads additionally retain their existing request-order guards.

## Persistence and commands

Retain the already-tested iOS account cache design. Account-owned preferences and recovery records use an account key; signed-out state cannot read an account's records. Preserve legitimate current-account drafts. In particular, switching away never deletes an unresolved creation envelope: returning to that account restores its exact operation UUID and payload, including the ambiguous-result edit lock. Availability drafts/retry identities remain owned by their original account and cannot appear in another account's screen. Every authenticated request captures its initiating session credentials before its first suspension. Cancellation or explicit credential binding must prevent queued work from dispatching under a later account after SDK initialization or token lookup. Completion checks alone do not protect dispatch. Server commands remain authoritative and idempotent; local premium flags grant no authority.

Explicit client sign-out revokes the captured current session with local/device scope. An old remote logout must not revoke a newly authenticated session of the same account. Global account/session administration is a separate operation. SDK credential cleanup must be isolated or ordered so delayed success/failure cannot clear a newer session.

## Provider reconciliation

RevenueCat identity changes must serialize and reconcile toward the latest desired account independently of profile loading. Clear local entitlement/pass visibility immediately at a boundary. If an old provider call cannot be cancelled, let it finish in its ordered worker and then apply the latest desired identity; never run a stale logout concurrently with a new login. Fence provider reads, callbacks and errors by generation, and ensure delayed cleanup cannot undo the current identity. Calendar requests/callbacks carry equivalent ownership and cancellation checks; device preferences are partitioned by account. Slow/failing provider operations must not stop observation of auth events.

## Callback and listener ownership

Authentication callbacks retain the intent that initiated them, including across process/browser startup. Verify that intent against current persisted session ownership before the SDK can save callback credentials; navigation or UI guards after SDK URL initialization are insufficient. Consume an accepted attempt once, reject obsolete attempts, and retain SDK PKCE/state/server validation.

Android cold and warm intents enter the same application-owned auth callback router, which waits for SDK initialization. Only the exact configured auth URI route is accepted. Calendar callback routing remains separate. Use the pinned SDK's supported PKCE/state/session APIs; validate malformed, expired, error, duplicate and obsolete callbacks. Preserve native Google ID-token sign-in. Document hosted allowlist/provider actions separately from deterministic source tests.

Web auth callbacks stay synchronous; dependent SDK work is deferred until the SDK releases its auth lock. Mount/unmount owns listener and deferred-work disposal; SSR creates no browser listeners. Repeated initialization cannot leak listeners or resurrect disposed work.

## Verification ownership

Platform owners test production controllers/services/adapters with injected dependencies, including delayed success and failure over A → B, A → logout → A and initialization races. Cover offline replacement, expiry, refresh, disposal/cancellation, recreation, provider ordering and old cleanup. Keep live-provider checks distinct. Preserve creation/availability regressions and add SDK transport checks where integration warrants them.

Coordinator owns this contract, shared test scripts/workflows and final combined review. Web owns `apps/web`, web lifecycle tests and its evidence; Android owns `apps/android` and its evidence; iOS owns `apps/mobile` and its evidence. Workers must request coordinator approval naming resource, actions, duration and cleanup before using any simulator, emulator, localhost server, Supabase/Docker instance or existing local service. Prior reservations and device IDs confer no permission.
