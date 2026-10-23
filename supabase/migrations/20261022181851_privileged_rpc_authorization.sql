-- F02: authorize every legacy poll/access RPC without changing its argument names
-- or result shape. Table-policy and guest-ownership repairs belong to F03/F04.
BEGIN;

-- This schema must remain outside the Data API's exposed schemas. Only the
-- helpers below are callable; no client role can create objects here.
CREATE SCHEMA poll_private;
REVOKE ALL ON SCHEMA poll_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA poll_private TO anon, authenticated, service_role;

CREATE FUNCTION poll_private.require_self(user_uuid UUID)
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := auth.uid();
BEGIN
    IF caller_id IS NULL OR user_uuid IS DISTINCT FROM caller_id THEN
        RAISE EXCEPTION 'Authenticated self-service access required' USING ERRCODE = '42501';
    END IF;
    RETURN caller_id;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.require_self(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.require_self(UUID) TO authenticated, service_role;

-- Bypass participant RLS only to answer membership for the current caller.
-- This avoids the existing polls <-> participants RLS recursion. It never
-- accepts another user's identity, including when called directly.
CREATE FUNCTION poll_private.is_poll_participant(poll_uuid UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.poll_participants pp
        WHERE pp.poll_id = poll_uuid AND pp.user_id = (SELECT auth.uid())
    );
$$;
REVOKE ALL ON FUNCTION poll_private.is_poll_participant(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.is_poll_participant(UUID) TO anon, authenticated, service_role;

CREATE FUNCTION poll_private.can_read_poll(poll_uuid UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.polls p
        WHERE p.id = poll_uuid AND (
            p.creator_id = (SELECT auth.uid())
            OR poll_private.is_poll_participant(p.id)
        )
    );
$$;
REVOKE ALL ON FUNCTION poll_private.can_read_poll(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.can_read_poll(UUID) TO authenticated, service_role;

-- Keep the signature used by existing policies, but prohibit membership probes
-- for another user. NULL and signed-out policy evaluations return false.
CREATE OR REPLACE FUNCTION public.is_poll_participant(poll_uuid UUID, user_uuid UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT CASE WHEN user_uuid = auth.uid()
        THEN poll_private.is_poll_participant(poll_uuid)
        ELSE false END;
$$;
REVOKE ALL ON FUNCTION public.is_poll_participant(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_poll_participant(UUID, UUID) TO anon, authenticated, service_role;

-- Optional UUID arguments remain for installed clients. Every supplied value
-- must match the authenticated caller; queries use only the verified identity.
-- These reads use the caller's table grants and RLS, rather than bypassing them.
CREATE OR REPLACE FUNCTION public.has_active_subscription(user_uuid UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.subscriptions s
        WHERE s.user_id = caller_id AND s.is_active = true
          AND (s.expires_at IS NULL OR s.expires_at > now())
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_entitlement(user_uuid UUID DEFAULT auth.uid())
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN (
        SELECT s.entitlement FROM public.subscriptions s
        WHERE s.user_id = caller_id AND s.is_active = true
          AND (s.expires_at IS NULL OR s.expires_at > now())
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.count_unredeemed_passes(user_uuid UUID DEFAULT auth.uid())
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN (
        SELECT count(*)::INTEGER FROM public.event_passes ep
        WHERE ep.user_id = caller_id AND ep.redeemed_at IS NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.count_active_polls(user_uuid UUID DEFAULT auth.uid())
RETURNS INTEGER
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN (
        SELECT count(*)::INTEGER FROM public.polls p
        WHERE p.creator_id = caller_id AND p.status IN ('draft', 'active')
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.can_create_poll(user_uuid UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN public.has_active_subscription(caller_id)
        OR public.count_unredeemed_passes(caller_id) > 0
        OR public.count_active_polls(caller_id) < 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_participated_polls(user_uuid UUID DEFAULT auth.uid())
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    caller_id UUID := poll_private.require_self(user_uuid);
BEGIN
    RETURN json_build_object(
        'created_polls', COALESCE(
            (SELECT json_agg(row_to_json(p) ORDER BY p.created_at DESC)
             FROM public.polls p WHERE p.creator_id = caller_id), '[]'::json
        ),
        'joined_polls', COALESCE(
            (SELECT json_agg(row_to_json(p) ORDER BY p.created_at DESC)
             FROM public.polls p
             WHERE p.creator_id <> caller_id AND EXISTS (
                 SELECT 1 FROM public.poll_participants pp
                 WHERE pp.poll_id = p.id AND pp.user_id = caller_id
             )), '[]'::json
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.has_active_subscription(UUID), public.get_user_entitlement(UUID),
    public.count_unredeemed_passes(UUID), public.count_active_polls(UUID),
    public.can_create_poll(UUID), public.get_user_participated_polls(UUID)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.has_active_subscription(UUID), public.get_user_entitlement(UUID),
    public.count_unredeemed_passes(UUID), public.count_active_polls(UUID),
    public.can_create_poll(UUID), public.get_user_participated_polls(UUID)
    TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_poll_with_summary(poll_uuid UUID)
RETURNS JSON
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    result JSON;
BEGIN
    IF NOT poll_private.can_read_poll(poll_uuid) THEN
        -- Missing and inaccessible polls have the same public error.
        RAISE EXCEPTION 'Poll access denied' USING ERRCODE = '42501';
    END IF;

    SELECT json_build_object(
        'poll', row_to_json(p),
        'time_options', (
            SELECT json_agg(json_build_object(
                'id', pto.id,
                'start_time', pto.start_time,
                'end_time', pto.end_time,
                'is_all_day', pto.is_all_day,
                'responses', (
                    SELECT json_build_object(
                        'available', count(*) FILTER (WHERE ar.status = 'available'),
                        'maybe', count(*) FILTER (WHERE ar.status = 'maybe'),
                        'unavailable', count(*) FILTER (WHERE ar.status = 'unavailable'),
                        'total', count(*)
                    )
                    FROM public.availability_responses ar
                    JOIN public.poll_participants pp ON pp.id = ar.participant_id
                    WHERE ar.time_option_id = pto.id AND pp.poll_id = p.id
                )
            ))
            FROM public.poll_time_options pto WHERE pto.poll_id = p.id
        ),
        'participants', (
            SELECT json_agg(json_build_object(
                'id', pp.id,
                'display_name', COALESCE(pr.display_name, pp.anonymous_name),
                'avatar_url', pr.avatar_url,
                'responses', (
                    SELECT json_agg(json_build_object(
                        'time_option_id', ar.time_option_id,
                        'status', ar.status,
                        'note', ar.note
                    ))
                    FROM public.availability_responses ar
                    JOIN public.poll_time_options pto ON pto.id = ar.time_option_id
                    WHERE ar.participant_id = pp.id AND pto.poll_id = p.id
                )
            ))
            FROM public.poll_participants pp
            LEFT JOIN public.profiles pr ON pr.id = pp.user_id
            WHERE pp.poll_id = p.id
        )
    ) INTO result
    FROM public.polls p WHERE p.id = poll_uuid;
    RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_poll_with_summary(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_poll_with_summary(UUID) TO authenticated, service_role;

-- A shared code permits only this existing preview projection of an active
-- invitation. Non-active previews require current owner/member access. This
-- helper stays elevated so later RLS tightening cannot break invitation lookup.
CREATE FUNCTION poll_private.get_poll_by_code(code TEXT)
RETURNS TABLE (
    id UUID, title TEXT, description TEXT, location TEXT, status public.poll_status,
    creator_id UUID, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, share_code TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT p.id, p.title, p.description, p.location, p.status,
           p.creator_id, p.created_at, p.updated_at, p.share_code
    FROM public.polls p
    WHERE p.share_code = upper(btrim(code))
      AND (p.status = 'active' OR poll_private.can_read_poll(p.id));
$$;
REVOKE ALL ON FUNCTION poll_private.get_poll_by_code(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.get_poll_by_code(TEXT) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_poll_by_code(code TEXT)
RETURNS TABLE (
    id UUID, title TEXT, description TEXT, location TEXT, status public.poll_status,
    creator_id UUID, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ, share_code TEXT
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT * FROM poll_private.get_poll_by_code(code);
$$;
REVOKE ALL ON FUNCTION public.get_poll_by_code(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_poll_by_code(TEXT) TO anon, authenticated, service_role;

-- Preserve existing insert/update triggers without a publicly executable
-- privileged trigger entry point or caller-controlled name resolution.
ALTER FUNCTION public.handle_new_user() SET search_path = '';
ALTER FUNCTION public.update_updated_at() SET search_path = '';
ALTER FUNCTION public.generate_share_code() SET search_path = '';

CREATE OR REPLACE FUNCTION public.generate_unique_share_code()
RETURNS TEXT
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    new_code TEXT;
BEGIN
    LOOP
        new_code := public.generate_share_code();
        IF NOT EXISTS (SELECT 1 FROM public.polls p WHERE p.share_code = new_code) THEN
            RETURN new_code;
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_poll_share_code()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
    IF NEW.share_code IS NULL THEN
        NEW.share_code := public.generate_unique_share_code();
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user(), public.update_updated_at(),
    public.set_poll_share_code() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.generate_share_code(), public.generate_unique_share_code()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.generate_share_code(), public.generate_unique_share_code()
    TO authenticated, service_role;

-- Deliberately do not change global default privileges or other function grants:
-- public.calendar_admin and the independent billing worker retain ownership of
-- their service-role contracts. Every function above revokes its own PUBLIC ACL.
COMMIT;
