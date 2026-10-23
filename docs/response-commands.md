# Response invariants and availability commands (F06 + F10)

Migration: [`20261023000544_response_commands.sql`](../supabase/migrations/20261023000544_response_commands.sql), created with Supabase CLI 2.109.1 using `supabase migration new response_commands`. It builds on [F03](participant-access.md), [F04](membership-integrity.md), and [account deletion](account-deletion.md).

Before this change, a response's participant and time option could belong to different polls. Direct writes continued after a poll closed or passed its deadline, and the final selected time was any pair of values. Clients saved availability one option at a time, then saved the comment separately, and could show success after a partial failure.

## Invariants

| Invariant | Enforcement | Applies to |
| --- | --- | --- |
| Participant and time option belong to the same poll | `responses_10_check_write` trigger, `23514` | Every role, every insert/update |
| A response cannot be moved to another participant or option | Same trigger, `42501` | Every role |
| A time option cannot move to another poll | `time_options_10_protect_poll`, `42501` | Every role |
| The interval of a selected option cannot change or be deleted | Same trigger, which locks the poll `FOR UPDATE`; `23514` `Selected time option cannot be changed or deleted` | Every option update/delete; deleting the whole poll still cascades |
| Response writes require an open poll (`active`, `closes_at` unset or in the future) | Same trigger, which locks the poll `FOR SHARE`; `42501` `Poll is not accepting responses` | Direct Data API writes (insert, update, delete). Commands check this themselves. Cascades and account deletion are exempt. |
| A member writes only their own responses | RLS insert/update/delete policies (`authenticated` only); `anon` has no write grants | Direct Data API writes |
| Response rows are readable only by the poll owner and current members | RLS select policy (`authenticated` only); verified guests use `get_guest_poll_detail` or `get_availability` | All reads, including the F02 summary, embeds, and Realtime |
| Selected final time is a valid pair matching one of the poll's options | `poll_selected_time_pair` check, plus `polls_10_normalize_selected_time` (`23514`), which matches at second precision and stores the option's exact interval | Every write to the selected times |

Existing cross-poll responses are moved to `private.response_invariant_quarantine` with their full row, then deleted. The F02 summary already ignored them. If existing polls violate the selected-time pair check, the migration leaves the constraint `NOT VALID`. It is still enforced for new writes, and the migration logs a notice. To find the violating rows, run `SELECT id, selected_start_time, selected_end_time FROM public.polls WHERE (selected_start_time IS NULL) <> (selected_end_time IS NULL) OR selected_end_time <= selected_start_time`. After fixing them, run `ALTER TABLE public.polls VALIDATE CONSTRAINT poll_selected_time_pair`.

## Serialization rule

Every response mutation, whether a command or a direct write, locks the poll row `FOR SHARE` and re-checks that the poll is open. Closing a poll (a direct status update) or finalizing it updates that row. That update waits for in-flight saves, and any save that starts later sees the closed state. **A save either commits entirely before the close/finalize, or is rejected after it.** Saves lock the poll before the participant (`FOR UPDATE`) and, for guests, the credential. Ownership and capability are checked again after the locks, before a saved request can be replayed. Claims and rotations use the same lock order: a claim or rotation that commits first rejects the waiting save's old capability.

Option interval edits/deletes and finalization serialize on the poll's `FOR UPDATE` lock. Once selected, an option's interval must remain unchanged. Clear the selection or select another option before editing/deleting it. Unselected options remain editable. If an option mutation commits before finalization, finalization uses the new interval or rejects a deleted option. If finalization commits first, a waiting mutation of its selected option is rejected. Deleting the parent poll remains allowed.

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

## Implemented clients and prelaunch deployment

Web, iOS and Android now load `get_availability`, save the complete response set and comment through `save_availability`, and finalize by option identity through `finalize_poll`. Each editor retains a failed draft, reuses its request UUID for an unchanged retry, applies the persisted response, and requires explicit review after a version conflict. Editing stays disabled until the initial saved baseline loads. Native services reject results from an earlier account; iOS also invalidates detail caches around uncertain writes and adopts the returned final poll.

Web guests retain a capability in memory when browser storage is unavailable. A lost join response can be retried with the same generated token, and stale page operations cannot overwrite a newer capability or account's state. Native navigation still requires sign-in; capability argument support does not establish a signed-out native journey.

This project has not been publicly released. Deploy the ordered migrations and these clients together in the development/staging environment before launch; no installed public-client retirement period is required. Direct response writes remain constrained by the database invariants above. Removing that compatibility surface can be a separate simplification.

1. Replay every migration in version order, then run `npm run test:database` and the real PostgreSQL concurrency suite below. CI replays the same history on PostgreSQL 17 and 18.
2. Before applying to an existing development database, inspect the cross-poll quarantine count and selected-time pair violations described above. Resolve invalid rows and validate any remaining `NOT VALID` constraint.
3. Apply the migrations and verify effective grants, policies and RPC exposure in the target Supabase project. Dashboard-created policies must not broaden the intended four response policies.
4. Deploy all three clients. Complete signed-in and guest journeys against the target PostgREST endpoint before launch, including permission loss, retry and conflict handling. Local role fixtures and SDK transport tests do not establish hosted configuration or a mounted UI journey.

See the [October 23 evidence index](architecture-remediation-evidence-2026-10-23/README.md), [web evidence](web-availability.md), [iOS cache evidence](ios-persistence-evidence.md), and [iOS command evidence](ios-response-client-evidence.md).

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

The PGlite scenarios also cover selected-option edits/deletion, clearing the selection, parent deletion with a selected option, and rejecting an old capability's saved-request replay after claim.

`tests/concurrent-commands.test.mjs` uses independent PostgreSQL connections. It observes `pg_stat_activity.wait_event_type = 'Lock'` before committing the winning operation; elapsed time is not used as evidence that the loser waited. Its 17 races cover claim/rotation before guest update/save/rotation/claim, an edit before claim, member and guest save/close in both orders, and selected-option edit/delete against finalization in both orders. The fixture replays every migration, uses actual API roles, and requires an empty database named `scheduler_test_*`.

```bash
# Create a fresh disposable database first. Never point this at development or hosted data.
TEST_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/scheduler_test_commands npm run test:commands:concurrent
```

The October 23 remediation run passed all 17 races on PostgreSQL 18.4 using an isolated Unix socket with TCP disabled. The test-only client is pinned to `pg` 8.23.1. A standard PostgreSQL service in CI can run the same command; no embedded runtime dependency or hosted Supabase access is required.

One existing test fixture changed: `tests/rpc-authorization.test.mjs` seeds its two legacy cross-poll responses with the new check trigger disabled when it exists. The test of F02's summary filter still covers rows written before F06.

The account-deletion function is redefined here to also delete the user's `response_save_requests`, which hold comments and notes. Its behavior is otherwise unchanged.
