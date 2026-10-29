# Bounded read contracts (F19)

Migration: [`20261025062518_bounded_read_apis.sql`](../supabase/migrations/20261025062518_bounded_read_apis.sql), created with `supabase migration new bounded_read_apis`.

Before this change, the poll list came from `get_user_participated_polls`, which returns a user's entire created and joined history as one JSON value. Detail screens read options, participants and responses straight from the tables, where the Data API silently stops at 1,000 rows (`max_rows` in `supabase/config.toml`). A poll can have 500 options and 100 participants, so its responses can reach 50,000 rows. Neither path told the client whether it had everything.

Three RPCs replace those reads for signed-in members. Each one has a hard size bound and tells the client how to confirm the result is complete.

## Access

Only `authenticated` and `service_role` can execute the public invoker wrappers. The private definers in `poll_private` use an empty `search_path` and take identity from `auth.uid()`. The list includes polls the caller created, plus other users' polls where the caller has an authenticated participant row, which is the same rule the legacy RPC used. Detail and response pages require `poll_private.can_read_poll`. A missing poll and an inaccessible poll both return `42501` with the same message.

Guests keep using `get_guest_poll_detail` through their capability. Its shape has not changed (see [remaining work](#remaining-work)).

## Poll summaries

```
list_poll_summaries(role_filter text = null, page_size int = 50, page_cursor text = null) -> jsonb
```

`role_filter` is `owner`, `member` or null (both). `page_size` must be 1–100.

```json
{
  "items": [
    {
      "poll": {"id": "uuid", "title": "Dinner", "status": "active", "created_at": "...", "...": "complete polls row"},
      "role": "owner",
      "participant_count": 12,
      "time_option_count": 4,
      "earliest_start": "2027-11-01T12:00:00+00:00",
      "latest_start": "2027-11-04T12:00:00+00:00"
    }
  ],
  "has_more": true,
  "next_cursor": "p1:1793520000000000:6f1c…",
  "total_count": 87
}
```

The database computes the counts and option range over every row for the poll, so they stay correct beyond the row cap. `earliest_start` and `latest_start` are null when a poll has no options. `total_count` is the number of polls matching `role_filter` at the time of that page.

Rows are ordered by `created_at DESC, id DESC`. The migration backfills null `created_at` values from `updated_at` (or the epoch), makes the column `NOT NULL`, and adds `polls_creator_created_order` on `(creator_id, created_at DESC, id DESC)`. `check_poll_update` already stops API roles from changing `created_at`, so a row's position never moves.

## Poll detail

```
get_poll_detail(poll_uuid uuid) -> jsonb
```

```json
{
  "poll": {"...": "complete polls row"},
  "time_options": [{"...": "complete row, ordered by start_time, id"}],
  "participants": [{"...": "complete row", "profiles": {"display_name": "Ana"}}],
  "time_option_count": 4,
  "participant_count": 12
}
```

Participants use the same projection and `profiles` embed as guest detail and the old `select('*, profiles(display_name)')`. For guest rows `profiles` is null. The F03 constraints keep `anonymous_email` null and `access_token` equal to `id`, so neither carries a secret.

Both collections are returned in full because writes already bound them: `check_poll_option` rejects a 501st option, and `check_participant_capacity` enforces `max_participants` (at most 100 for current tiers). A legacy poll with more than 500 options or 500 participants fails with `54000` instead of returning part of its data. Its summary still reports the true counts.

## Response pages

```
list_poll_responses(poll_uuid uuid, page_size int = 500, page_cursor text = null) -> jsonb
```

`page_size` must be 1–1000. Items are complete `availability_responses` rows ordered by `(participant_id, time_option_id)`, which the existing unique index serves. Only pairs whose participant and option both belong to the poll are included, matching guest detail and `get_poll_with_summary`. Legacy cross-poll rows written before F06 never appear.

`total_count` is present on the first page (no cursor) and null on later pages. Recounting on every page would repeat work proportional to the poll's responses.

## Cursors and the completeness rule

Cursors are opaque, versioned strings. `p1:` cursors encode integer microseconds plus the poll id. `r1:` cursors encode the participant and option ids. A cursor from one RPC is rejected by the other. Malformed cursors, unknown roles and out-of-range page sizes fail with `22023`; there is no fallback to a default page.

Pages use keyset traversal over immutable keys. A traversal never repeats a row, and a row that exists for the whole traversal is never skipped. Writes that land during a traversal behave as follows:

- A poll created after the first page sorts ahead of the cursor. It appears on the next refresh, never in the middle of a traversal.
- A deleted row simply stops appearing.
- A response inserted or deleted behind the cursor changes the total without appearing in the pages already read.

Clients must therefore:

1. Follow `next_cursor` until `has_more` is false. `has_more` is true exactly when `next_cursor` is non-null.
2. When a screen needs the whole collection (response pages), check that the rows are distinct and that their number equals the first page's `total_count`. On a mismatch, report an incomplete load and let the user retry; never show the partial set as if it were complete.
3. For detail, check that each array's length equals its count field.
4. For lists, show `total_count` and load later pages on demand rather than walking the whole history up front.

## Client adoption

| Client | Status |
| --- | --- |
| Web | Adopted. The list asks for the first page of each section (two requests regardless of history size) and appends pages with **Load more**; it no longer makes two table requests per poll. Detail uses `get_poll_detail` plus full response traversal, and the realtime response reload uses the same traversal. A failed or incomplete read shows an error with a retry button, not an empty history. See `apps/web/src/lib/paged-read.ts` and `tests/web-paged-reads.test.mjs`. |
| iOS | Adopted in the native continuation. The list reads one combined summary page (50 polls), exposes the current total and **Load more**, and uses summary counts/ranges directly. Filters apply to loaded polls. Both detail and response screens consume validated `get_poll_detail` metadata and traverse response pages before caching or displaying them. |
| Android | Adopted in the native continuation. One combined summary page populates both list sections, with the total and **Load more**. No per-poll enrichment runs. Detail and response screens use `get_poll_detail` and validated response traversal. |

`get_user_participated_polls` and `get_poll_with_summary` stay, with their F02 authorization, for compatibility with older builds. Current web/iOS/Android list and detail screens no longer call them. Retire them in a later migration once no shipped client calls them.

The native adapters reject mismatched metadata counts, duplicate response IDs/pairs, foreign participant/option references, missing first-page response totals, inconsistent continuation flags, and repeated cursors. They check the final response count against the first total. A failed traversal does not publish its partial rows. Account/request generations prevent late reads from replacing another account or a newer refresh. Transport tests cover these boundaries with intercepted SDK requests; hosted execution remains a separate check.

On iOS a partial list replaces only cached list membership. It does not delete unloaded details. Only an authoritative, complete first page reconciles deletion across the cache. A full traversal is not a database snapshot, so reaching the last page does not authorize deleting details for polls absent from that traversal. Transport failures retain the prior complete detail fallback; an invalid or incomplete payload shows a retry error instead. Cursors and totals are not persisted: reopening offline shows cached polls with a load error and retry, rather than claiming the history is complete.

## Verification

- `npm run test:reads:db` (also part of `npm run test:database`): migration replay with a legacy null `created_at`, grants, full traversal at several page sizes up to 100, including polls that share a microsecond timestamp, role filters, a poll created mid-traversal, 1,200 responses across pages of 400 and 500, cross-poll exclusion, invalid cursors and sizes, unrelated and missing callers, and the oversized-detail failure.
- `npm run test:web:reads`: the bundled web store and list screen against a mocked transport. It checks request counts, load-more and its fencing across account changes, error display, 1,200-row response traversal, and rejection of mismatched totals or counts.

Query plans and payload sizes have not been measured against representative hosted data. Do that before setting operating limits tighter or looser than the ones above.

## Rollout

Apply the migration with the other ordered migrations. `ALTER COLUMN created_at SET NOT NULL` scans `polls` under a brief exclusive lock, and the new index build blocks writes to `polls` while it runs. Both are short for an unreleased app. Ship web and native clients with or after the migration, because it calls the new RPCs directly.

## Remaining work

- Guest detail still returns all of a poll's responses in one value. A guest response-page variant would need its own capability check.
- F20 realtime: the web participant reload still reads the table directly. That read is bounded by capacity, well under the row cap.
