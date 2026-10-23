import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const owner = '00000000-0000-4000-8000-000000000001';
const leaving = '00000000-0000-4000-8000-000000000002';
const other = '00000000-0000-4000-8000-000000000003';
const claimant = '00000000-0000-4000-8000-000000000004';
const legacyLeaver = '00000000-0000-4000-8000-000000000005';
const session = '00000000-0000-4000-8000-000000000006';
const ciphertext = JSON.stringify({ version: 1, key_id: 'test', iv: 'iv', ciphertext: 'secret-refresh' });
const hex = fill => fill.repeat(64);
const deny = error => error.code === '42501';
const guestDenied = error => deny(error) && error.message === 'Guest access denied';

test('account deletion anonymizes participation and keeps existing cascades on Postgres', async t => {
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
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
  `);

  let replayed = false;
  const directory = new URL('../supabase/migrations/', import.meta.url);
  for (const name of (await readdir(directory)).filter(name => name.endsWith('.sql')).sort()) {
    if (name.endsWith('_participant_account_deletion.sql')) {
      // Demonstrate the pre-fix failure: SET NULL violates participant_identity.
      await db.query(`INSERT INTO auth.users(id,email) VALUES ($1,'legacy-leaver@example.test'),
        ($2,'owner@example.test')`, [legacyLeaver, owner]);
      const poll = (await db.query(`INSERT INTO public.polls(creator_id,title,status) VALUES ($1,'Before fix','active')
        RETURNING id`, [owner])).rows[0];
      await db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2)', [poll.id, legacyLeaver]);
      await assert.rejects(db.query('DELETE FROM auth.users WHERE id=$1', [legacyLeaver]), error => error.code === '23514');
      replayed = true;
    }
    await db.exec(await readFile(new URL(name, directory), 'utf8'));
  }
  assert.ok(replayed, 'account-deletion migration must be replayed');

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
  const count = (sql, params = []) => scalar(`SELECT count(*)::int AS result FROM ${sql}`, params);

  // Fixture: the leaving user joined the owner's poll (comment + responses),
  // joined a second poll without a comment, claimed a guest row in a third,
  // owns a poll others joined, and has calendar and billing state.
  await db.query(`INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES ($1,'leaving@example.test','{"full_name":"Leaving User"}'),
    ($2,'other@example.test','{"full_name":"Other"}'),($3,'claimant@example.test','{}')`, [leaving, other, claimant]);
  await db.query('INSERT INTO auth.sessions(id,user_id) VALUES ($1,$2)', [session, leaving]);
  const makePoll = async (creator, title) => {
    const poll = (await db.query(`INSERT INTO public.polls(creator_id,title,status) VALUES ($1,$2,'active') RETURNING *`,
      [creator, title])).rows[0];
    const options = (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time) VALUES
      ($1,'2026-11-01T12:00:00Z','2026-11-01T13:00:00Z'),($1,'2026-11-02T12:00:00Z','2026-11-02T13:00:00Z')
      RETURNING id`, [poll.id])).rows.map(row => row.id);
    return { ...poll, options };
  };
  const joined = await makePoll(owner, 'Joined poll');
  const quiet = await makePoll(owner, 'Joined without comment');
  const guestPoll = await makePoll(other, 'Claimed guest poll');
  const own = await makePoll(leaving, 'Leaving user poll');
  const membership = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id,comment)
    VALUES ($1,$2,'I prefer mornings') RETURNING *`, [joined.id, leaving])).rows[0];
  const otherMembership = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id,comment)
    VALUES ($1,$2,'Other comment') RETURNING *`, [joined.id, other])).rows[0];
  const quietMembership = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id)
    VALUES ($1,$2) RETURNING *`, [quiet.id, leaving])).rows[0];
  const responses = (await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status,note)
    VALUES ($1,$2,'available','Morning works'),($1,$3,'unavailable',NULL) RETURNING *`,
  [membership.id, ...joined.options])).rows;
  const ownMember = (await db.query(`INSERT INTO public.poll_participants(poll_id,user_id) VALUES ($1,$2) RETURNING *`,
    [own.id, other])).rows[0];
  await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status) VALUES ($1,$2,'maybe')`,
    [ownMember.id, own.options[0]]);
  const guest = await asRole('anon', null, () => scalar('SELECT public.join_poll_as_guest($1,$2,$3,$4) AS result',
    [guestPoll.id, 'Former guest', 'former-guest@example.test', hex('a')]));
  await asRole('authenticated', leaving, () => scalar('SELECT public.claim_guest_participant($1,$2) AS result',
    [guest.participant.id, hex('a')]));
  await db.query(`INSERT INTO private.calendar_connections(user_id,access_token_ciphertext,refresh_token_ciphertext,
    expires_at,provider_subject) VALUES ($1,$2,$2,now()+interval '1 hour','google-leaving')`, [leaving, ciphertext]);
  await db.query(`INSERT INTO public.subscriptions(user_id,entitlement,is_active) VALUES ($1,'pro_access',true)`, [leaving]);
  await db.query(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,poll_id)
    VALUES ($1,'leaving-pass','APP_STORE',now(),$2)`, [leaving, own.id]);
  await db.query(`INSERT INTO private.participant_merge_audit(survivor_id,participant_id,merge_role,participant,responses)
    VALUES ($1,$1,'duplicate',$2,'[]'),($3,$3,'duplicate',$4,'[]')`,
  [membership.id, JSON.stringify({ user_id: leaving, comment: 'archived' }),
    otherMembership.id, JSON.stringify({ user_id: other, comment: 'kept' })]);

  await t.test('deleting a user who joined others\' polls succeeds through the auth cascade', async () => {
    await db.query('DELETE FROM auth.users WHERE id=$1', [leaving]);
    assert.equal(await count('auth.users WHERE id=$1', [leaving]), 0);
    assert.equal(await count('public.profiles WHERE id=$1', [leaving]), 0);
  });

  await t.test('participant rows stay, unlinked and anonymized, with their responses', async () => {
    const row = (await db.query('SELECT * FROM public.poll_participants WHERE id=$1', [membership.id])).rows[0];
    assert.equal(row.user_id, null);
    assert.equal(row.anonymous_name, 'Deleted user');
    assert.equal(row.comment, '[user deleted]');
    assert.equal(row.poll_id, joined.id);
    assert.equal(row.access_token, row.id);
    const quietRow = (await db.query('SELECT * FROM public.poll_participants WHERE id=$1', [quietMembership.id])).rows[0];
    assert.deepEqual([quietRow.user_id, quietRow.anonymous_name, quietRow.comment], [null, 'Deleted user', null]);
    const kept = (await db.query(`SELECT id,status,note FROM public.availability_responses WHERE participant_id=$1 ORDER BY id`,
      [membership.id])).rows;
    assert.deepEqual(kept, responses.map(r => ({ id: r.id, status: r.status, note: r.note })).sort((a, b) => a.id.localeCompare(b.id)));
    const otherRow = (await db.query('SELECT user_id,comment FROM public.poll_participants WHERE id=$1', [otherMembership.id])).rows[0];
    assert.deepEqual(otherRow, { user_id: other, comment: 'Other comment' });
    await asRole('authenticated', owner, async () => {
      const summary = await scalar('SELECT public.get_poll_with_summary($1) AS result', [joined.id]);
      assert.ok(summary.participants.some(p => p.id === membership.id && p.display_name === 'Deleted user'));
      assert.deepEqual(summary.time_options.map(o => o.responses.total).sort(), [1, 1]);
    });
  });

  await t.test('an anonymized row has no capability and cannot be claimed, edited, or read as a guest', async () => {
    const id = guest.participant.id;
    const row = (await db.query('SELECT user_id,anonymous_name FROM public.poll_participants WHERE id=$1', [id])).rows[0];
    assert.deepEqual(row, { user_id: null, anonymous_name: 'Deleted user' });
    assert.equal(await count('private.participant_guest_credentials WHERE participant_id=ANY($1::uuid[])',
      [[id, membership.id, quietMembership.id]]), 0);
    assert.equal(JSON.stringify((await db.query('SELECT * FROM private.participant_guest_credentials')).rows)
      .includes('former-guest@example.test'), false);
    for (const [role, userId] of [['anon', null], ['authenticated', claimant]]) {
      await asRole(role, userId, async () => {
        for (const target of [id, membership.id]) {
          await assert.rejects(scalar('SELECT public.get_guest_participant($1,$2) AS result', [target, hex('a')]), guestDenied);
          await assert.rejects(scalar('SELECT public.get_guest_poll_detail($1,$2) AS result', [target, hex('a')]), guestDenied);
          await assert.rejects(scalar('SELECT public.update_guest_participant($1,$2,$3,NULL) AS result',
            [target, hex('a'), 'Reclaimed']), guestDenied);
        }
      });
    }
    await asRole('authenticated', claimant, async () => {
      for (const target of [id, membership.id]) {
        await assert.rejects(scalar('SELECT public.claim_guest_participant($1,$2) AS result', [target, hex('a')]), guestDenied);
        await assert.rejects(db.query('UPDATE public.poll_participants SET user_id=$2 WHERE id=$1', [target, claimant]), deny);
      }
    });
    assert.equal(await scalar('SELECT user_id AS result FROM public.poll_participants WHERE id=$1', [id]), null);
  });

  await t.test('the user\'s own polls, calendar connection, and billing rows follow their existing cascades', async () => {
    assert.equal(await count('public.polls WHERE id=$1', [own.id]), 0);
    assert.equal(await count('public.poll_time_options WHERE poll_id=$1', [own.id]), 0);
    assert.equal(await count('public.poll_participants WHERE id=$1', [ownMember.id]), 0);
    assert.equal(await count('public.availability_responses WHERE participant_id=$1', [ownMember.id]), 0);
    assert.equal(await count('private.calendar_connections WHERE user_id=$1', [leaving]), 0);
    assert.equal(await scalar('SELECT token_ciphertext AS result FROM private.calendar_revocations WHERE user_id=$1', [leaving]), ciphertext);
    assert.equal(await count('public.subscriptions WHERE user_id=$1', [leaving]), 0);
    assert.equal(await count('public.event_passes WHERE user_id=$1', [leaving]), 0);
    assert.equal(await count('auth.sessions WHERE user_id=$1', [leaving]), 0);
  });

  await t.test('merge-audit copies naming the user are erased; others are kept', async () => {
    assert.equal(await count("private.participant_merge_audit WHERE participant->>'user_id'=$1", [leaving]), 0);
    assert.equal(await count("private.participant_merge_audit WHERE participant->>'user_id'=$1", [other]), 1);
  });

  await t.test('the trigger function is pinned and not callable by API roles; Data API unlinking stays blocked', async () => {
    const fn = (await db.query(`SELECT p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='poll_private' AND p.proname='anonymize_deleted_participant'`)).rows[0];
    assert.equal(fn.prosecdef, true);
    assert.ok(fn.proconfig.includes('search_path=""'));
    assert.deepEqual([fn.anon, fn.authenticated], [false, false]);
    await db.exec('GRANT UPDATE ON public.poll_participants TO authenticated');
    try {
      await asRole('authenticated', other, async () => {
        await assert.rejects(db.query(`UPDATE public.poll_participants SET user_id=NULL, anonymous_name='Deleted user'
          WHERE id=$1`, [otherMembership.id]), deny);
      });
    } finally {
      await db.exec('REVOKE UPDATE ON public.poll_participants FROM authenticated; GRANT UPDATE (comment) ON public.poll_participants TO authenticated');
    }
    // Deleting a user with no participation, and the pre-fix fixture user, both succeed.
    await db.query('DELETE FROM auth.users WHERE id=ANY($1::uuid[])', [[claimant, legacyLeaver]]);
    assert.equal(await count('auth.users WHERE id=ANY($1::uuid[])', [[claimant, legacyLeaver]]), 0);
    assert.equal(await count("public.poll_participants WHERE anonymous_name='Deleted user'"), 4);
  });
});
