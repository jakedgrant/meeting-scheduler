-- F05/F09: server-owned creation, retry identity, quota and capacity.
BEGIN;
CREATE TABLE private.poll_creation_requests (
    creator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    operation_id uuid NOT NULL,
    payload jsonb NOT NULL,
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (creator_id, operation_id)
);
ALTER TABLE private.poll_creation_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.poll_creation_requests FROM PUBLIC, anon, authenticated, service_role;

-- Funding belongs permanently to the original poll, even if a receipt is
-- transferred, revoked, deleted or reconciled later. Never infer a free slot
-- from a mutable premium flag or the pass's current owner.
CREATE TABLE private.poll_pass_funding (
    poll_id uuid PRIMARY KEY REFERENCES public.polls(id) ON DELETE CASCADE,
    creator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    event_pass_id uuid NOT NULL UNIQUE,
    funded_at timestamptz NOT NULL
);
ALTER TABLE private.poll_pass_funding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.poll_pass_funding FROM PUBLIC,anon,authenticated,service_role;
-- Preserve actual historical redemption, including revoked/spent receipts.
INSERT INTO private.poll_pass_funding(poll_id,creator_id,event_pass_id,funded_at)
SELECT DISTINCT ON (p.id) p.id,p.creator_id,ep.id,ep.redeemed_at
FROM public.polls p JOIN public.event_passes ep ON ep.poll_id=p.id
WHERE ep.redeemed_at IS NOT NULL ORDER BY p.id,ep.redeemed_at,ep.id;

-- Billing decisions must use decision time after a lock wait, rather than
-- PostgreSQL's transaction-start now(). Preserve F08's private read contract.
CREATE OR REPLACE FUNCTION private.billing_effective_entitlement(p_user_id uuid)
RETURNS text LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path='' AS $$
    SELECT entitlement FROM private.billing_entitlements
    WHERE user_id=p_user_id AND valid_until>clock_timestamp()
    ORDER BY (entitlement='team_access') DESC,valid_until DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION private.billing_effective_entitlement(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION poll_private.can_join_poll(poll_uuid uuid)
RETURNS boolean LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path='' AS $$
    SELECT EXISTS (SELECT 1 FROM public.polls p WHERE p.id=poll_uuid AND p.status='active'
      AND (p.closes_at IS NULL OR p.closes_at>clock_timestamp()));
$$;

-- Every creation and reactivation of an owner's poll uses this lock. The
-- private function cannot be called by API roles with another owner's UUID.
CREATE FUNCTION poll_private.lock_poll_creator(creator_uuid uuid)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    PERFORM 1 FROM public.profiles WHERE id=creator_uuid FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.lock_poll_creator(uuid) FROM PUBLIC,anon,authenticated;

-- Direct inserts cannot skip the command's complete option set or idempotency.
DROP POLICY IF EXISTS "Users can create polls" ON public.polls;
REVOKE INSERT ON public.polls FROM anon,authenticated;

-- Billing-derived columns and identity stay server-owned. Reactivations use
-- the same owner lock and timed entitlement as creation.
CREATE FUNCTION poll_private.check_poll_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname=current_user AND (rolsuper OR rolbypassrls)) THEN
        IF (NEW.id,NEW.creator_id,NEW.is_premium,NEW.max_participants,NEW.share_code,NEW.created_at)
            IS DISTINCT FROM (OLD.id,OLD.creator_id,OLD.is_premium,OLD.max_participants,OLD.share_code,OLD.created_at) THEN
            RAISE EXCEPTION 'Poll identity and paid limits are server controlled' USING ERRCODE='42501';
        END IF;
        IF NEW.status IS NULL OR NEW.title IS NULL OR length(btrim(NEW.title)) NOT BETWEEN 1 AND 200
          OR length(NEW.description)>10000 OR length(NEW.location)>1000
          OR NEW.timezone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name=NEW.timezone)
          OR (NEW.closes_at IS DISTINCT FROM OLD.closes_at AND NEW.closes_at IS NOT NULL
              AND (NOT isfinite(NEW.closes_at) OR NEW.closes_at<=clock_timestamp())) THEN
            RAISE EXCEPTION 'Invalid poll fields' USING ERRCODE='22023';
        END IF;
        IF NEW.status IN ('draft','active') AND OLD.status IS DISTINCT FROM 'draft' AND OLD.status IS DISTINCT FROM 'active' THEN
            PERFORM poll_private.check_poll_reactivation(OLD.id);
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_poll_update() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER polls_05_server_fields BEFORE UPDATE ON public.polls
FOR EACH ROW EXECUTE FUNCTION poll_private.check_poll_update();

