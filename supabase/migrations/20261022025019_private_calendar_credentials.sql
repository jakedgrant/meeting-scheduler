-- Internal testing reset: discard formerly exposed credentials. Reconnect Google
-- after revoking the old grant. Never copy these plaintext tokens to the new store.
ALTER TABLE public.profiles
    DROP COLUMN IF EXISTS google_calendar_access_token,
    DROP COLUMN IF EXISTS google_calendar_refresh_token,
    DROP COLUMN IF EXISTS google_calendar_token_expires_at,
    DROP COLUMN IF EXISTS calendar_integration_enabled;

-- This schema must remain absent from the Data API's exposed schemas.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO service_role;

CREATE TABLE private.calendar_connections (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    generation UUID NOT NULL DEFAULT gen_random_uuid(),
    credential_version UUID NOT NULL DEFAULT gen_random_uuid(),
    access_token_ciphertext TEXT,
    refresh_token_ciphertext TEXT,
    expires_at TIMESTAMPTZ,
    provider_subject TEXT,
    provider_email TEXT,
    needs_reconnect BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT calendar_complete_credentials CHECK (
        (access_token_ciphertext IS NULL AND refresh_token_ciphertext IS NULL AND expires_at IS NULL)
        OR (access_token_ciphertext IS NOT NULL AND refresh_token_ciphertext IS NOT NULL
            AND expires_at IS NOT NULL AND provider_subject IS NOT NULL)
    ),
    CONSTRAINT calendar_ciphertext_size CHECK (
        length(access_token_ciphertext) <= 24000 AND length(refresh_token_ciphertext) <= 24000
    )
);

CREATE TABLE private.calendar_oauth_attempts (
    state_hash TEXT PRIMARY KEY CHECK (state_hash ~ '^[a-f0-9]{64}$'),
    user_id UUID NOT NULL UNIQUE REFERENCES private.calendar_connections(user_id) ON DELETE CASCADE,
    -- Keep an in-flight exchange fenced even if its login session is deleted.
    -- The helper below checks session liveness; an FK cascade would remove the fence.
    session_id UUID NOT NULL,
    generation UUID NOT NULL,
    verifier_ciphertext TEXT NOT NULL CHECK (length(verifier_ciphertext) <= 24000),
    return_to TEXT NOT NULL CHECK (length(return_to) <= 2048),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);
CREATE INDEX calendar_oauth_expiry ON private.calendar_oauth_attempts(expires_at);

-- Retain only encrypted tokens until Google confirms revocation. There is no FK
-- to auth.users: queued revocations must survive deletion of the owning account.
CREATE TABLE private.calendar_revocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token_ciphertext TEXT NOT NULL CHECK (length(token_ciphertext) <= 24000),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_id UUID,
    leased_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX calendar_revocations_due ON private.calendar_revocations(next_attempt_at);
CREATE INDEX calendar_revocations_user ON private.calendar_revocations(user_id);

ALTER TABLE private.calendar_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.calendar_oauth_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.calendar_revocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.calendar_connections, private.calendar_oauth_attempts,
    private.calendar_revocations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON private.calendar_connections,
    private.calendar_oauth_attempts, private.calendar_revocations TO service_role;

-- A private, pinned helper is the only code needing elevated auth-schema reads.
-- The exposed dispatcher below is SECURITY INVOKER and executable only by the
-- backend service role; neither authenticated clients nor anon can call it.
CREATE FUNCTION private.calendar_session_active(p_user_id UUID, p_session_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM auth.sessions s JOIN auth.users u ON u.id = s.user_id
        WHERE s.id = p_session_id AND s.user_id = p_user_id
          AND (s.not_after IS NULL OR s.not_after > now())
          AND u.deleted_at IS NULL
          AND (u.banned_until IS NULL OR u.banned_until <= now())
    );
$$;
REVOKE ALL ON FUNCTION private.calendar_session_active(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.calendar_session_active(UUID, UUID) TO service_role;

CREATE FUNCTION private.queue_deleted_calendar_revocation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF OLD.refresh_token_ciphertext IS NOT NULL THEN
        INSERT INTO private.calendar_revocations(user_id, token_ciphertext)
        VALUES (OLD.user_id, OLD.refresh_token_ciphertext);
    END IF;
    RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION private.queue_deleted_calendar_revocation() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER calendar_revoke_on_account_delete
    BEFORE DELETE ON private.calendar_connections
    FOR EACH ROW EXECUTE FUNCTION private.queue_deleted_calendar_revocation();

-- A finite backend repository API, not a client RPC. All identity parameters are
-- supplied by verified Edge Function context or a consumed one-time OAuth state.
CREATE FUNCTION public.calendar_admin(p_action TEXT, p_user_id UUID DEFAULT NULL,
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
    ELSE
        RAISE EXCEPTION 'Unsupported calendar operation' USING ERRCODE = '22023';
    END CASE;
END;
$$;
REVOKE ALL ON FUNCTION public.calendar_admin(TEXT, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calendar_admin(TEXT, UUID, JSONB) TO service_role;

COMMENT ON TABLE private.calendar_connections IS
    'Backend-only Google Calendar tokens, encrypted using an Edge Function key ring outside the database.';
