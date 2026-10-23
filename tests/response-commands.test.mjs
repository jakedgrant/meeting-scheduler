import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const owner = '00000000-0000-4000-8000-000000000001';
const member = '00000000-0000-4000-8000-000000000002';
const leaver = '00000000-0000-4000-8000-000000000003';
const unrelated = '00000000-0000-4000-8000-000000000004';
const otherOwner = '00000000-0000-4000-8000-000000000005';
const missing = '00000000-0000-4000-8000-000000000099';
const hex = fill => fill.repeat(64);
const deny = error => error.code === '42501';
const invalid = error => error.code === '22023';
const denied = message => error => deny(error) && error.message === message;
const notOpen = denied('Poll is not accepting responses');
const crossPoll = error => error.code === '23514';

test('F06/F10 response invariants, transactional saves and finalization on Postgres', async t => {
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
  const members = {};
  let legacyCross;
  let replayed = false;
  const addPoll = async (key, creator, status, closesAt = null) => {
    polls[key] = (await db.query(`INSERT INTO public.polls(creator_id,title,status,closes_at)
      VALUES ($1,$2,$3,$4) RETURNING *`, [creator, `${key} poll`, status, closesAt])).rows[0];
    options[key] = (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time) VALUES
      ($1,'2026-11-01T12:00:00.123Z','2026-11-01T13:00:00.456Z'),
      ($1,'2026-11-02T12:00:00Z','2026-11-02T13:00:00Z'),
      ($1,'2026-11-03T12:00:00Z','2026-11-03T13:00:00Z') RETURNING id`, [polls[key].id])).rows
      .map(row => row.id).sort();
  };
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    if (name.endsWith('_response_commands.sql')) {
      await db.query(`INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES
        ($1,'owner@example.test','{}'),($2,'member@example.test','{"full_name":"Member"}'),
        ($3,'leaver@example.test','{}'),($4,'unrelated@example.test','{}'),($5,'other@example.test','{}')`,
      [owner, member, leaver, unrelated, otherOwner]);
      await addPoll('open', owner, 'active');
      await addPoll('other', otherOwner, 'active');
      await addPoll('closed', owner, 'closed');
      await addPoll('expired', owner, 'active', '2026-01-01T00:00:00Z');
      await addPoll('draft', owner, 'draft');
      for (const key of ['open', 'closed', 'expired', 'other']) {
        members[key] = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2) RETURNING *`,
          [polls[key].id, member])).rows[0];
      }
      members.leaver = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2) RETURNING *`,
        [polls.open.id, leaver])).rows[0];
      // Pre-F06 data: a response whose time option belongs to another poll.
      legacyCross = (await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status,note)
        VALUES ($1,$2,'available','Cross-poll note') RETURNING *`, [members.open.id, options.other[0]])).rows[0];
      await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
        VALUES ($1,$2,'maybe')`, [members.closed.id, options.closed[0]]);
      replayed = true;
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  assert.ok(replayed, 'F06/F10 migration must be replayed');

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
  const save = (pollId, responses, comment = null, extra = {}) => scalar(
    'SELECT public.save_availability($1,$2,$3,$4,$5,$6,$7) AS result',
    [pollId, extra.requestId ?? randomUUID(), JSON.stringify(responses), comment,
      extra.expectedVersion ?? null, extra.participant ?? null, extra.token ?? null]);
  const getAvailability = (pollId, extra = {}) => scalar('SELECT public.get_availability($1,$2,$3) AS result',
    [pollId, extra.participant ?? null, extra.token ?? null]);
  const finalize = (pollId, optionId) => scalar('SELECT public.finalize_poll($1,$2) AS result', [pollId, optionId]);
  const stored = async participantId => (await db.query(`SELECT time_option_id, status, note FROM public.availability_responses
    WHERE participant_id=$1 ORDER BY time_option_id`, [participantId])).rows;
  const r = (option, status, note = null) => ({ time_option_id: option, status, note });
  // A save result without its per-call fields equals the stored availability.
  const persisted = ({ saved_at, replayed, ...rest }) => rest;
  const guest = await asRole('anon', null, () => scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',
    [polls.open.id, 'Guest', hex('a')]));
  const otherGuest = await asRole('anon', null, () => scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',
    [polls.other.id, 'Other guest', hex('b')]));

  await t.test('existing cross-poll responses are quarantined, not deleted silently', async () => {
    assert.equal(await scalar('SELECT count(*)::int AS result FROM public.availability_responses WHERE id=$1', [legacyCross.id]), 0);
    const quarantined = (await db.query('SELECT reason, response FROM private.response_invariant_quarantine')).rows;
    assert.equal(quarantined.length, 1);
    assert.equal(quarantined[0].response.id, legacyCross.id);
    assert.equal(quarantined[0].response.note, 'Cross-poll note');
    assert.equal(await scalar(`SELECT count(*)::int AS result FROM public.availability_responses ar
      JOIN public.poll_participants pp ON pp.id=ar.participant_id JOIN public.poll_time_options pto ON pto.id=ar.time_option_id
      WHERE pp.poll_id<>pto.poll_id`), 0);
  });

  await t.test('catalog: response policies, write grants, private state, pinned commands', async () => {
    const policies = (await db.query(`SELECT policyname, cmd, roles::text AS roles FROM pg_policies
      WHERE schemaname='public' AND tablename='availability_responses' ORDER BY policyname`)).rows;
    assert.deepEqual(policies.map(p => [p.policyname, p.cmd, p.roles]), [
      ['Members delete their own responses', 'DELETE', '{authenticated}'],
      ['Members insert their own responses', 'INSERT', '{authenticated}'],
      ['Members update their own responses', 'UPDATE', '{authenticated}'],
      ['Responses are visible to the poll owner and members', 'SELECT', '{authenticated}'],
    ]);
    for (const privilege of ['INSERT', 'UPDATE', 'DELETE']) {
      assert.equal(await scalar(`SELECT has_table_privilege('anon','public.availability_responses',$1) AS result`, [privilege]), false);
    }
    for (const table of ['response_invariant_quarantine', 'participant_response_state', 'response_save_requests']) {
      for (const role of ['anon', 'authenticated']) {
        await asRole(role, role === 'anon' ? null : owner, () =>
          assert.rejects(db.query(`SELECT * FROM private.${table}`), deny));
      }
    }
    const fns = (await db.query(`SELECT n.nspname, p.proname, p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
      EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
        WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE') AS public_execute
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname IN ('public','poll_private') AND p.proname IN ('save_availability','get_availability',
        'finalize_poll','availability_result','resolve_availability_participant','check_response_write',
        'bump_response_version','normalize_selected_time','lock_open_poll','response_poll')
      ORDER BY 1,2`)).rows;
    assert.equal(fns.length, 13);
    const anonCallable = new Set(['save_availability', 'get_availability']);
    const authCallable = new Set(['save_availability', 'get_availability', 'finalize_poll', 'lock_open_poll', 'response_poll']);
    for (const fn of fns) {
      const label = `${fn.nspname}.${fn.proname}`;
      assert.ok(fn.proconfig.includes('search_path=""'), label);
      assert.equal(fn.public_execute, false, label);
      assert.equal(fn.anon, anonCallable.has(fn.proname), label);
      assert.equal(fn.authenticated, authCallable.has(fn.proname), label);
      assert.equal(fn.prosecdef, fn.nspname === 'poll_private' && fn.proname !== 'check_response_write', label);
    }
    assert.equal(await scalar(`SELECT convalidated AS result FROM pg_constraint WHERE conname='poll_selected_time_pair'`), true);
  });

  await t.test('response reads are limited to the poll owner, members, and verified guests', async () => {
    await asRole('authenticated', member, () => db.query(`INSERT INTO public.availability_responses
      (participant_id,time_option_id,status) VALUES ($1,$2,'available')`, [members.open.id, options.open[0]]));
    for (const [role, userId] of [['anon', null], ['authenticated', unrelated], ['authenticated', otherOwner]]) {
      await asRole(role, userId, async () => {
        const rows = (await db.query(`SELECT ar.id FROM public.availability_responses ar
          JOIN public.poll_time_options pto ON pto.id=ar.time_option_id WHERE pto.poll_id=$1`, [polls.open.id])).rows;
        assert.deepEqual(rows, [], `${role}:${userId}`);
      });
    }
    for (const userId of [owner, member, leaver]) {
      await asRole('authenticated', userId, async () => {
        assert.equal((await db.query('SELECT id FROM public.availability_responses WHERE participant_id=$1',
          [members.open.id])).rows.length, 1, userId);
      });
    }
    await asRole('anon', null, async () => {
      const detail = await scalar('SELECT public.get_guest_poll_detail($1,$2) AS result', [guest.participant.id, hex('a')]);
      assert.equal(detail.responses.length, 1);
    });
  });

  await t.test('direct writes cannot cross polls, change identity, or touch closed and expired polls', async () => {
    await asRole('authenticated', member, async () => {
      await assert.rejects(db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
        VALUES ($1,$2,'maybe')`, [members.open.id, options.other[0]]), crossPoll);
      await assert.rejects(db.query(`UPDATE public.availability_responses SET time_option_id=$2 WHERE participant_id=$1`,
        [members.open.id, options.open[1]]), deny);
      for (const key of ['closed', 'expired']) {
        const [option] = options[key];
        await assert.rejects(db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
          VALUES ($1,$2,'maybe')`, [members[key].id, option]), notOpen, key);
      }
      await assert.rejects(db.query(`UPDATE public.availability_responses SET status='available' WHERE participant_id=$1`,
        [members.closed.id]), notOpen);
      await assert.rejects(db.query('DELETE FROM public.availability_responses WHERE participant_id=$1',
        [members.closed.id]), notOpen);
      // Installed clients' upsert still works on an open poll and returns its row.
      const upserted = (await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status,note)
        VALUES ($1,$2,'maybe','Legacy upsert') ON CONFLICT (participant_id,time_option_id)
        DO UPDATE SET participant_id=EXCLUDED.participant_id, time_option_id=EXCLUDED.time_option_id,
          status=EXCLUDED.status, note=EXCLUDED.note RETURNING *`, [members.open.id, options.open[0]])).rows;
      assert.deepEqual([upserted.length, upserted[0].status], [1, 'maybe']);
      assert.equal((await db.query('UPDATE public.poll_time_options SET poll_id=$2 WHERE id=$1 RETURNING id',
        [options.open[0], polls.other.id])).rows.length, 0, 'members cannot edit options');
    });
    // Even the owner cannot move an option to another of their polls.
    await asRole('authenticated', owner, () => assert.rejects(db.query(
      'UPDATE public.poll_time_options SET poll_id=$2 WHERE id=$1', [options.open[0], polls.draft.id]), deny));
    await asRole('service_role', null, () => assert.rejects(db.query(`INSERT INTO public.availability_responses
      (participant_id,time_option_id,status) VALUES ($1,$2,'maybe')`, [members.open.id, options.other[0]]), crossPoll));
    await asRole('authenticated', unrelated, async () => {
      await assert.rejects(db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
        VALUES ($1,$2,'unavailable')`, [members.open.id, options.open[1]]), deny);
      assert.equal((await db.query(`UPDATE public.availability_responses SET status='unavailable'
        WHERE participant_id=$1 RETURNING id`, [members.open.id])).rows.length, 0);
      assert.equal((await db.query('DELETE FROM public.availability_responses WHERE participant_id=$1 RETURNING id',
        [members.open.id])).rows.length, 0);
    });
    await asRole('anon', null, () => assert.rejects(db.query(`INSERT INTO public.availability_responses
      (participant_id,time_option_id,status) VALUES ($1,$2,'available')`, [guest.participant.id, options.open[0]]), deny));
    assert.deepEqual(await stored(members.closed.id), [{ time_option_id: options.closed[0], status: 'maybe', note: null }]);
  });

  await t.test('a member save replaces the whole set and comment atomically with a persisted version', async () => {
    const [o1, o2, o3] = options.open;
    await asRole('authenticated', member, async () => {
      const first = await save(polls.open.id, [r(o1, 'available', 'Morning'), r(o2, 'maybe')], 'First comment');
      assert.equal(first.replayed, false);
      assert.equal(first.participant_id, members.open.id);
      assert.equal(first.comment, 'First comment');
      assert.deepEqual(first.responses.map(x => [x.time_option_id, x.status, x.note]),
        [[o1, 'available', 'Morning'], [o2, 'maybe', null]]);
      assert.ok(first.version > 0);
      const keptId = first.responses[0].id;
      const second = await save(polls.open.id, [r(o3, 'unavailable'), r(o1, 'maybe')], null);
      assert.deepEqual(second.responses.map(x => [x.time_option_id, x.status]), [[o1, 'maybe'], [o3, 'unavailable']]);
      assert.equal(second.responses[0].id, keptId, 'an updated response keeps its id');
      assert.equal(second.comment, null);
      assert.ok(second.version > first.version);
      const noop = await save(polls.open.id, [r(o1, 'maybe'), r(o3, 'unavailable')], null);
      assert.equal(noop.version, second.version, 'an unchanged save keeps the version');
      assert.deepEqual(await getAvailability(polls.open.id), persisted(second));
    });
    assert.deepEqual(await stored(members.open.id), [r(o1, 'maybe'), r(o3, 'unavailable')]);
  });

  await t.test('retries return the original result; reusing a request id with other data is rejected', async () => {
    const [o1, o2] = options.open;
    const requestId = randomUUID();
    await asRole('authenticated', member, async () => {
      const original = await save(polls.open.id, [r(o2, 'available')], 'Retry me', { requestId });
      const changed = await save(polls.open.id, [r(o1, 'unavailable')], 'Later save');
      const retry = await save(polls.open.id, [r(o2, 'available')], 'Retry me', { requestId });
      assert.equal(retry.replayed, true);
      assert.deepEqual({ ...retry, replayed: false }, original);
      assert.deepEqual((await getAvailability(polls.open.id)).responses.map(x => x.time_option_id), [o1],
        'a late retry does not overwrite the newer save');
      assert.ok(changed.version > original.version);
      await assert.rejects(save(polls.open.id, [r(o2, 'maybe')], 'Retry me', { requestId }),
        error => invalid(error) && /different payload/.test(error.message));
    });
  });

  await t.test('invalid payloads fail with 22023 and leave nothing partially saved', async () => {
    const [o1] = options.open;
    await asRole('authenticated', member, async () => {
      const before = await getAvailability(polls.open.id);
      const bad = [
        [{ not: 'an array' }], [[{ time_option_id: 'nope', status: 'available' }]],
        [[{ time_option_id: o1, status: 'yes' }]], [[{ time_option_id: o1 }]],
        [[r(o1, 'available'), r(o1.toUpperCase(), 'maybe')]],
        [[r(o1, 'available'), r(options.other[0], 'maybe')]],
        [[r(o1, 'available', 'x'.repeat(501))]], [[{ time_option_id: o1, status: 'maybe', note: 7 }]],
        [[r(o1, 'available')], 'x'.repeat(501)],
      ];
      for (const [responses, comment] of bad) {
        await assert.rejects(scalar('SELECT public.save_availability($1,$2,$3,$4) AS result',
          [polls.open.id, randomUUID(), JSON.stringify(responses), comment ?? 'changed']), invalid, JSON.stringify(responses).slice(0, 60));
      }
      await assert.rejects(scalar('SELECT public.save_availability($1,NULL,$2,NULL) AS result',
        [polls.open.id, '[]']), invalid);
      assert.deepEqual(await getAvailability(polls.open.id), before);
    });
  });

  await t.test('optimistic concurrency: a stale expected_version is a PT409 conflict', async () => {
    const [o1] = options.open;
    await asRole('authenticated', member, async () => {
      const current = await getAvailability(polls.open.id);
      await assert.rejects(save(polls.open.id, [r(o1, 'available')], null, { expectedVersion: current.version - 1 }),
        error => error.code === 'PT409' && error.detail === `current_version=${current.version}`);
      const ok = await save(polls.open.id, [r(o1, 'available')], null, { expectedVersion: current.version });
      assert.ok(ok.version > current.version);
    });
    // Direct legacy writes advance the same version.
    const before = await asRole('authenticated', member, () => getAvailability(polls.open.id));
    await asRole('authenticated', member, () => db.query(`UPDATE public.poll_participants SET comment='Direct' WHERE id=$1`,
      [members.open.id]));
    assert.ok((await asRole('authenticated', member, () => getAvailability(polls.open.id))).version > before.version);
  });

  await t.test('callers are identified by session or capability and cannot save for others', async () => {
    const [o1] = options.open;
    await asRole('anon', null, () => assert.rejects(save(polls.open.id, [r(o1, 'maybe')]), denied('Authentication required')));
    await asRole('authenticated', unrelated, async () => {
      await assert.rejects(save(polls.open.id, [r(o1, 'maybe')]), denied('Poll access denied'));
      await assert.rejects(save(missing, []), denied('Poll access denied'));
      await assert.rejects(getAvailability(polls.open.id), denied('Poll access denied'));
    });
    await asRole('authenticated', member, () => assert.rejects(save(polls.open.id, [r(o1, 'maybe')], null,
      { participant: members.leaver.id }), denied('Poll access denied')));
    await asRole('authenticated', otherOwner, () => assert.rejects(finalize(polls.open.id, o1), denied('Poll access denied')));
  });

  await t.test('a verified guest saves availability and comment through its capability only', async () => {
    const [o1, o2] = options.open;
    const id = guest.participant.id;
    await asRole('anon', null, async () => {
      const saved = await save(polls.open.id, [r(o1, 'available', 'Guest note'), r(o2, 'unavailable')], 'Guest comment',
        { participant: id, token: hex('a') });
      assert.equal(saved.participant_id, id);
      assert.equal(saved.comment, 'Guest comment');
      assert.equal(saved.responses.length, 2);
      assert.deepEqual(await getAvailability(polls.open.id, { participant: id, token: hex('a') }), persisted(saved));
      for (const [participant, token, pollId] of [[id, hex('c'), polls.open.id], [id, hex('b'), polls.open.id],
        [otherGuest.participant.id, hex('a'), polls.open.id], [id, hex('a'), polls.other.id],
        [otherGuest.participant.id, hex('b'), polls.open.id], [id, 'A'.repeat(64), polls.open.id]]) {
        await assert.rejects(save(pollId, [r(o1, 'maybe')], null, { participant, token }), denied('Guest access denied'));
      }
      const detail = await scalar('SELECT public.get_guest_poll_detail($1,$2) AS result', [id, hex('a')]);
      assert.ok(detail.responses.some(x => x.participant_id === id && x.note === 'Guest note'));
    });
    // A signed-in device holding the capability may also use it.
    await asRole('authenticated', unrelated, async () => {
      assert.equal((await save(polls.open.id, [r(o1, 'maybe')], 'Guest comment', { participant: id, token: hex('a') }))
        .participant_id, id);
    });
  });

  await t.test('closing serializes with saves: a retry of a committed save replays, new saves are rejected', async () => {
    const [o1, o2] = options.open;
    const requestId = randomUUID();
    const committed = await asRole('authenticated', member, () => save(polls.open.id, [r(o2, 'maybe')], 'Before close', { requestId }));
    await asRole('authenticated', owner, () => db.query(`UPDATE public.polls SET status='closed' WHERE id=$1`, [polls.open.id]));
    try {
      await asRole('authenticated', member, async () => {
        const retry = await save(polls.open.id, [r(o2, 'maybe')], 'Before close', { requestId });
        assert.deepEqual([retry.replayed, retry.version], [true, committed.version]);
        await assert.rejects(save(polls.open.id, [r(o1, 'available')], 'After close'), notOpen);
        assert.equal((await getAvailability(polls.open.id)).comment, 'Before close', 'reads work in any state');
      });
      await asRole('anon', null, () => assert.rejects(save(polls.open.id, [], null,
        { participant: guest.participant.id, token: hex('a') }), notOpen));
    } finally {
      await db.query(`UPDATE public.polls SET status='active' WHERE id=$1`, [polls.open.id]);
    }
    for (const key of ['closed', 'expired']) {
      await asRole('authenticated', member, () => assert.rejects(save(polls[key].id, []), notOpen, key));
    }
  });

  await t.test('finalize_poll is organizer-only, closes the poll, and stores an exact option interval', async () => {
    const [o1, o2] = options.open;
    await asRole('anon', null, () => assert.rejects(finalize(polls.open.id, o1), deny));
    await asRole('authenticated', member, () => assert.rejects(finalize(polls.open.id, o1), denied('Poll access denied')));
    await asRole('authenticated', owner, async () => {
      await assert.rejects(finalize(missing, o1), denied('Poll access denied'));
      await assert.rejects(finalize(polls.open.id, options.other[0]), invalid);
      await assert.rejects(finalize(polls.draft.id, options.draft[0]), denied('Poll cannot be finalized'));
      const final = await finalize(polls.open.id, o1);
      const option = (await db.query('SELECT start_time,end_time FROM public.poll_time_options WHERE id=$1', [o1])).rows[0];
      assert.equal(final.status, 'closed');
      assert.equal(new Date(final.selected_start_time).getTime(), option.start_time.getTime());
      assert.equal(new Date(final.selected_end_time).getTime(), option.end_time.getTime());
      // Re-finalizing a closed poll to another option is allowed and idempotent.
      assert.equal((await finalize(polls.open.id, o2)).selected_start_time, (await finalize(polls.open.id, o2)).selected_start_time);
    });
    await asRole('authenticated', member, () => assert.rejects(save(polls.open.id, [r(o1, 'available')]), notOpen));
    await db.query(`UPDATE public.polls SET status='active', selected_start_time=NULL, selected_end_time=NULL WHERE id=$1`, [polls.open.id]);
  });

  await t.test('direct finalization accepts only a matching option pair and normalizes precision', async () => {
    const [o1] = options.open;
    const option = (await db.query('SELECT start_time,end_time FROM public.poll_time_options WHERE id=$1', [o1])).rows[0];
    const isoSeconds = date => `${date.toISOString().slice(0, 19)}Z`;
    await asRole('authenticated', owner, async () => {
      // Installed iOS clients send ISO 8601 without fractional seconds.
      const row = (await db.query(`UPDATE public.polls SET selected_start_time=$2, selected_end_time=$3 WHERE id=$1
        RETURNING selected_start_time, selected_end_time`, [polls.open.id, isoSeconds(option.start_time), isoSeconds(option.end_time)])).rows[0];
      assert.deepEqual([row.selected_start_time.getTime(), row.selected_end_time.getTime()],
        [option.start_time.getTime(), option.end_time.getTime()]);
      for (const [start, end] of [['2026-12-01T00:00:00Z', '2026-12-01T01:00:00Z'], [isoSeconds(option.start_time), null],
        [null, isoSeconds(option.end_time)], [isoSeconds(option.end_time), isoSeconds(option.start_time)],
        [isoSeconds(option.start_time), '2026-11-02T13:00:00Z']]) {
        await assert.rejects(db.query('UPDATE public.polls SET selected_start_time=$2, selected_end_time=$3 WHERE id=$1',
          [polls.open.id, start, end]), error => error.code === '23514', `${start}/${end}`);
      }
      await db.query('UPDATE public.polls SET selected_start_time=NULL, selected_end_time=NULL WHERE id=$1', [polls.open.id]);
    });
  });

  await t.test('owners can still delete closed polls; account deletion erases save results and notes', async () => {
    await asRole('authenticated', member, () => save(polls.open.id, [r(options.open[0], 'available', 'Leaver should not see this')], 'x'));
    await asRole('authenticated', leaver, () => save(polls.open.id, [r(options.open[1], 'maybe', 'Private note')], 'Private comment'));
    await db.query('DELETE FROM auth.users WHERE id=$1', [leaver]);
    assert.equal(await scalar('SELECT count(*)::int AS result FROM private.response_save_requests WHERE participant_id=$1',
      [members.leaver.id]), 0);
    assert.deepEqual(await stored(members.leaver.id), [r(options.open[1], 'maybe', '[user deleted]')]);
    assert.ok(await scalar('SELECT count(*)::int AS result FROM private.response_save_requests WHERE participant_id=$1',
      [members.open.id]) > 0);
    await asRole('authenticated', owner, async () => {
      assert.equal((await db.query('DELETE FROM public.polls WHERE id=$1 RETURNING id', [polls.closed.id])).rows.length, 1);
    });
    assert.equal(await scalar('SELECT count(*)::int AS result FROM public.availability_responses WHERE participant_id=$1',
      [members.closed.id]), 0);
  });
});
