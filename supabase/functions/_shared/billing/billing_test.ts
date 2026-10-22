import assert from "node:assert/strict";
import {
  BillingConfig,
  BillingError,
  BillingRepository,
  Claim,
  Snapshot,
} from "./types.ts";
import { parseEvent, webhookHandler } from "./webhook.ts";
import { fetchSnapshot } from "./provider.ts";
import { processOne, workerHandler } from "./worker.ts";

const alice = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const bob = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const now = 1792692000000;
const config: BillingConfig = {
  projectId: "proj_test",
  environment: "production",
  appIds: ["app_test"],
  passProductIds: ["prod_pass"],
  webhookAuth: "Bearer webhook-secret",
  workerSecret: "Bearer worker-secret",
  apiKey: "sk_fixture_only",
};
const envelope = (extra: Record<string, unknown> = {}) => ({
  api_version: "1.0",
  event: {
    id: "event_fixture",
    type: "RENEWAL",
    app_id: "app_test",
    app_user_id: alice,
    event_timestamp_ms: now,
    environment: "PRODUCTION",
    ...extra,
  },
});
const request = (
  body: unknown = envelope(),
  headers: Record<string, string> = {},
) =>
  new Request("https://function.example.test", {
    method: "POST",
    headers: {
      Authorization: config.webhookAuth!,
      "Content-Type": "application/json",
      ...headers,
    },
    body: JSON.stringify(body),
  });
const list = (items: unknown[] = [], next_page: string | null = null) => ({
  object: "list",
  items,
  next_page,
});
const entitlement = (lookup_key: string) => ({
  state: "active",
  project_id: config.projectId,
  lookup_key,
});
const subscription = (extra: Record<string, unknown> = {}) => ({
  id: "sub_fixture",
  customer_id: alice,
  product_id: "prod_sub",
  starts_at: now - 86400000,
  ends_at: now + 86400000,
  store_subscription_identifier: "store-subscription",
  gives_access: true,
  environment: "production",
  store: "app_store",
  status: "active",
  entitlements: list([entitlement("pro_access")]),
  ...extra,
});
const purchase = (extra: Record<string, unknown> = {}) => ({
  id: "purch_fixture",
  customer_id: alice,
  product_id: "prod_pass",
  purchased_at: now - 3600000,
  store_purchase_identifier: "store-receipt",
  quantity: 1,
  status: "owned",
  environment: "production",
  store: "app_store",
  entitlements: list(),
  ...extra,
});
const snapshot = (): Snapshot => ({
  environment: "production",
  fetched_at: new Date(now).toISOString(),
  valid_until: new Date(now + 900000).toISOString(),
  entitlements: [],
  passes: [],
});
const claim = (extra: Partial<Claim> = {}): Claim => ({
  customer_id: alice,
  provider_customer_ids: [alice],
  profile_exists: true,
  revision: 1,
  lease_id: "lease_fixture",
  ...extra,
});
class Repository implements BillingRepository {
  calls: { action: string; data: Record<string, unknown> }[] = [];
  nextClaim: Claim | null = claim();
  error?: string;
  outcome = "applied";
  call<T>(action: string, data: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ action, data });
    if (this.error && ["accept", "complete"].includes(action)) {
      return Promise.reject(new BillingError(this.error));
    }
    return Promise.resolve(
      (action === "claim"
        ? this.nextClaim
        : action === "complete"
        ? this.outcome
        : true) as T,
    );
  }
}
function fakeProvider(
  routes: Record<string, unknown>,
  calls: URL[] = [],
): typeof fetch {
  return ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(
      input instanceof Request ? input.url : input.toString(),
    );
    calls.push(url);
    assert.equal(url.origin, "https://api.revenuecat.com");
    assert.equal(
      (init?.headers as Record<string, string>).Authorization,
      `Bearer ${config.apiKey}`,
    );
    assert.equal(init?.redirect, "error");
    const value = routes[url.pathname + url.search] ?? routes[url.pathname];
    assert.notEqual(
      value,
      undefined,
      `Unexpected fixture path ${url.pathname}${url.search}`,
    );
    return Promise.resolve(
      value instanceof Response ? value : Response.json(value),
    );
  }) as typeof fetch;
}
const customer = `/v2/projects/${config.projectId}/customers/${alice}`;
const resource =
  `/v2/projects/${config.projectId}/subscriptions/sub_fixture/entitlements`;

