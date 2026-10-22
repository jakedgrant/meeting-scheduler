# F02 and F08 combined validation

Validated by the coordinator on October 22, 2026, using frozen committed files. Feature branches and their worktrees were not merged or modified.

| Source | Commit |
| --- | --- |
| Common plan/calendar baseline | `29bbf439161a5f507d255e6e8288cad40b4a0f22` |
| F02 RPC authorization | `f86d55cfab9236a1c5dd045c58f59ef71d73e1a6` |
| F08 billing, including provider review fixes | `ec1238202d0760cd4a9d25ffaeae5ef8f97c7784` |

The snapshot starts from a Git archive of F08, overlays the exact committed F02 migration, RPC suite, and finding guide, and retains all three sets of package scripts. It uses the existing locked PGlite 0.5.11 dependency in process. [manifest.json](manifest.json) records source identities, method, temporary snapshot location, migration hash, and results.

| Check | Result | Full output |
| --- | --- | --- |
| Combined migration/database regression suites | 44 passed, zero failed: 15 billing, 12 calendar, 17 RPC | [Database output](combined-database-results.txt) |
| Billing and calendar Edge suites, with network/environment access denied | 38 passed, zero failed: 15 billing, 23 calendar | [Edge output](combined-edge-results.txt) |
| Billing and calendar entry-point type checks, frozen dependency lock | All seven passed | [Type-check output](entrypoint-check-results.txt) |

Commands ran from the isolated snapshot:

```bash
node --test --test-concurrency=1 tests/billing-database.test.mjs tests/calendar-database.test.mjs tests/rpc-authorization.test.mjs
deno test --cached-only --frozen --config supabase/functions/deno.json --deny-net --deny-env supabase/functions/_shared/billing/ supabase/functions/_shared/calendar/
deno check --frozen --config supabase/functions/deno.json supabase/functions/revenuecat-webhook/index.ts supabase/functions/billing-worker/index.ts supabase/functions/calendar-connection/index.ts supabase/functions/check-calendar-conflicts/index.ts supabase/functions/calendar-oauth-callback/index.ts supabase/functions/calendar-maintenance/index.ts supabase/functions/store-calendar-token/index.ts
```

The database suites execute actual anonymous/authenticated/service roles in PGlite's PostgreSQL 18.6 engine. Provider pages, credentials, and identities are synthetic fixtures. No simulator, emulator, local server, Docker/Supabase stack, or live provider customer API was used. Hosted engine/configuration, advisors, gateway behavior, provider key scopes, real purchases, worker scheduling, backfill, and deployed grants remain unverified.

The local features are ready for review in their separate branches. Before integration, retain `test:rpc:db` and the two billing scripts when resolving `package.json`. Before deployment, follow the feature guides and the [progress tracker](../architecture-remediation-progress.md). F03/F04 direct-table participant/membership bypasses remain separate work; these test results do not establish complete poll isolation.
