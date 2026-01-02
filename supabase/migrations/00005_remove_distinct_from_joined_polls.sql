-- Remove DISTINCT from joined_polls aggregation to fix PostgreSQL error
-- Each user can only join a poll once, so DISTINCT is unnecessary and causes ORDER BY conflicts

CREATE OR REPLACE FUNCTION public.get_user_participated_polls(user_uuid UUID DEFAULT auth.uid())
RETURNS JSON AS $$
BEGIN
    RETURN json_build_object(
        'created_polls', COALESCE(
            (SELECT json_agg(row_to_json(p) ORDER BY p.created_at DESC)
             FROM public.polls p
             WHERE p.creator_id = user_uuid),
            '[]'::json
        ),
        'joined_polls', COALESCE(
            (SELECT json_agg(row_to_json(p) ORDER BY p.created_at DESC)
             FROM public.polls p
             INNER JOIN public.poll_participants pp ON pp.poll_id = p.id
             WHERE pp.user_id = user_uuid
             AND p.creator_id != user_uuid),
            '[]'::json
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
