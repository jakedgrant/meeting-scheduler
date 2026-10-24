# Transactional creation and authoritative limits (F05 + F09)

Migration: [`20261023224522_transactional_poll_creation.sql`](../supabase/migrations/20261023224522_transactional_poll_creation.sql), created with `supabase migration new transactional_poll_creation`.

`create_poll` validates the entire request, creates the active poll and its options, and redeems a pass in one transaction. An invalid option or failed write leaves no poll, options, redemption, funding record or retry receipt. All three clients must use this command rather than inserting a poll and adding options separately.

## Command contract

Only `authenticated` and `service_role` may execute the public invoker wrapper. Its private definer uses an empty `search_path`, derives the creator from `auth.uid()`, and requires an existing profile. No request field selects another account.

```json
{
  "operation_id": "client-generated UUID",
  "payload": {
    "title": "Dinner",
    "description": null,
    "location": null,
    "timezone": "America/Chicago",
    "closes_at": null,
    "use_event_pass": false,
    "time_options": [
      {"start_time": "2027-11-01T12:00:00Z", "end_time": "2027-11-01T13:00:00Z", "is_all_day": false}
    ]
  }
}
```

`title`, `timezone`, and `time_options` are required. Missing nullable fields default to null; missing booleans default to false. Clients should consistently serialize those fields so the same logical retry sends the same JSONB value. Extra poll or option keys are rejected, including `creator_id`, `status`, `is_premium`, `max_participants`, and `share_code`.

Guardrails: trimmed title 1–200 characters, description at most 10,000, location at most 1,000, timezone in PostgreSQL's `pg_timezone_names`, and 1–500 options. Each option requires finite timestamps with a `Z` or numeric `±HH:MM` offset and an end after its start. `is_all_day` is a boolean. An optional deadline must be finite and in the future; it remains available on the free tier. These are validation bounds, not new paid features or date/calendar product policy.

Success:

```json
{
  "poll": {"id": "uuid", "creator_id": "uuid", "status": "active", "is_premium": false, "max_participants": 10, "share_code": "ABC234"},
  "time_options": [{"id": "uuid", "poll_id": "uuid", "start_time": "timestamp", "end_time": "timestamp", "is_all_day": false}],
  "redeemed_pass_id": null,
  "entitlement": "free",
  "replayed": false
}
```

`poll` and `time_options` contain their complete database rows, including timestamps and nullable fields. Options retain request order. `entitlement` is `free`, `pro_access`, `team_access`, or `event_pass`. Clients apply the returned rows and limits, rather than reconstructing them from cached RevenueCat booleans.

## Product rules

The owner confirmed these rules for this delivery:

| Funding | Active-poll rule | Participant rows per poll |
| --- | --- | --- |
| Free | One ordinary draft/active poll, plus any pass-funded polls | 10 |
| Current Pro | Unlimited draft/active polls | 50 |
| Current Team | Unlimited draft/active polls | 100 |
| Event pass | One additional premium poll per redeemed unit | 50 |

The organizer occupies a place only if they join. Counts include every actual member or guest row, including anonymized former members. No organizer membership is inserted automatically.

An event pass is spent only when `use_event_pass` is true and the caller has no current subscription. Select the oldest eligible `purchased_at`, with `id` as the tie-breaker. A current Pro/Team subscription always funds creation and preserves passes, including when the opt-in flag is true. Availability uses the [billing contract](billing-webhooks.md): a non-null project, no revocation, no redemption, and a future verification deadline. Receipt ownership and eligibility are rechecked under the pass row lock.

`private.poll_pass_funding` records the original creator, poll and redeemed pass ID. It preserves actual historical redemptions when the migration runs. Pass-funded polls stay outside the ordinary free quota if their receipt is later revoked, transferred or deleted. A mutable `is_premium` field or current receipt owner cannot change that quota. Poll deletion removes its funding record; it never restores a spent pass.

Existing active polls retain their saved settings. Reopening a subscription-funded premium poll requires a current tier that supports its saved capacity: a former Team poll with capacity 100 cannot reopen on Pro. Reopening a pass-funded poll keeps its historical funding even after refund/revocation or receipt transfer and spends no additional pass. Free reactivation uses the same ordinary-slot quota as creation.

## Retry and error behavior

The first successful `(creator_id, operation_id)` stores the exact JSONB payload and result in `private.poll_creation_requests`. A matching retry returns the original snapshot with `replayed: true`, including after a lost reply, closure, entitlement expiry or poll deletion. Another account cannot replay it. JSON object key order does not matter; omitted/null/default fields and array order remain part of the payload. A changed payload under the same ID fails. A failed first attempt saves no receipt, so a corrected request can reuse its ID. A payload-mismatch rejection means that ID already has a successful receipt; restore and retry the original envelope to recover that poll.

