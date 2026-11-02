-- F17: per-user budget for Google conflict checks, agreed with the owner on
-- November 2, 2026. Edge Function instances share no memory, so the count lives here.
CREATE TABLE private.calendar_check_admissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    admitted_at TIMESTAMPTZ NOT NULL,
    lease_expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX calendar_check_admissions_user ON private.calendar_check_admissions(user_id, admitted_at);
CREATE INDEX calendar_check_admissions_age ON private.calendar_check_admissions(admitted_at);

ALTER TABLE private.calendar_check_admissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.calendar_check_admissions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON private.calendar_check_admissions TO service_role;

-- Admits one conflict check or says when to retry. Rejected attempts are not recorded,
-- so a client that keeps retrying cannot extend its own wait. The per-user lock makes
-- the count and the insert one decision; decision time is read after any lock wait.
CREATE FUNCTION private.calendar_admit_check(p_user_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
    max_per_minute CONSTANT INTEGER := 20;
    max_per_hour CONSTANT INTEGER := 200;
    max_in_flight CONSTANT INTEGER := 2;
    -- Outlasts a check's four 10-second provider calls, so a crashed worker
    -- frees its slot and provider calls alone can't outlast the lease.
    lease CONSTANT INTERVAL := interval '60 seconds';
    decided TIMESTAMPTZ;
    last_minute INTEGER;
    last_hour INTEGER;
    in_flight INTEGER;
    retry_at TIMESTAMPTZ;
    admission UUID;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('calendar_check:' || p_user_id::text, 0));
    decided := clock_timestamp();
    DELETE FROM private.calendar_check_admissions
    WHERE user_id = p_user_id AND admitted_at <= decided - interval '1 hour';
    SELECT count(*), count(*) FILTER (WHERE admitted_at > decided - interval '1 minute'),
        count(*) FILTER (WHERE lease_expires_at > decided)
    INTO last_hour, last_minute, in_flight
    FROM private.calendar_check_admissions WHERE user_id = p_user_id;

    IF last_hour >= max_per_hour THEN
        SELECT min(admitted_at) + interval '1 hour' INTO retry_at
        FROM private.calendar_check_admissions WHERE user_id = p_user_id;
    ELSIF last_minute >= max_per_minute THEN
        SELECT min(admitted_at) + interval '1 minute' INTO retry_at
        FROM private.calendar_check_admissions
        WHERE user_id = p_user_id AND admitted_at > decided - interval '1 minute';
    ELSIF in_flight >= max_in_flight THEN
        -- A finished check frees its slot before the lease ends, so suggest a short retry.
        SELECT LEAST(min(lease_expires_at), decided + interval '5 seconds') INTO retry_at
        FROM private.calendar_check_admissions
        WHERE user_id = p_user_id AND lease_expires_at > decided;
    END IF;
    IF retry_at IS NOT NULL THEN
        RETURN jsonb_build_object('admitted', FALSE,
            'retry_after', GREATEST(1, ceil(extract(epoch FROM retry_at - decided)))::integer);
    END IF;

    INSERT INTO private.calendar_check_admissions(user_id, admitted_at, lease_expires_at)
    VALUES (p_user_id, decided, decided + lease) RETURNING id INTO admission;
    RETURN jsonb_build_object('admitted', TRUE, 'id', admission);
