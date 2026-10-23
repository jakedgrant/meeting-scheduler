-- F06 + F10: response invariants and transactional response commands.
--
-- * A response's participant and time option must belong to the same poll,
--   for every role. Existing cross-poll rows are quarantined privately.
-- * The selected final time must be a pair that matches one of the poll's
--   time options. finalize_poll is the organizer-only state transition.
-- * save_availability saves a participant's whole response set and comment in
--   one transaction. It is idempotent per request_id and returns a persisted
--   version. Members use their session; guests use their F03 capability.
-- * Direct Data API response writes remain for installed clients, but they
--   enforce the same rules: own row, open poll, matching poll. Response reads
--   are limited to the poll owner and members (owner decision, October 22).
--
-- Serialization rule: every response mutation (command or direct write)
-- locks the poll row FOR SHARE and re-checks that it is open. Closing or
-- finalizing updates that row, which waits for in-flight saves and makes later
-- saves see the closed state. A save therefore commits entirely before a
-- close/finalize, or is rejected after it.
--
-- Date/time (F21): unchanged column types. closes_at and option intervals are
-- timestamptz instants compared with now(); finalization copies an existing
-- option's interval, so it does not depend on how clients encode all-day or
-- zoned options.
BEGIN;

LOCK TABLE public.availability_responses IN SHARE ROW EXCLUSIVE MODE;

-- ---------------------------------------------------------------------------
-- Private state.
-- ---------------------------------------------------------------------------
CREATE TABLE private.response_invariant_quarantine (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason TEXT NOT NULL,
    response JSONB NOT NULL
);