Preserve the ID and the exact submitted payload after a transport failure. Keep the draft after every failure. After an explicit rollback rejection of a first attempt, a user edit can start a new logical operation; retrying unchanged content may reuse its ID. A payload-mismatch rejection preserves the original pending envelope and ID, because that operation already committed. A late response from another account must not enter the current account's cache, list, draft or navigation state.

| SQLSTATE | Meaning | Client action |
| --- | --- | --- |
| `42501` | Missing authentication, unsupported premium reopening/current subscription, or denied table mutation | Sign in, refresh access, or choose a supported action; show the specific server message |
| `22023` | Invalid fields/options/deadline, or option bound exceeded | Retain draft and let the user correct it |
| `22000` | Same operation ID with a different payload; the original operation already succeeded | Retain the edited draft separately, restore the original pending envelope and retry it to recover/check the existing poll |
| `P0001` | Ordinary active-poll quota reached | Close an ordinary poll, subscribe, or explicitly opt into a pass |
| `P0002` | No eligible event pass after locking/recheck | Refresh purchases, choose another funding option, or turn off pass use if a free slot exists |
| `P0003` | Participant capacity reached | Explain that the poll is full; an existing membership/capability retry still succeeds |
| `54000` | Twenty share-code allocation collisions | Retry unchanged content and operation ID |

A transport error is not evidence that the transaction failed. Validation/auth/quota errors are explicit transaction rejections; server/storage errors still retain the operation identity for a safe retry.

## Serialization and direct writes

Creation locks the creator's profile row before checking a previous operation, entitlement, quota or pass. API reactivation locks the same creator row. This serializes competing creates and reactivations. Options, pass redemption, provenance and the creation receipt commit together.

`private.billing_effective_entitlement(uuid)` remains the tier authority. Its additive replacement evaluates `clock_timestamp()` so a transaction waiting on a lock cannot authorize an entitlement that expired during the wait. Pass eligibility, changed deadlines, join deadlines and final creation checks also use decision time. A code-collision wait cannot carry an expired paid grant or deadline into the saved result.

The share-code unique index decides collisions, including codes attached to inaccessible polls and concurrent creators. The command generates a fresh candidate and catches only `polls_share_code_key`; it never retrieves or returns the colliding poll.

Poll API inserts have no policy and no insert grant. A direct update cannot change identity, share code, paid status or capacity. The update trigger validates title, text bounds, timezone, status and changed deadline, and guards reactivation. It applies to inherited API roles as well as the built-in roles. Trusted superusers/BYPASSRLS service roles retain administrative access for fixtures and deliberate maintenance; possession of those credentials is outside the public-client boundary.

Options remain editable by their existing owner policy. Their trigger locks the poll and applies finite intervals, boolean all-day state and the 500-option bound to direct insert/update paths. Existing selected-option protection runs first. This delivery does not change the F06 rule allowing edits of unselected options.

Every participant insert locks its poll `FOR UPDATE` and checks capacity against all participant rows. Member and guest join commands acquire that lock before participant/credential locks and recheck an existing identity after waiting. Direct inserts use the same trigger and the existing self/guest RLS policies. A direct or command join either occupies the final place before another join, or receives `P0003`; no two waits can both claim it. Guest/member retry identity is resolved before a capacity rejection.

## Verification

Run the full in-process migration/role suite:

```bash
npm run test:database
```

The focused creation suite includes historical funding backfill, invalid later options, failures before options and after redemption, changed/same-ID retries, lost replies, stale subscriptions, all unavailable pass states, explicit oldest selection, subscriber pass preservation, durable pass provenance, reopening, direct/inherited-role bypass attempts and full-poll retries.

Real PostgreSQL concurrency runs require separate fresh disposable `scheduler_test_*` databases for each suite:

```bash
TEST_DATABASE_URL='postgresql://.../scheduler_test_creation' node --test tests/concurrent-creation.test.mjs
TEST_DATABASE_URL='postgresql://.../scheduler_test_commands' node --test tests/concurrent-commands.test.mjs
```

Each race observes `pg_stat_activity.wait_event_type = 'Lock'` before releasing the winning transaction. Creation tests cover quota, same-ID replay/mismatch, pass competition, changed pass eligibility/ownership, natural subscription/pass/deadline expiry while blocked, reactivation, direct/command joins, full-place retries and option count. The coordinator's evidence index records tested commits, outputs, CI and runtime cleanup.

This migration is additive and preserves existing development/beta rows. Hosted migration, effective Data API grants, provider reconciliation and distribution credentials remain prelaunch validation; no hosted change is deployed by this PR.
