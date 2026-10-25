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
const pollId = '33333333-3333-4333-8333-333333333333';
const id = (prefix, index) => `${prefix}${String(index).padStart(12, '0')}`;
const pollRow = (index, creator = member) => ({ id: id('44444444-4444-4444-8444-', index), creator_id: creator, title: `Poll ${index}`, status: 'active', description: null });
const summary = (poll, role, extra = {}) => ({ poll, role, participant_count: 7, time_option_count: 2, earliest_start: '2026-11-01T12:00:00Z', latest_start: '2026-11-03T12:00:00Z', ...extra });
const page = (items, nextCursor = null, total = items.length) => ({ items, has_more: nextCursor !== null, next_cursor: nextCursor, total_count: total });
const responseRow = index => ({ id: id('55555555-5555-4555-8555-', index), participant_id: id('66666666-6666-4666-8666-', Math.floor(index / 30)), time_option_id: id('77777777-7777-4777-8777-', index % 30), status: 'available' });
let sequence = 0;

// Bundle the real stores, paging helper and list screen. Only the network
// client, account store and navigation are replaced; no server or port is used.
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-paged-'));
  const key = `__webPaged${++sequence}`;
  const state = { calls: [], supabase: {
    rpc(name, args) {
      const call = { name, args: structuredClone(args), signal: null };
      state.calls.push(call);
      const response = (async () => state.handler(name, args))();
      return Object.assign(response, { abortSignal(signal) { call.signal = signal; return this; } });
    },
    from(table) { throw Error(`Unexpected table read ${table}`); },
    channel() { return { on() { return this; }, subscribe() { return this; } }; },
    removeChannel() {}
  } };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export * from '${lib}/stores/polls.ts'; export * as paging from '${lib}/paged-read.ts'; export {user} from '${lib}/stores/auth.ts'; export {get} from 'svelte/store'; export {render} from 'svelte/server'; export {default as ListPage} from '${root}/apps/web/src/routes/polls/+page.svelte';`, resolveDir: join(root, 'apps/web') },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'offline-reads', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => {
        const relative = args.path.slice(5);
        if (['supabase', 'stores/auth'].includes(relative)) return { path: relative, namespace: 'fixture' };
        return { path: join(lib, `${relative}.ts`) };
      });
      b.onResolve({ filter: /\/stores\/auth\.ts$|^\.\/auth$/ }, () => ({ path: 'stores/auth', namespace: 'fixture' }));
      b.onResolve({ filter: /^\$app\// }, args => ({ path: args.path, namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: {
        'supabase': `export const supabase=globalThis.${key}.supabase;`,
        'stores/auth': `import {writable} from 'svelte/store'; export const user=writable(null), profile=writable(null); export async function signOut(){return true;}`,
        '$app/navigation': 'export function goto(){}'
      }[args.path], loader: 'js', resolveDir: join(root, 'apps/web') }));
      b.onLoad({ filter: /\.svelte$/ }, async args => ({ contents: compile(await readFile(args.path, 'utf8'), { filename: args.path, generate: 'server' }).js.code, loader: 'js', resolveDir: join(root, 'apps/web') }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  actual.user.set({ id: member });
  t.after(async () => { actual.cleanupPollRealtime(); delete globalThis[key]; await rm(directory, { recursive: true, force: true }); });
  return { actual, state };
}

test('readAllPages accepts only a complete, distinct, advancing traversal', async t => {
  const { actual: { paging } } = await fixture(t);
  const pages = { null: page([1, 2], 'a', 5), a: page([3, 4], 'b', null), b: page([5], null, null) };
  assert.deepEqual(await paging.readAllPages(async cursor => pages[cursor], String), [1, 2, 3, 4, 5]);
  const incomplete = { name: 'IncompleteReadError' };
  await assert.rejects(paging.readAllPages(async () => page([1, 2], null, 3), String), incomplete);
  await assert.rejects(paging.readAllPages(async cursor => cursor ? page([2], null, null) : page([1, 2], 'a', 3), String), incomplete);
  await assert.rejects(paging.readAllPages(async () => page([1], 'same', 9), String), incomplete);
  await assert.rejects(paging.readAllPages(async () => ({ items: [], has_more: true, next_cursor: null, total_count: 0 }), String), incomplete);
  await assert.rejects(paging.readAllPages(async () => ({ items: [], has_more: false, next_cursor: null, total_count: null }), String), incomplete);
  let calls = 0;
  await assert.rejects(paging.readAllPages(async () => page([++calls], `c${calls}`, 1e6), String, 3), incomplete);
  assert.equal(calls, 3, 'maxPages stops a server that never ends');
});

test('list loads one page per section with database counts, then appends on demand', async t => {
  const { actual, state } = await fixture(t);
  const owned = Array.from({ length: 120 }, (_, index) => pollRow(index));
  const joined = [pollRow(500, other)];
  state.handler = (name, args) => {
    assert.equal(name, 'list_poll_summaries');
    assert.equal(args.page_size, actual.POLL_LIST_PAGE_SIZE);
    if (args.role_filter === 'member') return { data: page([summary(joined[0], 'member', { participant_count: 1 })]), error: null };
    const start = args.page_cursor ? Number(args.page_cursor) : 0;
    const slice = owned.slice(start, start + 50);
    const next = start + 50 < owned.length ? String(start + 50) : null;
    return { data: page(slice.map(poll => summary(poll, 'owner')), next, args.page_cursor ? null : owned.length), error: null };
  };
  await actual.loadParticipatedPolls();
  assert.equal(state.calls.length, 2, 'request count does not grow with history');
  assert.equal(actual.get(actual.createdPolls).length, 50);
  assert.deepEqual(actual.get(actual.joinedPolls), joined);
  assert.deepEqual(actual.get(actual.pollListSections).owner, { total: 120, nextCursor: '50', loadingMore: false });
  assert.equal(actual.get(actual.pollListSections).member.nextCursor, null);
  assert.equal(actual.get(actual.pollSummaries)[joined[0].id].participant_count, 1);

  const html = actual.render(actual.ListPage).body;
  assert.match(html, /Showing 50 of 120/);
  assert.match(html, /7 participants/);
  assert.match(html, /1 participant</);

  const loading = actual.loadMorePolls('owner');
  assert.equal(actual.get(actual.pollListSections).owner.loadingMore, true);
  await actual.loadMorePolls('owner'); // a second click while loading sends nothing
  await loading;
  assert.equal(state.calls.length, 3);
  await actual.loadMorePolls('owner');
  assert.equal(actual.get(actual.createdPolls).length, 120);
  assert.deepEqual(actual.get(actual.createdPolls).map(poll => poll.id), owned.map(poll => poll.id));
  assert.deepEqual(actual.get(actual.pollListSections).owner, { total: 120, nextCursor: null, loadingMore: false }, 'later pages keep the first total');
  assert.equal(actual.get(actual.polls).length, 121);
  await actual.loadMorePolls('owner');
  assert.equal(state.calls.length, 4, 'nothing to load after the last page');
});

test('a page fetched for a previous account or reload is discarded', async t => {
  const { actual, state } = await fixture(t);
  let release;
  state.handler = (_name, args) => args.page_cursor
    ? new Promise(resolve => { release = () => resolve({ data: page([summary(pollRow(99), 'owner')]), error: null }); })
    : { data: page(args.role_filter === 'owner' ? [summary(pollRow(1), 'owner')] : [], args.role_filter === 'owner' ? 'next' : null, args.role_filter === 'owner' ? 2 : 0), error: null };
  await actual.loadParticipatedPolls();
  const late = actual.loadMorePolls('owner');
  actual.user.set({ id: other });
  release();
  await late;
  assert.deepEqual(actual.get(actual.createdPolls), []);
  assert.deepEqual(actual.get(actual.pollSummaries), {});
  assert.deepEqual(actual.get(actual.pollListSections).owner, { total: 0, nextCursor: null, loadingMore: false });
});

test('a failed list load is reported instead of shown as an empty history', async t => {
  const { actual, state } = await fixture(t);
  state.handler = (_name, args) => args.role_filter === 'member' ? { data: null, error: { code: '57014' } } : { data: page([summary(pollRow(1), 'owner')]), error: null };
  await actual.loadParticipatedPolls();
  assert.equal(actual.get(actual.pollsLoadError), 'Could not load your polls. Please retry.');
  assert.equal(actual.get(actual.pollsLoading), false);
  const html = actual.render(actual.ListPage).body;
  assert.match(html, /Could not load your polls/);
  assert.doesNotMatch(html, /No polls yet/);
  state.handler = (_name, args) => ({ data: page(args.role_filter === 'owner' ? [summary(pollRow(1), 'owner')] : []), error: null });
  await actual.loadParticipatedPolls();
  assert.equal(actual.get(actual.pollsLoadError), null);
  assert.equal(actual.get(actual.createdPolls).length, 1);
});

test('detail shows responses only after complete traversal beyond the row cap', async t => {
  const { actual, state } = await fixture(t);
  const poll = { ...pollRow(1), id: pollId };
  const participants = Array.from({ length: 40 }, (_, index) => ({ id: id('66666666-6666-4666-8666-', index), poll_id: pollId, user_id: null, anonymous_name: 'Guest', profiles: null }));
  const options = Array.from({ length: 30 }, (_, index) => ({ id: id('77777777-7777-4777-8777-', index), poll_id: pollId, start_time: '2026-11-01T12:00:00Z', end_time: '2026-11-01T13:00:00Z', is_all_day: false }));
  const rows = Array.from({ length: 1200 }, (_, index) => responseRow(index));
  let total = rows.length;
  state.handler = (name, args) => {
    if (name === 'get_poll_detail') return { data: { poll, time_options: options, participants, time_option_count: 30, participant_count: 40 }, error: null };
    assert.equal(name, 'list_poll_responses');
    assert.equal(args.page_size, 1000);
    const start = args.page_cursor ? Number(args.page_cursor) : 0;
    const next = start + 1000 < rows.length ? String(start + 1000) : null;
    return { data: page(rows.slice(start, start + 1000), next, args.page_cursor ? null : total), error: null };
  };
  await actual.loadPoll(pollId);
  assert.equal(actual.get(actual.currentPoll).id, pollId);
  assert.equal(actual.get(actual.currentPollParticipants).length, 40);
  assert.equal(actual.get(actual.currentPollResponses).length, 1200);
  assert.deepEqual(state.calls.filter(call => call.name === 'list_poll_responses').map(call => call.args.page_cursor), [null, '1000']);
  assert.ok(state.calls.every(call => call.signal), 'every read is cancellable');

  // A traversal that does not add up fails the load rather than showing partial data.
  total = 1201;
  await actual.loadPoll(pollId);
  assert.equal(actual.get(actual.currentPoll), null);

  // A detail whose collections disagree with its counts is also rejected.
  total = rows.length;
  const handler = state.handler;
  state.handler = (name, args) => name === 'get_poll_detail'
    ? { data: { poll, time_options: options.slice(1), participants, time_option_count: 30, participant_count: 40 }, error: null }
    : handler(name, args);
  await actual.loadPoll(pollId);
  assert.equal(actual.get(actual.currentPoll), null);
  assert.equal(state.calls.at(-1).name, 'get_poll_detail', 'no response pages are read for a rejected detail');
});
