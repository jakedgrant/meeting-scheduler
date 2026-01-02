# Meeting Scheduler - Project Brief for Claude Code

## Project Overview

Build a multiplatform meeting scheduling service (similar to Doodle/When2meet) that allows groups of people to find common meeting times. The service will be available on iOS, Android, and Web.

### Key Requirements
- **Platforms**: iOS, Android, Web
- **Tech Stack**: Swift-first for mobile, TypeScript for web
- **Backend**: Supabase (PostgreSQL, Auth, Edge Functions, Realtime)
- **Mobile**: Skip.tools for iOS + Android code sharing (Swift)
- **Web**: SvelteKit with TypeScript
- **Billing**: RevenueCat (iOS, Android, Web via Stripe)

### Architecture: Supabase-Only (No Separate Backend Server)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CLIENT APPS                                       │
├───────────────────┬───────────────────┬─────────────────────────────┤
│    iOS (Swift)    │  Android (Skip)   │       Web (SvelteKit)       │
│                   │                   │                             │
│  Supabase SDK     │  Supabase SDK     │    Supabase JS SDK          │
│  RevenueCat SDK   │  RevenueCat SDK   │    RevenueCat Web SDK       │
└─────────┬─────────┴─────────┬─────────┴──────────────┬──────────────┘
          │                   │                        │
          └───────────────────┼────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          SUPABASE                                    │
│                                                                      │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│  │      Auth       │  │   PostgreSQL    │  │    Realtime     │     │
│  │                 │  │                 │  │                 │     │
│  │ • Google OAuth  │  │ • All tables    │  │ • Live poll     │     │
│  │ • Apple Sign-In │  │ • RLS policies  │  │   updates       │     │
│  │ • Magic Links   │  │ • Functions     │  │ • Presence      │     │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                     Edge Functions                           │   │
│  │                                                               │   │
│  │  • revenuecat-webhook (subscription sync)                    │   │
│  │  • send-notification (email/push on poll updates)            │   │
│  │  • finalize-poll (complex business logic)                    │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ Webhooks
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        REVENUECAT                                    │
│                                                                      │
│  • iOS subscriptions (App Store)                                    │
│  • Android subscriptions (Play Store)                               │
│  • Web Billing (Stripe)                                             │
│  • Cross-platform entitlement sync                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Business Model

### Subscription Tiers

| Tier | Monthly | Yearly | Features |
|------|---------|--------|----------|
| Free | $0 | $0 | 1 active poll, 10 participants/poll |
| Pro | $4.99 | $49.99 | Unlimited polls, calendar sync, 50 participants |
| Team | $9.99 | $99.99 | Everything + team workspace, analytics |

### Consumable Purchase
- **Event Pass** ($1.99): One-time premium poll with Pro features

### RevenueCat Configuration
- Entitlements: `pro_access`, `team_access`
- Products configured in App Store Connect, Google Play Console, and RevenueCat Web Billing

---

## Repository Structure

