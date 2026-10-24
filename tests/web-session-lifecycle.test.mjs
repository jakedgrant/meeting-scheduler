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
const { createClient } = requireWeb('@supabase/supabase-js');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const web = join(root, 'apps/web');
const lib = join(web, 'src/lib');
const accountA = '11111111-1111-4111-8111-111111111111';
const accountB = '22222222-2222-4222-8222-222222222222';
const sessionFor = id => ({ user: { id, email: `${id}@test.invalid` }, access_token: `token-${id}`, refresh_token: `refresh-${id}`, expires_at: Math.floor(Date.now() / 1000) + 3600 });
const status = email => ({ connected: true, accountEmail: email, requiresReconnect: false, revocationPending: false });
const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
// Auth verification and dependent work each own a macrotask. Drain explicit
// turns instead of assuming a wall-clock delay can encompass nested timers.
const flush = async () => { for (let turn = 0; turn < 3; turn++) await new Promise(resolve => setTimeout(resolve, 0)); };
const disk = () => { const values = new Map(); return { values, getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) }; };
let sequence = 0;

// Run real stores/controllers, provider reconciliation and Svelte SSR. Inject
// only platform environment, SDK transport and provider SDK; no server/port.
async function fixture(t, { browser = true } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'web-session-'));
  const key = `__webSession${++sequence}`;
  const initial = deferred();
  const state = { calls: [], listeners: new Set(), initial, account: null, locked: false, provider: null, channels: [], removed: [] };
  const sdk = name => { assert.equal(state.locked, false, `${name} acquired SDK work inside auth callback`); state.calls.push(name); };
  state.emit = (event, session, updateStorage = true) => {
    if (updateStorage) { state.account = session?.user.id ?? null; state.storedSession = session; }
    state.locked = true;
    try { for (const listener of state.listeners) assert.equal(listener(event, session), undefined, 'auth callback is synchronous'); }
    finally { state.locked = false; }
  };
  function query(table) {
    sdk(`table:${table}`);
    const request = { table, account: state.account, eq: {}, update: null, signal: null };
    const builder = {
      select() { return this; }, eq(name, value) { request.eq[name] = value; return this; },
      in() { return this; }, order() { return this; }, update(value) { request.update = value; return this; },
      abortSignal(signal) { request.signal = signal; return this; },
      single() { return this; },
      then(yes, no) {
        state.requests ??= []; state.requests.push(request);
        const answer = state.query?.(request) ?? { data: table === 'profiles' ? { id: request.eq.id, display_name: request.eq.id } : table === 'subscriptions' ? { user_id: request.eq.user_id } : table === 'polls' ? { id: request.eq.id, creator_id: request.account } : [], error: null };
        return Promise.resolve(answer).then(yes, no);
      }
    };
    return builder;
  }
  state.supabase = {
    auth: {
      getSession() { sdk('getSession'); state.sessionReads = (state.sessionReads ?? 0) + 1; return state.sessionReads === 1 ? initial.promise : state.readSession ? state.readSession() : Promise.resolve({ data: { session: state.storedSession ?? null }, error: null }); },
      onAuthStateChange(callback) { state.listeners.add(callback); return { data: { subscription: { unsubscribe() { state.listeners.delete(callback); } } } }; },
      async signOut() { return state.signOut ? state.signOut() : { error: null }; },
      async signInWithOAuth(args) { return state.oauth(args); },
      async signInWithOtp() { return { error: null }; }
    },
    realtime: { setAuth(token) { sdk('realtime:setAuth'); state.realtimeToken = token; return Promise.resolve(); } },
    from: query,
    rpc(name, args) {
      sdk(`rpc:${name}`);
      const request = { name, args, account: state.account, signal: null };
      (state.rpcRequests ??= []).push(request);
      const response = (async () => state.rpc?.(name, args) ?? { data: null, error: null })();
      return Object.assign(response, { abortSignal(signal) { request.signal = signal; return this; } });
    },
    functions: { invoke(name, options) { sdk(`function:${name}`); return state.invoke?.(name, options) ?? Promise.resolve({ data: status(state.account), error: null }); } },
    channel(name) { sdk('channel'); const channel = { name, handlers: [], on(...args) { this.handlers.push(args.at(-1)); return this; }, subscribe() { return this; } }; state.channels.push(channel); return channel; },
    removeChannel(channel) { sdk('removeChannel'); state.removed.push(channel); return Promise.resolve('ok'); }
  };
  state.Purchases = {
    configure({ appUserId }) {
      sdk(`provider:configure:${appUserId}`);
      const instance = {
        account: appUserId,
        getAppUserId() { return this.account; },
        async changeUser(account) {
          sdk(`provider:change:${account}`);
          this.account = account; // Pinned SDK changes identity before fetching info.
          return state.changeUser ? state.changeUser(account) : { account };
        },
        close() { sdk(`provider:close:${this.account}`); state.closed ??= []; state.closed.push(this.account); },
        async getCustomerInfo() { sdk(`provider:info:${this.account}`); return state.info ? state.info(this.account) : { account: this.account, entitlements: { active: {} } }; },
        async getOfferings() { sdk(`provider:offerings:${this.account}`); return state.offerings ? state.offerings(this.account) : { current: { availablePackages: [{ identifier: this.account }] } }; },
        async purchase() { sdk(`provider:purchase:${this.account}`); return state.purchase ? state.purchase(this.account) : { customerInfo: { account: this.account } }; }
      };
      state.provider = instance;
      return instance;
    }
  };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `import * as auth from '${lib}/stores/auth.ts'; import * as polls from '${lib}/stores/polls.ts'; import * as calendar from '${lib}/stores/calendar.ts'; import * as billing from '${lib}/stores/subscription.ts'; import * as rc from '${lib}/revenuecat.ts'; import * as scope from '${lib}/session-scope.ts'; export {auth,polls,calendar,billing,rc,scope}; export {mountClientSession} from '${lib}/client-session.ts'; export {createSessionExpiry} from '${lib}/session-expiry.ts'; export {createAuthCallback} from '${lib}/auth-callback.ts'; export {createAvailabilityEditor} from '${lib}/availability-editor.ts'; export {createPollCreation} from '${lib}/poll-creation.ts'; export {get} from 'svelte/store'; export {render} from 'svelte/server'; export {default as Layout} from '${web}/src/routes/+layout.svelte';`, resolveDir: web },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    define: { 'import.meta.env.VITE_REVENUECAT_WEB_KEY': '"test-key"' },
    plugins: [{ name: 'offline-session', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => args.path.endsWith('favicon.svg') ? { path: 'favicon', namespace: 'fixture' } : args.path === '$lib/supabase' ? { path: 'supabase', namespace: 'fixture' } : { path: join(lib, `${args.path.slice(5)}.ts`) });
      b.onResolve({ filter: /^\$app\/environment$/ }, () => ({ path: 'environment', namespace: 'fixture' }));
      b.onResolve({ filter: /^@revenuecat\/purchases-js$/ }, () => ({ path: 'provider', namespace: 'fixture' }));
      b.onResolve({ filter: /favicon\.svg$/ }, () => ({ path: 'favicon', namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: {
        supabase: `export const supabase=globalThis.${key}.supabase;`,
        environment: `export const browser=${browser};`,
        provider: `export const Purchases=globalThis.${key}.Purchases;`,
        favicon: 'export default "";'
      }[args.path], loader: 'js' }));
      b.onLoad({ filter: /\.svelte$/ }, async args => ({ contents: compile(await readFile(args.path, 'utf8'), { filename: args.path, generate: 'server' }).js.code, loader: 'js', resolveDir: web }));
    } }]
  });
  const actual = await import(pathToFileURL(output));
  const disposals = [];
  const mount = () => { const dispose = actual.mountClientSession(); disposals.push(dispose); return dispose; };
  t.after(async () => {
    disposals.forEach(dispose => dispose());
    actual.polls.cleanupPollRealtime();
    await flush();
    delete globalThis[key];
    await rm(directory, { recursive: true, force: true });
  });
  return { actual, state, mount };
}