-- Monotonic per-participant version of the response set plus comment.
CREATE TABLE private.participant_response_state (
    participant_id UUID PRIMARY KEY REFERENCES public.poll_participants(id) ON DELETE CASCADE,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency log: a retried request_id returns its original result.
CREATE TABLE private.response_save_requests (
    participant_id UUID NOT NULL REFERENCES public.poll_participants(id) ON DELETE CASCADE,
    request_id UUID NOT NULL,
    request_hash BYTEA NOT NULL,
    result JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (participant_id, request_id)
);
CREATE INDEX response_save_requests_created ON private.response_save_requests (created_at);

ALTER TABLE private.response_invariant_quarantine ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.participant_response_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.response_save_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.response_invariant_quarantine, private.participant_response_state,
    private.response_save_requests FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Quarantine existing responses that cross poll boundaries.
-- ---------------------------------------------------------------------------
WITH crossed AS (
    DELETE FROM public.availability_responses ar
    USING public.poll_participants pp, public.poll_time_options pto
    WHERE pp.id = ar.participant_id AND pto.id = ar.time_option_id AND pp.poll_id <> pto.poll_id
    RETURNING ar.*
)
INSERT INTO private.response_invariant_quarantine (reason, response)
SELECT 'participant and time option belong to different polls', to_jsonb(crossed) FROM crossed;

-- ---------------------------------------------------------------------------
-- Helpers. Elevated reads avoid RLS recursion and never take a caller identity.
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.participant_poll(p_participant UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$ SELECT pp.poll_id FROM public.poll_participants pp WHERE pp.id = p_participant; $$;

-- The shared poll of a participant and time option, or NULL if they differ.
CREATE FUNCTION poll_private.response_poll(p_participant UUID, p_time_option UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT pp.poll_id
    FROM public.poll_participants pp
    JOIN public.poll_time_options pto ON pto.poll_id = pp.poll_id
    WHERE pp.id = p_participant AND pto.id = p_time_option;
$$;

-- Locks the poll row FOR SHARE (see the serialization rule) and reports
-- whether it is open for responses.
CREATE FUNCTION poll_private.lock_open_poll(p_poll UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM 1 FROM public.polls p
    WHERE p.id = p_poll AND p.status = 'active'
      AND (p.closes_at IS NULL OR p.closes_at > now())
    FOR SHARE;
    RETURN FOUND;
END;
$$;

CREATE FUNCTION poll_private.owns_participant(p_participant UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT (SELECT auth.uid()) IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.poll_participants pp
        WHERE pp.id = p_participant AND pp.user_id = (SELECT auth.uid())
    );
$$;

CREATE FUNCTION poll_private.can_view_responses_of(p_participant UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT (SELECT auth.uid()) IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.poll_participants pp
        JOIN public.polls p ON p.id = pp.poll_id
        WHERE pp.id = p_participant AND (
            p.creator_id = (SELECT auth.uid()) OR poll_private.is_poll_participant(p.id)
        )
    );
$$;

REVOKE ALL ON FUNCTION poll_private.participant_poll(UUID), poll_private.response_poll(UUID, UUID),
    poll_private.lock_open_poll(UUID), poll_private.owns_participant(UUID),
    poll_private.can_view_responses_of(UUID) FROM PUBLIC, anon, authenticated;
-- Called from invoker triggers and policies evaluated as the API caller.
GRANT EXECUTE ON FUNCTION poll_private.participant_poll(UUID), poll_private.response_poll(UUID, UUID),
    poll_private.lock_open_poll(UUID), poll_private.owns_participant(UUID),
    poll_private.can_view_responses_of(UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Response write invariants for every path.
-- ---------------------------------------------------------------------------
-- Invoker: current_user identifies direct Data API writes. Elevated commands,
-- cascades, and account deletion run as the owner and skip only the open-poll
-- check (they perform their own checks or are not user edits).
CREATE FUNCTION poll_private.check_response_write()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    api_caller BOOLEAN := current_user IN ('anon', 'authenticated');
    target_poll UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF api_caller THEN
            target_poll := poll_private.participant_poll(OLD.participant_id);
            IF target_poll IS NULL OR NOT poll_private.lock_open_poll(target_poll) THEN
                RAISE EXCEPTION 'Poll is not accepting responses' USING ERRCODE = '42501';
            END IF;
        END IF;
        RETURN OLD;
    END IF;
    IF TG_OP = 'UPDATE' AND (NEW.participant_id IS DISTINCT FROM OLD.participant_id
        OR NEW.time_option_id IS DISTINCT FROM OLD.time_option_id) THEN
        RAISE EXCEPTION 'Response identity fields cannot be changed' USING ERRCODE = '42501';
    END IF;
    target_poll := poll_private.response_poll(NEW.participant_id, NEW.time_option_id);
    IF target_poll IS NULL THEN
        RAISE EXCEPTION 'Response time option must belong to the participant''s poll' USING ERRCODE = '23514';
    END IF;
    IF api_caller AND NOT poll_private.lock_open_poll(target_poll) THEN
        RAISE EXCEPTION 'Poll is not accepting responses' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_response_write() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER responses_10_check_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.availability_responses
    FOR EACH ROW EXECUTE FUNCTION poll_private.check_response_write();

-- Options cannot move between polls (that would break the invariant).
CREATE FUNCTION poll_private.protect_time_option_poll()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
    IF NEW.poll_id IS DISTINCT FROM OLD.poll_id THEN
        RAISE EXCEPTION 'Time options cannot move to another poll' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.protect_time_option_poll() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER time_options_10_protect_poll
    BEFORE UPDATE OF poll_id ON public.poll_time_options
    FOR EACH ROW EXECUTE FUNCTION poll_private.protect_time_option_poll();

-- ---------------------------------------------------------------------------
-- Versioning: every persisted change to a participant's responses or comment.
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.bump_response_version(p_participant UUID)
RETURNS VOID
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
    -- Skips participants being deleted (cascades), whose state row goes too.
    INSERT INTO private.participant_response_state AS s (participant_id, version, updated_at)
    SELECT pp.id, 1, now() FROM public.poll_participants pp WHERE pp.id = p_participant
    ON CONFLICT (participant_id) DO UPDATE SET version = s.version + 1, updated_at = now();
$$;

CREATE FUNCTION poll_private.bump_version_from_response()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM poll_private.bump_response_version(
        CASE WHEN TG_OP = 'DELETE' THEN OLD.participant_id ELSE NEW.participant_id END);
    RETURN NULL;
END;
$$;

CREATE FUNCTION poll_private.bump_version_from_comment()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    PERFORM poll_private.bump_response_version(NEW.id);
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.bump_response_version(UUID), poll_private.bump_version_from_response(),
    poll_private.bump_version_from_comment() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER responses_90_bump_version_insert_delete
    AFTER INSERT OR DELETE ON public.availability_responses
    FOR EACH ROW EXECUTE FUNCTION poll_private.bump_version_from_response();
CREATE TRIGGER responses_90_bump_version_update
    AFTER UPDATE ON public.availability_responses
    FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.note IS DISTINCT FROM NEW.note)
    EXECUTE FUNCTION poll_private.bump_version_from_response();
CREATE TRIGGER participants_90_bump_version_comment
    AFTER UPDATE OF comment ON public.poll_participants
    FOR EACH ROW WHEN (OLD.comment IS DISTINCT FROM NEW.comment)
    EXECUTE FUNCTION poll_private.bump_version_from_comment();

-- ---------------------------------------------------------------------------
-- Response policies: owner/member reads; members write only their own rows.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anyone can view responses for accessible polls" ON public.availability_responses;
DROP POLICY IF EXISTS "Users can view responses for accessible polls" ON public.availability_responses;
DROP POLICY IF EXISTS "Participants can manage own responses" ON public.availability_responses;

CREATE POLICY "Responses are visible to the poll owner and members"
    ON public.availability_responses FOR SELECT TO authenticated
    USING (poll_private.can_view_responses_of(participant_id));
CREATE POLICY "Members insert their own responses"
    ON public.availability_responses FOR INSERT TO authenticated
    WITH CHECK (poll_private.owns_participant(participant_id));
CREATE POLICY "Members update their own responses"
    ON public.availability_responses FOR UPDATE TO authenticated
    USING (poll_private.owns_participant(participant_id))
    WITH CHECK (poll_private.owns_participant(participant_id));
CREATE POLICY "Members delete their own responses"
    ON public.availability_responses FOR DELETE TO authenticated
    USING (poll_private.owns_participant(participant_id));

REVOKE INSERT, UPDATE, DELETE ON public.availability_responses FROM anon;

-- ---------------------------------------------------------------------------
-- Selected final time: a valid pair matching one of the poll's options.
-- ---------------------------------------------------------------------------
ALTER TABLE public.polls ADD CONSTRAINT poll_selected_time_pair CHECK (
    (selected_start_time IS NULL) = (selected_end_time IS NULL)
    AND (selected_end_time IS NULL OR selected_end_time > selected_start_time)
) NOT VALID;
DO $$
BEGIN
    ALTER TABLE public.polls VALIDATE CONSTRAINT poll_selected_time_pair;
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'poll_selected_time_pair left NOT VALID: existing rows violate it (see docs/response-commands.md)';
END;
$$;

-- Matches at second precision (installed iOS clients send ISO 8601 without
-- fractional seconds) and stores the option's exact interval.
CREATE FUNCTION poll_private.normalize_selected_time()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    option_start TIMESTAMPTZ;
    option_end TIMESTAMPTZ;
BEGIN
    IF NEW.selected_start_time IS NULL AND NEW.selected_end_time IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT pto.start_time, pto.end_time INTO option_start, option_end
    FROM public.poll_time_options pto
    WHERE pto.poll_id = NEW.id
      AND date_trunc('second', pto.start_time) = date_trunc('second', NEW.selected_start_time)
      AND date_trunc('second', pto.end_time) = date_trunc('second', NEW.selected_end_time)
    ORDER BY pto.id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Selected time must match one of the poll''s time options' USING ERRCODE = '23514';
    END IF;
    NEW.selected_start_time := option_start;
    NEW.selected_end_time := option_end;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.normalize_selected_time() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER polls_10_normalize_selected_time
    BEFORE INSERT OR UPDATE OF selected_start_time, selected_end_time ON public.polls
    FOR EACH ROW EXECUTE FUNCTION poll_private.normalize_selected_time();

-- ---------------------------------------------------------------------------
-- Commands.
-- ---------------------------------------------------------------------------
CREATE FUNCTION poll_private.availability_result(p_participant UUID)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'participant_id', pp.id,
        'poll_id', pp.poll_id,
        'version', COALESCE(s.version, 0),
        'comment', pp.comment,
        'responses', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', ar.id, 'time_option_id', ar.time_option_id, 'status', ar.status,
                'note', ar.note, 'updated_at', ar.updated_at) ORDER BY ar.time_option_id)
            FROM public.availability_responses ar WHERE ar.participant_id = pp.id), '[]'::jsonb)
    )
    FROM public.poll_participants pp
    LEFT JOIN private.participant_response_state s ON s.participant_id = pp.id
    WHERE pp.id = p_participant;
