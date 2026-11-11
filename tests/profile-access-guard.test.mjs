import assert from 'node:assert/strict';
import test from 'node:test';
import { sources } from './helpers/source-files.mjs';

// profiles grants signed-in callers only these columns, so any other Data API
// read of profiles fails at runtime with 42501, including select('*'), an empty
// select, and an update that returns its row. The compiler cannot catch that and
// the client suites mock the transport, so this checks the sources instead.
// See docs/profile-access.md.
const readable = new Set(['id', 'display_name', 'avatar_url']);

const clientSources = async () => [
  ...await sources('apps/web/src/', ['.ts', '.svelte']),
  ...await sources('apps/mobile/Sources/', ['.swift']),
  ...await sources('apps/mobile/MeetingScheduler/', ['.swift']),
  ...await sources('apps/android/app/src/main/', ['.kt']),
];

const indentation = line => line.length - line.trimStart().length;

// The builder chain that starts at `.from("profiles")`: its own line, then the
// lines that continue it (`.call` lines and more-indented block bodies).
function profileChains({ path, text }) {
  const lines = text.split('\n');
  return lines.flatMap((line, index) => {
    if (!/\.from\(\s*['"]profiles['"]\s*\)/.test(line)) return [];
    const chain = [line];
    for (const next of lines.slice(index + 1)) {
      const trimmed = next.trim();
      if (!trimmed || (!trimmed.startsWith('.') && indentation(next) <= indentation(line))) break;
      chain.push(next);
    }
    return [{ location: `${path}:${index + 1}`, swift: path.endsWith('.swift'), text: chain.join('\n') }];
  });
}

// A select is safe only when it names readable columns as a string literal.
const unsafeSelect = text => [...text.matchAll(/\bselect\s*(\(([^)]*)\)|\{)/g)].some(([, , argument]) => {
  const literal = argument?.trim().match(/^(['"])([^'"]*)\1$/);
  return !literal || literal[2].split(',').some(column => !readable.has(column.trim()));
});

// supabase-swift defaults an update to return=representation, which selects every column.
const unsafeSwiftUpdate = chain =>
  chain.swift && /\.update\(/.test(chain.text) && !/returning:\s*\.minimal/.test(chain.text);

const unsafeEmbeds = text => [...text.matchAll(/\bprofiles\(([^)]*)\)/g)]
  .filter(([, columns]) => columns.split(',').some(column => !readable.has(column.trim())))
  .map(([embed]) => embed);

const violations = (files, check) => files.flatMap(profileChains).filter(check).map(chain => chain.location);

test('client Data API reads of profiles select only readable columns', async () => {
  const files = await clientSources();
  assert.ok(files.length > 0);
  assert.ok(files.flatMap(profileChains).length > 0, 'the guard must find the profile update call sites');
  assert.deepEqual(violations(files, chain => unsafeSelect(chain.text)), []);
});

test('Swift profile updates ask for no returned row', async () => {
  assert.deepEqual(violations(await clientSources(), unsafeSwiftUpdate), []);
});

test('client embeds of profiles name only readable columns', async () => {
  const files = await clientSources();
  assert.deepEqual(files.flatMap(({ path, text }) => unsafeEmbeds(text).map(embed => `${path}: ${embed}`)), []);
});

test('the guard rejects the read shapes it exists to catch', () => {
  const swiftUpdate = text => profileChains({ path: 'x.swift', text }).some(unsafeSwiftUpdate);
  assert.equal(swiftUpdate(`try await supabase\n    .from("profiles")\n    .update(updates)\n    .eq("id", value: id)`), true);
  assert.equal(swiftUpdate(`try await supabase\n    .from("profiles")\n    .update(updates, returning: .minimal)`), false);
  assert.deepEqual(unsafeEmbeds(`.select("*, profiles(*)")`), ['profiles(*)']);
  assert.deepEqual(unsafeEmbeds(`.select("*, profiles(display_name, email)")`), ['profiles(display_name, email)']);
  assert.deepEqual(unsafeEmbeds(`.select("*, profiles(display_name)")`), []);
  const check = text => profileChains({ path: 'x.ts', text }).some(chain => unsafeSelect(chain.text));
  assert.equal(check(`await supabase.from('profiles').select('*').eq('id', id)`), true);
  assert.equal(check(`await supabase\n    .from('profiles')\n    .update(u)\n    .select()\n    .single()`), true);
  assert.equal(check(`client.from("profiles").select {\n        filter { eq("id", id) }\n    }`), true);
  assert.equal(check(`client.from("profiles").select("id, email")`), true);
  assert.equal(check(`client.from("profiles").update(u) {\n        select()\n    }`), true);
  assert.equal(check(`await supabase.from('profiles').select('id, display_name')`), false);
  assert.equal(check(`await supabase\n    .from('profiles')\n    .update(u)\n    .eq('id', id)\n  const x = y.select()`), false);
});
