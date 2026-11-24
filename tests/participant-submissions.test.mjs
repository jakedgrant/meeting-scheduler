import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { bootstrapCreationDatabase } from './helpers/creation-database.mjs';

const denied = error => error.code === '42501';
const instant = value => value == null ? null : new Date(value).toISOString();

test('participant submission timestamps follow committed availability', async t => {
  const db = new PGlite();
  t.after(() => db.close());
  const owner = randomUUID(), member = randomUUID(), unrelated = randomUUID();
  let poll, options, participants, historicalSubmission;
  const scalar = async (sql, params = []) => (await db.query(sql, params)).rows[0].result;
  const as = async (id, action, role = 'authenticated') => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: id })]);
    await db.exec(`SET ROLE ${role}`);
    try { return await action(); } finally { await db.exec('RESET ROLE'); }
  };
  const answer = (option, status = 'unavailable') => ({ time_option_id: option, status });
  const save = (answers, comment = null, extra = {}) => as(member, () => scalar(
    'SELECT public.save_availability($1,$2,$3,$4,$5,$6,$7) AS result',
    [poll, extra.requestId ?? randomUUID(), JSON.stringify(answers), comment,
      extra.version ?? null, extra.participant ?? participants.member, extra.token ?? null]), extra.role);
  const submitted = id => scalar('SELECT poll_private.availability_submitted_at($1) AS result', [id]);

  await bootstrapCreationDatabase(db, async name => {
    if (!name.endsWith('_participant_submission_timestamps.sql')) return;
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2),($3,$4),($5,$6)',
      [owner, 'owner@test.invalid', member, 'member@test.invalid', unrelated, 'other@test.invalid']);
    poll = await scalar("INSERT INTO public.polls(creator_id,title,status) VALUES($1,'Submissions','active') RETURNING id AS result", [owner]);
    options = (await db.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time) VALUES
      ($1,'2027-12-01T12:00:00Z','2027-12-01T13:00:00Z'),
      ($1,'2027-12-02T12:00:00Z','2027-12-02T13:00:00Z') RETURNING id`, [poll])).rows.map(row => row.id);
    participants = {};
    participants.member = await scalar('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2) RETURNING id AS result', [poll, member]);
    for (const name of ['legacy', 'pending']) {
      participants[name] = await scalar('INSERT INTO public.poll_participants(poll_id,anonymous_name) VALUES($1,$2) RETURNING id AS result', [poll, name]);
    }
    await db.query(`INSERT INTO public.availability_responses(participant_id,time_option_id,status,updated_at)
      VALUES($1,$2,'maybe','2026-01-02T03:04:05Z')`, [participants.legacy, options[0]]);
    // Simulate a row predating response version tracking, then a mixed
    // command/direct-write history whose latest evidence is the version state.
    await db.query('DELETE FROM private.participant_response_state WHERE participant_id=$1', [participants.legacy]);
    await save([answer(options[0])], 'Previously submitted');
    await db.query(`UPDATE private.response_save_requests
      SET result=jsonb_set(result,'{saved_at}','"2026-01-01T00:00:00Z"'::jsonb)
      WHERE participant_id=$1`, [participants.member]);
    await as(member, () => db.query("UPDATE public.poll_participants SET comment='Later legacy edit' WHERE id=$1", [participants.member]));
    historicalSubmission = await scalar('SELECT updated_at AS result FROM private.participant_response_state WHERE participant_id=$1', [participants.member]);
  });

  await t.test('existing version state covers mixed write history, legacy rows fall back to answers, and joining stays pending', async () => {
    assert.equal(instant(await submitted(participants.member)), instant(historicalSubmission));
    assert.equal(instant(await submitted(participants.legacy)), '2026-01-02T03:04:05.000Z');
    assert.equal(await submitted(participants.pending), null);
  });

  await t.test('submitted time is included in protected participant detail and the saved snapshot', async () => {
    const detail = await as(owner, () => scalar('SELECT public.get_poll_detail($1) AS result', [poll]));
    const participant = detail.participants.find(p => p.id === participants.member);
    assert.equal(instant(participant.submitted_at), instant(historicalSubmission));
    const snapshot = await as(member, () => scalar('SELECT public.get_availability($1,$2,NULL) AS result', [poll, participants.member]));
    assert.equal(instant(snapshot.submitted_at), instant(historicalSubmission));
    await assert.rejects(as(unrelated, () => scalar('SELECT public.get_poll_detail($1) AS result', [poll])), denied);
  });

  let previous;
  await t.test('comment-only submissions advance the timestamp even when every answer is unchanged', async () => {
    previous = await save([answer(options[0])], 'Updated comment');
    assert.equal(previous.submitted_at, previous.saved_at);
    assert.equal(instant(await submitted(participants.member)), instant(previous.saved_at));
    assert.ok(new Date(previous.submitted_at) >= new Date(historicalSubmission));
  });

  await t.test('removing the newest answer keeps the time of the new submission', async () => {
    const withBoth = await save([answer(options[0]), answer(options[1], 'available')]);
    previous = await save([answer(options[0])]);
    assert.equal(previous.submitted_at, previous.saved_at);
    assert.equal(previous.responses[0].updated_at, withBoth.responses.find(r => r.time_option_id === options[0]).updated_at);
  });

  await t.test('idempotent replay and unchanged saves keep the timestamp', async () => {
    const requestId = randomUUID();
    const first = await save([answer(options[0], 'maybe')], null, { requestId });
    const replay = await save([answer(options[0], 'maybe')], null, { requestId });
    assert.equal(replay.replayed, true);
    assert.equal(replay.submitted_at, first.submitted_at);
    const unchanged = await save([answer(options[0], 'maybe')]);
    assert.equal(unchanged.submitted_at, first.submitted_at);
    previous = unchanged;
  });

  await t.test('conflicts and closed-poll failures cannot change the timestamp', async () => {
    await assert.rejects(save([answer(options[1])], null, { version: -1 }), error => error.code === 'PT409');
    assert.equal(instant(await submitted(participants.member)), instant(previous.submitted_at));
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1", [poll]);
    await assert.rejects(save([answer(options[1])]), denied);
    assert.equal(instant(await submitted(participants.member)), instant(previous.submitted_at));
    await db.query("UPDATE public.polls SET status='active' WHERE id=$1", [poll]);
  });

  await t.test('clearing all availability marks the participant as not submitted', async () => {
    const cleared = await save([]);
    assert.equal(cleared.submitted_at, null);
    assert.equal(await submitted(participants.member), null);
  });

  await t.test('guest submissions receive the same server timestamp', async () => {
    const token = 'a'.repeat(64);
    const guest = await as(null, () => scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result', [poll, 'Guest', token]), 'anon');
    const saved = await save([answer(options[0])], null, { participant: guest.participant.id, token, role: 'anon' });
    assert.equal(saved.submitted_at, saved.saved_at);
    assert.equal(instant(await submitted(guest.participant.id)), instant(saved.saved_at));
    const detail = await as(null, () => scalar('SELECT public.get_poll_detail_as_guest($1,$2) AS result', [guest.participant.id, token]), 'anon');
    assert.equal(detail.participants.find(p => p.id === guest.participant.id).submitted_at, saved.submitted_at);
  });

  await t.test('legacy direct response writes also maintain submission status', async () => {
    const row = await as(member, () => scalar(`INSERT INTO public.availability_responses(participant_id,time_option_id,status)
      VALUES($1,$2,'unavailable') RETURNING id AS result`, [participants.member, options[0]]));
    assert.ok(await submitted(participants.member));
    const before = await submitted(participants.member);
    await as(member, () => db.query("UPDATE public.poll_participants SET comment='Direct legacy comment' WHERE id=$1", [participants.member]));
    assert.ok(await submitted(participants.member) >= before);
    await as(member, () => db.query('DELETE FROM public.availability_responses WHERE id=$1', [row]));
    assert.equal(await submitted(participants.member), null);
  });

  await t.test('private submission state cannot be read or forged directly', async () => {
    for (const role of ['anon', 'authenticated', 'service_role']) {
      assert.equal(await scalar("SELECT has_function_privilege($1,'poll_private.availability_submitted_at(uuid)','EXECUTE') AS result", [role]), false);
    }
    await assert.rejects(as(member, () => scalar('SELECT poll_private.availability_submitted_at($1) AS result', [participants.member])), denied);
    await assert.rejects(as(member, () => db.query('UPDATE private.participant_response_state SET updated_at=now() WHERE participant_id=$1', [participants.member])), denied);
  });
});
