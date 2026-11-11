import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { bootstrapCreationDatabase } from './helpers/creation-database.mjs';

const deny = error => error.code === '42501';
const publicColumns = ['avatar_url', 'display_name', 'id'];

test('F01 profile reads: owner, poll peers and signed-out callers on Postgres', async t => {
  const db = new PGlite(); t.after(() => db.close());
  await bootstrapCreationDatabase(db);
  const rows = async (sql, params = []) => (await db.query(sql, params)).rows;
  const scalar = async (sql, params = []) => (await rows(sql, params))[0].result;
  const as = async (id, action, role = id ? 'authenticated' : 'anon') => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: id })]);
    await db.exec(`SET ROLE ${role}`);
    try { return await action(); } finally { await db.exec('RESET ROLE'); }
  };
  // The signup trigger creates each profile from auth.users.
  const user = async name => {
    const id = randomUUID();
    await db.query('INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES($1,$2,$3)',
      [id, `${name.toLowerCase()}@test.invalid`, JSON.stringify({ full_name: name, avatar_url: `https://img.test/${name}` })]);
    return id;
  };
  const poll = async (creator, status = 'active') => (await rows(`INSERT INTO public.polls(creator_id,title,status)
    VALUES($1,'Poll',$2) RETURNING id`, [creator, status]))[0].id;
  const join = (pollId, member) => db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)', [pollId, member]);
  const visibleIds = id => as(id, async () =>
    (await rows('SELECT id FROM public.profiles ORDER BY id')).map(row => row.id));
  const sorted = ids => [...ids].sort();

  // creator owns `shared`, where memberA and memberB participate. memberA also
  // created `draft`, where creator participates. outsider owns a poll with
  // outsiderMember; unrelated belongs to no poll.
  const creator = await user('Creator'); const memberA = await user('MemberA'); const memberB = await user('MemberB');
  const outsider = await user('Outsider'); const outsiderMember = await user('OutsiderMember');
  const unrelated = await user('Unrelated');
  const shared = await poll(creator);
  await join(shared, memberA); await join(shared, memberB);
  const draft = await poll(memberA, 'draft');
  await join(draft, creator);
  const elsewhere = await poll(outsider);
  await join(elsewhere, outsiderMember);
  await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
    VALUES($1,'2027-01-01T12:00:00Z','2027-01-01T13:00:00Z')`, [shared]);

  await t.test('catalog: one owner-or-peer read policy, no anon privileges, narrow column grants, pinned helpers', async () => {
    const policies = await rows(`SELECT policyname, cmd, roles::text AS roles FROM pg_policies
      WHERE schemaname='public' AND tablename='profiles' ORDER BY policyname`);
    assert.deepEqual(policies.map(p => [p.policyname, p.cmd, p.roles]), [
      ['Profiles are visible to their owner and poll peers', 'SELECT', '{authenticated}'],
      ['Users can update own profile', 'UPDATE', '{public}'],
    ]);
    assert.deepEqual(await rows(`SELECT privilege_type FROM information_schema.role_table_grants
      WHERE table_schema='public' AND table_name='profiles' AND grantee='anon'`), []);
    assert.equal(await scalar(`SELECT has_table_privilege('authenticated','public.profiles','SELECT') AS result`), false);
    const readable = await rows(`SELECT column_name FROM information_schema.columns
      WHERE table_schema='public' AND table_name='profiles'
        AND has_column_privilege('authenticated','public.profiles',column_name,'SELECT') ORDER BY column_name`);
    assert.deepEqual(readable.map(row => row.column_name), publicColumns);
    for (const role of ['anon', 'authenticated']) {
      assert.equal(await scalar(`SELECT has_any_column_privilege($1,'public.profiles','SELECT') AS result`, [role]),
        role === 'authenticated');
    }
    assert.equal(await scalar(`SELECT has_table_privilege('service_role','public.profiles','SELECT') AS result`), true);

    const helpers = await rows(`SELECT n.nspname || '.' || p.proname AS name, p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
      EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
        WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE') AS public_execute
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE p.proname IN ('poll_peer_ids','get_my_profile') ORDER BY 1`);
    assert.deepEqual(helpers.map(fn => [fn.name, fn.prosecdef]), [
      ['poll_private.get_my_profile', true], ['poll_private.poll_peer_ids', true], ['public.get_my_profile', false],
    ]);
    for (const fn of helpers) {
      assert.ok(fn.proconfig.includes('search_path=""'), fn.name);
      assert.equal(fn.public_execute, false, fn.name);
      assert.equal(fn.anon, false, fn.name);
      assert.equal(fn.authenticated, true, fn.name);
    }
  });

  await t.test('signed-out callers read no profile and cannot call get_my_profile', async () => {
    await as(null, async () => {
      // The anon GET /rest/v1/profiles?select=* probe, and narrower selects.
      for (const sql of ['SELECT * FROM public.profiles', 'SELECT id FROM public.profiles',
        'SELECT display_name FROM public.profiles WHERE id IS NOT NULL', 'SELECT count(*) FROM public.profiles']) {
        await assert.rejects(db.query(sql), deny, sql);
      }
      await assert.rejects(db.query('SELECT * FROM public.get_my_profile()'), deny);
      await assert.rejects(db.query("UPDATE public.profiles SET display_name='x'"), deny);
    });
  });

  await t.test('the owner reads the full row, email included, only through get_my_profile', async () => {
    for (const id of [creator, unrelated]) {
      const [expected] = await rows('SELECT * FROM public.profiles WHERE id=$1', [id]);
      await as(id, async () => {
        assert.deepEqual(await rows('SELECT * FROM public.get_my_profile()'), [expected]);
        assert.match(expected.email, /@test\.invalid$/);
        assert.ok(expected.timezone);
        assert.deepEqual(await rows('SELECT id, display_name, avatar_url FROM public.profiles WHERE id=$1', [id]),
          [{ id, display_name: expected.display_name, avatar_url: expected.avatar_url }]);
        // A Data API select('*') expands to every column, email included.
        await assert.rejects(db.query('SELECT * FROM public.profiles WHERE id=$1', [id]), deny);
        await assert.rejects(db.query('SELECT email FROM public.profiles WHERE id=$1', [id]), deny);
        await assert.rejects(db.query('SELECT timezone FROM public.profiles WHERE id=$1', [id]), deny);
      });
    }
    // A user without a profile row gets an empty set, so `.single()` reports it.
    const ghost = randomUUID();
    assert.deepEqual(await as(ghost, () => rows('SELECT * FROM public.get_my_profile()')), []);
  });

  await t.test('poll peers read name and avatar but never email; unrelated users read only themselves', async () => {
    const expectations = [
      // A poll's creator sees its participants, plus the creator of a poll it joined.
      [creator, [creator, memberA, memberB]],
      // A participant sees the creator and the other participants of its poll.
      [memberA, [creator, memberA, memberB]],
      [memberB, [creator, memberA, memberB]],
      [outsider, [outsider, outsiderMember]],
      [outsiderMember, [outsider, outsiderMember]],
      [unrelated, [unrelated]],
    ];
    for (const [id, expected] of expectations) assert.deepEqual(await visibleIds(id), sorted(expected), id);
    await as(memberB, async () => {
      assert.deepEqual(await rows('SELECT id, display_name, avatar_url FROM public.profiles WHERE id=$1', [creator]),
        [{ id: creator, display_name: 'Creator', avatar_url: 'https://img.test/Creator' }]);
      await assert.rejects(db.query('SELECT email FROM public.profiles WHERE id=$1', [creator]), deny);
      await assert.rejects(db.query('SELECT * FROM public.profiles WHERE id=$1', [creator]), deny);
      // get_my_profile ignores everything but the caller's identity.
      assert.deepEqual((await rows('SELECT id FROM public.get_my_profile()')).map(row => row.id), [memberB]);
    });
  });

  await t.test('peer visibility follows membership: a removed participant and a deleted poll stop sharing', async () => {
    const solo = await poll(unrelated);
    await join(solo, outsider);
    assert.deepEqual(await visibleIds(unrelated), sorted([unrelated, outsider]));
    await db.query('DELETE FROM public.poll_participants WHERE poll_id=$1 AND user_id=$2', [solo, outsider]);
    assert.deepEqual(await visibleIds(unrelated), [unrelated]);
    await join(solo, outsider);
    await db.query('DELETE FROM public.polls WHERE id=$1', [solo]);
    assert.deepEqual(await visibleIds(unrelated), [unrelated]);
    assert.deepEqual(await visibleIds(outsider), sorted([outsider, outsiderMember]));
  });

  await t.test('native participant reads keep their profiles(display_name) embed', async () => {
    // PostgREST's shape for poll_participants?select=*,profiles(display_name).
    const embed = id => as(id, () => rows(`SELECT pp.user_id, (SELECT to_jsonb(pr) FROM (SELECT pr.display_name
        FROM public.profiles pr WHERE pr.id = pp.user_id) pr) AS profiles
      FROM public.poll_participants pp WHERE pp.poll_id=$1 ORDER BY pp.user_id`, [shared]));
    const expected = sorted([memberA, memberB]).map(user_id =>
      ({ user_id, profiles: { display_name: user_id === memberA ? 'MemberA' : 'MemberB' } }));
    for (const id of [creator, memberA, memberB]) assert.deepEqual(await embed(id), expected, id);
    assert.deepEqual(await embed(unrelated), []);
  });

  await t.test('poll detail reads still return participant names to members and capability guests', async () => {
    const guest = await as(null, () => scalar('SELECT public.join_poll_as_guest($1,$2,$3) AS result',
      [shared, 'Guest', 'guest@test.invalid']));
    const names = detail => Object.fromEntries(detail.participants.map(p =>
      [p.user_id ?? p.anonymous_name, p.profiles?.display_name ?? null]));
    const expected = { [memberA]: 'MemberA', [memberB]: 'MemberB', Guest: null };
    for (const [id, read] of [
      [null, () => scalar('SELECT public.get_poll_detail_as_guest($1,$2) AS result', [guest.participant.id, guest.guest_token])],
      [unrelated, () => scalar('SELECT public.get_poll_detail_as_guest($1,$2) AS result', [guest.participant.id, guest.guest_token])],
      [memberA, () => scalar('SELECT public.get_poll_detail($1) AS result', [shared])],
      [creator, () => scalar('SELECT public.get_poll_detail($1) AS result', [shared])],
    ]) {
      const detail = await as(id, read);
      assert.deepEqual(names(detail), expected, id ?? 'anon');
      const payload = JSON.stringify(detail);
      for (const email of ['membera@test.invalid', 'memberb@test.invalid', 'creator@test.invalid']) {
        assert.equal(payload.includes(email), false, email);
      }
    }
  });

  await t.test('owners update their profile without returning it, then read it back', async () => {
    await as(memberA, async () => {
      // Clients send return=minimal: PostgREST then returns no columns.
      const update = await db.query(`UPDATE public.profiles SET display_name='Renamed', avatar_url=NULL,
        timezone='Europe/Paris' WHERE id=$1`, [memberA]);
      assert.equal(update.affectedRows, 1);
      const [own] = await rows('SELECT * FROM public.get_my_profile()');
      assert.deepEqual([own.display_name, own.avatar_url, own.timezone, own.email],
        ['Renamed', null, 'Europe/Paris', 'membera@test.invalid']);
      // return=representation without a column list would read email.
      await assert.rejects(db.query(`UPDATE public.profiles SET display_name='Again' WHERE id=$1 RETURNING *`, [memberA]), deny);
      // Peers stay read-only.
      assert.equal((await db.query("UPDATE public.profiles SET display_name='Hijack' WHERE id=$1", [memberB])).affectedRows, 0);
    });
    assert.equal(await scalar('SELECT display_name AS result FROM public.profiles WHERE id=$1', [memberB]), 'MemberB');
  });
});
