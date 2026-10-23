import { billingRuntime } from "../_shared/billing/runtime.ts";

Deno.serve(billingRuntime("worker"));
