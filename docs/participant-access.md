# Participant access and guest capabilities (F03)

Migration: [`20261022212301_participant_access.sql`](../supabase/migrations/20261022212301_participant_access.sql), created with Supabase CLI 2.109.1 using `supabase migration new participant_access`.

Migration 00010 made every `poll_participants` row readable (`USING (true)`) and let any caller update any row whose `user_id` was null, including its identity columns. Each row also carried a guest email and an `access_token` that looked like a guest credential. This migration removes those policies, makes participant lists member data, moves secrets out of the public table, protects identity columns, and adds a guest capability that is never published.

It builds on the [F02 RPC contract](rpc-authorization.md) and does not change any F02 helper, signature, or grant. Membership binding, duplicate memberships, and an idempotent member join are F04. Response-write invariants, including closed-poll rules for members, are F06.

## Access contract

**Owner decision (October 22):** participant lists are visible only to the poll owner and current members, in every poll state, including active polls. An active share code or poll ID gives the F02 poll preview, not the participant list. A guest reads through its capability.

An **open poll** has status `active` and a `closes_at` that is unset or in the future. Joining and guest edits require an open poll.

| Operation | Signed out | Signed-in non-member | Poll owner | Current member | Holder of a valid guest capability |
| --- | --- | --- | --- | --- | --- |
| Read `poll_participants` rows, any poll state | None | Own rows only (none before joining) | All rows of the poll | All rows of the poll | Through `get_guest_poll_detail` |
| Read guest email or capability | Never | Never | Never | Never | Never; the capability is shown once, at join |
| Update own `comment` through the Data API | Denied | Own rows only | Own rows only | Own row | Use `update_guest_participant` |
| Update `id`, `poll_id`, `user_id`, `anonymous_name`, `anonymous_email`, `access_token`, `created_at` through the Data API | Denied | Denied | Denied | Denied | Denied |
| Update a guest row through the Data API | Denied | Denied | Denied | Denied | Denied |
| Guest join (`join_poll_as_guest`) | Open polls | Rejected; join as a member | Rejected | Rejected | Not applicable |
| Guest name/comment edit (`update_guest_participant`) | With capability, open poll | With capability, open poll | With capability | With capability | Own row, open poll |
| Delete a participant row | Denied | Denied | Denied | Denied | Denied |

Readable rows have the existing row shape, because the public row no longer contains secrets: `anonymous_email` is always `NULL` and `access_token` always equals `id`. Existing `select('*')` reads and nested embeds keep working for owners and members. For everyone else they return an empty list, not an error.

`availability_responses` read access is unchanged by F03: active-poll response rows (participant UUIDs and statuses, without names) remain readable to non-members until the F06 response-policy work restricts them.

## What changed

**Policies.** The `USING (true)` read policy, the 00007 read policy, and both update policies (00001's owner-row policy and 00010's null-user policy) are dropped. Two policies replace them:

- `Participants are visible to the poll owner and members` (`SELECT`, `authenticated` only) allows `user_id = auth.uid()` or `poll_private.can_view_participants(poll_id)`. The elevated helper returns true only when the current user owns the poll or belongs to it. It reuses F02's `poll_private.is_poll_participant`, so it never accepts a caller-supplied identity and does not recurse through RLS. The own-row condition keeps `INSERT ... RETURNING` working for a member's first join, because the helper reads the statement snapshot, which does not include the row being inserted. `anon` has no read policy.
- `Members can update their own participant record` (`UPDATE`, `authenticated`) requires `user_id = auth.uid()` before and after the update.

The existing `Anyone can join active polls` insert policy is unchanged; F04 replaces it.

**Column privileges.** `UPDATE` on `poll_participants` is revoked from `anon` and `authenticated`. `authenticated` gets `UPDATE (comment)` only. `SELECT` and `INSERT` are untouched; RLS decides which rows are visible.

