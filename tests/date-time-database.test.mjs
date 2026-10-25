import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { bootstrapCreationDatabase, creationPayload } from './helpers/creation-database.mjs';

// F21: all-day intervals follow docs/date-time-contract.md through the creation
// command and direct option writes. Expected values come from the shared fixtures.
const fixtures = JSON.parse(await readFile(new URL('../packages/shared-config/date-time-fixtures.json', import.meta.url), 'utf8'));
const code = value => error => error.code === value;
const allDayRejection = error => error.code === '22023' && /all-day option must run/.test(error.message);

test('F21 all-day option intervals in the poll timezone', async t => {
  const db = new PGlite(); t.after(() => db.close());
  let legacyOption;
  await bootstrapCreationDatabase(db, async name => {
    if (!name.endsWith('_all_day_time_options.sql')) return;
    // A pre-contract row with a 23:59 end must survive the migration untouched.
    const owner = randomUUID();
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)', [owner, `${owner}@test.invalid`]);
    const poll = (await db.query("INSERT INTO public.polls(creator_id,title,status,timezone) VALUES($1,'Legacy','active','America/Chicago') RETURNING id", [owner])).rows[0].id;
    legacyOption = (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time,is_all_day)
      VALUES($1,'2026-11-01T05:00:00Z','2026-11-02T05:59:00Z',true) RETURNING id`, [poll])).rows[0].id;
  });
  const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0].result;
  const user = async () => {
    const id = randomUUID(); await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)', [id, `${id}@test.invalid`]); return id;
  };
  const as = async (id, action) => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id]);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role: 'authenticated', sub: id })]);
    await db.exec('SET ROLE authenticated');
    try { return await action(); } finally { await db.exec('RESET ROLE'); }
  };
  const create = async (payload, id) => { id ??= await user(); return { id, result: await as(id, () => scalar('SELECT public.create_poll($1,$2) AS result', [randomUUID(), JSON.stringify(payload)])) }; };
  const allDay = (zone, options) => creationPayload({ timezone: zone, time_options: options.map(o => ({ ...o, is_all_day: true })) });

  await t.test('every fixture all-day interval is accepted and stored unchanged', async () => {
    for (const c of fixtures.all_day_options) {
      const { result } = await create(allDay(c.zone, [{ start_time: c.start_time, end_time: c.end_time }]));
      const stored = result.time_options[0];
      assert.equal(new Date(stored.start_time).toISOString(), new Date(c.start_time).toISOString(), c.name);
      assert.equal(new Date(stored.end_time).toISOString(), new Date(c.end_time).toISOString(), c.name);
      assert.equal(stored.is_all_day, true);
    }
  });

  await t.test('a misaligned or legacy all-day interval rejects the whole creation', async () => {
    const chicago = fixtures.all_day_options.find(c => c.zone === 'America/Chicago');
    const santiago = fixtures.all_day_options.find(c => c.name === 'Missing local midnight');
    const invalid = [
      ['legacy 23:59 end', 'America/Chicago', { start_time: chicago.start_time, end_time: '2026-11-02T05:59:00Z' }],
      ['UTC midnight in Chicago', 'America/Chicago', { start_time: '2026-11-01T00:00:00Z', end_time: '2026-11-02T00:00:00Z' }],
      ['two dates', 'America/Chicago', { start_time: chicago.start_time, end_time: '2026-11-03T06:00:00Z' }],
      ['fixed 24 hours across fall-back', 'America/Chicago', { start_time: '2026-11-01T05:00:00Z', end_time: '2026-11-02T05:00:00Z' }],
      ['wall midnight before the gap', 'America/Santiago', { start_time: '2026-09-06T03:00:00Z', end_time: santiago.end_time }],
      ['fixture read in another zone', 'Asia/Kolkata', { start_time: chicago.start_time, end_time: chicago.end_time }],
    ];
    for (const [name, zone, option] of invalid) {
      const id = await user();
      await assert.rejects(create(allDay(zone, [option]), id), allDayRejection, name);
      assert.equal(await scalar('SELECT count(*)::int AS result FROM public.polls WHERE creator_id=$1', [id]), 0, name);
    }
  });

  await t.test('timed options keep their existing rules', async () => {
    for (const c of fixtures.timed_options.filter(c => !c.error)) {
      const { result } = await create(creationPayload({ timezone: c.zone, time_options: [{ start_time: c.start_time, end_time: c.end_time, is_all_day: false }] }));
      assert.equal(result.time_options.length, 1, c.name);
    }
  });

  await t.test('direct option writes follow the same rule; unrelated legacy edits remain possible', async () => {
    const c = fixtures.all_day_options.find(c => c.name === 'Chicago ordinary day');
    const { id, result } = await create(allDay(c.zone, [{ start_time: c.start_time, end_time: c.end_time }]));
    const option = result.time_options[0].id;
    await assert.rejects(as(id, () => db.query("UPDATE public.poll_time_options SET end_time=end_time - interval '1 minute' WHERE id=$1", [option])), allDayRejection);
    await assert.rejects(as(id, () => db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time,is_all_day)
      VALUES($1,'2026-11-04T06:00:00Z','2026-11-05T05:59:00Z',true)`, [result.poll.id])), allDayRejection);
    const next = fixtures.all_day_options.find(c => c.name === 'Chicago 25-hour day');
    await as(id, () => db.query('INSERT INTO public.poll_time_options(poll_id,start_time,end_time,is_all_day) VALUES($1,$2,$3,true)', [result.poll.id, next.start_time, next.end_time]));
    // Legacy rows are not revalidated unless their interval changes.
    await db.query('UPDATE public.poll_time_options SET is_all_day=true WHERE id=$1', [legacyOption]);
    assert.equal(await scalar('SELECT end_time=\'2026-11-02T05:59:00Z\'::timestamptz AS result FROM public.poll_time_options WHERE id=$1', [legacyOption]), true);
  });

  await t.test('a poll with all-day options cannot change timezone', async () => {
    const c = fixtures.all_day_options.find(c => c.name === 'Chicago 23-hour day');
    const { id, result } = await create(allDay(c.zone, [{ start_time: c.start_time, end_time: c.end_time }]));
    await assert.rejects(as(id, () => db.query("UPDATE public.polls SET timezone='Asia/Kolkata' WHERE id=$1", [result.poll.id])), code('22023'));
    const timed = await create(creationPayload());
    await as(timed.id, () => db.query("UPDATE public.polls SET timezone='Asia/Kolkata' WHERE id=$1", [timed.result.poll.id]));
    assert.equal(await scalar('SELECT timezone AS result FROM public.polls WHERE id=$1', [timed.result.poll.id]), 'Asia/Kolkata');
  });

  await t.test('the day-start helper is private', async () => {
    assert.equal(await scalar("SELECT has_function_privilege('authenticated','poll_private.is_zone_day_start(timestamptz,text)','EXECUTE') AS result"), false);
  });
});
