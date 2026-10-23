import assert from 'node:assert/strict';
import test from 'node:test';
// Node strips the module's TypeScript annotations natively; the module has no imports.
import {
  GUEST_ACCESS_LOST_MESSAGE,
  clearGuestCapability,
  guestStorageKey,
  isGuestAccessDenied,
  isMissingRpc,
  isPollClosedError,
  isValidCapability,
  readGuestCapability,
  saveGuestCapability,
} from '../apps/web/src/lib/guest-capability.ts';

const pollA = '11111111-1111-4111-8111-111111111111';
const pollB = '22222222-2222-4222-8222-222222222222';
const capability = { participantId: '33333333-3333-4333-8333-333333333333', token: 'ab'.repeat(32) };

const memoryStorage = () => {
  const values = new Map();
  return {
    values,
    getItem: key => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => { values.set(key, String(value)); },
    removeItem: key => { values.delete(key); },
  };
};

test('capabilities are stored per poll and read back exactly', () => {
  const storage = memoryStorage();
  assert.equal(saveGuestCapability(storage, pollA, capability), true);
  assert.deepEqual(readGuestCapability(storage, pollA), capability);
  assert.equal(readGuestCapability(storage, pollB), null, 'another poll has no capability');
  assert.deepEqual([...storage.values.keys()], [guestStorageKey(pollA)]);
  clearGuestCapability(storage, pollA);
  assert.equal(readGuestCapability(storage, pollA), null);
});

test('malformed or tampered entries are discarded rather than sent to the server', () => {
  const storage = memoryStorage();
  for (const raw of ['not json', '{}', JSON.stringify({ ...capability, token: 'AB'.repeat(32) }),
    JSON.stringify({ ...capability, token: 'ab' }), JSON.stringify({ ...capability, participantId: 'x' }),
    JSON.stringify(null)]) {
    storage.setItem(guestStorageKey(pollA), raw);
    assert.equal(readGuestCapability(storage, pollA), null, raw);
    assert.equal(storage.values.has(guestStorageKey(pollA)), false, raw);
  }
  assert.equal(saveGuestCapability(storage, pollA, { ...capability, token: 'short' }), false);
  assert.equal(isValidCapability({ ...capability, extra: true }), true);
  storage.setItem(guestStorageKey(pollA), JSON.stringify({ ...capability, extra: 'ignored' }));
  assert.deepEqual(readGuestCapability(storage, pollA), capability, 'only the two known fields are returned');
});

test('unavailable or failing storage degrades to no capability without throwing', () => {
  assert.equal(readGuestCapability(null, pollA), null);
  assert.equal(saveGuestCapability(null, pollA, capability), false);
  const failing = {
    getItem: () => { throw new Error('SecurityError'); },
    setItem: () => { throw new Error('QuotaExceededError'); },
    removeItem: () => { throw new Error('SecurityError'); },
  };
  assert.equal(readGuestCapability(failing, pollA), null);
  assert.equal(saveGuestCapability(failing, pollA, capability), false);
  assert.doesNotThrow(() => clearGuestCapability(failing, pollA));
});

test('error classification matches the server contract', () => {
  assert.equal(isMissingRpc({ code: 'PGRST202', message: 'Could not find the function' }), true);
  assert.equal(isMissingRpc({ code: '42501', message: 'Guest access denied' }), false);
  assert.equal(isMissingRpc(null), false);
  assert.equal(isGuestAccessDenied({ code: '42501', message: 'Guest access denied' }), true);
  assert.equal(isGuestAccessDenied({ code: '42501', message: 'Poll is not accepting changes' }), false);
  assert.equal(isGuestAccessDenied({ code: '22023', message: 'Guest access denied' }), false);
  assert.equal(isPollClosedError({ code: '42501', message: 'Poll is not accepting participants' }), true);
  assert.equal(isPollClosedError({ code: '42501', message: 'Poll is not accepting changes' }), true);
  assert.equal(isPollClosedError({ code: '42501', message: 'Guest access denied' }), false);
  assert.equal(GUEST_ACCESS_LOST_MESSAGE.includes(capability.token), false);
});
