import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));

const directory = await mkdtemp(join(tmpdir(), 'web-alpha-gate-'));
const output = join(directory, 'bundle.mjs');
await build({
  entryPoints: [join(root, 'apps/web/src/lib/server/alpha-gate.ts')],
  outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {}
});
const { alphaGate, ALPHA_COOKIE, ALPHA_UNLOCK_PATH } = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));

const site = 'https://meetful.app';
const password = 'correct horse';
const get = (path, cookie) => new Request(site + path, { headers: cookie ? { cookie } : {} });
const unlock = fields => new Request(site + ALPHA_UNLOCK_PATH, { method: 'POST', body: new URLSearchParams(fields) });

async function cookieFor(secret) {
  const response = await alphaGate(unlock({ password: secret, next: '/' }), secret);
  return response.headers.get('set-cookie').split(';')[0];
}

test('with no password configured, every request reaches the app', async () => {
  assert.equal(await alphaGate(get('/polls'), undefined), null);
  assert.equal(await alphaGate(get('/polls'), ''), null);
});

test('a visitor without the cookie gets the password form, not the page', async () => {
  const response = await alphaGate(get('/join/BFZZ7J?ref=share'), password);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('x-robots-tag'), 'noindex');
  const html = await response.text();
  assert.match(html, /<form method="post" action="\/alpha-unlock">/);
  assert.match(html, /name="next" value="\/join\/BFZZ7J\?ref=share"/);
});

test('robots.txt and the favicon stay reachable', async () => {
  assert.equal(await alphaGate(get('/robots.txt'), password), null);
  assert.equal(await alphaGate(get('/favicon.png'), password), null);
});

test('the right password sets a long-lived, HttpOnly cookie and returns to the requested page', async () => {
  const response = await alphaGate(unlock({ password, next: '/auth/callback?attempt=a&code=b' }), password);
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('location'), '/auth/callback?attempt=a&code=b');
  const cookie = response.headers.get('set-cookie');
  assert.match(cookie, new RegExp(`^${ALPHA_COOKIE}=[0-9a-f]{64}; `));
  for (const attribute of ['Path=/', 'Max-Age=7776000', 'HttpOnly', 'SameSite=Lax', 'Secure']) assert.ok(cookie.includes(attribute), attribute);
  assert.ok(!cookie.includes(password), 'the cookie must not contain the password');
});

test('the cookie from unlocking lets later requests through', async () => {
  assert.equal(await alphaGate(get('/polls', await cookieFor(password)), password), null);
  assert.equal(await alphaGate(get('/polls', `theme=dark; ${await cookieFor(password)}`), password), null);
});

test('a wrong password shows the form again with an error and sets no cookie', async () => {
  const response = await alphaGate(unlock({ password: 'nope', next: '/polls' }), password);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('set-cookie'), null);
  const html = await response.text();
  assert.match(html, /role="alert"/);
  assert.match(html, /name="next" value="\/polls"/);
});

test('changing the password invalidates cookies issued for the old one', async () => {
  const old = await cookieFor(password);
  assert.equal((await alphaGate(get('/polls', old), 'new password')).status, 401);
  assert.equal((await alphaGate(get('/polls', `${ALPHA_COOKIE}=forged`), password)).status, 401);
});

test('unlocking only redirects within the site', async () => {
  for (const next of ['https://evil.example', '//evil.example', '/\\evil.example', 'polls', '']) {
    const response = await alphaGate(unlock({ password, next }), password);
    assert.equal(response.headers.get('location'), '/', next);
  }
});

test('the form escapes the return path', async () => {
  const html = await (await alphaGate(get('/polls?q="><script>alert(1)</script>'), password)).text();
  assert.ok(!html.includes('<script>alert(1)</script>'));
});

test('a GET to the unlock path goes home instead of showing an empty page', async () => {
  const response = await alphaGate(get(ALPHA_UNLOCK_PATH), password);
  assert.equal(response.status, 303);
  assert.equal(response.headers.get('location'), '/');
});
