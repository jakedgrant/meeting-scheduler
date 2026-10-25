# sv

Everything you need to build a Svelte project, powered by [`sv`](https://github.com/sveltejs/cli).

## Creating a project

If you're seeing this, you've probably already done this step. Congrats!

```sh
# create a new project in the current directory
npx sv create

# create a new project in my-app
npx sv create my-app
```

## Developing

Once you've created a project and installed dependencies with `npm install` (or `pnpm install` or `yarn`), start a development server:

```sh
npm run dev

# or start the server and open the app in a new browser tab
npm run dev -- --open
```

## Building

To create a production version of your app:

```sh
npm run build
```

You can preview the production build with `npm run preview`.

> To deploy your app, you may need to install an [adapter](https://svelte.dev/docs/kit/adapters) for your target environment.

## Authentication callbacks and session ownership

The client keeps the existing Supabase storage key (`sb-<project-host-prefix>-auth-token`). It configures the SDK's public storage and lock interfaces explicitly. Local sign-out compares account plus JWT `session_id` under the same SDK lock, removes only that session, then uses `auth.admin.signOut(capturedJWT, 'local')` to revoke that original session outside the lock. A queued sign-out cannot select a newly installed account or fresh login to the same account. If remote revocation fails, the device remains signed out; server revocation was not confirmed.

Web Google, Apple and email-link initiation use PKCE and persist a ten-minute, single-use intent with its initiating session lineage, attempt UUID, origin and verifier. Automatic SDK URL installation is disabled. Root auth initialization exchanges a callback only through the owning intent and checks ownership under the SDK lock before publishing it. Missing, expired, used or obsolete callbacks cannot replace a persisted account. Old implicit links are rejected; request a fresh sign-in link from this build. The callback route is `/auth/callback?attempt=<UUID>`; calendar OAuth remains a separate backend-owned route.

The project owner must configure Supabase **Authentication → URL Configuration → Redirect URLs** to admit that query parameter. Do not assume an existing exact `/auth/callback` entry accepts it. For each approved origin, use an exact host and path with an escaped literal query separator and a wildcard only for the attempt value:

```text
https://<deployed-web-host>/auth/callback\?attempt=*
http://localhost:5173/auth/callback\?attempt=*
http://127.0.0.1:5173/auth/callback\?attempt=*
```

Replace the production placeholder with the actual deployed host; add only the development origins/ports used by the approved test environment. These are patterns for the Supabase allowlist, not literal redirect URLs passed by the app: the app sends a normal `?attempt=<UUID>` URL. The escaped `\?` and non-separator `*` follow Supabase's documented glob rules; see [Redirect URLs](https://supabase.com/docs/guides/auth/redirect-urls). Keep the production hostname and `/auth/callback` path exact. Confirm the deployed Auth service accepts the full emitted redirect and preserves its attempt query before claiming provider validation. Email templates must preserve the SDK's `emailRedirectTo`/confirmation URL rather than hard-code a site URL that discards the attempt.

Google/Apple's provider redirect still targets the Supabase project's `/auth/v1/callback`; the new attempt query belongs to the subsequent app redirect. No hosted allowlist, provider configuration or email template was changed or verified by local tests. An approved test account/environment must exercise real Google, Apple and email links, including cancellation, cold reload, logout/relogin and account replacement. [PKCE exchange API](https://supabase.com/docs/reference/javascript/auth-exchangecodeforsession).
