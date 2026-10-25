import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// F21: the web date helpers, creation encoding and calendar exports must match
// the shared fixtures in every host zone. No browser, server or port is used.
const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const lib = join(root, 'apps/web/src/lib');
const fixtures = JSON.parse(await readFile(join(root, 'packages/shared-config/date-time-fixtures.json'), 'utf8'));
const hostZones = ['America/Chicago', 'Pacific/Auckland', 'Asia/Kolkata', 'America/Santiago', 'UTC'];

const directory = await mkdtemp(join(tmpdir(), 'web-date-time-'));
const output = join(directory, 'bundle.mjs');
await build({
  stdin: { contents: `export * from '${lib}/date-time.ts'; export * from '${lib}/calendar-utils.ts'; export { creationPayload } from '${lib}/poll-creation.ts';`, resolveDir: join(root, 'apps/web') },
  outfile: output, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {},
  plugins: [{ name: 'offline', setup(b) {
    b.onResolve({ filter: /^\.\/supabase$/ }, () => ({ path: 'supabase', namespace: 'fixture' }));
    b.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: 'export const supabase = null;', loader: 'js' }));
  } }]
});
const web = await import(pathToFileURL(output));
test.after(() => rm(directory, { recursive: true, force: true }));

function inHostZones(body) {
  const original = process.env.TZ;
  try {
    for (const zone of hostZones) { process.env.TZ = zone; body(zone); }
  } finally {
    if (original === undefined) delete process.env.TZ; else process.env.TZ = original;
  }
}

const draft = (extra = {}) => ({
  title: 'Dates', description: '', location: '', dueDate: '', isAllDay: false, useEventPass: false, timezone: 'UTC',
  timeOptions: [{ id: 'a', date: '2026-11-02', startTime: '09:00', endTime: '10:00' }], ...extra
});

test('date ranges contain each calendar date once in every host zone', () => {
  inHostZones(host => {
    for (const range of fixtures.date_ranges) {
      assert.deepEqual(web.dateRange(range.start, range.end), range.dates, `${range.name} in ${host}`);
    }
  });
});

test('the historical Chicago loop defect is reproduced and the helper does not have it', () => {
  inHostZones(host => {
    if (host !== 'America/Chicago') return;
    // The pre-F21 loop: UTC parse, local increment, UTC format.
    const legacy = (start, end) => {
      const out = []; const current = new Date(start); const last = new Date(end);
      while (current <= last) { out.push(current.toISOString().split('T')[0]); current.setDate(current.getDate() + 1); }
      return out;
    };
    assert.deepEqual(legacy('2026-11-01', '2026-11-03'), ['2026-11-01', '2026-11-02']);
    assert.deepEqual(legacy('2026-03-07', '2026-03-10'), ['2026-03-07', '2026-03-08', '2026-03-08', '2026-03-09']);
    assert.deepEqual(web.dateRange('2026-11-01', '2026-11-03'), ['2026-11-01', '2026-11-02', '2026-11-03']);
    assert.deepEqual(web.dateRange('2026-03-07', '2026-03-10'), ['2026-03-07', '2026-03-08', '2026-03-09', '2026-03-10']);
  });
});

test('timed wall times resolve in the poll zone, reject gaps and take the first repeated time', () => {
  inHostZones(host => {
    for (const c of fixtures.timed_options) {
      if (c.error) {
        assert.throws(() => web.timedInterval(c.date, c.start, c.end, c.zone), error => error.code === c.error, `${c.name} in ${host}`);
      } else {
        assert.deepEqual(web.timedInterval(c.date, c.start, c.end, c.zone), { start_time: c.start_time, end_time: c.end_time }, `${c.name} in ${host}`);
      }
    }
  });
});

test('all-day options use an exclusive next-day start, including 23/25-hour days and missing midnights', () => {
  inHostZones(host => {
    for (const c of fixtures.all_day_options) {
      assert.deepEqual(web.allDayInterval(c.date, c.zone), { start_time: c.start_time, end_time: c.end_time }, `${c.name} in ${host}`);
    }
  });
});

test('a due date accepts responses through the end of that date', () => {
  inHostZones(host => {
    for (const c of fixtures.deadlines) assert.equal(web.deadlineFor(c.date, c.zone), c.closes_at, `${c.name} in ${host}`);
  });
});

test('an all-day option shows its poll-zone date to viewers in every zone', () => {
  inHostZones(host => {
    for (const c of fixtures.option_dates) {
      const date = web.allDayDate(c, c.zone);
      assert.equal(date, c.date, `${c.name} in ${host}`);
      const [y, m, d] = c.date.split('-').map(Number);
      assert.equal(web.formatCalendarDate(date, { month: 'numeric', day: 'numeric', year: 'numeric' }), `${m}/${d}/${y}`, `${c.name} label in ${host}`);
    }
  });
});

test('ICS and Google exports emit DATE values for all-day options and UTC instants otherwise', () => {
  inHostZones(host => {
    for (const c of fixtures.exports) {
      const event = { title: 'T', startTime: c.start_time, endTime: c.end_time, isAllDay: c.is_all_day, timezone: c.zone };
      const lines = web.generateICS(event).split('\r\n');
      assert.ok(lines.includes(c.ics_start), `${c.name} DTSTART in ${host}: ${lines}`);
      assert.ok(lines.includes(c.ics_end), `${c.name} DTEND in ${host}`);
      assert.equal(new URL(web.generateGoogleCalendarUrl(event)).searchParams.get('dates'), c.google_dates, `${c.name} Google in ${host}`);
    }
  });
});

test('creation payloads encode fixtures in the recorded zone with canonical instants', () => {
  inHostZones(host => {
    for (const c of fixtures.timed_options) {
      const value = draft({ timeOptions: [{ id: 'a', date: c.date, startTime: c.start, endTime: c.end }] });
      if (c.error) {
        assert.throws(() => web.creationPayload(value, c.zone), c.error === 'nonexistent_local_time' ? /clock change/ : /after start/, `${c.name} in ${host}`);
        continue;
      }
      const payload = web.creationPayload(value, c.zone);
      assert.equal(payload.timezone, c.zone);
      assert.deepEqual(payload.time_options, [{ start_time: c.start_time, end_time: c.end_time, is_all_day: false }], `${c.name} in ${host}`);
    }
    for (const c of fixtures.all_day_options) {
      const payload = web.creationPayload(draft({ isAllDay: true, timeOptions: [{ id: 'a', date: c.date, startTime: '09:00', endTime: '10:00' }] }), c.zone);
      assert.deepEqual(payload.time_options, [{ start_time: c.start_time, end_time: c.end_time, is_all_day: true }], `${c.name} in ${host}`);
    }
    for (const c of fixtures.deadlines) {
      assert.equal(web.creationPayload(draft({ dueDate: c.date }), c.zone).closes_at, c.closes_at, `${c.name} in ${host}`);
    }
  });
});

test('calendar dates reject impossible values and today follows the given zone', () => {
  for (const bad of ['2026-02-29', '2026-13-01', '2026-1-01', '']) assert.equal(web.isCalendarDate(bad), false, bad);
  assert.throws(() => web.creationPayload(draft({ dueDate: '2026-02-30' }), 'UTC'), /due date/);
  const instant = new Date('2026-11-01T03:00:00Z');
  assert.equal(web.today('America/Chicago', instant), '2026-10-31');
  assert.equal(web.today('Pacific/Auckland', instant), '2026-11-01');
  assert.equal(web.addDays('2028-02-28', 1), '2028-02-29');
});