$$;

-- Members are identified by the session; guests by their F03 capability.
CREATE FUNCTION poll_private.resolve_availability_participant(
    p_poll UUID, p_participant UUID, p_guest_token TEXT)
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    resolved UUID;
BEGIN
    IF p_guest_token IS NOT NULL THEN
        resolved := poll_private.verified_guest_participant(p_participant, p_guest_token);
        IF resolved IS NULL OR poll_private.participant_poll(resolved) IS DISTINCT FROM p_poll THEN
            RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
        END IF;
        RETURN resolved;
    END IF;
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;
    SELECT pp.id INTO resolved FROM public.poll_participants pp
    WHERE pp.poll_id = p_poll AND pp.user_id = auth.uid();
    IF resolved IS NULL OR (p_participant IS NOT NULL AND p_participant <> resolved) THEN
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
    RETURN resolved;
END;
$$;

CREATE FUNCTION poll_private.save_availability(
    p_poll UUID, p_request_id UUID, p_responses JSONB, p_comment TEXT,
    p_expected_version BIGINT, p_participant UUID, p_guest_token TEXT)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_participant UUID;
    entry JSONB;
    normalized JSONB;
    digest BYTEA;
    prior_hash BYTEA;
    prior_result JSONB;
    current_version BIGINT;
    result JSONB;
