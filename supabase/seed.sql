-- ============================================
-- SEED DATA FOR LOCAL DEVELOPMENT
-- ============================================

-- Note: This seed file is for local development only.
-- It creates test users and sample data.
-- Do NOT run this in production.

-- Sample polls will be created after users sign up
-- since they require valid auth.users references.

-- You can manually create test data after signing up:
--
-- INSERT INTO public.polls (creator_id, title, description, status, timezone)
-- VALUES (
--   'your-user-uuid-here',
--   'Team Meeting Poll',
--   'Let''s find a time that works for everyone!',
--   'active',
--   'America/New_York'
-- );
