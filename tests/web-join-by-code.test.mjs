import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { participantRow, pollRow, timeOptionRow } from './helpers/web-rows.mjs';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const lib = join(root, 'apps/web/src/lib');
const routes = join(root, 'apps/web/src/routes');

const poll = pollRow({ id: '33333333-3333-4333-8333-333333333333', title: 'Team sync', share_code: 'BFZZ7J' });
const option = timeOptionRow({ id: '44444444-4444-4444-8444-444444444444', poll_id: poll.id });
const member = '11111111-1111-4111-8111-111111111111';
const preview = status => ({ id: poll.id, title: poll.title, description: null, location: null, status, creator_id: '22222222-2222-4222-8222-222222222222', share_code: 'BFZZ7J' });
const joined = participantRow({ id: '55555555-5555-4555-8555-555555555555', poll_id: poll.id, user_id: member });
let sequence = 0;

// Bundle the real store and join logic; only the network client and account store are replaced.
async function fixture(t, { signedIn }) {
  const directory = await mkdtemp(join(tmpdir(), 'web-join-'));
  const key = `__webJoin${++sequence}`;
  const state = { calls: [], supabase: {
    rpc(name, args) {
      const response = (async () => {
        state.calls.push({ name, args: structuredClone(args) });
        return state.handler(name, args);
      })();
      return Object.assign(response, { abortSignal() { return this; } });
    },
    from(table) { throw Error(`Unexpected table ${table}`); },
    removeChannel() {}
  } };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export * from '${lib}/stores/polls.ts'; export * from '${lib}/join-by-code.ts'; export {user} from '${lib}/stores/auth.ts'; export {get} from 'svelte/store';`, resolveDir: join(root, 'apps/web') },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'offline-join', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => {
        const relative = args.path.slice(5);
        return ['supabase', 'stores/auth'].includes(relative) ? { path: relative, namespace: 'fixture' } : { path: join(lib, `${relative}.ts`) };
      });
      b.onResolve({ filter: /\/stores\/auth\.ts$|^\.\/auth$/ }, () => ({ path: 'stores/auth', namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: {
        'supabase': `export const supabase=globalThis.${key}.supabase;`,
        'stores/auth': `import {writable} from 'svelte/store'; export const user=writable(null);`
      }[args.path], loader: 'js', resolveDir: join(root, 'apps/web') }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  actual.user.set(signedIn ? { id: member } : null);
  t.after(async () => { actual.cleanupPollRealtime(); delete globalThis[key]; await rm(directory, { recursive: true, force: true }); });
  return { actual, state };
}

const names = state => state.calls.map(call => call.name);
const memberHandler = status => name => {
  if (name === 'get_poll_by_code') return { data: [preview(status)], error: null };
  if (name === 'join_poll') return { data: { participant: joined, created: true }, error: null };
  throw Error(`Unexpected ${name}`);
};

test('entering a code looks it up and joins before the caller opens the poll', async t => {
  const { actual, state } = await fixture(t, { signedIn: true });
  state.handler = memberHandler('active');
  const outcome = await actual.joinByCode('bfzz7j', { loadPollByCode: actual.loadPollByCode, joinPoll: actual.joinPoll });
  assert.deepEqual(outcome, { ok: true, pollId: poll.id });
  assert.deepEqual(names(state), ['get_poll_by_code', 'join_poll']);
  assert.deepEqual(state.calls[0].args, { code: 'BFZZ7J' });
  assert.deepEqual(state.calls[1].args, { poll_uuid: poll.id });
});

test('an unknown code or a closed or archived poll joins nothing', async t => {
  const { actual, state } = await fixture(t, { signedIn: true });
  const deps = { loadPollByCode: actual.loadPollByCode, joinPoll: actual.joinPoll };
  state.handler = () => ({ data: [], error: null });
  assert.deepEqual(await actual.joinByCode('NOPE00', deps), { ok: false, message: actual.UNKNOWN_CODE_MESSAGE });
  for (const status of ['closed', 'archived', 'draft']) {
    state.handler = memberHandler(status);
    assert.deepEqual(await actual.joinByCode('BFZZ7J', deps), { ok: false, message: actual.CLOSED_POLL_MESSAGE }, status);
  }
  assert.equal(names(state).includes('join_poll'), false);
});

test('join refusals become messages: 42501 means closed, P0003 the participant limit', async t => {
  const { actual, state } = await fixture(t, { signedIn: true });
  const deps = { loadPollByCode: actual.loadPollByCode, joinPoll: actual.joinPoll };
  const refuse = error => { state.handler = name => name === 'get_poll_by_code' ? { data: [preview('active')], error: null } : { data: null, error }; };
  refuse({ code: '42501', message: 'Poll is not accepting participants' });
  assert.deepEqual(await actual.joinByCode('BFZZ7J', deps), { ok: false, message: 'This poll is closed and cannot accept new participants.' });
  refuse({ code: 'P0003', message: 'limit' });
  const full = await actual.joinByCode('BFZZ7J', deps);
  assert.equal(full.ok, false);
  assert.match(full.message, /participant limit/);
});

test('a guest is told the poll is closed only when the server says so', async () => {
  const { joinFailureMessage, CLOSED_POLL_MESSAGE } = await import(pathToFileURL(join(lib, 'join-by-code.ts')));
  const denied = message => ({ code: '42501', message });
  assert.equal(joinFailureMessage(denied('Poll is not accepting participants'), true), CLOSED_POLL_MESSAGE);
  assert.notEqual(joinFailureMessage(denied('Guest access denied'), true), CLOSED_POLL_MESSAGE);
  assert.equal(joinFailureMessage(denied('anything'), false), CLOSED_POLL_MESSAGE);
});

test('the share link carries the code, not the poll id', async () => {
  const { joinPath } = await import(pathToFileURL(join(lib, 'join-by-code.ts')));
  assert.equal(joinPath('BFZZ7J'), '/join/BFZZ7J');
  const detail = await readFile(join(routes, 'polls/[id]/+page.svelte'), 'utf8');
  assert.match(detail, /joinPath\(\$currentPoll\.share_code\)/);
  assert.doesNotMatch(detail, /window\.location\.href/, 'the page address is not shareable: non-members cannot open it');
});

test('a signed-in visitor of a share link joins through join_poll', async t => {
  const { actual, state } = await fixture(t, { signedIn: true });
  state.handler = memberHandler('active');
  const found = await actual.lookUpJoinablePoll('BFZZ7J', { loadPollByCode: actual.loadPollByCode });
  assert.equal(found.ok, true);
  await actual.joinPoll(found.poll.id);
  assert.deepEqual(names(state), ['get_poll_by_code', 'join_poll']);
});

test('a guest joins with a name, keeps the capability, and the poll then loads for them', async t => {
  const { actual, state } = await fixture(t, { signedIn: false });
  const guestParticipant = participantRow({ id: '66666666-6666-4666-8666-666666666666', poll_id: poll.id, anonymous_name: 'Sam' });
  state.handler = (name, args) => {
    if (name === 'get_poll_by_code') return { data: [preview('active')], error: null };
    if (name === 'join_poll_as_guest') return { data: { participant: guestParticipant, created: true, guest_token: args.guest_token }, error: null };
    if (name === 'get_poll_detail_as_guest') return { data: { participant_id: args.participant_uuid, poll, time_options: [option], participants: [guestParticipant], time_option_count: 1, participant_count: 1 }, error: null };
    if (name === 'list_poll_responses_as_guest') return { data: { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null };
    if (name === 'get_availability') return { data: { poll_id: poll.id, participant_id: args.participant_uuid, version: 1, comment: null, responses: [] }, error: null };
    throw Error(`Unexpected ${name}`);
  };
  const outcome = await actual.joinByCode('BFZZ7J', { loadPollByCode: actual.loadPollByCode, joinPoll: actual.joinPoll }, 'Sam');
  assert.deepEqual(outcome, { ok: true, pollId: poll.id });
  assert.deepEqual(names(state), ['get_poll_by_code', 'join_poll_as_guest']);
  assert.equal(state.calls[1].args.display_name, 'Sam');
  assert.equal(names(state).includes('join_poll'), false);
  assert.equal(actual.get(actual.currentGuest).participantId, guestParticipant.id);
  await actual.loadPoll(poll.id);
  assert.equal(names(state).includes('get_poll_detail'), false, 'the member-only detail is never requested');
  assert.equal(names(state).includes('get_poll_detail_as_guest'), true);
  assert.deepEqual(actual.get(actual.currentPoll), poll);
});

test('the join route uses the shared lookup and the guest form requires a name', async () => {
  const route = await readFile(join(routes, 'join/[code]/+page.svelte'), 'utf8');
  assert.match(route, /lookUpJoinablePoll/);
  assert.match(route, /joinPoll\(id, name\)/);
  assert.doesNotMatch(route, /href="\/auth"/, 'the auth page cannot return to the link, so it must not be offered');
  assert.match(route, /<input[^>]*bind:value=\{guestName\}[^>]*required/);
  assert.match(route, /goto\(`\/polls\/\$\{id\}`/);
});
