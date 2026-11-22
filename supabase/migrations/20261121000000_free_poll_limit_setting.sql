-- The free plan's cap on active ordinary polls is a setting, not a constant.
-- NULL removes the cap (alpha); a number caps each free account at that many
-- draft or active polls that no event pass funds. Paid tiers, participant
-- limits and pass redemption are unaffected. Change it with:
--   UPDATE private.app_settings SET free_active_poll_limit = 1;  -- the original cap
--   UPDATE private.app_settings SET free_active_poll_limit = NULL; -- unlimited

CREATE TABLE private.app_settings(
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    free_active_poll_limit integer CHECK(free_active_poll_limit >= 0)
);
INSERT INTO private.app_settings(free_active_poll_limit) VALUES(NULL);
ALTER TABLE private.app_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.app_settings FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION poll_private.create_poll(operation_id uuid, payload jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE
    caller uuid := auth.uid();
    previous private.poll_creation_requests;
    made public.polls;
    pass public.event_passes;
    tier text;
    limit_count integer;
    option jsonb;
    starts timestamptz;
    ends timestamptz;
    deadline timestamptz;
    requested_pass boolean;
    code text;
    attempt integer;
    collision_constraint text;
    result jsonb;
    made_options jsonb := '[]'::jsonb;
    made_option public.poll_time_options;
BEGIN
    IF caller IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
    IF operation_id IS NULL OR payload IS NULL OR jsonb_typeof(payload)<>'object' THEN
        RAISE EXCEPTION 'Operation ID and poll payload are required' USING ERRCODE='22023';
    END IF;
    PERFORM poll_private.lock_poll_creator(caller);
    SELECT * INTO previous FROM private.poll_creation_requests r
      WHERE r.creator_id=caller AND r.operation_id=create_poll.operation_id;
    IF FOUND THEN
        IF previous.payload IS DISTINCT FROM payload THEN
            RAISE EXCEPTION 'Operation ID was already used with a different payload' USING ERRCODE='22000';
        END IF;
        RETURN previous.result || jsonb_build_object('replayed',true);
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_object_keys(payload) k WHERE k NOT IN
        ('title','description','location','timezone','closes_at','time_options','use_event_pass')) THEN
        RAISE EXCEPTION 'Unsupported poll field' USING ERRCODE='22023';
    END IF;
    IF jsonb_typeof(payload->'title') IS DISTINCT FROM 'string'
      OR length(btrim(payload->>'title')) NOT BETWEEN 1 AND 200
      OR jsonb_typeof(payload->'timezone') IS DISTINCT FROM 'string'
      OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name=payload->>'timezone')
      OR (payload ? 'description' AND jsonb_typeof(payload->'description') NOT IN ('string','null'))
      OR length(payload->>'description')>10000
      OR (payload ? 'location' AND jsonb_typeof(payload->'location') NOT IN ('string','null'))
      OR length(payload->>'location')>1000
      OR (payload ? 'closes_at' AND jsonb_typeof(payload->'closes_at') NOT IN ('string','null'))
      OR (payload ? 'use_event_pass' AND jsonb_typeof(payload->'use_event_pass')<>'boolean') THEN
        RAISE EXCEPTION 'Invalid poll fields' USING ERRCODE='22023';
    END IF;
    requested_pass := coalesce((payload->>'use_event_pass')::boolean,false);
    IF jsonb_typeof(payload->'time_options') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Time options must be an array' USING ERRCODE='22023';
    END IF;
    IF jsonb_array_length(payload->'time_options') NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'Provide between 1 and 500 time options' USING ERRCODE='22023';
    END IF;
    BEGIN
        IF payload->>'closes_at' IS NOT NULL THEN
            IF payload->>'closes_at' !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' THEN RAISE invalid_datetime_format; END IF;
            deadline := (payload->>'closes_at')::timestamptz;
            IF NOT isfinite(deadline) OR deadline<=clock_timestamp() THEN RAISE invalid_datetime_format; END IF;
        END IF;
        FOR option IN SELECT value FROM jsonb_array_elements(payload->'time_options') LOOP
            IF jsonb_typeof(option)<>'object' OR EXISTS (SELECT 1 FROM jsonb_object_keys(option) k
                WHERE k NOT IN ('start_time','end_time','is_all_day'))
              OR jsonb_typeof(option->'start_time') IS DISTINCT FROM 'string'
              OR jsonb_typeof(option->'end_time') IS DISTINCT FROM 'string'
              OR option->>'start_time' !~ '(Z|[+-][0-9]{2}:[0-9]{2})$'
              OR option->>'end_time' !~ '(Z|[+-][0-9]{2}:[0-9]{2})$'
              OR (option ? 'is_all_day' AND jsonb_typeof(option->'is_all_day')<>'boolean') THEN
                RAISE EXCEPTION 'Invalid time option' USING ERRCODE='22023';
            END IF;
            starts := (option->>'start_time')::timestamptz;
            ends := (option->>'end_time')::timestamptz;
            IF NOT isfinite(starts) OR NOT isfinite(ends) OR ends<=starts THEN
                RAISE EXCEPTION 'Each time option must end after it starts' USING ERRCODE='22023';
            END IF;
        END LOOP;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
        RAISE EXCEPTION 'Dates require valid timestamp offsets and a future deadline' USING ERRCODE='22023';
    END;
    tier := coalesce(private.billing_effective_entitlement(caller),'free');
    limit_count := CASE tier WHEN 'team_access' THEN 100 WHEN 'pro_access' THEN 50 ELSE 10 END;
    IF requested_pass AND tier='free' THEN
        -- Explicit opt-in only; subscriptions always preserve purchased passes.
        SELECT * INTO pass FROM public.event_passes ep WHERE ep.user_id=caller
          AND ep.billing_project_id IS NOT NULL AND ep.revoked_at IS NULL
          AND ep.redeemed_at IS NULL AND ep.verified_until>clock_timestamp()
          ORDER BY ep.purchased_at,ep.id LIMIT 1 FOR UPDATE;
        IF NOT FOUND OR pass.verified_until<=clock_timestamp() THEN
            RAISE EXCEPTION 'No eligible event pass is available' USING ERRCODE='P0002';
        END IF;
        tier := 'event_pass'; limit_count:=50;
    ELSIF tier='free' AND (SELECT s.free_active_poll_limit FROM private.app_settings s) IS NOT NULL
      AND (SELECT count(*) FROM public.polls p WHERE p.creator_id=caller AND p.status IN ('draft','active')
      AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id))
        >=(SELECT s.free_active_poll_limit FROM private.app_settings s) THEN
        RAISE EXCEPTION 'Active poll limit reached' USING ERRCODE='P0001';
    END IF;

    -- The unique index is the final arbiter, including concurrent creators and
    -- share codes on inaccessible polls. Never look up or return the collision.
    FOR attempt IN 1..20 LOOP
        IF deadline IS NOT NULL AND deadline<=clock_timestamp() THEN
            RAISE EXCEPTION 'Poll deadline has passed; choose a future deadline' USING ERRCODE='22023';
        END IF;
        code := public.generate_share_code();
        BEGIN
            INSERT INTO public.polls(creator_id,title,description,location,timezone,closes_at,status,
                is_premium,max_participants,share_code)
            VALUES(caller,btrim(payload->>'title'),payload->>'description',payload->>'location',
                payload->>'timezone',deadline,'active',tier<>'free',limit_count,code)
            RETURNING * INTO made;
            EXIT;
        EXCEPTION WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS collision_constraint=CONSTRAINT_NAME;
            IF collision_constraint<>'polls_share_code_key' THEN RAISE; END IF;
        END;
    END LOOP;
    IF made.id IS NULL THEN RAISE EXCEPTION 'Unable to allocate share code; retry creation' USING ERRCODE='54000'; END IF;
    FOR option IN SELECT value FROM jsonb_array_elements(payload->'time_options') LOOP
        INSERT INTO public.poll_time_options(poll_id,start_time,end_time,is_all_day)
        VALUES(made.id,(option->>'start_time')::timestamptz,(option->>'end_time')::timestamptz,
            coalesce((option->>'is_all_day')::boolean,false)) RETURNING * INTO made_option;
        made_options := made_options || jsonb_build_array(to_jsonb(made_option));
    END LOOP;
    IF pass.id IS NOT NULL THEN
        -- Recheck after the row lock, including billing ownership/freshness.
        UPDATE public.event_passes ep SET redeemed_at=clock_timestamp(),poll_id=made.id
          WHERE ep.id=pass.id AND ep.user_id=caller AND ep.billing_project_id IS NOT NULL
            AND ep.revoked_at IS NULL AND ep.redeemed_at IS NULL AND ep.verified_until>clock_timestamp();
        IF NOT FOUND THEN RAISE EXCEPTION 'No eligible event pass is available' USING ERRCODE='P0002'; END IF;
        INSERT INTO private.poll_pass_funding(poll_id,creator_id,event_pass_id,funded_at)
          VALUES(made.id,caller,pass.id,now());
    END IF;
    -- A unique-index collision can wait on another creator. Revalidate paid
    -- authorization and deadline after all waits, before saving a receipt.
    IF tier IN ('pro_access','team_access') AND
      coalesce(CASE private.billing_effective_entitlement(caller)
        WHEN 'team_access' THEN 100 WHEN 'pro_access' THEN 50 ELSE 0 END,0)<limit_count THEN
        RAISE EXCEPTION 'Current subscription no longer supports this poll; retry creation' USING ERRCODE='42501';
    END IF;
    IF deadline IS NOT NULL AND deadline<=clock_timestamp() THEN
        RAISE EXCEPTION 'Poll deadline has passed; choose a future deadline' USING ERRCODE='22023';
    END IF;
    result := jsonb_build_object('poll',to_jsonb(made),'time_options',made_options,
        'redeemed_pass_id',pass.id,'entitlement',tier,'replayed',false);
    INSERT INTO private.poll_creation_requests(creator_id,operation_id,payload,result)
      VALUES(caller,operation_id,payload,result);
    RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION poll_private.check_poll_reactivation(poll_uuid uuid)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE target public.polls; tier text; supported integer;
