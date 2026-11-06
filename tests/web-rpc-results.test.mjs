import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { PGlite } from '@electric-sql/pglite';
import { randomBytes, randomUUID } from 'node:crypto';
import { participantRow, pollRow, responseRow, timeOptionRow } from './helpers/web-rows.mjs';
import { bootstrapCreationDatabase, creationPayload } from './helpers/creation-database.mjs';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));

// The module imports only types, so it bundles without the app's aliases.
async function bundledChecks(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-rpc-results-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const output = join(directory, 'bundle.mjs');
  await build({ entryPoints: [join(root, 'apps/web/src/lib/rpc-results.ts')], outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {} });
  return import(pathToFileURL(output));
}

// A value no column accepts: not a string, number, boolean or null.
const wrong = { unexpected: true };

test('row checks accept complete rows and reject each missing or mistyped column', async t => {
  const actual = await bundledChecks(t);
  const rows = { isPoll: pollRow(), isPollTimeOption: timeOptionRow(), isPollParticipant: participantRow(), isAvailabilityResponse: responseRow() };
  for (const [name, row] of Object.entries(rows)) {
    const isRow = actual[name];
    assert.equal(isRow(row), true, name);
    assert.equal(isRow({ ...row, added_by_a_later_migration: 1 }), true, `${name} ignores extra keys`);
    for (const column of Object.keys(row)) {
      const { [column]: _, ...missing } = row;
      assert.equal(isRow(missing), false, `${name} without ${column}`);
      assert.equal(isRow({ ...row, [column]: wrong }), false, `${name}.${column} mistyped`);
    }
    assert.equal(isRow(null), false);
    assert.equal(isRow([row]), false);
  }
});

test('column checks enforce nullability, enums, integers and instants', async t => {
  const { isPoll, isPollParticipant, isAvailabilityResponse } = await bundledChecks(t);
  assert.equal(isPoll(pollRow({ description: null, closes_at: null })), true);
  for (const closes_at of ['2026-12-01T00:00:00+00:00', '2026-12-01T00:00:00.123456+05:30', '10000-01-01T00:00:00+00:00', '0001-01-01T00:00:00+00:00 BC']) {
    assert.equal(isPoll(pollRow({ closes_at })), true, closes_at);
  }
  for (const fields of [{ title: null }, { status: 'deleted' }, { max_participants: 1.5 }, { max_participants: '10' },
    { closes_at: 'next week' }, { closes_at: '2026-12-01 00:00:00+00' }, { closes_at: '2026-12-01T00:00:00' }, { created_at: null }, { is_premium: 'true' }]) {
    assert.equal(isPoll(pollRow(fields)), false, JSON.stringify(fields));
  }
  assert.equal(isAvailabilityResponse(responseRow({ status: 'busy' })), false);
  assert.equal(isPollParticipant(participantRow({ profiles: null })), true);
  assert.equal(isPollParticipant(participantRow({ profiles: { display_name: null } })), true);
  assert.equal(isPollParticipant(participantRow({ profiles: { display_name: 3 } })), false);
  assert.equal(isPollParticipant(participantRow({ profiles: {} })), false);
});

test('result checks cover nested rows and their own fields', async t => {
  const actual = await bundledChecks(t);
  const poll = pollRow(), option = timeOptionRow(), participant = participantRow();
  const creation = { poll, time_options: [option], redeemed_pass_id: null, entitlement: 'event_pass', replayed: true };
  assert.equal(actual.isCreationResult(creation), true);
  assert.equal(actual.isCreationResult({ ...creation, entitlement: 'enterprise' }), true, 'an unknown tier still confirms a committed creation');
  assert.equal(actual.isCreationResult({ ...creation, entitlement: null }), false);
  assert.equal(actual.isCreationResult({ ...creation, time_options: [{ ...option, is_all_day: null }] }), false);

  const detail = { poll, time_options: [option], participants: [participant], time_option_count: 1, participant_count: 1 };
  assert.equal(actual.isPollDetail(detail), true);
  assert.equal(actual.isPollDetail({ ...detail, participants: [{ ...participant, user_id: 7 }] }), false);
  assert.equal(actual.isPollDetail({ ...detail, participant_count: null }), false);

  const summary = { poll, role: 'owner', participant_count: 0, time_option_count: 1, earliest_start: option.start_time, latest_start: null };
  assert.equal(actual.isSummaryRow(summary), true);
  assert.equal(actual.isSummaryRow({ ...summary, role: 'admin' }), false);

  assert.equal(actual.isJoinResult({ participant, created: false }), true);
  assert.equal(actual.isJoinResult({ participant }), false);
  assert.equal(actual.isGuestJoinResult({ participant, created: true, guest_token: 'token' }), true);
  assert.equal(actual.isGuestJoinResult({ participant, created: true }), false);

  const snapshot = { participant_id: participant.id, poll_id: poll.id, version: 0, comment: null,
    responses: [{ id: 'r', time_option_id: option.id, status: 'maybe', note: null, updated_at: option.created_at }] };
  assert.equal(actual.isAvailabilitySnapshot(snapshot), true);
  assert.equal(actual.isAvailabilitySnapshot({ ...snapshot, saved_at: '2026-11-01T00:00:00Z', replayed: false }), true);
  assert.equal(actual.isAvailabilitySnapshot({ ...snapshot, saved_at: 'never' }), false);
  assert.equal(actual.isAvailabilitySnapshot({ ...snapshot, version: '1' }), false);
  assert.equal(actual.isAvailabilitySnapshot({ ...snapshot, responses: [{ ...snapshot.responses[0], note: undefined }] }), false);
});