BEGIN
    IF p_request_id IS NULL THEN
        RAISE EXCEPTION 'request_id is required' USING ERRCODE = '22023';
    END IF;
    v_participant := poll_private.resolve_availability_participant(p_poll, p_participant, p_guest_token);
    -- One save at a time per participant; a concurrent retry then sees the log.
    PERFORM 1 FROM public.poll_participants pp WHERE pp.id = v_participant FOR NO KEY UPDATE;

    IF jsonb_typeof(p_responses) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'responses must be a JSON array' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_responses) > 500 THEN
        RAISE EXCEPTION 'Too many responses' USING ERRCODE = '22023';
    END IF;
    FOR entry IN SELECT e.value FROM jsonb_array_elements(p_responses) e LOOP
        IF jsonb_typeof(entry) IS DISTINCT FROM 'object'
            OR jsonb_typeof(entry -> 'time_option_id') IS DISTINCT FROM 'string'
            OR (entry ->> 'time_option_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            OR (entry ->> 'status') IS NULL
            OR (entry ->> 'status') NOT IN ('available', 'maybe', 'unavailable')
            OR jsonb_typeof(entry -> 'status') IS DISTINCT FROM 'string'
            OR COALESCE(jsonb_typeof(entry -> 'note'), 'null') NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'Invalid response entry' USING ERRCODE = '22023';
        END IF;
        IF char_length(entry ->> 'note') > 500 THEN
            RAISE EXCEPTION 'Note must be 500 characters or fewer' USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF (SELECT count(DISTINCT lower(e.value ->> 'time_option_id')) FROM jsonb_array_elements(p_responses) e)
        <> jsonb_array_length(p_responses) THEN
        RAISE EXCEPTION 'Duplicate time option in responses' USING ERRCODE = '22023';
    END IF;
    IF char_length(p_comment) > 500 THEN
        RAISE EXCEPTION 'Comment must be 500 characters or fewer' USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'time_option_id', lower(e.value ->> 'time_option_id'),
               'status', e.value ->> 'status',
               'note', CASE WHEN jsonb_typeof(e.value -> 'note') = 'string' THEN e.value -> 'note' ELSE 'null'::jsonb END)
           ORDER BY lower(e.value ->> 'time_option_id')), '[]'::jsonb)
    INTO normalized
    FROM jsonb_array_elements(p_responses) e;
    digest := sha256(convert_to(jsonb_build_object(
        'poll_id', p_poll, 'responses', normalized, 'comment', p_comment,
        'expected_version', p_expected_version)::text, 'UTF8'));

    SELECT r.request_hash, r.result INTO prior_hash, prior_result
    FROM private.response_save_requests r
    WHERE r.participant_id = v_participant AND r.request_id = p_request_id;
    IF FOUND THEN
        IF prior_hash <> digest THEN
            RAISE EXCEPTION 'request_id was already used with a different payload' USING ERRCODE = '22023';
        END IF;
        RETURN (prior_result || jsonb_build_object('replayed', true))::json;
    END IF;

    IF NOT poll_private.lock_open_poll(p_poll) THEN
        RAISE EXCEPTION 'Poll is not accepting responses' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(normalized) e
        WHERE NOT EXISTS (SELECT 1 FROM public.poll_time_options pto
                          WHERE pto.id = (e.value ->> 'time_option_id')::uuid AND pto.poll_id = p_poll)
    ) THEN
        RAISE EXCEPTION 'Time option does not belong to this poll' USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE((SELECT s.version FROM private.participant_response_state s
                     WHERE s.participant_id = v_participant), 0)
    INTO current_version;
    IF p_expected_version IS NOT NULL AND p_expected_version <> current_version THEN
        RAISE EXCEPTION 'Responses changed since the expected version'
            USING ERRCODE = 'PT409', DETAIL = format('current_version=%s', current_version);
    END IF;

    -- The persisted set becomes exactly the submitted set; unchanged rows are
    -- not rewritten, so a no-op save keeps the same version.
    DELETE FROM public.availability_responses ar
    WHERE ar.participant_id = v_participant
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(normalized) e
                      WHERE (e.value ->> 'time_option_id')::uuid = ar.time_option_id);
    INSERT INTO public.availability_responses AS ar (participant_id, time_option_id, status, note)
    SELECT v_participant, (e.value ->> 'time_option_id')::uuid,
           (e.value ->> 'status')::public.availability_status, e.value ->> 'note'
    FROM jsonb_array_elements(normalized) e
    ON CONFLICT (participant_id, time_option_id) DO UPDATE
        SET status = EXCLUDED.status, note = EXCLUDED.note
        WHERE (ar.status, ar.note) IS DISTINCT FROM (EXCLUDED.status, EXCLUDED.note);
    UPDATE public.poll_participants pp SET comment = p_comment
    WHERE pp.id = v_participant AND pp.comment IS DISTINCT FROM p_comment;

    result := poll_private.availability_result(v_participant) || jsonb_build_object('saved_at', now());
    INSERT INTO private.response_save_requests (participant_id, request_id, request_hash, result)
    VALUES (v_participant, p_request_id, digest, result);
    RETURN (result || jsonb_build_object('replayed', false))::json;
