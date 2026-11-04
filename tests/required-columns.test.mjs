import assert from 'node:assert/strict';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { bootstrapCreationDatabase } from './helpers/creation-database.mjs';

const migration = '20261104000020_required_defaulted_columns.sql';
const user = '11111111-1111-4111-8111-111111111111';
const poll = '22222222-2222-4222-8222-222222222222';
const option = '33333333-3333-4333-8333-333333333333';
const participant = '44444444-4444-4444-8444-444444444444';
const created = '2026-01-02T03:04:05Z';

// The columns the migration requires, each of which has a default.
const required = {
  availability_responses: ['created_at', 'updated_at'],
  event_passes: ['created_at'],
  poll_participants: ['created_at', 'updated_at'],
  poll_time_options: ['created_at', 'is_all_day'],
  polls: ['is_premium', 'max_participants', 'status', 'timezone', 'updated_at'],
  profiles: ['created_at', 'timezone', 'updated_at'],
  subscriptions: ['created_at', 'is_active', 'updated_at'],
};

test('defaulted columns are backfilled and then required', async () => {
  const db = new PGlite();
  await bootstrapCreationDatabase(db, async name => {
    if (name !== migration) return;
    // Rows written before the columns were required, with the nulls the
    // schema used to allow. Triggers are skipped only to seed them.
    await db.exec(`
      SET session_replication_role = replica;
      INSERT INTO auth.users(id, email) VALUES ('${user}', 'owner@example.com');
      INSERT INTO public.profiles(id, email, created_at, timezone, updated_at)
        VALUES ('${user}', 'owner@example.com', '${created}', NULL, NULL);
      INSERT INTO public.subscriptions(user_id, created_at, is_active, updated_at)
        VALUES ('${user}', '${created}', NULL, NULL);
      INSERT INTO public.polls(id, creator_id, title, share_code, created_at,
          is_premium, max_participants, status, timezone, updated_at)
        VALUES ('${poll}', '${user}', 'Old poll', 'OLDROW', '${created}', NULL, NULL, NULL, NULL, NULL);
      INSERT INTO public.poll_time_options(id, poll_id, start_time, end_time, created_at, is_all_day)
        VALUES ('${option}', '${poll}', '2026-02-01T12:00:00Z', '2026-02-01T13:00:00Z', NULL, NULL);
      INSERT INTO public.poll_participants(id, poll_id, user_id, access_token, created_at, updated_at)
        VALUES ('${participant}', '${poll}', '${user}', '${participant}', '${created}', NULL);
      INSERT INTO public.availability_responses(participant_id, time_option_id, status, created_at, updated_at)
        VALUES ('${participant}', '${option}', 'available', '${created}', NULL);
      SET session_replication_role = origin;
    `);
  });

  const one = async sql => (await db.query(sql)).rows[0];
  assert.deepEqual(
    await one(`SELECT is_premium, max_participants, status, timezone, updated_at = created_at AS stamped
               FROM public.polls WHERE id = '${poll}'`),
    { is_premium: false, max_participants: 10, status: 'draft', timezone: 'UTC', stamped: true });
  assert.deepEqual(
    await one(`SELECT is_all_day, created_at IS NOT NULL AS created FROM public.poll_time_options WHERE id = '${option}'`),
    { is_all_day: false, created: true });
  assert.deepEqual(
    await one(`SELECT timezone, updated_at = created_at AS stamped FROM public.profiles WHERE id = '${user}'`),
    { timezone: 'UTC', stamped: true });
  assert.deepEqual(
    await one(`SELECT is_active, updated_at = created_at AS stamped FROM public.subscriptions WHERE user_id = '${user}'`),
    { is_active: false, stamped: true });
  for (const table of ['poll_participants', 'availability_responses']) {
    assert.deepEqual(await one(`SELECT bool_and(updated_at = created_at) AS stamped FROM public.${table}`), { stamped: true });
  }

  // A standing rule for later migrations too: a column with a default is required.
  const nullable = (await db.query(`
    SELECT table_name || '.' || column_name AS name FROM information_schema.columns
    WHERE table_schema = 'public' AND is_nullable = 'YES' AND column_default IS NOT NULL ORDER BY 1`)).rows;
  assert.deepEqual(nullable, [], 'every defaulted public column is required');
  const listed = Object.entries(required).flatMap(([table, columns]) => columns.map(column => `${table}.${column}`));
  const enforced = (await db.query(`
    SELECT c.relname || '.' || a.attname AS name FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND a.attnotnull AND c.relname || '.' || a.attname = ANY($1)`, [listed])).rows;
  assert.deepEqual(enforced.map(row => row.name).sort(), [...listed].sort());
  await assert.rejects(db.exec(`UPDATE public.polls SET timezone = NULL`), { code: '23502' });

  const disabled = (await db.query(`
    SELECT c.relname || '.' || t.tgname AS name FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND NOT t.tgisinternal AND t.tgenabled <> 'O'`)).rows;
  assert.deepEqual(disabled, [], 'the migration re-enables every trigger it disabled');
  await db.close();
});
