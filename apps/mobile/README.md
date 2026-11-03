# Meeting Scheduler - iOS App

## Service composition

The app wrapper calls `AppServices.live()` once at launch, and `AppRootView(services:)` places the services in the SwiftUI environment through `appServices(_:)`. Views read them through `@Environment(\.authService)` and its siblings. There are no service singletons.

A preview binds mocks with `previewServices()`, passing only the services it cares about. Those two modifiers are the only ways to bind services, and both bind all of them. The compiler can't check that a view has services bound, so reading one with none bound traps in every build configuration. `AppServices.live()` is public for the wrapper; don't call it from previews or tests.

To add a service, add it to `AppServices` and add a field and a read-only accessor to `ServiceSet` in `ServiceEnvironment.swift`. `appServices(_:)` and `previewServices()` then won't compile until they supply it. `AppServicesTests` checks each binding, so extend its environment tests too. `scripts/ci/check-ios-environment-keys.sh` fails on an environment key outside `ServiceSet`. If the service holds account state, also add it to the identity fan-out in `AppServices` and extend `testIdentityTransitionsReachEveryAccountScopedServiceAndTransport`.

`AppServices` also owns one `AppClock`, bound beside the services and read as `@Environment(\.appClock)`. Read the time from it rather than calling `Date()` in services, persistence or views, so tests and previews can pin it with `AppClock.fixed(_:)`.

The poll detail and creation screens keep their orchestration in a `Shared` model that takes its services and clock in its initializer: `PollDetailModel` and `PollCreationModel`. The view builds the model from the environment and holds it in `@State`, and tests drive the model with the mocks. Follow the same shape when moving another screen's commands out of its view.

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
