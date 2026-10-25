import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { bootstrapCreationDatabase } from './helpers/creation-database.mjs';

const code = value => error => error.code === value;

test('F19 paged summaries, bounded detail and complete response traversal', async t => {
  const db = new PGlite(); t.after(() => db.close());
  let legacyNullPoll;
  await bootstrapCreationDatabase(db, async name => {
    if (!name.endsWith('_bounded_read_apis.sql')) return;
    // A legacy row without created_at must be backfilled, not dropped from paging.
    const legacyOwner = randomUUID();
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)', [legacyOwner, 'legacy@test.invalid']);
    legacyNullPoll = (await db.query(`INSERT INTO public.polls(creator_id,title,status,created_at,updated_at)
      VALUES($1,'Legacy poll','closed',NULL,'2026-01-02T03:04:05.678901Z') RETURNING id`, [legacyOwner])).rows[0].id;
  });
  const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0].result;
  const user = async (name = null) => {
    const id = randomUUID();
    await db.query('INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES($1,$2,$3)',
      [id, `${id}@test.invalid`, JSON.stringify(name ? { full_name: name } : {})]);
    return id;
  };
  const as = async (id, action, role = 'authenticated') => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: id })]);
    await db.exec(`SET ROLE ${role}`);
    try { return await action(); } finally { await db.exec('RESET ROLE'); }
  };
  const summaries = (id, args = {}) => as(id, () => scalar(
    'SELECT public.list_poll_summaries($1,$2,$3) AS result',
    [args.role ?? null, args.size === undefined ? 50 : args.size, args.cursor ?? null]));
  const detail = (id, poll) => as(id, () => scalar('SELECT public.get_poll_detail($1) AS result', [poll]));
  const responses = (id, poll, size = 500, cursor = null) => as(id, () => scalar(
    'SELECT public.list_poll_responses($1,$2,$3) AS result', [poll, size, cursor]));
  const traverse = async fetchPage => {
    const items = []; let cursor = null; let first; let pages = 0;
    do {
      const page = await fetchPage(cursor);
      first ??= page; pages++;
      items.push(...page.items);
      assert.equal(page.has_more, page.next_cursor !== null);
      cursor = page.next_cursor;
      assert.ok(pages < 100, 'traversal must terminate');
    } while (cursor);
    return { items, first, pages };
  };
  // Seeds run as the migration owner; reads below use the API role.
  const poll = async (creator, createdAt, extra = {}) => (await db.query(`INSERT INTO public.polls
    (creator_id,title,status,created_at,max_participants) VALUES($1,$2,'active',$3,$4) RETURNING id`,
  [creator, extra.title ?? 'Poll', createdAt, extra.max ?? 100])).rows[0].id;
  const options = async (pollId, count) => (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
    SELECT $1, timestamptz '2027-01-01T12:00:00Z' + n * interval '1 day',
           timestamptz '2027-01-01T13:00:00Z' + n * interval '1 day'
    FROM generate_series(0,$2-1) n RETURNING id`, [pollId, count])).rows.map(row => row.id);
  const guests = async (pollId, count) => (await db.query(`INSERT INTO public.poll_participants(poll_id,anonymous_name)
    SELECT $1, 'Guest ' || n FROM generate_series(1,$2) n RETURNING id`, [pollId, count])).rows.map(row => row.id);
  const join = (pollId, member) => db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)', [pollId, member]);

  await t.test('migration keeps legacy polls orderable and grants only signed-in callers', async () => {
    const row = (await db.query('SELECT created_at FROM public.polls WHERE id=$1', [legacyNullPoll])).rows[0];
    assert.equal(row.created_at.toISOString(), '2026-01-02T03:04:05.678Z');
    assert.equal(await scalar(`SELECT is_nullable AS result FROM information_schema.columns
      WHERE table_schema='public' AND table_name='polls' AND column_name='created_at'`), 'NO');
    for (const fn of ['list_poll_summaries(text,integer,text)', 'get_poll_detail(uuid)', 'list_poll_responses(uuid,integer,text)']) {
      for (const [role, expected] of [['anon', false], ['authenticated', true], ['service_role', true]]) {
        assert.equal(await scalar(`SELECT has_function_privilege($1,$2,'EXECUTE') AS result`, [role, `public.${fn}`]),
          expected, `${role} ${fn}`);
      }
      assert.equal(await scalar(`SELECT has_function_privilege('anon',$1,'EXECUTE') AS result`, [`poll_private.${fn}`]), false);
    }
    await assert.rejects(as(null, () => scalar('SELECT public.list_poll_summaries() AS result'), 'anon'), code('42501'));
    await assert.rejects(as(null, () => scalar('SELECT public.list_poll_summaries() AS result')), code('42501'));
  });

  const owner = await user(); const other = await user('Other Owner'); const unrelated = await user();
  // Three polls share a microsecond timestamp, so both the id tiebreak and the
  // exact cursor encoding are exercised.
  const tie = '2026-06-01T10:00:00.123457Z';
  const created = [];
  for (let index = 0; index < 7; index++) {
    created.push(await poll(owner, index < 3 ? tie : `2026-0${index}-15T08:30:00.00000${index}Z`, { title: `Owned ${index}` }));
  }
  const joined = [];
  for (let index = 0; index < 4; index++) {
    const id = await poll(other, `2026-07-0${index + 1}T00:00:00Z`, { title: `Joined ${index}` });
    joined.push(id); await join(id, owner);
  }
  const hidden = await poll(other, '2026-09-01T00:00:00Z', { title: 'Not shared' });
  const busy = created[6];
  const busyOptions = await options(busy, 30);
  const busyGuests = await guests(busy, 40);
  // 1,200 rows: above the Data API's 1,000-row cap.
  await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
    SELECT p, o, (ARRAY['available','maybe','unavailable'])[1 + (abs(hashtext(p::text || o::text)) % 3)]::public.availability_status
    FROM unnest($1::uuid[]) p CROSS JOIN unnest($2::uuid[]) o`, [busyGuests, busyOptions]);

  await t.test('summary pages traverse every visible poll once in stable order', async () => {
    const { items, first, pages } = await traverse(cursor => summaries(owner, { size: 3, cursor }));
    assert.equal(pages, 4);
    assert.equal(first.total_count, 11);
    assert.equal(items.length, 11);
    const ids = items.map(item => item.poll.id);
    assert.equal(new Set(ids).size, ids.length, 'no duplicates');
    assert.deepEqual(new Set(ids), new Set([...created, ...joined]));
    assert.ok(!ids.includes(hidden));
    const expected = (await db.query(`SELECT id FROM public.polls WHERE id = ANY($1::uuid[])
      ORDER BY created_at DESC, id DESC`, [ids])).rows.map(row => row.id);
    assert.deepEqual(ids, expected);
    for (const item of items) assert.equal(item.role, created.includes(item.poll.id) ? 'owner' : 'member');
    const busyItem = items.find(item => item.poll.id === busy);
    assert.equal(busyItem.participant_count, 40);
    assert.equal(busyItem.time_option_count, 30);
    assert.equal(new Date(busyItem.earliest_start).toISOString(), '2027-01-01T12:00:00.000Z');
    assert.equal(new Date(busyItem.latest_start).toISOString(), '2027-01-30T12:00:00.000Z');
    const empty = items.find(item => item.poll.id === created[0]);
    assert.equal(empty.time_option_count, 0);
    assert.equal(empty.earliest_start, null);
    assert.equal(items.find(item => item.poll.id === joined[0]).participant_count, 1);
  });

  await t.test('role filters page their own section with their own total', async () => {
    const owned = await traverse(cursor => summaries(owner, { role: 'owner', size: 2, cursor }));
    assert.equal(owned.first.total_count, 7);
    assert.equal(owned.pages, 4);
    assert.deepEqual(new Set(owned.items.map(item => item.poll.id)), new Set(created));
    const member = await traverse(cursor => summaries(owner, { role: 'member', size: 100, cursor }));
    assert.equal(member.pages, 1);
    assert.equal(member.first.total_count, 4);
    assert.deepEqual(member.items.map(item => item.poll.id), [...joined].reverse());
    assert.deepEqual(await summaries(unrelated), { items: [], has_more: false, next_cursor: null, total_count: 0 });
  });

  await t.test('a poll created during traversal is neither duplicated nor misplaced', async () => {
    const page = await summaries(owner, { size: 5 });
    const late = await poll(owner, '2026-10-25T00:00:00Z', { title: 'Created later' });
    const rest = await traverse(cursor => summaries(owner, { size: 5, cursor: cursor ?? page.next_cursor }));
    const ids = [...page.items, ...rest.items].map(item => item.poll.id);
    assert.equal(new Set(ids).size, ids.length);
    assert.ok(!ids.includes(late), 'newer rows appear on the next refresh, not mid-traversal');
    assert.equal(ids.length, 11);
    await db.query('DELETE FROM public.polls WHERE id=$1', [late]);
  });

  await t.test('invalid page requests fail instead of returning partial pages', async () => {
    for (const size of [0, 101, null]) await assert.rejects(summaries(owner, { size }), code('22023'), String(size));
    await assert.rejects(summaries(owner, { role: 'admin' }), code('22023'));
    for (const cursor of ['', 'garbage', `p2:1:${randomUUID()}`, `r1:${randomUUID()}:${randomUUID()}`, `p1:1.5:${randomUUID()}`]) {
      await assert.rejects(summaries(owner, { cursor }), code('22023'), cursor);
    }
    const summaryCursor = (await summaries(owner, { size: 1 })).next_cursor;
    await assert.rejects(responses(owner, busy, 10, summaryCursor), code('22023'));
    for (const size of [0, 1001, null]) await assert.rejects(responses(owner, busy, size), code('22023'), String(size));
  });

  await t.test('detail returns complete bounded collections and counts', async () => {
    const value = await detail(owner, busy);
    assert.equal(value.poll.id, busy);
    assert.equal(value.time_options.length, 30);
    assert.equal(value.time_option_count, 30);
    assert.equal(value.participants.length, 40);
    assert.equal(value.participant_count, 40);
    assert.ok(value.participants.every(p => p.anonymous_email === null && p.access_token === p.id && p.profiles === null));
    const starts = value.time_options.map(option => Date.parse(option.start_time));
    assert.deepEqual(starts, [...starts].sort((a, b) => a - b));
    const shared = await detail(owner, joined[0]);
    assert.deepEqual(shared.participants.map(p => p.profiles), [{ display_name: null }]);
    assert.equal((await detail(other, joined[0])).participant_count, 1);
    await assert.rejects(detail(unrelated, busy), code('42501'));
    await assert.rejects(responses(unrelated, busy), code('42501'));
    await assert.rejects(detail(other, busy), code('42501'));
    await assert.rejects(detail(owner, hidden), code('42501'));
    await assert.rejects(detail(owner, randomUUID()), code('42501'));
  });

  await t.test('response pages beyond the row cap traverse completely', async () => {
    const { items, first, pages } = await traverse(cursor => responses(owner, busy, 500, cursor));
    assert.equal(pages, 3);
    assert.equal(first.total_count, 1200);
    assert.equal(items.length, 1200);
    const keys = items.map(row => `${row.participant_id}:${row.time_option_id}`);
    assert.equal(new Set(keys).size, 1200);
    assert.deepEqual(keys, [...keys].sort());
    assert.equal((await responses(owner, busy, 500, first.next_cursor)).total_count, null, 'later pages do not recount');
    // An exact multiple of the page size ends without an extra empty page.
    const exact = await traverse(cursor => responses(owner, busy, 400, cursor));
    assert.equal(exact.pages, 3);
    assert.equal(exact.items.length, 1200);
    assert.deepEqual(await responses(owner, created[0]), { items: [], has_more: false, next_cursor: null, total_count: 0 });
  });

  await t.test('response pages exclude legacy cross-poll rows', async () => {
    const foreign = await poll(owner, '2026-08-01T00:00:00Z');
    const [foreignOption] = await options(foreign, 1);
    await db.exec('ALTER TABLE public.availability_responses DISABLE TRIGGER responses_10_check_write');
    await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
      VALUES($1,$2,'available')`, [busyGuests[0], foreignOption]);
    await db.exec('ALTER TABLE public.availability_responses ENABLE TRIGGER responses_10_check_write');
    assert.equal((await responses(owner, busy, 1)).total_count, 1200);
    assert.equal((await responses(owner, foreign, 1)).total_count, 0);
  });

  await t.test('detail beyond the supported legacy size fails explicitly', async () => {
    const large = await poll(owner, '2026-08-02T00:00:00Z', { max: 1000 });
    await guests(large, 501);
    await assert.rejects(detail(owner, large), code('54000'));
    const summary = (await traverse(cursor => summaries(owner, { size: 100, cursor }))).items
      .find(item => item.poll.id === large);
    assert.equal(summary.participant_count, 501, 'summaries still report the true count');
  });
});
