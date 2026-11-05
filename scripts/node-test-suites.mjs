import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

/** Runs every `tests/*.test.mjs` file whose name passes `include`, one file at a time. */
export async function runTestSuites(include) {
  const files = (await readdir(new URL('../tests/', import.meta.url)))
    .filter(name => name.endsWith('.test.mjs') && include(name))
    .sort()
    .map(name => `tests/${name}`);
  if (!files.length) throw new Error('No test suites matched.');
  const result = spawnSync(process.execPath, ['--test', '--test-concurrency=1', ...files], { stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
}