Deno.test("webhook authenticates, rejects wrong methods/configuration and never leaks request data", async () => {
  const repo = new Repository();
  const handler = webhookHandler(config, repo);
  assert.equal(
    (await handler(request(envelope(), { Authorization: "Bearer wrong" })))
      .status,
    401,
  );
  assert.equal(
    (await handler(new Request("https://example.test", { method: "GET" })))
      .status,
    405,
  );
  assert.equal(
    (await webhookHandler({ ...config, webhookAuth: undefined }, repo)(
      request(),
    )).status,
    503,
  );
  assert.equal(repo.calls.length, 0);
});

Deno.test("payload validation rejects malformed/missing IDs, timestamps, API versions, invalid JSON and oversized bodies before acceptance", async () => {
  const repo = new Repository();
  const handler = webhookHandler(config, repo);
  for (
    const body of [
      null,
      {},
      { ...envelope(), api_version: "2.0" },
      envelope({ id: null }),
      envelope({ id: "" }),
      envelope({ event_timestamp_ms: "today" }),
      envelope({ event_timestamp_ms: -1 }),
      envelope({ app_id: "app_other" }),
      envelope({ type: "TRANSFER", transferred_from: [alice] }),
    ]
  ) assert.equal((await handler(request(body))).status, 400);
  assert.equal(
    (await handler(request(envelope(), { "Content-Type": "text/plain" })))
      .status,
    415,
  );
  assert.equal(
    (await handler(request({ junk: "x".repeat(270000) }))).status,
    413,
  );
  const invalid = new Request("https://example.test", {
    method: "POST",
    headers: {
      Authorization: config.webhookAuth!,
      "Content-Type": "application/json",
    },
    body: "{",
  });
  assert.equal((await handler(invalid)).status, 400);
  assert.equal(repo.calls.length, 0);
});

Deno.test("acceptance strips subscriber attributes and waits for durable storage; conflicts and database failures return retryable failure", async () => {
  const repo = new Repository();
  const body = envelope({
    subscriber_attributes: { email: "private@example.test" },
    aliases: [bob],
    original_app_user_id: bob,
  });
  assert.equal((await webhookHandler(config, repo)(request(body))).status, 200);
  assert.equal(repo.calls[0].action, "accept");
  const stored = repo.calls[0].data.event;
  assert.ok(!JSON.stringify(stored).includes("private@example.test"));
  assert.deepEqual((stored as { customer_ids: string[] }).customer_ids, [
    alice,
  ]);
  repo.error = "database_unavailable";
  assert.equal((await webhookHandler(config, repo)(request())).status, 503);
  repo.error = "event_conflict";
  assert.equal((await webhookHandler(config, repo)(request())).status, 409);
});

Deno.test("unknown/test/other-environment events have explicit dispositions; transfers reconcile both identities", () => {
  assert.equal(
    parseEvent(envelope({ type: "NEW_EVENT" }), config).disposition,
    "quarantined",
  );
  assert.equal(
    parseEvent(envelope({ type: "TEST" }), config).disposition,
    "ignored",
  );
  assert.equal(
    parseEvent(envelope({ environment: "SANDBOX" }), config).disposition,
    "ignored",
  );
  assert.deepEqual(
    parseEvent(
      envelope({
        type: "TRANSFER",
        app_user_id: null,
        environment: null,
        transferred_from: [bob, "$RCAnonymousID:old"],
        transferred_to: [alice],
      }),
      config,
    ).customer_ids,
    ["$RCAnonymousID:old", alice, bob],
  );
});

Deno.test("optional HMAC verifies original bytes and delivery timestamp in addition to shared authorization", async () => {
  const secret = "fixture-signing-secret";
  const raw = JSON.stringify(envelope());
  const timestamp = Math.floor(now / 1000);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = [
    ...new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(`${timestamp}.${raw}`),
      ),
    ),
  ].map((b) => b.toString(16).padStart(2, "0")).join("");
  const handler = webhookHandler(
    { ...config, signingSecret: secret },
    new Repository(),
    () => now,
  );
  const header = {
    "x-revenuecat-webhook-signature": `t=${timestamp},v1=${signature}`,
  };
  assert.equal((await handler(request(envelope(), header))).status, 200);
  assert.equal(
    (await handler(request(envelope({ id: "changed" }), header))).status,
    401,
  );
  assert.equal(
    (await handler(
      request(envelope(), {
        "x-revenuecat-webhook-signature": `t=${
          timestamp - 301
        },v1=${signature}`,
      }),
    )).status,
    401,
  );
});

