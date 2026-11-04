-- Columns that have a default and that the native clients decode as required.
--
-- iOS decodes all of these columns as non-optional, so a null in any of them
-- already fails to decode there. Android models them as non-null fields.
-- Requiring them here makes the schema say the same thing, and the
-- web's generated types follow from the schema.
--
-- A null in an existing row is replaced with the column's default first.
-- User triggers are disabled only for that backfill: the updated_at triggers
-- would restamp the repaired rows, and the poll and time-option validation
-- triggers can reject a repair, such as setting the zone of a poll that already
-- has all-day options. None of them applies to filling a missing value. The
-- transaction keeps the triggers off only for this migration's own writes.

BEGIN;

ALTER TABLE public.availability_responses DISABLE TRIGGER USER;
UPDATE public.availability_responses SET created_at = DEFAULT WHERE created_at IS NULL;
UPDATE public.availability_responses SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.availability_responses ENABLE TRIGGER USER;
ALTER TABLE public.availability_responses
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

UPDATE public.event_passes SET created_at = DEFAULT WHERE created_at IS NULL;
ALTER TABLE public.event_passes ALTER COLUMN created_at SET NOT NULL;

ALTER TABLE public.poll_participants DISABLE TRIGGER USER;
UPDATE public.poll_participants SET created_at = DEFAULT WHERE created_at IS NULL;
UPDATE public.poll_participants SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.poll_participants ENABLE TRIGGER USER;
ALTER TABLE public.poll_participants
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE public.poll_time_options DISABLE TRIGGER USER;
UPDATE public.poll_time_options SET created_at = DEFAULT WHERE created_at IS NULL;
UPDATE public.poll_time_options SET is_all_day = DEFAULT WHERE is_all_day IS NULL;
ALTER TABLE public.poll_time_options ENABLE TRIGGER USER;
ALTER TABLE public.poll_time_options
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN is_all_day SET NOT NULL;

ALTER TABLE public.polls DISABLE TRIGGER USER;
UPDATE public.polls SET is_premium = DEFAULT WHERE is_premium IS NULL;
UPDATE public.polls SET max_participants = DEFAULT WHERE max_participants IS NULL;
UPDATE public.polls SET status = DEFAULT WHERE status IS NULL;
UPDATE public.polls SET timezone = DEFAULT WHERE timezone IS NULL;
UPDATE public.polls SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.polls ENABLE TRIGGER USER;
ALTER TABLE public.polls
    ALTER COLUMN is_premium SET NOT NULL,
    ALTER COLUMN max_participants SET NOT NULL,
    ALTER COLUMN status SET NOT NULL,
    ALTER COLUMN timezone SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE public.profiles DISABLE TRIGGER USER;
UPDATE public.profiles SET created_at = DEFAULT WHERE created_at IS NULL;
UPDATE public.profiles SET timezone = DEFAULT WHERE timezone IS NULL;
UPDATE public.profiles SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.profiles ENABLE TRIGGER USER;
ALTER TABLE public.profiles
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN timezone SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE public.subscriptions DISABLE TRIGGER USER;
UPDATE public.subscriptions SET created_at = DEFAULT WHERE created_at IS NULL;
UPDATE public.subscriptions SET is_active = DEFAULT WHERE is_active IS NULL;
UPDATE public.subscriptions SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE public.subscriptions ENABLE TRIGGER USER;
ALTER TABLE public.subscriptions
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN is_active SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

COMMIT;
