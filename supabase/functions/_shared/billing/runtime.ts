import { createClient } from "npm:@supabase/supabase-js@2.89.0";
import { BillingConfig, BillingError, BillingRepository } from "./types.ts";
import { response, webhookHandler } from "./webhook.ts";
import { workerHandler } from "./worker.ts";

function config(): BillingConfig {
  const required = (key: string) => {
    const value = Deno.env.get(key);
    if (!value) throw new BillingError("configuration_unavailable");
    return value;
  };
  const environment = required("REVENUECAT_BILLING_ENVIRONMENT");
  if (!["production", "sandbox"].includes(environment)) {
    throw new BillingError("configuration_unavailable");
  }
  const appIds: unknown = JSON.parse(required("REVENUECAT_APP_IDS"));
  const passProductIds: unknown = JSON.parse(
    required("REVENUECAT_EVENT_PASS_PRODUCT_IDS"),
  );
  if (
    !Array.isArray(appIds) || !appIds.length ||
    !Array.isArray(passProductIds) ||
    [...appIds, ...passProductIds].some((id) =>
      typeof id !== "string" || !id || id.length > 255
    )
  ) throw new BillingError("configuration_unavailable");
  return {
    projectId: required("REVENUECAT_PROJECT_ID"),
    environment: environment as BillingConfig["environment"],
    appIds,
    passProductIds,
    apiKey: Deno.env.get("REVENUECAT_SECRET_API_KEY"),
    webhookAuth: Deno.env.get("REVENUECAT_WEBHOOK_AUTH"),
    signingSecret: Deno.env.get("REVENUECAT_WEBHOOK_SIGNING_SECRET"),
    workerSecret: Deno.env.get("REVENUECAT_BILLING_WORKER_AUTH"),
  };
}

function repository(): BillingRepository {
  const url = Deno.env.get("SUPABASE_URL"),
    key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new BillingError("configuration_unavailable");
  const client = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return {
    async call<T>(
      action: string,
      data: Record<string, unknown> = {},
    ): Promise<T> {
      const { data: result, error } = await client.rpc("billing_admin", {
        p_action: action,
        p_data: data,
      });
      if (error) {
        const code = [
          "event_conflict",
          "missing_profile",
          "legacy_pass_unmapped",
        ].find((code) => error.message === code);
        throw new BillingError(
          code ?? "database_unavailable",
          code === "missing_profile" ? 300 : 60,
        );
      }
      return result as T;
    },
  };
}

export function billingRuntime(mode: "webhook" | "worker") {
  return async (req: Request): Promise<Response> => {
    try {
      const settings = config();
      return await (mode === "webhook"
        ? webhookHandler(settings, repository())
        : workerHandler(settings, repository()))(req);
    } catch {
      console.error(
        JSON.stringify({
          component: "billing_runtime",
          code: "configuration_unavailable",
        }),
      );
      return response(503, "configuration_unavailable");
    }
  };
}
