import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const directory = await mkdtemp(join(tmpdir(), 'poll-invitation-'));
const output = join(directory, 'bundle.mjs');
await build({ entryPoints: ['apps/web/src/lib/poll-invitation.ts'], outfile: output,
  bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {} });
const { createPollInvitation } = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));
const poll = { id: 'poll-id', title: 'Planning', status: 'active' };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function fixture(overrides = {}) {
  const calls = [], opened = [];
  const controller = createPollInvitation({
    loadPollByCode: async () => poll,
    joinPoll: async (...args) => { calls.push(args); },
    open: id => opened.push(id), ...overrides
  });
  let state;
  const unsubscribe = controller.subscribe(value => { state = value; });
  return { controller, calls, opened, state: () => state, dispose() { controller.dispose(); unsubscribe(); } };
}

test('following a link looks up the poll but dispatches no join until confirmation', async t => {
  const f = fixture(); t.after(() => f.dispose());
  await f.controller.prepare('ABC123');
  assert.equal(f.state().status, 'ready');
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.opened, []);
  await f.controller.confirm({ accountId: 'member' });
  assert.deepEqual(f.calls, [[poll.id, undefined]]);
  assert.deepEqual(f.opened, [poll.id]);
});

test('cancelling the confirmation joins nothing', async () => {
  const f = fixture();
  await f.controller.prepare('ABC123');
  f.dispose();
  await f.controller.confirm({ accountId: 'member' });
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.opened, []);
});

test('a guest must provide a name and confirm before joining', async t => {
  const f = fixture(); t.after(() => f.dispose());
  await f.controller.prepare('ABC123');
  await f.controller.confirm({ accountId: null, name: '  ' });
  assert.equal(f.state().message, 'Please enter your name');
  assert.deepEqual(f.calls, []);
  await f.controller.confirm({ accountId: null, name: '  Sam  ' });
  assert.deepEqual(f.calls, [[poll.id, 'Sam']]);
});

for (const error of [{ code: '42501' }, new Error('This poll has reached its participant limit.')]) {
  test(`server refusal remains on the confirmation and permits retry: ${error.code ?? 'capacity'}`, async t => {
    const f = fixture({ joinPoll: async () => { throw error; } }); t.after(() => f.dispose());
    await f.controller.prepare('ABC123');
    await f.controller.confirm({ accountId: 'member' });
    assert.equal(f.state().status, 'ready');
    assert.match(f.state().message, /closed|participant limit/);
    assert.deepEqual(f.opened, []);
  });
}

test('a repeated click cannot join twice while confirmation is pending', async t => {
  const gate = deferred(); let joins = 0;
  const f = fixture({ joinPoll: () => { joins++; return gate.promise; } }); t.after(() => f.dispose());
  await f.controller.prepare('ABC123');
  const first = f.controller.confirm({ accountId: 'member' });
  await f.controller.confirm({ accountId: 'member' });
  assert.equal(joins, 1);
  gate.resolve(); await first;
  assert.deepEqual(f.opened, [poll.id]);
});

for (const boundary of ['route/account replacement', 'unmount']) {
  test(`late join result cannot navigate after ${boundary}`, async t => {
    const gate = deferred();
    const f = fixture({ joinPoll: () => gate.promise }); t.after(() => f.dispose());
    await f.controller.prepare('ABC123');
    const pending = f.controller.confirm({ accountId: 'member' });
    if (boundary === 'unmount') f.controller.dispose();
    else await f.controller.prepare('DEF456');
    gate.resolve(); await pending;
    assert.deepEqual(f.opened, []);
  });
}

test('an obsolete preview cannot replace a new invitation', async t => {
  const gate = deferred();
  const f = fixture({ loadPollByCode: code => code === 'OLD123' ? gate.promise : Promise.resolve({ ...poll, title: 'New' }) });
  t.after(() => f.dispose());
  const old = f.controller.prepare('OLD123');
  await f.controller.prepare('NEW123');
  gate.resolve({ ...poll, title: 'Old' }); await old;
  assert.equal(f.state().target.title, 'New');
  assert.deepEqual(f.calls, []);
});

test('unknown or inaccessible polls never offer a join confirmation', async t => {
  for (const preview of [null]) {
    const f = fixture({ loadPollByCode: async () => preview }); t.after(() => f.dispose());
    await f.controller.prepare('ABC123');
    await f.controller.confirm({ accountId: 'member' });
    assert.equal(f.state().status, 'failed');
    assert.deepEqual(f.calls, []);
  }
});

for (const role of ['owner', 'member']) {
  test(`server-authorized closed preview opens results only after confirmation (${role})`, async t => {
    const f = fixture({ loadPollByCode: async () => ({ ...poll, status: 'closed' }) }); t.after(() => f.dispose());
    await f.controller.prepare('ABC123');
    assert.equal(f.state().target.requiresJoin, false);
    assert.deepEqual(f.opened, []);
    await f.controller.confirm({ accountId: 'member' });
    assert.deepEqual(f.calls, []);
    assert.deepEqual(f.opened, [poll.id]);
  });
}

test('an owner confirms opening an active poll without adding membership', async t => {
  const f = fixture({ loadPollByCode: async () => ({ ...poll, creator_id: 'owner' }) }); t.after(() => f.dispose());
  await f.controller.prepare('ABC123');
  assert.deepEqual(f.opened, []);
  await f.controller.confirm({ accountId: 'owner' });
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.opened, [poll.id]);
});