for (const result of ['success', 'failure']) {
  test(`listener precedes restoration; newer auth wins delayed initialization ${result}`, async t => {
    const { actual, state, mount } = await fixture(t);
    mount();
    assert.equal(state.listeners.size, 1);
    state.emit('SIGNED_IN', sessionFor(accountB));
    assert.equal(actual.get(actual.auth.user), null, 'unverified auth hints cannot expose an account');
    if (result === 'success') state.initial.resolve({ data: { session: sessionFor(accountA) }, error: null });
    else state.initial.reject(Error('offline restoration'));
    await flush();
    assert.equal(actual.get(actual.auth.user).id, accountB);
    assert.equal(actual.get(actual.auth.profile).id, accountB);
    assert.equal(state.provider.getAppUserId(), accountB);
  });
}

test('combined auth composition holds no dependent SDK work under lock; repeated refresh/profile updates retain scope', async t => {
  const { actual, state, mount } = await fixture(t);
  mount();
  state.emit('SIGNED_IN', sessionFor(accountA));
  await flush();
  await actual.polls.loadPoll('poll-A');
  const before = actual.get(actual.scope.sessionIdentity);
  const profileReads = state.calls.filter(call => call === 'table:profiles').length;
  for (let index = 0; index < 4; index++) state.emit('TOKEN_REFRESHED', sessionFor(accountA));
  await flush();
  assert.deepEqual(actual.get(actual.scope.sessionIdentity), before);
  assert.equal(state.calls.filter(call => call === 'table:profiles').length, profileReads);
  await actual.auth.updateProfile({ display_name: 'Updated A' });
  assert.equal(actual.get(actual.auth.profile).id, accountA);
  state.emit('USER_UPDATED', sessionFor(accountA));
  await flush();
  assert.equal(actual.get(actual.auth.profile).id, accountA);
  state.emit('SIGNED_OUT', null);
  assert.equal(actual.get(actual.auth.profile), null);
  assert.equal(actual.get(actual.polls.currentPoll), null);
  assert.equal(actual.get(actual.billing.subscription), null);
  assert.equal(actual.get(actual.billing.customerInfo), null);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), null);
  await flush();
  assert.equal(state.removed.length, 1, 'owned realtime listener disposed outside lock');
  assert.equal(actual.rc.getPurchases(), null);
});