// The web's result checks against what the migrations actually return: each
// function the stores call runs in PGlite, and its json must pass unchanged.
test('database function results pass the web result checks', async t => {
  const checks = await bundledChecks(t);

  const db = new PGlite();
  t.after(() => db.close());
  await bootstrapCreationDatabase(db);
  const user = async () => {
    const id = randomUUID();
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)', [id, `${id}@test.invalid`]);
    return id;
  };
  const call = async (caller, sql, params) => {
    const role = caller ? 'authenticated' : 'anon';
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [caller ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: caller })]);
    await db.exec(`SET ROLE ${role}`);
    try { return (await db.query(`SELECT ${sql} AS result`, params)).rows[0].result; } finally { await db.exec('RESET ROLE'); }
  };
  const expectValid = (check, value, label) => assert.equal(checks[check](value), true, `${label}: ${JSON.stringify(value)}`);

  const owner = await user(), member = await user();
  assert.equal((await db.query('UPDATE public.profiles SET display_name=$2 WHERE id=$1', [member, 'Member'])).affectedRows, 1);
  const payload = creationPayload({ description: 'Described', location: 'Room 1', closes_at: '2027-10-30T12:00:00Z',
    time_options: [...creationPayload().time_options, { start_time: '2027-11-03T05:00:00Z', end_time: '2027-11-04T05:00:00Z', is_all_day: true }] });
  const operation = randomUUID();
  const created = await call(owner, 'public.create_poll($1,$2)', [operation, JSON.stringify(payload)]);
  expectValid('isCreationResult', created, 'create_poll');
  expectValid('isCreationResult', await call(owner, 'public.create_poll($1,$2)', [operation, JSON.stringify(payload)]), 'create_poll replay');
  const pollId = created.poll.id, [option] = created.time_options;

  const joined = await call(member, 'public.join_poll($1)', [pollId]);
  expectValid('isJoinResult', joined, 'join_poll');
  const token = randomBytes(32).toString('hex');
  const guest = await call(null, 'public.join_poll_as_guest($1,$2,$3,$4)', [pollId, 'Guest', 'guest@test.invalid', token]);
  expectValid('isGuestJoinResult', guest, 'join_poll_as_guest');

  const responses = JSON.stringify([{ time_option_id: option.id, status: 'maybe', note: 'Maybe' }]);
  expectValid('isAvailabilitySnapshot', await call(member, 'public.save_availability($1,$2,$3,$4,$5,$6)',
    [pollId, randomUUID(), responses, 'Member comment', 0, joined.participant.id]), 'save_availability');
  expectValid('isAvailabilitySnapshot', await call(null, 'public.save_availability($1,$2,$3,$4,$5,$6,$7)',
    [pollId, randomUUID(), responses, null, 0, guest.participant.id, token]), 'guest save_availability');
  expectValid('isAvailabilitySnapshot', await call(member, 'public.get_availability($1,$2)', [pollId, joined.participant.id]), 'get_availability');

  const detail = await call(member, 'public.get_poll_detail($1)', [pollId]);
  expectValid('isPollDetail', detail, 'get_poll_detail');
  assert.ok(detail.participants.some(participant => participant.profiles?.display_name === 'Member'), 'detail embeds the profile name');
  assert.ok(detail.participants.some(participant => participant.profiles === null), 'a guest has no profile');
  expectValid('isPollDetailAsGuest', await call(null, 'public.get_poll_detail_as_guest($1,$2)', [guest.participant.id, token]), 'get_poll_detail_as_guest');
  const guestPage = await call(null, 'public.list_poll_responses_as_guest($1,$2,$3,$4)', [guest.participant.id, token, 10, null]);
  assert.equal(guestPage.items.length, 2);
  for (const item of guestPage.items) expectValid('isAvailabilityResponse', item, 'list_poll_responses_as_guest item');

  const page = await call(member, 'public.list_poll_responses($1,$2,$3)', [pollId, 10, null]);
  assert.equal(page.items.length, 2);
  for (const item of page.items) expectValid('isAvailabilityResponse', item, 'list_poll_responses item');
  for (const [caller, role] of [[owner, 'owner'], [member, 'member']]) {
    const summaries = await call(caller, 'public.list_poll_summaries($1,$2,$3)', [role, 10, null]);
    assert.equal(summaries.items.length, 1);
    expectValid('isSummaryRow', summaries.items[0], `list_poll_summaries ${role}`);
  }

  // create_poll bounds no year, and Postgres writes five-digit years as they are.
  const farOwner = await user();
  const far = await call(farOwner, 'public.create_poll($1,$2)', [randomUUID(), JSON.stringify(creationPayload({ closes_at: '10000-01-01T00:00:00Z' }))]);
  assert.equal(far.poll.closes_at, '10000-01-01T00:00:00+00:00');
  expectValid('isCreationResult', far, 'create_poll closing in year 10000');
  expectValid('isSummaryRow', (await call(farOwner, 'public.list_poll_summaries($1,$2,$3)', ['owner', 10, null])).items[0], 'list_poll_summaries year 10000');

  const finalized = await call(owner, 'public.finalize_poll($1,$2)', [pollId, option.id]);
  expectValid('isPoll', finalized, 'finalize_poll');
  assert.equal(finalized.status, 'closed');
});
