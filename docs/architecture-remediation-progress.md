# Architecture remediation progress

Setup verified October 22, 2026. The [work sequence](architecture-review-2026-10-21.md#proposed-implementation-sequence) defines scope and dependencies. This file tracks the active workers and shared runtime reservations; the coordinator owns updates.

## Active work

Both workers started from `29bbf439161a5f507d255e6e8288cad40b4a0f22`, which contains the merged calendar remediation and the architecture work plan. Branches and worktree paths were verified with Git after setup.

| Finding | Worker task | Branch | Worktree | Latest progress |
| --- | --- | --- | --- | --- |
| F02: RPC authorization | [F02: Authorize database RPCs](codex://threads/01a164d4-109e-7a50-ad0e-ea921f381feb) | `codex/f02-rpc-authorization` | `/Users/jake/.codex/worktrees/a8fa/meeting-scheduler` | Active: RPC/caller inventory complete; implementing guarded compatible signatures and private access helpers. CLI migration allocated; offline validation planned. Resource rule acknowledged. |
| F08: Billing webhook reliability | [F08: Make billing webhooks reliable](codex://threads/01a164d4-4f33-76d0-960c-27dcad12e371) | `codex/f08-billing-webhooks` | `/Users/jake/.codex/worktrees/c5a4/meeting-scheduler` | Active: proposed private immutable inbox with leased canonical reconciliation/replay; preserving the public subscription projection. Resource rule acknowledged. |

Coordinator: [architecture review thread](codex://threads/01a164c2-5bc9-7272-b4be-5fe2147930c9), branch `codex/architecture-review`, checkout `/Users/jake/Developer/meeting-scheduler`.

Workers report setup, design, implementation, validation, blockers, migration filenames, and final local commits directly to the coordinator. During sustained work they report approximately every five minutes. Each worker implements and validates its assigned finding through local commits; pushing, PR creation, integration merges, and hosted deployment await a separate instruction.

## Ownership and integration

- **F02** owns existing poll/access RPCs, authorization helpers, their execute grants, necessary compatible callers, and focused authorization tests. F03/F04 remain separate follow-up work.
- **F08** owns the RevenueCat webhook, new private billing inbox/processing objects, subscription/event-pass processing, recovery instructions, and focused billing tests. F05 quota enforcement remains separate follow-up work.
- **Coordinated exception:** F08 owns the later compatibility update to `count_unredeemed_passes` after its revocation/verification metadata exists. It must preserve F02's hardened identity checks, signature, search path, and grants. F02's earlier migration remains independently replayable without the new billing columns. Revoked or quarantined passes must not be counted as available through legacy callers.
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
- [ ] Review F08's inbox/reconciliation design and output contract for F05.
- [x] Record migration filenames and verify allocated files have distinct version prefixes/ordering; combined replay remains pending.
- [ ] Review each worker's implementation, local commits, and focused validation evidence.
- [ ] Replay the combined migration history and verify calendar/security compatibility before any integration merge.

## Progress log

- **October 22, setup:** F02 and F08 independently verified the user's delegation/reporting authorization, created the assigned branches at the common baseline, and acknowledged that shared runtime access requires a reservation. Both began offline analysis; neither requested a runtime reservation.
- **October 22, initial coordination:** F08 proposed authoritative provider snapshot reconciliation, private entitlement/transaction/environment state, and a compatible public subscription projection with `team_access` precedence. The coordinator relayed this interface to F02 and requested concurrency/recovery tests from F08. The design remains subject to implementation review; no provider customer API or shared runtime use is authorized for validation.
- **October 22, F02 design:** allocated CLI migration `20261022181851_privileged_rpc_authorization.sql`. Proposed helpers live in unexposed `poll_private`, with guarded legacy signatures, owner/member summary access, and minimal active share-code preview. F02 changes authorization of read-only subscription/pass helpers, not billing storage, and avoids blanket grant changes. The coordinator relayed this boundary and migration version to F08. F03/F04 remain open.
- **October 22, F08 migration coordination:** allocated CLI migration `20261022181918_durable_billing_webhooks.sql`; its version is distinct and follows F02. Planned objects include a private billing inbox, reconciliation targets/customers/entitlements, and a service-only `billing_admin` dispatcher, plus additive public projection metadata. Pass availability must account for revocation and legacy identity quarantine. The coordinator assigned the later pass-count helper update to F08, preserving F02's authorization contract, and requested the canonical hardened definition from F02. Combined replay and final helper tests remain pending.
- **October 22, F02 contract handoff:** F02 supplied the compatible `count_unredeemed_passes(UUID DEFAULT auth.uid())` contract: stable invoker execution, empty search path, SQLSTATE `42501` for missing/NULL/mismatched identity, and self-service execute access restricted to authenticated callers. The coordinator forwarded it to F08, including independent-migration replay requirements and revoked/quarantined pass predicates, and requested actual-role helper/RLS execution tests from F02. Effective grant inventories must distinguish trigger functions from ordinary RPC exposure. Both migration files and their distinct ordering were independently verified; no shared runtime access has been requested or granted.
