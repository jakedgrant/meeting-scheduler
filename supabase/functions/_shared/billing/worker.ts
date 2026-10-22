import {
  BillingConfig,
  BillingError,
  BillingRepository,
  Claim,
  Snapshot,
  uuidPattern,
} from "./types.ts";
import { constantTimeEqual, response } from "./webhook.ts";
import { fetchSnapshot } from "./provider.ts";

export async function processOne(
  repo: BillingRepository,
  config: BillingConfig,
  provider: (
    customerId: string,
    config: BillingConfig,
    canonicalUserId: string,
    signal: AbortSignal,
  ) => Promise<Snapshot> = (customerId, settings, canonicalUserId, signal) =>
    fetchSnapshot(
      customerId,
      settings,
      fetch,
      Date.now,
      canonicalUserId,
      signal,
    ),
): Promise<"idle" | "applied" | "stale" | "retry"> {
  const claim = await repo.call<Claim | null>("claim", {
    project_id: config.projectId,
    environment: config.environment,
  });
  if (!claim) return "idle";
  try {
    if (!uuidPattern.test(claim.customer_id)) {
      throw new BillingError("unknown_identity", 3600);
    }
    if (!claim.profile_exists) throw new BillingError("missing_profile", 300);
    if (claim.provider_customer_ids.length > 8) {
      throw new BillingError("provider_snapshot_limit", 3600);
    }
    const signal = AbortSignal.timeout(60_000);
    const snapshots: Snapshot[] = [];
    for (const providerId of claim.provider_customer_ids) {
      try {
        if (signal.aborted) throw new BillingError("provider_unavailable");
        snapshots.push(
          await provider(providerId, config, claim.customer_id, signal),
        );
      } catch (error) {
        // Historical backfill may know only the lowercase Supabase UUID while
        // iOS used its uppercase spelling. A missing alias grants no access.
        // Every other failure aborts the whole snapshot, including later pages.
        if (
          !(error instanceof BillingError) ||
          error.code !== "provider_customer_not_found"
        ) throw error;
      }
    }
    if (!snapshots.length) throw new BillingError("provider_http_404", 300);
    const snapshot: Snapshot = {
      ...snapshots[0],
      entitlements: [],
      passes: [],
      valid_until: snapshots.map((s) => s.valid_until).sort()[0],
    };
    const entitlements = new Map<string, Snapshot["entitlements"][number]>();
    const passes = new Map<string, Snapshot["passes"][number]>();
    for (const state of snapshots) {
      for (const entry of state.entitlements) {
        const key = `${entry.resource_id}/${entry.entitlement}`;
        const previous = entitlements.get(key);
        if (previous && JSON.stringify(previous) !== JSON.stringify(entry)) {
          // Different request times are expected, conflicting purchase identity is not.
          if (
            previous.store !== entry.store ||
            previous.product_id !== entry.product_id ||
            previous.transaction_id !== entry.transaction_id
          ) throw new BillingError("provider_conflicting_aliases", 300);
          entry.valid_until =
            [previous.valid_until, entry.valid_until].sort()[0];
        }
        entitlements.set(key, entry);
      }
      for (const entry of state.passes) {
        const key = JSON.stringify([
          entry.store,
          entry.product_id,
          entry.transaction_id,
        ]);
        const previous = passes.get(key);
        if (previous && previous.quantity !== entry.quantity) {
          throw new BillingError("provider_conflicting_aliases", 300);
        }
        passes.set(key, entry);
      }
    }
    snapshot.entitlements = [...entitlements.values()];
    snapshot.passes = [...passes.values()];
    const result = await repo.call<string>("complete", { ...claim, snapshot });
    return result === "applied" ? "applied" : "stale";
  } catch (error) {
    const code = error instanceof BillingError
      ? error.code
      : "processing_failed";
    await repo.call("fail", {
      ...claim,
      code,
      retry_after: error instanceof BillingError ? error.retryAfter : 60,
      quarantine: [
        "unknown_identity",
        "provider_identity_mismatch",
        "legacy_pass_unmapped",
      ].includes(code),
    });
    console.error(JSON.stringify({ component: "billing_worker", code }));
    return "retry";
  }
}

export function workerHandler(config: BillingConfig, repo: BillingRepository) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return response(405, "method_not_allowed");
    if (!config.workerSecret) return response(503, "configuration_unavailable");
    if (
      !await constantTimeEqual(
        req.headers.get("authorization") ?? "",
        config.workerSecret,
      )
    ) return response(401, "unauthorized");
    try {
      // One bounded reconciliation per invocation. Concurrent calls lease
      // different customers; expired leases cannot overwrite newer work.
      const outcome = await processOne(repo, config);
      return response(outcome === "retry" ? 503 : 200, outcome);
    } catch {
      console.error(
        JSON.stringify({
          component: "billing_worker",
          code: "worker_unavailable",
        }),
      );
      return response(503, "worker_unavailable");
    }
  };
}
