import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

// Discover the focused in-process database suites present on this PR's stack.
// The real two-connection suite runs separately with its own empty database.
const files = (await readdir(new URL('../tests/', import.meta.url)))
  .filter(name => name.endsWith('.test.mjs') && !name.startsWith('web-') && !name.startsWith('concurrent-'))
  .sort()
  .map(name => `tests/${name}`);
if (!files.length) throw new Error('No database regression suites were found.');
const result = spawnSync(process.execPath, ['--test', '--test-concurrency=1', ...files], { stdio: 'inherit' });
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
