# Calendar credentials: design and rollout

The old implementation put plaintext Google access and refresh tokens on publicly readable profiles. This change removes those columns, disables the old token-upload endpoint, and gives the backend sole ownership of Google calendar authorization. The web, iOS, and Android clients receive connection metadata and conflicting option IDs only.

**Status:** implemented and validated locally; no hosted migration, secrets, functions, Google configuration, or client release has been applied. The existing hosted credentials remain a risk until the rollout below is completed. This is an internal test project with one account, so the migration deliberately discards the old credentials. It does not preserve compatibility with older clients.

## How it works

1. A signed-in client calls `calendar-connection` with `action: start`. The function cryptographically verifies the Supabase JWT and checks that its login session still exists and the user is not banned or deleted. It takes the user ID from those verified claims.
2. The backend constructs a Google consent URL with a random state and an S256 PKCE challenge. Postgres stores only the state hash and an encrypted verifier, bound to that user and login session. Consent lasts ten minutes. Web return origins come from a server allowlist; mobile returns use `meetingscheduler://calendar/callback`.
3. Google sends its authorization code to the backend callback. The backend consumes the state once, exchanges the code with its confidential client and PKCE verifier, checks the granted scope, verifies the Google account, and encrypts both tokens. Clients receive a result marker and fetch status from the API to verify it.
4. `check-calendar-conflicts` decrypts credentials only inside the Edge Function. It refreshes expired access tokens and sends one FreeBusy request for the primary Google Calendar. It returns only overlapping option IDs. Checks are bounded to 200 options, seven days per option, and a 93-day overall window. Provider errors produce failed requests and visible uncertainty in the clients.
5. Disconnect immediately removes the app's usable credentials and invalidates pending callbacks and refresh writes. Google revocation goes into a durable encrypted queue, including on account deletion. Reconnect waits for revocation to finish. A consumed callback retains a processing fence until it stores or queues cleanup, preventing an older callback from revoking a newer consent grant. The fence has a ten-minute recovery lease, longer than the hosted worker lifetime and provider timeouts.

The three credential tables live in the unexposed `private` schema with RLS and no client grants. A finite `calendar_admin` RPC is executable only by `service_role`; its invoker privileges do not elevate client access. The private helpers that read Auth or handle deletion have fixed empty search paths. The service-role key never enters a client build.

Credentials use AES-256-GCM with random IVs and authenticated user/purpose context. Ciphertexts carry a version and key ID. Keys live in Edge Function secrets outside Postgres. A database-only read cannot decrypt them; compromise of both the backend secrets and database still exposes the grants. Key loss makes the affected connections unrecoverable, so retain the key ring securely.

