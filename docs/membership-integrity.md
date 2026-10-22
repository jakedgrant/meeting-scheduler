# Membership integrity (F04)

Migration: [`20261022213242_membership_integrity.sql`](../supabase/migrations/20261022213242_membership_integrity.sql), created with Supabase CLI 2.109.1 using `supabase migration new membership_integrity`.

Before this change, the join policy checked only that a poll was active. A caller could insert a participant row naming another user's UUID, and nothing prevented the same user from joining a poll twice. Double taps, retries, and multiple devices could split one person's availability across rows and inflate counts.

F04 builds on [F03](participant-access.md): its guest capabilities, private storage, and identity trigger. It must be deployed after F03 and preserves the [F02 RPC contract](rpc-authorization.md).

## Access contract

| Operation | Signed out | Signed-in caller |
| --- | --- | --- |
| `join_poll(poll_uuid)` | Execute denied (`42501`) | Joins as `auth.uid()`; on retry returns the existing membership in any poll state |
| Direct insert with `user_id` set | Denied by RLS | Only `user_id = auth.uid()`, open poll, once (`23505` on a duplicate) |
| Direct insert as a guest (`user_id` null) | Open poll, trimmed name 1 to 100 characters | Denied by RLS |
| `join_poll_as_guest(...)` | Open poll; idempotent with a client capability | Rejected: join as a member |
| `claim_guest_participant(participant_uuid, guest_token)` | Execute denied | Valid capability, unclaimed guest, caller not already a member |
| Change `poll_id` | Denied | Denied, for every role including `service_role` and elevated commands |
| Change `user_id` from one user to another | Denied | Denied, for every role |

An **open poll** has status `active` and a `closes_at` that is unset or in the future. Before F04, direct inserts did not check `closes_at`.

## Duplicate reconciliation

The migration locks `poll_participants` and `availability_responses` against concurrent writes, then reconciles every `(poll_id, user_id)` group with more than one row (`user_id IS NOT NULL`):

1. **Survivor:** the row with the earliest `created_at`, then the lowest `id`.
2. **Audit:** every row in the group, survivor included, is copied to `private.participant_merge_audit` with all of its responses and any private F03 credentials row. The table has RLS enabled and no API role privileges, including `service_role`.
3. **Responses:** for each time option, the response with the latest `updated_at` wins; ties prefer the survivor's own response, then the lowest response `id`. Losing responses are deleted (they remain in the audit). Winning responses move to the survivor and keep their `id`, `status`, `note`, and timestamps.
4. **Comment:** the most recently updated non-null comment in the group, ties preferring the survivor. The survivor's `updated_at` becomes the latest in the group. Timestamp triggers are disabled during the merge so it does not look like a user edit.
5. Duplicate rows are deleted; their private credentials cascade (the audit keeps a copy).
6. `poll_participants_one_membership_per_user` is created: a unique index on `(poll_id, user_id) WHERE user_id IS NOT NULL`.

Guests have no account identity to merge on, so guest rows with the same name stay distinct. `get_user_participated_polls` already used `EXISTS` after F02, so its joined list did not repeat polls; the index now also keeps participant lists and counts correct.

**Pre-deployment inspection** (read-only, for the project owner):

```sql
SELECT poll_id, user_id, count(*) AS rows,
       (SELECT count(*) FROM public.availability_responses ar
        JOIN public.poll_participants p2 ON p2.id = ar.participant_id
        WHERE p2.poll_id = pp.poll_id AND p2.user_id = pp.user_id) AS responses,
       count(*) FILTER (WHERE comment IS NOT NULL) AS comments
FROM public.poll_participants pp
WHERE user_id IS NOT NULL
GROUP BY poll_id, user_id
HAVING count(*) > 1
ORDER BY rows DESC;
```

After deployment, `SELECT merge_role, count(*) FROM private.participant_merge_audit GROUP BY 1` should match those groups.