**Identity trigger.** `participants_10_protect_identity` (invoker, empty search path) rejects any change to `id`. For direct Data API writes (`current_user` is `anon` or `authenticated`), it also rejects changes to `poll_id`, `user_id`, `anonymous_name`, `anonymous_email`, `access_token`, and `created_at` with `42501` / `Participant identity fields cannot be changed`. It sets `created_at`/`updated_at` on API inserts and forces `access_token := id` on every write. The trigger is the backstop if broad table grants are reapplied, which older projects and the shared test fixtures do.

**Private contact storage.** `participants_20_private_contact` (definer, empty search path) moves any supplied `anonymous_email` into `private.participant_guest_credentials.contact_email` and stores `NULL` in the public row. This happens before the row is written, so the email never reaches Realtime either. Two check constraints make the result declarative: `participant_access_token_not_secret CHECK (access_token = id)` and `participant_email_private CHECK (anonymous_email IS NULL)`. `access_token` is now `NOT NULL` with no default.

**Private capability storage.** `private.participant_guest_credentials` holds, per guest: `token_hash` (SHA-256, 32 bytes, unique), `token_issued_at`, and `contact_email`. RLS is enabled with no policies, and no API role, including `service_role`, has privileges on the table. `anon` and `authenticated` still have no `private` schema usage. The participant foreign key is `ON DELETE CASCADE` and `DEFERRABLE INITIALLY DEFERRED`, so the contact trigger can write before the participant row exists in the same statement.

## Guest capability commands

