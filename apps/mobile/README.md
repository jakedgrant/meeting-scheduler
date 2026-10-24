# iOS authentication redirects

Email links and browser Google sign-in use Supabase PKCE with a persisted, single-use attempt UUID. The emitted redirect is:

```text
meetingscheduler://auth/callback?attempt=<UUID>
```

The app accepts only that auth scheme, host and path, with exactly one matching attempt and one nonempty `code` (or a provider `error`). It checks the originating account and JWT session identity before the SDK exchanges the code. A missing, malformed, duplicate or obsolete attempt cannot consume a newer intent or rotate its verifier. Request a fresh link from this build for older links without an attempt. Calendar OAuth remains on its separate calendar route; native Apple ID-token sign-in does not use this redirect.

The project owner must configure Supabase **Authentication → URL Configuration → Redirect URLs** to accept the attempt query. Use this allowlist pattern, with one literal backslash before `?`:

```text
meetingscheduler://auth/callback\?attempt=*
```

This follows the [documented Supabase glob syntax](https://supabase.com/docs/guides/auth/redirect-urls). The app sends a normal query separator without the backslash. Keep the scheme, host and path exact. An existing exact entry without the query must not be assumed to accept the new URL. Email templates must preserve the SDK-provided confirmation URL/redirect query. Google's upstream provider redirect remains the project's `https://<project-ref>.supabase.co/auth/v1/callback`; the native app URL is the subsequent Supabase redirect.

Before beta release, an owner with an approved test account/environment must verify the allowlist matches the complete emitted URL and preserves `attempt` through Google and email links on cold and warm launches. Verify cancellation, expired codes, duplicate links, old links after another account starts sign-in, and the genuine current link afterward. Deterministic tests exercise the production service and pinned Supabase Swift SDK with injected browser results and URLProtocol transport; they do not verify hosted allowlists, provider configuration, OS browser delivery or real sign-in. This change does not modify hosted settings.
