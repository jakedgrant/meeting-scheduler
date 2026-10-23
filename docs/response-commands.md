# Response invariants and availability commands (F06 + F10)

Migration: [`20261023000544_response_commands.sql`](../supabase/migrations/20261023000544_response_commands.sql), created with Supabase CLI 2.109.1 using `supabase migration new response_commands`. It builds on [F03](participant-access.md), [F04](membership-integrity.md), and [account deletion](account-deletion.md).

Before this change, a response's participant and time option could belong to different polls. Direct writes continued after a poll closed or passed its deadline, and the final selected time was any pair of values. Clients saved availability one option at a time, then saved the comment separately, and could show success after a partial failure.

## Invariants

| Invariant | Enforcement | Applies to |
| --- | --- | --- |
| Participant and time option belong to the same poll | `responses_10_check_write` trigger, `23514` | Every role, every insert/update |
| A response cannot be moved to another participant or option | Same trigger, `42501` | Every role |
| A time option cannot move to another poll | `time_options_10_protect_poll`, `42501` | Every role |
| Response writes require an open poll (`active`, `closes_at` unset or in the future) | Same trigger, which locks the poll `FOR SHARE`; `42501` `Poll is not accepting responses` | Direct Data API writes (insert, update, delete). Commands check this themselves. Cascades and account deletion are exempt. |
| A member writes only their own responses | RLS insert/update/delete policies (`authenticated` only); `anon` has no write grants | Direct Data API writes |
| Response rows are readable only by the poll owner and current members | RLS select policy (`authenticated` only); verified guests use `get_guest_poll_detail` or `get_availability` | All reads, including the F02 summary, embeds, and Realtime |
| Selected final time is a valid pair matching one of the poll's options | `poll_selected_time_pair` check, plus `polls_10_normalize_selected_time` (`23514`), which matches at second precision and stores the option's exact interval | Every write to the selected times |

Existing cross-poll responses are moved to `private.response_invariant_quarantine` with their full row, then deleted. The F02 summary already ignored them. If existing polls violate the selected-time pair check, the migration leaves the constraint `NOT VALID`. It is still enforced for new writes, and the migration logs a notice. To find the violating rows, run `SELECT id, selected_start_time, selected_end_time FROM public.polls WHERE (selected_start_time IS NULL) <> (selected_end_time IS NULL) OR selected_end_time <= selected_start_time`. After fixing them, run `ALTER TABLE public.polls VALIDATE CONSTRAINT poll_selected_time_pair`.

## Serialization rule

Every response mutation, whether a command or a direct write, locks the poll row `FOR SHARE` and re-checks that the poll is open. Closing a poll (a direct status update) or finalizing it updates that row. That update waits for in-flight saves, and any save that starts later sees the closed state. **A save either commits entirely before the close/finalize, or is rejected after it.** Saves for the same participant are serialized by a `FOR NO KEY UPDATE` lock on the participant row.

## Commands

Each command is a `public` invoker wrapper over a `poll_private` definer with an empty `search_path` and no `PUBLIC` execution. `save_availability` and `get_availability` are granted to `anon` (guests), `authenticated`, and `service_role`; `finalize_poll` to `authenticated` and `service_role`.

**Identity.** A signed-in member is resolved from `auth.uid()` and their membership in `poll_uuid`. If `participant_uuid` is sent, it must be that membership. A guest sends `participant_uuid` and its F03 `guest_token`, which `poll_private.verified_guest_participant` checks, and its participant must belong to `poll_uuid`. A signed-in device may also use a guest capability.

### `save_availability`

Request (named arguments; `comment` is required so that omitting it never clears a comment):

| Argument | Type | Meaning |
| --- | --- | --- |
| `poll_uuid` | uuid | Poll being answered |
| `request_id` | uuid | Client-generated per logical save; reuse it for retries |
| `responses` | jsonb array | The **complete** set: `[{ "time_option_id": uuid, "status": "available" \| "maybe" \| "unavailable", "note": string \| null }]`. Options left out are deleted. At most 500 entries, each note at most 500 characters. |
| `comment` | text or null | The participant's comment; `null` clears it. At most 500 characters. |
| `expected_version` | bigint, optional | Rejects the save if the stored version differs |
| `participant_uuid` | uuid, optional | Required for guests; optional check for members |
| `guest_token` | text, optional | Guest capability |

Success response:

```json
{
  "participant_id": "uuid", "poll_id": "uuid", "version": 7, "comment": "text or null",
  "responses": [{ "id": "uuid", "time_option_id": "uuid", "status": "available", "note": null, "updated_at": "timestamptz" }],
  "saved_at": "timestamptz", "replayed": false
}
```

Responses are ordered by `time_option_id`. The whole save is one transaction: responses are deleted, inserted, or updated, then the comment changes. Rows that did not change are not rewritten and keep their `id`.

**Version.** A monotonic counter per participant that increases with every persisted change to its responses or comment, including direct Data API writes and guest comment edits. It can increase by more than one per save, so compare for equality only. A save that changes nothing keeps the version.

**Idempotency.** The first result for each `(participant, request_id)` is stored. A retry with the same payload returns that stored result with `replayed: true` and writes nothing, even after the poll has closed or a newer save has happened. A late retry therefore never overwrites newer data.

Errors:

