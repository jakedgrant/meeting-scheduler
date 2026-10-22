import {
  BillingConfig,
  BillingError,
  Entitlement,
  millis,
  PassPurchase,
  record,
  Snapshot,
  string,
  uuidPattern,
} from "./types.ts";
import { boundedBody } from "./webhook.ts";

type Json = Record<string, unknown>;
const origin = "https://api.revenuecat.com";
const relevant = new Set(["pro_access", "team_access"]);

function sameIdentity(actual: string, expected: string): boolean {
  return uuidPattern.test(actual) && uuidPattern.test(expected)
    ? actual.toLowerCase() === expected.toLowerCase()
    : actual === expected;
}

// Fetch complete customer resource lists in ONE environment. A failed/truncated
// page must never become an empty, access-revoking snapshot.
export async function fetchSnapshot(
  customerId: string,
  config: BillingConfig,
  fetcher: typeof fetch = fetch,
  now = Date.now,
  canonicalUserId = customerId,
  signal: AbortSignal = AbortSignal.timeout(40_000),
): Promise<Snapshot> {
  if (!config.apiKey) throw new BillingError("provider_not_configured", 300);
  const root = `/v2/projects/${encodeURIComponent(config.projectId)}`;
  const customer = `${root}/customers/${encodeURIComponent(customerId)}`;
  let requests = 0;
  const get = async (url: URL): Promise<Json> => {
    if (++requests > 60) {
      throw new BillingError("provider_snapshot_limit", 3600);
    }
    let res: Response;
    try {
      res = await fetcher(url, {
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          Accept: "application/json",
        },
        redirect: "error",
        signal,
      });
    } catch {
      throw new BillingError("provider_unavailable");
    }
    if (!res.ok) {
      const retry = Number(res.headers.get("retry-after"));
      await res.body?.cancel();
      if (res.status === 404 && requests === 1) {
        throw new BillingError("provider_customer_not_found", 300);
      }
      throw new BillingError(
        `provider_http_${res.status}`,
        Number.isFinite(retry) && retry > 0 ? Math.min(retry, 3600) : 60,
      );
    }
    try {
      return record(JSON.parse(await boundedBody(res, 4 * 1024 * 1024)));
    } catch {
      throw new BillingError("provider_invalid_response", 300);
    }
  };
  const list = async (
    path: string,
    initial?: unknown,
    filterEnvironment = false,
  ): Promise<Json[]> => {
    const items: Json[] = [];
    const visited = new Set<string>();
    let page: Json | undefined = initial == null ? undefined : record(initial);
    let next: string | null = `${path}?limit=100${
      filterEnvironment
        ? `&environment=${config.environment}`
        : "&status=active"
    }`;
    while (next) {
      const url: URL = new URL(next, origin);
      if (
        url.origin !== origin || url.pathname !== path || url.username ||
        url.password || url.hash || visited.has(url.href)
      ) throw new BillingError("provider_invalid_pagination", 300);
      if (filterEnvironment) {
        url.searchParams.set("environment", config.environment);
      }
      if (visited.size >= 20) {
        throw new BillingError("provider_snapshot_limit", 3600);
      }
      visited.add(url.href);
      const current: Json = page ?? await get(url);
      page = undefined;
      if (current.object !== "list" || !Array.isArray(current.items)) {
        throw new BillingError("provider_invalid_response", 300);
      }
      items.push(...current.items.map(record));
      if (items.length > 2000) {
        throw new BillingError("provider_snapshot_limit", 3600);
      }
      next = current.next_page == null ? null : string(current.next_page, 4096);
    }
    return items;
  };
  const subscriptions = await list(
    `${customer}/subscriptions`,
    undefined,
    true,
  );
  const purchases = await list(`${customer}/purchases`, undefined, true);
  const snapshotTime = now();
  const validUntil = snapshotTime + 15 * 60_000;
  const entitlements: Entitlement[] = [];
  const passes: PassPurchase[] = [];
  const seen = new Set<string>();
  for (
    const [kind, resources] of [["subscriptions", subscriptions], [
      "purchases",
      purchases,
    ]] as const
  ) {
    for (const resource of resources) {
      const id = string(resource.id, 255);
      if (seen.has(`${kind}/${id}`)) {
        throw new BillingError("provider_duplicate_resource", 300);
      }
      seen.add(`${kind}/${id}`);
      if (resource.environment !== config.environment) {
        throw new BillingError("provider_environment_mismatch", 300);
      }
      if (
        typeof resource.customer_id !== "string" ||
        ![customerId, canonicalUserId].some((expected) =>
          sameIdentity(resource.customer_id as string, expected)
        )
      ) throw new BillingError("provider_identity_mismatch", 3600);
      let expires: number | null = null;
      if (kind === "subscriptions") {
        if (typeof resource.gives_access !== "boolean") {
          throw new BillingError("provider_invalid_response", 300);
        }
        if (!resource.gives_access) continue;
        expires = resource.ends_at === null ? null : millis(resource.ends_at);
      } else {
        string(resource.status, 80);
        if (resource.status !== "owned") continue;
      }
      const store = string(resource.store, 80).toUpperCase();
      const promotional = kind === "subscriptions" && store === "PROMOTIONAL";
      const product = promotional && resource.product_id === null
        ? null
        : string(resource.product_id, 255);
      const rawTransaction = resource[
        kind === "subscriptions"
          ? "store_subscription_identifier"
          : "store_purchase_identifier"
      ];
      if (
        !(promotional && rawTransaction == null) &&
        typeof rawTransaction !== "string" &&
        !(typeof rawTransaction === "number" &&
          Number.isSafeInteger(rawTransaction) && rawTransaction >= 0)
      ) {
        throw new BillingError("provider_invalid_transaction", 300);
      }
      const transaction = promotional && rawTransaction == null
        ? null
        : string(String(rawTransaction), 1000);
      const purchased = millis(
        resource[kind === "subscriptions" ? "starts_at" : "purchased_at"],
      );
      if (
        kind === "purchases" && product !== null && transaction !== null &&
        config.passProductIds.includes(product)
      ) {
        const quantity = resource.quantity;
        if (
          typeof quantity !== "number" || !Number.isSafeInteger(quantity) ||
          quantity < 1 || quantity > 100
        ) {
          throw new BillingError("provider_invalid_quantity", 300);
        }
        passes.push({
          purchase_id: id,
          product_id: product,
          store,
          transaction_id: transaction,
          purchased_at: new Date(purchased).toISOString(),
          quantity,
        });
        continue;
      }
      const associated = await list(
        `${root}/${kind}/${encodeURIComponent(id)}/entitlements`,
        resource.entitlements,
      );
      for (const entitlement of associated) {
        if (entitlement.project_id !== config.projectId) {
          throw new BillingError("provider_project_mismatch", 300);
        }
        const key = string(entitlement.lookup_key, 255);
        if (!relevant.has(key) || entitlement.state !== "active") continue;
        // gives_access is authoritative during grace even when ends_at is past.
        const boundary = expires !== null && expires > snapshotTime
          ? Math.min(expires, validUntil)
          : validUntil;
        entitlements.push({
          resource_id: `${kind}/${id}`,
          entitlement: key as Entitlement["entitlement"],
          product_id: product,
          store,
          transaction_id: transaction,
          purchased_at: new Date(purchased).toISOString(),
          expires_at: expires == null ? null : new Date(expires).toISOString(),
          valid_until: new Date(boundary).toISOString(),
        });
      }
    }
  }
  return {
    environment: config.environment,
    fetched_at: new Date(snapshotTime).toISOString(),
    valid_until: new Date(validUntil).toISOString(),
    entitlements,
    passes,
  };
}
