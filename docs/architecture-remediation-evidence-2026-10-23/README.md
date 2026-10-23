# October 23 PR remediation evidence

The coordinator reviewed all ten open architecture PRs and dispatched isolated backend, web and iOS agents. Android command integration was completed by the coordinator. Backend and native changes received an independent source review after integration. All seven blocking findings from that review are addressed in the PR branches.

| Review gap | Fix and evidence |
| --- | --- |
| F10 had only backend commands; clients could show partial success | PR #69 now integrates web, iOS and Android full-set commands, persisted snapshots, draft retention, stable retries, explicit conflict review and option-based finalization. See response-commands.md and platform tests. |
| Account A's iOS state/cache could appear for B | PR #56 account-scoped persistence, lifecycle resets, generation checks and purchase identity guards; integrated into #69. |
| List loads renewed stale detail | Separate freshness/completeness; participant-only command results invalidate detail rather than renewing another participant's snapshot. |
| Deleted children or inaccessible polls could reappear | Authoritative scoped replacement, child/deletion reconciliation, list membership and request-generation checks. |
| Selected option could change after finalization | Poll-row serialization and selected-option update/delete rejection; parent deletion still cascades. |
| Storage failure lost the web guest capability; join retry changed identity | In-memory per-poll fallback and stable pending join token, with page-generation guards. |
| Claim/rotation could invalidate a credential while a waiting write still used it | Poll → participant → credential lock order and authorization recheck after waiting, before replay or mutation. |

## Reproducible checks

- Database: `npm run test:database` passed 94 PGlite checks over the complete migration history. Raw output: [backend-database-results.txt](backend-database-results.txt).
- Real database concurrency: 17 observed lock races passed on isolated PostgreSQL 18.4; the node runner counts 18 including the parent. [Raw output](backend-race-results.txt). CI repeats these races on PostgreSQL 17 and 18: [successful run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39918920181). Each race observes an actual `Lock` wait before releasing the winner.
- Web: 25 in-process controller/store/SSR tests, type check (zero errors; five existing warnings), and client/SSR build passed. [Successful web CI](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39918684010).
- Android: debug build and 15 JVM tests passed, including six new command-session tests. CI also passed missing-signing rejection, signing with a throwaway certificate and explicit unsigned opt-in: [successful run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39918920285). No emulator was used.
- iOS: 54 combined simulator tests passed at integrated client head `e8c895dfebbaa38cebf165ded91ae3d56fd4684c`: 23 provider, nine lifecycle, eleven editor, ten actual SDK transport and one existing baseline test. Package build-for-testing passed. See [cache evidence](../ios-persistence-evidence.md) and [command evidence](../ios-response-client-evidence.md). The committed package CI reruns these suites on PR changes and uploads logs and xcresult artifacts.

The local combined iOS test head contains coordinator integration `0ce4bc5a1f3ace656ef8473fa4be6acd2feedf83`. Subsequent integration adds the CI environment-context correction and documentation. The final PR head and current checks are available on [PR #69](https://github.com/jakedgrant/meeting-scheduler/pull/69); local results are not described as hosted end-to-end proof.

## Integration into main

Although all ten PRs were marked merged, #64/#66/#67/#68/#69 targeted feature branches and were absent from main `a03af56fe0cc6affd171693898d6b11f8e7913e9`. The integration branch merges tested #69 head `2cd63ab000f3f0b787e2dc27500876a0f08f3c96` into that main. That head includes every missing delivery. The [final #69 iOS run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39921603550), [Android run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39921603635), and [database/race run](https://github.com/jakedgrant/meeting-scheduler/actions/runs/39921603748) all passed. The integration PR repeats these checks on the combined tree.

## Original merge dependencies and resource release

Merge #63 → #64 → #66. PR #68 branches from #63. Merge #62 before #67. PR #69 includes those prerequisites plus #56, so merge #56, #67 and #68 before #69; GitHub will then remove their already merged changes from its diff. PR #61 is independent. Merge documentation PR #65 after the implementation branches. Preserve the existing stack bases until their parent PRs merge.

All runtime use was reserved with the coordinator. The fresh PostgreSQL instance was stopped and removed. The dedicated iOS simulator `2843684A-0993-42A5-A850-0B0B61942888` was shut down and deleted. Android used its own temporary build daemon/cache; no emulator or application server was started. Existing user runtimes and the original checkout were not changed.

## Prelaunch boundary

The application is unreleased. Source fixes and disposable test evidence support merging this work. Before launch, apply the ordered migrations in the target environment, verify effective hosted grants/RLS/RPC exposure, and exercise signed-in/native and browser guest journeys against that environment. Configure real Android release signing and verify a clean iOS app-wrapper archive for distribution. Local tests and throwaway CI signing do not establish those environment-specific facts. Broader open architecture findings (including other-platform account isolation, creation/pass redemption and provider workflows) remain tracked separately.
