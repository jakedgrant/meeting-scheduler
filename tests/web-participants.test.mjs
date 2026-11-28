import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { participantRow } from './helpers/web-rows.mjs';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const { compile } = requireWeb('svelte/compiler');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));

async function component(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-participants-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  let css = '';
  const output = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export { default as Participants } from './src/lib/components/PollParticipants.svelte'; export { render } from 'svelte/server';`, resolveDir: join(root, 'apps/web') },
    outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
    plugins: [{ name: 'participants', setup(b) {
      b.onLoad({ filter: /\.svelte$/ }, async args => {
        const compiled = compile(await readFile(args.path, 'utf8'), { filename: args.path, generate: 'server' });
        css += compiled.css?.code ?? '';
        return { contents: compiled.js.code, loader: 'js', resolveDir: join(root, 'apps/web') };
      });
    } }]
  });
  const { Participants, render } = await import(pathToFileURL(output));
  return { render: props => render(Participants, { props }).body.replace(/<!--.*?-->/gs, ''), css };
}

test('participants render server submission timestamps, pending labels, counts, and current-user identity', async t => {
  const view = await component(t);
  const submitted_at = '2026-11-24T02:22:00Z';
  const people = [
    participantRow({ id: 'member', anonymous_name: 'Jordan Lee', comment: 'I can join after lunch.', submitted_at }),
    participantRow({ id: 'guest', anonymous_name: 'Guest', submitted_at: null }),
    participantRow({ id: 'pending', anonymous_name: 'Alexandria Montgomery Wellington' })
  ];
  const html = view.render({ participants: people, currentParticipantId: 'member' });
  assert.match(html, /1 of 3 submitted/);
  assert.equal((html.match(/Not submitted/g) ?? []).length, 2);
  assert.match(html, /<time datetime="2026-11-24T02:22:00Z"/);
  assert.ok(html.includes(new Date(submitted_at).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })));
  assert.match(html, /You/);
  assert.match(html, /I can join after lunch/);
  const directory = process.env.PARTICIPANT_WEB_FIXTURE_DIR;
  if (directory) {
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, 'web-participants.html'), `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Web participants fixture</title><style>body{font-family:system-ui,sans-serif;background:#f5f5f5;padding:24px;margin:0}*{box-sizing:border-box}${view.css}</style><body>${html}</body></html>`);
  }
});

test('empty and fully submitted participant lists have accurate counts', async t => {
  const view = await component(t);
  const empty = view.render({ participants: [] });
  assert.match(empty, /0 of 0 submitted/);
  assert.match(empty, /No participants yet/);
  const submitted = view.render({ participants: [participantRow({ submitted_at: '2026-11-24T02:22:00Z' })] });
  assert.match(submitted, /1 of 1 submitted/);
  assert.doesNotMatch(submitted, /Not submitted/);
});
