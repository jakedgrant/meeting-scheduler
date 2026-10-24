import { readdir, readFile } from 'node:fs/promises';
export async function bootstrapCreationDatabase(db, beforeMigration = async () => {}) {
  await db.exec(`
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
    END $$;
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id UUID PRIMARY KEY, email TEXT, raw_user_meta_data JSONB DEFAULT '{}',
      deleted_at TIMESTAMPTZ, banned_until TIMESTAMPTZ);
    CREATE TABLE auth.sessions(id UUID PRIMARY KEY, user_id UUID REFERENCES auth.users ON DELETE CASCADE,
      not_after TIMESTAMPTZ);
    CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    $$;
    CREATE FUNCTION auth.jwt() RETURNS JSONB LANGUAGE sql STABLE AS $$
      SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
    $$;
    GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
    CREATE PUBLICATION supabase_realtime;
    SET TIME ZONE 'UTC';
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
  `);


  const directory = new URL('../../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    await beforeMigration(name);
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
}
export const creationPayload = (extra = {}) => ({
  title: 'A transactional poll', description: null, location: null, timezone: 'America/Chicago', closes_at: null,
  use_event_pass: false, time_options: [
    {start_time:'2027-11-01T12:00:00Z',end_time:'2027-11-01T13:00:00Z',is_all_day:false},
    {start_time:'2027-11-02T12:00:00Z',end_time:'2027-11-02T13:00:00Z',is_all_day:false},
  ], ...extra
});
