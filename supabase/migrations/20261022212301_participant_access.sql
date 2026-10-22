-- F03: participant access.
--
-- * Participant rows are visible only through an active invitation, poll
--   ownership, or current authenticated membership. The global USING (true)
--   read policy from 00010 is removed.
-- * The public table no longer stores secrets. access_token becomes a
--   deprecated, non-secret alias of id (kept for installed clients that decode
--   it), and guest contact emails move to private storage.
-- * Identity, poll, and capability columns cannot be changed through the API.
--   Authenticated members can update only their own comment.
-- * Guests receive a separate high-entropy capability from
--   join_poll_as_guest. Only its SHA-256 verifier is stored, privately.
--   Previously published access_token values authorize nothing.
--
-- Membership binding, uniqueness, and an idempotent member join are F04.
-- Response-write invariants and closed-state rules for members are F06.
BEGIN;

-- ---------------------------------------------------------------------------
-- Private guest storage. The private schema has no client USAGE (see the
-- calendar and billing migrations); only elevated helpers below can reach it.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO service_role;

CREATE TABLE private.participant_guest_credentials (
    -- Deferred so the BEFORE INSERT trigger can store a contact email for a
    -- participant row that is inserted later in the same statement.
    participant_id UUID PRIMARY KEY
        REFERENCES public.poll_participants(id) ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED,
    -- SHA-256 of the guest capability. NULL for legacy guests, which never
    -- received a private capability.
    token_hash BYTEA UNIQUE CHECK (token_hash IS NULL OR length(token_hash) = 32),
    token_issued_at TIMESTAMPTZ,
    contact_email TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT participant_guest_token_issued CHECK ((token_hash IS NULL) = (token_issued_at IS NULL))
);
ALTER TABLE private.participant_guest_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.participant_guest_credentials FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Remove published secrets from the public table.
-- ---------------------------------------------------------------------------
-- Keep previously collected guest emails, but only in private storage.
INSERT INTO private.participant_guest_credentials (participant_id, contact_email)
SELECT pp.id, pp.anonymous_email
FROM public.poll_participants pp
WHERE pp.anonymous_email IS NOT NULL;

-- Every existing access_token was globally readable, so treat all of them as
-- disclosed. Nothing verified them; replace them with the participant id so the
-- column keeps a non-null UUID for installed clients but carries no secret.
-- updated_at is left untouched: this is not a participant change.
ALTER TABLE public.poll_participants DISABLE TRIGGER update_poll_participants_updated_at;
UPDATE public.poll_participants
SET access_token = id, anonymous_email = NULL
WHERE access_token IS DISTINCT FROM id OR anonymous_email IS NOT NULL;
ALTER TABLE public.poll_participants ENABLE TRIGGER update_poll_participants_updated_at;

ALTER TABLE public.poll_participants
    ALTER COLUMN access_token DROP DEFAULT,
    ALTER COLUMN access_token SET NOT NULL,
    ADD CONSTRAINT participant_access_token_not_secret CHECK (access_token = id),
    ADD CONSTRAINT participant_email_private CHECK (anonymous_email IS NULL);

COMMENT ON COLUMN public.poll_participants.access_token IS
    'Deprecated. Always equals id and is not a credential. Guest capabilities are issued by join_poll_as_guest.';
COMMENT ON COLUMN public.poll_participants.anonymous_email IS
    'Deprecated. Always NULL; guest contact emails are stored privately.';

