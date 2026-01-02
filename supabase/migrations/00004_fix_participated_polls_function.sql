-- ============================================
-- FIX PARTICIPATED POLLS FUNCTION
-- ============================================
-- Update the function to properly convert poll rows to JSON using row_to_json

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
