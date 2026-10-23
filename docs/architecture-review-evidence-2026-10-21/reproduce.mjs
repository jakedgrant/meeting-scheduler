// Offline reproductions for the architecture review. These assert the observed
// defects, not the desired behavior. No real credentials, services, or data are used.
// Requires Node.js with node:module.stripTypeScriptTypes and installed web deps.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire, stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = (path) => readFileSync(join(root, path), 'utf8');
const quiet = { log() {}, warn() {}, error() {} };
const reviewUser = '00000000-0000-4000-8000-000000000001';
let passed = 0;
const record = (message) => { passed++; console.log('REPRODUCED: ' + message); };

function loadEdge(path, { createClient, fetch, env = {} }) {
  let handler;
  const source = stripTypeScriptTypes(read(path).replace(/^import .*\n/gm, ''));
  vm.runInNewContext(source, {
    console: quiet, Request, Response, URLSearchParams, TextEncoder,
    atob, Date, fetch, createClient,
    serve: (callback) => { handler = callback; },
    Deno: {
      env: { get: (key) => ({ SUPABASE_URL: 'https://review.invalid',
        SUPABASE_SERVICE_ROLE_KEY: 'review-only-synthetic-key', ...env })[key] },
      serve: (callback) => { handler = callback; }
    }
  });
  assert.equal(typeof handler, 'function');
  return handler;
}

let selectedUser;
let googleRequests = 0;
let googleFails = false;
const calendarClient = {
  from() {
    return {
      select() { return this; },
      update() { return this; },
      eq(_column, userId) { selectedUser = userId; return this; },
      async single() {
        return { data: {
          google_calendar_refresh_token: 'synthetic-provider-refresh',
          google_calendar_access_token: 'synthetic-provider-access',
          google_calendar_token_expires_at: new Date(Date.now() + 3600000).toISOString()
        }, error: null };
      }
    };
  }
};
const calendar = loadEdge('supabase/functions/check-calendar-conflicts/index.ts', {
  createClient: () => calendarClient,
  fetch: async () => {
    googleRequests++;
    return googleFails
      ? new Response('unavailable', { status: 503 })
      : Response.json({ items: [] });
  }
});
const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const forgedToken = encode({ alg: 'HS256', typ: 'JWT' }) + '.' +
  encode({ sub: reviewUser, exp: Math.floor(Date.now() / 1000) + 3600,
    iss: 'https://review.invalid/auth/v1', role: 'authenticated' }) + '.not-a-signature';
const options = [{ id: 'review-slot', start_time: '2026-11-02T15:00:00Z',
  end_time: '2026-11-02T16:00:00Z' }];
const calendarRequest = (headers, timeOptions = options) => new Request('https://review.invalid/function', {
  method: 'POST', headers: { 'Content-Type': 'application/json', ...headers },
  body: JSON.stringify({ timeOptions })
});

let response = await calendar(calendarRequest({ Authorization: 'Bearer ' + forgedToken }));
assert.equal(response.status, 200);
assert.equal(selectedUser, reviewUser);
record('Calendar handler accepts a forged JWT when called without the gateway. This does not test deployed gateway protection.');

response = await calendar(calendarRequest({ 'x-user-id': reviewUser }));
assert.equal(response.status, 200);
assert.equal(selectedUser, reviewUser);
record('Calendar handler accepts a caller-supplied x-user-id without a bearer token when called without the gateway.');

googleFails = true;
response = await calendar(calendarRequest({ Authorization: 'Bearer ' + forgedToken }));
let body = await response.json();
assert.equal(body.success, true);
assert.deepEqual(body.conflictingIds, []);
record('A Google Calendar HTTP 503 becomes success=true with zero conflicting slots.');

googleFails = false;
googleRequests = 0;
await calendar(calendarRequest({ Authorization: 'Bearer ' + forgedToken },
  Array.from({ length: 12 }, (_, index) => ({ ...options[0], id: String(index) }))));
assert.equal(googleRequests, 12);
record('Twelve submitted slots cause twelve separate Google Calendar requests.');

let storedSubscription;
let failPassInsert = false;
const webhook = loadEdge('supabase/functions/revenuecat-webhook/index.ts', {
  env: { REVENUECAT_WEBHOOK_AUTH: 'review-only-webhook-secret' },
  createClient: () => ({
    from() {
      return {
        async upsert(value) { storedSubscription = value; return { error: null }; },
        async insert() { return { error: failPassInsert ? { code: '08006', message: 'database unavailable' } : null }; }
      };
    }
  })
});
const deliver = (event) => webhook(new Request('https://review.invalid/webhook', {
  method: 'POST', headers: { Authorization: 'review-only-webhook-secret', 'Content-Type': 'application/json' },
  body: JSON.stringify({ event: { app_user_id: reviewUser, entitlement_ids: ['pro_access'],
    expiration_at_ms: Date.now() + 86400000, ...event } })
}));
await deliver({ type: 'RENEWAL', id: 'new-event', event_timestamp_ms: 2000 });
assert.equal(storedSubscription.is_active, true);
await deliver({ type: 'EXPIRATION', id: 'old-event', event_timestamp_ms: 1000 });
assert.equal(storedSubscription.is_active, false);
record('A stale expiration delivered after a renewal overwrites the newer active subscription.');

await deliver({ type: 'UNRECOGNIZED_FUTURE_EVENT', id: 'unknown-event' });
assert.equal(storedSubscription.is_active, true);
record('An unrecognized webhook event writes an active subscription.');

failPassInsert = true;
response = await deliver({ type: 'NON_RENEWING_PURCHASE', id: 'pass-event', store: 'APP_STORE' });
assert.equal(response.status, 200);
record('A non-duplicate event-pass database failure is acknowledged with HTTP 200.');

const requireFromWeb = createRequire(join(root, 'apps/web/package.json'));
const { writable } = await import(pathToFileURL(requireFromWeb.resolve('svelte/store')).href);
const user = writable({ id: 'review-user-a' });
await new Promise((resolve) => {
  const unsubscribe = user.subscribe((value) => { resolve(value); unsubscribe(); });
});
assert.throws(() => user.set({ id: 'review-user-b' }), /Cannot access 'unsubscribe' before initialization/);
record('The web one-shot subscription pattern leaves a listener that throws on the next user-store update.');

process.env.TZ = 'America/Chicago';
function dateRange(start, end) {
  const currentDate = new Date(start);
  const endDate = new Date(end);
  const dates = [];
  while (currentDate <= endDate) {
    dates.push(currentDate.toISOString().split('T')[0]);
    currentDate.setDate(currentDate.getDate() + 1);
  }
  return dates;
}
assert.deepEqual(dateRange('2026-11-01', '2026-11-03'), ['2026-11-01', '2026-11-02']);
assert.deepEqual(dateRange('2026-03-07', '2026-03-10'), ['2026-03-07', '2026-03-08', '2026-03-08', '2026-03-09']);
record('The web date-range loop drops November 3 and duplicates March 8 across Chicago daylight-saving changes.');

console.log('\n' + passed + ' offline reproductions completed. These are audit demonstrations, not a passing application test suite.');
