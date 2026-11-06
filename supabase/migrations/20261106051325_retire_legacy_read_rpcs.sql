-- F19: retire the legacy poll read RPCs.
--
-- Bounded replacements exist and every client reads through them:
--
-- * get_user_participated_polls -> list_poll_summaries (20261025062518)
-- * get_poll_with_summary       -> get_poll_detail + list_poll_responses (20261025062518)
-- * get_guest_poll_detail       -> get_poll_detail_as_guest + list_poll_responses_as_guest (20261105214548)
--
-- Apply this migration only after every deployed web build calls
-- get_poll_detail_as_guest and no released native build calls any of the three
-- functions dropped here; see docs/read-contracts.md.
--
-- Nothing else depends on them. The poll_private builders added by
-- 20261105214548 (bounded_poll_detail, poll_response_page, guest_poll) and the
-- helpers they use (can_read_poll, verified_guest_participant, require_self)
-- stay: the replacement reads and other functions call them.
--
-- No checked-in migration references the dropped functions except the wrapper
-- that calls poll_private.get_guest_poll_detail, so no CASCADE is needed. Without
-- CASCADE a view, policy or SQL-function dependency that PostgreSQL tracks makes
-- the migration fail. A call inside a plpgsql body is not tracked; check hosted
-- definitions as described in docs/read-contracts.md before applying.
BEGIN;

DROP FUNCTION public.get_guest_poll_detail(UUID, TEXT);
DROP FUNCTION poll_private.get_guest_poll_detail(UUID, TEXT);
DROP FUNCTION public.get_user_participated_polls(UUID);
DROP FUNCTION public.get_poll_with_summary(UUID);

COMMIT;