Deno.test("complete paginated subscription, purchase and nested entitlement lists retain all relevant grants and pass quantity", async () => {
  const calls: URL[] = [];
  const continuation = `${customer}/subscriptions?starting_after=sub_fixture`;
  const purchasesNext = `${customer}/purchases?starting_after=purch_fixture`;
  const nestedNext = `${resource}?starting_after=other`;
  const state = await fetchSnapshot(
    alice,
    config,
    fakeProvider({
      [`${customer}/subscriptions`]: list([
        subscription({
          entitlements: list([entitlement("unrelated")], nestedNext),
        }),
      ], continuation),
      [`${continuation}&environment=production`]: list([
        subscription({ id: "sub_second", gives_access: false }),
      ]),
      [`${nestedNext}`]: list([
        entitlement("team_access"),
        entitlement("pro_access"),
      ]),
      [`${customer}/purchases`]: list(
        [purchase({ quantity: 2 })],
        purchasesNext,
      ),
      [`${purchasesNext}&environment=production`]: list([
        purchase({ id: "purch_second", product_id: "prod_unrelated" }),
      ]),
    }, calls),
    () => now,
  );
  assert.deepEqual(state.entitlements.map((e) => e.entitlement).sort(), [
    "pro_access",
    "team_access",
  ]);
  assert.equal(state.passes.length, 1);
  assert.equal(state.passes[0].quantity, 2);
  assert.equal(calls.length, 5);
  assert.ok(
    calls.filter((url) => url.pathname.startsWith(customer)).every((url) =>
      url.searchParams.get("environment") === "production"
    ),
  );
});

Deno.test("a failed later page, malformed record, mismatched environment/identity or hostile continuation cannot produce a partial snapshot", async () => {
  const later = `${customer}/purchases?starting_after=purch_fixture`;
  for (
    const failure of [
      new Response("provider private message", { status: 503 }),
      new Response("missing page", { status: 404 }),
    ]
  ) {
    await assert.rejects(
      () =>
        fetchSnapshot(
          alice,
          config,
          fakeProvider({
            [`${customer}/subscriptions`]: list([subscription()]),
            [`${customer}/purchases`]: list([purchase()], later),
            [`${later}&environment=production`]: failure,
          }),
          () => now,
        ),
      (error) =>
        error instanceof BillingError &&
        error.code.startsWith("provider_http_"),
    );
  }
  for (
    const entry of [
      subscription({ gives_access: "yes" }),
      subscription({ environment: "sandbox" }),
      subscription({ customer_id: bob }),
    ]
  ) {
    await assert.rejects(() =>
      fetchSnapshot(
        alice,
        config,
        fakeProvider({
          [`${customer}/subscriptions`]: list([entry]),
          [`${customer}/purchases`]: list(),
        }),
        () => now,
      )
    );
  }
  await assert.rejects(
    () =>
      fetchSnapshot(
        alice,
        config,
        fakeProvider({
          [`${customer}/subscriptions`]: list(
            [],
            "https://attacker.example/steal",
          ),
        }),
        () => now,
      ),
    { code: "provider_invalid_pagination" },
  );
});

Deno.test("provider configuration, rate limits, and first-request missing-customer are distinct recoverable failures", async () => {
  await assert.rejects(
    () => fetchSnapshot(alice, { ...config, apiKey: undefined }),
    { code: "provider_not_configured" },
  );
  await assert.rejects(
    () =>
      fetchSnapshot(
        alice,
        config,
        fakeProvider({
          [`${customer}/subscriptions`]: new Response("", { status: 404 }),
        }),
      ),
    { code: "provider_customer_not_found" },
  );
  await assert.rejects(
    () =>
      fetchSnapshot(
        alice,
        config,
        fakeProvider({
          [`${customer}/subscriptions`]: new Response("", {
            status: 429,
            headers: { "Retry-After": "180" },
          }),
        }),
      ),
    { code: "provider_http_429", retryAfter: 180 },
  );
});