for (const path of ['A-B', 'A-logout-A', 'A-B-A']) for (const outcome of ['success', 'failure']) {
  test(`obsolete profile/subscription/calendar ${outcome} cannot publish over ${path}`, async t => {
    const { actual, state, mount } = await fixture(t);
    const profile = deferred(), subscription = deferred(), calendar = deferred();
    let firstProfile = true, firstSubscription = true, firstCalendar = true;
    state.query = request => {
      if (request.table === 'profiles' && firstProfile) { firstProfile = false; return profile.promise; }
      if (request.table === 'subscriptions' && firstSubscription) { firstSubscription = false; return subscription.promise; }
      return { data: request.table === 'profiles' ? { id: request.eq.id, display_name: 'current' } : { user_id: request.eq.user_id }, error: null };
    };
    state.invoke = () => {
      if (firstCalendar) { firstCalendar = false; return calendar.promise; }
      return Promise.resolve({ data: status(`current:${state.account}`), error: null });
    };
    mount();
    state.emit('SIGNED_IN', sessionFor(accountA));
    await flush();
    const oldRequests = [...state.requests];
    state.emit(path === 'A-logout-A' ? 'SIGNED_OUT' : 'SIGNED_IN', path === 'A-logout-A' ? null : sessionFor(accountB));
    assert.equal(actual.get(actual.auth.profile), null);
    assert.equal(actual.get(actual.billing.subscription), null);
    if (path !== 'A-B') state.emit('SIGNED_IN', sessionFor(accountA));
    await flush();
    const current = path === 'A-B' ? accountB : accountA;
    const response = data => outcome === 'success' ? { data, error: null } : { data: null, error: Error('obsolete failure') };
    profile.resolve(response({ id: accountA, display_name: 'OLD' }));
    subscription.resolve(response({ user_id: accountA, old: true }));
    calendar.resolve(response(status('OLD')));
    await flush();
    assert.equal(actual.get(actual.auth.profile).id, current);
    assert.equal(actual.get(actual.auth.profile).display_name, 'current');
    assert.deepEqual(actual.get(actual.billing.subscription), { user_id: current });
    assert.equal(actual.get(actual.calendar.calendarAccountEmail), `current:${current}`);
    assert.equal(actual.get(actual.calendar.calendarStatusError), null);
    assert.equal(actual.get(actual.billing.subscriptionLoading), false, 'old finally cannot clear/change current state');
    assert.ok(oldRequests.every(request => request.signal.aborted), 'obsolete requests receive cancellation');
  });
}

for (const outcome of ['success', 'failure']) test(`late profile edit ${outcome} cannot alter a replacement profile`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const pending = deferred();
  state.query = request => request.update ? pending.promise : { data: request.table === 'profiles' ? { id: request.eq.id, display_name: 'current' } : null, error: null };
  const edit = actual.auth.updateProfile({ display_name: 'Old edit' });
  const rejected = assert.rejects(edit, /Session changed/);
  await Promise.resolve();
  state.emit('SIGNED_IN', sessionFor(accountB)); await flush();
  pending.resolve(outcome === 'success' ? { data: { id: accountA, display_name: 'Old edit' }, error: null } : { data: null, error: Error('old error') });
  await rejected;
  assert.equal(actual.get(actual.auth.profile).id, accountB);
});

test('offline replacement clears all account-owned visible state before failed new loads', async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  actual.polls.createdPolls.set([{ id: 'private-A' }]);
  actual.polls.currentPoll.set({ id: 'private-A' });
  actual.polls.currentPollParticipants.set([{ id: 'participant-A' }]);
  actual.polls.currentPollResponses.set([{ id: 'response-A' }]);
  actual.calendar.calendarConflicts.set(new Set(['private-option-A']));
  actual.billing.offerings.set([{ identifier: 'old-offering' }]);
  state.query = () => Promise.reject(Error('offline'));
  state.invoke = () => Promise.reject(Error('offline'));
  state.emit('SIGNED_IN', sessionFor(accountB));
  assert.equal(actual.get(actual.auth.profile), null);
  for (const store of [actual.polls.createdPolls, actual.polls.joinedPolls, actual.polls.currentPollParticipants, actual.polls.currentPollResponses, actual.billing.offerings]) assert.deepEqual(actual.get(store), []);
  assert.equal(actual.get(actual.polls.currentPoll), null);
  assert.equal(actual.get(actual.billing.customerInfo), null);
  assert.equal(actual.get(actual.calendar.calendarConflicts).size, 0);
  await flush();
  assert.equal(actual.get(actual.auth.profile), null);
  assert.equal(actual.get(actual.billing.subscription), null);
});

test('duplicate mounts own one listener; disposed restoration/timers cannot resurrect state, remount works', async t => {
  const { actual, state, mount } = await fixture(t);
  const stopOld = mount();
  const stopNew = mount();
  assert.equal(state.listeners.size, 1);
  state.emit('SIGNED_IN', sessionFor(accountB));
  stopOld(); stopOld();
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), accountB);
  stopNew();
  assert.equal(state.listeners.size, 0);
  const calls = state.calls.length;
  state.initial.resolve({ data: { session: sessionFor(accountA) }, error: null });
  await flush();
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal(state.calls.slice(calls).filter(call => call.startsWith('table:')).length, 0);
  mount();
  await flush();
  assert.equal(state.listeners.size, 1);
  assert.equal(actual.get(actual.auth.user).id, accountB);
});

