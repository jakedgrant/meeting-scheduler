-- F08: notifications are durable triggers, never authoritative entitlement state.
-- Deploy the worker/schedule and backfill before enabling paid creation (F05).
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO service_role;

CREATE TABLE private.billing_settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT true CHECK (singleton),
    project_id TEXT NOT NULL CHECK (length(project_id) BETWEEN 1 AND 255),
    environment TEXT NOT NULL CHECK (environment IN ('production', 'sandbox'))
);

CREATE TABLE private.billing_inbox (
    event_id TEXT PRIMARY KEY CHECK (length(event_id) BETWEEN 1 AND 255),
    event_type TEXT NOT NULL,
    event_timestamp_ms BIGINT NOT NULL CHECK (event_timestamp_ms >= 0),
    -- Deliberately excludes subscriber attributes, prices, email and auth headers.
    event JSONB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending','processed','ignored','quarantined')),
    reason TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);

-- No profile FK: a paid notification may arrive before profile creation or after
-- account deletion. Accepted work and its diagnostics must survive both.
CREATE TABLE private.billing_customers (
    customer_id TEXT PRIMARY KEY CHECK (length(customer_id) BETWEEN 1 AND 1500),
    provider_customer_ids TEXT[] NOT NULL DEFAULT '{}',
    revision BIGINT NOT NULL DEFAULT 1,
    completed_revision BIGINT NOT NULL DEFAULT 0,
    lease_id UUID,
    leased_until TIMESTAMPTZ,
    leased_revision BIGINT,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    paused BOOLEAN NOT NULL DEFAULT false,
    last_error_code TEXT,
    reconciled_at TIMESTAMPTZ
);
CREATE INDEX billing_customers_due ON private.billing_customers(next_attempt_at) WHERE NOT paused;
-- Only an operator with verified provider/account evidence may resolve an
-- anonymous/custom ID. Never trust webhook aliases or original_app_user_id.
CREATE TABLE private.billing_identity_links (
    provider_customer_id TEXT PRIMARY KEY CHECK (length(provider_customer_id) BETWEEN 1 AND 1500),
    user_id UUID NOT NULL,
    verification_reference TEXT NOT NULL CHECK (length(verification_reference) BETWEEN 1 AND 255),
    verified_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE private.billing_inbox_targets (
    event_id TEXT NOT NULL REFERENCES private.billing_inbox(event_id),
    customer_id TEXT NOT NULL REFERENCES private.billing_customers(customer_id),
    required_revision BIGINT NOT NULL,
    PRIMARY KEY(event_id, customer_id)
);
CREATE INDEX billing_targets_customer ON private.billing_inbox_targets(customer_id);

CREATE TABLE private.billing_entitlements (
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    resource_id TEXT NOT NULL,
    entitlement TEXT NOT NULL CHECK (entitlement IN ('pro_access','team_access')),
    product_id TEXT,
    store TEXT NOT NULL,
    transaction_id TEXT,
    purchased_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ,
    valid_until TIMESTAMPTZ NOT NULL,
    PRIMARY KEY(user_id, resource_id, entitlement),
    -- Promotional grants have a canonical resource/entitlement, but may have
    -- neither a store product nor a store receipt. Never manufacture either.
    CHECK ((product_id IS NOT NULL AND transaction_id IS NOT NULL) OR store='PROMOTIONAL')
);

ALTER TABLE public.subscriptions
    ADD COLUMN billing_contract_version INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN billing_environment TEXT CHECK (billing_environment IN ('production','sandbox')),
    ADD COLUMN reconciled_at TIMESTAMPTZ,
    ADD COLUMN access_valid_until TIMESTAMPTZ;
ALTER TABLE public.event_passes
    ADD COLUMN billing_project_id TEXT,
    ADD COLUMN billing_environment TEXT CHECK (billing_environment IN ('production','sandbox')),
    ADD COLUMN revenuecat_purchase_id TEXT,
    ADD COLUMN product_id TEXT,
    ADD COLUMN store_transaction_id TEXT,
    ADD COLUMN purchase_unit INTEGER CHECK (purchase_unit BETWEEN 1 AND 100),
    ADD COLUMN verified_until TIMESTAMPTZ,
    ADD COLUMN revoked_at TIMESTAMPTZ,
    ADD COLUMN revocation_reason TEXT;
CREATE UNIQUE INDEX event_passes_provider_unit ON public.event_passes
    (billing_project_id,billing_environment,store,product_id,store_transaction_id,purchase_unit);
ALTER TABLE public.event_passes ADD CONSTRAINT event_passes_provider_identity CHECK (
    (billing_project_id IS NULL AND billing_environment IS NULL AND revenuecat_purchase_id IS NULL
        AND product_id IS NULL AND store_transaction_id IS NULL AND purchase_unit IS NULL)
    OR (billing_project_id IS NOT NULL AND billing_environment IS NOT NULL AND revenuecat_purchase_id IS NOT NULL
        AND product_id IS NOT NULL AND store_transaction_id IS NOT NULL AND purchase_unit IS NOT NULL)
);

-- Historical rows have neither a trustworthy environment nor canonical state.
-- Retain pass IDs/redemption/poll links; match them explicitly before reactivation.
INSERT INTO private.billing_customers(customer_id,provider_customer_ids)
    SELECT user_id::text,ARRAY[user_id::text] FROM public.subscriptions
    UNION SELECT user_id::text,ARRAY[user_id::text] FROM public.event_passes;
UPDATE public.subscriptions SET is_active=false, entitlement=NULL;
UPDATE public.event_passes SET revoked_at=now(), revocation_reason='legacy_unverified';

ALTER TABLE private.billing_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.billing_inbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.billing_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.billing_identity_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.billing_inbox_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.billing_entitlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.billing_settings,private.billing_inbox,private.billing_customers,
    private.billing_identity_links,private.billing_inbox_targets,private.billing_entitlements FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON private.billing_settings,private.billing_inbox,private.billing_customers,
    private.billing_identity_links,private.billing_inbox_targets,private.billing_entitlements TO service_role;

-- Stable F05 read contract; only backend code may name a user. Time is checked
-- per entitlement, so an expired team grant falls back to an unexpired pro grant.
CREATE FUNCTION private.billing_effective_entitlement(p_user_id UUID)
RETURNS TEXT LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
    SELECT entitlement FROM private.billing_entitlements
    WHERE user_id=p_user_id AND valid_until>now()
    ORDER BY (entitlement='team_access') DESC, valid_until DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION private.billing_effective_entitlement(UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.billing_effective_entitlement(UUID) TO service_role;

CREATE FUNCTION private.billing_refresh_inbox(p_customer_id TEXT)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
    UPDATE private.billing_inbox i SET
        status=CASE WHEN NOT EXISTS (
            SELECT 1 FROM private.billing_inbox_targets t JOIN private.billing_customers c USING(customer_id)
            WHERE t.event_id=i.event_id AND c.completed_revision<t.required_revision
        ) THEN 'processed' WHEN EXISTS (
            SELECT 1 FROM private.billing_inbox_targets t JOIN private.billing_customers c USING(customer_id)
            WHERE t.event_id=i.event_id AND c.completed_revision<t.required_revision AND c.paused
        ) THEN 'quarantined' ELSE 'pending' END,
        processed_at=CASE WHEN NOT EXISTS (
            SELECT 1 FROM private.billing_inbox_targets t JOIN private.billing_customers c USING(customer_id)
            WHERE t.event_id=i.event_id AND c.completed_revision<t.required_revision
        ) THEN now() ELSE NULL END
    WHERE i.event_id IN (SELECT event_id FROM private.billing_inbox_targets WHERE customer_id=p_customer_id);
$$;
REVOKE ALL ON FUNCTION private.billing_refresh_inbox(TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.billing_refresh_inbox(TEXT) TO service_role;

-- Narrow service-only repository. No elevated function is exposed to clients.
CREATE FUNCTION public.billing_admin(p_action TEXT,p_data JSONB DEFAULT '{}')
RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE
    settings private.billing_settings;
    job private.billing_customers;
    incoming JSONB;
    existing private.billing_inbox;
    customer TEXT;
    provider_customer TEXT;
    version BIGINT;
    uid UUID;
    snapshot JSONB;
    entry JSONB;
    selected private.billing_entitlements;
    pass_key TEXT;
    unit INTEGER;
    inserted INTEGER;
    until_at TIMESTAMPTZ;
    snapshot_at TIMESTAMPTZ;
    profile_exists BOOLEAN;
BEGIN
    IF p_action IN ('accept','claim') THEN
        INSERT INTO private.billing_settings(project_id,environment)
            VALUES(p_data->>'project_id',p_data->>'environment') ON CONFLICT DO NOTHING;
        SELECT * INTO STRICT settings FROM private.billing_settings;
        IF settings.project_id IS DISTINCT FROM p_data->>'project_id'
            OR settings.environment IS DISTINCT FROM p_data->>'environment' THEN
            RAISE EXCEPTION 'billing_configuration_mismatch';
        END IF;
    ELSE SELECT * INTO STRICT settings FROM private.billing_settings;
    END IF;

    CASE p_action
    WHEN 'accept' THEN
        incoming:=p_data->'event';
        IF incoming->>'disposition' NOT IN ('pending','ignored','quarantined')
            OR jsonb_typeof(incoming->'customer_ids') IS DISTINCT FROM 'array'
            OR jsonb_array_length(incoming->'customer_ids')>200 THEN RAISE EXCEPTION 'invalid_event'; END IF;
        INSERT INTO private.billing_inbox(event_id,event_type,event_timestamp_ms,event,status,reason,processed_at)
            VALUES(incoming->>'id',incoming->>'type',(incoming->>'event_timestamp_ms')::bigint,incoming,
                incoming->>'disposition',incoming->>'reason',CASE WHEN incoming->>'disposition'='ignored' THEN now() END)
            ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS inserted=ROW_COUNT;
        SELECT * INTO STRICT existing FROM private.billing_inbox WHERE event_id=incoming->>'id' FOR UPDATE;
        IF existing.event IS DISTINCT FROM incoming THEN RAISE EXCEPTION 'event_conflict'; END IF;
        IF inserted=0 THEN RETURN jsonb_build_object('duplicate',true,'status',existing.status); END IF;
        IF existing.status<>'pending' THEN RETURN jsonb_build_object('status',existing.status); END IF;
        FOR provider_customer IN SELECT jsonb_array_elements_text(incoming->'customer_ids') ORDER BY 1 LOOP
            customer:=CASE WHEN provider_customer ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN lower(provider_customer) ELSE coalesce((SELECT user_id::text FROM private.billing_identity_links
                    WHERE provider_customer_id=provider_customer),provider_customer) END;
            INSERT INTO private.billing_customers(customer_id,provider_customer_ids) VALUES(customer,ARRAY[provider_customer])
                ON CONFLICT(customer_id) DO UPDATE SET revision=private.billing_customers.revision+1,
                    provider_customer_ids=ARRAY(SELECT DISTINCT unnest(private.billing_customers.provider_customer_ids||ARRAY[provider_customer]) ORDER BY 1),
                    next_attempt_at=now() RETURNING revision INTO version;
            INSERT INTO private.billing_inbox_targets VALUES(existing.event_id,customer,version)
                ON CONFLICT(event_id,customer_id) DO UPDATE SET required_revision=excluded.required_revision;
        END LOOP;
        RETURN jsonb_build_object('duplicate',false,'status','pending');

    WHEN 'claim' THEN
        SELECT * INTO job FROM private.billing_customers WHERE NOT paused AND next_attempt_at<=now()
            AND (leased_until IS NULL OR leased_until<=now()) ORDER BY next_attempt_at,customer_id
            FOR UPDATE SKIP LOCKED LIMIT 1;
        IF NOT FOUND THEN RETURN NULL; END IF;
        profile_exists:=CASE WHEN job.customer_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN EXISTS(SELECT 1 FROM public.profiles WHERE id=job.customer_id::uuid) ELSE false END;
        -- Current iOS uses UUID.uuidString (uppercase); web/Android use lower.
        -- Probe BOTH spellings, not just whichever emitted the latest event.
        IF profile_exists THEN
            UPDATE private.billing_customers SET provider_customer_ids=ARRAY(SELECT DISTINCT unnest(
                provider_customer_ids||ARRAY[lower(job.customer_id),upper(job.customer_id)]) ORDER BY 1)
                WHERE customer_id=job.customer_id;
        END IF;
        UPDATE private.billing_customers SET lease_id=gen_random_uuid(),leased_until=now()+interval '90 seconds',
            leased_revision=revision,attempts=attempts+1 WHERE customer_id=job.customer_id RETURNING * INTO job;
        RETURN jsonb_build_object('customer_id',job.customer_id,'provider_customer_ids',job.provider_customer_ids,
            'profile_exists',profile_exists,'revision',job.leased_revision,'lease_id',job.lease_id);

    WHEN 'complete' THEN
        SELECT * INTO job FROM private.billing_customers WHERE customer_id=p_data->>'customer_id' FOR UPDATE;
        IF NOT FOUND OR job.lease_id IS NULL OR job.leased_until IS NULL OR job.leased_revision IS NULL
            OR job.lease_id IS DISTINCT FROM (p_data->>'lease_id')::uuid OR job.leased_until<=now()
            OR job.leased_revision IS DISTINCT FROM (p_data->>'revision')::bigint THEN RETURN '"stale"'; END IF;
        IF job.revision<>job.leased_revision THEN
            UPDATE private.billing_customers SET lease_id=NULL,leased_until=NULL,next_attempt_at=now()
                WHERE customer_id=job.customer_id;
            RETURN '"stale"';
        END IF;
        uid:=job.customer_id::uuid;
        IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid) THEN RAISE EXCEPTION 'missing_profile'; END IF;
        snapshot:=p_data->'snapshot';
        snapshot_at:=(snapshot->>'fetched_at')::timestamptz;
        until_at:=(snapshot->>'valid_until')::timestamptz;
        IF snapshot->>'environment' IS DISTINCT FROM settings.environment
            OR snapshot_at IS NULL OR snapshot_at<now()-interval '5 minutes' OR snapshot_at>now()+interval '1 minute'
            OR until_at IS NULL OR until_at<=now() OR until_at>snapshot_at+interval '15 minutes'
            OR jsonb_typeof(snapshot->'entitlements') IS DISTINCT FROM 'array'
            OR jsonb_typeof(snapshot->'passes') IS DISTINCT FROM 'array'
            OR jsonb_array_length(snapshot->'entitlements')>4000 OR jsonb_array_length(snapshot->'passes')>2000
            THEN RAISE EXCEPTION 'invalid_snapshot'; END IF;

        -- Never guess the product/environment of old passes, especially spent
        -- ones: a new receipt must not mint a second spendable copy of a purchase.
        IF EXISTS(SELECT 1 FROM public.event_passes WHERE user_id=uid AND billing_project_id IS NULL)
            THEN RAISE EXCEPTION 'legacy_pass_unmapped'; END IF;
        DELETE FROM private.billing_entitlements WHERE user_id=uid;
        FOR entry IN SELECT jsonb_array_elements(snapshot->'entitlements') LOOP
            INSERT INTO private.billing_entitlements VALUES(uid,entry->>'resource_id',entry->>'entitlement',
                entry->>'product_id',entry->>'store',entry->>'transaction_id',(entry->>'purchased_at')::timestamptz,
                (entry->>'expires_at')::timestamptz,least(until_at,(entry->>'valid_until')::timestamptz));
        END LOOP;
        UPDATE public.event_passes SET revoked_at=coalesce(revoked_at,now()),revocation_reason='not_owned'
            WHERE user_id=uid AND billing_project_id=settings.project_id AND billing_environment=settings.environment;
        FOR entry IN SELECT jsonb_array_elements(snapshot->'passes') LOOP
            IF (entry->>'quantity')::integer NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
            FOR unit IN 1..(entry->>'quantity')::integer LOOP
                pass_key:='rc2:'||jsonb_build_array(settings.project_id,settings.environment,entry->>'store',
                    entry->>'product_id',entry->>'transaction_id',unit)::text;
                INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,billing_project_id,
                    billing_environment,revenuecat_purchase_id,product_id,store_transaction_id,purchase_unit,verified_until)
                VALUES(uid,pass_key,entry->>'store',(entry->>'purchased_at')::timestamptz,settings.project_id,
                    settings.environment,entry->>'purchase_id',entry->>'product_id',entry->>'transaction_id',unit,until_at)
                ON CONFLICT(transaction_id) DO UPDATE SET user_id=excluded.user_id,
                    revenuecat_purchase_id=excluded.revenuecat_purchase_id,purchased_at=excluded.purchased_at,
                    verified_until=excluded.verified_until,
                    revoked_at=NULL,revocation_reason=NULL;
                -- redeemed_at and poll_id are deliberately never reset here.
            END LOOP;
        END LOOP;
        SELECT * INTO selected FROM private.billing_entitlements WHERE user_id=uid AND valid_until>now()
            ORDER BY (entitlement='team_access') DESC,valid_until DESC,resource_id LIMIT 1;
        INSERT INTO public.subscriptions(user_id,revenuecat_app_user_id,original_transaction_id,entitlement,
            is_active,product_id,store,purchased_at,expires_at,cancellation_at,period_type,updated_at,
            billing_contract_version,billing_environment,reconciled_at,access_valid_until)
        VALUES(uid,job.customer_id,selected.transaction_id,selected.entitlement,selected.entitlement IS NOT NULL,
            selected.product_id,selected.store,selected.purchased_at,selected.valid_until,NULL,NULL,now(),
            1,settings.environment,snapshot_at,selected.valid_until)
        ON CONFLICT(user_id) DO UPDATE SET revenuecat_app_user_id=excluded.revenuecat_app_user_id,
            original_transaction_id=excluded.original_transaction_id,entitlement=excluded.entitlement,
            is_active=excluded.is_active,product_id=excluded.product_id,store=excluded.store,
            purchased_at=excluded.purchased_at,expires_at=excluded.expires_at,cancellation_at=NULL,period_type=NULL,
            updated_at=now(),billing_contract_version=1,billing_environment=excluded.billing_environment,
            reconciled_at=excluded.reconciled_at,access_valid_until=excluded.access_valid_until;
        UPDATE private.billing_customers SET completed_revision=job.leased_revision,lease_id=NULL,leased_until=NULL,
            attempts=0,last_error_code=NULL,reconciled_at=snapshot_at,
            next_attempt_at=greatest(now()+interval '30 seconds',least(until_at-interval '1 minute',
                coalesce((SELECT min(valid_until)-interval '30 seconds' FROM private.billing_entitlements WHERE user_id=uid),until_at)))
            WHERE customer_id=job.customer_id;
        PERFORM private.billing_refresh_inbox(job.customer_id);
        RETURN '"applied"';

    WHEN 'fail' THEN
        SELECT * INTO job FROM private.billing_customers WHERE customer_id=p_data->>'customer_id' FOR UPDATE;
        IF NOT FOUND OR job.lease_id IS NULL OR job.leased_revision IS NULL
            OR job.lease_id IS DISTINCT FROM (p_data->>'lease_id')::uuid
            OR job.leased_revision IS DISTINCT FROM (p_data->>'revision')::bigint THEN RETURN 'false'; END IF;
        UPDATE private.billing_customers SET lease_id=NULL,leased_until=NULL,
            paused=coalesce((p_data->>'quarantine')::boolean,false) AND revision=job.leased_revision,
            last_error_code=left(p_data->>'code',80),
            next_attempt_at=CASE WHEN revision<>job.leased_revision THEN now() ELSE now()+make_interval(secs=>
                greatest(30,least(3600,coalesce((p_data->>'retry_after')::integer,60)*power(2,least(attempts-1,5))::integer))) END
            WHERE customer_id=job.customer_id;
        PERFORM private.billing_refresh_inbox(job.customer_id);
        RETURN 'true';

    WHEN 'replay_event' THEN
        SELECT * INTO STRICT existing FROM private.billing_inbox WHERE event_id=p_data->>'event_id' FOR UPDATE;
        IF existing.status='ignored' THEN RAISE EXCEPTION 'ignored_event'; END IF;
        IF jsonb_array_length(existing.event->'customer_ids')=0 THEN RAISE EXCEPTION 'unknown_identity'; END IF;
        UPDATE private.billing_inbox SET status='pending',reason=NULL,processed_at=NULL WHERE event_id=existing.event_id;
        FOR provider_customer IN SELECT jsonb_array_elements_text(existing.event->'customer_ids') ORDER BY 1 LOOP
            customer:=CASE WHEN provider_customer ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                THEN lower(provider_customer) ELSE coalesce((SELECT user_id::text FROM private.billing_identity_links
                    WHERE provider_customer_id=provider_customer),provider_customer) END;
            INSERT INTO private.billing_customers(customer_id,provider_customer_ids) VALUES(customer,ARRAY[provider_customer]) ON CONFLICT(customer_id)
                DO UPDATE SET revision=private.billing_customers.revision+1,paused=false,next_attempt_at=now(),
                    provider_customer_ids=ARRAY(SELECT DISTINCT unnest(private.billing_customers.provider_customer_ids||ARRAY[provider_customer]) ORDER BY 1)
                RETURNING revision INTO version;
            INSERT INTO private.billing_inbox_targets VALUES(existing.event_id,customer,version)
                ON CONFLICT(event_id,customer_id) DO UPDATE SET required_revision=excluded.required_revision;
        END LOOP;
        RETURN 'true';

    WHEN 'queue_customer' THEN
        customer:=(p_data->>'customer_id')::uuid::text;
        provider_customer:=p_data->>'customer_id';
        INSERT INTO private.billing_customers(customer_id,provider_customer_ids) VALUES(customer,ARRAY[provider_customer]) ON CONFLICT(customer_id)
            DO UPDATE SET revision=private.billing_customers.revision+1,paused=false,next_attempt_at=now(),
                provider_customer_ids=ARRAY(SELECT DISTINCT unnest(private.billing_customers.provider_customer_ids||ARRAY[provider_customer]) ORDER BY 1);
        RETURN 'true';

    WHEN 'adopt_legacy_pass' THEN
        -- Operator-verified mapping only; canonical reconciliation must still
        -- confirm ownership before making this receipt available.
        pass_key:='rc2:'||jsonb_build_array(settings.project_id,settings.environment,p_data->>'store',
            p_data->>'product_id',p_data->>'transaction_id',1)::text;
        UPDATE public.event_passes SET billing_project_id=settings.project_id,billing_environment=settings.environment,
            revenuecat_purchase_id=p_data->>'purchase_id',product_id=p_data->>'product_id',
            store_transaction_id=p_data->>'transaction_id',purchase_unit=1,store=p_data->>'store',transaction_id=pass_key
            WHERE id=(p_data->>'pass_id')::uuid AND billing_project_id IS NULL;
        GET DIAGNOSTICS inserted=ROW_COUNT;
        RETURN to_jsonb(inserted=1);

    WHEN 'resolve_identity' THEN
        provider_customer:=p_data->>'provider_customer_id';
        uid:=(p_data->>'user_id')::uuid;
        IF provider_customer ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            AND provider_customer::uuid<>uid THEN RAISE EXCEPTION 'identity_conflict'; END IF;
        IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=uid) THEN RAISE EXCEPTION 'missing_profile'; END IF;
        INSERT INTO private.billing_identity_links(provider_customer_id,user_id,verification_reference)
            VALUES(provider_customer,uid,p_data->>'verification_reference') ON CONFLICT DO NOTHING;
        IF NOT EXISTS(SELECT 1 FROM private.billing_identity_links WHERE provider_customer_id=provider_customer AND user_id=uid)
            THEN RAISE EXCEPTION 'identity_conflict'; END IF;
        INSERT INTO private.billing_customers(customer_id,provider_customer_ids) VALUES(uid::text,ARRAY[provider_customer])
            ON CONFLICT(customer_id) DO UPDATE SET revision=private.billing_customers.revision+1,paused=false,next_attempt_at=now(),
                provider_customer_ids=ARRAY(SELECT DISTINCT unnest(private.billing_customers.provider_customer_ids||ARRAY[provider_customer]) ORDER BY 1)
            RETURNING revision INTO version;
        INSERT INTO private.billing_inbox_targets(event_id,customer_id,required_revision)
            SELECT event_id,uid::text,version FROM private.billing_inbox_targets WHERE customer_id=provider_customer
            ON CONFLICT(event_id,customer_id) DO UPDATE SET required_revision=excluded.required_revision;
        IF provider_customer<>uid::text THEN
            DELETE FROM private.billing_inbox_targets WHERE customer_id=provider_customer;
            UPDATE private.billing_customers SET paused=true,lease_id=NULL,leased_until=NULL,last_error_code='identity_resolved'
                WHERE customer_id=provider_customer;
        END IF;
        PERFORM private.billing_refresh_inbox(uid::text);
        RETURN 'true';
    ELSE RAISE EXCEPTION 'unknown_billing_action';
    END CASE;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_admin(TEXT,JSONB) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.billing_admin(TEXT,JSONB) TO service_role;

-- Keep F02's compatible, invoker-only, self-scoped contract. Inline the same
-- identity guard so this migration also replays on the shared baseline alone.
CREATE OR REPLACE FUNCTION public.count_unredeemed_passes(user_uuid UUID DEFAULT auth.uid())
RETURNS INTEGER LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE caller_id UUID:=auth.uid();
BEGIN
    IF caller_id IS NULL OR user_uuid IS NULL OR user_uuid IS DISTINCT FROM caller_id THEN
        RAISE EXCEPTION 'Authentication required for own account' USING ERRCODE='42501';
    END IF;
    RETURN (SELECT count(*)::integer FROM public.event_passes ep WHERE ep.user_id=caller_id
        AND ep.redeemed_at IS NULL AND ep.revoked_at IS NULL AND ep.billing_project_id IS NOT NULL
        AND ep.verified_until>now());
END;
$$;
REVOKE ALL ON FUNCTION public.count_unredeemed_passes(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.count_unredeemed_passes(UUID) TO authenticated;
