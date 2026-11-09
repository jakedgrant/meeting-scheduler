# Profile read access (F01 follow-up)

Migration: [`20261109045403_profile_read_access.sql`](../supabase/migrations/20261109045403_profile_read_access.sql), created with Supabase CLI 2.109.1 using `supabase migration new profile_read_access`.

Migration 00001 created `public.profiles` with the policy `Users can view all profiles` (`SELECT`, role `public`, `USING (true)`), and no later migration narrowed it. Anyone holding the publishable key could list every profile, email included, without signing in; `GET /rest/v1/profiles?select=*` returned every row. Signed-in users could read every profile too. The [architecture review](architecture-review-2026-10-21.md) named this policy under F01 and proposed restricting profile reads, but framed the exposure around the Google tokens these rows used to hold. F01's remediation dropped the tokens (`20261022025019`) and left the policy in place, and the review never named the email exposure. This migration makes a profile readable only by its owner and by people who share a poll with it, and makes email owner-only.

## Access contract

A **poll peer** of a user is anyone who belongs to a poll the user also belongs to, where belonging means being the poll's creator or one of its participants. Poll status does not matter.

| Read | Signed out | Signed in, own row | Signed in, poll peer's row | Signed in, anyone else's row |
| --- | --- | --- | --- | --- |
| `id`, `display_name`, `avatar_url` through the Data API | Denied (`42501`) | Yes | Yes | No row |
| `email`, `timezone`, `created_at`, `updated_at` through the Data API | Denied | Denied (`42501`) | Denied | Denied |
| The full row through `rpc/get_my_profile` | Denied | Yes | Never | Never |

For `anon` and `authenticated` callers, a Data API select that names any column outside `id`, `display_name` and `avatar_url` fails with `42501` on every row, the caller's own row included. That includes `select('*')`, and an update that returns its row without a column list, because both expand to every column. `service_role` keeps its table privileges and bypasses RLS.

Participant names also come from the definer builders, which ignore the row policy and column grants. `get_poll_detail` returns them to the poll's owner and members (signed-out callers are denied), and `get_poll_detail_as_guest` returns them to any caller, signed in or not, that presents a valid guest capability. Neither payload includes email.

## What changed

**Policy.** `Users can view all profiles` is dropped. `Profiles are visible to their owner and poll peers` (`SELECT`, `authenticated` only) allows `id = auth.uid()` or `id IN (SELECT poll_private.poll_peer_ids())`. The helper is a definer with an empty `search_path` that returns the caller's poll peers, the caller included, and nothing when signed out. It reads `polls` and `poll_participants` directly, so it does not recurse through their RLS, and it answers only for `auth.uid()`. Postgres evaluates the `IN` subquery once per statement (a hashed subplan in the PGlite plan), so an unfiltered `GET /rest/v1/profiles` costs one peer lookup, not one per profile row. `anon` has no read policy. The owner-row update policy from 00001 is unchanged.

**Grants.** Row policies cannot hide columns, so grants do. `anon` loses every privilege on `profiles`; its writes were already denied by RLS. `authenticated` loses table-level `SELECT` and gets `SELECT (id, display_name, avatar_url)`. `service_role` keeps its table privileges. `authenticated` keeps `UPDATE`, which the owner-row policy still limits to the caller's row.

Calendar tokens (F01) and guest emails (F03) were moved out of their public tables instead. Email stays on `profiles` because it is the owner's own data, not a credential or a third party's contact, and because all three clients decode it as a required `Profile` field; `get_my_profile` keeps that row shape, so the models and caches are unchanged. The cost is that the protection is only as good as the grants: a later table-level `GRANT SELECT ON public.profiles` to `anon` or `authenticated` exposes email again. The catalog test fails on such a grant in the migrations, but not on one made in the dashboard.

**Owner read.** `public.get_my_profile()` returns the caller's own `profiles` row, email included, as a one-row set (empty when signed in without a profile). Following the F02 pattern, it is an invoker wrapper over the definer `poll_private.get_my_profile()`. Both revoke `PUBLIC` execution and grant `authenticated` and `service_role` only, and both pin an empty `search_path`. It returns every column of the row, including columns added later, so secrets still belong in `private`.

**Functions that already read profiles.** The poll detail builders (`poll_private.bounded_poll_detail`, `poll_private.get_poll_detail`), the creation lock (`poll_private.lock_poll_creator`) and the signup trigger (`handle_new_user`) are definers owned by the table owner, so column grants and RLS do not apply to them. The billing worker's `billing_admin` runs as `service_role`. No view reads `profiles`, and `profiles` is not in the Realtime publication. None of these change.

## Client compatibility

Every client read of another user's profile already used only `display_name`. The changes are to each client's own-profile load and save.

| Client path | After this change |
| --- | --- |
| Own profile load: web `loadProfile`, iOS `AuthService` live `loadProfile`, Android `SupabaseAuthGateway.loadProfile` | Now `rpc/get_my_profile`, which returns the same row, so the `Profile` models are unchanged. Each client rejects a returned row whose `id` is not the account it asked for, as the old `id` filter did. Before, each selected `*` from `profiles`, which now fails. |
| Own profile save: web `updateProfile`, iOS `updateProfile`, Android `updateProfile` | Now an update that returns no row, followed by `rpc/get_my_profile`. Before, web called `.select()` and iOS used supabase-swift's default `return=representation`; both would now fail. Android's supabase-kt update already returned no row, so `decodeSingle()` had nothing to decode against a real server; the read-back fixes that as well. If the update commits and the read-back fails, the save reports an error, as a lost response to the old single request did; saving again is safe. |
| Member and owner participant lists with `profiles(display_name)`: iOS and Android `loadParticipants` | Unchanged. A visible participant row means the caller and that participant share the poll, so the embedded profile passes the policy, and the embed needs only `id` and `display_name`. |
| Poll detail: web, iOS and Android `get_poll_detail` | Unchanged. The definer builder adds `profiles: { display_name }` to each participant. |
| Signed-out guest poll view: web `get_poll_detail_as_guest` | Unchanged. No guest path reads `profiles` directly or embeds it; names come from the same definer builder. |
| Settings screens | Read `display_name`, `avatar_url` and `timezone` from the loaded profile, as before. Account email on iOS and Android comes from the session user, not the profile. |