test('SSR renders without auth/provider/network listeners or browser timers', async t => {
  const { actual, state, mount } = await fixture(t, { browser: false });
  mount();
  const html = actual.render(actual.Layout, { props: { children: () => {} } }).body;
  assert.equal(typeof html, 'string');
  assert.deepEqual(state.calls, []);
  assert.equal(state.listeners.size, 0);
  assert.equal(actual.get(actual.auth.authLoading), false);
});

test('provider identity worker orders in-flight A→B→A and old logout cleanup behind new identity', async t => {
  const { actual, state } = await fixture(t);
  actual.rc.setRevenueCatIdentity(accountA);
  await actual.rc.initRevenueCat();
  const changing = deferred();
  state.changeUser = account => account === accountB ? changing.promise : Promise.resolve({ account });
  actual.rc.setRevenueCatIdentity(accountB);
  const b = actual.rc.initRevenueCat();
  await Promise.resolve(); await Promise.resolve();
  actual.rc.setRevenueCatIdentity(null);
  const logout = actual.rc.initRevenueCat();
  actual.rc.setRevenueCatIdentity(accountA);
  const a = actual.rc.initRevenueCat();
  assert.equal(actual.rc.getPurchases(), null, 'old provider instance is not exposed during reconciliation');
  changing.resolve({ account: accountB });
  await Promise.all([a, b, logout]);
  assert.equal(state.provider.account, accountA);
  assert.equal(actual.rc.getPurchases().getAppUserId(), accountA);
  assert.equal(state.calls.filter(call => call === `provider:configure:${accountA}`).length, 1);
  assert.equal(state.calls.filter(call => call.startsWith('provider:close')).length, 0, 'old queued logout cannot close A');
});

for (const outcome of ['success', 'failure']) test(`obsolete RevenueCat identity ${outcome} reconciles latest identity even after local side effect`, async t => {
  const { actual, state } = await fixture(t);
  actual.rc.setRevenueCatIdentity(accountA); await actual.rc.initRevenueCat();
  const changing = deferred();
  state.changeUser = account => account === accountB ? changing.promise : Promise.resolve({ account });
  actual.rc.setRevenueCatIdentity(accountB);
  const old = actual.rc.initRevenueCat();
  await Promise.resolve(); await Promise.resolve();
  actual.rc.setRevenueCatIdentity(accountA);
  const latest = actual.rc.initRevenueCat();
  if (outcome === 'success') changing.resolve({ account: accountB }); else changing.reject(Error('failure after replacement'));
  await Promise.all([old, latest]);
  assert.equal(state.provider.getAppUserId(), accountA);
});

for (const outcome of ['success', 'failure']) test(`old provider customer info/purchase ${outcome} cannot publish into B`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const purchase = deferred();
  state.purchase = () => purchase.promise;
  const pending = actual.billing.purchase({ identifier: 'test' });
  await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  state.emit('SIGNED_IN', sessionFor(accountB));
  assert.equal(actual.get(actual.billing.customerInfo), null);
  if (outcome === 'success') purchase.resolve({ customerInfo: { account: accountA } }); else purchase.reject(Error('old failure'));
  assert.equal(await pending, false);
  await flush();
  assert.equal(actual.get(actual.billing.customerInfo).account, accountB);
  assert.equal(state.provider.getAppUserId(), accountB);
});

test('expired initial session is hidden; expiry timer survives refresh and fences old-account timers', async t => {
  const { actual, state, mount } = await fixture(t);
  mount();
  state.initial.resolve({ data: { session: { ...sessionFor(accountA), expires_at: 1 } }, error: null });
  await flush();
  assert.equal(actual.get(actual.auth.user), null);
  let now = 1000;
  const scheduled = [];
  const expiry = actual.createSessionExpiry({ now: () => now, schedule(callback, delay) { const timer = { callback, delay, cancelled: false }; scheduled.push(timer); return timer; }, cancel(timer) { timer.cancelled = true; } });
  const expired = [];
  expiry.watch(2, () => expired.push('A'));
  const old = scheduled.at(-1);
  expiry.watch(3, () => expired.push('refreshed A'));
  assert.equal(old.cancelled, true);
  expiry.watch(4, () => expired.push('B'));
  now = 5000;
  old.callback(); scheduled[1].callback();
  assert.deepEqual(expired, []);
  scheduled[2].callback();
  assert.deepEqual(expired, ['B']);
  expiry.dispose();
});

for (const outcome of ['success', 'failure']) for (const boundary of ['B', 'logout-A', 'disposed']) test(`auth callback ${outcome} does not navigate after ${boundary}`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const pending = deferred(), navigation = [];
  const callback = actual.createAuthCallback({ getSession: () => pending.promise, navigate: path => navigation.push(path) });
  const run = callback.run();
  if (boundary === 'disposed') callback.dispose();
  else if (boundary === 'B') state.emit('SIGNED_IN', sessionFor(accountB));
  else { state.emit('SIGNED_OUT', null); state.emit('SIGNED_IN', sessionFor(accountA)); }
  if (outcome === 'success') pending.resolve({ data: { session: sessionFor(accountA) }, error: null }); else pending.reject(Error('old callback failed'));
  await run;
  assert.deepEqual(navigation, []);
});

