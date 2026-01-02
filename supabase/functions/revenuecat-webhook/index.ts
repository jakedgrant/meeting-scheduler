import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface RevenueCatEvent {
  type: string
  app_user_id: string
  original_app_user_id?: string
  original_transaction_id?: string
  product_id?: string
  entitlement_ids?: string[]
  store?: string
  period_type?: string
  purchased_at_ms?: number
  expiration_at_ms?: number
  id?: string
}

interface WebhookPayload {
  event: RevenueCatEvent
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  // Verify RevenueCat authorization
  const authHeader = req.headers.get("Authorization")
  const expectedAuth = Deno.env.get("REVENUECAT_WEBHOOK_AUTH")

  if (!expectedAuth || authHeader !== expectedAuth) {
    console.error("Unauthorized webhook request")
    return new Response("Unauthorized", { status: 401, headers: corsHeaders })
  }

  // Initialize Supabase with service role (bypasses RLS)
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

  if (!supabaseUrl || !supabaseServiceKey) {
    console.error("Missing Supabase environment variables")
    return new Response("Server configuration error", { status: 500, headers: corsHeaders })
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey)

  try {
    const body: WebhookPayload = await req.json()
    const event = body.event

    if (!event) {
      return new Response("Invalid payload", { status: 400, headers: corsHeaders })
    }

    const appUserId = event.app_user_id
    const eventType = event.type

    console.log(`Processing ${eventType} for user ${appUserId}`)

    // Events that indicate active subscription
    const activeEvents = [
      "INITIAL_PURCHASE",
      "RENEWAL",
      "PRODUCT_CHANGE",
      "UNCANCELLATION",
      "SUBSCRIPTION_EXTENDED",
      "TEMPORARY_ENTITLEMENT_GRANT"
    ]

    // Events that indicate inactive subscription
    const inactiveEvents = ["EXPIRATION"]

    // Events that indicate pending cancellation (still active until expires)
    const cancellationEvents = ["CANCELLATION"]

    // Handle non-renewing purchases (consumables/event passes)
    if (eventType === "NON_RENEWING_PURCHASE") {
      const { error: passError } = await supabase
        .from("event_passes")
        .insert({
          user_id: appUserId,
          transaction_id: event.original_transaction_id || event.id,
          store: event.store,
          purchased_at: event.purchased_at_ms
            ? new Date(event.purchased_at_ms).toISOString()
            : new Date().toISOString()
        })

      if (passError && !passError.message.includes('duplicate')) {
        console.error("Error inserting event pass:", passError)
      }

      return new Response("OK", { status: 200, headers: corsHeaders })
    }

    // Determine subscription status
    let isActive = true
    let cancellationAt: string | null = null

    if (inactiveEvents.includes(eventType)) {
      isActive = false
    } else if (cancellationEvents.includes(eventType)) {
      isActive = true
      cancellationAt = event.expiration_at_ms
        ? new Date(event.expiration_at_ms).toISOString()
        : null
    }

    const entitlement = event.entitlement_ids?.[0] || null

    // Upsert subscription record
    const { error } = await supabase
      .from("subscriptions")
      .upsert({
        user_id: appUserId,
        revenuecat_app_user_id: event.original_app_user_id || appUserId,
        original_transaction_id: event.original_transaction_id,
        entitlement: isActive ? entitlement : null,
        is_active: isActive,
        product_id: event.product_id,
        store: event.store,
        period_type: event.period_type,
        purchased_at: event.purchased_at_ms
          ? new Date(event.purchased_at_ms).toISOString()
          : null,
        expires_at: event.expiration_at_ms
          ? new Date(event.expiration_at_ms).toISOString()
          : null,
        cancellation_at: cancellationAt,
        updated_at: new Date().toISOString()
      }, { onConflict: "user_id" })

    if (error) {
      console.error("Supabase upsert error:", error)

      // Foreign key violation = user doesn't exist yet
      // Return 200 so RevenueCat doesn't retry (not a recoverable error)
      if (error.code === "23503") {
        console.log(`User ${appUserId} not found in profiles - skipping`)
        return new Response("User not found - skipped", { status: 200, headers: corsHeaders })
      }

      return new Response("Database error", { status: 500, headers: corsHeaders })
    }

    console.log(`Successfully processed ${eventType} for ${appUserId}`)
    return new Response("OK", { status: 200, headers: corsHeaders })

  } catch (err) {
    console.error("Webhook processing error:", err)
    return new Response("Internal error", { status: 500, headers: corsHeaders })
  }
})
