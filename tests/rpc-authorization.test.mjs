import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const owner = '00000000-0000-4000-8000-000000000001';
const member = '00000000-0000-4000-8000-000000000002';
const unrelated = '00000000-0000-4000-8000-000000000003';
const otherOwner = '00000000-0000-4000-8000-000000000004';
const session = '00000000-0000-4000-8000-000000000005';
const missing = '00000000-0000-4000-8000-000000000099';
const selfFunctions = [
  'has_active_subscription', 'get_user_entitlement', 'count_unredeemed_passes',
  'count_active_polls', 'can_create_poll', 'get_user_participated_polls',
];
const legacyFunctions = [...selfFunctions, 'get_poll_with_summary', 'get_poll_by_code',
  'is_poll_participant', 'generate_share_code', 'generate_unique_share_code',
  'handle_new_user', 'set_poll_share_code', 'update_updated_at', 'calendar_admin'];
const deny = error => error.code === '42501';

test('F02 migration replay and direct role-based RPC authorization on Postgres', async t => {
  // PGlite runs Postgres in process, with no port, Docker, or shared database.
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
    GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
    CREATE PUBLICATION supabase_realtime;
    -- Simulate older Supabase projects' direct API-role grants as well as the
    -- normal PostgreSQL PUBLIC grant. Revoking PUBLIC alone must not pass.
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS
      TO anon, authenticated, service_role;
  `);

  let calendarBefore;
  let defaultsBefore;
  const calendarContract = async () => (await db.query(`
    SELECT n.nspname, p.proname, pg_get_functiondef(p.oid) AS definition, p.proacl::text AS acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE (n.nspname='private' AND p.proname IN ('calendar_session_active','queue_deleted_calendar_revocation'))
      OR (n.nspname='public' AND p.proname='calendar_admin')
    ORDER BY n.nspname, p.proname
  `)).rows;
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    if (name.endsWith('_privileged_rpc_authorization.sql')) {
      calendarBefore = await calendarContract();
      defaultsBefore = (await db.query('SELECT * FROM pg_default_acl')).rows;
      const legacy = (await db.query(`SELECT has_function_privilege('anon',
        'public.get_user_participated_polls(uuid)', 'EXECUTE') AS allowed`)).rows[0];
      assert.equal(legacy.allowed, true, 'test fixture must exercise legacy PUBLIC and direct grants');
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  assert.ok(calendarBefore, 'F02 migration must be replayed');

  // Supply explicit table grants, as the Data API deployment does. The migration
  // must authorize through actual RLS and cannot rely on migration-owner access.
  await db.exec(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
    TO anon, authenticated, service_role`);
  await db.query(`INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES
    ($1,'owner@example.test','{"full_name":"Owner"}'),
    ($2,'member@example.test','{"full_name":"Member"}'),
    ($3,'unrelated@example.test','{}'),($4,'other-owner@example.test','{}')`,
  [owner, member, unrelated, otherOwner]);
  await db.query('INSERT INTO auth.sessions(id,user_id) VALUES ($1,$2)', [session, owner]);

  const polls = {};
  for (const [index, status] of ['draft', 'active', 'closed', 'archived'].entries()) {
    const poll = (await db.query(`INSERT INTO public.polls(creator_id,title,status,share_code)
      VALUES ($1,$2,$3,$4) RETURNING *`, [owner, `${status} owner poll`, status, `TESTA${index}`])).rows[0];
    polls[status] = poll;
  }
  const otherPoll = (await db.query(`INSERT INTO public.polls(creator_id,title,status,share_code)
    VALUES ($1,'Other private poll','closed','OTHERX') RETURNING *`, [otherOwner])).rows[0];

  const options = {};
  const memberships = {};
  for (const poll of [...Object.values(polls), otherPoll]) {
    options[poll.id] = (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
      VALUES ($1,'2026-11-01T12:00:00Z','2026-11-01T13:00:00Z') RETURNING *`, [poll.id])).rows[0];
    memberships[poll.id] = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id)
      VALUES ($1,$2) RETURNING *`, [poll.id, poll.id === otherPoll.id ? owner : member])).rows[0];
  }
  const guest = (await db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name,anonymous_email)
    VALUES ($1,'Guest','private-guest@example.test') RETURNING *`, [polls.closed.id])).rows[0];
  await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status,note)
    VALUES ($1,$2,'available','Authorized member note'),($3,$2,'maybe','Authorized guest note'),
      ($4,$2,'unavailable','Foreign participant note'),($1,$5,'maybe','Foreign option note')`,
  [memberships[polls.closed.id].id, options[polls.closed.id].id, guest.id,
    memberships[otherPoll.id].id, options[otherPoll.id].id]);
  await db.query(`INSERT INTO public.subscriptions(user_id,entitlement,is_active,expires_at)
    VALUES ($1,'team_access',true,now()+interval '1 day'),
      ($2,'pro_access',true,now()-interval '1 day')`, [owner, member]);
  const verifiedPassSchema = (await db.query(`SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='event_passes' AND column_name='verified_until'`)).rows.length > 0;
  if (verifiedPassSchema) {
    // F08's later migration strengthens validity, while this suite must still
    // replay independently on F02's earlier schema. Seed a verified positive
    // and distinct receipt identities for every negative comparison.
    for (const kind of ['available', 'redeemed', 'revoked', 'expired']) {
      await db.query(`INSERT INTO public.event_passes
        (user_id,transaction_id,store,purchased_at,billing_project_id,billing_environment,
          revenuecat_purchase_id,product_id,store_transaction_id,purchase_unit,
          verified_until,revoked_at,redeemed_at)
        VALUES ($1,$2,'APP_STORE',now(),'proj_fixture','production',$3,'prod_pass',$4,1,
          CASE WHEN $5='expired' THEN now()-interval '1 second' ELSE now()+interval '10 minutes' END,
          CASE WHEN $5='revoked' THEN now() ELSE NULL END,
          CASE WHEN $5='redeemed' THEN now() ELSE NULL END)`,
      [owner, `rpc-fixture-${kind}`, `purch_rpc_${kind}`, `receipt_rpc_${kind}`, kind]);
    }
    await db.query(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at)
      VALUES ($1,'rpc-fixture-unverified-legacy','APP_STORE',now())`, [owner]);
  } else {
    await db.query(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,redeemed_at)
      VALUES ($1,'unredeemed-test-pass','APP_STORE',now(),NULL),
        ($1,'redeemed-test-pass','APP_STORE',now(),now())`, [owner]);
  }

  const asRole = async (role, userId, action) => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [userId ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: userId })]);
    await db.exec(`SET ROLE ${role}`);
    try { return await action(); }
    finally {
      await db.exec('RESET ROLE; RESET search_path');
      await db.query("SELECT set_config('request.jwt.claim.sub','',false)");
      await db.query("SELECT set_config('request.jwt.claims','{}',false)");
    }
  };
  const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0].result;
  const selfRead = (name, args = '', params = []) => scalar(`SELECT public.${name}(${args}) AS result`, params);

  await t.test('catalog inventory covers every legacy signature and removes effective anonymous self-service grants', async () => {
    const anonymous = new Set(['get_poll_by_code(text)', 'is_poll_participant(uuid,uuid)']);
    const authenticated = new Set([...anonymous, ...selfFunctions.map(name => `${name}(uuid)`),
      'get_poll_with_summary(uuid)', 'generate_share_code()', 'generate_unique_share_code()']);
    const inventory = (await db.query(`SELECT p.oid::regprocedure::text AS signature,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
      p.prosecdef, p.proconfig, p.prorettype='trigger'::regtype AS trigger
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
        AND p.proname=ANY($1::text[]) ORDER BY 1`, [legacyFunctions])).rows;
    // Trigger EXECUTE is inventoried separately: a trigger is not a normal RPC.
    for (const fn of inventory.filter(fn => fn.signature !== 'calendar_admin(text,uuid,jsonb)')) {
      assert.equal(fn.anon, anonymous.has(fn.signature), fn.signature);
      assert.equal(fn.authenticated, authenticated.has(fn.signature), fn.signature);
      assert.equal(fn.prosecdef, fn.signature === 'handle_new_user()', fn.signature);
      assert.ok(fn.proconfig.includes('search_path=""'), fn.signature);
    }
    assert.equal(inventory.filter(fn => fn.trigger).length, 3);
    assert.equal(inventory.length, 15);
    const publicGrants = (await db.query(`SELECT p.proname FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace,
      LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
      WHERE (n.nspname='poll_private' OR (n.nspname='public' AND p.proname=ANY($1::text[])))
        AND acl.grantee=0 AND acl.privilege_type='EXECUTE'`, [legacyFunctions])).rows;
    assert.deepEqual(publicGrants, []);
  });

  await t.test('anonymous callers cannot invoke any legacy user/summary signature, including explicit UUIDs', async () => {
    await asRole('anon', null, async () => {
      for (const name of selfFunctions) {
        await assert.rejects(selfRead(name), deny);
        await assert.rejects(selfRead(name, '$1', [owner]), deny);
        await assert.rejects(selfRead(name, 'NULL'), deny);
      }
      await assert.rejects(selfRead('get_poll_with_summary', '$1', [polls.closed.id]), deny);
    });
  });

  await t.test('every self-service RPC rejects another UUID and explicit NULL under authenticated role', async () => {
    await asRole('authenticated', unrelated, async () => {
      for (const name of selfFunctions) {
        await assert.rejects(selfRead(name, '$1', [owner]), deny);
        await assert.rejects(selfRead(name, 'NULL'), deny);
      }
    });
    for (const role of ['authenticated', 'service_role']) {
      await asRole(role, null, async () => {
        for (const name of selfFunctions) {
          await assert.rejects(selfRead(name), deny);
          await assert.rejects(selfRead(name, '$1', [owner]), deny);
        }
      });
    }
  });

  await t.test('default and explicit self calls retain subscription, pass, capacity and list result shapes', async () => {
    await asRole('authenticated', owner, async () => {
      const expected = [true, 'team_access', 1, 2, true];
      for (const [i, name] of selfFunctions.slice(0, 5).entries()) {
        assert.equal(await selfRead(name), expected[i], name);
        assert.equal(await selfRead(name, '$1', [owner]), expected[i], name);
      }
      for (const args of [[], [owner]]) {
        const result = await selfRead('get_user_participated_polls', args.length ? '$1' : '', args);
        assert.deepEqual(result.created_polls.map(poll => poll.id).sort(), Object.values(polls).map(poll => poll.id).sort());
        assert.deepEqual(result.joined_polls.map(poll => poll.id), [otherPoll.id]);
      }
    });
    await asRole('authenticated', member, async () => {
      assert.equal(await selfRead('has_active_subscription'), false);
      assert.equal(await selfRead('get_user_entitlement'), null);
      assert.equal(await selfRead('count_unredeemed_passes'), 0);
      assert.equal(await selfRead('count_active_polls'), 0);
      assert.equal(await selfRead('can_create_poll'), true);
      const result = await selfRead('get_user_participated_polls');
      assert.deepEqual(result.created_polls, []);
      assert.deepEqual(result.joined_polls.map(poll => poll.id).sort(), Object.values(polls).map(poll => poll.id).sort());
    });
    await asRole('authenticated', unrelated, async () => {
      assert.deepEqual(await selfRead('get_user_participated_polls'), { created_polls: [], joined_polls: [] });
      assert.equal(await selfRead('has_active_subscription'), false);
      assert.equal(await selfRead('get_user_entitlement'), null);
      assert.equal(await selfRead('count_unredeemed_passes'), 0);
      assert.equal(await selfRead('count_active_polls'), 0);
    });
  });

  await t.test('expired or inactive subscription access cannot bypass free creation limits', async () => {
    const original = (await db.query('SELECT expires_at,is_active FROM public.subscriptions WHERE user_id=$1', [owner])).rows[0];
    const redeemed = (await db.query(`UPDATE public.event_passes SET redeemed_at=now()
      WHERE user_id=$1 AND redeemed_at IS NULL RETURNING id`, [owner])).rows.map(row => row.id);
    try {
      await db.query('UPDATE public.subscriptions SET expires_at=now() WHERE user_id=$1', [owner]);
      await asRole('authenticated', owner, async () => {
        assert.equal(await selfRead('has_active_subscription'), false);
        assert.equal(await selfRead('get_user_entitlement'), null);
        assert.equal(await selfRead('count_unredeemed_passes'), 0);
        assert.equal(await selfRead('can_create_poll'), false);
      });
      await db.query("UPDATE public.subscriptions SET is_active=false,expires_at=now()+interval '1 day' WHERE user_id=$1", [owner]);
      await asRole('authenticated', owner, async () => {
        assert.equal(await selfRead('has_active_subscription'), false);
        assert.equal(await selfRead('get_user_entitlement'), null);
        assert.equal(await selfRead('can_create_poll'), false);
      });
    } finally {
      await db.query('UPDATE public.subscriptions SET expires_at=$1,is_active=$2 WHERE user_id=$3',
        [original.expires_at, original.is_active, owner]);
      await db.query('UPDATE public.event_passes SET redeemed_at=NULL WHERE id=ANY($1::uuid[])', [redeemed]);
    }
  });

  await t.test('owners and current members can read summaries in every poll state', async () => {
    for (const userId of [owner, member]) {
      await asRole('authenticated', userId, async () => {
        for (const poll of Object.values(polls)) {
          const result = await selfRead('get_poll_with_summary', '$1', [poll.id]);
          assert.equal(result.poll.id, poll.id);
          assert.equal(result.poll.status, poll.status);
          assert.equal(result.time_options[0].id, options[poll.id].id);
        }
      });
    }
  });

  await t.test('unrelated callers cannot read even active summaries, and missing polls have the same denial', async () => {
    await asRole('authenticated', unrelated, async () => {
      for (const pollId of [...Object.values(polls).map(poll => poll.id), missing, null]) {
        await assert.rejects(selfRead('get_poll_with_summary', '$1', [pollId]),
          error => deny(error) && error.message === 'Poll access denied');
      }
    });
    await asRole('authenticated', null, async () => {
      await assert.rejects(selfRead('get_poll_with_summary', '$1', [polls.active.id]), deny);
    });
  });

  await t.test('revoked membership immediately removes closed-poll list, preview and summary access', async () => {
    const membership = memberships[polls.archived.id];
    await db.query('DELETE FROM public.poll_participants WHERE id=$1', [membership.id]);
    try {
      await asRole('authenticated', member, async () => {
        assert.equal(await selfRead('is_poll_participant', '$1,$2', [polls.archived.id, member]), false);
        await assert.rejects(selfRead('get_poll_with_summary', '$1', [polls.archived.id]), deny);
        assert.deepEqual((await db.query('SELECT * FROM public.get_poll_by_code($1)', [polls.archived.share_code])).rows, []);
        assert.equal((await selfRead('get_user_participated_polls')).joined_polls.some(poll => poll.id === polls.archived.id), false);
      });
    } finally {
      await db.query('INSERT INTO public.poll_participants(id,poll_id,user_id) VALUES ($1,$2,$3)',
        [membership.id, polls.archived.id, member]);
    }
  });

  await t.test('authorized summary includes only same-poll responses and omits guest emails/capabilities', async () => {
    await asRole('authenticated', member, async () => {
      const result = await selfRead('get_poll_with_summary', '$1', [polls.closed.id]);
      assert.deepEqual(result.time_options[0].responses, { available: 1, maybe: 1, unavailable: 0, total: 2 });
      const payload = JSON.stringify(result);
      assert.ok(payload.includes('Authorized member note'));
      assert.ok(payload.includes('Authorized guest note'));
      // After F03 the email is stored privately and access_token is a non-secret
      // alias of the participant id, which the summary legitimately returns.
      const capability = guest.access_token === guest.id ? [] : [guest.access_token];
      for (const secret of ['Foreign participant note', 'Foreign option note', 'private-guest@example.test', ...capability]) {
        assert.equal(payload.includes(secret), false, secret);
      }
    });
  });

  await t.test('legacy and private membership helpers answer only for the current caller', async () => {
    for (const [role, userId] of [['anon', null], ['authenticated', owner],
      ['authenticated', member], ['authenticated', unrelated], ['authenticated', null]]) {
      await asRole(role, userId, async () => {
        for (const argument of [owner, member, unrelated, null]) {
          assert.equal(await selfRead('is_poll_participant', '$1,$2', [polls.closed.id, argument]),
            userId === member && argument === member);
        }
        assert.equal(await scalar('SELECT poll_private.is_poll_participant($1) AS result', [polls.closed.id]), userId === member);
        if (role === 'anon') {
          await assert.rejects(scalar('SELECT poll_private.require_self($1) AS result', [owner]), deny);
          await assert.rejects(scalar('SELECT poll_private.can_read_poll($1) AS result', [polls.closed.id]), deny);
        } else {
          assert.equal(await scalar('SELECT poll_private.can_read_poll($1) AS result', [polls.closed.id]),
            userId === owner || userId === member);
          if (userId !== owner) await assert.rejects(scalar('SELECT poll_private.require_self($1) AS result', [owner]), deny);
        }
      });
    }
  });

  await t.test('anonymous reads actually execute RLS without recursion or missing helper privileges', async () => {
    await asRole('anon', null, async () => {
      assert.deepEqual((await db.query('SELECT id FROM public.polls ORDER BY id')).rows.map(row => row.id), [polls.active.id]);
      assert.equal((await db.query('SELECT id FROM public.poll_time_options')).rows.length, 1);
      assert.equal((await db.query('SELECT id FROM public.availability_responses')).rows.length, 0);
    });
    await asRole('authenticated', member, async () => {
      assert.equal((await db.query('SELECT id FROM public.polls WHERE id=$1', [polls.closed.id])).rows.length, 1);
      assert.equal((await db.query('SELECT id FROM public.poll_time_options WHERE poll_id=$1', [polls.closed.id])).rows.length, 1);
    });
  });

  await t.test('share-code and direct private preview paths preserve active invitations with the same minimal projection', async () => {
    const columns = ['id', 'title', 'description', 'location', 'status', 'creator_id', 'created_at', 'updated_at', 'share_code'].sort();
    for (const [role, userId] of [['anon', null], ['authenticated', unrelated]]) {
      await asRole(role, userId, async () => {
        for (const schema of ['public', 'poll_private']) {
          const preview = (await db.query(`SELECT * FROM ${schema}.get_poll_by_code($1)`,
            [` ${polls.active.share_code.toLowerCase()} `])).rows;
          assert.equal(preview.length, 1);
          assert.equal(preview[0].id, polls.active.id);
          assert.deepEqual(Object.keys(preview[0]).sort(), columns);
          for (const code of [polls.closed.share_code, polls.draft.share_code, polls.archived.share_code, 'BADCODE', null]) {
            assert.deepEqual((await db.query(`SELECT * FROM ${schema}.get_poll_by_code($1)`, [code])).rows, []);
          }
        }
      });
    }
    for (const userId of [owner, member]) {
      await asRole('authenticated', userId, async () => {
        for (const poll of Object.values(polls)) {
          assert.equal((await db.query('SELECT * FROM public.get_poll_by_code($1)', [poll.share_code])).rows[0].id, poll.id);
        }
      });
    }
  });

  await t.test('private schema is not exposed and API roles can neither create helpers nor access calendar tables', async () => {
    const config = await readFile(new URL('../supabase/config.toml', import.meta.url), 'utf8');
    assert.equal(config.match(/^schemas\s*=\s*(.+)$/m)?.[1].includes('poll_private'), false);
    const helpers = (await db.query(`SELECT p.proname,p.prosecdef,p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='poll_private'
        AND p.proname IN ('require_self','is_poll_participant','can_read_poll','get_poll_by_code')`)).rows;
    // Later findings add their own helpers here; each suite inventories its own.
    assert.equal(helpers.length, 4);
    for (const helper of helpers) {
      assert.equal(helper.prosecdef, helper.proname !== 'require_self', helper.proname);
      assert.ok(helper.proconfig.includes('search_path=""'), helper.proname);
      assert.equal(helper.anon, ['get_poll_by_code', 'is_poll_participant'].includes(helper.proname), helper.proname);
      assert.equal(helper.authenticated, true, helper.proname);
    }
    for (const role of ['anon', 'authenticated']) {
      const grants = (await db.query(`SELECT has_schema_privilege($1,'poll_private','USAGE') AS usage,
        has_schema_privilege($1,'poll_private','CREATE') AS create,
        has_schema_privilege($1,'private','USAGE') AS calendar`, [role])).rows[0];
      assert.deepEqual(grants, { usage: true, create: false, calendar: false });
      await asRole(role, role === 'authenticated' ? member : null, async () => {
        await assert.rejects(db.query('CREATE TABLE poll_private.untrusted(id integer)'), deny);
        await assert.rejects(db.query('SELECT * FROM private.calendar_connections'), deny);
      });
    }
  });

  await t.test('invoker reads cannot bypass table grants and elevated helpers resist a hostile search path', async () => {
    await db.exec('REVOKE SELECT ON public.subscriptions FROM authenticated');
    try {
      await asRole('authenticated', owner, async () => {
        await assert.rejects(selfRead('has_active_subscription'), deny);
        await assert.rejects(selfRead('get_user_entitlement'), deny);
      });
    } finally { await db.exec('GRANT SELECT ON public.subscriptions TO authenticated'); }
    await db.exec(`CREATE SCHEMA hostile;
      GRANT USAGE ON SCHEMA hostile TO authenticated;
      CREATE TABLE hostile.polls (id UUID, creator_id UUID, status TEXT, share_code TEXT);
      CREATE TABLE hostile.poll_participants (poll_id UUID, user_id UUID);
      INSERT INTO hostile.poll_participants VALUES ('${otherPoll.id}','${unrelated}');
      GRANT SELECT ON ALL TABLES IN SCHEMA hostile TO authenticated;
      CREATE FUNCTION hostile.generate_share_code() RETURNS TEXT LANGUAGE sql AS $$ SELECT 'TAKENX'::text $$;`);
    await asRole('authenticated', unrelated, async () => {
      await db.exec('SET search_path = hostile, public, pg_temp');
      assert.equal(await selfRead('is_poll_participant', '$1,$2', [otherPoll.id, unrelated]), false);
      await assert.rejects(selfRead('get_poll_with_summary', '$1', [otherPoll.id]), deny);
      assert.equal((await db.query('SELECT * FROM public.get_poll_by_code($1)', [polls.active.share_code])).rows[0].id, polls.active.id);
    });
  });

  await t.test('signup, generated share codes and timestamp triggers still work after execute revocation', async () => {
    await db.query('INSERT INTO auth.users(id,email) VALUES ($1,$2)', [missing, 'new-user@example.test']);
    assert.equal((await db.query('SELECT id FROM public.profiles WHERE id=$1', [missing])).rows.length, 1);
    await asRole('authenticated', owner, async () => {
      await db.exec('SET search_path = hostile, public, pg_temp');
      const poll = (await db.query(`INSERT INTO public.polls(creator_id,title)
        VALUES ($1,'Generated invitation') RETURNING *`, [owner])).rows[0];
      assert.match(poll.share_code, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/);
      assert.notEqual(poll.share_code, 'TAKENX');
      assert.equal(typeof await selfRead('generate_share_code'), 'string');
      assert.equal(typeof await selfRead('generate_unique_share_code'), 'string');
      const updated = (await db.query(`UPDATE public.polls SET title='Updated title', updated_at='2000-01-01'
        WHERE id=$1 RETURNING updated_at`, [poll.id])).rows[0];
      assert.ok(new Date(updated.updated_at).getFullYear() > 2000);
      for (const name of ['handle_new_user', 'set_poll_share_code', 'update_updated_at']) {
        await assert.rejects(selfRead(name), deny);
      }
    });
    await asRole('anon', null, async () => {
      for (const name of ['generate_share_code', 'generate_unique_share_code', 'handle_new_user', 'set_poll_share_code', 'update_updated_at']) {
        await assert.rejects(selfRead(name), deny);
      }
    });
  });

  await t.test('calendar service-role definitions/grants and global default privileges remain unchanged', async () => {
    assert.deepEqual(await calendarContract(), calendarBefore);
    assert.deepEqual((await db.query('SELECT * FROM pg_default_acl')).rows, defaultsBefore);
    await asRole('service_role', null, async () => {
      assert.equal(await scalar("SELECT public.calendar_admin('session',$1,$2::jsonb) AS result",
        [owner, JSON.stringify({ session_id: session })]), true);
    });
    for (const role of ['anon', 'authenticated']) {
      await asRole(role, role === 'authenticated' ? owner : null, async () => {
        await assert.rejects(scalar("SELECT public.calendar_admin('session',$1,$2::jsonb) AS result",
          [owner, JSON.stringify({ session_id: session })]), deny);
      });
    }
  });
});
