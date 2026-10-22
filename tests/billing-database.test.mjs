import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const alice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const bob = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const missing = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const poll = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const legacy = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const project = { project_id: 'proj_test', environment: 'production' };
const date = delta => new Date(Date.now() + delta).toISOString();
const event = (id, customers = [alice], extra = {}) => ({ id, type: 'RENEWAL', event_timestamp_ms: Date.now(),
  customer_ids: customers, disposition: 'pending', reason: null, ...extra });
const entitlement = (name = 'pro_access', extra = {}) => ({ resource_id: `subscriptions/${name}`,
  entitlement: name, product_id: 'prod_subscription', store: 'APP_STORE', transaction_id: 'subscription-transaction',
  purchased_at: date(-3600000), expires_at: date(3600000), valid_until: date(600000), ...extra });
const pass = (extra = {}) => ({ purchase_id: 'purch_test', product_id: 'prod_pass', store: 'APP_STORE',
  transaction_id: 'store-receipt', purchased_at: date(-3600000), quantity: 1, ...extra });
const snapshot = (entitlements = [entitlement()], passes = []) => ({ environment: 'production', fetched_at: date(0),
  valid_until: date(900000), entitlements, passes });

test('billing migration, privileges, transactional recovery and fencing on Postgres', async t => {
  const db = new PGlite();
  t.after(() => db.close());
  await db.exec(`
    CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id UUID PRIMARY KEY,email TEXT,raw_user_meta_data JSONB DEFAULT '{}',deleted_at TIMESTAMPTZ,banned_until TIMESTAMPTZ);
    CREATE TABLE auth.sessions(id UUID PRIMARY KEY,user_id UUID REFERENCES auth.users ON DELETE CASCADE,not_after TIMESTAMPTZ);
    CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    CREATE FUNCTION auth.jwt() RETURNS JSONB LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
    GRANT USAGE ON SCHEMA auth TO anon,authenticated,service_role;
    CREATE PUBLICATION supabase_realtime;
  `);
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(n => n.endsWith('.sql')).sort()) {
    if (name.includes('durable_billing_webhooks')) {
      await db.exec(`
        INSERT INTO auth.users(id,email) VALUES('${alice}','alice@example.test'),('${bob}','bob@example.test');
        INSERT INTO public.polls(id,creator_id,title) VALUES('${poll}','${alice}','Previously redeemed');
        INSERT INTO public.subscriptions(user_id,is_active,entitlement) VALUES('${alice}',true,'team_access');
        INSERT INTO public.event_passes(id,user_id,transaction_id,store,purchased_at,redeemed_at,poll_id)
          VALUES('${legacy}','${alice}','old-receipt','APP_STORE',now(),now(),'${poll}');
      `);
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  // Model standard API/table grants explicitly, rather than accidentally testing
  // as the owner. RLS and function grants remain the authorization boundary.
  await db.exec('GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon,authenticated; GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role');
  const call = async (action, data = {}) => {
    await db.exec('SET ROLE service_role');
    try { return (await db.query('SELECT public.billing_admin($1,$2) AS result', [action, JSON.stringify(data)])).rows[0].result; }
    finally { await db.exec('RESET ROLE'); }
  };
  const accept = value => call('accept', { ...project, event: value });
  const claim = () => call('claim', project);
  const complete = (job, value = snapshot()) => call('complete', { ...job, snapshot: value });
  const fail = (job, code = 'provider_unavailable', quarantine = false) => call('fail', { ...job, code, quarantine, retry_after: 60 });
  const one = async sql => (await db.query(sql)).rows[0];
  const reset = async () => db.exec(`DELETE FROM private.billing_inbox_targets; DELETE FROM private.billing_inbox;
    DELETE FROM private.billing_customers; DELETE FROM private.billing_entitlements; DELETE FROM public.event_passes;
    DELETE FROM public.subscriptions;`);
  const due = () => db.exec("UPDATE private.billing_customers SET next_attempt_at=now()-interval '1 second'");

  await t.test('legacy purchases fail closed, remain replayable, and retain spent IDs/poll links after verified adoption', async () => {
    assert.equal((await one('SELECT is_active FROM public.subscriptions')).is_active, false);
    const old = await one('SELECT id,revoked_at,poll_id,redeemed_at FROM public.event_passes');
    assert.equal(old.id, legacy); assert.equal(old.poll_id, poll); assert.ok(old.revoked_at); assert.ok(old.redeemed_at);
    const job = await claim();
    await assert.rejects(complete(job, snapshot([entitlement()], [pass()])), /legacy_pass_unmapped/);
    await fail(job, 'legacy_pass_unmapped', true);
    assert.equal(await claim(), null);
    assert.equal(await call('adopt_legacy_pass', { pass_id: legacy, product_id: 'prod_pass', store: 'APP_STORE',
      transaction_id: 'store-receipt', purchase_id: 'purch_test' }), true);
    await call('queue_customer', { customer_id: alice });
    assert.equal(await complete(await claim(), snapshot([entitlement()], [pass()])), 'applied');
    const imported = await one('SELECT id,poll_id,redeemed_at,revoked_at FROM public.event_passes');
    assert.equal(imported.id, legacy); assert.equal(imported.poll_id, poll); assert.ok(imported.redeemed_at); assert.equal(imported.revoked_at, null);
    assert.equal((await one('SELECT count(*)::int AS n FROM public.event_passes')).n, 1);
  });
  await reset();

  await t.test('private tables/RPCs are unavailable to clients, use RLS, and all billing functions pin invoker search paths', async () => {
    const tables = await db.query("SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='private' AND c.relname LIKE 'billing_%' AND c.relkind='r'");
    assert.equal(tables.rows.length, 6); assert.ok(tables.rows.every(r => r.relrowsecurity));
    const functions = await db.query("SELECT prosecdef,proconfig FROM pg_proc WHERE proname LIKE 'billing_%'");
    assert.ok(functions.rows.every(f => !f.prosecdef && f.proconfig.includes('search_path=""')));
    for (const role of ['anon', 'authenticated']) {
      assert.equal((await db.query("SELECT has_function_privilege($1,'public.billing_admin(text,jsonb)','EXECUTE') AS allowed", [role])).rows[0].allowed, false);
      await db.exec(`SET ROLE ${role}`);
      try {
        await assert.rejects(db.query("SELECT public.billing_admin('claim','{}')"), /permission denied/);
        await assert.rejects(db.query('SELECT * FROM private.billing_inbox'), /permission denied/);
        await assert.rejects(db.query(`SELECT private.billing_effective_entitlement('${alice}')`), /permission denied/);
      } finally { await db.exec('RESET ROLE'); }
    }
  });

  await t.test('acceptance is durable, duplicates do not requeue, conflicting IDs and environment changes fail atomically', async () => {
    const value = event('durable');
    await accept(value);
    const before = await one('SELECT revision FROM private.billing_customers');
    assert.equal((await accept(value)).duplicate, true);
    assert.deepEqual(await one('SELECT revision FROM private.billing_customers'), before);
    await assert.rejects(accept({ ...value, type: 'EXPIRATION' }), /event_conflict/);
    await assert.rejects(call('accept', { ...project, environment: 'sandbox', event: event('wrong-env') }), /billing_configuration_mismatch/);
    assert.equal((await one('SELECT count(*)::int AS n FROM private.billing_inbox')).n, 1);
    assert.equal((await one('SELECT status FROM private.billing_inbox')).status, 'pending');
  });
  await reset();

  await t.test('new events invalidate in-flight snapshots and expired/replaced leases cannot commit or acknowledge targets', async () => {
    await accept(event('first'));
    assert.equal(await complete({ customer_id: alice }), 'stale');
    const first = await claim();
    assert.equal(await claim(), null);
    await accept(event('newer'));
    assert.equal(await complete(first), 'stale');
    assert.equal((await one('SELECT count(*)::int AS n FROM public.subscriptions')).n, 0);
    const second = await claim();
    await db.exec("UPDATE private.billing_customers SET leased_until=now()-interval '1 second'");
    assert.equal(await complete(second), 'stale');
    const replacement = await claim();
    assert.notEqual(second.lease_id, replacement.lease_id);
    assert.equal(await complete(second), 'stale');
    assert.equal(await fail(second), false);
    assert.equal((await one("SELECT count(*)::int AS n FROM private.billing_inbox WHERE status='processed'")).n, 0);
    assert.equal(await complete(replacement), 'applied');
    assert.equal((await one("SELECT count(*)::int AS n FROM private.billing_inbox WHERE status='processed'")).n, 2);
  });
  await reset();

  await t.test('an old expiration delivered after renewal cannot revoke a current canonical entitlement', async () => {
    await accept(event('renewed'));
    await complete(await claim());
    await accept(event('late-expiration', [alice], { type: 'EXPIRATION', event_timestamp_ms: 1000 }));
    await complete(await claim()); // Both reads see the provider's current renewed state.
    const current = await one('SELECT is_active,entitlement,expires_at<=now()+interval \'15 minutes\' AS bounded FROM public.subscriptions');
    assert.deepEqual(current, { is_active: true, entitlement: 'pro_access', bounded: true });
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='late-expiration'")).status, 'processed');
  });
  await reset();

  await t.test('environment and stale snapshot rejection leaves outputs and completion untouched; store identities do not collide', async () => {
    await accept(event('environment'));
    const job = await claim();
    await assert.rejects(complete(job, { ...snapshot(), environment: 'sandbox' }), /invalid_snapshot/);
    await assert.rejects(complete(job, { ...snapshot(), fetched_at: date(-3600000) }), /invalid_snapshot/);
    assert.equal((await one('SELECT count(*)::int AS n FROM public.subscriptions')).n, 0);
    assert.equal((await one('SELECT status FROM private.billing_inbox')).status, 'pending');
    await complete(job, snapshot([], [pass(), pass({ purchase_id: 'purch_play', store: 'PLAY_STORE' })]));
    assert.equal((await one('SELECT count(*)::int AS n FROM public.event_passes')).n, 2);
  });
  await reset();

  await t.test('a pass write failure rolls back subscription and receipt writes; accepted work replays exactly once after recovery', async () => {
    await accept(event('pass-failure'));
    await db.exec(`CREATE FUNCTION public.test_pass_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected storage failure'; END $$;
      CREATE TRIGGER test_pass_failure BEFORE INSERT ON public.event_passes FOR EACH ROW EXECUTE FUNCTION public.test_pass_failure();`);
    const job = await claim();
    await assert.rejects(complete(job, snapshot([entitlement()], [pass()])), /injected storage failure/);
    assert.equal((await one('SELECT count(*)::int AS n FROM private.billing_entitlements')).n, 0);
    assert.equal((await one('SELECT status FROM private.billing_inbox')).status, 'pending');
    await fail(job, 'database_unavailable');
    assert.equal(await claim(), null);
    await db.exec('DROP TRIGGER test_pass_failure ON public.event_passes; DROP FUNCTION public.test_pass_failure()');
    await call('replay_event', { event_id: 'pass-failure' });
    assert.equal(await complete(await claim(), snapshot([entitlement()], [pass()])), 'applied');
    await call('replay_event', { event_id: 'pass-failure' });
    assert.equal(await complete(await claim(), snapshot([entitlement()], [pass()])), 'applied');
    assert.equal((await one('SELECT count(*)::int AS n FROM public.event_passes')).n, 1);
  });
  await reset();

  await t.test('missing profiles retry after signup and anonymous identities quarantine durably instead of losing purchases', async () => {
    await accept(event('before-signup', [missing]));
    const job = await claim();
    await assert.rejects(complete(job), /missing_profile/);
    await fail(job, 'missing_profile');
    await db.exec(`INSERT INTO auth.users(id,email) VALUES('${missing}','late@example.test')`);
    await call('replay_event', { event_id: 'before-signup' });
    assert.equal(await complete(await claim()), 'applied');
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='before-signup'")).status, 'processed');
    await accept(event('anonymous', ['$RCAnonymousID:test']));
    const anonymous = await claim();
    await fail(anonymous, 'unknown_identity', true);
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='anonymous'")).status, 'quarantined');
    assert.equal(await claim(), null);
    await call('resolve_identity', { provider_customer_id: '$RCAnonymousID:test', user_id: alice, verification_reference: 'verified-test-evidence' });
    assert.equal(await complete(await claim(), snapshot([], [pass()])), 'applied');
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='anonymous'")).status, 'processed');
    assert.equal((await one(`SELECT count(*)::int AS n FROM public.event_passes WHERE user_id='${alice}'`)).n, 1);
    const audit = await one('SELECT provider_customer_id,user_id,verification_reference,verified_at FROM private.billing_identity_links');
    assert.equal(audit.provider_customer_id, '$RCAnonymousID:test'); assert.equal(audit.user_id, alice);
    assert.equal(audit.verification_reference, 'verified-test-evidence'); assert.ok(audit.verified_at);
    await call('resolve_identity', { provider_customer_id: '$RCAnonymousID:test', user_id: alice, verification_reference: 'repeat-review' });
    await call('replay_event', { event_id: 'anonymous' });
    assert.equal(await complete(await claim(), snapshot([], [pass()])), 'applied');
    assert.deepEqual(await one('SELECT provider_customer_id,user_id,verification_reference,verified_at FROM private.billing_identity_links'), audit);
    assert.equal((await one("SELECT event->'customer_ids' AS ids FROM private.billing_inbox WHERE event_id='anonymous'")).ids[0], '$RCAnonymousID:test');
    await assert.rejects(call('resolve_identity', { provider_customer_id: '$RCAnonymousID:test', user_id: bob, verification_reference: 'wrong' }), /identity_conflict/);
    await assert.rejects(call('resolve_identity', { provider_customer_id: bob, user_id: alice, verification_reference: 'wrong' }), /identity_conflict/);
  });
  await reset();

  await t.test('unknown/test events never activate; an operator can explicitly replay an unknown event as reconciliation', async () => {
    await accept(event('unknown', [alice], { type: 'NEW_PROVIDER_EVENT', disposition: 'quarantined', reason: 'unknown_event_type' }));
    await accept(event('test', [alice], { type: 'TEST', disposition: 'ignored' }));
    assert.equal(await claim(), null);
    await call('replay_event', { event_id: 'unknown' });
    assert.equal(await complete(await claim(), snapshot([])), 'applied');
    assert.equal((await one('SELECT is_active FROM public.subscriptions')).is_active, false);
    await assert.rejects(call('replay_event', { event_id: 'test' }), /ignored_event/);
  });
  await reset();

  await t.test('case-sensitive RevenueCat UUID spellings share one fenced Supabase account job', async () => {
    await accept(event('lower'));
    const old = await claim();
    await accept(event('upper', [alice.toUpperCase()]));
    assert.equal(await complete(old), 'stale');
    const next = await claim();
    assert.deepEqual(next.provider_customer_ids.sort(), [alice, alice.toUpperCase()].sort());
    assert.equal(next.customer_id, alice);
    assert.equal((await one('SELECT count(*)::int AS n FROM private.billing_customers')).n, 1);
    await complete(next);
  });
  await reset();

  await t.test('refund/transfer/quantity reconciliation preserves spent units and completes all affected event targets', async () => {
    await accept(event('purchase'));
    await complete(await claim(), snapshot([], [pass({ quantity: 2 })]));
    const spent = await one('SELECT id FROM public.event_passes ORDER BY purchase_unit LIMIT 1');
    await db.exec(`UPDATE public.event_passes SET redeemed_at=now(),poll_id='${poll}' WHERE id='${spent.id}'`);
    await accept(event('transfer', [alice, bob], { type: 'TRANSFER' }));
    const source = await claim();
    assert.equal(source.customer_id, alice);
    await complete(source, snapshot([]));
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='transfer'")).status, 'pending');
    await complete(await claim(), snapshot([], [pass({ quantity: 2 })]));
    assert.equal((await one("SELECT status FROM private.billing_inbox WHERE event_id='transfer'")).status, 'processed');
    assert.equal((await one('SELECT count(*)::int AS n FROM public.event_passes')).n, 2);
    const retained = await one(`SELECT user_id,redeemed_at,poll_id FROM public.event_passes WHERE id='${spent.id}'`);
    assert.equal(retained.user_id, bob); assert.ok(retained.redeemed_at); assert.equal(retained.poll_id, poll);
    await accept(event('refund', [bob], { type: 'CANCELLATION' }));
    await complete(await claim(), snapshot([]));
    assert.equal((await one('SELECT count(*)::int AS n FROM public.event_passes WHERE revoked_at IS NULL')).n, 0);
  });
  await reset();

  await t.test('all entitlement grants are retained; team precedence, natural expiry and freshness horizons are enforced', async () => {
    await accept(event('both'));
    await complete(await claim(), snapshot([entitlement(), entitlement('team_access')], [pass()]));
    assert.equal((await one('SELECT entitlement,billing_contract_version FROM public.subscriptions')).entitlement, 'team_access');
    assert.equal((await one('SELECT billing_contract_version FROM public.subscriptions')).billing_contract_version, 1);
    await db.exec("UPDATE private.billing_entitlements SET valid_until=now()-interval '1 second' WHERE entitlement='team_access'");
    assert.equal((await one(`SELECT private.billing_effective_entitlement('${alice}') AS tier`)).tier, 'pro_access');
    await db.exec("UPDATE private.billing_entitlements SET valid_until=now()-interval '1 second'; UPDATE public.subscriptions SET expires_at=now()-interval '1 second'; UPDATE public.event_passes SET verified_until=now()-interval '1 second'");
    assert.equal((await one(`SELECT private.billing_effective_entitlement('${alice}') AS tier`)).tier, null);
    await db.exec(`SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${alice}',false)`);
    try {
      assert.equal((await one(`SELECT public.has_active_subscription('${alice}') AS active`)).active, false);
      assert.equal((await one(`SELECT public.get_user_entitlement('${alice}') AS tier`)).tier, null);
    } finally { await db.exec("RESET ROLE; SELECT set_config('request.jwt.claim.sub','',false)"); }
    await due();
    assert.ok(await claim()); // Scheduled reconciliation works without a new webhook.
  });

  await t.test('authenticated pass counts reject other accounts and exclude expired, revoked, legacy and spent rows', async () => {
    await db.exec(`UPDATE public.event_passes SET verified_until=now()+interval '5 minutes'`);
    const read = async (userId, supplied = userId) => {
      await db.exec(`SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${userId ?? ''}',false)`);
      try { return (await db.query('SELECT public.count_unredeemed_passes($1) AS n', [supplied])).rows[0].n; }
      finally { await db.exec("RESET ROLE; SELECT set_config('request.jwt.claim.sub','',false)"); }
    };
    assert.equal(await read(alice), 1);
    await assert.rejects(read(alice, bob), /Authentication required/);
    await assert.rejects(read(alice, null), /Authentication required/);
    await assert.rejects(read(null, alice), /Authentication required/);
    await db.exec('UPDATE public.event_passes SET revoked_at=now()');
    assert.equal(await read(alice), 0);
    await db.exec("UPDATE public.event_passes SET verified_until=now()+interval '5 minutes',redeemed_at=now()");
    assert.equal(await read(alice), 0);
    await db.exec(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at) VALUES('${alice}','unmatched-legacy-fixture','APP_STORE',now())`);
    assert.equal(await read(alice), 0);
    await db.exec("UPDATE public.event_passes SET revoked_at=NULL,verified_until=now()-interval '1 second'");
    assert.equal(await read(alice), 0);
    await db.exec('SET ROLE anon');
    try { await assert.rejects(db.query('SELECT public.count_unredeemed_passes()'), /permission denied/); }
    finally { await db.exec('RESET ROLE'); }
    await db.exec('SET ROLE service_role');
    try { await assert.rejects(db.query(`SELECT public.count_unredeemed_passes('${alice}')`), /Authentication required|permission denied/); }
    finally { await db.exec('RESET ROLE'); }
  });
});
