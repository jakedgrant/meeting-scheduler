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
const realSDK = requireWeb('@supabase/supabase-js');
const { createClient } = realSDK;
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
const summaryPage = (polls, role) => ({ data: { items: polls.map(poll => ({ poll, role, participant_count: 0, time_option_count: 0, earliest_start: null, latest_start: null })), has_more: false, next_cursor: null, total_count: polls.length }, error: null });
const pollDetail = poll => ({ data: { poll, time_options: [], participants: [], time_option_count: 0, participant_count: 0 }, error: null });
// F19 read RPCs answer for the account that issued the request.
const defaultRpc = (name, args, account) => name === 'get_poll_detail' ? pollDetail({ id: args.poll_uuid, creator_id: account })
  : name === 'list_poll_responses' || name === 'list_poll_summaries' ? summaryPage([], args?.role_filter)
  : { data: null, error: null };

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
      const response = (async () => (await state.rpc?.(name, args)) ?? defaultRpc(name, args, request.account))();
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
  state.realSDK = realSDK;
  state.ownedListeners = new Set();
  state.ownedAuth = {
    subscribe(listener) { state.ownedListeners.add(listener); return () => state.ownedListeners.delete(listener); },
    syncRealtime(session) { return state.supabase.realtime.setAuth(session?.access_token ?? 'test-anon-key'); },
    signOut() {
      const local = Promise.resolve().then(() => { state.storedSession = null; state.account = null; for (const listener of state.ownedListeners) listener(null); return true; });
      const remote = local.then(() => state.signOut?.());
      return { local, remote };
    }
  };
  globalThis[key] = state;
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `import * as auth from '${lib}/stores/auth.ts'; import * as polls from '${lib}/stores/polls.ts'; import * as calendar from '${lib}/stores/calendar.ts'; import * as billing from '${lib}/stores/subscription.ts'; import * as rc from '${lib}/revenuecat.ts'; import * as scope from '${lib}/session-scope.ts'; export {auth,polls,calendar,billing,rc,scope}; export {createOwnedAuth,memoryAuthStorage} from '${lib}/owned-auth.ts'; export {mountClientSession} from '${lib}/client-session.ts'; export {createSessionExpiry} from '${lib}/session-expiry.ts'; export {createAuthCallback} from '${lib}/auth-callback.ts'; export {createAvailabilityEditor} from '${lib}/availability-editor.ts'; export {createPollCreation} from '${lib}/poll-creation.ts'; export {get} from 'svelte/store'; export {render} from 'svelte/server'; export {default as Layout} from '${web}/src/routes/+layout.svelte';`, resolveDir: web },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    define: { 'import.meta.env.VITE_REVENUECAT_WEB_KEY': '"test-key"' },
    plugins: [{ name: 'offline-session', setup(b) {
      b.onResolve({ filter: /^\$lib\// }, args => args.path.endsWith('favicon.svg') ? { path: 'favicon', namespace: 'fixture' } : args.path === '$lib/supabase' ? { path: 'supabase', namespace: 'fixture' } : { path: join(lib, `${args.path.slice(5)}.ts`) });
      b.onResolve({ filter: /^\$app\/environment$/ }, () => ({ path: 'environment', namespace: 'fixture' }));
      b.onResolve({ filter: /^@supabase\/supabase-js$/ }, () => ({ path: 'real-sdk', namespace: 'fixture' }));
      b.onResolve({ filter: /^@revenuecat\/purchases-js$/ }, () => ({ path: 'provider', namespace: 'fixture' }));
      b.onResolve({ filter: /favicon\.svg$/ }, () => ({ path: 'favicon', namespace: 'fixture' }));
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: {
        supabase: `export const supabase=globalThis.${key}.supabase; export const ownedAuth=new Proxy({}, {get:(_,name)=>globalThis.${key}.ownedAuth[name]});`,
        'real-sdk': `export const {AuthClient,createClient,navigatorLock,processLock}=globalThis.${key}.realSDK;`,
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
  assert.equal(state.channels.length, 0, 'poll detail opens no broad Realtime listener');
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

const tokenIssuedAt = Math.floor(Date.now() / 1000);
const jwt = (account, lineage = 'session-1') => {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode({ sub: account, session_id: `${account}:${lineage}`, aud: 'authenticated', exp: tokenIssuedAt + 3600, iat: tokenIssuedAt })}.${Buffer.from('signature').toString('base64url')}`;
};
async function sdkTransport(t, state, actual) {
  let locked = false;
  let tail = Promise.resolve();
  const requests = [];
  const control = { requests, logout: null, refresh: null, user: null, aborted: 0 };
  const runtime = actual.createOwnedAuth({ url: 'https://session.test.invalid', key: 'test-anon-key', storage: state.authStorage ?? actual.memoryAuthStorage(),
      async lock(_name, _timeout, operation) {
        const previous = tail, release = deferred();
        tail = release.promise;
        await previous;
        locked = true;
        try { return await operation(); } finally { locked = false; release.resolve(); }
      },
      async fetch(input, options = {}) {
        const url = new URL(typeof input === 'string' ? input : input.url);
        if (options.signal?.aborted) { control.aborted++; throw new DOMException("Session cancelled", "AbortError"); }
        const headers = new Headers(options.headers);
        const authorization = headers.get('Authorization');
        requests.push({ path: url.pathname, authorization, locked, search: url.search, body: options.body });
        const payload = authorization?.split('.')[1];
        const account = payload ? JSON.parse(Buffer.from(payload, 'base64url').toString()).sub : null;
        if (url.pathname.endsWith('/user')) {
          if (control.user?.account === account) { control.user.started.resolve(); await control.user.finish.promise; }
          return Response.json({ id: account, email: 'sdk@test.invalid' });
        }
        if (url.pathname.endsWith('/logout')) {
          control.logout?.started.resolve();
          if (control.logout && (!control.logout.account || control.logout.account === account)) await control.logout.finish.promise;
          if (control.logout?.failure && (!control.logout.account || control.logout.account === account)) return Response.json({ message: 'Revocation unavailable' }, { status: 500 });
          return new Response(null, { status: 204 });
        }
        if (url.pathname.endsWith('/otp')) return Response.json({});
        if (url.pathname.endsWith('/token')) {
          if (url.searchParams.get('grant_type') === 'pkce') {
            control.callback?.started.resolve();
            if (control.callback) await control.callback.finish.promise;
            if (control.callback?.failure) return Response.json({ error: 'invalid_grant', error_description: 'Expired code' }, { status: 400 });
            return Response.json({ access_token: jwt(accountA, 'callback-session'), refresh_token: 'callback-refresh', token_type: 'bearer', expires_in: 3600, user: { id: accountA } });
          }
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
  });
  const client = runtime.client;
  state.ownedAuth = runtime;
  await client.auth.initialize();
  state.supabase.auth = client.auth;
  state.supabase.realtime = client.realtime;
  state.supabase.from = (...args) => client.from(...args);
  state.supabase.functions = client.functions;
  t.after(() => { client.auth.stopAutoRefresh(); client.removeAllChannels(); });
  return { client, control, runtime };
}

test('real pinned Supabase transport defers dependent reads past auth lock and serializes logout before B installation', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount();
  const installed = await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  assert.equal(installed.error, null);
  assert.equal(installed.data.session?.user.id, accountA);
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountA);
  control.logout = { started: deferred(), finish: deferred() };
  const logout = actual.auth.signOut();
  assert.equal(actual.get(actual.auth.user), null, 'explicit sign-out hides A before slow cleanup');
  await control.logout.started.promise;
  assert.ok(control.requests.some(request => request.path.endsWith('/logout') && request.search === '?scope=local'));
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await replacement;
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB, 'remote A revocation does not block B installation');
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
  const { client, control } = await sdkTransport(t, state, actual);
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
  const { client } = await sdkTransport(t, state, actual);
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
  const { client } = await sdkTransport(t, state, actual);
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
  state.rpc = (name, args) => {
    if (name === 'list_poll_summaries') {
      if (firstList) { firstList = false; return list.promise; }
      return summaryPage(args.role_filter === 'owner' ? [{ id: 'CURRENT', creator_id: state.account }] : [], args.role_filter);
    }
    if (name === 'get_poll_detail' && firstDetail) { firstDetail = false; return detail.promise; }
    assert.ok(['list_poll_summaries', 'get_poll_detail', 'list_poll_responses'].includes(name), name);
  };
  const oldList = actual.polls.loadParticipatedPolls();
  const oldDetail = actual.polls.loadPoll('OLD');
  await Promise.resolve();
  const oldListRequests = state.rpcRequests.filter(request => request.name === 'list_poll_summaries');
  const oldDetailRequest = state.rpcRequests.findLast(request => request.name === 'get_poll_detail');
  assert.equal(oldListRequests.length, 2, 'one first page per section, independent of history size');
  state.emit(path === 'A-logout-A' ? 'SIGNED_OUT' : 'SIGNED_IN', path === 'A-logout-A' ? null : sessionFor(accountB));
  if (path !== 'A-B') state.emit('SIGNED_IN', sessionFor(accountA));
  await flush();
  await actual.polls.loadParticipatedPolls();
  await actual.polls.loadPoll('CURRENT');
  for (const request of oldListRequests) assert.equal(request.signal.aborted, true);
  assert.equal(oldDetailRequest.signal.aborted, true);
  list.resolve(outcome === 'success' ? summaryPage([{ id: 'OLD', creator_id: accountA }], 'owner') : { data: null, error: Error('old list failure') });
  detail.resolve(outcome === 'success' ? pollDetail({ id: 'OLD', creator_id: accountA }) : { data: null, error: Error('old detail failure') });
  await Promise.all([oldList, oldDetail]);
  assert.equal(actual.get(actual.polls.currentPoll).id, 'CURRENT');
  assert.deepEqual(actual.get(actual.polls.createdPolls).map(poll => poll.id), ['CURRENT']);
  assert.equal(actual.get(actual.polls.pollsLoading), false);
});


test('real SDK queued creation cannot resolve B credentials for an operation captured by A', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
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


test('real SDK queued calendar disconnect cannot resolve B credentials for an A action', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount();
  await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'refresh-A' });
  await flush();
  control.user = { account: accountB, started: deferred(), finish: deferred() };
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'refresh-B' });
  await control.user.started.promise;
  const disconnect = actual.calendar.disableCalendarIntegration().catch(error => error);
  await Promise.resolve();
  control.user.finish.resolve();
  await replacement;
  await disconnect;
  await flush();
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.equal(actual.get(actual.calendar.calendarEnabled), true);
  assert.equal(actual.get(actual.calendar.calendarAccountEmail), accountB);
  assert.equal(control.requests.filter(request => request.path.endsWith('/calendar-connection') && JSON.parse(request.body ?? '{}').action === 'disconnect').length, 0);
  assert.equal(control.aborted, 1);
});

for (const replacement of ['B', 'new-A']) for (const outcome of ['success', 'failure']) test(`queued original-A logout ${outcome} preserves installed ${replacement} SDK credentials and UI`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount();
  await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  const next = replacement === 'B' ? accountB : accountA;
  control.user = { account: next, started: deferred(), finish: deferred() };
  const nextToken = jwt(next, 'new-session');
  const installing = client.auth.setSession({ access_token: nextToken, refresh_token: 'new-refresh' });
  await control.user.started.promise;
  control.logout = { started: deferred(), finish: deferred(), failure: outcome === 'failure' };
  const logout = actual.auth.signOut();
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal(actual.get(actual.auth.profile), null);
  assert.equal(actual.get(actual.billing.customerInfo), null);
  assert.equal(actual.get(actual.calendar.calendarEnabled), false);
  control.user.finish.resolve(); await installing;
  await control.logout.started.promise; await flush();
  assert.equal(actual.get(actual.auth.user).id, next);
  assert.equal((await client.auth.getSession()).data.session.access_token, nextToken);
  assert.equal(client.realtime.accessTokenValue, nextToken);
  control.logout.finish.resolve();
  assert.equal(await logout, false);
  await flush();
  assert.equal((await client.auth.getSession()).data.session.access_token, nextToken);
  assert.equal(actual.get(actual.auth.user).id, next);
  const revocations = control.requests.filter(request => request.path.endsWith('/logout'));
  assert.equal(revocations.length, 1);
  assert.equal(revocations[0].authorization, `Bearer ${jwt(accountA)}`);
  assert.equal(revocations[0].search, '?scope=local');
  assert.equal(revocations[0].locked, false, 'remote revocation runs outside SDK storage lock');
});

for (const outcome of ['success', 'failure']) test(`explicit logout clears local SDK session before slow remote ${outcome}`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount(); await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  control.logout = { started: deferred(), finish: deferred(), failure: outcome === 'failure' };
  const logout = actual.auth.signOut();
  const done = outcome === 'failure' ? assert.rejects(logout) : logout;
  assert.equal(actual.get(actual.auth.user), null);
  await control.logout.started.promise;
  assert.equal((await client.auth.getSession()).data.session, null);
  assert.equal(client.realtime.accessTokenValue, 'test-anon-key');
  // A stale refresh/broadcast cannot restore the explicitly ended lineage.
  await client.auth._notifyAllSubscribers('TOKEN_REFRESHED', { ...sessionFor(accountA), access_token: jwt(accountA) }, false);
  await flush(); assert.equal(actual.get(actual.auth.user), null);
  control.logout.finish.resolve(); await done;
  assert.equal((await client.auth.getSession()).data.session, null);
  assert.equal(actual.get(actual.auth.user), null);
});

test('queued original logout accepts ordinary same-session refresh but never a new A lineage', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount(); await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  control.refresh = { started: deferred(), finish: deferred() };
  const refresh = client.auth.refreshSession(); await control.refresh.started.promise;
  const logout = actual.auth.signOut();
  control.refresh.finish.resolve(); await refresh; await logout; await flush();
  assert.equal((await client.auth.getSession()).data.session, null);
  assert.equal(actual.get(actual.auth.user), null);
});

function callbackURL(authorizationURL) {
  const redirect = new URL(authorizationURL).searchParams.get('redirect_to');
  assert.ok(redirect);
  const url = new URL(redirect); url.searchParams.set('code', 'valid-code'); return url;
}

test('production PKCE initiation/exchange persists exact intent, installs once, and preserves original storage key', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, runtime, control } = await sdkTransport(t, state, actual);
  mount(); await flush();
  assert.equal(runtime.storageKey, 'sb-session-auth-token');
  const url = callbackURL(await runtime.start({ provider: 'google' }, null, 'https://web.test.invalid'));
  assert.ok(new URLSearchParams(new URL(await runtime.start({ provider: 'apple' }, null, 'https://web.test.invalid')).search).get('code_challenge'));
  await assert.rejects(runtime.complete(url), /expired|another session/);
  const latest = callbackURL(await runtime.start({ provider: 'google' }, null, 'https://web.test.invalid'));
  const result = await runtime.complete(latest); await flush();
  assert.equal(result.user.id, accountA);
  assert.equal((await client.auth.getSession()).data.session.access_token, jwt(accountA, 'callback-session'));
  assert.equal(actual.get(actual.auth.user).id, accountA);
  await assert.rejects(runtime.complete(latest), /already used/);
  assert.equal(control.requests.filter(request => request.search === '?grant_type=pkce').length, 1);
});

for (const replacement of ['B', 'new-A']) test(`queued PKCE callback cannot install obsolete A over ${replacement}`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, runtime, control } = await sdkTransport(t, state, actual);
  mount(); await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  const original = (await client.auth.getSession()).data.session;
  const url = callbackURL(await runtime.start({ provider: 'google' }, original, 'https://web.test.invalid'));
  const next = replacement === 'B' ? accountB : accountA;
  control.user = { account: next, started: deferred(), finish: deferred() };
  const token = jwt(next, 'new-session');
  const installing = client.auth.setSession({ access_token: token, refresh_token: 'new-refresh' });
  await control.user.started.promise;
  const callback = runtime.complete(url); const rejected = assert.rejects(callback, /another session/);
  control.user.finish.resolve(); await installing; await rejected; await flush();
  assert.equal((await client.auth.getSession()).data.session.access_token, token);
  assert.equal(actual.get(actual.auth.user).id, next);
  assert.equal(control.requests.filter(request => request.search === '?grant_type=pkce').length, 0);
});

for (const outcome of ['success', 'failure']) test(`PKCE ${outcome} while B installation waits cannot later clear B`, async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, runtime, control } = await sdkTransport(t, state, actual);
  mount(); await flush();
  const url = callbackURL(await runtime.start({ provider: 'google' }, null, 'https://web.test.invalid'));
  control.callback = { started: deferred(), finish: deferred(), failure: outcome === 'failure' };
  const callback = runtime.complete(url);
  const callbackDone = outcome === 'failure' ? assert.rejects(callback) : callback;
  await control.callback.started.promise;
  const replacement = client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'B-1' });
  control.callback.finish.resolve(); await callbackDone; await replacement; await flush();
  assert.equal((await client.auth.getSession()).data.session.user.id, accountB);
  assert.equal(actual.get(actual.auth.user).id, accountB);
});

function browserFixture(t, url) {
  const originals = new Map(['window', 'document', 'BroadcastChannel'].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const listeners = new Map(), channels = [];
  const window = {
    location: new URL(url),
    addEventListener(name, listener) { if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(listener); },
    removeEventListener(name, listener) { listeners.get(name)?.delete(listener); },
    history: { replaceState() {} }
  };
  const restore = () => { for (const [key, descriptor] of originals) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key]; } };
  Object.defineProperty(globalThis, 'window', { configurable: true, value: window });
  Object.defineProperty(globalThis, 'document', { configurable: true, value: { visibilityState: 'visible' } });
  Object.defineProperty(globalThis, 'BroadcastChannel', { configurable: true, value: class {
    constructor(name) { this.name = name; this.listeners = []; channels.push(this); }
    addEventListener(_name, listener) { this.listeners.push(listener); }
    postMessage() {}
    close() { this.listeners = []; }
  } });
  t.after(restore);
  return { window, listeners, channels, restore };
}

test('cold root callback completes owned PKCE before mounting production callback navigator; helper leaves no extra listener/channel', async t => {
  const { actual, state, mount } = await fixture(t);
  state.authStorage = actual.memoryAuthStorage();
  const first = await sdkTransport(t, state, actual);
  const url = callbackURL(await first.runtime.start({ provider: 'google' }, null, 'https://web.test.invalid'));
  const browser = browserFixture(t, url);
  const { client } = await sdkTransport(t, state, actual);
  assert.equal((await client.auth.getSession()).data.session, null, 'main SDK does not auto-install callback URL');
  const stop = mount();
  assert.equal(actual.get(actual.auth.authLoading), true);
  await flush();
  assert.equal(actual.get(actual.auth.authLoading), false);
  assert.equal(actual.get(actual.auth.authCallbackError), null);
  assert.equal(actual.get(actual.auth.user).id, accountA);
  const navigation = [];
  const navigator = actual.createAuthCallback({ getSession: () => client.auth.getSession(), navigate: path => navigation.push(path) });
  await navigator.run();
  assert.deepEqual(navigation, ['/polls']);
  assert.equal(browser.channels.length, 1, 'only main SDK owns BroadcastChannel; helper has virtual empty namespace');
  assert.equal(browser.listeners.get('visibilitychange').size, 1, 'only main SDK retains visibility observer');
  assert.equal(browser.listeners.get('storage').size, 1);
  navigator.dispose(); stop(); await client.auth.stopAutoRefresh();
  assert.equal(browser.listeners.get('storage').size, 0);
  assert.equal(browser.listeners.get('visibilitychange').size, 0);
  browser.restore();
});

for (const artifact of ['implicit', 'unowned-code', 'obsolete-owned-code']) test(`cold SDK URL initialization preserves persisted B against ${artifact}`, async t => {
  const { actual, state, mount } = await fixture(t);
  state.authStorage = actual.memoryAuthStorage();
  const first = await sdkTransport(t, state, actual);
  await first.client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' });
  let url = new URL('https://web.test.invalid/auth/callback?code=unowned');
  if (artifact === 'obsolete-owned-code') url = callbackURL(await first.runtime.start({ provider: 'google' }, (await first.client.auth.getSession()).data.session, 'https://web.test.invalid'));
  if (artifact === 'implicit') url = new URL(`https://web.test.invalid/auth/callback#access_token=${jwt(accountA)}&refresh_token=old-A&expires_in=3600&token_type=bearer`);
  await first.client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'B-1' });
  const browser = browserFixture(t, url);
  const { client, control } = await sdkTransport(t, state, actual);
  assert.equal((await client.auth.getSession()).data.session.user.id, accountB);
  const stop = mount(); await flush();
  assert.equal((await client.auth.getSession()).data.session.user.id, accountB);
  assert.equal(actual.get(actual.auth.user).id, accountB);
  assert.ok(actual.get(actual.auth.authCallbackError));
  assert.equal(control.requests.filter(request => request.search === '?grant_type=pkce').length, 0);
  stop(); await client.auth.stopAutoRefresh(); browser.restore();
});

test('external storage replacement/refresh is observed once and disposal removes cross-tab listener/deferred work', async t => {
  const { actual, state, mount } = await fixture(t);
  const browser = browserFixture(t, 'https://web.test.invalid/polls');
  state.authStorage = actual.memoryAuthStorage();
  const { client, runtime } = await sdkTransport(t, state, actual);
  const old = mount(), current = mount();
  await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  assert.equal(browser.listeners.get('storage').size, 1);
  const generation = actual.get(actual.scope.sessionIdentity).generation;
  const refreshed = { ...sessionFor(accountA), access_token: jwt(accountA), refresh_token: 'A-refresh' };
  await state.authStorage.setItem(runtime.storageKey, JSON.stringify(refreshed));
  for (const listener of browser.listeners.get('storage')) listener({ key: runtime.storageKey, newValue: JSON.stringify(refreshed) });
  await flush();
  assert.equal(actual.get(actual.scope.sessionIdentity).generation, generation);
  const replacement = { ...sessionFor(accountB), access_token: jwt(accountB), refresh_token: 'B-1' };
  await state.authStorage.setItem(runtime.storageKey, JSON.stringify(replacement));
  for (const listener of browser.listeners.get('storage')) listener({ key: runtime.storageKey, newValue: JSON.stringify(replacement) });
  assert.equal(actual.get(actual.auth.user), null);
  old(); await flush(); assert.equal(actual.get(actual.auth.user).id, accountB);
  current(); assert.equal(browser.listeners.get('storage').size, 0);
  await flush(); assert.equal(actual.get(actual.auth.user), null);
  await client.auth.stopAutoRefresh(); browser.restore();
});

for (const request of [{ email: 'test@example.invalid' }, { provider: 'apple' }]) test(`owned ${'email' in request ? 'OTP' : 'Apple OAuth'} initiation retains PKCE intent and rejects malformed/expired/cancelled routes`, async t => {
  const { actual, state } = await fixture(t);
  state.authStorage = actual.memoryAuthStorage();
  const { runtime, control, client } = await sdkTransport(t, state, actual);
  const authorization = await runtime.start(request, null, 'https://web.test.invalid');
  const raw = JSON.parse(await state.authStorage.getItem(`${runtime.storageKey}:sign-in-attempt`));
  assert.ok(raw.verifier);
  const url = authorization ? callbackURL(authorization) : new URL(`https://web.test.invalid/auth/callback?attempt=${raw.id}&code=valid`);
  const calendar = new URL(url); calendar.pathname = '/settings';
  await assert.rejects(runtime.complete(calendar), /expired|another session/);
  const cancelled = new URL(url); cancelled.searchParams.set('error', 'access_denied');
  await assert.rejects(runtime.complete(cancelled), /cancelled/);
  raw.expires = 1; await state.authStorage.setItem(`${runtime.storageKey}:sign-in-attempt`, JSON.stringify(raw));
  await assert.rejects(runtime.complete(url), /expired/);
  assert.equal((await client.auth.getSession()).data.session, null);
  assert.equal(control.requests.filter(request => request.search === '?grant_type=pkce').length, 0);
});

test('original A logout queued behind real SDK initialization reads ownership inside the SDK lock and preserves B', async t => {
  const { actual, state } = await fixture(t);
  const ready = deferred(), began = deferred(), disk = actual.memoryAuthStorage();
  const key = 'sb-initialize-auth-token';
  const persistedB = { ...sessionFor(accountB), access_token: jwt(accountB), refresh_token: 'B-1' };
  await disk.setItem(key, JSON.stringify(persistedB));
  let first = true, tail = Promise.resolve();
  const requests = [];
  const runtime = actual.createOwnedAuth({ url: 'https://initialize.test.invalid', key: 'anon',
    storage: { async getItem(name) { if (name === key && first) { first = false; began.resolve(); await ready.promise; } return disk.getItem(name); }, setItem: disk.setItem, removeItem: disk.removeItem },
    async lock(_name, _timeout, operation) { const previous = tail, release = deferred(); tail = release.promise; await previous; try { return await operation(); } finally { release.resolve(); } },
    async fetch(_input, options) { requests.push(new Headers(options.headers).get('Authorization')); return new Response(null, { status: 204 }); }
  });
  await began.promise;
  const original = { ...sessionFor(accountA), access_token: jwt(accountA), refresh_token: 'A-1' };
  const logout = runtime.signOut(original);
  ready.resolve();
  assert.equal(await logout.local, false);
  await logout.remote;
  assert.equal((await runtime.client.auth.getSession()).data.session.user.id, accountB);
  assert.deepEqual(requests, [`Bearer ${original.access_token}`]);
  await runtime.client.auth.stopAutoRefresh();
});

test('fresh login to same account advances generation while ordinary token refresh retains it', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client } = await sdkTransport(t, state, actual);
  mount(); await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  const before = actual.get(actual.scope.sessionIdentity).generation;
  const originalScope = actual.scope.captureSession();
  await client.auth.refreshSession(); await flush();
  assert.equal(actual.get(actual.scope.sessionIdentity).generation, before);
  assert.equal(originalScope.isCurrent(), true);
  await client.auth.setSession({ access_token: jwt(accountA, 'fresh-login'), refresh_token: 'new-A' }); await flush();
  assert.ok(actual.get(actual.scope.sessionIdentity).generation > before);
  assert.equal(originalScope.isCurrent(), false);
  assert.equal(actual.get(actual.auth.user).id, accountA);
});

