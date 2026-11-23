import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));

const directory = await mkdtemp(join(tmpdir(), 'web-aasa-'));
const output = join(directory, 'bundle.mjs');
await build({
  entryPoints: [join(root, 'apps/web/src/lib/apple-app-site-association.ts')],
  outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {}
});
const { appleAppSiteAssociation, IOS_APP_ID, POLL_PATH_PATTERN, JOIN_PATH_PATTERN } = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));

const ios = join(root, 'apps/mobile/MeetingScheduler');

/** Every distinct value of an Xcode build setting across the project's configurations. */
async function buildSetting(name) {
  const project = await readFile(join(ios, 'MeetingScheduler.xcodeproj/project.pbxproj'), 'utf8');
  return new Set([...project.matchAll(new RegExp(`\\b${name} = ([^;]+);`, 'g'))].map(match => match[1]));
}

// Apple's component pattern: `?` is any one character and `*` any run of characters.
function matches(pattern, path) {
  const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\?/g, '.').replace(/\*/g, '.*');
  return new RegExp(`^${escaped}$`).test(path);
}

test('the app ID is the iOS app\'s team and bundle ID', async () => {
  const teams = await buildSetting('DEVELOPMENT_TEAM');
  const bundles = await buildSetting('PRODUCT_BUNDLE_IDENTIFIER');
  assert.equal(teams.size, 1);
  assert.equal(bundles.size, 1);
  assert.equal(IOS_APP_ID, `${[...teams][0]}.${[...bundles][0]}`);
  assert.deepEqual(appleAppSiteAssociation.applinks.details.map(detail => detail.appIDs), [[IOS_APP_ID]]);
});

test('the iOS app claims the domain the file is served from', async () => {
  const entitlements = await readFile(join(ios, 'MeetingScheduler/MeetingScheduler.entitlements'), 'utf8');
  assert.match(entitlements, /<key>com\.apple\.developer\.associated-domains<\/key>\s*<array>\s*<string>applinks:meetful\.app<\/string>/);
});

test('code invitations and legacy poll pages open the app', () => {
  const [{ components }] = appleAppSiteAssociation.applinks.details;
  assert.deepEqual(components.map(component => component['/']), [JOIN_PATH_PATTERN, POLL_PATH_PATTERN]);
  assert.ok(matches(POLL_PATH_PATTERN, `/polls/${crypto.randomUUID()}`));
  assert.ok(matches(JOIN_PATH_PATTERN, '/join/ABC123'));
  assert.ok(matches(JOIN_PATH_PATTERN, '/join/abc123'));
  for (const path of ['/polls', '/polls/', '/polls/new', `/polls/${crypto.randomUUID()}/times/${crypto.randomUUID()}`,
    '/join/ABC12', '/join/ABC1234', '/join/ABC123/extra', '/auth/callback', `/polls/${crypto.randomUUID()}x`]) {
    assert.ok(!components.some(component => matches(component['/'], path)), path);
  }
});