| SQLSTATE | Message | Meaning / client action |
| --- | --- | --- |
| `42501` | `Authentication required` | No session and no guest capability |
| `42501` | `Poll access denied` | Not a member of the poll, wrong `participant_uuid`, or missing poll (indistinguishable) |
| `42501` | `Guest access denied` | Invalid, rotated, claimed, or other-poll capability: clear it and offer to rejoin |
| `42501` | `Poll is not accepting responses` | Closed, expired, draft, or archived: keep the draft, show the poll as closed |
| `PT409` (HTTP 409) | `Responses changed since the expected version` | `details` is `current_version=N`. Reload, merge the draft, retry with a new `request_id`. |
| `22023` | `request_id is required`, `responses must be a JSON array`, `Too many responses`, `Invalid response entry`, `Duplicate time option in responses`, `Time option does not belong to this poll`, `Note must be 500 characters or fewer`, `Comment must be 500 characters or fewer` | Client bug or stale options: nothing was saved |
| `22023` | `request_id was already used with a different payload` | Generate a new `request_id` for a changed draft |

### `get_availability`

`get_availability(poll_uuid, participant_uuid DEFAULT NULL, guest_token DEFAULT NULL)` returns the same object without `saved_at`/`replayed`, in any poll state. It uses the same identity rules and errors. Use it to obtain `version` for `expected_version`.

### `finalize_poll`

`finalize_poll(poll_uuid, time_option_uuid)` is organizer-only. It locks the poll `FOR UPDATE` (see the serialization rule), sets `selected_start_time`/`selected_end_time` to the option's exact interval, sets `status = 'closed'`, and returns the `polls` row. It works on active or closed polls and can be repeated to change the selection.

Errors: `42501` `Authentication required`; `42501` `Poll access denied` (not the creator, or missing); `42501` `Poll cannot be finalized` (draft or archived); `22023` `Time option does not belong to this poll`.

## Client adapter contract and rollout

Installed clients keep working; no client change is required for this migration:

- Web `submitAvailability`, iOS `submitAvailability`, and Android `saveResponses` upsert their own rows on open polls. On closed or expired polls they now get `42501`. The web hides editing on closed polls but not on active polls past `closes_at`, and it only logs save failures; the F10 adapter below fixes both.
- Member comment updates are unchanged.
- Web/iOS/Android finalize by updating `selected_*_time` with an option's times; the trigger normalizes iOS's second-precision values. Writes that match no option fail with `23514`.
- Signed-out and pre-join screens no longer receive response rows. Web already fetched responses by participant ID, so pre-join counts were empty after F03.

Target adapter, per client (F10):

1. Keep the user's edits as a **draft** separate from the server snapshot. Generate a `request_id` when the user taps Save and reuse it for every retry of that draft.
2. Call `save_availability` with the complete response set and the comment. Pass the `version` from the last load as `expected_version` to detect edits from another device, or omit it for last-write-wins.
3. Replace the displayed state and cache only with the returned object. On any error, keep the draft and show a retry action; never mark it saved. Handle `PT409` by reloading through `get_availability` and asking the user, or merging.
4. Organizers finalize with `finalize_poll` instead of updating `polls`.
5. **Web guests** (F03 adapter, `apps/web/src/lib/guest-capability.ts`): pass the stored `participant_uuid` and `guest_token`, re-enable the availability buttons for guests, and route `Guest access denied` to the existing lost-capability notice.

Rollout:

1. **Integration owner:** replay F02, F08, F03, F04, account deletion, and this migration in version order, then run every suite.
2. **Project owner:** before applying, count the cross-poll rows that will be quarantined: `SELECT count(*) FROM availability_responses ar JOIN poll_participants pp ON pp.id = ar.participant_id JOIN poll_time_options pto ON pto.id = ar.time_option_id WHERE pp.poll_id <> pto.poll_id`. Run the selected-time query above as well.
3. Apply the migration. It locks `availability_responses` while quarantining. Check for the `NOT VALID` notice, and confirm the live response policies are exactly the four above (remove dashboard-created ones).
4. Ship the client adapters: web first (it can feature-detect `PGRST202`), then native.
5. After installed versions age out, a follow-up migration can drop the direct response write policies so that `save_availability` is the only write path. Until then, direct writes are held to the same invariants.

Retention: `private.response_save_requests` grows by one row per save. Prune old entries, for example `DELETE FROM private.response_save_requests WHERE created_at < now() - interval '30 days'`, from a scheduled job. Retries older than the retention window will then be re-applied as new saves.

## Date and time (F21)

Column types are unchanged, and F21 does not block this work. `closes_at` and option intervals are `timestamptz` instants compared with the database's `now()`. Finalization copies an existing option's interval, so it does not depend on how a client encoded all-day or zoned options. When F21 introduces calendar dates or exclusive all-day ends, the deadline comparison and option matching here should be revisited.

## Verification

```bash
npm run test:responses:db
```

`tests/response-commands.test.mjs` replays the full history in PGlite and seeds a pre-F06 cross-poll response and a closed-poll response before this migration. As actual `anon`, `authenticated`, and `service_role` roles, its 14 scenarios cover:

- quarantine, and the policy/grant/function catalog
- owner/member/guest response reads
- direct writes: cross-poll, identity changes, closed and expired polls, the legacy upsert, other users' rows, and option moves
- full-set replacement with preserved ids and versions, and no-op saves
- idempotent replays, including after a newer save and after closing, and request-id reuse
- payload validation with no partial writes, `PT409` conflicts, and versions advanced by direct writes
- identity resolution for members, guests, and swapped or other-poll capabilities
- close serialization outcomes, organizer-only finalization, and selected-time normalization and rejection
- owner poll deletion cascades, and account deletion erasing save results and notes

PGlite has one connection, so row-lock waiting is described rather than raced; the tests assert the outcomes on both sides of a close.

One existing test fixture changed: `tests/rpc-authorization.test.mjs` seeds its two legacy cross-poll responses with the new check trigger disabled when it exists. The test of F02's summary filter still covers rows written before F06.

The account-deletion function is redefined here to also delete the user's `response_save_requests`, which hold comments and notes. Its behavior is otherwise unchanged.