test('old logout failure cannot report into a later signed-out generation after B logs out', async t => {
  const { actual, state, mount } = await fixture(t);
  const { client, control } = await sdkTransport(t, state, actual);
  mount(); await client.auth.setSession({ access_token: jwt(accountA), refresh_token: 'A-1' }); await flush();
  control.logout = { account: accountA, started: deferred(), finish: deferred(), failure: true };
  const old = actual.auth.signOut(); await control.logout.started.promise;
  await client.auth.setSession({ access_token: jwt(accountB), refresh_token: 'B-1' }); await flush();
  assert.equal(await actual.auth.signOut(), true); await flush();
  control.logout.finish.resolve();
  assert.equal(await old, false);
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal((await client.auth.getSession()).data.session, null);
});

for (const outcome of ['success', 'failure']) test(`disposed cold callback ${outcome} cannot install SDK credentials or resurrect root state`, async t => {
  const { actual, state, mount } = await fixture(t);
  state.authStorage = actual.memoryAuthStorage();
  const first = await sdkTransport(t, state, actual);
  const url = callbackURL(await first.runtime.start({ provider: 'google' }, null, 'https://web.test.invalid'));
  const browser = browserFixture(t, url);
  const { client, control } = await sdkTransport(t, state, actual);
  control.callback = { started: deferred(), finish: deferred(), failure: outcome === 'failure' };
  const stop = mount(); await control.callback.started.promise;
  stop(); control.callback.finish.resolve(); await flush();
  assert.equal((await client.auth.getSession()).data.session, null);
  assert.equal(actual.get(actual.auth.user), null);
  assert.equal(actual.get(actual.auth.authCallbackError), null);
  assert.equal(browser.listeners.get('storage').size, 0);
  await client.auth.stopAutoRefresh(); browser.restore();
});
