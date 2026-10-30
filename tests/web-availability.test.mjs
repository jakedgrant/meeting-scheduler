import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const { compile } = requireWeb('svelte/compiler');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const lib = join(root, 'apps/web/src/lib');
const pollId = '11111111-1111-4111-8111-111111111111';
const otherPollId = '11111111-1111-4111-8111-111111111112';
const participantId = '22222222-2222-4222-8222-222222222222';
const memberId = '33333333-3333-4333-8333-333333333333';
const optionId = '44444444-4444-4444-8444-444444444444';
const secondOption = '44444444-4444-4444-8444-444444444445';
const poll = { id: pollId, title: 'Planning', creator_id: memberId, status: 'active', closes_at: null, share_code: 'TEST', timezone: 'UTC' };
const option = { id: optionId, poll_id: pollId, start_time: '2026-11-01T12:00:00Z', end_time: '2026-11-01T13:00:00Z', is_all_day: false };
const snapshot = (overrides = {}) => ({ participant_id: participantId, poll_id: pollId, version: 1, comment: 'Saved comment', responses: [], ...overrides });
const response = (status = 'available', overrides = {}) => ({ id: 'response', time_option_id: optionId, status, note: 'Keep my note', updated_at: '2026-10-23T00:00:00Z', ...overrides });
const storage = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key), values };
};
const failingStorage = { getItem() { throw Error('SecurityError'); }, setItem() { throw Error('QuotaExceeded'); }, removeItem() { throw Error('SecurityError'); } };
let fixtureSequence = 0;

