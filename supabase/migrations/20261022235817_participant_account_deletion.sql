-- Account deletion anonymizes poll participation (owner decision, October 22).
--
-- Deleting an auth user cascades to public.profiles. poll_participants.user_id
-- is ON DELETE SET NULL, but participant_identity requires a user or a guest
-- name, so deleting anyone who had joined a poll failed. Before the profile row
-- goes, this trigger turns each of the user's participant rows into an
-- anonymous, capability-less row:
--   * user_id -> NULL, display name -> 'Deleted user'
--   * a non-null comment -> '[user deleted]' (a NULL comment stays NULL)
--   * availability responses are kept on the row
--   * any private guest credential (verifier, contact email) is deleted, so the
--     row can never verify as a guest or be claimed
--   * F04 merge-audit copies that name the user are deleted
-- The user's own polls still follow the existing creator_id ON DELETE CASCADE.
BEGIN;

CREATE FUNCTION poll_private.anonymize_deleted_participant()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    DELETE FROM private.participant_guest_credentials c
    USING public.poll_participants pp
    WHERE c.participant_id = pp.id AND pp.user_id = OLD.id;

    -- Runs as the function owner, so the F03/F04 identity trigger permits the
    -- user -> NULL unlink and the name change (it blocks only API callers and
    -- user-to-user reassignment).
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

-- BEFORE DELETE runs ahead of the profile foreign-key actions (AFTER
-- triggers), so ON DELETE SET NULL then finds no rows left to change.
CREATE TRIGGER profiles_anonymize_participation
    BEFORE DELETE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION poll_private.anonymize_deleted_participant();

COMMIT;