-- ---------------------------------------------------------------------------
-- Write normalization and identity protection.
-- ---------------------------------------------------------------------------
-- Invoker trigger: current_user is the API role for direct Data API writes and
-- the function owner inside elevated commands, which may change these fields.
CREATE FUNCTION poll_private.protect_participant_identity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    api_caller BOOLEAN := current_user IN ('anon', 'authenticated');
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.id IS DISTINCT FROM OLD.id OR (api_caller AND (
            NEW.poll_id IS DISTINCT FROM OLD.poll_id
            OR NEW.user_id IS DISTINCT FROM OLD.user_id
            OR NEW.anonymous_name IS DISTINCT FROM OLD.anonymous_name
            OR NEW.anonymous_email IS DISTINCT FROM OLD.anonymous_email
            OR NEW.access_token IS DISTINCT FROM OLD.access_token
            OR NEW.created_at IS DISTINCT FROM OLD.created_at
        )) THEN
            RAISE EXCEPTION 'Participant identity fields cannot be changed' USING ERRCODE = '42501';
        END IF;
    ELSIF api_caller THEN
        NEW.created_at := now();
        NEW.updated_at := now();
    END IF;
    NEW.access_token := NEW.id;
    RETURN NEW;
END;
$$;

-- Elevated only to write private storage. Moves any supplied contact email out
-- of the public row before it is stored or published through Realtime.
CREATE FUNCTION poll_private.store_participant_contact()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NEW.anonymous_email IS NOT NULL THEN
        IF btrim(NEW.anonymous_email) <> '' THEN
            INSERT INTO private.participant_guest_credentials (participant_id, contact_email)
            VALUES (NEW.id, left(btrim(NEW.anonymous_email), 320))
            ON CONFLICT (participant_id) DO UPDATE
                SET contact_email = EXCLUDED.contact_email, updated_at = now();
        END IF;
        NEW.anonymous_email := NULL;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION poll_private.protect_participant_identity(),
    poll_private.store_participant_contact() FROM PUBLIC, anon, authenticated;

-- BEFORE triggers fire in name order: reject identity changes first, then move
-- contact data, then the existing update_poll_participants_updated_at trigger.
CREATE TRIGGER participants_10_protect_identity
    BEFORE INSERT OR UPDATE ON public.poll_participants
    FOR EACH ROW EXECUTE FUNCTION poll_private.protect_participant_identity();
CREATE TRIGGER participants_20_private_contact
    BEFORE INSERT OR UPDATE OF anonymous_email ON public.poll_participants
    FOR EACH ROW EXECUTE FUNCTION poll_private.store_participant_contact();

-- Members may change only their comment through the Data API. Guests and
-- other fields go through the commands below. The trigger above still guards
-- identity fields if broader grants are later reapplied.
REVOKE UPDATE ON public.poll_participants FROM anon, authenticated;
GRANT UPDATE (comment) ON public.poll_participants TO authenticated;

-- ---------------------------------------------------------------------------
-- Read and update policies.
-- ---------------------------------------------------------------------------
-- An active poll is an open invitation: its participant list (safe columns
-- only, after the changes above) is visible to anyone who opens it. Draft,
-- closed, and archived participant lists require ownership or membership.
CREATE FUNCTION poll_private.can_view_participants(poll_uuid UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.polls p
        WHERE p.id = poll_uuid AND (
            p.status = 'active'
            OR ((SELECT auth.uid()) IS NOT NULL AND (
                p.creator_id = (SELECT auth.uid())
                OR poll_private.is_poll_participant(p.id)
            ))
        )
    );
