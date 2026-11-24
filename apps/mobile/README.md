# Meeting Scheduler - iOS App

## Poll detail caching

Previously opened polls show the current account's complete cached detail before loading saved availability or checking calendars. Detail stays fresh for five minutes; reopening during that window reuses it without another detail request. Older snapshots stay visible while a complete refresh runs. A transport failure keeps the cached detail with an out-of-date notice. Denied or incomplete reads do not use that fallback.

The existing SwiftData account store supplies persistence across app launches. Pull down on poll content to force a refresh. Successful saves, joins, status changes and finalization invalidate cached detail; subsequent loads revalidate with the backend. Account transitions clear the previous account's cache. This cache does not queue offline writes.

## Participant submissions

The participants sheet shows how many people have submitted availability and each person's latest submission date and time, formatted in the device's locale and time zone. Joining alone stays “Not submitted.” Local drafts and failed saves do not change this status. Clearing all saved answers returns it to “Not submitted.”

Deploy `20261124022447_participant_submission_timestamps.sql` before shipping this UI. The authorized detail and availability reads expose `submitted_at` from the existing private response-version timestamp, which changes when saved answers or their comment change, including guest submissions and legacy direct writes. Replaying the same command or saving identical availability preserves the timestamp. Existing submissions already have version timestamps; rows predating version tracking use the latest saved answer time as a historical estimate. SwiftData retains the field with cached poll detail, so the existing five-minute cache and pull-to-refresh behavior also apply to submission status.

## Service composition

The app wrapper calls `AppServices.live()` once at launch, and `AppRootView(services:)` places the services in the SwiftUI environment through `appServices(_:)`. Views read them through `@Environment(\.authService)` and its siblings. There are no service singletons.

A preview binds mocks with `previewServices()`, passing only the services it cares about. Those two modifiers are the only ways to bind services, and both bind all of them. The compiler can't check that a view has services bound, so reading one with none bound traps in every build configuration. `AppServices.live()` is public for the wrapper; don't call it from previews or tests.

To add a service, add it to `AppServices` and add a field and a read-only accessor to `ServiceSet` in `ServiceEnvironment.swift`. `appServices(_:)` and `previewServices()` then won't compile until they supply it. `AppServicesTests` checks each binding, so extend its environment tests too. `scripts/ci/check-ios-environment-keys.sh` fails on an environment key outside `ServiceSet`. If the service holds account state, also add it to the identity fan-out in `AppServices` and extend `testIdentityTransitionsReachEveryAccountScopedServiceAndTransport`.

`AppServices` also owns one `AppClock`, bound beside the services and read as `@Environment(\.appClock)`. Read the time from it rather than calling `Date()` in services, persistence or views, so tests and previews can pin it with `AppClock.fixed(_:)`.

The poll detail and creation screens keep their orchestration in a `Shared` model that takes its services and clock in its initializer: `PollDetailModel` and `PollCreationModel`. The view builds the model from the environment and holds it in `@State`, and tests drive the model with the mocks. Follow the same shape when moving another screen's commands out of its view.

## Plan limits

The server sets each poll's capacity and active-poll quota when it creates the poll. The client keeps a copy of those limits only to describe plans, on `PollCreationEntitlement` (`participantLimit`, `allowsUnlimitedActivePolls`). Read limits and entitlement identifiers from there instead of writing the numbers or strings again. `EntitlementContractTests` checks the copy against `packages/shared-config/entitlements.json`, and the database suite checks that file against `create_poll`. To change a limit, change the migration, the file and the enum together.

## Authentication redirects

Email links and browser Google sign-in use Supabase PKCE with a persisted, single-use attempt UUID. The emitted redirect is:

```text
meetingscheduler://auth/callback?attempt=<UUID>
```

The app accepts only that auth scheme, host and path, with exactly one matching attempt and one nonempty `code` (or a provider `error`). It checks the originating account and JWT session identity before the SDK exchanges the code. A missing, malformed, duplicate or obsolete attempt cannot consume a newer intent or rotate its verifier. Request a fresh link from this build for older links without an attempt. Calendar OAuth remains on its separate calendar route; native Apple ID-token sign-in does not use this redirect. Starting Apple sign-in supersedes earlier browser/email intents, and its SDK result retains that original attempt even if another sign-in starts.

The project owner must configure Supabase **Authentication → URL Configuration → Redirect URLs** to accept the attempt query. Use this allowlist pattern, with one literal backslash before `?`:

```text
meetingscheduler://auth/callback\?attempt=*
```

This follows the [documented Supabase glob syntax](https://supabase.com/docs/guides/auth/redirect-urls). The app sends a normal query separator without the backslash. Keep the scheme, host and path exact. An existing exact entry without the query must not be assumed to accept the new URL. Email templates must preserve the SDK-provided confirmation URL/redirect query. Google's upstream provider redirect remains the project's `https://<project-ref>.supabase.co/auth/v1/callback`; the native app URL is the subsequent Supabase redirect.

Before beta release, an owner with an approved test account/environment must verify the allowlist matches the complete emitted URL and preserves `attempt` through Google and email links on cold and warm launches. Verify cancellation, expired codes, duplicate links, old links after another account starts sign-in, and the genuine current link afterward. Deterministic tests exercise the production service and pinned Supabase Swift SDK with injected browser results and URLProtocol transport; they do not verify hosted allowlists, provider configuration, OS browser delivery or real sign-in. This change does not modify hosted settings.

## Poll links

All share actions and QR codes use `https://meetful.app/join/<six-character-code>`. On iOS, `PollLink` accepts this URL and `meetingscheduler://join/<code>`, validates the six ASCII letters/digits, and opens a prefilled confirmation sheet. Opening the link does not join. The recipient chooses Join Poll or Cancel; a confirmed join runs the existing server command before opening detail. A link received while signed out waits above sign-in. A link received while creating a poll waits until that flow closes.

The browser looks up the code and shows the poll title with the same explicit Join Poll and Cancel choices. Signed-out browser guests must also enter a name. Android shares the same URL and uses this browser flow. New share URLs contain the code, with no poll UUID or query parameters. Older UUID links remain supported by the previous detail/join fallback. A non-active preview is returned only for an existing owner or member; confirming that invitation opens its results without adding membership.

The app claims `applinks:meetful.app`. The web serves `/.well-known/apple-app-site-association` from `apps/web/src/lib/apple-app-site-association.ts`, and the alpha password gate lets that path through. The file claims six-character `/join/` paths and the older UUID-shaped `/polls/` paths; other pages remain on the web. Every unrelated URL still goes to `AuthService.handleDeepLink`.

The project owner must deploy the updated association file and ship the app before code invitations open the native confirmation sheet. Associated Domains must be enabled for `com.jacobgrant.MeetingScheduler`. Check that the association endpoint returns 200 with `content-type: application/json` and no redirect. Apple's CDN caches the file. Before release, verify cold/warm universal links and sign-in handoff on a physical device, and confirm that cancelling before Join Poll adds no participant. Cancel and swipe dismissal are disabled while joining.