All five are exposed as `public` invoker wrappers over `poll_private` definers, following the F02 pattern. Every function revokes `PUBLIC` execution, grants `anon`, `authenticated`, and `service_role`, and pins an empty `search_path`. The capability is 64 lowercase hex characters (two v4 UUIDs, 244 bits from PostgreSQL's strong random source). Only its SHA-256 is stored. Any malformed, unknown, swapped, rotated, or legacy value produces the same `42501` / `Guest access denied`.

| RPC | Request | Success response | Errors |
| --- | --- | --- | --- |
| `join_poll_as_guest` | `poll_uuid uuid`, `display_name text`, `contact_email text` (optional) | `{ "participant": <poll_participants row>, "guest_token": "<64 hex>" }` | `42501` `Signed-in callers must join as members`; `42501` `Poll is not accepting participants` (missing, non-active, or past `closes_at`; indistinguishable); `22023` `Guest display name must be 1 to 100 characters` (after trimming); `22023` `Guest contact email is invalid` (over 320 characters or not `local@domain`) |
| `get_guest_participant` | `participant_uuid uuid`, `guest_token text` | `{ "participant": <row>, "poll": { "id", "status", "closes_at" } }`, in any poll state | `42501` `Guest access denied` |
| `get_guest_poll_detail` | `participant_uuid uuid`, `guest_token text` | `{ "participant_id", "poll": <polls row>, "time_options": [<poll_time_options row>], "participants": [<poll_participants row + "profiles": { "display_name" } \| null>], "responses": [<availability_responses row>] }`, in any poll state | `42501` `Guest access denied` |
| `update_guest_participant` | `participant_uuid uuid`, `guest_token text`, `display_name text`, `comment text` (optional; `NULL` clears) | Updated `poll_participants` row | `42501` `Guest access denied`; `42501` `Poll is not accepting changes`; `22023` name length as above; `22023` `Comment must be 500 characters or fewer` |
| `rotate_guest_token` | `participant_uuid uuid`, `guest_token text` | New capability (text). The presented one stops working immediately. | `42501` `Guest access denied` |

`get_guest_poll_detail` gives a verified guest the same view a member gets from the tables: the poll row, time options ordered by start time, the poll's participant rows in the `select('*, profiles(display_name)')` shape, and responses whose participant and time option both belong to the poll. It contains no emails or capabilities.

`update_guest_participant` replaces both editable fields, so clients send the current display name with the new comment. It cannot change any other column. The returned `participant.anonymous_email` is always `NULL`; a supplied contact email is stored privately and has no client read path yet. Join and edit take a `FOR SHARE` lock on the poll row, so they cannot interleave with a concurrent close.

`poll_private.verified_guest_participant(participant_uuid, guest_token)` returns the verified guest row ID or `NULL`. It is not executable by API roles and is the verifier later elevated commands should reuse: F04 for claiming a guest record and F06/F10 for guest availability saves. A row with a non-null `user_id` never verifies as a guest. No API exists to claim a guest row; that belongs to F04.

## Previously exposed tokens and emails

Every pre-F03 `access_token` was globally readable, so all of them are treated as disclosed. Nothing in the database, Edge Functions, or clients ever verified them, so they authorized nothing. The migration overwrites them with the row's `id`. They are not converted into capabilities: existing guests have `token_hash IS NULL` and cannot be edited by anyone through the API. This matches the current web behavior, where a guest could not respond or edit after joining. A guest who needs to participate again can join with the new command. The data rewrite does not change `updated_at`.

Existing guest emails move to private storage. They were readable by any caller while 00010 was deployed. Whether that requires notifying anyone is a project-owner decision; the count is `SELECT count(*) FROM private.participant_guest_credentials WHERE contact_email IS NOT NULL`.

## Client compatibility

Signed-in flows keep working without client changes. **The web signed-out guest join breaks and needs the adapter below**, because signed-out callers can no longer read the row their insert returns.

| Client path | After F03 |
| --- | --- |
| Owner/member participant lists: web `loadPoll`/`loadPollParticipants`, iOS `loadParticipants` and nested detail embed, Android `loadParticipants`, web/iOS list counts | Unchanged shape. `access_token` is a non-null UUID equal to `id`; `anonymous_email` is `null`. iOS (`UUID`) and Android (`String`) still decode it. |
| Signed-in poll page/detail **before joining** (web, iOS, Android) | Poll, time options, and the F02 preview still load. The participant list is empty, so names and the per-participant breakdown disappear until the user joins. Web response loading is keyed by participant IDs, so it also shows no responses. The join prompt still appears (`!myParticipant && active`). |
| Signed-in direct join `insert({ poll_id, user_id }).select().single()` (web, iOS, Android) | Works: the returned row passes the own-row read condition. After joining, the caller is a member and sees the full list. |
| Member comment update `update({ comment }).eq('id', …)` (web, iOS, Android) | Works for the caller's own row. Another participant's row matches zero rows. |
| **Web signed-out join** `insert({ poll_id, anonymous_name, anonymous_email }).select().single()` | **Fails with `42501`** (PostgREST `new row violates row-level security policy`). Before F03 the guest could join but then saw no own row, could not respond, and was shown the join prompt again. An insert without `.select()` still succeeds but gives the guest nothing usable. |
| Signed-out poll page | Poll and time options still load for active polls. The participant list is empty, so web fetches no responses (it keys them by participant ID). |
| Realtime participant subscriptions | Same policy evaluation as reads: owners and members receive changes; payloads no longer contain email or a credential. Signed-out and pre-join subscribers receive no participant events. |

iOS and Android do not support signed-out participation (`PollDetailView` passes no guest name; Android omits a name and would violate the identity check), so their only change is the empty pre-join list.

**Web guest adapter (required; ships with F03).** Implemented in [`guest-capability.ts`](../apps/web/src/lib/guest-capability.ts), [`stores/polls.ts`](../apps/web/src/lib/stores/polls.ts), and the [poll page](../apps/web/src/routes/polls/[id]/+page.svelte):

1. **Join.** A signed-out `joinPoll` calls `rpc('join_poll_as_guest', { poll_uuid, display_name, contact_email })`. It stores `{ participantId, token }` in `localStorage` under `meeting-scheduler:guest:<poll id>`, one entry per poll. Only on `PGRST202` (the web deployed before the migration) does it fall back to the legacy direct insert. Signed-in joins are unchanged.
2. **Load.** When signed out with a stored capability, `loadPoll` reads `rpc('get_guest_poll_detail', …)` and fills the poll, time option, participant, and response stores. The page identifies the guest's own row by the stored participant ID, including the "You" badge. Without a capability, or on `PGRST202`, the normal table reads run.
3. **Edit.** The guest's comment is saved with `update_guest_participant`, sending the current display name. Availability buttons are hidden for guests, with a note, until the F06/F10 guest save command exists. The store refuses guest availability writes rather than letting them fail on RLS.
4. **Lost or invalid capability.** On `Guest access denied`, or a detail payload for another poll, the stored entry is removed. The page shows "Your guest access to this poll is no longer valid on this device. Join again to take part." and the join prompt returns while the poll is active. Malformed stored entries are discarded without a request. Unavailable storage degrades to a capability that lasts only for the page view.
5. **Secrecy.** The token is never rendered. Errors are logged as `code`/`message` only, and the token goes nowhere except the guest RPCs.
6. **Realtime.** Guests do not subscribe; they refresh on load and after their own saves.

`npm run test:web:guest` covers storage scoping, tamper handling, storage failures, and error classification. `npm run check` and `npm run build` in `apps/web` cover the store and page.

## Verification

```bash
npm ci --ignore-scripts --no-audit --no-fund
npm run test:participants:db
npm run test:rpc:db
npm run test:calendar:db
npm run test:billing:db
```

`tests/participant-access.test.mjs` replays the full migration history in PGlite 0.5.11 (PostgreSQL 18.6) in process, seeding pre-F03 rows, including a published token and email, immediately before this migration. It models Supabase's default table and function grants at creation time, then queries as actual `anon`, `authenticated`, and `service_role` roles. Its 14 scenarios cover:

- the data rewrite and preserved timestamps, and the policy/grant/helper catalog
- signed-out and non-member reads of every poll state, including active polls and nested counts
- owner/member reads in every state, and capability and email leakage across rows and summaries
- join validation, valid and invalid capabilities, the guest detail read, rotation, and closed-poll edits
- guest takeover and identity-column changes, with and without reapplied broad grants
- the signed-in insert-returning path, the broken signed-out insert-returning path, cascade cleanup, and a hostile search path

It opens no listening port.

Two assertions in `tests/rpc-authorization.test.mjs` were scoped, without changing their intent. The `poll_private` inventory now counts F02's four named helpers instead of every function in the schema. The summary leak check uses the fixture's literal guest email, and checks `access_token` only when it differs from `id`, so an F02-only replay still verifies that a real token is absent.

## Hosted rollout

1. **Integration owner:** replay the combined history (F02, F08, F03 in version order) and run every database and Edge suite.
2. **Project owner, before applying:** list live policies with `SELECT policyname, cmd, roles, qual, with_check FROM pg_policies WHERE tablename = 'poll_participants'`. The migration drops only the policies named in checked-in migrations. Remove any dashboard-created permissive policy as part of the same change; otherwise it still combines with OR.
3. Deploy the web release containing the guest adapter **first**. Until the migration lands, its `PGRST202` fallback keeps the legacy signed-out join working, so there is no broken window.
4. Apply the migration through the normal deployment process. It rewrites every participant row once and adds two check constraints, so it briefly holds an exclusive lock on `poll_participants`. Guests who joined through the fallback before this point have no capability, the same as other legacy guests.
5. Confirm `private` and `poll_private` remain absent from the exposed API schemas. Check live grants, including custom roles that inherit from `anon` or `authenticated`: `has_table_privilege(role, 'public.poll_participants', 'UPDATE')` should be false and `has_column_privilege(role, 'public.poll_participants', 'comment', 'UPDATE')` true only for `authenticated`.
6. PostgREST smoke checks with a signed-out key, a member account, and a non-member account. Signed-out and non-member reads of any poll's participants return `[]`. A member's read returns rows with `access_token = id` and no email. A member `PATCH` of `comment` succeeds and of `user_id` or `poll_id` fails. `rpc/join_poll_as_guest` returns a capability that works with `rpc/get_guest_poll_detail`.
7. Check that web Realtime participant updates still arrive for members of an active poll.
8. Decide on disclosure for previously exposed guest emails (count query above). Rotating the old `access_token` values needs no further action; the migration already invalidated them.

No hosted migration, live grant inspection, PostgREST request, Realtime check, or Supabase advisor run is established by the offline suites.
