-- F04: membership integrity.
--
-- * Reconciles duplicate authenticated memberships onto one deterministic
--   surviving row, keeping every response and comment (the newest value wins
--   per time option and for the comment) and archiving all pre-merge data.
-- * Adds a partial unique index: one membership per (poll_id, user_id).
-- * Adds join_poll, an idempotent member join that derives identity from
--   auth.uid(), and makes guest joins idempotent with a client-generated
--   capability. Adds claim_guest_participant, which requires the capability.
-- * Binds direct inserts to the caller and blocks moving a membership to
--   another poll or another user, for every role.
--
-- Builds on F03 (20261022212301_participant_access.sql): guest capabilities,
-- private storage, and the identity trigger.
BEGIN;

-- Keep direct joins and response writes out until the index exists.
LOCK TABLE public.poll_participants IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.availability_responses IN SHARE ROW EXCLUSIVE MODE;

-- ---------------------------------------------------------------------------
-- Duplicate reconciliation.
-- ---------------------------------------------------------------------------
-- Full pre-merge copies of every participant row in a duplicate group,
-- including the survivor, with all of its responses and private data.
CREATE TABLE private.participant_merge_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    survivor_id UUID NOT NULL,
    participant_id UUID NOT NULL,
    merge_role TEXT NOT NULL CHECK (merge_role IN ('survivor', 'duplicate')),
    participant JSONB NOT NULL,
    responses JSONB NOT NULL,
    private_credentials JSONB
);
ALTER TABLE private.participant_merge_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.participant_merge_audit FROM PUBLIC, anon, authenticated, service_role;

-- Survivor: earliest created_at, then lowest id.
CREATE TEMP TABLE f04_membership_groups ON COMMIT DROP AS
SELECT ranked.participant_id, ranked.survivor_id
FROM (
    SELECT pp.id AS participant_id,
           first_value(pp.id) OVER w AS survivor_id,
           count(*) OVER (PARTITION BY pp.poll_id, pp.user_id) AS group_size
    FROM public.poll_participants pp
    WHERE pp.user_id IS NOT NULL
    WINDOW w AS (PARTITION BY pp.poll_id, pp.user_id ORDER BY pp.created_at ASC NULLS LAST, pp.id ASC)
) ranked
WHERE ranked.group_size > 1;

INSERT INTO private.participant_merge_audit
    (survivor_id, participant_id, merge_role, participant, responses, private_credentials)
SELECT g.survivor_id, g.participant_id,
       CASE WHEN g.participant_id = g.survivor_id THEN 'survivor' ELSE 'duplicate' END,
       to_jsonb(pp),
       COALESCE((SELECT jsonb_agg(to_jsonb(ar) ORDER BY ar.time_option_id, ar.id)
                 FROM public.availability_responses ar WHERE ar.participant_id = pp.id), '[]'::jsonb),
       (SELECT to_jsonb(c) FROM private.participant_guest_credentials c WHERE c.participant_id = pp.id)
FROM f04_membership_groups g
JOIN public.poll_participants pp ON pp.id = g.participant_id;

-- Merged rows keep their original timestamps; this is not a user edit.
ALTER TABLE public.poll_participants DISABLE TRIGGER update_poll_participants_updated_at;
ALTER TABLE public.availability_responses DISABLE TRIGGER update_availability_responses_updated_at;

-- One response per (survivor, time option): latest updated_at, then the
-- survivor's own response, then lowest id. Response ids are preserved.
CREATE TEMP TABLE f04_response_winners ON COMMIT DROP AS
SELECT DISTINCT ON (g.survivor_id, ar.time_option_id) ar.id AS response_id, g.survivor_id
FROM f04_membership_groups g
JOIN public.availability_responses ar ON ar.participant_id = g.participant_id
ORDER BY g.survivor_id, ar.time_option_id,
         ar.updated_at DESC NULLS LAST, (ar.participant_id = g.survivor_id) DESC, ar.id;

DELETE FROM public.availability_responses ar
USING f04_membership_groups g
WHERE ar.participant_id = g.participant_id
  AND NOT EXISTS (SELECT 1 FROM f04_response_winners w WHERE w.response_id = ar.id);

UPDATE public.availability_responses ar
SET participant_id = w.survivor_id
FROM f04_response_winners w
WHERE ar.id = w.response_id AND ar.participant_id <> w.survivor_id;

-- Comment: the most recently updated non-null comment in the group (ties
-- prefer the survivor). updated_at: the latest in the group.
UPDATE public.poll_participants s
SET comment = merged.comment, updated_at = merged.updated_at
FROM (
    SELECT g.survivor_id,
           (SELECT pp2.comment
            FROM f04_membership_groups g2
            JOIN public.poll_participants pp2 ON pp2.id = g2.participant_id
            WHERE g2.survivor_id = g.survivor_id AND pp2.comment IS NOT NULL
            ORDER BY pp2.updated_at DESC NULLS LAST, (pp2.id = g2.survivor_id) DESC, pp2.id
            LIMIT 1) AS comment,
           max(pp.updated_at) AS updated_at
    FROM f04_membership_groups g
    JOIN public.poll_participants pp ON pp.id = g.participant_id
    GROUP BY g.survivor_id
) merged
WHERE s.id = merged.survivor_id;

DELETE FROM public.poll_participants pp
USING f04_membership_groups g
WHERE pp.id = g.participant_id AND g.participant_id <> g.survivor_id;

ALTER TABLE public.poll_participants ENABLE TRIGGER update_poll_participants_updated_at;
ALTER TABLE public.availability_responses ENABLE TRIGGER update_availability_responses_updated_at;