test('current callback success/error routes use current initialized session', async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const navigation = [];
  await actual.createAuthCallback({ getSession: async () => ({ data: { session: sessionFor(accountA) }, error: null }), navigate: path => navigation.push(path) }).run();
  await actual.createAuthCallback({ getSession: async () => ({ data: { session: null }, error: { message: 'Expired link' } }), navigate: path => navigation.push(path) }).run();
  assert.deepEqual(navigation, ['/polls', '/auth?error=Expired%20link']);
});

for (const outcome of ['success', 'failure']) test(`obsolete poll mutation/detail ${outcome} cannot overwrite B; old route cleanup owns only its lease`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const oldRoute = actual.polls.ownPollDetail();
  await oldRoute.load('poll-A');
  const mutation = deferred();
  state.query = request => request.update ? mutation.promise : { data: request.table === 'polls' ? { id: request.eq.id, creator_id: request.account } : [], error: null };
  const old = actual.polls.updatePollStatus('poll-A', 'closed');
  state.emit('SIGNED_IN', sessionFor(accountB)); await flush();
  const newRoute = actual.polls.ownPollDetail();
  await newRoute.load('poll-B');
  oldRoute.dispose();
  mutation.resolve(outcome === 'success' ? { error: null } : { error: Error('old mutation failed') });
  await old;
  assert.equal(actual.get(actual.polls.currentPoll).id, 'poll-B');
  assert.equal(actual.get(actual.polls.currentPoll).status, undefined);
  newRoute.dispose();
});

for (const outcome of ['success', 'failure']) test(`availability retry stays with A across B and screen recreation (${outcome})`, async t => {
  const { actual } = await fixture(t);
  const snapshot = { poll_id: 'poll', participant_id: 'participant-A', version: 2, comment: 'Saved', responses: [] };
  const pending = deferred(), calls = [];
  const editor = actual.createAvailabilityEditor({ save: operation => { calls.push(structuredClone(operation)); return pending.promise; }, load: async () => snapshot });
  editor.setOwner(accountA); editor.initialize(snapshot); editor.setComment('Original A draft');
  const saving = editor.save();
  editor.setOwner(accountB);
  assert.equal(actual.get(editor).snapshot, null);
  assert.equal(actual.get(editor).comment, '');
  editor.initialize({ ...snapshot, participant_id: 'participant-B' }); editor.setComment('B draft');
  if (outcome === 'success') pending.resolve({ ...snapshot, version: 3, comment: 'Original A draft' }); else pending.reject(Error('offline'));
  await saving;
  assert.equal(actual.get(editor).comment, 'B draft');
  assert.equal(actual.get(editor).error, null);
  editor.invalidate();
  const restored = actual.createAvailabilityEditor({ save: async operation => { calls.push(structuredClone(operation)); return { ...snapshot, version: 3, comment: 'Original A draft', replayed: true }; }, load: async () => snapshot });
  restored.setOwner(accountA); restored.initialize({ ...snapshot, version: 3 });
  assert.equal(actual.get(restored).comment, 'Original A draft');
  await restored.save();
  assert.deepEqual(calls[1], calls[0]);
});

test('creation retry survives A→logout→B→A and recovers original poll with original UUID/payload', async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const storage = disk(), calls = [];
  const poll = { id: 'created-once', creator_id: accountA, is_premium: true, max_participants: 50 };
  const editor = actual.createPollCreation({ create: actual.polls.createPoll }, storage);
  const stop = actual.auth.user.subscribe(user => editor.setOwner(user?.id ?? null));
  t.after(stop);
  editor.edit({ title: 'Exact draft', useEventPass: true, timeOptions: [{ id: 'draft', date: '2026-11-01', startTime: '12:00', endTime: '13:00' }] });
  state.rpc = async (name, args) => { assert.equal(name, 'create_poll'); calls.push(structuredClone(args)); if (calls.length === 1) throw Error('Reply lost after committed pass redemption'); return { data: { poll, time_options: [{ id: 'option', poll_id: poll.id }], redeemed_pass_id: 'same-pass', entitlement: 'event_pass', replayed: true }, error: null }; };
  assert.equal(await editor.submit(), null);
  state.emit('SIGNED_OUT', null); state.emit('SIGNED_IN', sessionFor(accountB));
  assert.equal(actual.get(editor).draft.title, '');
  assert.ok(storage.getItem(`meeting-scheduler:create-poll:${accountA}`));
  state.emit('SIGNED_IN', sessionFor(accountA));
  await flush();
  assert.equal(actual.get(editor).draft.title, 'Exact draft');
  assert.equal(actual.get(editor).uncertain, true);
  assert.equal((await editor.submit()).poll.id, poll.id);
  assert.deepEqual(calls[1], calls[0]);
  assert.equal(actual.get(actual.polls.createdPolls).length, 1);
});

