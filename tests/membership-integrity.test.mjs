import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const owner = '00000000-0000-4000-8000-000000000001';
const member = '00000000-0000-4000-8000-000000000002';
const unrelated = '00000000-0000-4000-8000-000000000003';
const otherOwner = '00000000-0000-4000-8000-000000000004';
const claimant = '00000000-0000-4000-8000-000000000005';
const missing = '00000000-0000-4000-8000-000000000099';
// Duplicate membership rows and responses with explicit ids for deterministic ties.
const d1 = '10000000-0000-4000-8000-000000000001';
const d2 = '10000000-0000-4000-8000-000000000002';
const d3 = '10000000-0000-4000-8000-000000000003';
const e1 = '20000000-0000-4000-8000-000000000001';
const e2 = '20000000-0000-4000-8000-000000000002';
const r = n => `30000000-0000-4000-8000-00000000000${n}`;
const hex = fill => fill.repeat(64);
const deny = error => error.code === '42501';
const invalid = error => error.code === '22023';
const duplicate = error => error.code === '23505';
const guestDenied = error => deny(error) && error.message === 'Guest access denied';
const notJoinable = error => deny(error) && error.message === 'Poll is not accepting participants';

test('F04 membership reconciliation, uniqueness, idempotent joins and claims on Postgres', async t => {
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
    SET TIME ZONE 'UTC';
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
  `);

  const polls = {};
  const options = {};
  let responsesBefore;
  let replayed = false;
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    if (name.endsWith('_membership_integrity.sql')) {
      // Pre-F04 history allowed duplicate memberships; seed them as a legacy
      // client double-tap or multi-device join would have created them.
      await db.query(`INSERT INTO auth.users(id,email) VALUES ($1,'owner@example.test'),($2,'member@example.test'),
        ($3,'unrelated@example.test'),($4,'other@example.test'),($5,'claimant@example.test')`,
      [owner, member, unrelated, otherOwner, claimant]);
      for (const [key, status, creator] of [['active', 'active', owner], ['closed', 'closed', owner],
        ['draft', 'draft', owner], ['other', 'active', otherOwner]]) {
        polls[key] = (await db.query(`INSERT INTO public.polls(creator_id,title,status)
          VALUES ($1,$2,$3) RETURNING *`, [creator, `${key} poll`, status])).rows[0];
        options[key] = [];
        for (const hour of [12, 13, 14]) {
          options[key].push((await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
            VALUES ($1,$2,$3) RETURNING id`, [polls[key].id, `2026-11-01T${hour}:00:00Z`, `2026-11-01T${hour}:30:00Z`])).rows[0].id);
        }
      }
      const [o1, o2, o3] = options.active;
      await db.query(`INSERT INTO public.poll_participants(id,poll_id,user_id,comment,created_at,updated_at) VALUES
        ($1,$4,$5,NULL,'2026-01-01','2026-01-01'),
        ($2,$4,$5,'older comment','2026-01-02','2026-03-01'),
        ($3,$4,$5,'newest comment','2026-01-03','2026-03-05'),
        ($6,$8,$5,'survivor comment','2026-01-01','2026-04-01'),
        ($7,$8,$5,'duplicate comment','2026-01-01','2026-04-01')`,
      [d1, d2, d3, polls.active.id, member, e1, e2, polls.closed.id]);
      await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2)`, [polls.active.id, unrelated]);
      await db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name) VALUES ($1,'Twin'),($1,'Twin')`, [polls.active.id]);
      await db.query(`INSERT INTO public.availability_responses(id,participant_id,time_option_id,status,updated_at) VALUES
        ($1,$7,$10,'available','2026-02-01'),
        ($2,$8,$10,'unavailable','2026-02-05'),
        ($3,$8,$11,'maybe','2026-02-02'),
        ($4,$9,$12,'available','2026-02-03'),
        ($5,$9,$10,'maybe','2026-02-05'),
        ($6,$13,$15,'available','2026-04-01'),
        (gen_random_uuid(),$14,$15,'maybe','2026-04-01')`,
      [r(1), r(2), r(3), r(4), r(5), r(6), d1, d2, d3, o1, o2, o3, e1, e2, options.closed[0]]);
      responsesBefore = (await db.query('SELECT * FROM public.availability_responses ORDER BY id')).rows;
      replayed = true;
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  assert.ok(replayed, 'F04 migration must be replayed');

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
  const joinPoll = pollId => scalar('SELECT public.join_poll($1) AS result', [pollId]);
  const joinGuest = (pollId, name = 'Guest', token = null) =>
    scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result', [pollId, name, token]);
  const claim = (id, token) => scalar('SELECT public.claim_guest_participant($1,$2) AS result', [id, token]);
  const memberships = async (pollId, userId) => (await db.query(
    'SELECT * FROM public.poll_participants WHERE poll_id=$1 AND user_id=$2', [pollId, userId])).rows;

  await t.test('duplicate memberships merge deterministically onto one row without losing responses or comments', async () => {
    const [o1, o2, o3] = options.active;
    assert.deepEqual((await memberships(polls.active.id, member)).map(row => row.id), [d1]);
    assert.deepEqual((await memberships(polls.closed.id, member)).map(row => row.id), [e1]);
    const survivor = (await db.query('SELECT * FROM public.poll_participants WHERE id=$1', [d1])).rows[0];
    assert.equal(survivor.comment, 'newest comment');
    assert.equal(survivor.updated_at.toISOString(), new Date('2026-03-05').toISOString());
    assert.equal(survivor.access_token, d1);
    const merged = (await db.query(`SELECT id, time_option_id, status, updated_at FROM public.availability_responses
      WHERE participant_id=$1 ORDER BY time_option_id`, [d1])).rows;
    const byOption = Object.fromEntries(merged.map(row => [row.time_option_id, row]));
    assert.equal(merged.length, 3);
    // o1: two responses share the latest timestamp; neither is the survivor's, so the lowest id wins.
    assert.deepEqual([byOption[o1].id, byOption[o1].status], [r(2), 'unavailable']);
    assert.deepEqual([byOption[o2].id, byOption[o2].status], [r(3), 'maybe']);
    assert.deepEqual([byOption[o3].id, byOption[o3].status], [r(4), 'available']);
    assert.equal(byOption[o1].updated_at.toISOString(), new Date('2026-02-05').toISOString());
    // Equal created_at picks the lowest id; equal timestamps prefer the survivor's data.
    const tie = (await db.query('SELECT * FROM public.poll_participants WHERE id=$1', [e1])).rows[0];
    assert.equal(tie.comment, 'survivor comment');
    const tieResponses = (await db.query('SELECT id,status FROM public.availability_responses WHERE participant_id=$1', [e1])).rows;
    assert.deepEqual(tieResponses, [{ id: r(6), status: 'available' }]);
    // Guests have no account identity to merge on; same-name guests stay distinct.
    assert.equal((await db.query(`SELECT count(*)::int AS n FROM public.poll_participants
      WHERE poll_id=$1 AND anonymous_name='Twin'`, [polls.active.id])).rows[0].n, 2);
    assert.equal((await memberships(polls.active.id, unrelated)).length, 1);
  });

  await t.test('every pre-merge row and response is archived privately', async () => {
    const audit = (await db.query('SELECT * FROM private.participant_merge_audit ORDER BY participant_id')).rows;
    assert.deepEqual(audit.map(row => [row.participant_id, row.survivor_id, row.merge_role]), [
      [d1, d1, 'survivor'], [d2, d1, 'duplicate'], [d3, d1, 'duplicate'], [e1, e1, 'survivor'], [e2, e1, 'duplicate'],
    ]);
    const archived = new Set(audit.flatMap(row => row.responses.map(response => response.id)));
    const merged = responsesBefore.filter(row => [d1, d2, d3, e1, e2].includes(row.participant_id));
    assert.equal(merged.length, 7);
    for (const response of merged) assert.ok(archived.has(response.id), response.id);
    assert.equal(audit.find(row => row.participant_id === d3).participant.comment, 'newest comment');
    const remaining = (await db.query('SELECT id FROM public.availability_responses')).rows.map(row => row.id);
    assert.equal(remaining.length, responsesBefore.length - 3);
    for (const role of ['anon', 'authenticated']) {
      await asRole(role, role === 'anon' ? null : owner, () =>
        assert.rejects(db.query('SELECT * FROM private.participant_merge_audit'), deny));
    }
  });

  await t.test('authenticated membership is unique and joined lists contain each poll once', async () => {
    const index = (await db.query(`SELECT indexdef FROM pg_indexes WHERE schemaname='public'
      AND indexname='poll_participants_one_membership_per_user'`)).rows[0];
    assert.match(index.indexdef, /UNIQUE INDEX .* \(poll_id, user_id\) WHERE \(user_id IS NOT NULL\)/);
    assert.equal(await scalar(`SELECT count(*)::int AS result FROM (SELECT 1 FROM public.poll_participants
      WHERE user_id IS NOT NULL GROUP BY poll_id, user_id HAVING count(*) > 1) d`), 0);
    await asRole('authenticated', member, async () => {
      const joined = (await scalar('SELECT public.get_user_participated_polls() AS result')).joined_polls.map(p => p.id);
      assert.deepEqual(joined.sort(), [polls.active.id, polls.closed.id].sort());
    });
    await assert.rejects(db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2)',
      [polls.active.id, member]), duplicate);
  });

  await t.test('catalog: bound insert policies, pinned elevated commands, narrow execute grants', async () => {
    const policies = (await db.query(`SELECT policyname, roles::text AS roles, with_check FROM pg_policies
      WHERE schemaname='public' AND tablename='poll_participants' AND cmd='INSERT' ORDER BY policyname`)).rows;
    assert.deepEqual(policies.map(p => [p.policyname, p.roles]), [
      ['Guests join open polls without an account identity', '{anon}'],
      ['Members join open polls as themselves', '{authenticated}'],
    ]);
    assert.match(policies[1].with_check, /user_id = \( SELECT auth\.uid\(\)/);
    const functions = (await db.query(`SELECT n.nspname, p.proname, p.oid::regprocedure::text AS signature,
      p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
      EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
        WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE') AS public_execute
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname IN ('public','poll_private') AND p.proname IN ('join_poll','join_poll_as_guest',
        'claim_guest_participant','can_join_poll','guest_participant_for_digest','protect_participant_identity')
      ORDER BY 1,2`)).rows;
    assert.equal(functions.length, 9);
    assert.deepEqual(functions.filter(fn => fn.proname === 'join_poll_as_guest').map(fn => fn.signature),
      ['poll_private.join_poll_as_guest(uuid,text,text,text)', 'join_poll_as_guest(uuid,text,text,text)']);
    const anonCallable = new Set(['join_poll_as_guest', 'can_join_poll']);
    const authCallable = new Set(['join_poll', 'join_poll_as_guest', 'claim_guest_participant', 'can_join_poll']);
    for (const fn of functions) {
      const label = `${fn.nspname}.${fn.proname}`;
      assert.ok(fn.proconfig.includes('search_path=""'), label);
      assert.equal(fn.public_execute, false, label);
      assert.equal(fn.anon, anonCallable.has(fn.proname), label);
      assert.equal(fn.authenticated, authCallable.has(fn.proname), label);
      assert.equal(fn.prosecdef, fn.nspname === 'poll_private' && fn.proname !== 'protect_participant_identity', label);
    }
  });

  await t.test('join_poll derives identity, checks poll state, and returns the existing membership on retry', async () => {
    await asRole('anon', null, () => assert.rejects(joinPoll(polls.active.id), deny));
    await asRole('authenticated', null, () => assert.rejects(joinPoll(polls.active.id),
      error => deny(error) && error.message === 'Authentication required'));
    await asRole('authenticated', claimant, async () => {
      const first = await joinPoll(polls.active.id);
      assert.equal(first.created, true);
      assert.equal(first.participant.user_id, claimant);
      assert.equal(first.participant.access_token, first.participant.id);
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const retry = await joinPoll(polls.active.id);
        assert.deepEqual([retry.created, retry.participant.id], [false, first.participant.id]);
      }
    });
    assert.equal((await memberships(polls.active.id, claimant)).length, 1);
    await asRole('authenticated', member, async () => {
      assert.deepEqual([(await joinPoll(polls.active.id)).participant.id, (await joinPoll(polls.closed.id)).participant.id], [d1, e1]);
    });
    await asRole('authenticated', unrelated, async () => {
      for (const pollId of [polls.closed.id, polls.draft.id, missing, null]) await assert.rejects(joinPoll(pollId), notJoinable);
    });
    await db.query("UPDATE public.polls SET closes_at=now()-interval '1 minute' WHERE id=$1", [polls.other.id]);
    try {
      await asRole('authenticated', unrelated, () => assert.rejects(joinPoll(polls.other.id), notJoinable));
    } finally { await db.query('UPDATE public.polls SET closes_at=NULL WHERE id=$1', [polls.other.id]); }
    await asRole('authenticated', owner, async () => assert.equal((await joinPoll(polls.active.id)).created, true));
  });

  await t.test('a join that loses a concurrent race returns the winning membership, never a duplicate', async () => {
    // Deterministically interleave a competing join between join_poll's
    // membership check and its insert, as a second device would.
    await db.exec(`CREATE FUNCTION public.test_competing_join() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF current_setting('test.compete', true) = 'on' THEN
          PERFORM set_config('test.compete', 'off', false);
          INSERT INTO public.poll_participants(poll_id,user_id) VALUES (NEW.poll_id, NEW.user_id);
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER participants_00_test_compete BEFORE INSERT ON public.poll_participants
        FOR EACH ROW EXECUTE FUNCTION public.test_competing_join();`);
    try {
      await db.query("SELECT set_config('test.compete','on',false)");
      const result = await asRole('authenticated', unrelated, () => joinPoll(polls.other.id));
      assert.equal(result.created, false);
      const rows = await memberships(polls.other.id, unrelated);
      assert.deepEqual(rows.map(row => row.id), [result.participant.id]);
    } finally {
      await db.exec(`DROP TRIGGER participants_00_test_compete ON public.poll_participants;
        DROP FUNCTION public.test_competing_join(); SELECT set_config('test.compete','off',false);`);
    }
  });

  await t.test('direct inserts cannot name another user, duplicate a membership, or join closed polls', async () => {
    await asRole('authenticated', otherOwner, async () => {
      for (const userId of [member, unrelated, null]) {
        await assert.rejects(db.query(`INSERT INTO public.poll_participants(poll_id,user_id,anonymous_name)
          VALUES ($1,$2,'Forged')`, [polls.active.id, userId]), deny);
      }
      const own = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2) RETURNING *`,
        [polls.active.id, otherOwner])).rows[0];
      assert.equal(own.user_id, otherOwner);
      await assert.rejects(db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2)',
        [polls.active.id, otherOwner]), duplicate);
      await assert.rejects(db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2)',
        [polls.closed.id, otherOwner]), deny);
    });
    await asRole('anon', null, async () => {
      await assert.rejects(db.query(`INSERT INTO public.poll_participants(poll_id,user_id,anonymous_name)
        VALUES ($1,$2,'Forged')`, [polls.active.id, member]), deny);
      for (const name of [null, '', '   ', 'x'.repeat(101)]) {
        await assert.rejects(db.query('INSERT INTO public.poll_participants(poll_id,anonymous_name) VALUES ($1,$2)',
          [polls.active.id, name]), error => deny(error) || error.code === '23514');
      }
      await assert.rejects(db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name)
        VALUES ($1,'Late guest')`, [polls.closed.id]), deny);
      // Signed-out callers cannot read participant rows (F03), so only a
      // return=minimal legacy insert succeeds.
      await db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name)
        VALUES ($1,'Legacy web guest')`, [polls.active.id]);
    });
    assert.equal(await scalar(`SELECT user_id AS result FROM public.poll_participants
      WHERE anonymous_name='Legacy web guest'`), null);
    assert.equal((await memberships(polls.active.id, member)).length, 1);
  });

  await t.test('no role can move a membership to another poll or another user', async () => {
    await asRole('authenticated', member, async () => {
      await assert.rejects(db.query('UPDATE public.poll_participants SET poll_id=$2 WHERE id=$1', [d1, polls.other.id]), deny);
    });
    await db.exec('GRANT UPDATE ON public.poll_participants TO authenticated');
    try {
      await asRole('authenticated', member, async () => {
        await assert.rejects(db.query('UPDATE public.poll_participants SET poll_id=$2 WHERE id=$1', [d1, polls.other.id]), deny);
        await assert.rejects(db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1', [d1, unrelated]), deny);
      });
    } finally {
      await db.exec('REVOKE UPDATE ON public.poll_participants FROM authenticated; GRANT UPDATE (comment) ON public.poll_participants TO authenticated');
    }
    await asRole('service_role', null, async () => {
      await assert.rejects(db.query('UPDATE public.poll_participants SET poll_id=$2 WHERE id=$1', [d1, polls.other.id]), deny);
      await assert.rejects(db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1', [d1, unrelated]), deny);
    });
    const row = (await db.query('SELECT poll_id,user_id FROM public.poll_participants WHERE id=$1', [d1])).rows[0];
    assert.deepEqual(row, { poll_id: polls.active.id, user_id: member });
  });

  await t.test('guest joins with a client capability are idempotent and bound to one poll', async () => {
    const token = hex('a');
    await asRole('anon', null, async () => {
      const first = await joinGuest(polls.active.id, 'Retry guest', token);
      assert.deepEqual([first.created, first.guest_token], [true, token]);
      const retry = await joinGuest(polls.active.id, 'Retry guest', token);
      assert.deepEqual([retry.created, retry.participant.id], [false, first.participant.id]);
      await assert.rejects(joinGuest(polls.other.id, 'Retry guest', token), guestDenied);
      for (const bad of ['A'.repeat(64), 'a'.repeat(63), `${token} `, 'not-hex']) {
        await assert.rejects(joinGuest(polls.active.id, 'Guest', bad), invalid);
      }
      const server = [await joinGuest(polls.active.id, 'Server token'), await joinGuest(polls.active.id, 'Server token')];
      assert.notEqual(server[0].participant.id, server[1].participant.id);
      assert.match(server[0].guest_token, /^[0-9a-f]{64}$/);
    });
    assert.equal(await scalar(`SELECT count(*)::int AS result FROM public.poll_participants
      WHERE anonymous_name='Retry guest'`), 1);
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1", [polls.active.id]);
    try {
      await asRole('anon', null, async () => {
        assert.equal((await joinGuest(polls.active.id, 'Retry guest', token)).created, false);
        await assert.rejects(joinGuest(polls.active.id, 'New guest', hex('b')), notJoinable);
      });
    } finally { await db.query("UPDATE public.polls SET status='active' WHERE id=$1", [polls.active.id]); }
  });

  await t.test('a guest row can be claimed only with its capability, once, by a non-member', async () => {
    const guest = await asRole('anon', null, () => joinGuest(polls.other.id, 'Claimable', hex('c')));
    const otherGuest = await asRole('anon', null, () => joinGuest(polls.other.id, 'Other guest', hex('d')));
    const id = guest.participant.id;
    await asRole('anon', null, () => assert.rejects(claim(id, hex('c')), deny));
    await asRole('authenticated', claimant, async () => {
      for (const token of [null, hex('e'), hex('d'), id, 'C'.repeat(64)]) {
        await assert.rejects(claim(id, token), guestDenied, String(token));
      }
      await assert.rejects(db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1', [id, claimant]), deny);
    });
    assert.equal((await db.query('SELECT user_id FROM public.poll_participants WHERE id=$1', [id])).rows[0].user_id, null);

    // The unrelated user already belongs to this poll (race test above).
    await asRole('authenticated', unrelated, () => assert.rejects(claim(otherGuest.participant.id, hex('d')), duplicate));
    assert.equal((await scalar('SELECT public.get_guest_participant($1,$2) AS result', [otherGuest.participant.id, hex('d')]))
      .participant.user_id, null, 'a rejected claim leaves the capability valid');

    const claimed = await asRole('authenticated', claimant, () => claim(id, hex('c')));
    assert.equal(claimed.participant.id, id);
    assert.equal(claimed.participant.user_id, claimant);
    assert.equal(claimed.participant.anonymous_name, 'Claimable');
    await asRole('authenticated', claimant, async () => {
      assert.deepEqual((await joinPoll(polls.other.id)).participant.id, id);
      await assert.rejects(claim(id, hex('c')), guestDenied);
    });
    await asRole('anon', null, async () => {
      await assert.rejects(scalar('SELECT public.get_guest_participant($1,$2) AS result', [id, hex('c')]), guestDenied);
      // The consumed capability cannot mint a new guest row either.
      await assert.rejects(joinGuest(polls.other.id, 'Claimable', hex('c')), guestDenied);
      for (const fn of ['update_guest_participant($1,$2,$3,NULL)', 'rotate_guest_token($1,$2)']) {
        const args = fn.startsWith('update') ? [id, hex('c'), 'Renamed'] : [id, hex('c')];
        await assert.rejects(scalar(`SELECT public.${fn} AS result`, args), guestDenied);
      }
    });
  });
});