```
meeting-scheduler/
├── README.md
├── .gitignore
├── .env.example
│
├── packages/
│   └── shared-config/           # Shared configuration
│       ├── product-ids.json     # RevenueCat product identifiers
│       └── entitlements.json    # Entitlement definitions
│
├── apps/
│   ├── web/                     # SvelteKit web app
│   │   ├── package.json
│   │   ├── svelte.config.js
│   │   ├── vite.config.ts
│   │   ├── src/
│   │   │   ├── lib/
│   │   │   │   ├── supabase.ts
│   │   │   │   ├── revenuecat.ts
│   │   │   │   ├── stores/
│   │   │   │   │   ├── auth.ts
│   │   │   │   │   ├── subscription.ts
│   │   │   │   │   └── polls.ts
│   │   │   │   └── components/
│   │   │   │       ├── AvailabilityGrid.svelte
│   │   │   │       ├── Paywall.svelte
│   │   │   │       └── PollCard.svelte
│   │   │   └── routes/
│   │   │       ├── +layout.svelte
│   │   │       ├── +page.svelte
│   │   │       ├── auth/
│   │   │       ├── polls/
│   │   │       │   ├── +page.svelte
│   │   │       │   ├── new/
│   │   │       │   └── [id]/
│   │   │       └── settings/
│   │   └── static/
│   │
│   └── mobile/                  # Skip iOS + Android
│       ├── Package.swift
│       ├── Sources/
│       │   ├── Shared/          # Cross-platform Swift code
│       │   │   ├── Models/
│       │   │   │   ├── User.swift
│       │   │   │   ├── Poll.swift
│       │   │   │   ├── TimeOption.swift
│       │   │   │   ├── Participant.swift
│       │   │   │   └── Subscription.swift
│       │   │   ├── Services/
│       │   │   │   ├── SupabaseService.swift
│       │   │   │   ├── AuthService.swift
│       │   │   │   ├── PurchaseService.swift
│       │   │   │   └── PollService.swift
│       │   │   └── ViewModels/
│       │   │       ├── AuthViewModel.swift
│       │   │       ├── PollListViewModel.swift
│       │   │       ├── PollDetailViewModel.swift
│       │   │       └── PaywallViewModel.swift
│       │   │
│       │   ├── MeetingSchedulerApp/  # iOS app target
│       │   │   ├── App.swift
│       │   │   ├── Views/
│       │   │   │   ├── ContentView.swift
│       │   │   │   ├── AuthView.swift
│       │   │   │   ├── PollListView.swift
│       │   │   │   ├── PollDetailView.swift
│       │   │   │   ├── CreatePollView.swift
│       │   │   │   ├── AvailabilityGridView.swift
│       │   │   │   └── PaywallView.swift
│       │   │   └── Resources/
│       │   │
│       │   └── Skip/                 # Skip Android generation
│       │
│       └── Tests/
│
├── supabase/
│   ├── config.toml
│   ├── seed.sql                     # Test data
│   ├── migrations/
│   │   └── 00001_initial_schema.sql
│   └── functions/
│       ├── revenuecat-webhook/
│       │   └── index.ts
│       ├── send-poll-notification/
│       │   └── index.ts
│       └── _shared/
│           └── supabase-client.ts
│
└── scripts/
    └── setup-dev.sh
```

---

## Database Schema (Supabase PostgreSQL)

