import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { pollRow, timeOptionRow } from './helpers/web-rows.mjs';

const requireWeb = createRequire(new URL('../apps/web/package.json', import.meta.url));
const { build } = requireWeb('esbuild');
const lib = join(resolve(fileURLToPath(new URL('..', import.meta.url))), 'apps/web/src/lib');
const owner = '11111111-1111-4111-8111-111111111111';
const option = { id: 'o1', date: '2030-03-01', startTime: '14:00', endTime: '15:00' };
const created = { poll: pollRow({ id: '33333333-3333-4333-8333-333333333333', creator_id: owner, share_code: 'K7QX4M' }), time_options: [timeOptionRow()], redeemed_pass_id: null, entitlement: 'free', replayed: false };
const disk = () => {
  const values = new Map();
  return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
};

// The step rules are a plain module: no component, store or browser is involved.
async function load(t) {
  const directory = await mkdtemp(join(tmpdir(), 'web-poll-flow-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const outfile = join(directory, 'bundle.mjs');
  await build({
    stdin: { contents: `export * from '${lib}/poll-flow.ts'; export * from '${lib}/poll-creation.ts'; export {get} from 'svelte/store';`, resolveDir: join(lib, '..') },
    outfile, bundle: true, platform: 'node', format: 'esm', tsconfigRaw: {}, logLevel: 'silent'
  });
  return import(pathToFileURL(outfile));
}

test('steps advance in order and each waits for its requirements', async t => {
  const flow = await load(t);
  assert.deepEqual(flow.flowSteps, ['details', 'timeOptions', 'deadline', 'eventPass', 'share']);
  let draft = { title: '', isAllDay: false, timeOptions: [] };
  let step = 'details';
  step = flow.advance(step, draft);
  assert.equal(step, 'details', 'a title is required');
  draft = { ...draft, title: '   ' };
  assert.equal(flow.advance(step, draft), 'details', 'a blank title is not a title');

  draft = { ...draft, title: 'Planning' };
  step = flow.advance(step, draft);
  assert.equal(step, 'timeOptions');
  assert.equal(flow.advance(step, draft), 'timeOptions', 'an option is required');

  draft = { ...draft, timeOptions: [option] };
  step = flow.advance(step, draft);
  assert.equal(step, 'deadline');
  step = flow.advance(step, draft);
  assert.equal(step, 'eventPass');
  assert.equal(flow.advance(step, draft), 'eventPass', 'creating the poll, not advancing, leaves the last step');

  step = flow.goBack(step);
  assert.equal(step, 'deadline');
  step = flow.goTo(step, 'details');
  assert.equal(step, 'details');
  assert.equal(flow.goTo(step, 'eventPass'), 'details', 'goTo only moves backward');
  assert.equal(flow.goBack('details'), 'details', 'step 1 has no back');
});

test('the step label counts to five', async t => {
  const flow = await load(t);
  assert.deepEqual(flow.flowSteps.slice(0, 4).map(flow.stepLabel), ['Step 1 of 5', 'Step 2 of 5', 'Step 3 of 5', 'Step 4 of 5']);
});

test('all-day needs a day selected', async t => {
  const flow = await load(t);
  const draft = { title: 'Planning', isAllDay: true, timeOptions: [] };
  assert.equal(flow.canAdvance('timeOptions', draft), false);
  assert.equal(flow.canAdvance('timeOptions', { ...draft, timeOptions: [{ ...option }] }), true);
});

test('the deadline step always allows moving on', async t => {
  const flow = await load(t);
  assert.equal(flow.canAdvance('deadline', { title: '', isAllDay: false, timeOptions: [] }), true);
});

test('creating the poll moves to the share step and going back is blocked', async t => {
  const flow = await load(t);
  const editor = flow.createPollCreation({ create: async () => created }, disk());
  editor.setOwner(owner);
  editor.edit({ title: 'Planning', timeOptions: [option] });
  let step = flow.initialStep(false);
  step = flow.advance(flow.advance(flow.advance(step, flow.get(editor).draft), flow.get(editor).draft), flow.get(editor).draft);
  assert.equal(step, 'eventPass');
  assert.equal(flow.get(editor).result, null);

  const result = await editor.submit();
  assert.equal(result.poll.share_code, 'K7QX4M');
  step = flow.created();
  assert.equal(step, 'share');
  assert.equal(flow.goBack(step), 'share', 'a created poll can not be edited by going back');
  assert.equal(flow.goTo(step, 'details'), 'share');
  assert.equal(flow.canAdvance(step, flow.get(editor).draft), false);
});

test('a retained unresolved submission reopens on step 4', async t => {
  const flow = await load(t);
  const storage = disk();
  const failing = flow.createPollCreation({ create: async () => { throw new Error('offline'); } }, storage);
  failing.setOwner(owner);
  failing.edit({ title: 'Planning', timeOptions: [option] });
  assert.equal(await failing.submit(), null);

  const reopened = flow.createPollCreation({ create: async () => created }, storage);
  reopened.setOwner(owner);
  const state = flow.get(reopened);
  assert.equal(state.uncertain, true);
  assert.equal(state.draft.title, 'Planning');
  assert.equal(flow.initialStep(state.uncertain || state.recoveryRequired), 'eventPass');
  assert.equal(flow.initialStep(false), 'details');
});

test('the review rows jump back to the step that owns each value', async t => {
  const flow = await load(t);
  const rows = flow.reviewRows({ ...flow.emptyCreationDraft(), title: ' Planning ', location: '', dueDate: '2030-03-04', timeOptions: [option, { ...option, id: 'o2' }] });
  assert.deepEqual(rows.map(row => [row.step, row.label]), [['details', 'Title'], ['timeOptions', 'Time options'], ['deadline', 'Deadline'], ['details', 'Location']]);
  assert.equal(rows[0].value, 'Planning');
  assert.equal(rows[1].value, '2 options');
  assert.match(rows[2].value, /Mar 4, 2030/);
  assert.equal(rows[3].value, 'None');
  assert.equal(flow.reviewRows({ ...flow.emptyCreationDraft(), timeOptions: [option] })[1].value, '1 option');
});

test('the deadline note names the end of the day, the zone and the first option', async t => {
  const flow = await load(t);
  const note = flow.deadlineNote('2030-03-04', '2030-03-06', 'America/Chicago');
  assert.match(note, /Responses close at the end of .*Mar 4, 2030, Central (Standard|Daylight) Time\./);
  assert.match(note, /Your first option is .*Mar 6, 2030\./);
  assert.doesNotMatch(flow.deadlineNote('2030-03-04', null, 'UTC'), /first option/);
  assert.equal(flow.firstOptionDate({ timeOptions: [{ ...option, date: '2030-03-09' }, option, { ...option, date: '' }] }), '2030-03-01');
  assert.equal(flow.firstOptionDate({ timeOptions: [] }), null);
  assert.deepEqual(flow.quickPicks.map(pick => [pick.label, flow.quickPickDate('2030-03-01', pick.days)]), [['Tomorrow', '2030-03-02'], ['In 2 days', '2030-03-03'], ['In 1 week', '2030-03-08']]);
});

test('month cells pad to the weekday and months shift across years', async t => {
  const flow = await load(t);
  const cells = flow.monthCells('2026-11');
  assert.equal(cells.length - cells.filter(Boolean).length, 0, 'Nov 1 2026 is a Sunday');
  assert.equal(cells.length, 30);
  assert.equal(flow.monthCells('2026-12').findIndex(Boolean), 2, 'Dec 1 2026 is a Tuesday');
  assert.equal(flow.shiftMonth('2026-12', 1), '2027-01');
  assert.equal(flow.shiftMonth('2027-01', -1), '2026-12');
  assert.equal(flow.pollLink('https://example.com', 'abc'), 'https://example.com/polls/abc');
});