## Identity protection

F03's `poll_private.protect_participant_identity` trigger is replaced with a stricter version. For every role it rejects changes to `id` or `poll_id`, and a `user_id` change from one non-null user to another (`42501` / `Participant identity fields cannot be changed`). Elevated commands may still set `user_id` from null (guest claim), and account deletion may still clear it through the existing `ON DELETE SET NULL` foreign key. The F03 Data API rules are unchanged.

## Commands

All are `public` invoker wrappers over `poll_private` definers with an empty `search_path`, no `PUBLIC` execution, and the grants shown above. `service_role` can execute each but still needs a user identity where one is required.

| RPC | Request | Success response | Errors |
| --- | --- | --- | --- |
| `join_poll` | `poll_uuid uuid` | `{ "participant": <poll_participants row>, "created": true \| false }` | `42501` `Authentication required`; `42501` `Poll is not accepting participants` (missing, non-active, or past `closes_at`; indistinguishable) |
| `join_poll_as_guest` | `poll_uuid uuid`, `display_name text`, `contact_email text` (optional), `guest_token text` (optional) | `{ "participant": <row>, "guest_token": "<64 hex>", "created": true \| false }` | F03 errors, plus `22023` `Guest token must be 64 lowercase hexadecimal characters`; `42501` `Guest access denied` if the supplied capability already belongs to another poll or a claimed row |
| `claim_guest_participant` | `participant_uuid uuid`, `guest_token text` | `{ "participant": <row with user_id = caller> }` | `42501` `Authentication required`; `42501` `Guest access denied` (any invalid, swapped, or already-claimed capability); `23505` `Already a member of this poll` |

`join_poll` returns an existing membership before checking poll state, so a retry after the poll closes still succeeds. A new membership locks the poll row `FOR SHARE` and inserts with `ON CONFLICT DO NOTHING` on the unique index. If a concurrent request commits first, the command returns that row with `created: false`.

`join_poll_as_guest` keeps F03's named arguments. The F03 three-argument function is dropped and replaced by a four-argument function whose new parameters have defaults, so existing named and positional calls still resolve. When the client supplies `guest_token`, generated with a cryptographically secure source, a retry with the same capability returns the same guest row, including after the poll closes. A concurrent request with the same capability is resolved through the token-hash uniqueness constraint. Without `guest_token`, the server generates one as in F03 and each call creates a new guest.

`claim_guest_participant` converts a guest row into the caller's membership, keeping its name, comment, and responses. It locks the row and re-checks that it is still unclaimed. Afterwards, every guest command rejects that capability: get, update, rotate, and a join retry with it. Its verifier is kept so it cannot mint a new guest row. If the caller already belongs to the poll, the claim fails and the guest capability stays valid; merging a guest into an existing membership is not supported.

`poll_private.verified_guest_participant` (F03) remains the verifier for later commands such as the F06/F10 availability save.

## Client migration and rollout

Installed signed-in clients keep working: their joins send their own `user_id`, which the new policy accepts, and the inserted row is returned through F03's own-row read condition. The web signed-out insert is still accepted by the insert policy, but F03 already broke its `.select()` (signed-out callers read no participant rows), so the web needs the `join_poll_as_guest` adapter from [F03](participant-access.md#client-compatibility) either way. Two behaviors change for signed-in clients. A second join by the same user now fails with `23505` (HTTP 409) instead of creating a duplicate, and joining a poll past `closes_at` fails with an RLS error. The first join on a double tap succeeds, so a reload shows the membership.