```sql
-- ============================================
-- MEETING SCHEDULER DATABASE SCHEMA
-- ============================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- PROFILES (extends auth.users)
-- ============================================
CREATE TABLE public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT NOT NULL,
    display_name TEXT,
    avatar_url TEXT,
    timezone TEXT DEFAULT 'UTC',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Auto-create profile on user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, display_name, avatar_url)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name'),
        NEW.raw_user_meta_data->>'avatar_url'
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================
-- SUBSCRIPTIONS (synced from RevenueCat)
-- ============================================
CREATE TABLE public.subscriptions (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL UNIQUE,
    
    -- RevenueCat identifiers
    revenuecat_app_user_id TEXT,
    original_transaction_id TEXT,
    
    -- Entitlement status
    entitlement TEXT, -- 'pro_access', 'team_access', or NULL
    is_active BOOLEAN DEFAULT FALSE,
    
    -- Subscription details
    product_id TEXT,
    store TEXT, -- 'APP_STORE', 'PLAY_STORE', 'STRIPE'
    period_type TEXT, -- 'NORMAL', 'TRIAL', 'INTRO', 'PROMOTIONAL'
    
    -- Dates
    purchased_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    cancellation_at TIMESTAMPTZ,
    
    -- Metadata
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX idx_subscriptions_expires_at ON public.subscriptions(expires_at);

-- ============================================
-- EVENT PASSES (consumable purchases)
-- ============================================
CREATE TABLE public.event_passes (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    
    -- Purchase info
    transaction_id TEXT NOT NULL UNIQUE,
    store TEXT NOT NULL,
    purchased_at TIMESTAMPTZ NOT NULL,
    
    -- Redemption
    redeemed_at TIMESTAMPTZ,
    poll_id UUID,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_event_passes_user_id ON public.event_passes(user_id);

-- ============================================
-- POLLS
-- ============================================
CREATE TYPE poll_status AS ENUM ('draft', 'active', 'closed', 'archived');

CREATE TABLE public.polls (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    
    -- Owner
    creator_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
    
    -- Basic info
    title TEXT NOT NULL,
    description TEXT,
    location TEXT,
    
    -- Settings
    status poll_status DEFAULT 'draft',
    timezone TEXT DEFAULT 'UTC',
    is_premium BOOLEAN DEFAULT FALSE,
    
    -- Limits (based on subscription tier)
    max_participants INTEGER DEFAULT 10,
    
    -- Dates
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    closes_at TIMESTAMPTZ,
    
    -- Selected meeting time (after finalization)
    selected_start_time TIMESTAMPTZ,
    selected_end_time TIMESTAMPTZ
);

CREATE INDEX idx_polls_creator_id ON public.polls(creator_id);
CREATE INDEX idx_polls_status ON public.polls(status);

-- Add foreign key for event_passes after polls table exists
ALTER TABLE public.event_passes 
    ADD CONSTRAINT fk_event_passes_poll 
    FOREIGN KEY (poll_id) REFERENCES public.polls(id) ON DELETE SET NULL;

-- ============================================
-- POLL TIME OPTIONS
-- ============================================
CREATE TABLE public.poll_time_options (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    poll_id UUID REFERENCES public.polls(id) ON DELETE CASCADE NOT NULL,
    
    -- Time slot
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    
    -- For recurring options
    is_all_day BOOLEAN DEFAULT FALSE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT valid_time_range CHECK (end_time > start_time)
);

CREATE INDEX idx_poll_time_options_poll_id ON public.poll_time_options(poll_id);

-- ============================================
-- POLL PARTICIPANTS
-- ============================================
CREATE TABLE public.poll_participants (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    poll_id UUID REFERENCES public.polls(id) ON DELETE CASCADE NOT NULL,
    
    -- Can be authenticated user or anonymous
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    anonymous_name TEXT,
    anonymous_email TEXT,
    
    -- Participant token for anonymous access
    access_token UUID DEFAULT uuid_generate_v4() UNIQUE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    CONSTRAINT participant_identity CHECK (
        user_id IS NOT NULL OR anonymous_name IS NOT NULL
    )
);

CREATE INDEX idx_poll_participants_poll_id ON public.poll_participants(poll_id);
CREATE INDEX idx_poll_participants_user_id ON public.poll_participants(user_id);
CREATE INDEX idx_poll_participants_token ON public.poll_participants(access_token);

-- ============================================
-- AVAILABILITY RESPONSES
-- ============================================
CREATE TYPE availability_status AS ENUM ('available', 'maybe', 'unavailable');

CREATE TABLE public.availability_responses (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    participant_id UUID REFERENCES public.poll_participants(id) ON DELETE CASCADE NOT NULL,
    time_option_id UUID REFERENCES public.poll_time_options(id) ON DELETE CASCADE NOT NULL,
    
    status availability_status NOT NULL,
    note TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(participant_id, time_option_id)
);

CREATE INDEX idx_availability_responses_participant ON public.availability_responses(participant_id);
CREATE INDEX idx_availability_responses_time_option ON public.availability_responses(time_option_id);

-- ============================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================

-- Profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view all profiles"
    ON public.profiles FOR SELECT
    USING (true);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

-- Subscriptions
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own subscription"
    ON public.subscriptions FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage subscriptions"
    ON public.subscriptions FOR ALL
    USING (auth.jwt()->>'role' = 'service_role');

-- Event Passes
ALTER TABLE public.event_passes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own event passes"
    ON public.event_passes FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage event passes"
    ON public.event_passes FOR ALL
    USING (auth.jwt()->>'role' = 'service_role');

-- Polls
ALTER TABLE public.polls ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active polls"
    ON public.polls FOR SELECT
    USING (status = 'active' OR creator_id = auth.uid());

CREATE POLICY "Users can create polls"
    ON public.polls FOR INSERT
    WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Creators can update own polls"
    ON public.polls FOR UPDATE
    USING (auth.uid() = creator_id);

CREATE POLICY "Creators can delete own polls"
    ON public.polls FOR DELETE
    USING (auth.uid() = creator_id);

-- Poll Time Options
ALTER TABLE public.poll_time_options ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view time options for accessible polls"
    ON public.poll_time_options FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.polls 
            WHERE polls.id = poll_time_options.poll_id 
            AND (polls.status = 'active' OR polls.creator_id = auth.uid())
        )
    );

CREATE POLICY "Poll creators can manage time options"
    ON public.poll_time_options FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.polls 
            WHERE polls.id = poll_time_options.poll_id 
            AND polls.creator_id = auth.uid()
        )
    );

-- Poll Participants
ALTER TABLE public.poll_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view participants for accessible polls"
    ON public.poll_participants FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.polls 
            WHERE polls.id = poll_participants.poll_id 
            AND (polls.status = 'active' OR polls.creator_id = auth.uid())
        )
    );

CREATE POLICY "Anyone can join active polls"
    ON public.poll_participants FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.polls 
            WHERE polls.id = poll_id AND polls.status = 'active'
        )
    );

CREATE POLICY "Participants can update own record"
    ON public.poll_participants FOR UPDATE
    USING (auth.uid() = user_id);

-- Availability Responses
ALTER TABLE public.availability_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view responses for accessible polls"
    ON public.availability_responses FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.poll_participants pp
            JOIN public.polls p ON p.id = pp.poll_id
            WHERE pp.id = availability_responses.participant_id
            AND (p.status = 'active' OR p.creator_id = auth.uid())
        )
    );

CREATE POLICY "Participants can manage own responses"
    ON public.availability_responses FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.poll_participants 
            WHERE poll_participants.id = availability_responses.participant_id
            AND poll_participants.user_id = auth.uid()
        )
    );

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Check if user has active subscription
CREATE OR REPLACE FUNCTION public.has_active_subscription(user_uuid UUID DEFAULT auth.uid())
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.subscriptions 
        WHERE user_id = user_uuid 
        AND is_active = true 
        AND (expires_at IS NULL OR expires_at > NOW())
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get user's current entitlement
CREATE OR REPLACE FUNCTION public.get_user_entitlement(user_uuid UUID DEFAULT auth.uid())
RETURNS TEXT AS $$
DECLARE
    result TEXT;
BEGIN
    SELECT entitlement INTO result
    FROM public.subscriptions 
    WHERE user_id = user_uuid 
    AND is_active = true 
    AND (expires_at IS NULL OR expires_at > NOW());
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Count user's unredeemed event passes
CREATE OR REPLACE FUNCTION public.count_unredeemed_passes(user_uuid UUID DEFAULT auth.uid())
RETURNS INTEGER AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)::INTEGER FROM public.event_passes 
        WHERE user_id = user_uuid AND redeemed_at IS NULL
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get user's active poll count
CREATE OR REPLACE FUNCTION public.count_active_polls(user_uuid UUID DEFAULT auth.uid())
RETURNS INTEGER AS $$
BEGIN
    RETURN (
        SELECT COUNT(*)::INTEGER FROM public.polls 
        WHERE creator_id = user_uuid AND status IN ('draft', 'active')
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Check if user can create a new poll
CREATE OR REPLACE FUNCTION public.can_create_poll(user_uuid UUID DEFAULT auth.uid())
RETURNS BOOLEAN AS $$
DECLARE
    active_count INTEGER;
    has_subscription BOOLEAN;
    unredeemed_passes INTEGER;
BEGIN
    active_count := public.count_active_polls(user_uuid);
    has_subscription := public.has_active_subscription(user_uuid);
    unredeemed_passes := public.count_unredeemed_passes(user_uuid);
    
    -- Free users: 1 active poll
    -- Pro/Team users: unlimited
    -- Event pass: allows 1 additional premium poll
    IF has_subscription THEN
        RETURN true;
    ELSIF unredeemed_passes > 0 THEN
        RETURN true;
    ELSIF active_count < 1 THEN
        RETURN true;
    ELSE
        RETURN false;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get poll with response summary
CREATE OR REPLACE FUNCTION public.get_poll_with_summary(poll_uuid UUID)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'poll', row_to_json(p),
        'time_options', (
            SELECT json_agg(
                json_build_object(
                    'id', pto.id,
                    'start_time', pto.start_time,
                    'end_time', pto.end_time,
                    'is_all_day', pto.is_all_day,
                    'responses', (
                        SELECT json_build_object(
                            'available', COUNT(*) FILTER (WHERE ar.status = 'available'),
                            'maybe', COUNT(*) FILTER (WHERE ar.status = 'maybe'),
                            'unavailable', COUNT(*) FILTER (WHERE ar.status = 'unavailable'),
                            'total', COUNT(*)
                        )
                        FROM public.availability_responses ar
                        WHERE ar.time_option_id = pto.id
                    )
                )
            )
            FROM public.poll_time_options pto
            WHERE pto.poll_id = p.id
        ),
        'participants', (
            SELECT json_agg(
                json_build_object(
                    'id', pp.id,
                    'display_name', COALESCE(pr.display_name, pp.anonymous_name),
                    'avatar_url', pr.avatar_url,
                    'responses', (
                        SELECT json_agg(
                            json_build_object(
                                'time_option_id', ar.time_option_id,
                                'status', ar.status,
                                'note', ar.note
                            )
                        )
                        FROM public.availability_responses ar
                        WHERE ar.participant_id = pp.id
                    )
                )
            )
            FROM public.poll_participants pp
            LEFT JOIN public.profiles pr ON pr.id = pp.user_id
            WHERE pp.poll_id = p.id
        )
    ) INTO result
    FROM public.polls p
    WHERE p.id = poll_uuid;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update timestamp trigger
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_subscriptions_updated_at
    BEFORE UPDATE ON public.subscriptions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_polls_updated_at
    BEFORE UPDATE ON public.polls
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_poll_participants_updated_at
    BEFORE UPDATE ON public.poll_participants
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_availability_responses_updated_at
    BEFORE UPDATE ON public.availability_responses
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================
-- REALTIME SUBSCRIPTIONS
-- ============================================

-- Enable realtime for polls and responses
ALTER PUBLICATION supabase_realtime ADD TABLE public.polls;
ALTER PUBLICATION supabase_realtime ADD TABLE public.poll_participants;
ALTER PUBLICATION supabase_realtime ADD TABLE public.availability_responses;
```

