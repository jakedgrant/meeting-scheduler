import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const owner = '00000000-0000-4000-8000-000000000001';
const member = '00000000-0000-4000-8000-000000000002';
const unrelated = '00000000-0000-4000-8000-000000000003';
const otherOwner = '00000000-0000-4000-8000-000000000004';
const missing = '00000000-0000-4000-8000-000000000099';
const legacyToken = '11111111-1111-4111-8111-111111111111';
const legacyEmail = 'legacy-guest@example.test';
const deny = error => error.code === '42501';
const invalid = error => error.code === '22023';
const guestDenied = error => deny(error) && error.message === 'Guest access denied';
const notJoinable = error => deny(error) && error.message === 'Poll is not accepting participants';
const identityDenied = error => deny(error) && /identity fields|permission denied/.test(error.message);

test('F03 participant access, guest capabilities and identity protection on Postgres', async t => {
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
    -- Model Supabase's default API grants at table/function creation time, so
    -- the migration's narrower table privileges are what the API roles get.
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
  `);

  // Replay history, seeding pre-F03 rows (including a published guest token and
  // email) immediately before the participant-access migration.
  const polls = {};
  const memberships = {};
  let legacyGuest;
  let legacyUpdatedAt;
  const directory = new URL('../supabase/migrations/', import.meta.url);
  let replayed = false;
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    if (name.endsWith('_participant_access.sql')) {
      await db.query(`INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES
        ($1,'owner@example.test','{"full_name":"Owner"}'),($2,'member@example.test','{"full_name":"Member"}'),
        ($3,'unrelated@example.test','{}'),($4,'other-owner@example.test','{}')`, [owner, member, unrelated, otherOwner]);
      for (const [index, status] of ['draft', 'active', 'closed', 'archived'].entries()) {
        polls[status] = (await db.query(`INSERT INTO public.polls(creator_id,title,status,share_code)
          VALUES ($1,$2,$3,$4) RETURNING *`, [owner, `${status} poll`, status, `PART${index}X`])).rows[0];
        memberships[status] = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id)
          VALUES ($1,$2) RETURNING *`, [polls[status].id, member])).rows[0];
        await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
          VALUES ($1,'2026-11-01T12:00:00Z','2026-11-01T13:00:00Z')`, [polls[status].id]);
      }
      polls.other = (await db.query(`INSERT INTO public.polls(creator_id,title,status,share_code)
        VALUES ($1,'Other active poll','active','PARTOX') RETURNING *`, [otherOwner])).rows[0];
      legacyGuest = (await db.query(`INSERT INTO public.poll_participants
        (poll_id,anonymous_name,anonymous_email,access_token,comment,updated_at)
        VALUES ($1,'Legacy guest',$2,$3,'Legacy comment','2026-01-01T00:00:00Z') RETURNING *`,
      [polls.closed.id, legacyEmail, legacyToken])).rows[0];
      legacyUpdatedAt = legacyGuest.updated_at;
      assert.equal(legacyGuest.access_token, legacyToken, 'fixture must publish a pre-F03 token');
      replayed = true;
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  assert.ok(replayed, 'F03 migration must be replayed');

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
  const join = (pollId, name = 'Guest', email = null) =>
    scalar('SELECT public.join_poll_as_guest($1,$2,$3) AS result', [pollId, name, email]);
  const getGuest = (id, token) => scalar('SELECT public.get_guest_participant($1,$2) AS result', [id, token]);
  const updateGuest = (id, token, name, comment) =>
    scalar('SELECT public.update_guest_participant($1,$2,$3,$4) AS result', [id, token, name, comment]);
  const rotate = (id, token) => scalar('SELECT public.rotate_guest_token($1,$2) AS result', [id, token]);
  const visible = async (pollId = null) => (await db.query(`SELECT * FROM public.poll_participants
    WHERE $1::uuid IS NULL OR poll_id=$1 ORDER BY id`, [pollId])).rows;
  const callers = [['anon', null], ['authenticated', unrelated], ['authenticated', owner],
    ['authenticated', member], ['authenticated', otherOwner]];

  // A guest with a valid capability, joined through the new command.
  const joined = await asRole('anon', null, () => join(polls.active.id, '  Active guest  ', 'guest@example.test'));
  const guest = joined.participant;
  const guestToken = joined.guest_token;
  const second = await asRole('anon', null, () => join(polls.active.id, 'Second guest'));

  await t.test('migration removes published tokens and emails while keeping rows and timestamps', async () => {
    const rows = (await db.query('SELECT * FROM public.poll_participants')).rows;
    assert.ok(rows.length >= 7);
    for (const row of rows) {
      assert.equal(row.access_token, row.id);
      assert.equal(row.anonymous_email, null);
    }
    const legacy = rows.find(row => row.id === legacyGuest.id);
    assert.equal(legacy.anonymous_name, 'Legacy guest');
    assert.equal(legacy.comment, 'Legacy comment');
    assert.equal(legacy.updated_at.toISOString(), legacyUpdatedAt.toISOString());
    assert.equal(JSON.stringify(rows).includes(legacyToken), false);
    assert.equal(JSON.stringify(rows).includes(legacyEmail), false);
    const stored = (await db.query('SELECT * FROM private.participant_guest_credentials WHERE participant_id=$1',
      [legacyGuest.id])).rows[0];
    assert.equal(stored.contact_email, legacyEmail);
    assert.equal(stored.token_hash, null, 'a disclosed legacy token must not become a capability');
    const column = (await db.query(`SELECT column_default, is_nullable FROM information_schema.columns
      WHERE table_schema='public' AND table_name='poll_participants' AND column_name='access_token'`)).rows[0];
    assert.deepEqual(column, { column_default: null, is_nullable: 'NO' });
  });

  await t.test('catalog: no permissive participant policies, narrow grants, private storage, pinned helpers', async () => {
    const policies = (await db.query(`SELECT policyname, cmd, roles::text, qual, with_check FROM pg_policies
      WHERE schemaname='public' AND tablename='poll_participants' ORDER BY policyname`)).rows;
    assert.deepEqual(policies.map(p => [p.policyname, p.cmd]), [
      ['Anyone can join active polls', 'INSERT'],
      ['Members can update their own participant record', 'UPDATE'],
      ['Participants are visible through invitation or membership', 'SELECT'],
    ]);
    for (const policy of policies) {
      assert.notEqual(policy.qual, 'true');
      assert.equal(/user_id IS NULL/i.test(`${policy.qual} ${policy.with_check}`), false, policy.policyname);
    }
    const privileges = (await db.query(`SELECT
      has_table_privilege('anon','public.poll_participants','UPDATE') AS anon_update,
      has_table_privilege('authenticated','public.poll_participants','UPDATE') AS auth_table_update,
      has_column_privilege('authenticated','public.poll_participants','comment','UPDATE') AS auth_comment,
      has_column_privilege('anon','public.poll_participants','comment','UPDATE') AS anon_comment,
      has_table_privilege('anon','public.poll_participants','SELECT') AS anon_select,
      has_table_privilege('authenticated','public.poll_participants','SELECT') AS auth_select`)).rows[0];
    assert.deepEqual(privileges, { anon_update: false, auth_table_update: false, auth_comment: true,
      anon_comment: false, anon_select: true, auth_select: true });
    for (const column of ['id', 'poll_id', 'user_id', 'anonymous_name', 'anonymous_email', 'access_token', 'created_at']) {
      const result = await scalar(`SELECT has_column_privilege('authenticated','public.poll_participants',$1,'UPDATE') AS result`, [column]);
      assert.equal(result, false, column);
    }
    for (const role of ['anon', 'authenticated']) {
      assert.equal(await scalar("SELECT has_schema_privilege($1,'private','USAGE') AS result", [role]), false);
      await asRole(role, role === 'anon' ? null : member, async () => {
        await assert.rejects(db.query('SELECT * FROM private.participant_guest_credentials'), deny);
      });
    }
    const helpers = (await db.query(`SELECT n.nspname, p.proname, p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
      EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
        WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE') AS public_execute
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE (n.nspname='poll_private' AND p.proname IN ('protect_participant_identity','store_participant_contact',
        'can_view_participants','new_guest_token','guest_token_hash','verified_guest_participant',
        'join_poll_as_guest','get_guest_participant','update_guest_participant','rotate_guest_token'))
        OR (n.nspname='public' AND p.proname IN ('join_poll_as_guest','get_guest_participant',
        'update_guest_participant','rotate_guest_token'))
      ORDER BY 1,2`)).rows;
    assert.equal(helpers.length, 14);
    const callable = new Set(['can_view_participants', 'join_poll_as_guest', 'get_guest_participant',
      'update_guest_participant', 'rotate_guest_token']);
    const elevated = new Set(['store_participant_contact', 'can_view_participants', 'verified_guest_participant',
      'join_poll_as_guest', 'get_guest_participant', 'update_guest_participant', 'rotate_guest_token']);
    for (const fn of helpers) {
      const label = `${fn.nspname}.${fn.proname}`;
      assert.ok(fn.proconfig.includes('search_path=""'), label);
      assert.equal(fn.public_execute, false, label);
      assert.equal(fn.anon, callable.has(fn.proname), label);
      assert.equal(fn.authenticated, callable.has(fn.proname), label);
      assert.equal(fn.prosecdef, fn.nspname === 'poll_private' && elevated.has(fn.proname), label);
    }
  });

  await t.test('anonymous and unrelated callers see only active-invitation participants, never closed-poll lists', async () => {
    for (const [role, userId] of [['anon', null], ['authenticated', unrelated]]) {
      await asRole(role, userId, async () => {
        const rows = await visible();
        assert.deepEqual([...new Set(rows.map(row => row.poll_id))], [polls.active.id]);
        for (const status of ['draft', 'closed', 'archived']) {
          assert.deepEqual(await visible(polls[status].id), [], status);
          assert.deepEqual((await db.query('SELECT id FROM public.poll_participants WHERE id=$1',
            [memberships[status].id])).rows, [], status);
        }
        assert.deepEqual((await db.query('SELECT id FROM public.poll_participants WHERE id=$1', [legacyGuest.id])).rows, []);
        // The existing summary RPC remains owner/member only.
        if (role === 'authenticated') {
          await assert.rejects(scalar('SELECT public.get_poll_with_summary($1) AS result', [polls.closed.id]), deny);
        }
      });
    }
  });

  await t.test('owners and members read their polls in every state; members see no other closed polls', async () => {
    await asRole('authenticated', owner, async () => {
      for (const status of ['draft', 'active', 'closed', 'archived']) {
        assert.ok((await visible(polls[status].id)).some(row => row.id === memberships[status].id), status);
      }
      assert.ok((await visible(polls.closed.id)).some(row => row.id === legacyGuest.id));
      const summary = await scalar('SELECT public.get_poll_with_summary($1) AS result', [polls.closed.id]);
      assert.ok(summary.participants.some(p => p.display_name === 'Legacy guest'));
    });
    await asRole('authenticated', member, async () => {
      for (const status of ['draft', 'active', 'closed', 'archived']) {
        assert.ok((await visible(polls[status].id)).length >= 1, status);
      }
    });
    await asRole('authenticated', otherOwner, async () => {
      assert.deepEqual(await visible(polls.closed.id), []);
      assert.deepEqual(await visible(polls.draft.id), []);
    });
  });

  await t.test('no caller can read guest emails or capabilities from rows, embeds, or summaries', async () => {
    for (const [role, userId] of callers) {
      await asRole(role, userId, async () => {
        const payload = JSON.stringify(await visible());
        for (const secret of [guestToken, second.guest_token, legacyToken, legacyEmail, 'guest@example.test']) {
          assert.equal(payload.includes(secret), false, `${role}:${userId}:${secret}`);
        }
        for (const row of await visible()) assert.equal(row.access_token, row.id);
      });
    }
    await asRole('authenticated', owner, async () => {
      const payload = JSON.stringify(await scalar('SELECT public.get_poll_with_summary($1) AS result', [polls.active.id]));
      assert.ok(payload.includes('Active guest'));
      assert.equal(payload.includes(guestToken), false);
      assert.equal(payload.includes('guest@example.test'), false);
    });
    const stored = (await db.query('SELECT * FROM private.participant_guest_credentials WHERE participant_id=$1', [guest.id])).rows[0];
    assert.equal(stored.contact_email, 'guest@example.test');
    assert.equal(stored.token_hash.length, 32);
    assert.equal(Buffer.from(stored.token_hash).toString('hex').includes(guestToken), false);
  });

  await t.test('guest join returns one private capability and a safe row; invalid joins fail closed', async () => {
    assert.match(guestToken, /^[0-9a-f]{64}$/);
    assert.notEqual(guestToken, second.guest_token);
    assert.equal(guest.anonymous_name, 'Active guest');
    assert.equal(guest.user_id, null);
    assert.equal(guest.anonymous_email, null);
    assert.equal(guest.access_token, guest.id);
    assert.equal(guest.poll_id, polls.active.id);
    await asRole('anon', null, async () => {
      for (const pollId of [polls.draft.id, polls.closed.id, polls.archived.id, missing, null]) {
        await assert.rejects(join(pollId), notJoinable);
      }
      for (const name of ['', '   ', null, 'x'.repeat(101)]) await assert.rejects(join(polls.active.id, name), invalid);
      for (const email of ['not-an-email', `${'x'.repeat(320)}@example.test`]) {
        await assert.rejects(join(polls.active.id, 'Guest', email), invalid);
      }
    });
    await db.query("UPDATE public.polls SET closes_at=now()-interval '1 minute' WHERE id=$1", [polls.other.id]);
    try {
      await asRole('anon', null, () => assert.rejects(join(polls.other.id), notJoinable));
    } finally { await db.query('UPDATE public.polls SET closes_at=NULL WHERE id=$1', [polls.other.id]); }
    await asRole('authenticated', unrelated, () => assert.rejects(join(polls.active.id),
      error => deny(error) && /join as members/.test(error.message)));
  });

  await t.test('a valid capability reads and edits only its own allowed fields', async () => {
    await asRole('anon', null, async () => {
      const read = await getGuest(guest.id, guestToken);
      assert.equal(read.participant.id, guest.id);
      assert.deepEqual(read.poll, { id: polls.active.id, status: 'active', closes_at: null });
      const updated = await updateGuest(guest.id, guestToken, ' Renamed guest ', 'Guest comment');
      assert.equal(updated.anonymous_name, 'Renamed guest');
      assert.equal(updated.comment, 'Guest comment');
      for (const field of ['id', 'poll_id', 'user_id', 'access_token', 'created_at']) {
        assert.equal(JSON.stringify(updated[field]), JSON.stringify(read.participant[field]), field);
      }
      assert.equal((await updateGuest(guest.id, guestToken, 'Renamed guest', null)).comment, null);
      await assert.rejects(updateGuest(guest.id, guestToken, '', 'x'), invalid);
      await assert.rejects(updateGuest(guest.id, guestToken, 'Guest', 'x'.repeat(501)), invalid);
    });
    // An authenticated device that holds the capability may use it too.
    await asRole('authenticated', unrelated, async () => {
      assert.equal((await getGuest(guest.id, guestToken)).participant.id, guest.id);
    });
  });

  await t.test('invalid, swapped, legacy, and rotated capabilities are rejected without side effects', async () => {
    const before = (await db.query('SELECT * FROM public.poll_participants WHERE id=ANY($1::uuid[]) ORDER BY id',
      [[guest.id, second.participant.id, legacyGuest.id]])).rows;
    for (const [role, userId] of callers) {
      await asRole(role, userId, async () => {
        const attempts = [
          [guest.id, second.guest_token], [second.participant.id, guestToken], [guest.id, '0'.repeat(64)],
          [guest.id, guestToken.toUpperCase()], [guest.id, `${guestToken} `], [guest.id, guest.id], [guest.id, null],
          [legacyGuest.id, legacyToken], [legacyGuest.id, legacyGuest.id], [memberships.active.id, guestToken],
          [missing, guestToken], [null, guestToken],
        ];
        for (const [id, token] of attempts) {
          await assert.rejects(getGuest(id, token), guestDenied, `${id}:${token}`);
          await assert.rejects(updateGuest(id, token, 'Hijacked', 'Hijacked'), guestDenied, `${id}:${token}`);
          await assert.rejects(rotate(id, token), guestDenied, `${id}:${token}`);
        }
      });
    }
    const after = (await db.query('SELECT * FROM public.poll_participants WHERE id=ANY($1::uuid[]) ORDER BY id',
      [[guest.id, second.participant.id, legacyGuest.id]])).rows;
    assert.deepEqual(after, before);

    const rotated = await asRole('anon', null, () => rotate(second.participant.id, second.guest_token));
    assert.match(rotated, /^[0-9a-f]{64}$/);
    await asRole('anon', null, async () => {
      await assert.rejects(getGuest(second.participant.id, second.guest_token), guestDenied);
      assert.equal((await getGuest(second.participant.id, rotated)).participant.id, second.participant.id);
    });
    second.guest_token = rotated;
  });

  await t.test('guest capability reads a closed poll row but cannot edit it after closing', async () => {
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1", [polls.active.id]);
    try {
      await asRole('anon', null, async () => {
        assert.equal((await getGuest(guest.id, guestToken)).poll.status, 'closed');
        await assert.rejects(updateGuest(guest.id, guestToken, 'Late', 'Late'),
          error => deny(error) && error.message === 'Poll is not accepting changes');
        assert.deepEqual(await visible(polls.active.id), []);
      });
    } finally { await db.query("UPDATE public.polls SET status='active' WHERE id=$1", [polls.active.id]); }
  });

  await t.test('takeover of guest rows through the Data API is impossible for anon and unrelated users', async () => {
    const before = (await db.query('SELECT * FROM public.poll_participants WHERE id=ANY($1::uuid[]) ORDER BY id',
      [[guest.id, legacyGuest.id]])).rows;
    await asRole('anon', null, async () => {
      for (const id of [guest.id, legacyGuest.id]) {
        await assert.rejects(db.query('UPDATE public.poll_participants SET comment=$2 WHERE id=$1', [id, 'x']), deny);
        await assert.rejects(db.query('UPDATE public.poll_participants SET anonymous_name=$2 WHERE id=$1', [id, 'x']), deny);
      }
    });
    await asRole('authenticated', unrelated, async () => {
      for (const id of [guest.id, legacyGuest.id]) {
        await assert.rejects(db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1', [id, unrelated]), deny);
        await assert.rejects(db.query('UPDATE public.poll_participants SET anonymous_name=$2 WHERE id=$1', [id, 'x']), deny);
        assert.equal((await db.query('UPDATE public.poll_participants SET comment=$2 WHERE id=$1 RETURNING id',
          [id, 'claimed'])).rows.length, 0);
        assert.equal((await db.query('DELETE FROM public.poll_participants WHERE id=$1 RETURNING id', [id])).rows.length, 0);
      }
    });
    const after = (await db.query('SELECT * FROM public.poll_participants WHERE id=ANY($1::uuid[]) ORDER BY id',
      [[guest.id, legacyGuest.id]])).rows;
    assert.deepEqual(after, before);
  });

  await t.test('identity, poll, and capability columns stay protected even if broad API grants are reapplied', async () => {
    const own = memberships.active;
    const changes = [['poll_id', polls.other.id], ['user_id', unrelated], ['user_id', null], ['id', missing],
      ['access_token', missing], ['anonymous_name', 'Alias'], ['anonymous_email', 'x@example.test'],
      ['created_at', '2000-01-01T00:00:00Z']];
    const attempt = async () => {
      for (const [column, value] of changes) {
        await assert.rejects(db.query(`UPDATE public.poll_participants SET ${column}=$2 WHERE id=$1`, [own.id, value]),
          identityDenied, column);
      }
    };
    await asRole('authenticated', member, attempt);
    // Older projects and the shared suites re-grant full table privileges; the
    // trigger is the backstop for identity fields when that happens.
    await db.exec('GRANT UPDATE ON public.poll_participants TO anon, authenticated');
    try {
      await asRole('authenticated', member, attempt);
      await asRole('authenticated', unrelated, async () => {
        assert.equal((await db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1 RETURNING id',
          [guest.id, unrelated])).rows.length, 0);
      });
      await asRole('anon', null, async () => {
        assert.equal((await db.query('UPDATE public.poll_participants SET anonymous_name=$2 WHERE id=$1 RETURNING id',
          [guest.id, 'Hijacked'])).rows.length, 0);
      });
    } finally {
      await db.exec(`REVOKE UPDATE ON public.poll_participants FROM anon, authenticated;
        GRANT UPDATE (comment) ON public.poll_participants TO authenticated`);
    }
    const row = (await db.query('SELECT * FROM public.poll_participants WHERE id=$1', [own.id])).rows[0];
    assert.equal(row.poll_id, own.poll_id);
    assert.equal(row.user_id, member);
    // Elevated/back-office writes are normalized too: access_token cannot hold a secret.
    await asRole('service_role', null, async () => {
      const updated = (await db.query(`UPDATE public.poll_participants SET access_token=$2, anonymous_email='ops@example.test'
        WHERE id=$1 RETURNING access_token, anonymous_email`, [own.id, missing])).rows[0];
      assert.deepEqual(updated, { access_token: own.id, anonymous_email: null });
    });
  });

  await t.test('legitimate member edits and legacy shared-link joins still work', async () => {
    await asRole('authenticated', member, async () => {
      const updated = (await db.query(`UPDATE public.poll_participants SET comment='Member comment'
        WHERE id=$1 RETURNING *`, [memberships.closed.id])).rows;
      assert.equal(updated.length, 1);
      assert.equal(updated[0].comment, 'Member comment');
      assert.equal((await db.query(`UPDATE public.poll_participants SET comment='x' WHERE id=$1 RETURNING id`,
        [guest.id])).rows.length, 0, 'members cannot edit another participant');
    });
    // Installed web guest join: direct insert with RETURNING, as PostgREST issues it.
    await asRole('anon', null, async () => {
      const row = (await db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name,anonymous_email,access_token,created_at)
        VALUES ($1,'Legacy web guest','web-guest@example.test',$2,'2000-01-01') RETURNING *`, [polls.active.id, legacyToken])).rows[0];
      assert.equal(row.access_token, row.id);
      assert.equal(row.anonymous_email, null);
      assert.ok(new Date(row.created_at).getFullYear() > 2000);
      await assert.rejects(db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name)
        VALUES ($1,'Closed guest')`, [polls.closed.id]), deny);
      // Such guests have no capability and cannot be edited by anyone.
      await assert.rejects(getGuest(row.id, row.access_token), guestDenied);
    });
    assert.equal(await scalar(`SELECT contact_email AS result FROM private.participant_guest_credentials c
      JOIN public.poll_participants pp ON pp.id=c.participant_id WHERE pp.anonymous_name='Legacy web guest'`), 'web-guest@example.test');
    await asRole('authenticated', unrelated, async () => {
      const row = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2) RETURNING *`,
        [polls.active.id, unrelated])).rows[0];
      assert.equal(row.access_token, row.id);
      assert.equal((await db.query(`UPDATE public.poll_participants SET comment='Joined' WHERE id=$1 RETURNING id`,
        [row.id])).rows.length, 1);
      assert.ok((await db.query('SELECT id FROM public.poll_participants WHERE poll_id=$1', [polls.active.id])).rows
        .some(r => r.id === row.id));
    });
    // Deleting a participant also removes its private capability and contact.
    await db.query('DELETE FROM public.poll_participants WHERE id=$1', [second.participant.id]);
    assert.equal(await scalar('SELECT count(*)::int AS result FROM private.participant_guest_credentials WHERE participant_id=$1',
      [second.participant.id]), 0);
  });

  await t.test('elevated guest commands resist a hostile search path', async () => {
    await db.exec(`CREATE SCHEMA hostile_f03;
      GRANT USAGE ON SCHEMA hostile_f03 TO anon;
      CREATE TABLE hostile_f03.poll_participants (LIKE public.poll_participants);
      CREATE TABLE hostile_f03.polls (LIKE public.polls);
      GRANT ALL ON ALL TABLES IN SCHEMA hostile_f03 TO anon;
      CREATE FUNCTION hostile_f03.sha256(bytea) RETURNS bytea LANGUAGE sql AS $$ SELECT '\\x00'::bytea $$;
      GRANT EXECUTE ON FUNCTION hostile_f03.sha256(bytea) TO anon;`);
    await asRole('anon', null, async () => {
      await db.exec('SET search_path = hostile_f03, public, pg_temp');
      const result = await join(polls.active.id, 'Search path guest');
      assert.equal((await getGuest(result.participant.id, result.guest_token)).participant.anonymous_name, 'Search path guest');
      await assert.rejects(getGuest(guest.id, '0'.repeat(64)), guestDenied);
    });
    assert.equal(await scalar('SELECT count(*)::int AS result FROM hostile_f03.poll_participants'), 0);
  });
});
