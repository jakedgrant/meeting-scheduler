import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { bootstrapCreationDatabase } from './helpers/creation-database.mjs';

const migration = '20261127000000_profile_onboarding.sql';
const deny = error => error.code === '42501';

test('onboarding completion is stored per account and set once', async t => {
  const db = new PGlite(); t.after(() => db.close());
  const rows = async (sql, params = []) => (await db.query(sql, params)).rows;
  const scalar = async (sql, params = []) => (await rows(sql, params))[0].result;
  const user = async (id = randomUUID()) => {
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)', [id, `${id}@test.invalid`]);
    return id;
  };
  const as = async (id, action, role = id ? 'authenticated' : 'anon') => {
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id ?? '']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ role, sub: id })]);
    await db.exec(`SET ROLE ${role}`);
    try { return await action(); } finally { await db.exec('RESET ROLE'); }
  };

  // An account that signed up before the migration.
  let existing;
  await bootstrapCreationDatabase(db, async name => { if (name === migration) existing = await user(); });
  const fresh = await user();
  const completedAt = async id => scalar('SELECT onboarding_completed_at AS result FROM public.profiles WHERE id=$1', [id]);

  await t.test('existing accounts are complete as of their creation; new accounts are not', async () => {
    const [row] = await rows('SELECT created_at, updated_at FROM public.profiles WHERE id=$1', [existing]);
    assert.deepEqual(await completedAt(existing), row.created_at);
    // The backfill is not an edit, so updated_at is untouched.
    assert.deepEqual(row.updated_at, row.created_at);
    assert.equal(await completedAt(fresh), null);
  });

  await t.test('the owner reads the column only through get_my_profile', async () => {
    await as(fresh, async () => {
      const [own] = await rows('SELECT onboarding_completed_at FROM public.get_my_profile()');
      assert.equal(own.onboarding_completed_at, null);
      await assert.rejects(db.query('SELECT onboarding_completed_at FROM public.profiles'), deny);
    });
  });

  await t.test('complete_onboarding stamps the caller once and returns the stored time', async () => {
    const first = await as(fresh, () => scalar('SELECT public.complete_onboarding() AS result'));
    assert.ok(first instanceof Date);
    assert.deepEqual(await completedAt(fresh), first);
    const again = await as(fresh, () => scalar('SELECT public.complete_onboarding() AS result'));
    assert.deepEqual(again, first);
    const [own] = await as(fresh, () => rows('SELECT onboarding_completed_at FROM public.get_my_profile()'));
    assert.deepEqual(own.onboarding_completed_at, first);
  });

  await t.test('it changes no other account and signed-out callers cannot call it', async () => {
    const other = await user();
    await as(fresh, () => scalar('SELECT public.complete_onboarding() AS result'));
    assert.equal(await completedAt(other), null);
    await as(null, () => assert.rejects(db.query('SELECT public.complete_onboarding()'), deny));
    await as(null, () => assert.rejects(db.query('SELECT poll_private.complete_onboarding()'), deny));
  });

  await t.test('catalog: a pinned definer helper behind an invoker wrapper, not executable by anon', async () => {
    const functions = await rows(`SELECT n.nspname || '.' || p.proname AS name, p.prosecdef, p.proconfig,
      has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
      has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE p.proname='complete_onboarding' ORDER BY 1`);
    assert.deepEqual(functions.map(fn => [fn.name, fn.prosecdef, fn.anon, fn.authenticated]), [
      ['poll_private.complete_onboarding', true, false, true],
      ['public.complete_onboarding', false, false, true],
    ]);
    for (const fn of functions) assert.ok(fn.proconfig.includes('search_path=""'), fn.name);
  });
});
