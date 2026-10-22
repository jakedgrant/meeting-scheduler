import {
  AcceptedEvent,
  BillingConfig,
  BillingError,
  BillingRepository,
  millis,
  record,
  string,
} from "./types.ts";

const reconcileTypes = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "CANCELLATION",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_PAUSED",
  "EXPIRATION",
  "BILLING_ISSUE",
  "PRODUCT_CHANGE",
  "SUBSCRIPTION_EXTENDED",
  "REFUND_REVERSED",
  "TRANSFER",
  "TEMPORARY_ENTITLEMENT_GRANT",
  "PURCHASE_REDEEMED",
]);

export async function constantTimeEqual(
  left: string,
  right: string,
): Promise<boolean> {
  const encode = new TextEncoder();
  const [a, b] = await Promise.all(
    [left, right].map((value) =>
      crypto.subtle.digest("SHA-256", encode.encode(value))
    ),
  );
  const aa = new Uint8Array(a), bb = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
}

export async function boundedBody(
  req: Pick<Request, "headers" | "body">,
  max = 256 * 1024,
): Promise<string> {
  if (Number(req.headers.get("content-length")) > max) {
    throw new BillingError("payload_too_large");
  }
  const reader = req.body?.getReader();
  if (!reader) throw new BillingError("invalid_payload");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > max) {
        await reader.cancel();
        throw new BillingError("payload_too_large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

async function verifySignature(
  req: Request,
  raw: string,
  secret: string,
  now: number,
): Promise<boolean> {
  const match = req.headers.get("x-revenuecat-webhook-signature")?.match(
    /^t=(\d+),v1=([a-f0-9]{64})$/,
  );
  if (!match || Math.abs(now / 1000 - Number(match[1])) > 300) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`${match[1]}.${raw}`),
  );
  const expected = [...new Uint8Array(bytes)].map((n) =>
    n.toString(16).padStart(2, "0")
  ).join("");
  return constantTimeEqual(expected, match[2]);
}

function identities(value: unknown): string[] {
  if (!Array.isArray(value) || !value.length || value.length > 100) {
    throw new BillingError("invalid_payload");
  }
  return value.map((id) => string(id));
}

export function parseEvent(
  value: unknown,
  config: BillingConfig,
): AcceptedEvent {
  const body = record(value);
  if (body.api_version !== "1.0") {
    throw new BillingError("unsupported_api_version");
  }
  const event = record(body.event);
  const type = string(event.type, 80);
  const id = string(event.id, 255);
  const timestamp = millis(event.event_timestamp_ms);
  const optional = (key: string, max = 1500) =>
    event[key] == null ? null : string(event[key], max);
  const appId = optional("app_id", 255);
  if (appId && !config.appIds.includes(appId)) {
    throw new BillingError("unexpected_app");
  }
  const environment = optional("environment", 32);
  if (environment && !["PRODUCTION", "SANDBOX"].includes(environment)) {
    throw new BillingError("invalid_payload");
  }
  let customers: string[] = [];
  if (type === "TRANSFER") {
    customers = [
      ...identities(event.transferred_from),
      ...identities(event.transferred_to),
    ];
  } else if (type === "PURCHASE_REDEEMED") {
    customers = [
      ...(event.redeemed_from == null ? [] : identities(event.redeemed_from)),
      ...(event.redeemed_by == null ? [] : identities(event.redeemed_by)),
    ];
    if (event.app_user_id != null) customers.push(string(event.app_user_id));
  } else if (event.app_user_id != null) customers = [string(event.app_user_id)];
  let disposition: AcceptedEvent["disposition"] = "pending";
  let reason: string | null = null;
  if (type === "TEST") {
    disposition = "ignored";
    reason = "test_event";
  } else if (!reconcileTypes.has(type)) {
    disposition = "quarantined";
    reason = "unknown_event_type";
  } else if (!customers.length) throw new BillingError("invalid_payload");
  // Transfers and temporary grants can omit app/environment. They trigger an
  // environment-filtered provider lookup; they never grant from event fields.
  if (
    !["TEST", "TRANSFER", "PURCHASE_REDEEMED"].includes(type) && environment &&
    environment.toLowerCase() !== config.environment
  ) {
    disposition = "ignored";
    reason = "other_environment";
  }
  return {
    id,
    type,
    event_timestamp_ms: timestamp,
    app_id: appId,
    environment,
    app_user_id: optional("app_user_id"),
    transaction_id: optional("transaction_id"),
    original_transaction_id: optional("original_transaction_id"),
    product_id: optional("product_id"),
    customer_ids: [...new Set(customers)].sort(),
    disposition,
    reason,
  };
}

export function response(status: number, code: string): Response {
  return Response.json({ code }, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

export function webhookHandler(
  config: BillingConfig,
  repo: BillingRepository,
  now = Date.now,
) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return response(405, "method_not_allowed");
    if (!config.webhookAuth) return response(503, "configuration_unavailable");
    if (
      !await constantTimeEqual(
        req.headers.get("authorization") ?? "",
        config.webhookAuth,
      )
    ) return response(401, "unauthorized");
    let event: AcceptedEvent;
    try {
      if (
        req.headers.get("content-type")?.split(";")[0].trim() !==
          "application/json"
      ) return response(415, "json_required");
      const raw = await boundedBody(req);
      if (
        config.signingSecret &&
        !await verifySignature(req, raw, config.signingSecret, now())
      ) return response(401, "invalid_signature");
      event = parseEvent(JSON.parse(raw), config);
    } catch (error) {
      const code = error instanceof BillingError
        ? error.code
        : "invalid_payload";
      return response(code === "payload_too_large" ? 413 : 400, code);
    }
    try {
      await repo.call("accept", {
        event,
        project_id: config.projectId,
        environment: config.environment,
      });
      return response(200, "accepted");
    } catch (error) {
      if (error instanceof BillingError && error.code === "event_conflict") {
        return response(409, "event_conflict");
      }
      // No payload, user identifiers, raw database/provider errors, or secrets.
      console.error(
        JSON.stringify({ component: "billing_webhook", code: "accept_failed" }),
      );
      return response(503, "accept_failed");
    }
  };
}
