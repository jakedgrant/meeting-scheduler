import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const alice = '00000000-0000-4000-8000-000000000001';
const bob = '00000000-0000-4000-8000-000000000002';
const session = '00000000-0000-4000-8000-000000000003';
const ciphertext = JSON.stringify({ version: 1, key_id: 'test', iv: 'encrypted', ciphertext: 'encrypted' });

test('calendar migration and backend-only repository contract on real Postgres', async t => {
  const db = new PGlite();
  t.after(() => db.close());
  await db.exec(`
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
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
    CREATE PUBLICATION supabase_realtime;
  `);
  const directory = new URL('../supabase/migrations/', import.meta.url);
  const migrations = (await readdir(directory)).filter(name => name.endsWith('.sql')).sort();
  for (const name of migrations) {
    if (name.includes('private_calendar_credentials')) {
      await db.exec(`
        INSERT INTO auth.users(id,email) VALUES ('${alice}','alice@example.test'),('${bob}','bob@example.test');
        INSERT INTO auth.sessions(id,user_id) VALUES ('${session}','${alice}');
        UPDATE public.profiles SET google_calendar_access_token='formerly-public-access',
          google_calendar_refresh_token='formerly-public-refresh', calendar_integration_enabled=true;
      `);
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  const call = async (action, userId = null, data = {}) => {
    await db.exec('SET ROLE service_role');
    try {
      const result = await db.query('SELECT public.calendar_admin($1,$2,$3) AS result', [action, userId, JSON.stringify(data)]);
      return result.rows[0].result;
    } finally { await db.exec('RESET ROLE'); }
  };
  const begin = async (hash = 'a'.repeat(64)) => ({ generation: await call('begin', alice,
    { session_id: session, state_hash: hash, verifier_ciphertext: ciphertext, return_to: 'https://web.example.test/settings' }), hash });
  const credentials = (generation, stateHash = 'a'.repeat(64)) => ({ generation, session_id: session, state_hash: stateHash,
    access_token_ciphertext: ciphertext, refresh_token_ciphertext: ciphertext,
    expires_at: new Date(Date.now() + 3600000).toISOString(),
    provider_subject: 'google-alice', provider_email: 'alice@example.test' });
  const connect = async attempt => {
    assert.ok(await call('consume', null, { state_hash: attempt.hash }));
    assert.equal(await call('connect', alice, credentials(attempt.generation, attempt.hash)), true);
  };

  await t.test('public profile payloads no longer contain token or calendar columns', async () => {
    const columns = await db.query("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='profiles'");
    assert.equal(columns.rows.some(row => /google_calendar|calendar_integration/.test(row.column_name)), false);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM private.calendar_connections')).rows[0].n, 0);
    assert.equal(JSON.stringify((await db.query('SELECT * FROM public.profiles')).rows).includes('formerly-public'), false);
  });

  await t.test('anonymous and authenticated roles cannot read private tables or execute repository helpers', async () => {
    for (const role of ['anon', 'authenticated']) {
      const grants = await db.query(`SELECT
        has_schema_privilege($1,'private','USAGE') AS schema_access,
        has_function_privilege($1,'public.calendar_admin(text,uuid,jsonb)','EXECUTE') AS rpc_access,
        has_function_privilege($1,'private.calendar_session_active(uuid,uuid)','EXECUTE') AS helper_access`, [role]);
      assert.deepEqual(grants.rows[0], { schema_access: false, rpc_access: false, helper_access: false });
      await db.exec(`SET ROLE ${role}`);
      try {
        await assert.rejects(db.query('SELECT public.calendar_admin($1,$2)', ['read', bob]), /permission denied/);
        for (const table of ['calendar_connections', 'calendar_oauth_attempts', 'calendar_revocations']) {
          await assert.rejects(db.query(`SELECT * FROM private.${table}`), /permission denied/);
        }
      } finally { await db.exec('RESET ROLE'); }
    }
  });

  await t.test('new objects enable RLS, pin elevated search paths and keep the exposed RPC as invoker', async () => {
    const tables = await db.query("SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='private' AND c.relkind='r' AND c.relname LIKE 'calendar_%'");
    assert.equal(tables.rows.length, 3);
    assert.equal(tables.rows.every(row => row.relrowsecurity), true);
    const functions = await db.query(`SELECT n.nspname,p.proname,p.prosecdef,p.proconfig FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='private' OR (n.nspname='public' AND p.proname='calendar_admin')`);
    for (const fn of functions.rows) {
      if (fn.nspname === 'public') assert.equal(fn.prosecdef, false);
      if (fn.prosecdef) assert.ok(fn.proconfig.some(value => value.startsWith('search_path=')));
    }
    const config = await readFile(new URL('../supabase/config.toml', import.meta.url), 'utf8');
    const schemas = config.match(/^schemas\s*=\s*(.+)$/m)?.[1];
    assert.ok(schemas);
    assert.equal(schemas.includes('private'), false);
  });

  await t.test('verified identities must still have a live, matching session', async () => {
    assert.equal(await call('session', alice, { session_id: session }), true);
    assert.equal(await call('session', bob, { session_id: session }), false);
    await assert.rejects(call('begin', bob, { session_id: session }), /Authentication required/);
    await db.exec(`UPDATE auth.users SET banned_until=now()+interval '1 hour' WHERE id='${alice}'`);
    assert.equal(await call('session', alice, { session_id: session }), false);
    await db.exec(`UPDATE auth.users SET banned_until=NULL WHERE id='${alice}'`);
  });

  await t.test('OAuth state is single-use, expiring, and replaced by the latest attempt', async () => {
    await begin('a'.repeat(64));
    await begin('b'.repeat(64));
    assert.equal(await call('consume', null, { state_hash: 'a'.repeat(64) }), null);
    const attempt = await call('consume', null, { state_hash: 'b'.repeat(64) });
    assert.equal(attempt.user_id, alice);
    assert.equal(attempt.session_id, session);
    assert.equal(await call('consume', null, { state_hash: 'b'.repeat(64) }), null);
    await assert.rejects(begin(), /Calendar operation pending/);
    await call('finish_callback', alice, { state_hash: 'b'.repeat(64) });
    await begin('c'.repeat(64));
    await db.exec("UPDATE private.calendar_oauth_attempts SET expires_at=now()-interval '1 second'");
    assert.equal(await call('consume', null, { state_hash: 'c'.repeat(64) }), null);
  });

  await t.test('disconnect fences callbacks and stale refresh writes', async () => {
    const first = await begin();
    await connect(first);
    const before = await call('read', alice);
    await call('disconnect', alice);
    assert.equal(await call('connect', alice, credentials(first.generation)), false);
    assert.equal(await call('refresh', alice, { ...credentials(first.generation), credential_version: before.credential_version }), false);
    assert.equal((await call('read', alice)).refresh_token_ciphertext, null);
    assert.equal(await call('pending_revocation', alice), true);
    await assert.rejects(begin(), /Revocation pending/);
  });

  await t.test('revocation leases prevent duplicate workers and only matching acknowledgements delete jobs', async () => {
    const jobs = await call('claim_revocations');
    assert.equal(jobs.length, 1);
    assert.equal((await call('claim_revocations')).length, 0);
    await call('finish_revocation', null, { id: jobs[0].id, lease_id: session, success: true });
    assert.equal(await call('pending_revocation', alice), true);
    await call('finish_revocation', null, { id: jobs[0].id, lease_id: jobs[0].lease_id, success: true });
    assert.equal(await call('pending_revocation', alice), false);
  });

  await t.test('an exchanging callback fences reconnect until cleanup is queued; failed and abandoned revocations are retried', async () => {
    const attempt = await begin();
    assert.ok(await call('consume', null, { state_hash: attempt.hash }));
    await call('disconnect', alice);
    await assert.rejects(begin(), /Calendar operation pending/);
    assert.equal(await call('connect', alice, credentials(attempt.generation)), false);
    await call('finish_callback', alice, { state_hash: attempt.hash, token_ciphertext: ciphertext });
    await assert.rejects(begin(), /Revocation pending/);
    const [first] = await call('claim_revocations');
    await call('finish_revocation', null, { id: first.id, lease_id: first.lease_id, success: false });
    assert.equal((await call('claim_revocations')).length, 0);
    const retry = await db.query('SELECT attempts, next_attempt_at > now() AS delayed FROM private.calendar_revocations');
    assert.deepEqual(retry.rows[0], { attempts: 1, delayed: true });
    await db.exec("UPDATE private.calendar_revocations SET next_attempt_at=now()-interval '1 second'");
    const [second] = await call('claim_revocations');
    await db.exec("UPDATE private.calendar_revocations SET leased_until=now()-interval '1 second'");
    const [third] = await call('claim_revocations');
    assert.notEqual(second.lease_id, third.lease_id);
    await call('finish_revocation', null, { id: second.id, lease_id: second.lease_id, success: true });
    assert.equal(await call('pending_revocation', alice), true);
    await call('finish_revocation', null, { id: third.id, lease_id: third.lease_id, success: true });
    assert.equal(await call('pending_revocation', alice), false);
  });

  await t.test('refresh uses compare-and-swap and rewrap preserves connection semantics', async () => {
    const next = await begin();
    await connect(next);
    await assert.rejects(begin(), /Calendar operation pending/);
    const before = await call('read', alice);
    const update = { ...credentials(next.generation), credential_version: before.credential_version };
    assert.equal(await call('refresh', alice, update), true);
    assert.equal(await call('refresh', alice, update), false);
    await call('invalidate', alice, update);
    assert.equal((await call('read', alice)).needs_reconnect, false);
    const current = await call('read', alice);
    assert.equal(await call('rewrap', alice, { ...update, credential_version: current.credential_version }), true);
  });

  await t.test('sign-out prevents a consumed callback from storing credentials', async () => {
    await call('disconnect', alice);
    for (const job of await call('claim_revocations')) {
      await call('finish_revocation', null, { id: job.id, lease_id: job.lease_id, success: true });
    }
    const next = await begin();
    await call('consume', null, { state_hash: next.hash });
    await db.exec(`DELETE FROM auth.sessions WHERE id='${session}'`);
    assert.equal(await call('connect', alice, credentials(next.generation)), false);
    await db.exec(`INSERT INTO auth.sessions(id,user_id) VALUES ('${session}','${alice}')`);
    await assert.rejects(begin(), /Calendar operation pending/);
    await call('finish_callback', alice, { state_hash: next.hash });
  });

  await t.test('deleting an account queues revocation instead of orphaning its Google grant', async () => {
    await connect(await begin());
    await db.exec(`DELETE FROM auth.users WHERE id='${alice}'`);
    assert.equal(await call('read', alice), null);
    assert.equal(await call('pending_revocation', alice), true);
    assert.equal((await db.query('SELECT count(*)::int AS n FROM private.calendar_oauth_attempts')).rows[0].n, 0);
  });
});
