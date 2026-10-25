-- F19: bounded, cursor-paged member reads with database-computed totals.
--
-- * list_poll_summaries pages the caller's created/joined polls by
--   (created_at DESC, id DESC) and returns participant counts and option
--   ranges, so list screens need one request per page instead of 1 + 2N.
-- * get_poll_detail returns the poll, options and participants in one value,
--   with counts. Both collections are bounded by write-side limits (500
--   options; capacity-checked participants); a legacy poll beyond the detail
--   limits fails explicitly instead of truncating.
-- * list_poll_responses pages a poll's responses by
--   (participant_id, time_option_id). The first page carries total_count.
--
-- Cursors are opaque, versioned strings. A cursor from one API is rejected by
-- the other. get_user_participated_polls stays until native readers migrate;
-- see docs/read-contracts.md. Guest detail is unchanged.
BEGIN;

-- Keyset order needs a non-null created_at. check_poll_update already keeps it
-- immutable for API roles; backfill legacy nulls deterministically.
UPDATE public.polls SET created_at = COALESCE(updated_at, 'epoch'::timestamptz)
WHERE created_at IS NULL;
ALTER TABLE public.polls ALTER COLUMN created_at SET NOT NULL;

CREATE INDEX polls_creator_created_order ON public.polls (creator_id, created_at DESC, id DESC);