END;
$$;

CREATE FUNCTION poll_private.get_availability(p_poll UUID, p_participant UUID, p_guest_token TEXT)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN poll_private.availability_result(
        poll_private.resolve_availability_participant(p_poll, p_participant, p_guest_token))::json;
END;
$$;

-- Organizer-only: selects one of the poll's options and closes the poll.
-- FOR UPDATE waits for in-flight saves (which hold FOR SHARE).
CREATE FUNCTION poll_private.finalize_poll(p_poll UUID, p_time_option UUID)
RETURNS JSON
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    target public.polls;
    option_start TIMESTAMPTZ;
    option_end TIMESTAMPTZ;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO target FROM public.polls p
    WHERE p.id = p_poll AND p.creator_id = auth.uid()
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
    IF target.status NOT IN ('active', 'closed') THEN
        RAISE EXCEPTION 'Poll cannot be finalized' USING ERRCODE = '42501';
    END IF;
    SELECT pto.start_time, pto.end_time INTO option_start, option_end
    FROM public.poll_time_options pto WHERE pto.id = p_time_option AND pto.poll_id = p_poll;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Time option does not belong to this poll' USING ERRCODE = '22023';
    END IF;
    UPDATE public.polls p
    SET status = 'closed', selected_start_time = option_start, selected_end_time = option_end
    WHERE p.id = p_poll
    RETURNING * INTO target;
    RETURN row_to_json(target);
