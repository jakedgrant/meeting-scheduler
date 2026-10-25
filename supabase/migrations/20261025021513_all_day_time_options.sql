-- F21: an all-day option is one calendar date in its poll's IANA zone, stored as
-- the first instant of that date through the first instant of the next date
-- (exclusive). See docs/date-time-contract.md.
--
-- Additive. Existing rows, including legacy 23:59 all-day ends, are not
-- rewritten or revalidated; clients read their date from start_time. New or
-- edited intervals must follow the contract, through create_poll and direct
-- option writes alike.

-- True when t is the first instant of its calendar date in zone. This holds for
-- a local midnight and for the first time after a skipped midnight, and does not
-- depend on how PostgreSQL resolves a nonexistent or repeated wall time.
CREATE FUNCTION poll_private.is_zone_day_start(t timestamptz, zone text)
RETURNS boolean LANGUAGE sql STABLE STRICT SET search_path='' AS $$
    SELECT (t AT TIME ZONE zone)::date > ((t - interval '1 microsecond') AT TIME ZONE zone)::date;
$$;
REVOKE ALL ON FUNCTION poll_private.is_zone_day_start(timestamptz,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION poll_private.check_poll_option()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
DECLARE
    zone text;
BEGIN
    SELECT p.timezone INTO zone FROM public.polls p WHERE p.id=NEW.poll_id FOR UPDATE;
    IF NOT isfinite(NEW.start_time) OR NOT isfinite(NEW.end_time)
      OR NEW.start_time IS NULL OR NEW.end_time IS NULL OR NEW.end_time<=NEW.start_time
      OR NEW.is_all_day IS NULL THEN
        RAISE EXCEPTION 'Invalid time option' USING ERRCODE='22023';
    END IF;
    IF NEW.is_all_day AND (TG_OP='INSERT' OR NEW.start_time IS DISTINCT FROM OLD.start_time
        OR NEW.end_time IS DISTINCT FROM OLD.end_time OR NEW.is_all_day IS DISTINCT FROM OLD.is_all_day
        OR NEW.poll_id IS DISTINCT FROM OLD.poll_id) THEN
        zone := coalesce(zone,'UTC');
        IF NOT poll_private.is_zone_day_start(NEW.start_time,zone)
          OR NOT poll_private.is_zone_day_start(NEW.end_time,zone)
          OR (NEW.end_time AT TIME ZONE zone)::date<>(NEW.start_time AT TIME ZONE zone)::date+1 THEN
            RAISE EXCEPTION 'An all-day option must run from the start of one date to the start of the next in the poll timezone'
              USING ERRCODE='22023';
        END IF;
    END IF;
    IF TG_OP='INSERT' AND (SELECT count(*) FROM public.poll_time_options WHERE poll_id=NEW.poll_id)>=500 THEN
        RAISE EXCEPTION 'Provide between 1 and 500 time options' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_poll_option() FROM PUBLIC,anon,authenticated;

-- All-day dates are read in the poll's zone, so changing that zone would move
-- every all-day option to a different date. Reject it while any exist.
CREATE FUNCTION poll_private.check_poll_timezone_change()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path='' AS $$
BEGIN
    IF NEW.timezone IS DISTINCT FROM OLD.timezone
      AND EXISTS (SELECT 1 FROM public.poll_time_options o WHERE o.poll_id=NEW.id AND o.is_all_day) THEN
        RAISE EXCEPTION 'The timezone of a poll with all-day options cannot change' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION poll_private.check_poll_timezone_change() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER polls_06_timezone BEFORE UPDATE OF timezone ON public.polls
FOR EACH ROW EXECUTE FUNCTION poll_private.check_poll_timezone_change();
