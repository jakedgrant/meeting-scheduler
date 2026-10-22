# Participant access and guest capabilities (F03)

Migration: [`20261022212301_participant_access.sql`](../supabase/migrations/20261022212301_participant_access.sql), created with Supabase CLI 2.109.1 using `supabase migration new participant_access`.

Migration 00010 made every `poll_participants` row readable (`USING (true)`) and let any caller update any row whose `user_id` was null, including its identity columns. Each row also carried a guest email and an `access_token` that looked like a guest credential. This migration removes those policies, moves secrets out of the public table, protects identity columns, and adds a guest capability that is never published.

It builds on the [F02 RPC contract](rpc-authorization.md) and does not change any F02 helper, signature, or grant. Membership binding, duplicate memberships, and an idempotent member join are F04. Response-write invariants, including closed-poll rules for members, are F06.

## Access contract

"Invitation" means the poll's status is `active`, which matches F02's share-code preview. Joining and guest edits additionally require `closes_at` to be unset or in the future.

| Operation | Signed out | Unrelated signed-in user | Poll owner | Current member | Holder of a valid guest capability |
| --- | --- | --- | --- | --- | --- |
| Read participants of an active poll | Safe columns | Safe columns | Safe columns | Safe columns | Safe columns |
| Read participants of a draft, closed, or archived poll | None | None | Safe columns | Safe columns | Own row only, through `get_guest_participant` |
| Read guest email or capability | Never | Never | Never | Never | Never; the capability is shown once, at join |
| Update own `comment` through the Data API | Denied | Own rows only | Own rows only | Own row | Use `update_guest_participant` |
| Update `id`, `poll_id`, `user_id`, `anonymous_name`, `anonymous_email`, `access_token`, `created_at` through the Data API | Denied | Denied | Denied | Denied | Denied |
| Update a guest row through the Data API | Denied | Denied | Denied | Denied | Denied |
| Guest join (`join_poll_as_guest`) | Active, open polls | Rejected; join as a member | Rejected | Rejected | Not applicable |
| Guest name/comment edit (`update_guest_participant`) | With capability, open poll | With capability, open poll | With capability | With capability | Own row, open poll |
| Delete a participant row | Denied | Denied | Denied | Denied | Denied |

"Safe columns" is the whole existing row shape, because the public row no longer contains secrets: `anonymous_email` is always `NULL` and `access_token` always equals `id`. Existing `select('*')` reads and nested embeds keep working on all clients.

## What changed

**Policies.** The `USING (true)` read policy and both update policies (00001's owner-row policy and 00010's null-user policy) are dropped. Two policies replace them:

- `Participants are visible through invitation or membership` (`SELECT`, `anon`/`authenticated`) calls `poll_private.can_view_participants(poll_id)`. That elevated helper returns true for an active poll, or when the current user owns or belongs to the poll. It reuses F02's `poll_private.is_poll_participant`, so it never accepts a caller-supplied identity and does not recurse through RLS.
- `Members can update their own participant record` (`UPDATE`, `authenticated`) requires `user_id = auth.uid()` before and after the update.

The existing `Anyone can join active polls` insert policy is unchanged; F04 replaces it.

**Column privileges.** `UPDATE` on `poll_participants` is revoked from `anon` and `authenticated`. `authenticated` gets `UPDATE (comment)` only. `SELECT` and `INSERT` are untouched.

**Identity trigger.** `participants_10_protect_identity` (invoker, empty search path) rejects any change to `id`. For direct Data API writes (`current_user` is `anon` or `authenticated`), it also rejects changes to `poll_id`, `user_id`, `anonymous_name`, `anonymous_email`, `access_token`, and `created_at` with `42501` / `Participant identity fields cannot be changed`. It sets `created_at`/`updated_at` on API inserts and forces `access_token := id` on every write. The trigger is the backstop if broad table grants are reapplied, which older projects and the shared test fixtures do.

**Private contact storage.** `participants_20_private_contact` (definer, empty search path) moves any supplied `anonymous_email` into `private.participant_guest_credentials.contact_email` and stores `NULL` in the public row. This happens before the row is written, so the email never reaches Realtime either. Two check constraints make the result declarative: `participant_access_token_not_secret CHECK (access_token = id)` and `participant_email_private CHECK (anonymous_email IS NULL)`. `access_token` is now `NOT NULL` with no default.

