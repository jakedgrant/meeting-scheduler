-- ============================================
-- MEETING SCHEDULER DATABASE SCHEMA
-- ============================================

-- Using gen_random_uuid() which is built into PostgreSQL 13+

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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,

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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    poll_id UUID REFERENCES public.polls(id) ON DELETE CASCADE NOT NULL,

    -- Can be authenticated user or anonymous
    user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    anonymous_name TEXT,
    anonymous_email TEXT,

    -- Participant token for anonymous access
    access_token UUID DEFAULT gen_random_uuid() UNIQUE,

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
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
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
