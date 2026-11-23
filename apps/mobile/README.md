# Meeting Scheduler - iOS App

## Poll detail caching

Previously opened polls show the current account's complete cached detail before loading saved availability or checking calendars. Detail stays fresh for five minutes; reopening during that window reuses it without another detail request. Older snapshots stay visible while a complete refresh runs. A transport failure keeps the cached detail with an out-of-date notice. Denied or incomplete reads do not use that fallback.

The existing SwiftData account store supplies persistence across app launches. Pull down on poll content to force a refresh. Successful saves, joins, status changes and finalization invalidate cached detail; subsequent loads revalidate with the backend. Account transitions clear the previous account's cache. This cache does not queue offline writes.

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

`https://meetful.app/polls/<UUID>` opens the poll in the app when it's installed, and the web page otherwise. The app claims `applinks:meetful.app`. The web serves `/.well-known/apple-app-site-association` from `apps/web/src/lib/apple-app-site-association.ts`, and the alpha password gate lets that path through. The file claims only paths shaped like a UUID under `/polls/`, so `/polls/new`, the per-time pages and `/join/<code>` stay on the web. `meetingscheduler://polls/<UUID>` opens the same screen, which helps on a simulator before the file is deployed.

`PollLink` parses both forms. `AppRootView` keeps the link above sign-in, so a link opened while signed out opens after sign-in. The Meets tab then pushes the poll. Every other URL still goes to `AuthService.handleDeepLink`. The server still restricts detail reads to the creator and participants. If the read is denied, the screen offers Join Poll, calls `join_poll` on confirmation, then reloads complete detail. Closed, past-deadline and full polls report the server refusal. The browser offers the same join action for UUID links, with a name required for signed-out guests. Code links keep their existing preview and join flow.

Before links open the app, the project owner must enable **Associated Domains** for `com.jacobgrant.MeetingScheduler` in the Apple Developer portal (automatic signing may do it on the next signed build) and deploy the web. Then check that `curl -i https://meetful.app/.well-known/apple-app-site-association` returns 200 with `content-type: application/json` and no redirect. Apple's CDN caches the file, so a change can take a while to reach devices.
