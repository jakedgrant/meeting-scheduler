# Architecture remediation progress

Setup verified October 22, 2026. The [work sequence](architecture-review-2026-10-21.md#proposed-implementation-sequence) defines scope and dependencies. This file tracks the active workers and shared runtime reservations; the coordinator owns updates.

## Active work

Both workers started from `29bbf439161a5f507d255e6e8288cad40b4a0f22`, which contains the merged calendar remediation and the architecture work plan. Branches and worktree paths were verified with Git after setup.

| Finding | Worker task | Branch | Worktree | Latest progress |
| --- | --- | --- | --- | --- |
| F02: RPC authorization | [F02: Authorize database RPCs](codex://threads/01a164d4-109e-7a50-ad0e-ea921f381feb) | `codex/f02-rpc-authorization` | `/Users/jake/.codex/worktrees/a8fa/meeting-scheduler` | Active: migration and authorization tests drafted; worker reports 15 RPC tests and 12 calendar DB tests passing. Finding docs, final local commit, and combined-history verified-pass fixture remain pending. Resource rule acknowledged. |
| F08: Billing webhook reliability | [F08: Make billing webhooks reliable](codex://threads/01a164d4-4f33-76d0-960c-27dcad12e371) | `codex/f08-billing-webhooks` | `/Users/jake/.codex/worktrees/c5a4/meeting-scheduler` | Active: worker reports 12 actual-role billing DB tests passing; provider/casing/completeness fixtures and operational docs continue. Verified-pass fixture supplied. Existing calendar test compatibility update assigned; full regression validation pending. Resource rule acknowledged. |

Coordinator: [architecture review thread](codex://threads/01a164c2-5bc9-7272-b4be-5fe2147930c9), branch `codex/architecture-review`, checkout `/Users/jake/Developer/meeting-scheduler`.

Workers report setup, design, implementation, validation, blockers, migration filenames, and final local commits directly to the coordinator. During sustained work they report approximately every five minutes. Each worker implements and validates its assigned finding through local commits; pushing, PR creation, integration merges, and hosted deployment await a separate instruction.

## Ownership and integration

- **F02** owns existing poll/access RPCs, authorization helpers, their execute grants, necessary compatible callers, and focused authorization tests. F03/F04 remain separate follow-up work.
- **F08** owns the RevenueCat webhook, new private billing inbox/processing objects, subscription/event-pass processing, recovery instructions, and focused billing tests. F05 quota enforcement remains separate follow-up work.
- **Coordinated exception:** F08 owns the later compatibility update to `count_unredeemed_passes` after its revocation/verification metadata exists. It must preserve F02's hardened identity checks, signature, search path, and grants. F02's earlier migration remains independently replayable without the new billing columns. Revoked or quarantined passes must not be counted as available through legacy callers.
- **Calendar test compatibility:** F08 owns the narrow update to `tests/calendar-database.test.mjs` that scopes its three-table assertion to the named calendar tables. Additional private billing tables must retain separate RLS/privilege coverage; calendar security assertions must remain intact. F02 leaves this shared test file to F08.
- Workers report overlapping schema/function contracts before broadening scope. New migrations are additive and CLI-created. The coordinator checks distinct migration versions and combined replay before integration.
- Workers write finding-specific documentation in their own worktrees. The coordinator maintains this tracker and the shared architecture review. No worker edits the coordinator's or another worker's checkout.

## Shared runtime reservations

No simulator, emulator, or local-server reservation has been granted. Availability of any pre-existing resource is unverified; an absent reservation does not mean the resource is idle.

| Resource class | Reservation | Worker | Release |
| --- | --- | --- | --- |
| iOS simulators | None granted | — | — |
| Android emulators | None granted | — | — |
| Local servers, including Supabase/Docker databases and dev/preview/test servers | None granted | — | — |

Before querying or using a simulator/emulator, starting a local server, or connecting to an existing local service, the worker must request a reservation from the coordinator and wait for explicit approval. The request includes device ID or bind address/port, purpose, expected duration, and any install/reset/stop actions. Approval applies only to the named resource and actions. Workers report release when finished; elapsed time does not grant access. Occupied or user-owned resources must not be stopped or reset without permission.

Static checks, pure compilation, and isolated in-process PGlite/offline Deno tests that open no listening port can proceed without a reservation. While waiting for runtime access, workers continue independent offline work. Dependency setup must not silently start shared services or run an advisory inventory upload.

## Coordinator follow-ups

- [x] Commit the common work plan at `29bbf43`.
- [x] Verify both new branches and separate managed worktrees.
- [x] Receive both workers' progress-report and resource-rule acknowledgements.
- [x] Review F02's initial RPC inventory, access model, and compatibility direction; implementation review remains pending.
- [x] Review F08's initial inbox/reconciliation design and output contract direction for F05; implementation, freshness semantics, and recovery validation remain pending.
- [x] Record migration filenames and verify allocated files have distinct version prefixes/ordering; combined replay remains pending.
- [x] Receive F08's verified-pass fixture and relay required provider identity/freshness fields to F02.
- [ ] Confirm F02 retains a meaningful positive pass count after combined replay as well as independent baseline replay.
- [ ] Review each worker's implementation, local commits, and focused validation evidence.
- [ ] Replay the combined migration history and verify calendar/security compatibility before any integration merge.

## Progress log

- **October 22, setup:** F02 and F08 independently verified the user's delegation/reporting authorization, created the assigned branches at the common baseline, and acknowledged that shared runtime access requires a reservation. Both began offline analysis; neither requested a runtime reservation.
- **October 22, initial coordination:** F08 proposed authoritative provider snapshot reconciliation, private entitlement/transaction/environment state, and a compatible public subscription projection with `team_access` precedence. The coordinator relayed this interface to F02 and requested concurrency/recovery tests from F08. The design remains subject to implementation review; no provider customer API or shared runtime use is authorized for validation.
- **October 22, F02 design:** allocated CLI migration `20261022181851_privileged_rpc_authorization.sql`. Proposed helpers live in unexposed `poll_private`, with guarded legacy signatures, owner/member summary access, and minimal active share-code preview. F02 changes authorization of read-only subscription/pass helpers, not billing storage, and avoids blanket grant changes. The coordinator relayed this boundary and migration version to F08. F03/F04 remain open.
- **October 22, F08 migration coordination:** allocated CLI migration `20261022181918_durable_billing_webhooks.sql`; its version is distinct and follows F02. Planned objects include a private billing inbox, reconciliation targets/customers/entitlements, and a service-only `billing_admin` dispatcher, plus additive public projection metadata. Pass availability must account for revocation and legacy identity quarantine. The coordinator assigned the later pass-count helper update to F08, preserving F02's authorization contract, and requested the canonical hardened definition from F02. Combined replay and final helper tests remain pending.
- **October 22, F02 contract handoff:** F02 supplied the compatible `count_unredeemed_passes(UUID DEFAULT auth.uid())` contract: stable invoker execution, empty search path, SQLSTATE `42501` for missing/NULL/mismatched identity, and self-service execute access restricted to authenticated callers. The coordinator forwarded it to F08, including independent-migration replay requirements and revoked/quarantined pass predicates, and requested actual-role helper/RLS execution tests from F02. Effective grant inventories must distinguish trigger functions from ordinary RPC exposure. Both migration files and their distinct ordering were independently verified; no shared runtime access has been requested or granted.
- **October 22, F08 draft implementation:** acceptance, worker/replay, private billing storage, and additive projection metadata are drafted. F08 reports revision/lease fencing, transactional projection and target completion, verified pass freshness, and an inline self guard matching F02. Public subscription expiry becomes a bounded access decision (at most 15 minutes), with canonical provider expiry kept privately. The coordinator requested explicit contract/consumer documentation, multi-page failure tests, stale/concurrent worker tests, freshness-expiry checks, and real legacy/missing-profile recovery through offline replay/backfill. Test results and operational readiness are still pending; no live provider or shared runtime validation has been authorized.
- **October 22, F08 identity follow-up:** the worker found different UUID casing between native iOS and web/Android RevenueCat IDs. It is consolidating observed raw provider IDs under a canonical UUID job while retaining exact provider fetch identities and deduplicating receipts. The coordinator requested alphabetic-UUID fixtures, case-variant event races, union/deduplication tests, and a verified backfill procedure for variants without new events. Alias-based ownership inference remains disallowed; implementation and validation are pending.
- **October 22, F02 implementation/testing:** the worker reports `npm run test:rpc:db` passing 15 tests (14 scenarios plus the parent) and all 12 calendar database tests passing, using actual anonymous/authenticated/service roles. Reported coverage includes self/object authorization, legacy signatures, narrow previews, private-helper grants, RLS recursion, hostile search paths, trigger compatibility, and unchanged calendar security. The inventory now distinguishes 14 legacy effective execute grants (including three trigger-returning functions) from ordinary RPC exposure, and nine elevated ordinary functions plus the signup trigger. Final review/commit remain pending. The coordinator requested F08's exact verified-pass fixture so combined-history positive counts test authorization and billing validity together without making F02-only replay depend on future columns. No runtime resources were used.
- **October 22, billing fixture/testing:** F08 reports 12 actual-role billing DB tests passing, including transactional rollback, lease/revision fencing, missing-profile replay, transfer/quantity, expiry, and spent-pass adoption. Its positive count fixture requires complete provider identity, unredeemed/unrevoked state, and future `verified_until`; the coordinator relayed it and invalid-state comparisons to F02. Provider/casing/completeness cases remain in progress. The coordinator independently found the calendar suite's global three-private-table assumption and assigned F08 a narrow scoping fix plus a full calendar DB rerun. Combined-history tests and final commits remain pending; no shared runtime use was requested.
