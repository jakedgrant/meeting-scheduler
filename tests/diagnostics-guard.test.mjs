import assert from 'node:assert/strict';
import test from 'node:test';
import { sources } from './helpers/source-files.mjs';

// F27: raw errors can carry URLs, tokens and provider responses, so every client and
// function keeps them out of logs. See docs/integration-diagnostics.md.

const violations = (files, pattern) => files.flatMap(({ path, text }) =>
  text.split('\n').flatMap((line, index) => pattern.test(line) ? [`${path}:${index + 1}: ${line.trim()}`] : []));

test('iOS sources log failures only through FailureLog', async () => {
  const files = [...await sources('apps/mobile/Sources/', ['.swift']),
    ...await sources('apps/mobile/MeetingScheduler/', ['.swift'])];
  assert.ok(files.length > 0);
  assert.deepEqual(violations(files, /(?<![\w.])(print|debugPrint|dump|NSLog)\(/), []);
});

test('Android sources never log an exception or its message directly', async () => {
  const files = (await sources('apps/android/app/src/main/', ['.kt']))
    .filter(({ path }) => !path.endsWith('/FailureLog.kt'));
  assert.ok(files.length > 0);
  assert.deepEqual(violations(files, /(?<![\w.])println\(/), []);
  assert.deepEqual(violations(files, /\bLog\.[a-z]\(.*(\.message\b|\.localizedMessage\b|,\s*\w+\s*\)\s*$)/), []);
});

test('web sources log only fixed messages', async () => {
  const files = await sources('apps/web/src/', ['.ts', '.svelte']);
  assert.ok(files.length > 0);
  assert.deepEqual(violations(files, /\bconsole\.\w+\((?!'[^']*'\);?\s*$)/), []);
});

test('Edge Functions log only through the diagnostics allowlist', async () => {
  const files = (await sources('supabase/functions/', ['.ts']))
    .filter(({ path }) => !path.endsWith('_test.ts') && !path.endsWith('/_shared/diagnostics.ts'));
  assert.ok(files.length > 0);
  assert.deepEqual(violations(files, /\bconsole\.\w+\(/), []);
  assert.deepEqual(violations(files, /\bheaders\.(forEach|entries)\(/), []);
});