END;
$$;

REVOKE ALL ON FUNCTION poll_private.availability_result(UUID),
    poll_private.resolve_availability_participant(UUID, UUID, TEXT),
    poll_private.save_availability(UUID, UUID, JSONB, TEXT, BIGINT, UUID, TEXT),
    poll_private.get_availability(UUID, UUID, TEXT),
    poll_private.finalize_poll(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.save_availability(UUID, UUID, JSONB, TEXT, BIGINT, UUID, TEXT),
    poll_private.get_availability(UUID, UUID, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION poll_private.finalize_poll(UUID, UUID) TO authenticated, service_role;

CREATE FUNCTION public.save_availability(
    poll_uuid UUID, request_id UUID, responses JSONB, comment TEXT,
    expected_version BIGINT DEFAULT NULL, participant_uuid UUID DEFAULT NULL, guest_token TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT poll_private.save_availability(poll_uuid, request_id, responses, comment,
        expected_version, participant_uuid, guest_token);
$$;

CREATE FUNCTION public.get_availability(
    poll_uuid UUID, participant_uuid UUID DEFAULT NULL, guest_token TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.get_availability(poll_uuid, participant_uuid, guest_token); $$;

CREATE FUNCTION public.finalize_poll(poll_uuid UUID, time_option_uuid UUID)
RETURNS JSON
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.finalize_poll(poll_uuid, time_option_uuid); $$;

REVOKE ALL ON FUNCTION public.save_availability(UUID, UUID, JSONB, TEXT, BIGINT, UUID, TEXT),
    public.get_availability(UUID, UUID, TEXT), public.finalize_poll(UUID, UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_availability(UUID, UUID, JSONB, TEXT, BIGINT, UUID, TEXT),
    public.get_availability(UUID, UUID, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_poll(UUID, UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Account deletion also erases the user's save results (they hold comments
-- and notes). Otherwise identical to 20261022235817.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poll_private.anonymize_deleted_participant()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    DELETE FROM private.participant_guest_credentials c
    USING public.poll_participants pp
    WHERE c.participant_id = pp.id AND pp.user_id = OLD.id;

    DELETE FROM private.response_save_requests r
    USING public.poll_participants pp
    WHERE r.participant_id = pp.id AND pp.user_id = OLD.id;

    UPDATE public.availability_responses ar
    SET note = '[user deleted]'
    FROM public.poll_participants pp
    WHERE ar.participant_id = pp.id AND pp.user_id = OLD.id AND ar.note IS NOT NULL;

    UPDATE public.poll_participants pp
    SET user_id = NULL,
        anonymous_name = 'Deleted user',
        comment = CASE WHEN pp.comment IS NULL THEN NULL ELSE '[user deleted]' END
    WHERE pp.user_id = OLD.id;

    DELETE FROM private.participant_merge_audit a
    WHERE a.participant ->> 'user_id' = OLD.id::text;
    RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.anonymize_deleted_participant() FROM PUBLIC, anon, authenticated;

COMMIT;