const jwt = account => {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({ sub: account, aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600, iat: Math.floor(Date.now() / 1000) })}.${Buffer.from('signature').toString('base64url')}`;
};
async function sdkTransport(t, state) {
  let locked = false;
  let tail = Promise.resolve();
  const requests = [];
  const control = { requests, logout: null, refresh: null, user: null, aborted: 0 };
  const client = createClient('https://session.test.invalid', 'test-anon-key', {
    auth: {
      persistSession: false, autoRefreshToken: false, detectSessionInUrl: false,
      async lock(_name, _timeout, operation) {
        const previous = tail, release = deferred();
        tail = release.promise;
        await previous;
        locked = true;
        try { return await operation(); } finally { locked = false; release.resolve(); }
      }
    },
    global: {
      async fetch(input, options = {}) {
        const url = new URL(typeof input === 'string' ? input : input.url);
        if (options.signal?.aborted) { control.aborted++; throw new DOMException("Session cancelled", "AbortError"); }
        const headers = new Headers(options.headers);
        const authorization = headers.get('Authorization');
        requests.push({ path: url.pathname, authorization, locked });
        const payload = authorization?.split('.')[1];
        const account = payload ? JSON.parse(Buffer.from(payload, 'base64url').toString()).sub : null;
        if (url.pathname.endsWith('/user')) {
          if (control.user?.account === account) { control.user.started.resolve(); await control.user.finish.promise; }
          return Response.json({ id: account, email: 'sdk@test.invalid' });
        }
        if (url.pathname.endsWith('/logout')) {
          control.logout?.started.resolve();
          if (control.logout) await control.logout.finish.promise;
          return new Response(null, { status: 204 });
        }
        if (url.pathname.endsWith('/token')) {
          control.refresh?.started.resolve();
          if (control.refresh) await control.refresh.finish.promise;
          return Response.json({ access_token: jwt(accountA), refresh_token: 'refreshed-A', token_type: 'bearer', expires_in: 3600, user: { id: accountA } });
        }
        assert.equal(locked, false, `production dependent request ${url.pathname} ran under SDK auth lock`);
        if (url.pathname.endsWith('/profiles')) return Response.json({ id: account, display_name: account });
        if (url.pathname.endsWith('/subscriptions')) return Response.json({ user_id: account });
        if (url.pathname.endsWith('/calendar-connection')) return Response.json(status(account));
        throw Error(`Unexpected SDK request ${url}`);
      }
    }
  });
  await client.auth.initialize();
  state.supabase.auth = client.auth;
  state.supabase.realtime = client.realtime;
  state.supabase.from = (...args) => client.from(...args);
  state.supabase.functions = client.functions;
  t.after(() => { client.auth.stopAutoRefresh(); client.removeAllChannels(); });
  return { client, control };
}

test('real pinned Supabase transport defers dependent reads past auth lock and serializes logout before B installation', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state);
  mount();
  const installed = await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  assert.equal(installed.error, null);
  assert.equal(installed.data.session?.user.id, accountA);
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountA);
  control.logout = { started: deferred(), finish: deferred() };
  const logout = actual.auth.signOut();
  await control.logout.started.promise;
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountA, 'B installation waits on the pinned SDK session lock');
  control.logout.finish.resolve();
  await Promise.all([logout, replacement]);
  await flush();
  assert.equal((await client.auth.getSession()).data.session.user.id, accountB);
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(actual.auth.profile).id, accountB);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), accountB);
  assert.equal(actual.get(actual.billing.subscription).user_id, accountB);
  assert.ok(control.requests.some(request => request.path.endsWith('/profiles') && request.authorization === `Bearer ${jwt(accountB)}`));
});

test('real pinned Supabase transport serializes delayed A refresh before B; SDK credentials and app state agree', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state);
  mount();
  const installed = await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  assert.equal(installed.error, null);
  assert.equal(installed.data.session?.user.id, accountA);
  await flush();
  const generation = actual.get(actual.scope.sessionIdentity).generation;
  control.refresh = { started: deferred(), finish: deferred() };
  const refreshing = client.auth.refreshSession();
  await control.refresh.started.promise;
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountA);
  assert.equal(actual.get(actual.scope.sessionIdentity).generation, generation);
  control.refresh.finish.resolve();
  await Promise.all([refreshing, replacement]);
  await flush();
  const current = (await client.auth.getSession()).data.session;
  assert.equal(current.user.id, accountB);
  assert.equal(current.access_token, jwt(accountB));
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(actual.auth.profile).id, accountB);
});

test('offline session expiry clears visible account promptly, reauthentication creates a distinct A generation', async t => {
  const { actual, state, mount } = await fixture(t);
  mount();
  const session = { ...sessionFor(accountA), expires_at: Date.now() / 1000 + 0.04 };
  state.emit('SIGNED_IN', session);
  await flush();
  const generation = actual.get(actual.scope.sessionIdentity).generation;
  actual.polls.createdPolls.set([{ id: 'A-private' }]);
  await new Promise(resolve => setTimeout(resolve, 50));
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal(actual.get(actual.auth.profile), null);
  assert.deepEqual(actual.get(actual.polls.createdPolls), []);
  assert.equal(actual.get(actual.billing.subscription), null);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), null);
  state.emit('TOKEN_REFRESHED', sessionFor(accountA));
  await flush();
  assert.ok(actual.get(actual.scope.sessionIdentity).generation > generation);
  assert.equal(actual.get(actual.auth.user).id, accountA);
});

for (const event of ['SIGNED_IN', 'TOKEN_REFRESHED', 'SIGNED_OUT']) test(`real SDK stale ${event} broadcast cannot expose A recovery or authorize its creation under SDK B`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client } = await sdkTransport(t, state);
  mount();
  await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  await flush();
  const storage = disk(), calls = [];
  const editor = actual.createPollCreation({ create: actual.polls.createPoll }, storage);
  const stop = actual.auth.user.subscribe(user => editor.setOwner(user?.id ?? null));
  t.after(stop);
  editor.edit({ title: 'A unresolved creation', useEventPass: true, timeOptions: [{ id: 'draft', date: '2026-11-01', startTime: '12:00', endTime: '13:00' }] });
  state.rpc = async (_name, args) => { calls.push(structuredClone(args)); throw Error('reply lost after commit'); };
  assert.equal(await editor.submit(), null);
  const original = storage.getItem(`meeting-scheduler:create-poll:${accountA}`);
  await client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await flush();
  // This is the exact pinned SDK entry point invoked by BroadcastChannel.
  // It emits the obsolete hint without modifying current SDK session storage.
  await client.auth._notifyAllSubscribers(event, event === 'SIGNED_OUT' ? null : { ...sessionFor(accountA), access_token: jwt(accountA) }, false);
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal(actual.get(editor).ownerId, null);
  assert.equal(actual.get(editor).draft.title, '');
  assert.equal(await editor.submit(), null);
  await assert.rejects(actual.polls.createPoll(calls[0]), error => error.code === '42501');
  assert.equal(calls.length, 1, 'no A recovery operation was dispatched while SDK B was current');
  // Another delayed sign-out while verification is pending must not cancel
  // verification and leave the app permanently signed out over SDK B.
  await client.auth._notifyAllSubscribers('SIGNED_OUT', null, false);
  await flush();
  assert.equal((await client.auth.getSession()).data.session.user.id, accountB);
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(editor).ownerId, accountB);
  assert.equal(client.realtime.accessTokenValue, jwt(accountB));
  assert.equal(storage.getItem(`meeting-scheduler:create-poll:${accountA}`), original);
});

for (const event of ['SIGNED_IN', 'TOKEN_REFRESHED', 'USER_UPDATED']) test(`real SDK obsolete same-account ${event} hint cannot expire or replace current B credentials/metadata`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client } = await sdkTransport(t, state);
  mount();
  await client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await flush();
  const generation = actual.get(actual.scope.sessionIdentity).generation;
  const stored = (await client.auth.getSession()).data.session;
  await client.auth._notifyAllSubscribers(event, { ...sessionFor(accountB), expires_at: 1, access_token: 'old-B-token', user: { id: accountB, email: 'OLD' } }, false);
  assert.equal(actual.get(actual.auth.user).id, accountB, 'same-account refresh preserves visible state');
  assert.equal(actual.get(actual.scope.sessionIdentity).generation, generation);
  await flush();
  assert.equal(actual.get(actual.auth.user).email, stored.user.email);
  assert.equal(actual.get(actual.auth.session).access_token, stored.access_token);
  assert.equal(actual.get(actual.auth.session).expires_at, stored.expires_at);
  assert.equal(actual.get(actual.scope.sessionIdentity).generation, generation);
  assert.equal(client.realtime.accessTokenValue, stored.access_token);
});

for (const outcome of ['success', 'failure']) test(`obsolete auth-event verification ${outcome} cannot replace B or clear its state`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount();
  const old = deferred();
  let first = true;
  state.readSession = () => { if (first) { first = false; return old.promise; } return Promise.resolve({ data: { session: state.storedSession }, error: null }); };
  state.emit('SIGNED_IN', sessionFor(accountA));
  await flush();
  state.emit('SIGNED_IN', sessionFor(accountB));
  await flush();
  if (outcome === 'success') old.resolve({ data: { session: sessionFor(accountA) }, error: null }); else old.reject(Error('old validation failed'));
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(actual.auth.profile).id, accountB);
  assert.equal(actual.get(actual.auth.authLoading), false);
});

for (const kind of ['info', 'offerings']) for (const outcome of ['success', 'failure']) test(`delayed provider ${kind} ${outcome} does not block observing B or publish old state`, async t => {
  const { actual, state, mount } = await fixture(t);
  const old = deferred();
  let first = true;
  if (kind === 'info') state.info = account => { if (account === accountA && first) { first = false; return old.promise; } return Promise.resolve({ account, entitlements: { active: {} } }); };
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  let reading;
  if (kind === 'offerings') {
    state.offerings = account => { if (account === accountA && first) { first = false; return old.promise; } return Promise.resolve({ current: { availablePackages: [{ identifier: account }] } }); };
    reading = actual.billing.loadOfferings();
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
  }
  state.emit('SIGNED_IN', sessionFor(accountB)); await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB, 'provider I/O does not block later auth');
  assert.equal(actual.get(actual.auth.profile).id, accountB);
  if (outcome === 'failure') old.reject(Error('old provider failure'));
  else old.resolve(kind === 'info' ? { account: accountA, entitlements: { active: {} } } : { current: { availablePackages: [{ identifier: accountA }] } });
  await reading;
  await flush();
  assert.equal(actual.get(actual.billing.customerInfo).account, accountB);
  assert.equal(state.provider.getAppUserId(), accountB);
  assert.deepEqual(actual.get(actual.billing.offerings), []);
});

for (const outcome of ['success', 'failure']) test(`old calendar disconnect ${outcome}/finally cannot clear B's active conflict request`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const old = deferred(), current = deferred();
  state.invoke = (name, options) => options.body.action === 'disconnect' ? old.promise : name === 'check-calendar-conflicts' ? current.promise : Promise.resolve({ data: status(state.account), error: null });
  const disconnect = actual.calendar.disableCalendarIntegration();
  const rejected = assert.rejects(disconnect, /Session changed/);
  state.emit('SIGNED_IN', sessionFor(accountB)); await flush();
  const conflicts = actual.calendar.checkCalendarConflicts([{ id: 'B-option', start_time: '2026-11-01T12:00:00Z', end_time: '2026-11-01T13:00:00Z' }]);
  assert.equal(actual.get(actual.calendar.calendarLoading), true);
  old.resolve(outcome === 'success' ? { data: { ...status(null), connected: false }, error: null } : { data: null, error: Error('obsolete disconnect failed') });
  await rejected;
  assert.equal(actual.get(actual.calendar.calendarLoading), true);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), accountB);
  current.resolve({ data: { success: true, conflictingIds: ['B-option'] }, error: null });
  await conflicts;
  assert.deepEqual([...actual.get(actual.calendar.calendarConflicts)], ['B-option']);
});

