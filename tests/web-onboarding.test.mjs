import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// The /welcome flow's rules, bundled from the web source.
const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const directory = await mkdtemp(join(tmpdir(), 'web-onboarding-'));
const output = join(directory, 'bundle.mjs');
await build({
  stdin: { contents: `export * from '${join(root, 'apps/web/src/lib/onboarding.ts')}'; export * from '${join(root, 'apps/web/src/lib/calendar-result.ts')}';`, resolveDir: join(root, 'apps/web') },
  outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {}
});
const onboarding = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));

const memoryStorage = () => {
  const values = new Map();
  return { values, getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) };
};

test('the step comes from the URL and defaults to the name step', () => {
  assert.equal(onboarding.parseStep('calendar'), 'calendar');
  assert.equal(onboarding.parseStep('name'), 'name');
  assert.equal(onboarding.parseStep(null), 'name');
  assert.equal(onboarding.parseStep('finish'), 'name');
});

test('next accepts only a same-origin path that does not loop back into sign-in or onboarding', () => {
  assert.equal(onboarding.safeNext('/polls/abc?tab=results#top'), '/polls/abc?tab=results#top');
  assert.equal(onboarding.safeNext('/join/BFZZ7J'), '/join/BFZZ7J');
  for (const value of [null, '', 'polls', 'https://evil.example/', '//evil.example/path', '/\\evil.example',
    'javascript:alert(1)', '/.//evil.example', '/a/..//evil.example', '/./\t/evil.example', '/welcome', '/welcome/', '/%77elcome', '/%61uth', '/auth/', '/%E0%A4%A', '/welcome', '/welcome?step=calendar', '/auth', '/auth/callback?attempt=1']) {
    assert.equal(onboarding.safeNext(value), onboarding.HOME, String(value));
  }
  assert.equal(onboarding.safeNext('/authors'), '/authors');
});

test('step links keep next only when it is not home', () => {
  assert.equal(onboarding.welcomeHref('calendar', onboarding.HOME), '/welcome?step=calendar');
  assert.equal(onboarding.welcomeHref('name', '/polls/abc?x=1'), '/welcome?step=name&next=%2Fpolls%2Fabc%3Fx%3D1');
  const href = new URL(onboarding.welcomeHref('name', '/polls/abc?x=1'), 'https://meetful.invalid');
  assert.equal(onboarding.safeNext(href.searchParams.get('next')), '/polls/abc?x=1');
});

test('the saved name is trimmed and blank means Anonymous', () => {
  assert.equal(onboarding.normalizeName('  Jake  '), 'Jake');
  assert.equal(onboarding.normalizeName('   '), null);
  assert.equal(onboarding.normalizeName('x'.repeat(60)).length, onboarding.DISPLAY_NAME_MAX);
  assert.deepEqual(onboarding.previewOf(' jake '), { name: 'jake', initial: 'J' });
  assert.deepEqual(onboarding.previewOf(''), { name: 'Anonymous', initial: null });
  // The initial is the first grapheme, so a composed character stays whole.
  assert.equal(onboarding.previewOf('émile').initial, 'É');
  assert.equal(onboarding.previewOf('👩🏽‍💻 Ana').initial, '👩🏽‍💻');
});

test('the name prefills from the profile, then from the sign-in provider', () => {
  assert.equal(onboarding.prefillName('Jake Grant', { full_name: 'Other' }), 'Jake Grant');
  assert.equal(onboarding.prefillName(null, { full_name: ' Jake ' }), 'Jake');
  assert.equal(onboarding.prefillName(null, { name: 'Jake' }), 'Jake');
  assert.equal(onboarding.prefillName(null, { full_name: 42 }), '');
  assert.equal(onboarding.prefillName(undefined, undefined), '');
});

test('callback markers map to the calendar block state', () => {
  const state = (overrides) => onboarding.calendarState({ connected: false, connecting: false, result: null, startFailed: false, ...overrides });
  assert.equal(state({}), 'not-connected');
  assert.equal(state({ result: 'cancelled' }), 'not-connected');
  assert.equal(state({ result: 'failed' }), 'failed');
  assert.equal(state({ startFailed: true }), 'failed');
  assert.equal(state({ result: 'declined' }), 'declined');
  assert.equal(state({ connecting: true, result: 'failed' }), 'connecting');
  // A verified connection wins over any marker; a "connected" marker alone is not trusted.
  assert.equal(state({ connected: true, result: 'failed' }), 'connected');
  assert.equal(state({ result: 'connected' }), 'not-connected');
  assert.equal(onboarding.parseCalendarResult('declined'), 'declined');
  assert.equal(onboarding.parseCalendarResult('granted'), null);
  assert.equal(onboarding.CALENDAR_MESSAGES.failed, "Couldn't connect. Try again.");
  assert.equal(onboarding.CALENDAR_MESSAGES.declined, "Calendar access wasn't granted. Connect again and allow it to check conflicts.");
});