| Caller | Current call | Target call |
| --- | --- | --- |
| Web `joinPoll` (signed in), [`polls.ts`](../apps/web/src/lib/stores/polls.ts) | `from('poll_participants').insert({ poll_id, user_id }).select().single()` | `rpc('join_poll', { poll_uuid })`; use `data.participant` |
| Web `joinPoll` (signed out) | `insert({ poll_id, anonymous_name, anonymous_email }).select()`; fails since F03 | `rpc('join_poll_as_guest', { poll_uuid, display_name, guest_token })` with a token from `crypto.getRandomValues` (32 bytes, lowercase hex). Persist the token per poll before the call so a retry after a lost response reuses it. |
| iOS `PollService.joinPoll`, [`PollService.swift`](../apps/mobile/Sources/Shared/Services/PollService.swift) | Insert with `user_id` | `rpc("join_poll", params: ["poll_uuid": id])` decoding `{ participant: PollParticipant, created: Bool }`. The signed-out branch is unreachable today (`PollDetailView` passes `nil`). |
| Android `PollService.joinPoll`, [`PollService.kt`](../apps/android/app/src/main/kotlin/com/meetingscheduler/android/services/PollService.kt) | Insert with optional `user_id` | `rpc("join_poll", { poll_uuid })` decoding the same shape. A signed-out call today violates the identity check and fails; keep requiring sign-in. |
| Guest sign-in (new, optional) | None | After sign-in, call `claim_guest_participant` with the stored capability, then delete it locally. On `23505`, keep the existing membership and the guest row. |

Treat `42501` from `join_poll` as "cannot join" and `23505` from a legacy insert as "already joined, reload". No client source was changed in this branch.

**Rollout order**

1. **Integration owner:** replay F02, F08, F03, and F04 in version order and run every database and Edge suite.
2. **Project owner:** run the inspection query above and keep its output. Apply F03 first, then this migration, through the normal deployment process. It briefly holds locks that block writes to both tables.
3. Check the audit counts against the inspection, then confirm with `pg_indexes` that the unique index exists. Confirm the live `INSERT` policies on `poll_participants` are only the two F04 policies; remove any dashboard-created insert policy, which would combine with OR.
4. PostgREST smoke checks with test accounts: `rpc/join_poll` twice returns the same row; a direct insert naming another user fails; a `PATCH` of `poll_id` fails.
5. Ship the client adapters above. Web can ship immediately after deployment; native releases follow store review.
6. After installed versions using direct inserts age out, add a follow-up migration that drops both direct insert policies, so `join_poll` and `join_poll_as_guest` become the only join paths. Track this as a separate retirement step.

## Verification

```bash
npm ci --ignore-scripts --no-audit --no-fund
npm run test:membership:db
npm run test:participants:db
npm run test:rpc:db
npm run test:calendar:db
npm run test:billing:db
```

`tests/membership-integrity.test.mjs` replays the full history in PGlite 0.5.11 (PostgreSQL 18.6) in process. It seeds three-way and tied duplicate memberships, conflicting and tied responses, and same-name guests immediately before this migration, then queries as actual `anon`, `authenticated`, and `service_role` roles. Its 10 scenarios cover deterministic merging with preserved ids and timestamps, a complete private audit, the partial unique index, catalog grants and policies, `join_poll` identity and state rules and retries, a deterministically interleaved competing join, direct-insert forgery, duplicates and closed polls, poll/user reassignment by every role, idempotent guest joins, and capability-bound claims. PGlite is single-connection, so the race is simulated with a test trigger that inserts the competing membership between the command's check and its insert. Real concurrency relies on the unique index. No listening port is opened.

One F03 assertion was scoped: `tests/participant-access.test.mjs` now checks only the read and update policies that F03 owns, because F04 replaces the insert policy.

## Open items

- Account deletion: `user_id` is `ON DELETE SET NULL`, but the `participant_identity` check requires a user or guest name. Deleting a profile that has joined a poll therefore fails. This predates F04; choose between cascade deletion and anonymizing the row (`anonymous_name = 'Deleted user'`) as a separate change.
- Capacity (`max_participants`) is not enforced at join; that is F05, and `join_poll` is the place to add it.
- Guest availability responses still have no write path; F06/F10 should accept the guest capability.
