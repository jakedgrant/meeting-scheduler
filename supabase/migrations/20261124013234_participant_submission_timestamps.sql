-- Version state already records every saved answer/comment change, including
-- legacy direct writes. Expose its timestamp without changing the write path.
-- Rows predating version tracking use their latest answer time as an estimate.
CREATE FUNCTION poll_private.availability_submitted_at(p_participant UUID)
RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT CASE WHEN count(*) > 0 THEN COALESCE(
        (SELECT s.updated_at FROM private.participant_response_state s
         WHERE s.participant_id = p_participant),
        max(ar.updated_at)
    ) END
    FROM public.availability_responses ar WHERE ar.participant_id = p_participant;
$$;
REVOKE ALL ON FUNCTION poll_private.availability_submitted_at(UUID)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION poll_private.bounded_poll_detail(poll_uuid UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    option_total INTEGER;
    participant_total INTEGER;
BEGIN
    SELECT count(*) INTO option_total FROM public.poll_time_options WHERE poll_id = poll_uuid;
    SELECT count(*) INTO participant_total FROM public.poll_participants WHERE poll_id = poll_uuid;
    -- New polls cannot exceed 500 options or their participant capacity. Fail a
    -- legacy outlier visibly rather than return a silently partial detail.
    IF option_total > 500 OR participant_total > 500 THEN
        RAISE EXCEPTION 'Poll detail exceeds the supported size' USING ERRCODE = '54000';
    END IF;
    RETURN (
        SELECT jsonb_build_object(
            'poll', to_jsonb(p),
            'time_options', COALESCE((
                SELECT jsonb_agg(to_jsonb(pto) ORDER BY pto.start_time, pto.id)
                FROM public.poll_time_options pto WHERE pto.poll_id = p.id), '[]'::jsonb),
            'participants', COALESCE((
                SELECT jsonb_agg(to_jsonb(pp) || jsonb_build_object('profiles',
                    CASE WHEN pr.id IS NULL THEN NULL
                         ELSE jsonb_build_object('display_name', pr.display_name) END,
                    'submitted_at', poll_private.availability_submitted_at(pp.id))
                    ORDER BY pp.created_at, pp.id)
                FROM public.poll_participants pp
                LEFT JOIN public.profiles pr ON pr.id = pp.user_id
                WHERE pp.poll_id = p.id), '[]'::jsonb),
            'time_option_count', option_total,
            'participant_count', participant_total
        )
        FROM public.polls p WHERE p.id = poll_uuid
    );
END;
$$;

CREATE OR REPLACE FUNCTION poll_private.availability_result(p_participant UUID)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'participant_id', pp.id,
        'poll_id', pp.poll_id,
        'version', COALESCE(s.version, 0),
        'comment', pp.comment,
        'submitted_at', poll_private.availability_submitted_at(pp.id),
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