for (const path of ['A-B', 'A-logout-A', 'A-B-A']) for (const outcome of ['success', 'failure']) test(`cancelled list/detail ${outcome} is fenced across ${path}`, async t => {
  const { actual, state, mount } = await fixture(t);
  mount(); state.emit('SIGNED_IN', sessionFor(accountA)); await flush();
  const list = deferred(), detail = deferred();
  let firstList = true, firstDetail = true;
  state.rpc = name => {
    assert.equal(name, 'get_user_participated_polls');
    if (firstList) { firstList = false; return list.promise; }
    return { data: { created_polls: [{ id: 'CURRENT', creator_id: state.account }], joined_polls: [] }, error: null };
  };
  state.query = request => {
    if (request.table === 'polls' && firstDetail) { firstDetail = false; return detail.promise; }
    return { data: request.table === 'polls' ? { id: request.eq.id, creator_id: request.account } : request.table === 'profiles' ? { id: request.eq.id } : [], error: null };
  };
  const oldList = actual.polls.loadParticipatedPolls();
  const oldDetail = actual.polls.loadPoll('OLD');
  await Promise.resolve();
  const oldListRequest = state.rpcRequests.at(-1);
  const oldDetailRequest = state.requests.findLast(request => request.table === 'polls');
  state.emit(path === 'A-logout-A' ? 'SIGNED_OUT' : 'SIGNED_IN', path === 'A-logout-A' ? null : sessionFor(accountB));
  if (path !== 'A-B') state.emit('SIGNED_IN', sessionFor(accountA));
  await flush();
  await actual.polls.loadParticipatedPolls();
  await actual.polls.loadPoll('CURRENT');
  assert.equal(oldListRequest.signal.aborted, true);
  assert.equal(oldDetailRequest.signal.aborted, true);
  list.resolve(outcome === 'success' ? { data: { created_polls: [{ id: 'OLD' }], joined_polls: [] }, error: null } : { data: null, error: Error('old list failure') });
  detail.resolve(outcome === 'success' ? { data: { id: 'OLD', creator_id: accountA }, error: null } : { data: null, error: Error('old detail failure') });
  await Promise.all([oldList, oldDetail]);
  assert.equal(actual.get(actual.polls.currentPoll).id, 'CURRENT');
  assert.deepEqual(actual.get(actual.polls.createdPolls).map(poll => poll.id), ['CURRENT']);
  assert.equal(actual.get(actual.polls.pollsLoading), false);
});