`verify_jwt = false` in the five calendar function configurations is intentional: the user endpoints perform signature and live-session checks in the handler; the callback uses single-use state and PKCE; maintenance uses its own secret; the obsolete upload endpoint always returns 410. See [Supabase's function authentication guidance](https://supabase.com/docs/guides/functions/auth).

## Configure Google and server secrets

Create a dedicated **Web application** OAuth client for calendar access and enable the Google Calendar API. Keep calendar authorization separate from the client used by Supabase sign-in. Google revocation can affect a broader grant, so a separate Google Cloud project gives stronger isolation if sign-in and calendar currently share a project. Register this exact authorized redirect URI for the configured Supabase project:

```text
https://jaymsvyddyvvozzrgfpg.supabase.co/functions/v1/calendar-oauth-callback
```

The backend asks for `openid email https://www.googleapis.com/auth/calendar.events.freebusy`. It requests offline access and explicit consent. Add the internal test account to the consent screen's test users. Google's testing-mode refresh-token lifetime may require periodic reconnection; see [Google's server OAuth guide](https://developers.google.com/identity/protocols/oauth2/web-server) and [FreeBusy scope documentation](https://developers.google.com/workspace/calendar/api/v3/reference/freebusy/query).

Generate fresh keys without printing them:

```bash
node scripts/generate-calendar-secrets.mjs
```

This exclusively creates the ignored `.env.calendar.local` file with owner-only permissions. It refuses to overwrite an existing file. Fill in these settings locally, then upload the file to Supabase Secrets. Do not copy its contents into source files, logs, issue comments, or client build settings.

| Setting | Value |
| --- | --- |
| `CALENDAR_TOKEN_KEY_ID` | Active encryption key ID, generated by the helper. |
| `CALENDAR_TOKEN_KEYS` | JSON map of key IDs to 32-byte base64url keys, generated by the helper. Keep retired decrypt keys during rotation. |
| `CALENDAR_MAINTENANCE_SECRET` | Separate random 32-byte base64url secret, generated by the helper. |
| `CALENDAR_GOOGLE_CLIENT_ID` | Dedicated Google Web OAuth client ID. |
| `CALENDAR_GOOGLE_CLIENT_SECRET` | That client's secret. |
| `CALENDAR_ALLOWED_WEB_ORIGINS` | Comma-separated exact origins. Include the actual deployed web origin and any needed localhost origin. HTTPS is required except on localhost or 127.0.0.1. No paths or wildcards. |
| `CALENDAR_OAUTH_REDIRECT_URI` | Optional override; defaults to `SUPABASE_URL/functions/v1/calendar-oauth-callback`. It must match Google exactly. |
| `CALENDAR_JWT_ISSUER` | Optional local/custom-domain override; production defaults to `SUPABASE_URL/auth/v1`. |

Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to the backend. Do not put the service-role key in the generated file or any app configuration.

## Internal rollout checklist

The tasks in this section need hosted access or the account owner's Google consent. They are intentionally unchecked until completed.

- [ ] Pause internal calendar testing and revoke the **old** app's Google access in the test account's [third-party connections](https://myaccount.google.com/connections). Deleting database columns cannot invalidate tokens already exposed or retained in old backups. Reconnect Supabase sign-in too if it shared that old grant.
- [ ] Create/configure the dedicated Google calendar client, add the test account, and fill in all server settings above. Confirm the production web origin.
- [ ] Authenticate the Supabase CLI and link the intended project. Confirm migration history matches this checkout; do not blindly apply unrelated missing migrations.
- [ ] Upload the generated secrets, deploy the 410 upload tombstone, apply the new migration, and deploy the new calendar endpoints in the sequence below.
- [ ] Deploy the updated web app and install updated iOS and Android test builds. Older clients cannot use the new connection flow.
- [ ] Configure and enable the maintenance workflow below. Run it once manually and confirm it succeeds.
- [ ] Run the hosted permission checks below and inspect Supabase security advisors for the newly created objects. Confirm `private` is absent from the hosted Data API exposed schemas.
- [ ] On web, iOS, and Android: connect the test account, check a known busy/free poll, cancel consent, disconnect, and reconnect. Confirm sign-out/account switching clears connection state. In a second browser session, disconnect during consent and during a conflict check; neither late response may restore access.
- [ ] Test revocation retry by temporarily preventing the maintenance worker from reaching Google in a non-production environment, then restore access and confirm the queue drains. Never log or inspect token plaintext to do this.

Commands, from the repository root after linking the intended project:

```bash
supabase secrets set --project-ref jaymsvyddyvvozzrgfpg --env-file .env.calendar.local
supabase migration list --linked
supabase db push --linked --dry-run

# Disable the old deployed upload function before removing its storage columns.
supabase functions deploy store-calendar-token --project-ref jaymsvyddyvvozzrgfpg --use-api
supabase db push --linked
supabase functions deploy calendar-connection calendar-oauth-callback check-calendar-conflicts calendar-maintenance --project-ref jaymsvyddyvvozzrgfpg --use-api
```

Inspect the dry run: the intended new migration is `20261022025019_private_calendar_credentials.sql`. Keep the explicit function names to avoid redeploying unrelated billing endpoints. There is no safe rollback to the old plaintext credential design; recover by fixing the new functions/configuration and reconnecting the test account.

Hosted checks in the Supabase SQL editor should return zero old columns and `false` for every client privilege. These queries return no credentials:

```sql
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'profiles'
  AND column_name IN ('google_calendar_access_token', 'google_calendar_refresh_token',
    'google_calendar_token_expires_at', 'calendar_integration_enabled');

SELECT role_name,
  has_schema_privilege(role_name, 'private', 'USAGE') AS private_access,
  has_function_privilege(role_name, 'public.calendar_admin(text,uuid,jsonb)', 'EXECUTE') AS repository_access
FROM unnest(ARRAY['anon', 'authenticated']) AS role_name;
```

## Maintenance and rotation

`.github/workflows/calendar-maintenance.yml` calls the maintenance endpoint every five minutes, with a manual trigger too. Set repository variable `CALENDAR_MAINTENANCE_URL` to `https://jaymsvyddyvvozzrgfpg.supabase.co/functions/v1/calendar-maintenance` and repository secret `CALENDAR_MAINTENANCE_SECRET` to the same value stored in Supabase. It needs no repository token permissions or service-role key. It follows no redirects and logs only counts. Until the URL is configured, the job skips.

The workflow must reach the default branch before scheduled runs occur. GitHub schedules can be delayed, so monitor failed runs and queue age; use a managed scheduler if strict timing is needed. [GitHub documents these scheduling limits](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).

Each run retries up to 20 due revocations with leases and bounded backoff, prunes expired OAuth attempts, and re-encrypts up to 100 connections with the active key. Failed revocations stay encrypted in the queue; app access remains disconnected while retrying. Check queue count and oldest creation time in SQL without selecting ciphertext. A job failing with `calendar_oauth_cleanup_required` needs investigation and manual grant revocation if cleanup could not be persisted or sent to Google.

To rotate a key without losing access:

1. Generate a new random 32-byte key and add it under a new ID in `CALENDAR_TOKEN_KEYS`, retaining every existing decrypt key. Deploy that expanded key ring to **all** calendar functions first.
2. Switch `CALENDAR_TOKEN_KEY_ID` to the new ID. Redeploy all calendar functions and let previous worker instances drain. New ciphertext now uses the new key.
3. Run maintenance repeatedly until all connection envelopes use the new ID. Let OAuth processing leases expire and confirm no queued revocation references the old key. Check metadata/counts only.
4. Retain retired keys as long as any live ciphertext, delayed worker, restorable database backup, or retained local export may need them. Remove them only after those retention obligations end. Rotating encryption alone cannot repair an exposed Google grant; revoke the grant and reconnect when compromise is suspected.

Keep failure notifications for this workflow enabled. If it stops, disconnect still blocks app access but remote Google revocation and record rotation can be delayed.

## Validation evidence

- Postgres/PGlite replays every repository migration: **12 passing tests**, including removed public columns, denied client privileges, RLS, pinned search paths, live sessions, state replay/expiry, refresh CAS, callback/disconnect fences, lease recovery/backoff, and account-deletion revocation.
- Deno: **23 passing tests** with network and environment access denied, including actual Supabase SDK ES256 signature verification, AES-GCM owner/purpose binding, PKCE, provider failures, revocation retries, and key rotation. All five calendar entry points type-check with a frozen lockfile.
- Web: type check passes with zero errors and seven existing warnings; production build passes.
- Android: `compileDebugKotlin` and `testDebugUnitTest` pass with JDK 21 and Android SDK 36. The repository has three existing unit tests; these do not exercise live Google consent.
- iOS: the entire Swift package and application wrapper build successfully for the simulator with RevenueCat 5.97.0 under Xcode 27.1 / Swift 6.4. The existing Swift package test passes (one test, zero failures). This uses the real billing SDK, including the [upstream initializer fix](https://github.com/RevenueCat/purchases-ios/pull/6949) that resolves the previous `PaywallColor.swift` and CustomerCenter compilation errors. Live provider consent and native UI flows remain rollout checks.
- No npm advisory scan was run, per the user's instruction. Hosted permission/advisor checks and real consent/disconnect tests remain rollout tasks.

Run the repeatable backend checks with `npm run test:calendar:db` and `npm run test:calendar:edge`. `.github/workflows/calendar-security.yml` runs them on pull requests and pushes to main.
