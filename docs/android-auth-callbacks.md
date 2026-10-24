# Android authentication callbacks

Android uses `meetingscheduler://auth/callback` for Supabase authentication. `MainActivity.onCreate` and `onNewIntent` send this exact route to the same application-owned router. The calendar route remains `meetingscheduler://calendar/callback`; it only requests current-account connection metadata from the calendar backend.

## SDK and request configuration

The app pins Supabase Kotlin **3.3.0**. Auth configuration sets `scheme = "meetingscheduler"`, `host = "auth"`, `defaultRedirectUrl = "meetingscheduler://auth/callback"`, and `FlowType.PKCE`. OTP requests and the Google browser fallback pass the same explicit redirect. Native Credential Manager Google sign-in retains its ID token and original nonce.

Current official [initialization](https://supabase.com/docs/reference/kotlin/initializing), [code exchange](https://supabase.com/docs/reference/kotlin/auth-exchangecodeforsession), and [native mobile deep-link](https://supabase.com/docs/guides/auth/native-mobile-deep-linking) documentation were checked against the installed 3.3.0 Android artifact. The pinned SDK exposes `awaitInitialization`, `exchangeCodeForSession(code, saveSession = false)`, `importSession`, and the ID-token provider's custom success callback. Tests execute those SDK methods through Ktor MockEngine.

The router accepts the exact scheme, host and `/callback` path. It rejects other paths, credentials in the authority, ports, fragments and malformed URIs. It rejects missing/duplicate codes and reports provider cancellation or exchange failure without logging credentials. PKCE verifier validation and one-time code handling belong to the SDK/server. The client never imports URL-supplied access tokens.

## Attempt ownership and process startup

A pending attempt is stored before starting OTP/browser work. It contains an account/generation key, process identifier, attempt UUID, creation time and readiness flag. Starting another attempt replaces the UUID. Native Google also invalidates a pending browser/OTP attempt. SDK initiation is serialized so overlapping requests cannot race writes to the SDK's shared PKCE verifier.

An account boundary invalidates the persisted attempt. A valid old code arriving only after B signs in is rejected before exchange. An older exchange's success, failure or cleanup cannot affect a newer attempt in the same session. Authentication links received before SDK initialization wait for restoration. Only the initial restoration in a new process may rebind a saved attempt, and only when its owner matches the restored account. A signed-out attempt cannot replace a restored B session. Attempts expire after 15 minutes. Duplicate delivery is ignored; consumed attempts remain consumed across process restart.

Callbacks queued while a request is still starting wait for that request to become ready or obsolete. A cold process can recover a saved pending attempt after the original HTTP response was lost, using the persisted SDK verifier. A link opened on another app installation has no matching attempt/verifier and must be requested again there.

## Session publication and sign-out

SDK refresh jobs and gateway credential mutations run on `Dispatchers.Main.immediate`. `AtomicSessionManager` uses the same default Settings backing, scoped key and public `UserSession` serializer as 3.3.0, including its legacy `session` key migration. The Android backing uses `SharedPreferences.apply`. Save/remove update memory synchronously, so there is no dispatcher switch between persistence and SDK auth-state publication. This replaces the pinned default manager's `withContext(IO)` gap without changing the saved schema.

Gateway imports serialize, check ownership after entering the mutation boundary, cancel old refresh work and publish the new session before starting its refresh worker. Poll RPCs/status updates and calendar requests bind the originating app-session credential explicitly; a later SDK credential lookup cannot dispatch an old envelope as B. Transport tests assert every Authorization header value, including the absence of duplicate A/B headers. Actual SDK transport tests delay old refresh success and failure across replacement and returning-account sessions. They check both SDK credentials and persisted credentials.

Explicit sign-out cancels refresh and clears shared SDK credentials immediately. Remote revocation uses an ephemeral in-memory SDK client containing only the captured old session, with `SignOutScope.LOCAL`. Its delayed success or failure cannot clear a replacement session or retain the old shared credential. The local scope revokes that captured session rather than signing out other devices or a new reauthentication session.

## Required external configuration

These are owner actions. Hosted configuration and real provider sign-in were not verified in this workstream.

1. Add the exact `meetingscheduler://auth/callback` URL to the intended Supabase project's Auth redirect allowlist. Keep calendar redirects configured separately according to [calendar credentials](calendar-credentials.md).
2. Enable the intended Google OAuth provider and register the project's Supabase Auth callback URL (`https://<project-ref>.supabase.co/auth/v1/callback`) in its Google web OAuth client. Confirm the configured web client ID matches the native ID-token audience.
3. Register the intended Android application IDs and signing certificate SHA-1 values for native Google. Debug and release signing differ; use the actual intended certificates described in [Android release signing](android-release-signing.md).
4. Keep the OTP email link template compatible with Supabase's confirmation URL and requested redirect. Test the link on the installation that requested it.
5. Use an approved test project/account to verify native Google, browser Google and OTP with the app cold and warm; cancellation, expiry and replay; A → B and A → logout → A; offline sign-out and reconnection. Confirm RevenueCat's actual current app user ID in the test dashboard. Local tests do not establish hosted allowlists, email delivery, Google consent, RevenueCat identity or purchases.

The emulator checks used a fresh task-owned Android 36 device with Wi-Fi and mobile data disabled before app installation. They exercised Activity routing, recreation and a persisted cold-start cancellation callback. No real account or provider session was used. Exact commands and results are recorded in the [Android workstream evidence](architecture-remediation-evidence-2026-10-23/f12-f14-f22/android.md).