END;
$$;
REVOKE ALL ON FUNCTION private.calendar_admit_check(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.calendar_admit_check(UUID) TO service_role;

-- Only the two check operations and the maintenance prune differ from the original dispatcher.
CREATE OR REPLACE FUNCTION public.calendar_admin(p_action TEXT, p_user_id UUID DEFAULT NULL,
    p_data JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
    connection private.calendar_connections;
    attempt private.calendar_oauth_attempts;
    affected INTEGER;
    result JSONB;
BEGIN
    CASE p_action
    WHEN 'session' THEN
        RETURN to_jsonb(private.calendar_session_active(p_user_id, (p_data->>'session_id')::uuid));
    WHEN 'read' THEN
        SELECT * INTO connection FROM private.calendar_connections WHERE user_id = p_user_id;
        RETURN CASE WHEN FOUND THEN to_jsonb(connection) ELSE NULL END;
    WHEN 'pending_revocation' THEN
        RETURN to_jsonb(EXISTS(SELECT 1 FROM private.calendar_revocations WHERE user_id = p_user_id));
    WHEN 'begin' THEN
        IF NOT private.calendar_session_active(p_user_id, (p_data->>'session_id')::uuid) THEN
            RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
        END IF;
        INSERT INTO private.calendar_connections(user_id) VALUES (p_user_id)
            ON CONFLICT (user_id) DO NOTHING;
        SELECT * INTO connection FROM private.calendar_connections WHERE user_id = p_user_id FOR UPDATE;
        IF EXISTS(SELECT 1 FROM private.calendar_revocations WHERE user_id = p_user_id) THEN
            RAISE EXCEPTION 'Revocation pending' USING ERRCODE = '55000';
        END IF;
        DELETE FROM private.calendar_oauth_attempts WHERE expires_at <= now()
            OR (user_id = p_user_id AND consumed_at IS NULL);
        IF EXISTS(SELECT 1 FROM private.calendar_oauth_attempts WHERE user_id = p_user_id)
            OR connection.refresh_token_ciphertext IS NOT NULL THEN
            RAISE EXCEPTION 'Calendar operation pending' USING ERRCODE = '55000';
        END IF;
        UPDATE private.calendar_connections SET generation = gen_random_uuid(), updated_at = now()
            WHERE user_id = p_user_id RETURNING * INTO connection;
        INSERT INTO private.calendar_oauth_attempts(state_hash, user_id, session_id, generation,
            verifier_ciphertext, return_to, expires_at)
        VALUES (p_data->>'state_hash', p_user_id, (p_data->>'session_id')::uuid, connection.generation,
            p_data->>'verifier_ciphertext', p_data->>'return_to', now() + interval '10 minutes');
        RETURN to_jsonb(connection.generation);
    WHEN 'consume' THEN
        -- Keep a bounded processing fence until connect/finish_callback commits.
        -- Supabase's worker lifetime and provider timeouts are shorter than this lease.
        UPDATE private.calendar_oauth_attempts SET consumed_at = now(), expires_at = now() + interval '10 minutes'
            WHERE state_hash = p_data->>'state_hash' AND consumed_at IS NULL AND expires_at > now()
                AND private.calendar_session_active(user_id, session_id)
            RETURNING * INTO attempt;
        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
        RETURN to_jsonb(attempt);
    WHEN 'connect' THEN
        UPDATE private.calendar_connections SET
            access_token_ciphertext = p_data->>'access_token_ciphertext',
            refresh_token_ciphertext = p_data->>'refresh_token_ciphertext',
            expires_at = (p_data->>'expires_at')::timestamptz,
            provider_subject = p_data->>'provider_subject', provider_email = p_data->>'provider_email',
            credential_version = gen_random_uuid(), needs_reconnect = FALSE, updated_at = now()
        WHERE user_id = p_user_id AND generation = (p_data->>'generation')::uuid
            AND private.calendar_session_active(p_user_id, (p_data->>'session_id')::uuid)
            AND EXISTS(SELECT 1 FROM private.calendar_oauth_attempts a
                WHERE a.state_hash = p_data->>'state_hash' AND a.user_id = p_user_id
                    AND a.session_id = (p_data->>'session_id')::uuid
                    AND a.generation = (p_data->>'generation')::uuid
                    AND a.consumed_at IS NOT NULL AND a.expires_at > now())
            AND NOT EXISTS(SELECT 1 FROM private.calendar_revocations WHERE user_id = p_user_id);
        GET DIAGNOSTICS affected = ROW_COUNT;
        IF affected = 1 THEN
            DELETE FROM private.calendar_oauth_attempts WHERE state_hash = p_data->>'state_hash' AND user_id = p_user_id;
        END IF;
        RETURN to_jsonb(affected = 1);
    WHEN 'refresh', 'rewrap' THEN
        UPDATE private.calendar_connections SET
            access_token_ciphertext = p_data->>'access_token_ciphertext',
            refresh_token_ciphertext = p_data->>'refresh_token_ciphertext',
            expires_at = COALESCE((p_data->>'expires_at')::timestamptz, expires_at),
            credential_version = gen_random_uuid(), updated_at = now()
        WHERE user_id = p_user_id AND generation = (p_data->>'generation')::uuid
            AND credential_version = (p_data->>'credential_version')::uuid
            AND refresh_token_ciphertext IS NOT NULL;
        GET DIAGNOSTICS affected = ROW_COUNT;
        RETURN to_jsonb(affected = 1);
    WHEN 'invalidate' THEN
        UPDATE private.calendar_connections SET needs_reconnect = TRUE, updated_at = now()
        WHERE user_id = p_user_id AND generation = (p_data->>'generation')::uuid
            AND credential_version = (p_data->>'credential_version')::uuid;
        RETURN 'null'::jsonb;
    WHEN 'disconnect' THEN
        -- Lock the same row used by begin/connect/refresh before enqueuing or
        -- clearing anything, fencing callbacks and refreshes already in flight.
        INSERT INTO private.calendar_connections(user_id) VALUES (p_user_id)
            ON CONFLICT (user_id) DO NOTHING;
        SELECT * INTO connection FROM private.calendar_connections WHERE user_id = p_user_id FOR UPDATE;
        IF FOUND THEN
            IF connection.refresh_token_ciphertext IS NOT NULL THEN
                INSERT INTO private.calendar_revocations(user_id, token_ciphertext)
                VALUES (p_user_id, connection.refresh_token_ciphertext);
            END IF;
            UPDATE private.calendar_connections SET generation = gen_random_uuid(),
                credential_version = gen_random_uuid(), access_token_ciphertext = NULL,
                refresh_token_ciphertext = NULL, expires_at = NULL, provider_subject = NULL,
                provider_email = NULL, needs_reconnect = FALSE, updated_at = now()
            WHERE user_id = p_user_id;
        END IF;
        DELETE FROM private.calendar_oauth_attempts WHERE user_id = p_user_id AND consumed_at IS NULL;
        RETURN 'null'::jsonb;
    WHEN 'finish_callback' THEN
        -- Queue cleanup before releasing the processing fence. Google revocation
        -- is grant-wide: an older callback must never revoke a newer connection.
        IF p_data->>'token_ciphertext' IS NOT NULL THEN
            INSERT INTO private.calendar_revocations(user_id, token_ciphertext)
                VALUES (p_user_id, p_data->>'token_ciphertext');
        END IF;
        DELETE FROM private.calendar_oauth_attempts WHERE state_hash = p_data->>'state_hash' AND user_id = p_user_id;
        RETURN 'null'::jsonb;
    WHEN 'claim_revocations' THEN
        WITH due AS (
            SELECT id FROM private.calendar_revocations
            WHERE (p_user_id IS NULL OR user_id = p_user_id) AND next_attempt_at <= now()
                AND (leased_until IS NULL OR leased_until <= now())
            ORDER BY next_attempt_at LIMIT 20 FOR UPDATE SKIP LOCKED
        ), claimed AS (
            UPDATE private.calendar_revocations r SET lease_id = gen_random_uuid(),
                leased_until = now() + interval '60 seconds', attempts = attempts + 1
            FROM due WHERE r.id = due.id RETURNING r.*
        ) SELECT COALESCE(jsonb_agg(to_jsonb(claimed)), '[]'::jsonb) INTO result FROM claimed;
        RETURN result;
    WHEN 'finish_revocation' THEN
        IF (p_data->>'success')::boolean THEN
            DELETE FROM private.calendar_revocations
            WHERE id = (p_data->>'id')::uuid AND lease_id = (p_data->>'lease_id')::uuid;
        ELSE
            UPDATE private.calendar_revocations SET lease_id = NULL, leased_until = NULL,
                next_attempt_at = now() + interval '1 minute' * LEAST(60, power(2, LEAST(attempts, 6)))
            WHERE id = (p_data->>'id')::uuid AND lease_id = (p_data->>'lease_id')::uuid;
        END IF;
        RETURN 'null'::jsonb;
    WHEN 'rotation_candidates' THEN
        DELETE FROM private.calendar_check_admissions WHERE id IN (
            SELECT id FROM private.calendar_check_admissions
            WHERE admitted_at <= now() - interval '1 hour' LIMIT 1000
        );
        DELETE FROM private.calendar_oauth_attempts WHERE state_hash IN (
            SELECT state_hash FROM private.calendar_oauth_attempts WHERE expires_at <= now() LIMIT 1000
        );
        SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO result FROM (
            SELECT * FROM private.calendar_connections
            WHERE refresh_token_ciphertext IS NOT NULL AND (
                refresh_token_ciphertext::jsonb->>'key_id' IS DISTINCT FROM p_data->>'key_id'
                OR access_token_ciphertext::jsonb->>'key_id' IS DISTINCT FROM p_data->>'key_id')
            ORDER BY updated_at LIMIT 100
        ) c;
        RETURN result;
    WHEN 'admit_check' THEN
        RETURN private.calendar_admit_check(p_user_id);
    WHEN 'finish_check' THEN
        -- A finished check frees its concurrency slot but still counts against the budget.
        UPDATE private.calendar_check_admissions SET lease_expires_at = LEAST(lease_expires_at, clock_timestamp())
        WHERE id = (p_data->>'id')::uuid AND user_id = p_user_id;
        RETURN 'null'::jsonb;
    ELSE
        RAISE EXCEPTION 'Unsupported calendar operation' USING ERRCODE = '22023';
    END CASE;
END;
$$;
