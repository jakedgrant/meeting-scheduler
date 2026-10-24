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
const member = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const poll = { id: '33333333-3333-4333-8333-333333333333', creator_id: member, title: 'Authoritative title', status: 'active', timezone: 'UTC', is_premium: true, max_participants: 50, share_code: 'SERVER' };
const option = { id: '44444444-4444-4444-8444-444444444444', poll_id: poll.id, start_time: '2026-11-01T12:00:00Z', end_time: '2026-11-01T13:00:00Z', is_all_day: false };
const result = { poll, time_options: [option], redeemed_pass_id: null, entitlement: 'pro_access', replayed: false };
const disk = () => {
  const values = new Map();
  return { values, getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
};
const failingDisk = { getItem() { throw Error('SecurityError'); }, setItem() { throw Error('QuotaExceeded'); }, removeItem() { throw Error('SecurityError'); } };
let sequence = 0;

// Bundle the real store, controller, and Svelte screen. Only the network client,
// account store and navigation are replaced. No server, browser or port is used.
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-creation-'));
  const key = `__webCreation${++sequence}`;
  const state = { calls: [], supabase: {
    rpc(name, args) {
      const response = (async () => {
      state.calls.push({ name, args: structuredClone(args) });
      return state.handler ? state.handler(name, args) : { data: result, error: null };
      })();
      return Object.assign(response, { abortSignal() { return this; } });
    },
    from(table) { throw Error(`Unexpected table write/read ${table}`); },
    removeChannel() {}
  } };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export * from '${lib}/stores/polls.ts'; export * from '${lib}/poll-creation.ts'; export {user} from '${lib}/stores/auth.ts'; export {get} from 'svelte/store'; export {render} from 'svelte/server'; export {default as Page} from '${root}/apps/web/src/routes/polls/new/+page.svelte';`, resolveDir: join(root, 'apps/web') },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'offline-creation', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => {
        const relative = args.path.slice(5);
        if (['supabase', 'stores/auth', 'poll-creation'].includes(relative)) return { path: relative, namespace: 'fixture' };
        return { path: join(lib, `${relative}.ts`) };
      });
      b.onResolve({ filter: /\/stores\/auth\.ts$|^\.\/auth$/ }, () => ({ path: 'stores/auth', namespace: 'fixture' }));
      b.onResolve({ filter: /^\$app\// }, args => ({ path: args.path, namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => {
        const reference = `globalThis.${key}`;
        return { contents: {
          'supabase': `export const supabase=${reference}.supabase;`,
          'stores/auth': `import {writable} from 'svelte/store'; export const user=writable(null);`,
          'poll-creation': `import {createPollCreation as real} from '${lib}/poll-creation.ts'; export const createPollCreation=commands=>${reference}.editor ?? real(commands);`,
          '$app/navigation': `export function goto(path){${reference}.navigation=path;}`
        }[args.path], loader: 'js', resolveDir: join(root, 'apps/web') };
      });
      b.onLoad({ filter: /\.svelte$/ }, async args => ({ contents: compile(await readFile(args.path, 'utf8'), { filename: args.path, generate: 'server' }).js.code, loader: 'js', resolveDir: join(root, 'apps/web') }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  actual.user.set({ id: member });
  t.after(async () => { actual.cleanupPollRealtime(); delete globalThis[key]; await rm(directory, { recursive: true, force: true }); });
  return { actual, state };
}

function editorFor(actual, storage = disk()) {
  const editor = actual.createPollCreation({ create: actual.createPoll }, storage);
  editor.setOwner(member);
  editor.edit({ title: 'My draft', description: 'Description', location: 'Room', timezone: 'UTC', timeOptions: [{ id: 'draft-option', date: '2026-11-01', startTime: '12:00', endTime: '13:00' }] });
  return editor;
}

test('one creation RPC applies authoritative complete state and never writes tables', async t => {
  const { actual, state } = await fixture(t);
  const storage = disk();
  const editor = editorFor(actual, storage);
  const returned = await editor.submit();
  assert.deepEqual(returned, result);
  assert.deepEqual(actual.get(actual.currentPoll), poll);
  assert.deepEqual(actual.get(actual.currentPollTimeOptions), [option]);
  assert.deepEqual(actual.get(actual.createdPolls), [poll]);
  assert.deepEqual(actual.get(actual.polls), [poll]);
  assert.equal(state.calls.length, 1);
  assert.equal(state.calls[0].name, 'create_poll');
  assert.match(state.calls[0].args.operation_id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(Object.keys(state.calls[0].args.payload).sort(), ['title', 'description', 'location', 'timezone', 'closes_at', 'time_options', 'use_event_pass'].sort());
  assert.equal(state.calls[0].args.payload.use_event_pass, false);
  assert.equal(storage.values.size, 0);
});

test('a delayed list snapshot from before creation cannot erase authoritative success', async t => {
  const { actual, state } = await fixture(t);
  let finishList;
  state.handler = name => name === 'get_user_participated_polls'
    ? new Promise(resolve => { finishList = resolve; })
    : { data: result, error: null };
  const loadingList = actual.loadParticipatedPolls();
  assert.equal(actual.get(actual.pollsLoading), true);
  const editor = editorFor(actual);
  await editor.submit();
  assert.equal(actual.get(actual.pollsLoading), false);
  finishList({ data: { created_polls: [], joined_polls: [] }, error: null });
  await loadingList;
  assert.deepEqual(actual.get(actual.createdPolls), [poll]);
  assert.deepEqual(actual.get(actual.polls), [poll]);
  assert.deepEqual(actual.get(actual.currentPoll), poll);
  // A later, fresh server load may still reconcile normal list state.
  state.handler = () => ({ data: { created_polls: [poll], joined_polls: [] }, error: null });
  await actual.loadParticipatedPolls();
  assert.deepEqual(actual.get(actual.createdPolls), [poll]);
});

for (const storage of [disk()]) {
  test(`lost reply retains draft and immutable operation, then recovers authoritative replay (${storage === failingDisk ? 'failed' : 'working'} storage)`, async t => {
    const { actual, state } = await fixture(t);
    const editor = editorFor(actual, storage);
    let original;
    state.handler = (_name, args) => {
      if (!original) { original = structuredClone(args); throw Error('Reply lost after commit'); }
      assert.deepEqual(args, original);
      return { data: { ...result, replayed: true }, error: null };
    };
    assert.equal(await editor.submit(), null);
    assert.equal(actual.get(editor).draft.title, 'My draft');
    assert.equal(actual.get(editor).uncertain, true);
    assert.match(actual.get(editor).error, /Retry to recover/);
    assert.equal(actual.get(actual.currentPoll), null);
    editor.edit({ title: 'Must not change an uncertain request' });
    assert.equal(actual.get(editor).draft.title, 'My draft');
    state.editor = editor;
    const html = actual.render(actual.Page).body;
    assert.match(html, /Retry Create Poll/);
    assert.match(html, /Your draft is kept/);
    assert.match(html, /value="My draft"[^>]*disabled/);
    assert.equal((await editor.submit()).replayed, true);
    assert.equal(actual.get(actual.createdPolls).length, 1);
  });
}

test('lost reply and pending operation survive navigation/reload in the same account', async t => {
  const { actual, state } = await fixture(t);
  const storage = disk();
  const editor = editorFor(actual, storage);
  state.handler = () => ({ data: null, error: { code: 'NETWORK' } });
  await editor.submit();
  const original = state.calls[0].args;
  // A fresh bundle has no module-level memory, matching an actual reload.
  const next = await fixture(t);
  const restored = next.actual.createPollCreation({ create: next.actual.createPoll }, storage);
  restored.setOwner(member);
  assert.equal(next.actual.get(restored).draft.description, 'Description');
  assert.equal(next.actual.get(restored).uncertain, true);
  next.state.handler = () => ({ data: { ...result, replayed: true }, error: null });
  await restored.submit();
  assert.deepEqual(next.state.calls[0].args, original);
});

test('unavailable storage blocks dispatch and retains editable draft across same-tab navigation', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual, failingDisk);
  await editor.submit();
  assert.match(actual.get(editor).error, /Enable browser storage/);
  assert.equal(actual.get(editor).saving, false);
  assert.equal(actual.get(editor).uncertain, false);
  assert.equal(state.calls.length, 0);
  const restored = actual.createPollCreation({ create: actual.createPoll }, failingDisk);
  restored.setOwner(member);
  assert.equal(actual.get(restored).draft.title, 'My draft');
  restored.edit({ title: 'Still editable' });
  await restored.submit();
  assert.equal(actual.get(restored).draft.title, 'Still editable');
  assert.equal(state.calls.length, 0);
});

for (const storage of [null, { getItem: () => null, setItem() {}, removeItem() {} }]) {
  test(`missing or silently failing storage blocks every creation dispatch (${storage ? 'silent' : 'null'})`, async t => {
    const { actual, state } = await fixture(t);
    const editor = editorFor(actual, storage);
    await editor.submit();
    assert.match(actual.get(editor).error, /no creation request was sent/);
    assert.equal(state.calls.length, 0);
  });
}

for (const raw of ['bad-json', JSON.stringify({ draft: {}, operation: { operation_id: 'corrupt' }, uncertain: true }), JSON.stringify({ draft: { title: 'Draft', description: '', location: '', dueDate: '', timezone: 'UTC', isAllDay: false, useEventPass: true, timeOptions: [] }, operation: { operation_id: 'bad-id', payload: {} }, uncertain: true })]) {
  test(`corrupt saved operation blocks replacement rather than minting another ID (${raw.slice(0, 12)})`, async t => {
    const { actual, state } = await fixture(t);
    const storage = disk();
    storage.setItem(`meeting-scheduler:create-poll:${member}`, raw);
    const editor = actual.createPollCreation({ create: actual.createPoll }, storage);
    editor.setOwner(member);
    assert.equal(actual.get(editor).recoveryRequired, true);
    assert.match(actual.get(editor).error, /Check My Polls/);
    editor.edit({ title: 'Replacement' });
    await editor.submit();
    assert.equal(state.calls.length, 0);
    assert.equal(storage.getItem(`meeting-scheduler:create-poll:${member}`), raw);
  });
}

test('a successful screen cannot submit another poll before navigation completes', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  await editor.submit();
  await editor.submit();
  assert.equal(state.calls.length, 1);
});

test('pending identity is durably recorded before the request, including interruption mid-flight', async t => {
  const { actual, state } = await fixture(t);
  const storage = disk();
  const editor = editorFor(actual, storage);
  let finish;
  state.handler = () => new Promise(resolve => { finish = resolve; });
  const pending = editor.submit();
  const restored = actual.createPollCreation({ create: actual.createPoll }, storage);
  restored.setOwner(member);
  assert.equal(actual.get(restored).uncertain, true);
  editor.invalidate();
  finish({ data: result, error: null });
  assert.equal(await pending, null, 'unmounted screen cannot navigate with late success');
  state.handler = () => ({ data: result, error: null });
  await restored.submit();
  assert.deepEqual(state.calls[1].args, state.calls[0].args);
});

for (const [code, message] of [['P0001', /active poll limit/], ['P0002', /No verified event pass/], ['22023', /details were rejected/], ['42501', /Sign in again/], ['54000', /share code/], ['PGRST202', /temporarily unavailable/]]) {
  test(`${code} rejection keeps editable draft and same-ID unchanged retry`, async t => {
    const { actual, state } = await fixture(t);
    const editor = editorFor(actual);
    state.handler = () => ({ data: null, error: { code, message: 'Internal details are not rendered' } });
    await editor.submit();
    assert.match(actual.get(editor).error, message);
    assert.equal(actual.get(editor).uncertain, false);
    await editor.submit();
    assert.deepEqual(state.calls[1].args, state.calls[0].args);
    editor.edit({ title: 'Revised draft' });
    await editor.submit();
    assert.notEqual(state.calls[2].args.operation_id, state.calls[1].args.operation_id);
    assert.equal(state.calls[2].args.payload.title, 'Revised draft');
  });
}

test('same-ID changed-payload rejection is actionable and cannot silently create another poll', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  state.handler = () => ({ data: null, error: { code: '22000' } });
  await editor.submit();
  assert.match(actual.get(editor).error, /original draft/);
  editor.edit({ title: 'Another poll' });
  await editor.submit();
  assert.deepEqual(state.calls[1].args, state.calls[0].args);
});

test('invalid complete draft is rejected before any RPC rather than silently dropping options', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  const good = actual.get(editor).draft.timeOptions[0];
  editor.edit({ timeOptions: [good, { ...good, id: 'unfinished', date: '' }] });
  await editor.submit();
  assert.match(actual.get(editor).error, /every option/);
  editor.edit({ timeOptions: [{ ...good, endTime: '11:00' }] });
  await editor.submit();
  assert.match(actual.get(editor).error, /End time/);
  assert.equal(state.calls.length, 0);
});

test('explicit event-pass choice reaches server and returned cap/pass state is adopted', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  editor.edit({ useEventPass: true });
  state.editor = editor;
  const html = actual.render(actual.Page).body;
  assert.match(html, /Use an event pass for this poll/);
  assert.match(html, /type="checkbox" checked/);
  state.handler = () => ({ data: { ...result, entitlement: 'event_pass', redeemed_pass_id: other }, error: null });
  await editor.submit();
  assert.equal(state.calls[0].args.payload.use_event_pass, true);
  assert.equal(actual.get(editor).result.redeemed_pass_id, other);
  assert.equal(actual.get(actual.currentPoll).max_participants, 50);
});

test('subscription-covered authoritative success keeps the pass despite explicit request', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  editor.edit({ useEventPass: true });
  await editor.submit();
  assert.equal(state.calls[0].args.payload.use_event_pass, true);
  assert.equal(actual.get(editor).result.entitlement, 'pro_access');
  assert.equal(actual.get(editor).result.redeemed_pass_id, null);
});

test('new payload timezone matches picker conversion zone; pending payload keeps its original zone', async t => {
  const { actual, state } = await fixture(t);
  const storage = disk();
  const editor = editorFor(actual, storage);
  editor.edit({ timezone: 'Pacific/Auckland' });
  state.handler = () => ({ data: null, error: { code: 'NETWORK' } });
  await editor.submit();
  assert.equal(state.calls[0].args.payload.timezone, Intl.DateTimeFormat().resolvedOptions().timeZone);
  const previousZone = process.env.TZ;
  try {
    process.env.TZ = state.calls[0].args.payload.timezone === 'Pacific/Auckland' ? 'America/New_York' : 'Pacific/Auckland';
    const next = await fixture(t);
    const restored = next.actual.createPollCreation({ create: next.actual.createPoll }, storage);
    restored.setOwner(member);
    await restored.submit();
    assert.deepEqual(state.calls[0].args, next.state.calls[0].args);
  } finally {
    if (previousZone === undefined) delete process.env.TZ;
    else process.env.TZ = previousZone;
  }
});

for (const guest of [false, true]) {
  test(`${guest ? 'guest' : 'member'} capacity rejection is actionable and never applies a participant`, async t => {
    const { actual, state } = await fixture(t);
    if (guest) actual.user.set(null);
    state.handler = () => ({ data: null, error: { code: 'P0003', message: 'Poll participant limit reached' } });
    await assert.rejects(actual.joinPoll(poll.id, 'Guest'), /participant limit.*organizer.*retry joining/);
    assert.equal(actual.get(actual.currentPollParticipants).length, 0);
  });
}

test('confirmed rejection stays editable after reload and retains unchanged retry ID', async t => {
  const first = await fixture(t);
  const storage = disk();
  const editor = editorFor(first.actual, storage);
  first.state.handler = () => ({ data: null, error: { code: 'P0001' } });
  await editor.submit();
  const next = await fixture(t);
  const restored = next.actual.createPollCreation({ create: next.actual.createPoll }, storage);
  restored.setOwner(member);
  assert.equal(next.actual.get(restored).uncertain, false);
  await restored.submit();
  assert.deepEqual(next.state.calls[0].args, first.state.calls[0].args);
});

for (const outcome of ['success', 'failure']) {
  test(`late account-A ${outcome} cannot replace account-B draft/state or navigate`, async t => {
    const { actual, state } = await fixture(t);
    const storage = disk();
    const editor = editorFor(actual, storage);
    let finish;
    state.handler = () => new Promise(resolve => { finish = resolve; });
    const pending = editor.submit();
    actual.user.set({ id: other });
    editor.setOwner(other);
    editor.edit({ title: 'Account B' });
    finish(outcome === 'success' ? { data: result, error: null } : { data: null, error: { code: 'P0001' } });
    assert.equal(await pending, null);
    assert.equal(actual.get(editor).draft.title, 'Account B');
    assert.equal(actual.get(editor).result, null);
    assert.equal(actual.get(editor).error, null);
    assert.equal(actual.get(actual.currentPoll), null);
    assert.deepEqual(actual.get(actual.createdPolls), []);
    assert.equal(state.navigation, undefined);
    editor.setOwner(member);
    assert.equal(actual.get(editor).draft.title, 'My draft');
    assert.equal(actual.get(editor).uncertain, true);
  });
}

test('same-account sign-out/sign-in generation still rejects the old creation result', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  let finish;
  state.handler = () => new Promise(resolve => { finish = resolve; });
  const pending = editor.submit();
  actual.user.set(null);
  actual.user.set({ id: member });
  finish({ data: result, error: null });
  assert.equal(await pending, null);
  assert.equal(actual.get(actual.currentPoll), null);
  assert.equal(actual.get(editor).uncertain, true);
});

test('malformed creation reply is never treated as success', async t => {
  const { actual, state } = await fixture(t);
  const editor = editorFor(actual);
  state.handler = () => ({ data: { ...result, poll: { ...poll, creator_id: other } }, error: null });
  assert.equal(await editor.submit(), null);
  assert.equal(actual.get(editor).uncertain, true);
  assert.deepEqual(actual.get(actual.polls), []);
});

test('dashboard permits authoritative creation attempt without local quota/entitlement blocking', async () => {
  const source = await readFile(join(root, 'apps/web/src/routes/polls/+page.svelte'), 'utf8');
  assert.match(source, /href="\/polls\/new"/);
  assert.doesNotMatch(source, /canCreatePoll|getMaxActivePolls|Upgrade to Pro/);
});