Deno.test("canonical gives_access handles grace, cancellation/pause, lifetime purchases, unrelated products and refunds", async () => {
  const state = await fetchSnapshot(
    alice,
    config,
    fakeProvider({
      [`${customer}/subscriptions`]: list([
        subscription({ status: "in_grace_period", ends_at: now - 1000 }),
        subscription({ id: "paused", status: "paused", gives_access: false }),
        subscription({
          id: "cancelled_but_paid",
          auto_renewal_status: "will_not_renew",
        }),
      ]),
      [`${customer}/purchases`]: list([
        purchase({ status: "refunded" }),
        purchase({ id: "unrelated", product_id: "other" }),
        purchase({
          id: "lifetime",
          product_id: "prod_lifetime",
          entitlements: list([entitlement("team_access")]),
        }),
      ]),
    }),
    () => now,
  );
  assert.equal(state.passes.length, 0);
  assert.equal(state.entitlements.length, 3);
  assert.equal(
    state.entitlements[0].valid_until,
    new Date(now + 900000).toISOString(),
  );
  assert.ok(
    state.entitlements.some((e) =>
      e.resource_id === "purchases/lifetime" && e.entitlement === "team_access"
    ),
  );
});

Deno.test("UUID case variants union their paid states and deduplicate the same receipt without multiplying quantity", async () => {
  const repo = new Repository();
  repo.nextClaim = claim({
    provider_customer_ids: [alice, alice.toUpperCase()],
  });
  const pro = subscription();
  const base = await fetchSnapshot(
    alice,
    config,
    fakeProvider({
      [`${customer}/subscriptions`]: list([pro]),
      [`${customer}/purchases`]: list([purchase({ quantity: 2 })]),
    }),
    () => now,
  );
  const second = structuredClone(base);
  second.entitlements[0].resource_id = "subscriptions/team";
  second.entitlements[0].entitlement = "team_access";
  await processOne(
    repo,
    config,
    (id) => Promise.resolve(id === alice ? base : second),
  );
  const output = repo.calls.find((c) => c.action === "complete")!.data
    .snapshot as Snapshot;
  assert.deepEqual(output.entitlements.map((e) => e.entitlement), [
    "pro_access",
    "team_access",
  ]);
  assert.equal(output.passes.length, 1);
  assert.equal(output.passes[0].quantity, 2);
});

Deno.test("absent casing variant is safe only on first request; any partial/later-page failure blocks complete", async () => {
  const repo = new Repository();
  repo.nextClaim = claim({
    provider_customer_ids: [alice, alice.toUpperCase()],
  });
  await processOne(
    repo,
    config,
    (id) =>
      id === alice
        ? Promise.reject(new BillingError("provider_customer_not_found"))
        : Promise.resolve(snapshot()),
  );
  assert.ok(repo.calls.some((c) => c.action === "complete"));
  repo.calls = [];
  assert.equal(
    await processOne(
      repo,
      config,
      (id) =>
        id === alice
          ? Promise.resolve(snapshot())
          : Promise.reject(new BillingError("provider_http_404")),
    ),
    "retry",
  );
  assert.ok(!repo.calls.some((c) => c.action === "complete"));
});

Deno.test("unknown identities and missing profiles fail durably before provider lookup", async () => {
  for (
    const [job, code] of [[
      claim({ customer_id: "$RCAnonymousID:test" }),
      "unknown_identity",
    ], [claim({ profile_exists: false }), "missing_profile"]] as const
  ) {
    const repo = new Repository();
    repo.nextClaim = job;
    assert.equal(
      await processOne(repo, config, () => {
        throw new Error("must not call provider");
      }),
      "retry",
    );
    assert.equal(repo.calls.find((c) => c.action === "fail")!.data.code, code);
  }
});

Deno.test("processing/provider errors retain work; stale completion and worker-secret checks are explicit", async () => {
  const repo = new Repository();
  repo.error = "database_unavailable";
  assert.equal(
    await processOne(repo, config, () => Promise.resolve(snapshot())),
    "retry",
  );
  assert.equal(repo.calls.at(-1)?.action, "fail");
  repo.error = undefined;
  repo.outcome = "stale";
  assert.equal(
    await processOne(repo, config, () => Promise.resolve(snapshot())),
    "stale",
  );
  const handler = workerHandler(config, repo);
  repo.calls = [];
  assert.equal((await handler(request())).status, 401);
  assert.equal(repo.calls.length, 0);
  repo.nextClaim = null;
  assert.equal(
    (await handler(request({}, { Authorization: config.workerSecret! })))
      .status,
    200,
  );
});