**Private capability storage.** `private.participant_guest_credentials` holds, per guest: `token_hash` (SHA-256, 32 bytes, unique), `token_issued_at`, and `contact_email`. RLS is enabled with no policies, and no API role, including `service_role`, has privileges on the table. `anon` and `authenticated` still have no `private` schema usage. The participant foreign key is `ON DELETE CASCADE` and `DEFERRABLE INITIALLY DEFERRED`, so the contact trigger can write before the participant row exists in the same statement.

## Guest capability commands

All four are exposed as `public` invoker wrappers over `poll_private` definers, following the F02 pattern. Every function revokes `PUBLIC` execution, grants `anon`, `authenticated`, and `service_role`, and pins an empty `search_path`. The capability is 64 lowercase hex characters (two v4 UUIDs, 244 bits from PostgreSQL's strong random source). Only its SHA-256 is stored. Any malformed, unknown, swapped, rotated, or legacy value produces the same `42501` / `Guest access denied`.

| RPC | Request | Success response | Errors |
| --- | --- | --- | --- |
| `join_poll_as_guest` | `poll_uuid uuid`, `display_name text`, `contact_email text` (optional) | `{ "participant": <poll_participants row>, "guest_token": "<64 hex>" }` | `42501` `Signed-in callers must join as members`; `42501` `Poll is not accepting participants` (missing, non-active, or past `closes_at`; indistinguishable); `22023` `Guest display name must be 1 to 100 characters` (after trimming); `22023` `Guest contact email is invalid` (over 320 characters or not `local@domain`) |
| `get_guest_participant` | `participant_uuid uuid`, `guest_token text` | `{ "participant": <row>, "poll": { "id", "status", "closes_at" } }`, in any poll state | `42501` `Guest access denied` |
| `update_guest_participant` | `participant_uuid uuid`, `guest_token text`, `display_name text`, `comment text` (optional; `NULL` clears) | Updated `poll_participants` row | `42501` `Guest access denied`; `42501` `Poll is not accepting changes`; `22023` name length as above; `22023` `Comment must be 500 characters or fewer` |
| `rotate_guest_token` | `participant_uuid uuid`, `guest_token text` | New capability (text). The presented one stops working immediately. | `42501` `Guest access denied` |

`update_guest_participant` replaces both editable fields, so clients send the current display name with the new comment. It cannot change any other column. The returned `participant.anonymous_email` is always `NULL`; a supplied contact email is stored privately and has no client read path yet. Join and edit take a `FOR SHARE` lock on the poll row, so they cannot interleave with a concurrent close.

`poll_private.verified_guest_participant(participant_uuid, guest_token)` returns the verified guest row ID or `NULL`. It is not executable by API roles and is the verifier later elevated commands should reuse: F04 for claiming a guest record and F06/F10 for guest availability saves. A row with a non-null `user_id` never verifies as a guest. No API exists to claim a guest row; that belongs to F04.

## Previously exposed tokens and emails

Every pre-F03 `access_token` was globally readable, so all of them are treated as disclosed. Nothing in the database, Edge Functions, or clients ever verified them, so they authorized nothing. The migration overwrites them with the row's `id`. They are not converted into capabilities: existing guests have `token_hash IS NULL` and cannot be edited by anyone through the API. This matches the current web behavior, where a guest could not respond or edit after joining. A guest who needs to participate again can join with the new command. The data rewrite does not change `updated_at`.

Existing guest emails move to private storage. They were readable by any caller while 00010 was deployed. Whether that requires notifying anyone is a project-owner decision; the count is `SELECT count(*) FROM private.participant_guest_credentials WHERE contact_email IS NOT NULL`.

## Client compatibility

No installed client needs to change for this migration.

| Client path | After F03 |
| --- | --- |
| Web, iOS, Android participant lists (`select('*, profiles(display_name)')`, iOS nested detail embed) | Unchanged shape. `access_token` is a non-null UUID equal to `id`; `anonymous_email` is `null`. iOS (`UUID`) and Android (`String`) still decode it. |
| Web, iOS, Android member comment update (`update({ comment }).eq('id', …)`) | Works for the caller's own row. Another participant's row matches zero rows, as before for non-guest rows. |
| Web signed-out join (`insert({ poll_id, anonymous_name, anonymous_email }).select().single()`) | Works on active polls. Any email is stored privately; the returned row has `anonymous_email: null`. The guest receives no capability. |
| Signed-in joins (web, iOS, Android) | Unchanged in F03. F04 binds `user_id` and adds the idempotent join. |
| Realtime participant subscriptions | Same policy evaluation as reads; payloads no longer contain email or a credential. |

**Web guest adapter (optional, after the migration is deployed).** Replace the signed-out direct insert with `supabase.rpc('join_poll_as_guest', { poll_uuid, display_name })`. Store `{ participant_id, guest_token }` per poll in browser storage and never log or send it elsewhere. Identify the guest's own row by `participant_id` (today the page matches only `user_id`). Save the guest's name/comment with `update_guest_participant`, and recover from `Guest access denied` by clearing the stored capability. Guest availability responses still have no write path: the response policy requires an authenticated owner, as before F03. That command is F06/F10 work and should accept the same capability.

## Verification

```bash
npm ci --ignore-scripts --no-audit --no-fund
npm run test:participants:db
npm run test:rpc:db
npm run test:calendar:db
npm run test:billing:db
```

`tests/participant-access.test.mjs` replays the full migration history in PGlite 0.5.11 (PostgreSQL 18.6) in process, seeding pre-F03 rows, including a published token and email, immediately before this migration. It models Supabase's default table and function grants at creation time, then queries as actual `anon`, `authenticated`, and `service_role` roles. Its 13 scenarios cover the data rewrite and preserved timestamps, the policy/grant/helper catalog, closed-poll enumeration, owner/member reads in every state, capability and email leakage across rows and summaries, join validation, valid and invalid capabilities, rotation, closed-poll edits, guest takeover, identity-column changes with and without reapplied broad grants, legacy web and member paths, cascade cleanup, and a hostile search path. It opens no listening port.

Two assertions in `tests/rpc-authorization.test.mjs` were scoped, without changing their intent. The `poll_private` inventory now counts F02's four named helpers instead of every function in the schema. The summary leak check uses the fixture's literal guest email, and checks `access_token` only when it differs from `id`, so an F02-only replay still verifies that a real token is absent.

## Hosted rollout

1. **Integration owner:** replay the combined history (F02, F08, F03 in version order) and run every database and Edge suite.
2. **Project owner, before applying:** list live policies with `SELECT policyname, cmd, roles, qual, with_check FROM pg_policies WHERE tablename = 'poll_participants'`. The migration drops only the policies named in checked-in migrations. Remove any dashboard-created permissive policy as part of the same change; otherwise it still combines with OR.
3. Apply the migration through the normal deployment process. It rewrites every participant row once and adds two check constraints, so it briefly holds an exclusive lock on `poll_participants`.
4. Confirm `private` and `poll_private` remain absent from the exposed API schemas. Check live grants, including custom roles that inherit from `anon` or `authenticated`: `has_table_privilege(role, 'public.poll_participants', 'UPDATE')` should be false and `has_column_privilege(role, 'public.poll_participants', 'comment', 'UPDATE')` true only for `authenticated`.
5. PostgREST smoke checks with a signed-out key and a test account: closed-poll participants return `[]`; an active poll's participant list returns rows with `access_token = id` and no email; a member `PATCH` of `comment` succeeds and of `user_id` or `poll_id` fails; `rpc/join_poll_as_guest` returns a capability that works with `rpc/get_guest_participant`.
6. Check that web Realtime participant updates still arrive for an active poll.
7. Decide on disclosure for previously exposed guest emails (count query above). Rotating the old `access_token` values needs no further action; the migration already invalidated them.
8. Ship the optional web guest adapter afterwards. Do not ship it before the migration, because the RPCs will not exist.

No hosted migration, live grant inspection, PostgREST request, Realtime check, or Supabase advisor run is established by the offline suites.
