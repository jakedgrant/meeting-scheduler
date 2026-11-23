import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { pollRow, timeOptionRow, participantRow } from './helpers/web-rows.mjs';

const web = fileURLToPath(new URL('../apps/web/', import.meta.url));
const lib = join(web, 'src/lib');
const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const original = pollRow({ creator_id: owner, title: 'Planning', description: 'Agenda', location: 'Room',
  timezone: 'America/Chicago', closes_at: '2020-01-01T00:00:00.123456Z' });
const option = timeOptionRow({ poll_id: original.id });
const member = participantRow({ poll_id: original.id, user_id: owner });
const snapshot = { participant_id: member.id, poll_id: original.id, version: 3, comment: 'Saved', responses: [] };
const detail = poll => ({ poll, time_options: [option], participants: [member], time_option_count: 1, participant_count: 1 });
const deferred = () => { let resolve; const promise = new Promise(yes => { resolve = yes; }); return { promise, resolve }; };
let sequence = 0;

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-poll-edit-'));
  const key = `__pollEdit${++sequence}`;
  const state = { patches: [], rpcCalls: [], refresh: null, saved: { ...original, title: 'Updated' } };
  state.rpc = (name, args) => ({ data: name === 'get_poll_detail' ? detail(original)
    : name === 'get_availability' ? snapshot
    : name === 'list_poll_summaries' ? { items: [], has_more: false, next_cursor: null, total_count: 0 }
    : { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null });
  state.supabase = {
    rpc(name, args) {
      state.rpcCalls.push({ name, args });
      return Object.assign(Promise.resolve().then(() => state.rpc(name, args)), { abortSignal() { return this; } });
    },
    from(table) {
      const request = { table, filters: {}, fields: null, signal: null };
      return {
        update(fields) { request.fields = fields; return this; },
        eq(name, value) { request.filters[name] = value; return this; },
        select() { return this; }, single() { return this; },
        abortSignal(signal) { request.signal = signal; return this; },
        then(yes, no) {
          state.patches.push(request);
          return Promise.resolve().then(() => state.patch?.(request) ?? { data: state.saved, error: null }).then(yes, no);
        }
      };
    }
  };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({ stdin: { contents: `export * from '${lib}/stores/polls.ts'; export * from '${lib}/poll-edit.ts'; export * from '${lib}/session-scope.ts'; export {createAvailabilityEditor} from '${lib}/availability-editor.ts'; export {user} from '${lib}/stores/auth.ts'; export {get} from 'svelte/store';`, resolveDir: web },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'poll-edit-transport', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => {
        const name = args.path.slice(5);
        return ['supabase', 'stores/auth', 'poll-refresh'].includes(name)
          ? { path: name, namespace: 'fixture' } : { path: join(lib, `${name}.ts`) };
      });
      b.onResolve({ filter: /\/stores\/auth\.ts$|^\.\/auth$/ }, () => ({ path: 'stores/auth', namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: {
        supabase: `export const supabase=globalThis.${key}.supabase;`,
        'stores/auth': `import {writable} from 'svelte/store'; export const user=writable(null);`,
        'poll-refresh': `export function startPollRefresh(refresh){globalThis.${key}.refresh=refresh;return {stop(){},wake(){return refresh();}};}`
      }[args.path], loader: 'js', resolveDir: web }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  actual.user.set({ id: owner }); actual.transitionSession(owner);
  await actual.loadPoll(original.id);
  t.after(async () => { actual.cleanupPollRealtime(); delete globalThis[key]; await rm(directory, { recursive: true, force: true }); });
  return { actual, state };
}

test('details edits preserve untouched deadline precision and clear optional fields explicitly', async t => {
  const { actual: a, state } = await fixture(t);
  const draft = a.createPollEditDraft(original);
  assert.equal(draft.deadline, '2019-12-31T18:00');
  assert.equal(a.hasPollEdits(original, draft), false);
  draft.title = ' Updated '; draft.description = ''; draft.location = '';
  const options = a.get(a.currentPollTimeOptions), people = a.get(a.currentPollParticipants);
  await a.updatePollDetails(original, draft);
  assert.deepEqual(state.patches[0].fields, { title: 'Updated', description: null, location: null });
  assert.deepEqual(state.patches[0].filters, { id: original.id, creator_id: owner });
  assert.equal(a.get(a.currentPoll).title, 'Updated');
  assert.equal(a.get(a.currentPollTimeOptions), options);
  assert.equal(a.get(a.currentPollParticipants), people);
  assert.equal(a.get(a.currentAvailability).version, 3);
});

test('deadline edits use the poll zone, reject skipped times and permit removal', async t => {
  const { actual: a } = await fixture(t);
  const draft = { ...a.createPollEditDraft(original), deadline: '2027-03-14T02:30' };
  assert.throws(() => a.pollEditChanges(original, draft), /does not exist/);
  draft.deadline = '2027-11-07T01:30';
  assert.equal(a.pollEditChanges(original, draft).closes_at, '2027-11-07T06:30:00Z');
  assert.equal(a.pollEditChanges(original, { ...draft, hasDeadline: false }).closes_at, null);
  draft.deadline = '2020-01-01T12:00';
  assert.throws(() => a.pollEditChanges(original, draft), /future/);
  for (const fields of [{ title: ' ' }, { title: 'a'.repeat(201) }, { description: 'a'.repeat(10001) }, { location: 'a'.repeat(1001) }]) {
    assert.throws(() => a.pollEditChanges(original, { ...a.createPollEditDraft(original), ...fields }));
  }
});

test('failed or incomplete saves leave saved details and availability drafts intact for retry', async t => {
  const { actual: a, state } = await fixture(t);
  const editor = a.createAvailabilityEditor({ save: a.saveAvailability, load: a.loadAvailability });
  editor.setOwner(owner); editor.initialize(snapshot); editor.setComment('Unsaved'); editor.setResponse(option.id, 'maybe');
  const draft = { ...a.createPollEditDraft(original), title: 'Updated' };
  for (const reply of [{ data: null, error: { code: '42501' } }, { data: { id: original.id }, error: null },
    { data: pollRow({ id: 'foreign', creator_id: owner }), error: null }]) {
    state.patch = () => reply;
    await assert.rejects(a.updatePollDetails(original, draft));
    assert.equal(a.get(a.currentPoll).title, original.title);
    assert.equal(a.get(editor).comment, 'Unsaved');
    assert.equal(a.get(editor).responses[option.id].status, 'maybe');
  }
  state.patch = null;
  await a.updatePollDetails(original, draft);
  assert.equal(a.get(a.currentPoll).title, 'Updated');
  assert.equal(a.get(editor).comment, 'Unsaved');
});

test('guests and nonowners cannot dispatch a detail edit', async t => {
  const { actual: a, state } = await fixture(t);
  const draft = { ...a.createPollEditDraft(original), title: 'Updated' };
  for (const id of [null, other]) {
    a.user.set(id ? { id } : null); a.currentPoll.set(original);
    await assert.rejects(a.updatePollDetails(original, draft), /owner/);
  }
  assert.equal(state.patches.length, 0);
});

test('late edit results cannot publish after route or same-account session replacement', async t => {
  for (const transition of ['route', 'session']) {
    const { actual: a, state } = await fixture(t);
    const gate = deferred(), started = deferred();
    state.patch = () => { started.resolve(); return gate.promise; };
    const saving = a.updatePollDetails(original, { ...a.createPollEditDraft(original), title: 'Updated' });
    await started.promise;
    if (transition === 'session') a.transitionSession(owner, true);
    else { await a.loadPoll('another'); a.currentPoll.set(pollRow({ id: 'another' })); }
    const visible = a.get(a.currentPoll);
    gate.resolve({ data: state.saved, error: null });
    await assert.rejects(saving);
    assert.equal(a.get(a.currentPoll), visible);
  }
});

test('refreshes started before a save cannot overwrite its confirmed result', async t => {
  const { actual: a, state } = await fixture(t);
  const stale = deferred(), began = deferred();
  state.rpc = name => {
    if (name === 'get_poll_detail') { began.resolve(); return stale.promise; }
    return { data: { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null };
  };
  const refresh = state.refresh();
  await began.promise;
  await a.updatePollDetails(original, { ...a.createPollEditDraft(original), title: 'Updated' });
  stale.resolve({ data: detail(original), error: null });
  await refresh;
  assert.equal(a.get(a.currentPoll).title, 'Updated');
});


test('a refresh started during a pending edit cannot restore its pre-commit row', async t => {
  const { actual: a, state } = await fixture(t);
  const saveGate = deferred(), saveStarted = deferred(), readGate = deferred(), readStarted = deferred();
  state.patch = () => { saveStarted.resolve(); return saveGate.promise; };
  const saving = a.updatePollDetails(original, { ...a.createPollEditDraft(original), title: 'Updated' });
  await saveStarted.promise;
  state.rpc = name => {
    if (name === 'get_poll_detail') { readStarted.resolve(); return readGate.promise; }
    return { data: { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null };
  };
  const refreshing = state.refresh(); await readStarted.promise;
  saveGate.resolve({ data: state.saved, error: null }); await saving;
  readGate.resolve({ data: detail(original), error: null }); await refreshing;
  assert.equal(a.get(a.currentPoll).title, 'Updated');
});

test('an obsolete list read cannot replace the saved row or leave paging locked', async t => {
  const { actual: a, state } = await fixture(t);
  a.createdPolls.set([original]); a.polls.set([original]);
  const gate = deferred(), started = deferred();
  state.rpc = name => {
    if (name === 'list_poll_summaries') { started.resolve(); return gate.promise; }
    throw new Error('Unexpected RPC');
  };
  const listing = a.loadParticipatedPolls(); await started.promise;
  await a.updatePollDetails(original, { ...a.createPollEditDraft(original), title: 'Updated' });
  gate.resolve({ data: { items: [], has_more: false, next_cursor: null, total_count: 0 }, error: null });
  await listing;
  assert.equal(a.get(a.createdPolls)[0].title, 'Updated');
  assert.equal(a.get(a.pollsLoading), false);
  assert.equal(a.get(a.pollListSections).owner.loadingMore, false);
  assert.equal(a.get(a.pollsLoadError), 'Refresh to load your poll history.');
});