CREATE UNIQUE INDEX poll_participants_one_membership_per_user
    ON public.poll_participants (poll_id, user_id)
    WHERE user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Identity protection for every role.
-- ---------------------------------------------------------------------------
-- F03 already rejects identity changes through the Data API. Elevated and
-- service-role writes may still claim a guest (NULL -> user) and account
-- deletion may clear user_id (FK ON DELETE SET NULL), but no role can move a
-- row to another poll or reassign it from one user to another.
CREATE OR REPLACE FUNCTION poll_private.protect_participant_identity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    api_caller BOOLEAN := current_user IN ('anon', 'authenticated');
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.id IS DISTINCT FROM OLD.id
            OR NEW.poll_id IS DISTINCT FROM OLD.poll_id
            OR (OLD.user_id IS NOT NULL AND NEW.user_id IS NOT NULL AND NEW.user_id <> OLD.user_id)
            OR (api_caller AND (
                NEW.user_id IS DISTINCT FROM OLD.user_id
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
REVOKE ALL ON FUNCTION poll_private.protect_participant_identity() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Direct-insert policies bound to the caller (legacy installed clients).
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.can_join_poll(poll_uuid UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.polls p
        WHERE p.id = poll_uuid AND p.status = 'active'
          AND (p.closes_at IS NULL OR p.closes_at > now())
    );
$$;
REVOKE ALL ON FUNCTION poll_private.can_join_poll(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.can_join_poll(UUID) TO anon, authenticated, service_role;

DROP POLICY IF EXISTS "Anyone can join active polls" ON public.poll_participants;

CREATE POLICY "Members join open polls as themselves"
    ON public.poll_participants FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid()) AND poll_private.can_join_poll(poll_id));

CREATE POLICY "Guests join open polls without an account identity"
    ON public.poll_participants FOR INSERT TO anon
    WITH CHECK (
        user_id IS NULL
        AND length(btrim(anonymous_name)) BETWEEN 1 AND 100
        AND poll_private.can_join_poll(poll_id)
    );

-- ---------------------------------------------------------------------------
-- Idempotent member join.
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.join_poll(poll_uuid UUID)
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

    PERFORM 1 FROM public.polls p
    WHERE p.id = poll_uuid AND p.status = 'active'
      AND (p.closes_at IS NULL OR p.closes_at > now())
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll is not accepting participants' USING ERRCODE = '42501';
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

-- ---------------------------------------------------------------------------
-- Idempotent guest join (replaces the F03 three-argument signature).
-- ---------------------------------------------------------------------------
-- Callers may supply their own 64-hex capability (generated with a CSPRNG).
-- Retrying with it returns the same guest row instead of a new one. Without
-- it, the server generates the capability as in F03.
DROP FUNCTION public.join_poll_as_guest(UUID, TEXT, TEXT);
DROP FUNCTION poll_private.join_poll_as_guest(UUID, TEXT, TEXT);

CREATE FUNCTION poll_private.guest_participant_for_digest(token_digest BYTEA)
RETURNS public.poll_participants
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT pp.*
    FROM private.participant_guest_credentials c
    JOIN public.poll_participants pp ON pp.id = c.participant_id
    WHERE c.token_hash = token_digest;
$$;
REVOKE ALL ON FUNCTION poll_private.guest_participant_for_digest(BYTEA) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION poll_private.join_poll_as_guest(
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

-- ---------------------------------------------------------------------------
-- Claiming a guest row requires its capability.
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.claim_guest_participant(participant_uuid UUID, guest_token TEXT)
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
    PERFORM poll_private.lock_guest_participant(participant_uuid, guest_token);
    SELECT * INTO participant FROM public.poll_participants pp WHERE pp.id = participant_uuid;
    IF EXISTS (SELECT 1 FROM public.poll_participants pp
               WHERE pp.poll_id = participant.poll_id AND pp.user_id = caller_id) THEN
        RAISE EXCEPTION 'Already a member of this poll' USING ERRCODE = '23505';
    END IF;

    -- Once user_id is set, every guest command rejects this capability. Its
    -- verifier is kept so the same capability cannot create a new guest row.
    UPDATE public.poll_participants pp SET user_id = caller_id
    WHERE pp.id = participant.id
    RETURNING * INTO participant;
    RETURN json_build_object('participant', row_to_json(participant));
END;
$$;

REVOKE ALL ON FUNCTION poll_private.join_poll(UUID),
    poll_private.join_poll_as_guest(UUID, TEXT, TEXT, TEXT),
    poll_private.claim_guest_participant(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.join_poll(UUID),
    poll_private.claim_guest_participant(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION poll_private.join_poll_as_guest(UUID, TEXT, TEXT, TEXT)
    TO anon, authenticated, service_role;

CREATE FUNCTION public.join_poll(poll_uuid UUID)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.join_poll(poll_uuid); $$;

CREATE FUNCTION public.join_poll_as_guest(
    poll_uuid UUID, display_name TEXT, contact_email TEXT DEFAULT NULL, guest_token TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.join_poll_as_guest(poll_uuid, display_name, contact_email, guest_token); $$;

CREATE FUNCTION public.claim_guest_participant(participant_uuid UUID, guest_token TEXT)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.claim_guest_participant(participant_uuid, guest_token); $$;

REVOKE ALL ON FUNCTION public.join_poll(UUID),
    public.join_poll_as_guest(UUID, TEXT, TEXT, TEXT),
    public.claim_guest_participant(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.join_poll(UUID),
    public.claim_guest_participant(UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.join_poll_as_guest(UUID, TEXT, TEXT, TEXT)
    TO anon, authenticated, service_role;

COMMIT;