-- This trigger covers commands AND direct member/guest inserts. A poll update
-- lock serializes competing joins, close/finalize, and capacity changes. Commands
-- acquire it before a participant/credential lock (never upgrade a share lock).
CREATE FUNCTION poll_private.check_participant_capacity()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE target public.polls;
BEGIN
    SELECT * INTO target FROM public.polls WHERE id=NEW.poll_id FOR UPDATE;
    IF NOT FOUND THEN RETURN NEW; END IF; -- the FK supplies the missing-parent error
    IF target.max_participants IS NULL OR target.max_participants<1
      OR (SELECT count(*) FROM public.poll_participants WHERE poll_id=NEW.poll_id)>=target.max_participants THEN
        RAISE EXCEPTION 'Poll participant limit reached' USING ERRCODE='P0003';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_participant_capacity() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER participants_05_capacity BEFORE INSERT ON public.poll_participants
FOR EACH ROW EXECUTE FUNCTION poll_private.check_participant_capacity();

-- Options remain editable through the existing owner path. Apply the same
-- engineering bounds to direct mutations, including inserted/edited timestamps.
CREATE FUNCTION poll_private.check_poll_option()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    PERFORM 1 FROM public.polls WHERE id=NEW.poll_id FOR UPDATE;
    IF NOT isfinite(NEW.start_time) OR NOT isfinite(NEW.end_time)
      OR NEW.start_time IS NULL OR NEW.end_time IS NULL OR NEW.end_time<=NEW.start_time
      OR NEW.is_all_day IS NULL THEN
        RAISE EXCEPTION 'Invalid time option' USING ERRCODE='22023';
    END IF;
    IF TG_OP='INSERT' AND (SELECT count(*) FROM public.poll_time_options WHERE poll_id=NEW.poll_id)>=500 THEN
        RAISE EXCEPTION 'Provide between 1 and 500 time options' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_poll_option() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER time_options_20_payload BEFORE INSERT OR UPDATE ON public.poll_time_options
FOR EACH ROW EXECUTE FUNCTION poll_private.check_poll_option();

-- Complete JSONB payload is retained rather than a weak client-supplied hash.
-- Key ordering is irrelevant; an unchanged retry returns its original snapshot,
-- even if the poll was later closed or deleted. A changed payload is rejected.
CREATE FUNCTION poll_private.create_poll(operation_id uuid, payload jsonb)
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
    ELSIF tier='free' AND (SELECT count(*) FROM public.polls p WHERE p.creator_id=caller AND p.status IN ('draft','active')
      AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id))>=1 THEN
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
REVOKE ALL ON FUNCTION poll_private.create_poll(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION poll_private.create_poll(uuid,jsonb) TO authenticated,service_role;
CREATE FUNCTION public.create_poll(operation_id uuid,payload jsonb)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path='' AS $$
    SELECT poll_private.create_poll(operation_id,payload);
$$;
REVOKE ALL ON FUNCTION public.create_poll(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_poll(uuid,jsonb) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION poll_private.join_poll(poll_uuid UUID)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := auth.uid();
    participant public.poll_participants;
BEGIN
    IF caller_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;

    -- A retry returns the existing membership in any poll state.
    SELECT * INTO participant FROM public.poll_participants pp
    WHERE pp.poll_id = poll_uuid AND pp.user_id = caller_id;
    IF FOUND THEN
        RETURN json_build_object('participant', row_to_json(participant), 'created', false);
    END IF;

    PERFORM 1 FROM public.polls p WHERE p.id = poll_uuid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE = '42501';
    END IF;

    -- Recheck after waiting: a competing retry may have filled the final slot.
    SELECT * INTO participant FROM public.poll_participants pp
    WHERE pp.poll_id = poll_uuid AND pp.user_id = caller_id;
    IF FOUND THEN
        RETURN json_build_object('participant', row_to_json(participant), 'created', false);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.polls p WHERE p.id=poll_uuid AND p.status='active'
      AND (p.closes_at IS NULL OR p.closes_at>clock_timestamp())) THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE='42501';
    END IF;

    INSERT INTO public.poll_participants (poll_id, user_id)
    VALUES (poll_uuid, caller_id)
    ON CONFLICT (poll_id, user_id) WHERE user_id IS NOT NULL DO NOTHING
    RETURNING * INTO participant;
    IF FOUND THEN
        RETURN json_build_object('participant', row_to_json(participant), 'created', true);
    END IF;

    -- A concurrent request committed the membership first.
    SELECT * INTO participant FROM public.poll_participants pp
    WHERE pp.poll_id = poll_uuid AND pp.user_id = caller_id;
    RETURN json_build_object('participant', row_to_json(participant), 'created', false);
END;
$$;

CREATE OR REPLACE FUNCTION poll_private.join_poll_as_guest(
    poll_uuid UUID, display_name TEXT, contact_email TEXT, guest_token TEXT)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    guest_name TEXT := btrim(display_name);
    guest_email TEXT := nullif(btrim(contact_email), '');
    token TEXT := guest_token;
    token_digest BYTEA;
    participant public.poll_participants;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        RAISE EXCEPTION 'Signed-in callers must join as members' USING ERRCODE = '42501';
    END IF;

    IF token IS NULL THEN
        token := poll_private.new_guest_token();
        token_digest := poll_private.guest_token_hash(token);
    ELSE
        token_digest := poll_private.guest_token_hash(token);
        IF token_digest IS NULL THEN
            RAISE EXCEPTION 'Guest token must be 64 lowercase hexadecimal characters' USING ERRCODE = '22023';
        END IF;
        participant := poll_private.guest_participant_for_digest(token_digest);
        IF participant.id IS NOT NULL THEN
            IF participant.poll_id = poll_uuid AND participant.user_id IS NULL THEN
                RETURN json_build_object('participant', row_to_json(participant),
                    'guest_token', token, 'created', false);
            END IF;
            RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
        END IF;
    END IF;

    PERFORM 1 FROM public.polls p WHERE p.id = poll_uuid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE = '42501';
    END IF;
    -- Recheck capability after waiting, before capacity or creating another row.
    participant := poll_private.guest_participant_for_digest(token_digest);
    IF participant.id IS NOT NULL THEN
        IF participant.poll_id = poll_uuid AND participant.user_id IS NULL THEN
            RETURN json_build_object('participant', row_to_json(participant),
                'guest_token', token, 'created', false);
        END IF;
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.polls p WHERE p.id=poll_uuid AND p.status='active'
      AND (p.closes_at IS NULL OR p.closes_at>clock_timestamp())) THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE='42501';
    END IF;

    IF guest_name IS NULL OR length(guest_name) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'Guest display name must be 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    IF guest_email IS NOT NULL AND (length(guest_email) > 320 OR guest_email !~ '^[^@[:space:]]+@[^@[:space:]]+$') THEN
        RAISE EXCEPTION 'Guest contact email is invalid' USING ERRCODE = '22023';
    END IF;

    BEGIN
        INSERT INTO public.poll_participants (poll_id, anonymous_name, anonymous_email)
        VALUES (poll_uuid, guest_name, guest_email)
        RETURNING * INTO participant;
        INSERT INTO private.participant_guest_credentials (participant_id, token_hash, token_issued_at)
        VALUES (participant.id, token_digest, now())
        ON CONFLICT (participant_id) DO UPDATE
            SET token_hash = EXCLUDED.token_hash, token_issued_at = EXCLUDED.token_issued_at, updated_at = now();
    EXCEPTION WHEN unique_violation THEN
        -- A concurrent request with the same capability committed first.
        participant := poll_private.guest_participant_for_digest(token_digest);
        IF participant.id IS NOT NULL AND participant.poll_id = poll_uuid AND participant.user_id IS NULL THEN
            RETURN json_build_object('participant', row_to_json(participant),
                'guest_token', token, 'created', false);
        END IF;
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END;

    RETURN json_build_object('participant', row_to_json(participant), 'guest_token', token, 'created', true);
