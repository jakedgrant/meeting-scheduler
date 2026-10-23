import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import pg from 'pg';

// Run only against a fresh disposable database. CI creates one explicitly;
// local callers must reserve their own runtime before starting this command.
const connectionString = process.env.TEST_DATABASE_URL;
assert.ok(connectionString, 'TEST_DATABASE_URL must name a fresh disposable PostgreSQL database');
const databaseName = decodeURIComponent(new URL(connectionString).pathname.slice(1));
assert.match(databaseName, /^scheduler_test_/, 'refusing a database outside scheduler_test_*');
const owner = '00000000-0000-4000-8000-000000000001';
const member = '00000000-0000-4000-8000-000000000002';
const claimant = '00000000-0000-4000-8000-000000000003';
const sqlValue = value => JSON.stringify(value);

test('real PostgreSQL command ordering with independent sessions', { timeout: 90000 }, async t => {
  const admin = new pg.Client({ connectionString, application_name: 'scheduler-race-observer' });
  const first = new pg.Client({ connectionString, application_name: 'scheduler-race-first' });
  const second = new pg.Client({ connectionString, application_name: 'scheduler-race-second' });
  await Promise.all([admin.connect(), first.connect(), second.connect()]);
  t.after(async () => { await Promise.all([admin.end(), first.end(), second.end()]); });
  await Promise.all([admin, first, second].map(client => client.query("SET statement_timeout='10s'")));
  const query = async (client, sql, params = []) => (await client.query(sql, params)).rows;
  assert.equal((await query(admin, `SELECT count(*)::int AS n FROM information_schema.tables
    WHERE table_schema IN ('public','auth','private','poll_private')`))[0].n, 0, 'database must be empty');
  console.log(`Race runtime: ${(await query(admin, 'SELECT version() AS v'))[0].v}`);
  await admin.query(`
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
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
  `);
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    await admin.query(await readFile(new URL(name, directory), 'utf8'));
  }
  await admin.query(`INSERT INTO auth.users(id,email) VALUES ($1,'owner@test.invalid'),
    ($2,'member@test.invalid'),($3,'claimant@test.invalid')`, [owner, member, claimant]);

  const role = async (client, name, userId = '') => {
    await client.query('RESET ROLE');
    await client.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [userId]);
    await client.query("SELECT set_config('request.jwt.claims',$1,false)", [sqlValue({ role: name, sub: userId })]);
    await client.query(`SET ROLE ${name}`);
  };
  const fixture = async () => {
    const poll = (await query(admin, `INSERT INTO public.polls(creator_id,title,status)
      VALUES ($1,'Race fixture','active') RETURNING id`, [owner]))[0].id;
    const option = (await query(admin, `INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
      VALUES ($1,'2027-01-01T12:00Z','2027-01-01T13:00Z') RETURNING id`, [poll]))[0].id;
    const participant = (await query(admin, `INSERT INTO public.poll_participants(poll_id,user_id)
      VALUES ($1,$2) RETURNING id`, [poll, member]))[0].id;
    await role(first, 'anon');
    const guest = (await query(first, 'SELECT public.join_poll_as_guest($1,$2) AS result', [poll, 'Guest']))[0].result;
    return { poll, option, participant, guest };
  };
  const save = (client, f, guest = false, requestId = randomUUID()) => query(client,
    'SELECT public.save_availability($1,$2,$3,$4,NULL,$5,$6) AS result',
    [f.poll, requestId, sqlValue([{ time_option_id: f.option, status: 'available' }]), 'Saved',
      guest ? f.guest.participant.id : null, guest ? f.guest.guest_token : null]);
  const editGuest = (client, f) => query(client, 'SELECT public.update_guest_participant($1,$2,$3,$4) AS result',
    [f.guest.participant.id, f.guest.guest_token, 'Edited', 'Guest edit']);
  const claim = (client, f) => query(client, 'SELECT public.claim_guest_participant($1,$2) AS result',
    [f.guest.participant.id, f.guest.guest_token]);
  const rotate = (client, f) => query(client, 'SELECT public.rotate_guest_token($1,$2) AS result',
    [f.guest.participant.id, f.guest.guest_token]);
  const final = (client, f) => query(client, 'SELECT public.finalize_poll($1,$2) AS result', [f.poll, f.option]);
  const mutateOption = (client, f, action) => action === 'delete'
    ? client.query('DELETE FROM public.poll_time_options WHERE id=$1', [f.option])
    : client.query(`UPDATE public.poll_time_options SET start_time=start_time+interval '1 hour',
        end_time=end_time+interval '1 hour' WHERE id=$1`, [f.option]);
  const observeWait = async pid => {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      const [row] = await query(admin, 'SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1', [pid]);
      if (row?.wait_event_type === 'Lock') return;
      await delay(20);
    }
    assert.fail(`session ${pid} did not actually wait for a database lock`);
  };
  const race = async (winner, loser, expectedCode = null) => {
    await first.query('BEGIN');
    try {
      const won = await winner();
      const pid = (await query(second, 'SELECT pg_backend_pid() AS pid'))[0].pid;
      const pending = loser().then(result => ({ result }), error => ({ error }));
      await observeWait(pid);
      await first.query('COMMIT');
      const outcome = await pending;
      if (expectedCode) assert.equal(outcome.error?.code, expectedCode, outcome.error?.message);
      else if (outcome.error) throw outcome.error;
      return { won, outcome };
    } finally { await first.query('ROLLBACK'); }
  };

  for (const operation of ['update', 'save', 'rotate', 'claim']) {
    await t.test(`claim commits before waiting guest ${operation}: old capability denied`, async () => {
      const f = await fixture();
      await role(first, 'authenticated', claimant);
      await role(second, operation === 'claim' ? 'authenticated' : 'anon', operation === 'claim' ? member : '');
      const operationFn = { update: editGuest, save: (c, x) => save(c, x, true), rotate, claim }[operation];
      await race(() => claim(first, f), () => operationFn(second, f), '42501');
      const [row] = await query(admin, 'SELECT user_id,comment FROM public.poll_participants WHERE id=$1', [f.guest.participant.id]);
      assert.equal(row.user_id, claimant);
      assert.equal(row.comment, null);
    });
  }
  for (const operation of ['update', 'save', 'rotate', 'claim']) {
    await t.test(`rotation commits before waiting guest ${operation}: old capability denied`, async () => {
      const f = await fixture();
      await role(first, 'anon');
      await role(second, operation === 'claim' ? 'authenticated' : 'anon', operation === 'claim' ? claimant : '');
      const operationFn = { update: editGuest, save: (c, x) => save(c, x, true), rotate, claim }[operation];
      await race(() => rotate(first, f), () => operationFn(second, f), '42501');
      assert.equal((await query(admin, 'SELECT comment FROM public.poll_participants WHERE id=$1', [f.guest.participant.id]))[0].comment, null);
    });
  }
  await t.test('guest edit commits before waiting claim and its result is preserved', async () => {
    const f = await fixture();
    await role(first, 'anon'); await role(second, 'authenticated', claimant);
    await race(() => editGuest(first, f), () => claim(second, f));
    assert.equal((await query(admin, 'SELECT comment FROM public.poll_participants WHERE id=$1', [f.guest.participant.id]))[0].comment, 'Guest edit');
  });
  for (const guest of [false, true]) {
    await t.test(`${guest ? 'guest' : 'member'} save commits before waiting close`, async () => {
      const f = await fixture();
      await role(first, guest ? 'anon' : 'authenticated', guest ? '' : member);
      await role(second, 'authenticated', owner);
      await race(() => save(first, f, guest), () => second.query("UPDATE public.polls SET status='closed' WHERE id=$1", [f.poll]));
      assert.equal((await query(admin, 'SELECT count(*)::int AS n FROM public.availability_responses WHERE participant_id=$1',
        [guest ? f.guest.participant.id : f.participant]))[0].n, 1);
    });
    await t.test(`close commits before waiting ${guest ? 'guest' : 'member'} save: no partial write`, async () => {
      const f = await fixture();
      await role(first, 'authenticated', owner);
      await role(second, guest ? 'anon' : 'authenticated', guest ? '' : member);
      await race(() => first.query("UPDATE public.polls SET status='closed' WHERE id=$1", [f.poll]), () => save(second, f, guest), '42501');
      assert.equal((await query(admin, 'SELECT count(*)::int AS n FROM public.availability_responses WHERE participant_id=$1',
        [guest ? f.guest.participant.id : f.participant]))[0].n, 0);
    });
  }
  for (const action of ['edit', 'delete']) {
    await t.test(`finalization commits before waiting option ${action}: mutation rejected`, async () => {
      const f = await fixture();
      await role(first, 'authenticated', owner); await role(second, 'authenticated', owner);
      await race(() => final(first, f), () => mutateOption(second, f, action), '23514');
      assert.equal((await query(admin, `SELECT count(*)::int AS n FROM public.polls p JOIN public.poll_time_options o
        ON o.poll_id=p.id AND (o.start_time,o.end_time)=(p.selected_start_time,p.selected_end_time) WHERE p.id=$1`, [f.poll]))[0].n, 1);
    });
    await t.test(`option ${action} commits before waiting finalization: current interval or rejection`, async () => {
      const f = await fixture();
      await role(first, 'authenticated', owner); await role(second, 'authenticated', owner);
      await race(() => mutateOption(first, f, action), () => final(second, f), action === 'delete' ? '22023' : null);
      const [p] = await query(admin, 'SELECT status,selected_start_time FROM public.polls WHERE id=$1', [f.poll]);
      if (action === 'delete') assert.equal(p.selected_start_time, null);
      else assert.equal(p.selected_start_time.toISOString(), '2027-01-01T13:00:00.000Z');
    });
  }
});
