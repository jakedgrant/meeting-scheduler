import { runTestSuites } from './node-test-suites.mjs';

// The focused in-process database suites. The web suites run in the web workflow, and the
// real two-connection suites run separately, each with its own empty database.
await runTestSuites(name => !name.startsWith('web-') && !name.startsWith('concurrent-'));
