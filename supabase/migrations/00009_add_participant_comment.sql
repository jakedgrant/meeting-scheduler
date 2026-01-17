-- Add comment field to poll_participants table
ALTER TABLE public.poll_participants ADD COLUMN comment TEXT;