CREATE FUNCTION poll_private.list_poll_summaries(role_filter TEXT, page_size INTEGER, page_cursor TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    caller UUID := auth.uid();
    parts TEXT[];
    after_at TIMESTAMPTZ;
    after_id UUID;
    items JSONB;
    more BOOLEAN;
    last_cursor TEXT;
    total INTEGER;
BEGIN
    IF caller IS NULL THEN
        RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
    END IF;
    IF role_filter IS NOT NULL AND role_filter NOT IN ('owner', 'member') THEN
        RAISE EXCEPTION 'role_filter must be owner, member or null' USING ERRCODE = '22023';
    END IF;
    IF page_size IS NULL OR page_size NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'page_size must be between 1 and 100' USING ERRCODE = '22023';
    END IF;
    IF page_cursor IS NOT NULL THEN
        parts := regexp_match(page_cursor,
            '^p1:(-?[0-9]{1,17}):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');
        IF parts IS NULL THEN
            RAISE EXCEPTION 'Invalid page cursor' USING ERRCODE = '22023';
        END IF;
        -- Integer microseconds round-trip exactly; floating epoch seconds do not.
        after_at := 'epoch'::timestamptz + parts[1]::BIGINT * interval '1 microsecond';
        after_id := parts[2]::UUID;
    END IF;

    -- Same membership rule as the legacy RPC: owned polls, plus other users'
    -- polls in which the caller has an authenticated participant row.
    WITH visible AS (
        SELECT p AS poll_row, p.id, p.created_at,
               CASE WHEN p.creator_id = caller THEN 'owner' ELSE 'member' END AS caller_role
        FROM public.polls p
        WHERE (role_filter IS DISTINCT FROM 'member' AND p.creator_id = caller)
           OR (role_filter IS DISTINCT FROM 'owner' AND p.creator_id <> caller AND EXISTS (
                SELECT 1 FROM public.poll_participants pp
                WHERE pp.poll_id = p.id AND pp.user_id = caller))
    ), candidates AS (
        SELECT v.*, row_number() OVER (ORDER BY v.created_at DESC, v.id DESC) AS ord
        FROM visible v
        WHERE after_id IS NULL OR (v.created_at, v.id) < (after_at, after_id)
        ORDER BY v.created_at DESC, v.id DESC
        LIMIT page_size + 1
    )
    SELECT
        COALESCE(jsonb_agg(jsonb_build_object(
            'poll', to_jsonb(c.poll_row),
            'role', c.caller_role,
            'participant_count', (SELECT count(*) FROM public.poll_participants pp WHERE pp.poll_id = c.id),
            'time_option_count', o.option_count,
            'earliest_start', o.earliest_start,
            'latest_start', o.latest_start
        ) ORDER BY c.ord) FILTER (WHERE c.ord <= page_size), '[]'::jsonb),
        count(*) > page_size,
        (array_agg('p1:' || (extract(epoch FROM c.created_at) * 1000000)::BIGINT || ':' || c.id
            ORDER BY c.ord DESC) FILTER (WHERE c.ord <= page_size))[1]
    INTO items, more, last_cursor
    FROM candidates c
    CROSS JOIN LATERAL (
        SELECT count(*) AS option_count, min(pto.start_time) AS earliest_start,
               max(pto.start_time) AS latest_start
        FROM public.poll_time_options pto WHERE pto.poll_id = c.id
    ) o;

    SELECT count(*) INTO total
    FROM public.polls p
    WHERE (role_filter IS DISTINCT FROM 'member' AND p.creator_id = caller)
       OR (role_filter IS DISTINCT FROM 'owner' AND p.creator_id <> caller AND EXISTS (
            SELECT 1 FROM public.poll_participants pp
            WHERE pp.poll_id = p.id AND pp.user_id = caller));

    RETURN jsonb_build_object(
        'items', items,
        'has_more', more,
        'next_cursor', CASE WHEN more THEN last_cursor END,
        'total_count', total
    );
END;
$$;

CREATE FUNCTION poll_private.get_poll_detail(poll_uuid UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    option_total INTEGER;
    participant_total INTEGER;
BEGIN
    IF NOT poll_private.can_read_poll(poll_uuid) THEN
        -- Missing and inaccessible polls have the same public error.
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
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
            -- Same projection and profiles(display_name) embed as guest detail.
            'participants', COALESCE((
                SELECT jsonb_agg(to_jsonb(pp) || jsonb_build_object('profiles',
                    CASE WHEN pr.id IS NULL THEN NULL
                         ELSE jsonb_build_object('display_name', pr.display_name) END)
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

CREATE FUNCTION poll_private.list_poll_responses(poll_uuid UUID, page_size INTEGER, page_cursor TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    parts TEXT[];
    after_participant UUID;
    after_option UUID;
    items JSONB;
    more BOOLEAN;
    last_cursor TEXT;
    total INTEGER;
BEGIN
    IF NOT poll_private.can_read_poll(poll_uuid) THEN
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
    IF page_size IS NULL OR page_size NOT BETWEEN 1 AND 1000 THEN
        RAISE EXCEPTION 'page_size must be between 1 and 1000' USING ERRCODE = '22023';
    END IF;
    IF page_cursor IS NOT NULL THEN
        parts := regexp_match(page_cursor,
            '^r1:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');
        IF parts IS NULL THEN
            RAISE EXCEPTION 'Invalid page cursor' USING ERRCODE = '22023';
        END IF;
        after_participant := parts[1]::UUID;
        after_option := parts[2]::UUID;
    END IF;

    -- Only same-poll pairs count, matching guest detail and get_poll_with_summary.
    WITH candidates AS (
        SELECT ar, ar.participant_id, ar.time_option_id,
               row_number() OVER (ORDER BY ar.participant_id, ar.time_option_id) AS ord
        FROM public.availability_responses ar
        JOIN public.poll_participants pp ON pp.id = ar.participant_id AND pp.poll_id = poll_uuid
        JOIN public.poll_time_options pto ON pto.id = ar.time_option_id AND pto.poll_id = poll_uuid
        WHERE after_participant IS NULL
           OR (ar.participant_id, ar.time_option_id) > (after_participant, after_option)
        ORDER BY ar.participant_id, ar.time_option_id
        LIMIT page_size + 1
    )
    SELECT
        COALESCE(jsonb_agg(to_jsonb(c.ar) ORDER BY c.ord) FILTER (WHERE c.ord <= page_size), '[]'::jsonb),
        count(*) > page_size,
        (array_agg('r1:' || c.participant_id || ':' || c.time_option_id ORDER BY c.ord DESC)
            FILTER (WHERE c.ord <= page_size))[1]
    INTO items, more, last_cursor
    FROM candidates c;

    -- Counting every page would repeat O(responses) work; clients compare their
    -- traversal with the first page's total.
    IF page_cursor IS NULL THEN
        SELECT count(*) INTO total
        FROM public.availability_responses ar
        JOIN public.poll_participants pp ON pp.id = ar.participant_id AND pp.poll_id = poll_uuid
        JOIN public.poll_time_options pto ON pto.id = ar.time_option_id AND pto.poll_id = poll_uuid;
    END IF;

    RETURN jsonb_build_object(
        'items', items,
        'has_more', more,
        'next_cursor', CASE WHEN more THEN last_cursor END,
        'total_count', total
    );
END;
$$;

REVOKE ALL ON FUNCTION poll_private.list_poll_summaries(TEXT, INTEGER, TEXT),
    poll_private.get_poll_detail(UUID),
    poll_private.list_poll_responses(UUID, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.list_poll_summaries(TEXT, INTEGER, TEXT),
    poll_private.get_poll_detail(UUID),
    poll_private.list_poll_responses(UUID, INTEGER, TEXT) TO authenticated, service_role;

CREATE FUNCTION public.list_poll_summaries(
    role_filter TEXT DEFAULT NULL, page_size INTEGER DEFAULT 50, page_cursor TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.list_poll_summaries(role_filter, page_size, page_cursor); $$;

CREATE FUNCTION public.get_poll_detail(poll_uuid UUID)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.get_poll_detail(poll_uuid); $$;

CREATE FUNCTION public.list_poll_responses(
    poll_uuid UUID, page_size INTEGER DEFAULT 500, page_cursor TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.list_poll_responses(poll_uuid, page_size, page_cursor); $$;

REVOKE ALL ON FUNCTION public.list_poll_summaries(TEXT, INTEGER, TEXT),
    public.get_poll_detail(UUID),
    public.list_poll_responses(UUID, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_poll_summaries(TEXT, INTEGER, TEXT),
    public.get_poll_detail(UUID),
    public.list_poll_responses(UUID, INTEGER, TEXT) TO authenticated, service_role;

COMMIT;
