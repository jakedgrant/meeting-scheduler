-- F01 follow-up: profile read access.
--
-- 00001 let every caller, signed in or not, read every profiles row, email
-- included. After this migration:
--
-- * Signed-out callers read no profile rows and hold no profiles privileges.
-- * A signed-in caller reads their own row and the rows of people they share a
--   poll with, as its creator or a participant.
-- * Through the Data API, a signed-in caller can read only id, display_name and
--   avatar_url, on any row. email, timezone and the timestamps are owner data,
--   which get_my_profile returns for the caller's own row only.
--
-- Definer functions that read profiles (the poll detail builders, the creation
-- lock, the signup trigger) run as the table owner and are unaffected. Clients
-- must stop selecting * from profiles, including the implicit * of an update
-- that returns its row; see docs/profile-access.md.
BEGIN;

-- The users who share at least one poll with the caller, each as its creator or
-- a participant, the caller included. It bypasses polls and participants RLS to
-- avoid policy recursion and answers only for the current caller; signed out, it
-- returns nothing. The policy below evaluates it once per statement rather than
-- once per profile row, so an unfiltered read does not run it across the table.
CREATE FUNCTION poll_private.poll_peer_ids()
RETURNS SETOF UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
    WITH mine(poll_id) AS (
        SELECT p.id FROM public.polls p WHERE p.creator_id = (SELECT auth.uid())
        UNION
        SELECT pp.poll_id FROM public.poll_participants pp WHERE pp.user_id = (SELECT auth.uid())
    )
    SELECT p.creator_id FROM public.polls p JOIN mine ON mine.poll_id = p.id
    UNION
    SELECT pp.user_id FROM public.poll_participants pp JOIN mine ON mine.poll_id = pp.poll_id
    WHERE pp.user_id IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION poll_private.poll_peer_ids() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.poll_peer_ids() TO authenticated, service_role;

DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;

CREATE POLICY "Profiles are visible to their owner and poll peers"
    ON public.profiles FOR SELECT TO authenticated
    USING (id = (SELECT auth.uid()) OR id IN (SELECT poll_private.poll_peer_ids()));

-- Row policies cannot hide columns, so the grants do. anon has no use for
-- profiles at all; its UPDATE, INSERT and DELETE were already denied by RLS.
REVOKE ALL ON public.profiles FROM anon;
REVOKE SELECT ON public.profiles FROM authenticated;
GRANT SELECT (id, display_name, avatar_url) ON public.profiles TO authenticated;

-- The caller's own full row, email included.
CREATE FUNCTION poll_private.get_my_profile()
RETURNS SETOF public.profiles
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
ROWS 1
AS $$
    SELECT * FROM public.profiles WHERE id = (SELECT auth.uid());
$$;
REVOKE ALL ON FUNCTION poll_private.get_my_profile() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.get_my_profile() TO authenticated, service_role;

CREATE FUNCTION public.get_my_profile()
RETURNS SETOF public.profiles
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
ROWS 1
AS $$ SELECT * FROM poll_private.get_my_profile(); $$;
REVOKE ALL ON FUNCTION public.get_my_profile() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_profile() TO authenticated, service_role;

COMMIT;
