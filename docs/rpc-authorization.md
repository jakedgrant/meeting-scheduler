# Poll RPC authorization (F02)

Migration: [`20261022181851_privileged_rpc_authorization.sql`](../supabase/migrations/20261022181851_privileged_rpc_authorization.sql), created with Supabase CLI 2.109.1 using `supabase migration new privileged_rpc_authorization`.

The legacy self-service functions accepted another user's UUID and ran with the database owner's privileges. The migration keeps their existing names, argument names, defaults, and result types, but binds every self-service read to `auth.uid()`. The summary RPC requires current ownership or membership. Its reads run with the caller's table grants and RLS.

This closes direct RPC authorization gaps in the checked-in schema. Participant read/update policies and direct membership inserts still have the F03/F04 vulnerabilities. **F02 alone does not establish poll isolation:** a caller who forges or claims membership through those unchanged table paths can satisfy a membership-based RPC check.

## Access contract

| Operation | Signed out | Authenticated owner | Authenticated member | Unrelated authenticated user |
| --- | --- | --- | --- | --- |
| Own list, entitlement, pass count, active count, creation eligibility | Execute denied | Own data | Own data | Own data |
| Same self-service RPC with another user's UUID or explicit `NULL` | Execute denied | `42501` | `42501` | `42501` |
| Summary by poll UUID, any state | Execute denied | Allowed | Allowed | `42501`, including active polls |
| Preview by exact active share code | Minimal preview | Minimal preview | Minimal preview | Minimal preview |
| Preview by draft, closed, or archived share code | Empty result | Allowed | Allowed | Empty result |
| Legacy membership helper with another user's UUID | `false` | `false` | `false` | `false` |

Self-service callers should continue omitting `user_uuid`. Installed clients that send their own UUID still work. An explicit `NULL` is rejected rather than treated as a missing argument. Having the `authenticated` database role without a user identity is insufficient. A service-role call to a self-service function also needs a matching user identity; backend billing and calendar operations use their separate service-only contracts.

`get_poll_with_summary` returns the same `42501` / `Poll access denied` error for a missing poll and an inaccessible poll. It includes only responses whose participant and time option both belong to the requested poll. Its existing participant projection contains display names, avatars, response statuses, and notes; it does not add guest emails or access tokens. Cross-poll response **writes** remain F06 work.

`get_poll_by_code(code)` trims whitespace and normalizes case. An active invitation returns the existing nine-column projection: ID, title, description, location, status, creator ID, timestamps, and share code. It returns no participant, response, email, or guest capability data. Knowing an inactive poll's code alone does not authorize its preview or summary.

Anonymous guests can continue opening active invitation previews. Existing guest joins and edits use direct table paths; this migration does not change those policies. No current client calls the summary RPC as a guest. A verified guest read/edit command for closed polls needs the capability ownership and rotation rules from F03. The existing globally readable access tokens are not a suitable new authorization boundary.

## Function and grant inventory

Replaying the pre-F02 history gives `anon` effective `EXECUTE` on 14 legacy functions through PostgreSQL's default `PUBLIC` grant. Older Supabase projects may also have direct role grants. Eleven of these functions return ordinary RPC results; three return `trigger` and cannot be invoked as ordinary RPCs. Nine ordinary functions and the signup trigger run as `SECURITY DEFINER`. Catalog execution grants and usable Data API endpoints are different facts.

The migration revokes `PUBLIC`, `anon`, and `authenticated` grants on each affected function, then grants only its supported callers. Existing service-role execution is retained explicitly for ordinary functions. Trigger functions have no client execution grant; PostgreSQL still invokes their existing triggers.