---

## Edge Functions

### RevenueCat Webhook Handler

```typescript
// supabase/functions/revenuecat-webhook/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
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
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  )

  try {
    const body = await req.json()
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
    let cancellationAt = null
    
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
      return new Response("Database error", { status: 500, headers: corsHeaders })
    }

    console.log(`Successfully processed ${eventType} for ${appUserId}`)
    return new Response("OK", { status: 200, headers: corsHeaders })
    
  } catch (err) {
    console.error("Webhook processing error:", err)
    return new Response("Internal error", { status: 500, headers: corsHeaders })
  }
})
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1-2)
**Goal:** Set up infrastructure and database

1. **Supabase Setup**
   - [ ] Create Supabase project
   - [ ] Configure Auth providers (Google, Apple)
   - [ ] Run database migration (schema above)
   - [ ] Deploy RevenueCat webhook Edge Function
   - [ ] Test webhook with sandbox purchases

2. **RevenueCat Setup**
   - [ ] Create RevenueCat project
   - [ ] Connect Stripe for Web Billing
   - [ ] Create entitlements: `pro_access`, `team_access`
   - [ ] Configure webhook URL to Supabase Edge Function

3. **Repository Setup**
   - [ ] Create repository with structure above
   - [ ] Set up environment variables
   - [ ] Create shared configuration files

### Phase 2: Web MVP (Week 3-4)
**Goal:** Functional web app

1. **SvelteKit Project**
   - [ ] Initialize with TypeScript
   - [ ] Configure Supabase client
   - [ ] Set up auth flow (Google, Apple, Magic Link)
   - [ ] Create auth store with session management

2. **Core Features**
   - [ ] Dashboard / poll list page
   - [ ] Create poll flow
   - [ ] Poll detail page with availability grid
   - [ ] Submit availability as participant
   - [ ] Real-time updates via Supabase Realtime

3. **Billing Integration**
   - [ ] Integrate RevenueCat Web SDK
   - [ ] Build paywall component
   - [ ] Enforce limits based on subscription status

4. **Deployment**
   - [ ] Deploy to Cloudflare Pages (or Vercel)
   - [ ] Configure custom domain

### Phase 3: Mobile Apps (Week 5-7)
**Goal:** iOS and Android apps with shared Swift code

1. **Skip Project Setup**
   - [ ] Initialize Skip project
   - [ ] Configure for iOS and Android targets
   - [ ] Add Supabase Swift SDK dependency
   - [ ] Add RevenueCat SDK dependency

2. **Shared Swift Code**
   - [ ] Data models (User, Poll, Subscription, etc.)
   - [ ] SupabaseService (client initialization, queries)
   - [ ] AuthService (sign in, sign out, session management)
   - [ ] PurchaseService (RevenueCat integration)
   - [ ] PollService (CRUD operations)

3. **iOS UI (SwiftUI)**
   - [ ] Auth flow views
   - [ ] Poll list view
   - [ ] Poll detail view with availability grid
   - [ ] Create poll flow
   - [ ] Paywall view
   - [ ] Settings / account view

4. **Android (Skip-generated)**
   - [ ] Verify Skip transpilation works
   - [ ] Test on Android emulator
   - [ ] Fix any platform-specific issues

### Phase 4: Polish & Launch (Week 8-10)
**Goal:** Production-ready apps

1. **Features**
   - [ ] Calendar integrations (Google Calendar, Apple Calendar)
   - [ ] Push notifications for poll updates
   - [ ] Email notifications
   - [ ] Share poll via link / QR code

2. **Quality**
   - [ ] Error handling and offline support
   - [ ] Loading states and animations
   - [ ] Accessibility audit
   - [ ] Security review

3. **Launch**
   - [ ] App Store submission
   - [ ] Play Store submission
   - [ ] Marketing site

---

## Key Integration Patterns

### 1. Supabase Auth → RevenueCat User Linking (Swift)

```swift
import Supabase
import RevenueCat

