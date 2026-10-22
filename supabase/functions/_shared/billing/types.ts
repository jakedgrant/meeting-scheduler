export type Environment = "production" | "sandbox";

export class BillingError extends Error {
  constructor(public code: string, public retryAfter = 60) {
    super(code);
  }
}

export interface BillingConfig {
  projectId: string;
  environment: Environment;
  appIds: string[];
  passProductIds: string[];
  apiKey?: string;
  webhookAuth?: string;
  signingSecret?: string;
  workerSecret?: string;
}

export interface AcceptedEvent {
  id: string;
  type: string;
  event_timestamp_ms: number;
  app_id: string | null;
  environment: string | null;
  app_user_id: string | null;
  transaction_id: string | null;
  original_transaction_id: string | null;
  product_id: string | null;
  customer_ids: string[];
  disposition: "pending" | "ignored" | "quarantined";
  reason: string | null;
}

export interface Claim {
  customer_id: string;
  provider_customer_ids: string[];
  profile_exists: boolean;
  revision: number;
  lease_id: string;
}

export interface Entitlement {
  resource_id: string;
  entitlement: "pro_access" | "team_access";
  product_id: string;
  store: string;
  transaction_id: string;
  purchased_at: string;
  expires_at: string | null;
  valid_until: string;
}

export interface PassPurchase {
  purchase_id: string;
  product_id: string;
  store: string;
  transaction_id: string;
  purchased_at: string;
  quantity: number;
}

export interface Snapshot {
  environment: Environment;
  fetched_at: string;
  valid_until: string;
  entitlements: Entitlement[];
  passes: PassPurchase[];
}

export interface BillingRepository {
  call<T>(action: string, data?: Record<string, unknown>): Promise<T>;
}

export const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new BillingError("invalid_payload");
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, max = 1500): string {
  if (
    typeof value !== "string" || !value.trim() || value.length > max ||
    [...value].some((char) => char.charCodeAt(0) < 32)
  ) {
    throw new BillingError("invalid_payload");
  }
  return value;
}

export function millis(value: unknown): number {
  if (
    typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 ||
    value > 8640000000000000
  ) {
    throw new BillingError("invalid_payload");
  }
  return value;
}