END;
$$;


CREATE FUNCTION poll_private.check_poll_reactivation(poll_uuid uuid)
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
    IF tier IS NULL AND (SELECT count(*) FROM public.polls p WHERE p.creator_id=target.creator_id
      AND p.id<>poll_uuid AND p.status IN ('draft','active')
      AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id))>=1 THEN
        RAISE EXCEPTION 'Active poll limit reached' USING ERRCODE='P0001';
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_poll_reactivation(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION poll_private.check_poll_reactivation(uuid) TO authenticated,service_role;

CREATE FUNCTION poll_private.can_create_poll(user_uuid uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    PERFORM poll_private.require_self(user_uuid);
    RETURN private.billing_effective_entitlement(auth.uid()) IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.event_passes ep WHERE ep.user_id=auth.uid()
        AND ep.billing_project_id IS NOT NULL AND ep.revoked_at IS NULL
        AND ep.redeemed_at IS NULL AND ep.verified_until>clock_timestamp())
      OR NOT EXISTS (SELECT 1 FROM public.polls p WHERE p.creator_id=auth.uid() AND p.status IN ('draft','active')
        AND NOT EXISTS (SELECT 1 FROM private.poll_pass_funding f WHERE f.poll_id=p.id));
END;
$$;
REVOKE ALL ON FUNCTION poll_private.can_create_poll(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION poll_private.can_create_poll(uuid) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.can_create_poll(user_uuid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
    SELECT poll_private.can_create_poll(user_uuid);
$$;

-- Keep legacy preflights useful without treating the public billing projection's
-- cached boolean as authorization. The command rechecks everything while locked.
CREATE FUNCTION poll_private.self_entitlement(user_uuid uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    PERFORM poll_private.require_self(user_uuid);
    RETURN private.billing_effective_entitlement(auth.uid());
END;
$$;
REVOKE ALL ON FUNCTION poll_private.self_entitlement(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION poll_private.self_entitlement(uuid) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.get_user_entitlement(user_uuid uuid DEFAULT auth.uid())
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
    SELECT poll_private.self_entitlement(user_uuid);
$$;
CREATE OR REPLACE FUNCTION public.has_active_subscription(user_uuid uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
    SELECT poll_private.self_entitlement(user_uuid) IS NOT NULL;
$$;
COMMIT;