@Observable
class AuthService {
    private let supabase: SupabaseClient
    
    init() {
        supabase = SupabaseClient(
            supabaseURL: URL(string: Config.supabaseURL)!,
            supabaseKey: Config.supabaseAnonKey
        )
        
        // Listen for auth state changes
        Task {
            for await state in supabase.auth.authStateChanges {
                await handleAuthStateChange(event: state.event, session: state.session)
            }
        }
    }
    
    private func handleAuthStateChange(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .signedIn:
            if let userId = session?.user.id.uuidString {
                // Link Supabase user ID to RevenueCat
                do {
                    let (customerInfo, _) = try await Purchases.shared.logIn(userId)
                    print("RevenueCat logged in: \(customerInfo.originalAppUserId)")
                } catch {
                    print("RevenueCat login error: \(error)")
                }
            }
            
        case .signedOut:
            do {
                _ = try await Purchases.shared.logOut()
            } catch {
                print("RevenueCat logout error: \(error)")
            }
            
        default:
            break
        }
    }
}
```

### 2. Supabase Auth → RevenueCat User Linking (TypeScript/SvelteKit)

```typescript
// src/lib/stores/auth.ts
import { createClient } from '@supabase/supabase-js'
import { Purchases } from '@revenuecat/purchases-js'
import { writable } from 'svelte/store'