| Public signature | Runs as after F02 | `anon` execution | `authenticated` execution | Current callers |
| --- | --- | --- | --- | --- |
| `get_user_participated_polls(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | Web, iOS, Android |
| `has_active_subscription(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | `can_create_poll` |
| `get_user_entitlement(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | No current direct client call |
| `count_unredeemed_passes(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | `can_create_poll` |
| `count_active_polls(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | iOS, `can_create_poll` |
| `can_create_poll(uuid DEFAULT auth.uid())` | Invoker, self guard | Denied | Self only | iOS |
| `get_poll_with_summary(uuid)` | Invoker, owner/member guard | Denied | Owner/member | No current client call |
| `get_poll_by_code(text)` | Invoker wrapper | Allowed preview | Allowed preview | Web, iOS, Android |
| `is_poll_participant(uuid,uuid)` | Invoker wrapper | `false` | Current user's membership only | Existing RLS policies |
| `generate_share_code()` | Invoker | Denied | Allowed | Share-code helper |
| `generate_unique_share_code()` | Invoker | Denied | Allowed | Poll insert trigger |
| `handle_new_user()` | Definer trigger | Denied | Denied | Auth signup trigger |
| `set_poll_share_code()` | Invoker trigger | Denied | Denied | Poll insert trigger |
| `update_updated_at()` | Invoker trigger | Denied | Denied | Existing update triggers |
| `calendar_admin(text,uuid,jsonb)` | Existing invoker | Denied | Denied | Calendar backend, service role only; unchanged |

All affected public functions have an empty pinned `search_path`. Relation and application-function references are schema-qualified, including the existing share-code trigger chain. The two code generators retain caller privileges. Client-side poll creation still needs their execution grants because an invoker trigger calls them.

The clients already use compatible call shapes in [web](../apps/web/src/lib/stores/polls.ts), [iOS](../apps/mobile/Sources/Shared/Services/PollService.swift), and [Android](../apps/android/app/src/main/kotlin/com/meetingscheduler/android/services/PollService.kt). No client source change is needed for F02. The independently scheduled F03/F04 adapters will need new guest and join commands.

## Private helper boundary

`poll_private` is absent from `supabase/config.toml`'s exposed API schemas. Client roles have schema `USAGE` only so invoker wrappers and policies can resolve the allowed helpers. They have no schema `CREATE` privilege. The schema contains functions and no tables.

| Private helper | Execution | Purpose and direct-call behavior |
| --- | --- | --- |
| `require_self(uuid)` | Invoker; authenticated/service role | Returns `auth.uid()` only after a non-null, matching UUID check; otherwise raises `42501`. |
| `is_poll_participant(uuid)` | Definer; anon/authenticated/service role | Reads membership without recursive RLS. Its only user identity is `auth.uid()`; signed-out calls return `false`. |
| `can_read_poll(uuid)` | Definer; authenticated/service role | Returns only whether the current caller owns or belongs to this poll. |
| `get_poll_by_code(text)` | Definer; anon/authenticated/service role | Returns only the allowed invitation preview, including when called directly. |

Every helper revokes default `PUBLIC` execution and pins an empty `search_path`. Elevated helpers qualify all relations. Hiding a schema is not the authorization check: tests call every granted helper directly, without the public wrapper. The checks still hold.

The migration does not change global default privileges, calendar schema/table/function grants, billing storage, or table policies. New functions in other work streams must set their own grants. Calendar definitions and ACLs are compared before and after the migration in the regression suite, and the existing calendar database suite is replayed too.

## Billing integration

The subscription read helpers retain their output types and check `is_active` plus `(expires_at IS NULL OR expires_at > now())`. The expiry is an access decision supplied by the backend; callers must not assume it is the store renewal date. These helpers do not grant a paid feature, consume a pass, or enforce a create quota. Those transactional guarantees remain F05/F09.

F08 owns subscription projection freshness, pass validity, and webhook processing. Its later migration can strengthen pass predicates without changing `count_unredeemed_passes(user_uuid UUID DEFAULT auth.uid())`, its integer result, or its authorization contract. It must keep invoker privileges, a pinned search path, self-only identity checks including explicit `NULL`, and the execution grants above. F02's earlier migration deliberately references only the historical `redeemed_at` column so it replays independently.

## Verification and rollout

Run from the repository root:

```bash
npm ci --ignore-scripts --no-audit --no-fund
npm run test:rpc:db
npm run test:calendar:db
```

The RPC suite uses PostgreSQL 18.6 through PGlite 0.5.11 in process. It replays the full migration history, simulates both default `PUBLIC` grants and direct API-role grants, then issues queries as actual `anon`, `authenticated`, and `service_role` roles. It covers all affected legacy signatures/defaults, direct private-helper paths, RLS reads, positive owner/member calls, expiry, unrelated and signed-out denials, search-path spoofing, trigger execution, and calendar service access. It opens no listening port and uses no shared runtime.

The historical-schema fixture includes one unredeemed pass and one redeemed pass. When the later F08 billing columns exist, schema-aware setup supplies a verified positive pass and distinct revoked, expired, redeemed, and unmatched legacy comparison rows. The expected available count remains exactly one. F02 does not require those future columns to replay.

Local validation on October 22, 2026: 17 RPC tests, 12 calendar database tests, and 23 calendar Edge Function tests passed. Web type checking passed with zero errors and seven existing warnings; the production build passed with the existing accessibility, chunk-size, and deployment-adapter notices. `git diff --check` passed. No simulator, emulator, local server, or hosted resource was accessed.

Before a hosted rollout, the integration owner must replay the combined F02/F08 migration order and run both branches' tests. Apply this additive migration through the deployment process, keep `poll_private` out of exposed schemas, and verify live effective grants including any custom role inheritance. Check installed-client list, eligibility, invitation, and owner/member closed-poll reads. No hosted migration, live role/grant inspection, PostgREST request, or Supabase advisor run is established by the offline suite.

The remaining access work must retain these checks while replacing permissive policies:

- F03: remove globally readable participant/capability rows and null-user update access; define safe participant projections, verified guest read/edit commands, and capability rotation or invalidation.
- F04: bind joins to the current authenticated identity or verified guest capability, prevent identity/poll reassignment, reconcile existing duplicates, and enforce uniqueness and idempotency.
- F06: enforce matching poll boundaries and open-state rules on response writes. Summary filtering does not repair stored invalid relationships.
- F19: add bounded, authorized list/detail contracts. Existing JSON list and summary sizes remain unbounded.

The implementation follows [Supabase function security guidance](https://supabase.com/docs/guides/database/functions), [Supabase RLS guidance](https://supabase.com/docs/guides/database/postgres/row-level-security), and [PostgreSQL function privilege/search-path guidance](https://www.postgresql.org/docs/current/sql-createfunction.html#SQL-CREATEFUNCTION-SECURITY). The current [Data API grant change](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically) affects newly created tables; this migration adds none. Existing invoker reads require the deployment's existing table grants.
