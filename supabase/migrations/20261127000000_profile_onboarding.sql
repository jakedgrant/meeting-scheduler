-- Onboarding completion, recorded per account so a reinstall or a second
-- device does not show the onboarding flow again.
--
-- * profiles.onboarding_completed_at is NULL until the account finishes or
--   skips onboarding. get_my_profile returns it with the rest of the row; the
--   Data API column grants are unchanged, so peers cannot read it.
-- * Accounts that existed before this migration already went through their
--   first sign-in, so they are marked complete as of their creation.
-- * complete_onboarding() stamps the caller's row with the server time once and
--   returns the stored value. Calling it again keeps the first timestamp, so a
--   client can retry it freely.
BEGIN;

ALTER TABLE public.profiles ADD COLUMN onboarding_completed_at TIMESTAMPTZ;

-- The backfill is not a profile edit, so it keeps each row's updated_at.
ALTER TABLE public.profiles DISABLE TRIGGER update_profiles_updated_at;
UPDATE public.profiles SET onboarding_completed_at = created_at;
ALTER TABLE public.profiles ENABLE TRIGGER update_profiles_updated_at;

-- Follows get_my_profile: authenticated can read only id, display_name and
-- avatar_url, so the definer reads and stamps the column for the caller's own
-- row, and the public invoker wrapper is the API surface. Signed out,
-- auth.uid() is NULL, nothing matches and the result is NULL.
CREATE FUNCTION poll_private.complete_onboarding()
RETURNS TIMESTAMPTZ
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = ''
AS $$
    UPDATE public.profiles
    SET onboarding_completed_at = coalesce(onboarding_completed_at, now())
    WHERE id = (SELECT auth.uid())
    RETURNING onboarding_completed_at;
$$;
REVOKE ALL ON FUNCTION poll_private.complete_onboarding() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION poll_private.complete_onboarding() TO authenticated, service_role;

CREATE FUNCTION public.complete_onboarding()
RETURNS TIMESTAMPTZ
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = ''
AS $$ SELECT poll_private.complete_onboarding(); $$;
REVOKE ALL ON FUNCTION public.complete_onboarding() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_onboarding() TO authenticated, service_role;

COMMIT;