const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
)

export const user = writable(null)
export const session = writable(null)

// Initialize auth listener
supabase.auth.onAuthStateChange(async (event, newSession) => {
  session.set(newSession)
  user.set(newSession?.user ?? null)
  
  if (event === 'SIGNED_IN' && newSession?.user) {
    // Link to RevenueCat
    try {
      await Purchases.configure({
        apiKey: import.meta.env.VITE_REVENUECAT_WEB_KEY,
        appUserId: newSession.user.id
      })
    } catch (err) {
      console.error('RevenueCat config error:', err)
    }
  }
  
  if (event === 'SIGNED_OUT') {
    // RevenueCat will use anonymous ID
    await Purchases.configure({
      apiKey: import.meta.env.VITE_REVENUECAT_WEB_KEY
    })
  }
})
```

### 3. Check Subscription Status (Swift)

```swift
// Fast check via local Supabase cache
func hasActiveSubscription() async -> Bool {
    do {
        let result: Bool = try await supabase.rpc("has_active_subscription").execute().value
        return result
    } catch {
        // Fallback to RevenueCat
        let customerInfo = try? await Purchases.shared.customerInfo()
        return customerInfo?.entitlements.active.isEmpty == false
    }
}

// Get specific entitlement
func getUserEntitlement() async -> String? {
    do {
        let result: String? = try await supabase.rpc("get_user_entitlement").execute().value
        return result
    } catch {
        return nil
    }
}
```

### 4. Real-time Poll Updates (TypeScript)

```typescript
// Subscribe to poll changes
const pollSubscription = supabase
  .channel('poll-updates')
  .on(
    'postgres_changes',
    {
      event: '*',
      schema: 'public',
      table: 'availability_responses',
      filter: `participant_id=in.(${participantIds.join(',')})`
    },
    (payload) => {
      console.log('Response changed:', payload)
      // Update UI
    }
  )
  .subscribe()

