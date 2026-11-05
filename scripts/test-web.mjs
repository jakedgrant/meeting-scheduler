import { runTestSuites } from './node-test-suites.mjs';

// Every web suite, so a new `tests/web-*.test.mjs` file runs in CI without a workflow edit.
await runTestSuites(name => name.startsWith('web-'));