A web build released before this migration still selects `*`, so against the new schema its settings form loads blank and a profile save fails with `42501` (the update is rolled back). Nothing else in that build reads profiles.

**Keeping clients within the grants.** No compiler catches a `select('*')` on `profiles`: supabase-js types it as the full row, and the client suites mock the transport. `tests/profile-access-guard.test.mjs` checks the web, iOS and Android sources instead. Every `.from("profiles")` chain may select only readable columns as a string literal, every Swift profile update must pass `returning: .minimal`, and every `profiles(...)` embed must name only readable columns. It fails on all five reads this change replaced. It reads builder chains line by line, so a query built across separate statements, a table name held in a variable, or a hinted embed such as `profiles!fk(...)` can get past it.

## Verification

```bash
npm ci --ignore-scripts --no-audit --no-fund
npm run test:profiles:db
npm run test:database
npm run test:web
```

`tests/profile-access.test.mjs` replays the full migration history in PGlite in process, with Supabase's default grants at creation time, and queries as the actual `anon` and `authenticated` roles. It covers:

- the catalog: one read policy for `authenticated`, no `anon` privileges, exactly three readable columns, and the two definer helpers and the `get_my_profile` wrapper, each with a pinned `search_path` and not executable by `anon`
- signed-out reads, including the `select=*` probe, a count, `get_my_profile` and an update, all denied
- the owner's full row through `get_my_profile`, and `select *`, `email` and `timezone` denied on the owner's own row
- peers across a creator, two participants and a poll the participant created; separate polls; and a user in no poll, who sees only their own row
- peer visibility ending when a participant leaves or the shared poll is deleted
- the `poll_participants?select=*,profiles(display_name)` embed for the owner and members, and its empty result for a non-member
- participant names from `get_poll_detail` and `get_poll_detail_as_guest`, with no email in the payload
- an owner update without a returned row, the read-back, `RETURNING *` denied, and a peer's row not updatable

`npm run test:database` also runs the source guard. `tests/web-session-lifecycle.test.mjs` now answers the profile load at `rpc/get_my_profile` (the real pinned supabase-js transport handles it in its transport tests), and its save tests read the row back. iOS `SessionTransportTests` and Android `ReviewedIsolationTest` reply to the update with no body and to `get_my_profile` with the row.

## Previously exposed emails

Every account's email was readable by any holder of the publishable key while 00001's policy was live. Whether that requires notifying anyone is a project-owner decision. `SELECT count(*) FROM public.profiles` counts the current accounts; accounts deleted since then were also exposed and are not included, because deleting an account deletes its profile.

## Hosted rollout

1. **Before applying:** list live policies with `SELECT policyname, cmd, roles, qual FROM pg_policies WHERE schemaname = 'public' AND tablename = 'profiles'`. The migration drops only `Users can view all profiles`. Remove any other permissive `SELECT` policy as part of the same change; otherwise it still combines with OR.
2. Apply the migration when no long transaction touches `profiles`. Swapping the policy takes an `ACCESS EXCLUSIVE` lock on `profiles` and holds it until the migration commits. While the migration waits for that lock, and while it holds it, every query that reads `profiles` queues behind it, including poll detail reads, participant embeds and signups. It rewrites no rows.
3. Deploy the web build that calls `get_my_profile` right after. Applying first is the safer order: an old build against the new schema fails its profile save atomically, while a new build against the old schema would save and then fail to read the row back.
4. Release native builds from this change or later. Earlier native builds cannot load or save their own profile against the new schema; iOS falls back to its cached profile.
5. Check live grants, including custom roles that inherit from `anon` or `authenticated`: `has_any_column_privilege('anon', 'public.profiles', 'SELECT')` is false, `has_table_privilege('authenticated', 'public.profiles', 'SELECT')` is false, and only `id`, `display_name` and `avatar_url` pass `has_column_privilege('authenticated', 'public.profiles', <column>, 'SELECT')`.
6. PostgREST checks with the publishable key:
   - signed out, `GET /rest/v1/profiles?select=*` returns `401` with code `42501` (`permission denied for table profiles`), not rows;
   - signed in, `GET /rest/v1/profiles?select=id,display_name,avatar_url` returns the caller's row and their poll peers' rows only, and `select=*` or `select=email` returns `403` with code `42501`;
   - signed in, `POST /rest/v1/rpc/get_my_profile` returns the caller's own row with email; signed out it returns `401`.
7. Open a poll as a member and as a signed-out guest, and confirm participant names still show; open Settings on each client and save a change.
8. Decide whether the earlier exposure needs disclosure; see [previously exposed emails](#previously-exposed-emails).

Rollback: recreate the 00001 policy and `GRANT SELECT ON public.profiles TO anon, authenticated`. This makes every profile, email included, readable with the publishable key again, so use it only to restore a broken client path, and reapply the restriction as soon as that path is fixed. Leave `get_my_profile` in place, because the updated clients call it.

No hosted migration, live grant inspection, PostgREST request or Supabase advisor run is established by the offline suites.