// Bundle the actual store, editor, and poll page. Only the remote client and
// unrelated platform integrations are replaced; Svelte's stores/rendering are real.
async function fixture(t, { member = false, disk = storage() } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'web-availability-'));
  const key = `__webAvailability${++fixtureSequence}`;
  const state = { calls: [], version: snapshot(), participant: { id: participantId, poll_id: pollId, user_id: member ? memberId : null, anonymous_name: 'Guest', comment: 'Saved comment' } };
  globalThis[key] = state;
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'localStorage', { value: disk, writable: true, configurable: true });
  state.supabase = {
    rpc(name, args) {
      const response = (async () => {
      state.calls.push({ name, args: structuredClone(args) });
      if (state.handler) {
        const result = await state.handler(name, args);
        if (result !== undefined) return result;
      }
      if (name === 'join_poll_as_guest') return { data: { participant: state.participant, guest_token: args.guest_token }, error: null };
      if (name === 'join_poll') return { data: { participant: state.participant, created: false }, error: null };
      if (name === 'get_guest_poll_detail') return { data: { participant_id: participantId, poll, time_options: [option], participants: [state.participant], responses: [] }, error: null };
      if (name === 'get_availability') return { data: state.version, error: null };
      if (name === 'get_poll_detail') return { data: { poll, time_options: [option], participants: [state.participant], time_option_count: 1, participant_count: 1 }, error: null };
      if (name === 'list_poll_responses') return { data: { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null };
      throw Error(`Unexpected RPC ${name}`);
      })();
      return Object.assign(response, { abortSignal() { return this; } });
    },
    from(table) {
      const data = table === 'polls' ? poll : table === 'poll_time_options' ? [option] : table === 'poll_participants' ? [state.participant] : [];
      return { abortSignal() { return this; }, select() { return this; }, eq() { return this; }, in() { return this; }, order() { return this; }, single: async () => ({ data, error: null }), then(resolve) { return Promise.resolve({ data, error: null }).then(resolve); } };
    },
    channel() { return { on() { return this; }, subscribe() { return this; } }; }, removeChannel() {}
  };
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export * from '${lib}/stores/polls.ts'; export {createAvailabilityEditor} from '${lib}/availability-editor.ts'; export {createPollPageSession} from '${lib}/poll-page-session.ts'; export {user} from '${lib}/stores/auth.ts'; export {get} from 'svelte/store'; export {render} from 'svelte/server'; export {default as Page} from '${root}/apps/web/src/routes/polls/[id]/+page.svelte';`, resolveDir: join(root, 'apps/web') },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'offline-fixture', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => {
        const relative = args.path.slice(5);
        if (['supabase', 'stores/auth', 'stores/calendar', 'availability-editor'].includes(relative)) return { path: relative, namespace: 'fixture' };
        return { path: join(lib, `${relative}.ts`) };
      });
      b.onResolve({ filter: /\/stores\/auth\.ts$|^\.\/auth$/ }, () => ({ path: 'stores/auth', namespace: 'fixture' }));
      b.onResolve({ filter: /^\$app\// }, args => ({ path: args.path, namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => {
        const reference = `globalThis.${key}`;
        const prefix = `import {writable} from 'svelte/store';`;
        const contents = {
          'supabase': `export const supabase=${reference}.supabase;`,
          'stores/auth': `${prefix} export const user=writable(null);`,
          'stores/calendar': `${prefix} export const calendarEnabled=writable(false),calendarConflicts=writable(new Set()),calendarStatusError=writable(null); export async function checkCalendarConflicts(){}`,
          'availability-editor': `import {createAvailabilityEditor as real} from '${lib}/availability-editor.ts'; export const createAvailabilityEditor=commands=>${reference}.editor ?? real(commands);`,
          '$app/stores': `${prefix} export const page=writable({params:{id:'${pollId}'}});`,
          '$app/navigation': 'export function goto(){}'
        }[args.path];
        return { contents, loader: 'js', resolveDir: join(root, 'apps/web') };
      });
      b.onLoad({ filter: /\.svelte$/ }, async args => ({ contents: compile(await readFile(args.path, 'utf8'), { filename: args.path, generate: 'server' }).js.code, loader: 'js', resolveDir: join(root, 'apps/web') }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  if (member) actual.user.set({ id: memberId });
  t.after(async () => { actual.cleanupPollRealtime(); if (previousStorage) Object.defineProperty(globalThis, 'localStorage', previousStorage); else delete globalThis.localStorage; delete globalThis[key]; await rm(directory, { recursive: true, force: true }); });
  const primePage = editor => {
    state.editor = editor;
    actual.currentPoll.set(poll);
    actual.currentPollTimeOptions.set([option]);
    actual.currentPollParticipants.set([state.participant]);
    actual.currentGuest.set(member ? null : { participantId, token: 'ab'.repeat(32) });
  };
  return { actual, state, disk, primePage };
}

test('guest join -> immediate reload and navigation retain per-poll capability with unavailable storage', async t => {
  const { actual, state } = await fixture(t, { disk: failingStorage });
  await actual.joinPoll(pollId, 'Guest');
  const capability = actual.get(actual.currentGuest);
  assert.match(capability.token, /^[a-f0-9]{64}$/);
  await actual.loadPoll(pollId);
  assert.deepEqual(actual.get(actual.currentGuest), capability);
  assert.equal(actual.get(actual.currentAvailability).participant_id, participantId);
  actual.cleanupPollRealtime();
  await actual.loadPoll(pollId);
  assert.deepEqual(actual.get(actual.currentGuest), capability);
  assert.equal(state.calls.filter(call => call.name === 'get_guest_poll_detail').length, 2);
  await actual.joinPoll(otherPollId, 'Another guest').catch(() => {});
  assert.notEqual(state.calls.filter(call => call.name === 'join_poll_as_guest')[1].args.guest_token, capability.token);
});

test('lost guest join response retries the same CSPRNG token and participant, also with failed storage', async t => {
  const { actual, state } = await fixture(t, { disk: failingStorage });
  let token;
  state.handler = (name, args) => {
    if (name !== 'join_poll_as_guest') return;
    if (!token) { token = args.guest_token; throw Error('Reply lost after commit'); }
    assert.equal(args.guest_token, token);
    return { data: { participant: state.participant, guest_token: token, created: false }, error: null };
  };
  await assert.rejects(actual.joinPoll(pollId, 'Guest'));
  const joined = await actual.joinPoll(pollId, 'Guest');
  assert.equal(joined.id, participantId);
  assert.equal(actual.get(actual.currentGuest).token, token);
  assert.equal(state.calls.length, 2);
});

test('pending guest join token survives a page reload when storage works', async t => {
  const disk = storage();
  const first = await fixture(t, { disk });
  first.state.handler = () => { throw Error('Lost response'); };
  await assert.rejects(first.actual.joinPoll(pollId, 'Guest'));
  const token = first.state.calls[0].args.guest_token;
  const second = await fixture(t, { disk });
  await second.actual.joinPoll(pollId, 'Guest');
  assert.equal(second.state.calls[0].args.guest_token, token);
  assert.equal([...disk.values.keys()].some(key => key.includes('guest-pending')), false);
});

for (const member of [false, true]) {
  const identity = member ? 'member' : 'guest';
  test(`${identity} failed/lost save retains draft and saved rows, then retries one command with same ID`, async t => {
    const { actual, state, primePage } = await fixture(t, { member });
    if (!member) await actual.joinPoll(pollId, 'Guest');
    await actual.loadPoll(pollId);
    const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
    editor.initialize(actual.get(actual.currentAvailability));
    editor.setResponse(optionId, 'maybe');
    editor.setComment('My draft');
    let firstRequest;
    state.handler = (name, args) => {
      if (name !== 'save_availability') return;
      if (!firstRequest) { firstRequest = structuredClone(args); return { data: null, error: { code: 'NETWORK', message: 'Reply lost' } }; }
      assert.deepEqual(args, firstRequest);
      return { data: snapshot({ version: 4, comment: 'Persisted normalized comment', responses: [response('maybe')], replayed: true }), error: null };
    };
    await editor.save();
    assert.equal(actual.get(editor).dirty, true);
    assert.equal(actual.get(editor).responses[optionId].status, 'maybe');
    assert.equal(actual.get(editor).comment, 'My draft');
    assert.equal(actual.get(editor).saved, false);
    assert.equal(actual.get(actual.currentAvailability).comment, 'Saved comment');
    assert.equal(actual.get(actual.currentPollResponses).length, 0);
    editor.initialize(snapshot({ version: 3, comment: 'Realtime update' }));
    assert.equal(actual.get(editor).comment, 'My draft', 'refresh cannot replace dirty draft');
    primePage(editor);
    const failedHtml = actual.render(actual.Page).body;
    assert.match(failedHtml, /Your draft is kept/);
    assert.match(failedHtml, /Retry Save/);
    assert.doesNotMatch(failedHtml, /Responses saved\./);
    assert.doesNotMatch(failedHtml, /can.t be saved as a guest/);
    assert.match(failedHtml, /class="response-btn available/);
    primePage(editor);
    await editor.save();
    const saved = actual.get(editor);
    assert.equal(saved.saved, true);
    assert.equal(saved.dirty, false);
    assert.equal(saved.comment, 'Persisted normalized comment');
    assert.equal(actual.get(actual.currentPollResponses)[0].note, 'Keep my note');
    assert.equal(state.calls.filter(call => call.name === 'save_availability').length, 2);
    assert.equal(firstRequest.participant_uuid, participantId);
    assert.equal(Object.hasOwn(firstRequest, 'guest_token'), !member);
    assert.deepEqual(firstRequest.responses, [{ time_option_id: optionId, status: 'maybe', note: null }]);
    primePage(editor);
    assert.match(actual.render(actual.Page).body, /Responses saved\./);
  });

  test(`${identity} version conflict keeps the draft and requires explicit reload and new operation ID`, async t => {
    const { actual, state, primePage } = await fixture(t, { member });
    if (!member) await actual.joinPoll(pollId, 'Guest');
    await actual.loadPoll(pollId);
    const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
    editor.initialize(actual.get(actual.currentAvailability));
    editor.setResponse(optionId, 'available');
    editor.setComment('Keep this draft');
    const requests = [];
    state.handler = (name, args) => {
      if (name !== 'save_availability') return;
      requests.push(args);
      return requests.length === 1
        ? { data: null, error: { code: 'PT409', message: 'Responses changed since the expected version', details: 'current_version=7' } }
        : { data: snapshot({ version: 8, comment: args.comment, responses: [response('available')] }), error: null };
    };
    await editor.save();
    assert.equal(actual.get(editor).conflict, true);
    await editor.save();
    assert.equal(requests.length, 1, 'no automatic last-write-wins retry');
    primePage(editor);
    assert.match(actual.render(actual.Page).body, /Reload saved version and keep my draft/);
    state.version = snapshot({ version: 7, comment: 'Other device comment', responses: [response('unavailable')] });
    await editor.reloadAfterConflict();
    assert.equal(actual.get(editor).comment, 'Keep this draft');
    assert.equal(actual.get(editor).snapshot.version, 7);
    assert.equal(actual.get(editor).snapshot.comment, 'Other device comment');
    primePage(editor);
    await editor.save();
    assert.notEqual(requests[1].request_id, requests[0].request_id);
    assert.equal(requests[1].expected_version, 7);
    assert.equal(actual.get(editor).saved, true);
  });
}

test('changed draft gets new request ID; complete save preserves notes and applies empty server response set', async t => {
  const { actual, state } = await fixture(t, { member: true });
  state.version = snapshot({ responses: [response(), response('unavailable', { id: 'second', time_option_id: secondOption, note: null })] });
  await actual.loadPoll(pollId);
  const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
  editor.initialize(actual.get(actual.currentAvailability));
  editor.setResponse(optionId, 'maybe');
  const requests = [];
  state.handler = (name, args) => {
    if (name !== 'save_availability') return;
    requests.push(args);
    return requests.length === 1 ? { error: { message: 'Failed' } } : { data: snapshot({ version: 9, comment: null, responses: [] }) };
  };
  await editor.save();
  editor.setComment('Changed logical save');
  await editor.save();
  assert.notEqual(requests[0].request_id, requests[1].request_id);
  assert.equal(requests[1].responses.length, 2);
  assert.equal(requests[1].responses.find(value => value.time_option_id === optionId).note, 'Keep my note');
  assert.deepEqual(actual.get(editor).responses, {});
  assert.deepEqual(actual.get(actual.currentPollResponses), []);
});

test('revoked guest capability shows lost access, clears capability, and retains failed draft', async t => {
  const { actual, state } = await fixture(t);
  await actual.joinPoll(pollId, 'Guest');
  await actual.loadPoll(pollId);
  const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
  editor.initialize(actual.get(actual.currentAvailability));
  editor.setComment('Unsent draft');
  state.handler = name => name === 'save_availability' ? { error: { code: '42501', message: 'Guest access denied' } } : undefined;
  await editor.save();
  assert.equal(actual.get(actual.currentGuest), null);
  assert.match(actual.get(actual.guestNotice), /Join again/);
  assert.equal(actual.get(editor).comment, 'Unsent draft');
  assert.equal(actual.get(editor).saved, false);
});

test('member join and finalization use idempotent commands and returned poll row', async t => {
  const { actual, state } = await fixture(t, { member: true });
  assert.equal((await actual.joinPoll(pollId)).id, participantId);
  await actual.loadPoll(pollId);
  const finalized = { ...poll, status: 'closed', selected_start_time: option.start_time, selected_end_time: option.end_time };
  state.handler = name => name === 'finalize_poll' ? { data: finalized } : undefined;
  await actual.setSelectedFinalDate(pollId, optionId);
  assert.deepEqual(actual.get(actual.currentPoll), finalized);
  assert.deepEqual(state.calls.find(call => call.name === 'finalize_poll').args, { poll_uuid: pollId, time_option_uuid: optionId });
  assert.equal(state.calls[0].name, 'join_poll');
});

test('account transition discards an in-flight save result and its editor state', async t => {
  const { actual, state } = await fixture(t, { member: true });
  await actual.loadPoll(pollId);
  const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
  editor.initialize(actual.get(actual.currentAvailability));
  editor.setComment('Account A draft');
  let complete;
  state.handler = name => name === 'save_availability' ? new Promise(resolve => { complete = resolve; }) : undefined;
  const saving = editor.save();
  actual.user.set(null);
  editor.initialize(actual.get(actual.currentAvailability));
  actual.user.set({ id: 'another-account' });
  complete({ data: snapshot({ version: 5, comment: 'Account A saved' }) });
  await saving;
  assert.equal(actual.get(actual.currentAvailability), null);
  assert.equal(actual.get(actual.currentPoll), null);
  assert.equal(actual.get(editor).snapshot, null);
  assert.equal(actual.get(editor).comment, '');
});


test('closed/expired poll hides response controls and load failure offers a retry', async t => {
  const { actual, primePage } = await fixture(t, { member: true });
  const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
  editor.initialize(snapshot());
  for (const closed of [{ ...poll, status: 'closed' }, { ...poll, closes_at: '2020-01-01T00:00:00Z' }]) {
    primePage(editor);
    actual.currentPoll.set(closed);
    const html = actual.render(actual.Page).body;
    assert.doesNotMatch(html, /class="response-btn available/);
    assert.doesNotMatch(html, /Save Responses/);
    assert.match(html, /no longer accepting responses/);
  }
  primePage(editor);
  actual.availabilityLoadError.set('Could not load your saved responses. Retry before editing.');
  const html = actual.render(actual.Page).body;
  assert.match(html, /Retry loading responses/);
  assert.doesNotMatch(html, /class="response-btn available/);
  actual.availabilityLoadError.set(null);
  actual.pollRefreshError.set('Displayed results may be out of date.');
  const stale = actual.render(actual.Page).body;
  assert.match(stale, /Displayed results may be out of date/);
  assert.match(stale, /Retry refreshing poll/);
  assert.doesNotMatch(stale, /class="response-btn available/);
  assert.doesNotMatch(stale, /Save Responses/);
});

test('failed conflict reload keeps the conflict and cannot send an unsafe retry', async t => {
  const { actual, state } = await fixture(t, { member: true });
  await actual.loadPoll(pollId);
  const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
  editor.initialize(actual.get(actual.currentAvailability));
  editor.setComment('Preserved');
  state.handler = name => name === 'save_availability'
    ? { error: { code: 'PT409' } } : name === 'get_availability' ? { error: { message: 'Offline' } } : undefined;
  await editor.save();
  await editor.reloadAfterConflict();
  await editor.save();
  assert.equal(actual.get(editor).conflict, true);
  assert.equal(actual.get(editor).comment, 'Preserved');
  assert.equal(state.calls.filter(call => call.name === 'save_availability').length, 1);
});


for (const member of [false, true]) {
  test(`${member ? 'member' : 'guest'} same-value edits preserve failed save request ID`, async t => {
    const { actual, state } = await fixture(t, { member });
    if (!member) await actual.joinPoll(pollId, 'Guest');
    await actual.loadPoll(pollId);
    const editor = actual.createAvailabilityEditor({ save: actual.saveAvailability, load: actual.loadAvailability });
    editor.initialize(actual.get(actual.currentAvailability));
    editor.setResponse(optionId, 'maybe');
    editor.setComment('Draft');
    const requests = [];
    state.handler = (name, args) => {
      if (name !== 'save_availability') return;
      requests.push(structuredClone(args));
      return requests.length === 1 ? { error: { message: 'Lost committed reply' } }
        : { data: snapshot({ version: 3, comment: 'Draft', responses: [response('maybe')], replayed: true }) };
    };
    await editor.save();
    editor.setResponse(optionId, 'maybe');
    editor.setComment('Draft');
    await editor.save();
    assert.deepEqual(requests[1], requests[0]);
    assert.equal(actual.get(editor).saved, true);
  });
}

for (const boundary of ['destroy', 'route', 'account']) {
  test(`late guest join after ${boundary} cannot restore detail or restart its page reload`, async t => {
    const { actual, state } = await fixture(t);
    const pageSession = actual.createPollPageSession();
    pageSession.activate();
    let complete;
    state.handler = (name, args) => name === 'join_poll_as_guest'
      ? new Promise(resolve => { complete = () => resolve({ data: { participant: state.participant, guest_token: args.guest_token } }); })
      : undefined;
    let reloads = 0;
    const joining = pageSession.joinAndReload(
      () => actual.joinPoll(pollId, 'Guest'),
      async () => { reloads++; await actual.loadPoll(pollId); }
    );
    actual.cleanupPollRealtime();
    if (boundary === 'destroy') pageSession.invalidate();
    else pageSession.activate();
    if (boundary === 'route') actual.currentPoll.set({ ...poll, id: otherPollId });
    if (boundary === 'account') actual.user.set({ id: memberId });
    complete();
    await joining;
    assert.equal(reloads, 0);
    assert.equal(actual.get(actual.currentGuest), null);
    assert.equal(actual.get(actual.currentAvailability), null);
    assert.equal(state.calls.some(call => call.name === 'get_guest_poll_detail'), false);
    assert.equal(actual.get(actual.currentPoll)?.id ?? null, boundary === 'route' ? otherPollId : null);
  });
}

for (const command of ['get_availability', 'save_availability']) {
  test(`stale denied ${command} cannot erase a newer guest capability`, async t => {
    const { actual, state } = await fixture(t);
    await actual.joinPoll(pollId, 'Guest');
    await actual.loadPoll(pollId);
    const oldCapability = actual.get(actual.currentGuest);
    let complete;
    state.handler = name => name === command
      ? new Promise(resolve => { complete = () => resolve({ error: { code: '42501', message: 'Guest access denied' } }); })
      : undefined;
    const pending = (command === 'get_availability'
      ? actual.loadAvailability(pollId, participantId)
      : actual.saveAvailability({ pollId, participantId, requestId: crypto.randomUUID(), expectedVersion: 1, responses: [], comment: 'Old guest' }))
      .catch(error => error);
    actual.cleanupPollRealtime();
    // A current detail request detects rotation, then the user joins again.
    state.handler = name => name === 'get_guest_poll_detail' ? { error: { code: '42501', message: 'Guest access denied' } } : undefined;
    await actual.loadPoll(pollId);
    state.handler = undefined;
    await actual.joinPoll(pollId, 'Guest again');
    await actual.loadPoll(pollId);
    const newCapability = actual.get(actual.currentGuest);
    assert.notEqual(newCapability.token, oldCapability.token);
    complete();
    await pending;
    assert.deepEqual(actual.get(actual.currentGuest), newCapability);
    await actual.loadPoll(pollId);
    assert.deepEqual(actual.get(actual.currentGuest), newCapability);
    assert.equal(actual.get(actual.guestNotice), null);
  });
}


test('late successful join cannot replace a capability acquired after revocation', async t => {
  const { actual, state } = await fixture(t);
  await actual.joinPoll(pollId, 'Guest');
  await actual.loadPoll(pollId);
  const oldCapability = actual.get(actual.currentGuest);
  let complete;
  state.handler = (name, args) => name === 'join_poll_as_guest'
    ? new Promise(resolve => { complete = () => resolve({ data: { participant: state.participant, guest_token: args.guest_token } }); })
    : undefined;
  const oldJoin = actual.joinPoll(pollId, 'Retry guest');
  actual.cleanupPollRealtime();
  state.handler = name => name === 'get_guest_poll_detail' ? { error: { code: '42501', message: 'Guest access denied' } } : undefined;
  await actual.loadPoll(pollId);
  state.handler = undefined;
  await actual.joinPoll(pollId, 'Guest again');
  const newCapability = actual.get(actual.currentGuest);
  assert.notEqual(newCapability.token, oldCapability.token);
  complete();
  await oldJoin;
  assert.deepEqual(actual.get(actual.currentGuest), newCapability);
  await actual.loadPoll(pollId);
  assert.deepEqual(actual.get(actual.currentGuest), newCapability);
});
