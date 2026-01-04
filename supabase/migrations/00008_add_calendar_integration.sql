-- Add calendar integration support to profiles table
-- Stores OAuth tokens for Google Calendar and user preferences

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS
  calendar_integration_enabled BOOLEAN DEFAULT FALSE;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS
  google_calendar_refresh_token TEXT;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS
  google_calendar_token_expires_at TIMESTAMPTZ;

-- Index for efficient token expiry lookups
CREATE INDEX IF NOT EXISTS idx_profiles_calendar_token_expiry
  ON public.profiles(google_calendar_token_expires_at)
  WHERE google_calendar_refresh_token IS NOT NULL;

-- Add column comments for clarity
COMMENT ON COLUMN public.profiles.calendar_integration_enabled IS
  'Whether user has enabled automatic calendar conflict checking';

COMMENT ON COLUMN public.profiles.google_calendar_refresh_token IS
  'Encrypted Google OAuth refresh token for Calendar API access (web only)';

COMMENT ON COLUMN public.profiles.google_calendar_token_expires_at IS
  'Expiration timestamp for Google Calendar access token';