// Clean up
onDestroy(() => {
  pollSubscription.unsubscribe()
})
```

---

## Environment Variables

```bash
# .env.example

# Supabase
VITE_SUPABASE_URL=https://xxxxx.supabase.co
VITE_SUPABASE_ANON_KEY=eyJ...

# For Edge Functions (set via supabase secrets)
# SUPABASE_SERVICE_ROLE_KEY=eyJ...

# RevenueCat
VITE_REVENUECAT_WEB_KEY=rcb_xxxxx
# For Edge Functions
# REVENUECAT_WEBHOOK_AUTH=Bearer your-secret

# App
VITE_APP_NAME="Meeting Scheduler"
VITE_APP_URL=https://yourapp.com
```

---

## Claude Code Initial Tasks

1. **Create repository structure**
   ```
   mkdir meeting-scheduler && cd meeting-scheduler
   # Create all directories as defined above
   ```

2. **Initialize Supabase project**
   ```bash
   supabase init
   supabase link --project-ref YOUR_PROJECT_REF
   ```

3. **Create database migration**
   - Copy schema SQL to `supabase/migrations/00001_initial_schema.sql`
   - Run: `supabase db push`

4. **Deploy Edge Function**
   ```bash
   supabase functions deploy revenuecat-webhook
   supabase secrets set REVENUECAT_WEBHOOK_AUTH="Bearer your-secret"
   ```

5. **Initialize SvelteKit web app**
   ```bash
   cd apps/web
   pnpm create svelte@latest .
   pnpm add @supabase/supabase-js @revenuecat/purchases-js
   ```

6. **Initialize Skip mobile project**
   ```bash
   cd apps/mobile
   skip init MeetingScheduler
   ```

---

## Startup Prompt for Claude Code

```
I'm building a multiplatform meeting scheduler app. Here's my setup:

**Architecture:** Supabase-only (no separate backend server)
- Supabase for auth, database, edge functions, realtime
- RevenueCat for billing (iOS, Android, Web)
- SvelteKit for web
- Skip.tools for iOS + Android (shared Swift code)

**Completed:**
- Supabase project created
- RevenueCat project created with Stripe connected
- Auth providers configured (Google, Apple)

**My Supabase credentials:**
- Project URL: [YOUR_URL]
- Anon Key: [YOUR_KEY]

Let's start Phase 1:
1. Create the repository structure as defined in the project brief
2. Create the database migration file with the full schema
3. Create the RevenueCat webhook Edge Function
4. Initialize the SvelteKit web project with Supabase auth

I have the full project brief with all schemas and code. Should I paste it, or would you like to start with the repository structure first?
```
