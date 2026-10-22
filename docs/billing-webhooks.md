# RevenueCat billing processing (F08)

Implemented and merged into `main` October 22, 2026 ([#60](https://github.com/jakedgrant/meeting-scheduler/pull/60)). **Merging did not deploy anything. Hosted migration, secrets, deployment, scheduling, backfill and real store/provider validation remain pending.** Nothing in this change deploys functions or changes RevenueCat accounts, products or customers. F05 quota enforcement and atomic pass redemption remain separate work.

## Delivery and processing

`revenuecat-webhook` accepts POST JSON with the configured authorization header. If `REVENUECAT_WEBHOOK_SIGNING_SECRET` is set, the raw body must also pass RevenueCat HMAC verification with a five-minute delivery timestamp tolerance. The handler bounds the body, validates version/identity/event fields, and strips subscriber attributes before storage. It has no provider API calls or background promises.

A successful HTTP **200 means the event was committed to `private.billing_inbox`**, including an explicit ignored/quarantined disposition where appropriate. The unique event ID prevents duplicate scheduling. Reusing an ID with different normalized event data returns 409. Invalid input returns 400/413/415, bad authentication 401, methods other than POST 405, and unavailable configuration/storage 503. No failed durable write is acknowledged as success. RevenueCat treats non-200 responses as failed deliveries and retries a finite number of times; its retry window is not the recovery queue.

The independently scheduled `billing-worker` claims one customer per invocation. It reads complete RevenueCat **v2** subscriptions and purchases, including all pages and relevant nested entitlement pages, filtered to the configured environment. `gives_access`, current purchase ownership/refund status, and entitlement membership determine access. A cancellation, billing issue, scheduled product change or pause notification never directly grants or revokes access. An unrelated one-time product never creates a pass; only explicitly configured RevenueCat product IDs do. Configured consumables never confer lifetime subscription access.

One database transaction replaces relevant grants, reconciles pass units, updates the compatible subscription projection, and completes the event targets. A failed receipt write rolls back every output and completion marker. Error handling records a bounded error code and exponential backoff, capped at an hour. Crashes leave a 90-second lease that another worker can reclaim. There is no automatic terminal retry count that drops a paid event.

A lease has a random token and the customer's requested revision. New accepted events increment that revision. An older fetch cannot commit after a new event arrives, after its lease expires, or after another worker replaces the lease. Transfers track every source/destination; the event becomes processed only when all affected targets reconcile. Exact duplicate deliveries do not increment revisions.

This fence orders local work; **it does not create a canonical RevenueCat revision**. Customer lists and casing variants are separate provider reads, not an atomic provider snapshot. Provider/store propagation can lag a webhook. Periodic fresh reconciliation repairs later differences. There is no claim of instantaneous cross-account/store consistency. A fetch failure, incomplete page, contradictory identity, or resource limit never applies a partial snapshot.

## Identity and environment

One database is pinned to one RevenueCat project and one environment by `private.billing_settings`. The first authenticated accept/claim initializes it; mismatches subsequently fail. Use separate Supabase environments for sandbox and production. Sandbox receipts cannot replace production state. Transfers/redemptions trigger the configured environment's reconciliation even when their notification also mentions a different environment; they do not import that environment's receipts.

Current iOS passes `UUID.uuidString` to RevenueCat (uppercase); web and Android use lowercase UUIDs. Jobs normalize a syntactically valid UUID to the Supabase account key but **retain exact provider IDs**. A profile must exist before lookup or output writes. Each claim probes both current-client spellings, plus exact IDs previously observed or explicitly verified by an operator. The provider's read-only v2 resource endpoints do not create missing customers. Only a 404 on a variant's *first* request is treated as an absent customer; all variants absent, or a 404 on a later resource/page, is a retryable failure.

The worker unions active grants across those variants and deduplicates store receipts before expanding quantity into pass units. A new spelling arriving during a lease increments the account revision and fences that lease. The original event retains its exact identity and transaction metadata. An arbitrary webhook `aliases` or `original_app_user_id` value is never an account ownership proof. Case normalization applies only when both compared IDs are syntactically valid UUIDs. Verified custom IDs such as `CustomUser` must match exactly; `customuser` is a different identity. A resource naming the verified canonical UUID is also accepted for that mapped custom lookup.

Non-UUID/custom/anonymous identities are durably quarantined. A trusted operator can use `resolve_identity` only after verifying the customer-to-account relationship outside this pipeline; it requires an existing profile and a verification reference. The mapping and first verification time are retained in `private.billing_identity_links`. Mapping one UUID to a different UUID, or changing an existing mapping to another account, fails. Accepted target records move to the verified account's queue; original event data remains unchanged. Future notifications use the same verified mapping.

Both standard UUID spellings are probed during backfill even before a new notification arrives. Older clients using another mixed spelling or a custom ID require provider-verified discovery and explicit mapping/queuing. The system cannot enumerate every possible custom alias. Do not declare that account backfilled until its known purchase identities have been checked against provider evidence. More than eight candidate IDs or a large/incomplete provider result stays retryable for operator investigation rather than being truncated.

## Billing contract version 1

The private tables are not exposed through the Data API. Their functions use invoker privileges, empty search paths and explicit service-role grants. End users cannot execute `public.billing_admin` or inspect the inbox/identity map. No calendar grants or poll policies are changed.

| Output | Contract |
| --- | --- |
| `private.billing_entitlements` | Current relevant active grants, including both `pro_access` and `team_access`, with resource/product/store/transaction identity, canonical `expires_at`, and bounded `valid_until`. Promotional grants use their canonical RevenueCat resource/entitlement identity; `product_id` and a missing store receipt remain null for `PROMOTIONAL`, with no invented purchase identity. Inactive promotional resources cannot block an unrelated paid grant. A provider `gives_access` grace-period result can remain active when canonical period expiry is past. |
| `private.billing_effective_entitlement(uuid)` | Backend-only current tier; checks time per grant, prefers team, falls back to pro as individual grants expire. F05 should use this contract inside its transaction. |
| `public.subscriptions` | One compatible row per account; `billing_contract_version=1`, environment and reconciliation metadata. Strongest currently valid tier projects to the existing `entitlement`/`is_active` fields. `product_id` is now the RevenueCat v2 product ID, and `original_transaction_id` the store subscription/purchase identifier. `revenuecat_app_user_id` is the canonical account key; exact lookup IDs live privately. Unknown renewal/cancellation fields remain null. |
| `subscriptions.expires_at` and `access_valid_until` | **Access-decision horizon, not renewal/period-end date.** At most 15 minutes from snapshot time and no later than a known future canonical expiry. Expiry-aware legacy helpers fail closed during worker outages. Multiple grants remain private; a public strongest-tier row can temporarily understate a lower surviving tier until reconciliation. |
| `public.event_passes` | One durable row per `(project,environment,store,product,store_transaction_id,purchase_unit)`. `transaction_id` is an opaque `rc2:` namespaced identity; never parse it in clients. `revenuecat_purchase_id` retains RevenueCat's resource ID. `purchase_unit` is 1..quantity. Receipt ownership changes preserve the row ID, redemption time and linked poll. |
| Available pass | `billing_project_id IS NOT NULL AND revoked_at IS NULL AND redeemed_at IS NULL AND verified_until > now()`. F05 must lock/recheck the row and redeem it in the poll-creation transaction. Revocation alone never restores a spent unit. |
| Refund/not owned | Existing managed units absent from a complete owned snapshot receive `revoked_at` and `revocation_reason='not_owned'`; refund reversal can reactivate an unspent unit after canonical confirmation. Spent IDs/poll links survive both transitions. Refunds of already spent passes do not delete polls; product policy for that case belongs with F05. |
| Legacy data | Migration disables unverified subscription access, quarantines legacy passes with `legacy_unverified`, and queues affected users. No product/environment is guessed. A legacy pass blocks that user's output transaction until its receipt mapping is explicitly verified. |

Existing web/Swift/Kotlin subscription models accept the additive columns and nullable existing fields; their date fields remain nullable ISO timestamps. Source inspection found no UI that displays the database `expires_at` as a renewal date and no client that queries pass availability directly. Existing client premium convenience properties can still cache a bare boolean; they are not authorization. Keep using RevenueCat customer info for purchase UI, and use backend timed decisions for F05. No shared client source was changed here.

`public.count_unredeemed_passes(uuid DEFAULT auth.uid())` keeps the F02 caller shape, invoker/search-path/grant hardening, and denies null/missing/mismatched caller IDs. It applies the full available-pass predicate. The inline self guard allows isolated F08 replay as well as F02-then-F08 replay. No other existing exposed RPC is redefined by F08.

## Required hosted setup and rollout

1. Review/replay F02 (`20261022181851_privileged_rpc_authorization.sql`) then F08 (`20261022181918_durable_billing_webhooks.sql`) together in a disposable staging database. Keep `private` outside exposed schemas; inspect actual table/function grants and run hosted database advisors. PGlite is not a check of PostgREST/gateway configuration.
2. Before applying F08 in production, inventory existing billing users and legacy receipts, retain a controlled recovery snapshot, and arrange a billing maintenance window. Stop/disable the old direct-write handler **before applying the migration** so an old invocation cannot overwrite the new projection. Preserve/resend provider deliveries during the window. The migration intentionally fails old access closed; prepare identity/receipt evidence and the worker first to keep backfill short. Do not enable F05 paid rollout on an unverified backfill.
3. Configure the secrets below, apply the migration, and deploy `billing-worker` and the new `revenuecat-webhook`. Both have `verify_jwt=false` in `config.toml` and authenticate their own distinct server credentials. Verify that no old handler invocation remains before backfill.
4. Install and verify the worker schedule **before routing paid notifications to the new accepting handler**. Invoke the worker repeatedly to drain the migration-seeded queue. Resolve unknown identities and map legacy receipts with provider evidence as described below. If RevenueCat delivery was paused, resend retained failures/events through its dashboard after the durable handler is available.
5. Check both casing variants and all known verified custom identities for affected users; compare subscriptions, owned/refunded purchases, quantities and redeemed units with canonical provider evidence. Verify fresh `reconciled_at` values, zero unexplained pending/quarantined rows and correct available-pass counts before completing backfill.
6. Test real sandbox purchase, renewal, voluntary cancellation, grace/expiry, refund/reversal, restore/transfer and duplicate delivery through the hosted gateway in a separate sandbox database. Then verify production key scopes, schedule health and gateway responses with the owner. These external checks have **not** been run for this branch.

| Secret | Value |
| --- | --- |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Server environment only. Service key never goes to RevenueCat or clients. |
| `REVENUECAT_PROJECT_ID` | Intended RevenueCat project ID. |
| `REVENUECAT_BILLING_ENVIRONMENT` | Exactly `production` or `sandbox`. |
| `REVENUECAT_APP_IDS` | Nonempty JSON array of allowed app IDs, e.g. `["app_example"]`. |
| `REVENUECAT_EVENT_PASS_PRODUCT_IDS` | Explicit JSON array of **v2 `prod...` IDs**, not store SKUs. Use `[]` only after confirming there are no event-pass products. Wrong/missing classification must be fixed before paid rollout. |
| `REVENUECAT_SECRET_API_KEY` | V2 secret key with `customer_information:subscriptions:read` and `customer_information:purchases:read`. A v1/public SDK key will not work. No write permission is needed. |
| `REVENUECAT_WEBHOOK_AUTH` | Exact high-entropy Authorization header configured on the webhook. |
| `REVENUECAT_WEBHOOK_SIGNING_SECRET` | Optional integration HMAC secret; when set, unsigned deliveries are rejected. Enable on both ends together. |
| `REVENUECAT_BILLING_WORKER_AUTH` | Separate high-entropy exact Authorization header used only by the scheduler/worker. |

The accepting webhook can retain work while the provider API key is missing/unavailable. Missing required project/environment/app/product classification configuration returns 503 before acceptance. Worker/provider failures cannot erase accepted events. Fix configuration and drain/replay the queue; do not restore the old overwrite-on-notification handler.

## Scheduling and capacity

The worker processes one account per authenticated POST, including periodic reconciliation even without notifications. Paid decisions and pass verification expire within 15 minutes. **A one-call-per-minute schedule supports fewer than 14 continuously refreshed accounts**, with fewer still during retries or backlog. Provision enough invocations to drain new work and refresh every tracked account before its deadline; monitor and increase concurrency with observed load. This branch has no production capacity/load measurement.

Supabase supports `pg_cron` + `pg_net` with secrets in Vault. For example, after an operator creates `billing_project_url` and `billing_worker_auth` Vault entries and enables the relevant hosted extensions, the following reviewed template schedules five independent leases per minute. Choose capacity for the actual account count/provider rate budget. It is intentionally not an automatic migration and was not executed here.

```sql
select cron.schedule('billing-worker-every-minute', '* * * * *', $schedule$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='billing_project_url') || '/functions/v1/billing-worker',
    headers := jsonb_build_object('Content-Type','application/json',
      'Authorization',(select decrypted_secret from vault.decrypted_secrets where name='billing_worker_auth')),
    body := '{}'::jsonb,
    timeout_milliseconds := 80000
  ) from generate_series(1,5);
$schedule$);
```

Each account probes at least two casing variants, and pagination can consume more requests. Honor RevenueCat 429 `Retry-After`; the worker persists backoff. Calls share a 60-second provider deadline per claim; leases expire at 90 seconds. The handler also bounds individual response size, pages, items and candidate IDs. A large customer needs operator investigation or a deliberate bound/capacity change, never a partial import. Monitor scheduler responses independently: persisted queue failures remain after RevenueCat has received its 200.

## Recovery and diagnostics

Run the following only in a trusted backend/operator SQL context. Clients have no execution permission. Initialize settings through a correctly configured worker claim or accepting handler before using repair actions. Use actual verified identifiers, and put a ticket/evidence reference rather than email or credentials in provenance.

```sql
-- Explicit fresh reconciliation/backfill; exact case is retained for lookup.
select public.billing_admin('queue_customer', '{"customer_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}');

-- Missing profile: create/repair it through normal auth provisioning, then replay.
-- Unknown event: review its type first; replay fetches current state, never grants from event fields.
select public.billing_admin('replay_event', '{"event_id":"event-id"}');

-- Anonymous/custom identity: verify outside the pipeline, then link and drain.
select public.billing_admin('resolve_identity', '{"provider_customer_id":"$RCAnonymousID:verified-id","user_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","verification_reference":"billing-review-ticket-123"}');

-- Legacy pass: confirm product/environment/store receipt and purchased unit.
-- This preserves id/redeemed_at/poll_id and remains revoked until reconciliation.
select public.billing_admin('adopt_legacy_pass', '{"pass_id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","purchase_id":"purch_verified","product_id":"prod_verified","store":"APP_STORE","transaction_id":"verified-store-receipt"}');
select public.billing_admin('queue_customer', '{"customer_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}');
```

Identity resolution moves existing accepted targets into the verified account's queue. Replaying the original event later uses the same audited mapping. An existing map cannot be redirected to a different account. If an old pass cannot be matched, leave it quarantined and investigate; do not clear `revoked_at`, delete a spent row, invent a transaction ID, or mint replacement credit. Conflicting legacy/provider identities fail their unique constraints and retain pending work. Unmatched legacy passes can delay subscriptions for that account because output writes deliberately remain atomic.

For an expired/killed worker, wait for its lease to expire and invoke the worker again. Ordinary provider/storage failures retry automatically after backoff; `replay_event` or `queue_customer` requests earlier fresh work without applying saved stale snapshots. Duplicate webhook deliveries after success remain harmless. Deleted/missing profiles retain diagnostic work and receive no grant; investigate repeated failures rather than discarding the inbox.

Inspect aggregate state without logging event bodies or identifiers publicly:

```sql
select status,count(*),min(received_at) from private.billing_inbox group by status;
select last_error_code,count(*),min(next_attempt_at) from private.billing_customers
  where last_error_code is not null and last_error_code<>'identity_resolved' group by last_error_code;
select count(*) as overdue from private.billing_customers where not paused and next_attempt_at < now()-interval '2 minutes';
select count(*) as legacy_unmatched from public.event_passes where billing_project_id is null;
select count(*) as expired_decisions from public.subscriptions
  where is_active and access_valid_until<=now();
```

Alert on scheduler absence, growing pending age, any new quarantine/conflicting ID, persistent provider 401/403/429, or expired paid decisions. Structured Edge logs contain component/error codes only, not authorization headers, payloads, emails, receipt IDs or provider/database error bodies. The private inbox retains deduplication IDs and minimal processing metadata; there is no automatic destructive retention cleanup. Define backup/access/retention policy before pruning it, since deleting identities/receipt rows can compromise replay or spent-unit deduplication.

## Validation and references

Offline commands (no listeners, Docker, local Supabase stack, simulators, or live provider calls):

```bash
npm ci --offline --ignore-scripts --no-audit --no-fund
npm run test:billing:db
npm run test:billing:edge
npm run test:calendar:db
npm run test:calendar:edge
deno check --frozen --config supabase/functions/deno.json supabase/functions/revenuecat-webhook/index.ts supabase/functions/billing-worker/index.ts
deno lint --config supabase/functions/deno.json supabase/functions/_shared/billing supabase/functions/revenuecat-webhook supabase/functions/billing-worker
git diff --check
```

The PGlite suite replays all historical migrations with explicit API-style grants and real role execution. It covers duplicate/conflicting acceptance, storage rollback, expiry, operator identity/legacy recovery, transferred/spent quantities and stale/expired leases. Deno tests use mocked read-only provider pages and deny network/environment access. The calendar suites guard the merged credential implementation; their table-count assertion is scoped to calendar objects so billing can share the unexposed schema.

October 22 local results: **15 billing database, 15 billing Edge, 12 calendar database, and 23 calendar Edge tests passed**, along with billing type/lint/format checks. A separate temporary in-process harness replayed F02 commit `f86d55cfab9236a1c5dd045c58f59ef71d73e1a6` before F08 and passed all **44 database tests** (17 RPC, 15 billing, 12 calendar). Neither worktree was merged for that check. CI now has a separate billing workflow; hosted CI/deployment has not been run for this local commit.

Official documentation checked October 22, 2026: [RevenueCat webhook authentication/retries/reconciliation](https://www.revenuecat.com/docs/integrations/webhooks), [event fields and transfers](https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields), [v2 permissions/pagination](https://www.revenuecat.com/docs/api-v2), [customer subscriptions/purchases](https://www.revenuecat.com/docs/api-v2/customer/resources), [gives_access and grace](https://www.revenuecat.com/docs/api-v2/subscription-data-model), [Supabase function grants/search paths](https://supabase.com/docs/guides/database/functions), [function configuration](https://supabase.com/docs/guides/functions/function-configuration), and [scheduling with Vault](https://supabase.com/docs/guides/functions/schedule-functions). Supabase's changelog was checked for relevant breaking changes. No hosted advisor, PostgREST/gateway, actual key scopes, live provider result, scheduler or purchase flow was verified locally.
