import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// The time option row's date, time range and tally text, bundled from the web source.
const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const directory = await mkdtemp(join(tmpdir(), 'web-time-option-labels-'));
const output = join(directory, 'bundle.mjs');
await build({
  stdin: { contents: `export * from '${join(root, 'apps/web/src/lib/time-option-labels.ts')}';`, resolveDir: join(root, 'apps/web') },
  outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {}
});
const labels = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));

const zone = 'America/Chicago';
const now = new Date('2026-11-27T15:00:00Z');

test('the date drops the year in the current year only', () => {
  assert.equal(labels.optionDateLabel({ start_time: '2026-12-02T00:00:00Z', is_all_day: false }, 'UTC', now, zone), 'Tue, Dec 1');
  assert.equal(labels.optionDateLabel({ start_time: '2027-01-06T00:00:00Z', is_all_day: false }, 'UTC', now, zone), 'Tue, Jan 5, 2027');
  // All-day options are dates in the poll's zone, whatever the viewer's zone.
  assert.equal(labels.optionDateLabel({ start_time: '2026-12-01T06:00:00Z', is_all_day: true }, zone, now, 'Pacific/Auckland'), 'Tue, Dec 1');
});

test('time ranges drop :00 per end and share AM/PM', () => {
  assert.equal(labels.timeRangeLabel('2026-12-02T00:00:00Z', '2026-12-02T02:00:00Z', zone), '6–8 PM');
  assert.equal(labels.timeRangeLabel('2026-12-01T17:00:00Z', '2026-12-01T19:00:00Z', zone), '11 AM–1 PM');
  assert.equal(labels.timeRangeLabel('2026-12-01T23:30:00Z', '2026-12-02T01:00:00Z', zone), '5:30–7 PM');
});

test('a range across midnight names the end date; one ending at midnight does not', () => {
  assert.equal(labels.timeRangeLabel('2026-12-02T05:00:00Z', '2026-12-02T07:00:00Z', zone), '11 PM – 1 AM (Dec 2)');
  assert.equal(labels.timeRangeLabel('2026-12-02T04:00:00Z', '2026-12-02T06:00:00Z', zone), '10 PM – 12 AM');
});

test('tally segments keep yes, maybe, no order and skip empty counts', () => {
  assert.deepEqual(labels.tallySegments({ available: 3, maybe: 0, unavailable: 1 }),
    [{ status: 'available', count: 3 }, { status: 'unavailable', count: 1 }]);
  assert.deepEqual(labels.tallySegments({ available: 0, maybe: 0, unavailable: 0 }), []);
});