$$;
REVOKE ALL ON FUNCTION poll_private.can_view_participants(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.can_view_participants(UUID) TO anon, authenticated, service_role;

DROP POLICY IF EXISTS "Participants can view poll participants" ON public.poll_participants;
DROP POLICY IF EXISTS "Users can view participants for accessible polls" ON public.poll_participants;
DROP POLICY IF EXISTS "Users can update their own comment" ON public.poll_participants;
DROP POLICY IF EXISTS "Participants can update own record" ON public.poll_participants;

CREATE POLICY "Participants are visible through invitation or membership"
    ON public.poll_participants FOR SELECT TO anon, authenticated
    USING (poll_private.can_view_participants(poll_id));

CREATE POLICY "Members can update their own participant record"
    ON public.poll_participants FOR UPDATE TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- Guest capability commands.
-- ---------------------------------------------------------------------------
-- 64 lowercase hex characters from two v4 UUIDs (244 random bits from
-- PostgreSQL's strong random source). Never stored; only its SHA-256 is.
CREATE FUNCTION poll_private.new_guest_token()
RETURNS TEXT
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT encode(uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()), 'hex');
$$;

CREATE FUNCTION poll_private.guest_token_hash(guest_token TEXT)
RETURNS BYTEA
LANGUAGE sql IMMUTABLE SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT CASE WHEN guest_token ~ '^[0-9a-f]{64}$'
        THEN sha256(convert_to(guest_token, 'UTF8')) END;
$$;

-- Internal verifier for elevated commands (including later F04/F06 commands).
-- Returns the verified guest participant id or NULL. Claimed rows (user_id set)
-- are never guest-editable. Not granted to API roles.
CREATE FUNCTION poll_private.verified_guest_participant(participant_uuid UUID, guest_token TEXT)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT pp.id
    FROM public.poll_participants pp
    JOIN private.participant_guest_credentials c ON c.participant_id = pp.id
    WHERE pp.id = participant_uuid
      AND pp.user_id IS NULL
      AND c.token_hash = poll_private.guest_token_hash(guest_token);
$$;

REVOKE ALL ON FUNCTION poll_private.new_guest_token(), poll_private.guest_token_hash(TEXT),
    poll_private.verified_guest_participant(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.verified_guest_participant(UUID, TEXT) TO service_role;

CREATE FUNCTION poll_private.join_poll_as_guest(poll_uuid UUID, display_name TEXT, contact_email TEXT)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    guest_name TEXT := btrim(display_name);
    guest_email TEXT := nullif(btrim(contact_email), '');
    token TEXT;
    participant public.poll_participants;
BEGIN
    IF auth.uid() IS NOT NULL THEN
        RAISE EXCEPTION 'Signed-in callers must join as members' USING ERRCODE = '42501';
    END IF;
    -- Hold the poll state for this transaction so a concurrent close cannot
    -- interleave with the join. Missing and closed polls share one error.
    PERFORM 1 FROM public.polls p
    WHERE p.id = poll_uuid AND p.status = 'active'
      AND (p.closes_at IS NULL OR p.closes_at > now())
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE = '42501';
    END IF;
    IF guest_name IS NULL OR length(guest_name) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'Guest display name must be 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    IF guest_email IS NOT NULL AND (length(guest_email) > 320 OR guest_email !~ '^[^@[:space:]]+@[^@[:space:]]+$') THEN
        RAISE EXCEPTION 'Guest contact email is invalid' USING ERRCODE = '22023';
    END IF;

    token := poll_private.new_guest_token();
    INSERT INTO public.poll_participants (poll_id, anonymous_name, anonymous_email)
    VALUES (poll_uuid, guest_name, guest_email)
    RETURNING * INTO participant;
    INSERT INTO private.participant_guest_credentials (participant_id, token_hash, token_issued_at)
    VALUES (participant.id, poll_private.guest_token_hash(token), now())
    ON CONFLICT (participant_id) DO UPDATE
        SET token_hash = EXCLUDED.token_hash, token_issued_at = EXCLUDED.token_issued_at, updated_at = now();

    RETURN json_build_object('participant', row_to_json(participant), 'guest_token', token);
END;
$$;

CREATE FUNCTION poll_private.get_guest_participant(participant_uuid UUID, guest_token TEXT)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'participant', row_to_json(pp),
        'poll', json_build_object('id', p.id, 'status', p.status, 'closes_at', p.closes_at)
    ) INTO result
    FROM public.poll_participants pp
    JOIN public.polls p ON p.id = pp.poll_id
    WHERE pp.id = poll_private.verified_guest_participant(participant_uuid, guest_token);
    IF result IS NULL THEN
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END IF;
    RETURN result;
END;
$$;

-- Replaces both guest-editable fields: send the current display name and the
-- desired comment (NULL clears it). Accepted only while the poll is open.
CREATE FUNCTION poll_private.update_guest_participant(
    participant_uuid UUID, guest_token TEXT, display_name TEXT, comment TEXT)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    guest_id UUID := poll_private.verified_guest_participant(participant_uuid, guest_token);
    guest_name TEXT := btrim(display_name);
    participant public.poll_participants;
BEGIN
    IF guest_id IS NULL THEN
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END IF;
    PERFORM 1 FROM public.polls p
    JOIN public.poll_participants pp ON pp.poll_id = p.id
    WHERE pp.id = guest_id AND p.status = 'active'
      AND (p.closes_at IS NULL OR p.closes_at > now())
    FOR SHARE OF p;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll is not accepting changes' USING ERRCODE = '42501';
    END IF;
    IF guest_name IS NULL OR length(guest_name) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'Guest display name must be 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    IF char_length(comment) > 500 THEN
        RAISE EXCEPTION 'Comment must be 500 characters or fewer' USING ERRCODE = '22023';
    END IF;

    UPDATE public.poll_participants pp
    SET anonymous_name = guest_name, comment = update_guest_participant.comment
    WHERE pp.id = guest_id
    RETURNING * INTO participant;
    RETURN row_to_json(participant);
END;
$$;

-- Issues a new capability and invalidates the presented one.
CREATE FUNCTION poll_private.rotate_guest_token(participant_uuid UUID, guest_token TEXT)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    token TEXT := poll_private.new_guest_token();
BEGIN
    UPDATE private.participant_guest_credentials c
    SET token_hash = poll_private.guest_token_hash(token), token_issued_at = now(), updated_at = now()
    WHERE c.participant_id = poll_private.verified_guest_participant(participant_uuid, guest_token)
      AND c.token_hash = poll_private.guest_token_hash(guest_token);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END IF;
    RETURN token;
END;
$$;

REVOKE ALL ON FUNCTION poll_private.join_poll_as_guest(UUID, TEXT, TEXT),
    poll_private.get_guest_participant(UUID, TEXT),
    poll_private.update_guest_participant(UUID, TEXT, TEXT, TEXT),
    poll_private.rotate_guest_token(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.join_poll_as_guest(UUID, TEXT, TEXT),
    poll_private.get_guest_participant(UUID, TEXT),
    poll_private.update_guest_participant(UUID, TEXT, TEXT, TEXT),
    poll_private.rotate_guest_token(UUID, TEXT) TO anon, authenticated, service_role;

-- Exposed invoker wrappers, following the F02 pattern: the public schema holds
-- no elevated entry points; authorization lives in the private definers.
CREATE FUNCTION public.join_poll_as_guest(poll_uuid UUID, display_name TEXT, contact_email TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.join_poll_as_guest(poll_uuid, display_name, contact_email); $$;

CREATE FUNCTION public.get_guest_participant(participant_uuid UUID, guest_token TEXT)
RETURNS JSON
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.get_guest_participant(participant_uuid, guest_token); $$;

CREATE FUNCTION public.update_guest_participant(
    participant_uuid UUID, guest_token TEXT, display_name TEXT, comment TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.update_guest_participant(participant_uuid, guest_token, display_name, comment); $$;

CREATE FUNCTION public.rotate_guest_token(participant_uuid UUID, guest_token TEXT)
RETURNS TEXT
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.rotate_guest_token(participant_uuid, guest_token); $$;

REVOKE ALL ON FUNCTION public.join_poll_as_guest(UUID, TEXT, TEXT),
    public.get_guest_participant(UUID, TEXT),
    public.update_guest_participant(UUID, TEXT, TEXT, TEXT),
    public.rotate_guest_token(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.join_poll_as_guest(UUID, TEXT, TEXT),
    public.get_guest_participant(UUID, TEXT),
    public.update_guest_participant(UUID, TEXT, TEXT, TEXT),
    public.rotate_guest_token(UUID, TEXT) TO anon, authenticated, service_role;

COMMIT;