test('real SDK queued creation cannot resolve B credentials for an operation captured by A', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state);
  state.supabase.rpc = (...args) => client.rpc(...args);
  mount();
  await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  await flush();
  const storage = disk();
  const editor = actual.createPollCreation({ create: actual.polls.createPoll }, storage);
  const stop = actual.auth.user.subscribe(value => editor.setOwner(value?.id ?? null));
  t.after(stop);
  editor.edit({ title: 'A private recovery', useEventPass: true, timeOptions: [{ id: 'draft', date: '2026-11-01', startTime: '12:00', endTime: '13:00' }] });
  control.user = { account: accountB, started: deferred(), finish: deferred() };
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await control.user.started.promise;
  assert.equal(actual.get(actual.auth.user).id, accountA);
  const creation = editor.submit();
  // The command waits behind B installation's SDK lock while its durable owner
  // and exact recovery payload are still A. Cancellation must reach Fetch.
  await Promise.resolve();
  control.user.finish.resolve();
  await replacement;
  assert.equal(await creation, null);
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(editor).draft.title, '');
  assert.ok(storage.getItem(`meeting-scheduler:create-poll:${accountA}`));
  assert.equal(storage.getItem(`meeting-scheduler:create-poll:${accountB}`), null);
  assert.equal(control.requests.filter(request => request.path.endsWith('/rpc/create_poll')).length, 0);
  assert.equal(control.aborted, 1);
});