BEGIN
    SELECT * INTO target FROM public.polls WHERE id=poll_uuid;
    IF target.creator_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';
    END IF;
    PERFORM poll_private.lock_poll_creator(target.creator_id);
    -- A redeemed pass permanently funds this poll; refunds/receipt transfers
    -- preserve that history and never consume another unit on reopening.
    IF EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=poll_uuid) THEN RETURN; END IF;
    tier:=private.billing_effective_entitlement(target.creator_id);
    supported:=CASE tier WHEN 'team_access' THEN 100 WHEN 'pro_access' THEN 50 ELSE 10 END;
    IF target.max_participants IS NULL OR target.max_participants>supported
      OR (target.is_premium AND tier IS NULL) THEN
        RAISE EXCEPTION 'Current subscription cannot reopen this premium poll' USING ERRCODE='42501';
    END IF;
    IF tier IS NULL AND (SELECT s.free_active_poll_limit FROM private.app_settings s) IS NOT NULL
      AND (SELECT count(*) FROM public.polls p WHERE p.creator_id=target.creator_id
      AND p.id<>poll_uuid AND p.status IN ('draft','active')
      AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id))
        >=(SELECT s.free_active_poll_limit FROM private.app_settings s) THEN
        RAISE EXCEPTION 'Active poll limit reached' USING ERRCODE='P0001';
    END IF;
END;
$$;
CREATE OR REPLACE FUNCTION poll_private.can_create_poll(user_uuid uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    PERFORM poll_private.require_self(user_uuid);
    RETURN private.billing_effective_entitlement(auth.uid()) IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.event_passes ep WHERE ep.user_id=auth.uid()
        AND ep.billing_project_id IS NOT NULL AND ep.revoked_at IS NULL
        AND ep.redeemed_at IS NULL AND ep.verified_until>clock_timestamp())
      OR (SELECT s.free_active_poll_limit FROM private.app_settings s) IS NULL
      OR (SELECT count(*) FROM public.polls p WHERE p.creator_id=auth.uid() AND p.status IN ('draft','active')
        AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id))
        <(SELECT s.free_active_poll_limit FROM private.app_settings s);
END;
$$;