test('retry waits between attempts and gives up after the last delay or when told to stop', async () => {
  const waits = [];
  const wait = async ms => { waits.push(ms); };
  let calls = 0;
  assert.equal(await onboarding.retry(async () => { if (++calls < 3) throw new Error('down'); return 'saved'; }, { delays: [10, 20], wait }), 'saved');
  assert.deepEqual(waits, [10, 20]);

  calls = 0;
  await assert.rejects(onboarding.retry(async () => { calls++; throw new Error('down'); }, { delays: [10, 20], wait }), /down/);
  assert.equal(calls, 3);

  calls = 0;
  await assert.rejects(onboarding.retry(async () => { calls++; throw new Error('down'); }, { delays: [10, 20], wait, shouldStop: () => calls >= 1 }), /down/);
  assert.equal(calls, 1);
});

test('next survives the Google round trip once, and a bad stored value falls back home', () => {
  const storage = memoryStorage();
  onboarding.rememberNext(storage, '/polls/abc');
  assert.equal(onboarding.recallNext(storage), '/polls/abc');
  assert.equal(onboarding.recallNext(storage), onboarding.HOME);

  onboarding.rememberNext(storage, '/polls/abc');
  onboarding.rememberNext(storage, onboarding.HOME);
  assert.equal(storage.values.size, 0);

  storage.setItem('meetful:onboarding-next', 'https://evil.example/');
  assert.equal(onboarding.recallNext(storage), onboarding.HOME);

  const broken = { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); }, removeItem() { throw new Error('blocked'); } };
  onboarding.rememberNext(broken, '/polls/abc');
  assert.equal(onboarding.recallNext(broken), onboarding.HOME);
  assert.equal(onboarding.recallNext(undefined), onboarding.HOME);
});

test('the entry decision forwards finished or unreadable accounts and shows the flow otherwise', async () => {
  const url = path => new URL(path, 'https://meetful.invalid');
  const profile = overrides => async () => ({ onboarding_completed_at: null, display_name: 'Jake', avatar_url: null, ...overrides });
  const entry = (path, loadProfile, storage = memoryStorage()) =>
    onboarding.resolveWelcomeEntry({ url: url(path), storage, loadProfile, metadata: { full_name: 'From Google' } });

  // A finished account passes straight through, to next when one is given.
  assert.deepEqual(await entry('/welcome', profile({ onboarding_completed_at: '2026-11-27T00:00:00Z' })), { kind: 'leave', to: '/polls' });
  assert.deepEqual(await entry('/welcome?next=/polls/abc', profile({ onboarding_completed_at: '2026-11-27T00:00:00Z' })), { kind: 'leave', to: '/polls/abc' });
  // An unreadable profile never holds anyone in onboarding.
  assert.deepEqual(await entry('/welcome?next=/polls/abc', async () => { throw new Error('down'); }), { kind: 'leave', to: '/polls/abc' });
  // A hostile next is not followed either way.
  assert.deepEqual(await entry('/welcome?next=//evil.example', async () => { throw new Error('down'); }), { kind: 'leave', to: '/polls' });

  assert.deepEqual(await entry('/welcome?next=/polls/abc', profile({ avatar_url: 'https://cdn.example/a.png' })), {
    kind: 'show', next: '/polls/abc', result: null, name: 'Jake', savedName: 'Jake', avatarUrl: 'https://cdn.example/a.png'
  });
  const unnamed = await entry('/welcome', profile({ display_name: null }));
  assert.equal(unnamed.name, 'From Google');
  assert.equal(unnamed.savedName, null);

  // Back from consent, the marker is read and next comes from this tab's storage, once.
  const storage = memoryStorage();
  onboarding.rememberNext(storage, '/polls/abc');
  const returned = await entry('/welcome?step=calendar&calendar=declined&next=/ignored', profile({}), storage);
  assert.equal(returned.result, 'declined');
  assert.equal(returned.next, '/polls/abc');
  assert.equal(storage.values.size, 0);
  assert.equal((await entry('/welcome?calendar=bogus', profile({}))).result, null);
});
