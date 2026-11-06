-- F19: bounded guest reads.
--
-- get_guest_poll_detail returns every response of the poll in one value. Guests
-- now read the same bounded detail and response pages members use, through
-- their capability:
--
-- * get_poll_detail_as_guest returns get_poll_detail's value plus the guest's
--   participant_id, with the same size limits.
-- * list_poll_responses_as_guest returns list_poll_responses' pages, r1:
--   cursors and first-page total.
--
-- Member and guest reads share one detail builder and one response pager, so
-- the two contracts cannot drift. get_guest_poll_detail stays for web builds
-- released before this migration; see docs/read-contracts.md.
BEGIN;

-- Unauthorized builders. Only the authorizing definers below may call them.
CREATE FUNCTION poll_private.bounded_poll_detail(poll_uuid UUID)
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

CREATE FUNCTION poll_private.poll_response_page(poll_uuid UUID, page_size INTEGER, page_cursor TEXT)
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

    -- Only same-poll pairs count, matching get_poll_with_summary.
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

REVOKE ALL ON FUNCTION poll_private.bounded_poll_detail(UUID),
    poll_private.poll_response_page(UUID, INTEGER, TEXT) FROM PUBLIC, anon, authenticated, service_role;

-- Member reads keep their signatures, grants and errors; only the bodies move.
CREATE OR REPLACE FUNCTION poll_private.get_poll_detail(poll_uuid UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT poll_private.can_read_poll(poll_uuid) THEN
        -- Missing and inaccessible polls have the same public error.
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
    RETURN poll_private.bounded_poll_detail(poll_uuid);
END;
$$;

CREATE OR REPLACE FUNCTION poll_private.list_poll_responses(poll_uuid UUID, page_size INTEGER, page_cursor TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT poll_private.can_read_poll(poll_uuid) THEN
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;
    RETURN poll_private.poll_response_page(poll_uuid, page_size, page_cursor);
END;
$$;

-- The guest's poll, or 42501 when the capability does not verify. Like
-- get_guest_poll_detail, a guest keeps read access after the poll closes.
CREATE FUNCTION poll_private.guest_poll(participant_uuid UUID, guest_token TEXT)
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    guest_poll UUID;
BEGIN
    SELECT pp.poll_id INTO guest_poll
    FROM public.poll_participants pp
    WHERE pp.id = poll_private.verified_guest_participant(participant_uuid, guest_token);
    IF guest_poll IS NULL THEN
        RAISE EXCEPTION 'Guest access denied' USING ERRCODE = '42501';
    END IF;
    RETURN guest_poll;
END;
$$;

REVOKE ALL ON FUNCTION poll_private.guest_poll(UUID, TEXT) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION poll_private.get_poll_detail_as_guest(participant_uuid UUID, guest_token TEXT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT poll_private.bounded_poll_detail(poll_private.guest_poll(participant_uuid, guest_token))
        || jsonb_build_object('participant_id', participant_uuid);
$$;

CREATE FUNCTION poll_private.list_poll_responses_as_guest(
    participant_uuid UUID, guest_token TEXT, page_size INTEGER, page_cursor TEXT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT poll_private.poll_response_page(
        poll_private.guest_poll(participant_uuid, guest_token), page_size, page_cursor);
$$;

REVOKE ALL ON FUNCTION poll_private.get_poll_detail_as_guest(UUID, TEXT),
    poll_private.list_poll_responses_as_guest(UUID, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.get_poll_detail_as_guest(UUID, TEXT),
    poll_private.list_poll_responses_as_guest(UUID, TEXT, INTEGER, TEXT) TO anon, authenticated, service_role;

CREATE FUNCTION public.get_poll_detail_as_guest(participant_uuid UUID, guest_token TEXT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.get_poll_detail_as_guest(participant_uuid, guest_token); $$;

CREATE FUNCTION public.list_poll_responses_as_guest(
    participant_uuid UUID, guest_token TEXT, page_size INTEGER DEFAULT 500, page_cursor TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.list_poll_responses_as_guest(participant_uuid, guest_token, page_size, page_cursor); $$;

REVOKE ALL ON FUNCTION public.get_poll_detail_as_guest(UUID, TEXT),
    public.list_poll_responses_as_guest(UUID, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_poll_detail_as_guest(UUID, TEXT),
    public.list_poll_responses_as_guest(UUID, TEXT, INTEGER, TEXT) TO anon, authenticated, service_role;

COMMIT;
