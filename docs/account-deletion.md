# Account deletion and poll participation

Migration: [`20261022235817_participant_account_deletion.sql`](../supabase/migrations/20261022235817_participant_account_deletion.sql), created with Supabase CLI 2.109.1 using `supabase migration new participant_account_deletion`. It builds on [F03](participant-access.md) and [F04](membership-integrity.md).

## Problem

Deleting an auth user cascades to `public.profiles`. `poll_participants.user_id` is `ON DELETE SET NULL`, but the `participant_identity` check requires either a user or a guest name. Deleting anyone who had joined a poll therefore failed with `23514`, which also blocked account deletion as a whole.

## Behavior (owner decision, October 22)

A `BEFORE DELETE` trigger on `public.profiles`, `profiles_anonymize_participation`, runs `poll_private.anonymize_deleted_participant()`. That function is a definer with an empty `search_path`, and no API role can execute it. For each of the user's participant rows, the trigger:

| Field | After deletion |
| --- | --- |
| Row, `id`, `poll_id`, `access_token` | Kept |
| `user_id` | `NULL` |
| `anonymous_name` | `Deleted user` |
| `comment` | `[user deleted]` if the user had written one; a `NULL` comment stays `NULL` |
| Availability responses, including notes | Kept on the row |
| Private guest credential (verifier and contact email), for example from a claimed guest row | Deleted |
| F04 merge-audit copies whose archived row names the user | Deleted |

The row never has a capability afterwards. Every guest command, including get, detail, update, rotate, and claim, returns `42501` / `Guest access denied`. A Data API caller still cannot unlink or rename a participant: F03/F04's identity trigger blocks API roles. The anonymizing update runs as the function owner, which that trigger allows for `user_id → NULL`. The trigger runs before the profile's foreign-key actions, so `ON DELETE SET NULL` finds nothing left to change.

Everything else is unchanged. The user's own polls are still deleted through `creator_id ON DELETE CASCADE`, together with their options, participants, and responses. Subscriptions, event passes, billing entitlements, auth sessions, and the calendar connection follow their existing cascades. The calendar connection still queues its refresh token for revocation.

## Choices to confirm

- The comment marker replaces existing text only. If the owner wants every former member row marked, change the `CASE` to an unconditional `'[user deleted]'`.
- Response `note` text written by the deleted user is kept with the responses. The decision preserves responses; if notes count as personal data to erase, clear `note` in the same trigger.

## Verification

```bash
npm run test:account-deletion:db
```

`tests/account-deletion.test.mjs` replays the full history in PGlite and first reproduces the pre-fix `23514` failure. It then deletes auth users that have:

- memberships with and without comments, with responses
- a claimed guest row
- their own poll that others joined
- calendar, subscription, pass, and session rows
- merge-audit copies

It checks anonymization, kept responses and summaries, failed claims and guest reads with the old capability, the existing cascades including calendar revocation queuing, audit erasure, function grants, and blocked Data API unlinking.

## Hosted rollout

Apply after F03 and F04. No client change is needed. Clients already show `anonymous_name` when there is no profile. After deploying, delete a test account that joined another user's poll. Then confirm the row reads `Deleted user` / `[user deleted]` and the account's own polls are gone. Check whether account deletions have been failing in production. Any user who requested deletion and was blocked by the old error may need the deletion re-run.
