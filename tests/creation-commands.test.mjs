import { PGlite } from '@electric-sql/pglite';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import {bootstrapCreationDatabase,creationPayload} from './helpers/creation-database.mjs';
const code = value => error => error.code===value;

test('F05/F09 atomic creation, retry identity and server limits', async t => {
  const db=new PGlite(); t.after(()=>db.close());
  const legacyOwner=randomUUID(),legacyReceiptOwner=randomUUID();let legacyPoll,legacyPass;
  await bootstrapCreationDatabase(db,async name=>{
    if(!name.endsWith('_transactional_poll_creation.sql'))return;
    await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2),($3,$4)',
      [legacyOwner,'legacy-owner@test.invalid',legacyReceiptOwner,'legacy-receipt@test.invalid']);
    legacyPoll=(await db.query("INSERT INTO public.polls(creator_id,title,status,is_premium,max_participants) VALUES($1,'Historical funded poll','active',true,50) RETURNING id",[legacyOwner])).rows[0].id;
    legacyPass=(await db.query(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,redeemed_at,poll_id,revoked_at)
      VALUES($1,'historical-redeemed-pass','APP_STORE',now(),now(),$2,now()) RETURNING id`,[legacyReceiptOwner,legacyPoll])).rows[0].id;
  });
  const scalar=async(sql,params=[]) => (await db.query(sql,params)).rows[0].result;
  const user=async()=>{
    const id=randomUUID(); await db.query('INSERT INTO auth.users(id,email) VALUES($1,$2)',[id,`${id}@test.invalid`]); return id;
  };
  const as=async(id,action,role='authenticated')=>{
    await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id??'']);
    await db.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({role,sub:id})]);
    await db.exec(`SET ROLE ${role}`);
    try{return await action();}finally{await db.exec('RESET ROLE');}
  };
  const create=(id,payload=creationPayload(),operation=randomUUID())=>as(id,()=>scalar('SELECT public.create_poll($1,$2) AS result',[operation,JSON.stringify(payload)]));
  const grant=async(id,tier='pro_access',valid="now()+interval '1 hour'")=>db.query(`INSERT INTO private.billing_entitlements
    (user_id,resource_id,entitlement,store,purchased_at,valid_until) VALUES($1,$2,$3,'PROMOTIONAL',now(),${valid})`,[id,randomUUID(),tier]);
  const addPass=async(id,{expired=false,revoked=false,spent=false,legacy=false}={})=>{
    const pass=(await db.query(`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,
      billing_project_id,billing_environment,revenuecat_purchase_id,product_id,store_transaction_id,purchase_unit,verified_until,revoked_at,redeemed_at)
      VALUES($1,$2,'APP_STORE',now(),$3,$4,$5,$6,$7,$8,${expired?"now()-interval '1 hour'":"now()+interval '1 hour'"},
        ${revoked?'now()':'NULL'},${spent?'now()':'NULL'}) RETURNING id`,
    [id,randomUUID(),legacy?null:'project',legacy?null:'sandbox',legacy?null:'purchase',legacy?null:'product',legacy?null:randomUUID(),legacy?null:1])).rows[0].id;return pass;
  };
  const counts=async(id)=>scalar(`SELECT jsonb_build_object('polls',(SELECT count(*) FROM public.polls WHERE creator_id=$1),
    'options',(SELECT count(*) FROM public.poll_time_options o JOIN public.polls p ON p.id=o.poll_id WHERE p.creator_id=$1),
    'spent',(SELECT count(*) FROM public.event_passes WHERE user_id=$1 AND redeemed_at IS NOT NULL),
    'requests',(SELECT count(*) FROM private.poll_creation_requests WHERE creator_id=$1)) AS result`,[id]);

  await t.test('catalog restricts creation, private retry state and function execution',async()=>{
    assert.equal(await scalar("SELECT has_function_privilege('anon','public.create_poll(uuid,jsonb)','EXECUTE') AS result"),false);
    for(const role of ['anon','authenticated']){
      assert.equal(await scalar(`SELECT has_table_privilege($1,'public.polls','INSERT') AS result`,[role]),false);
      assert.equal(await scalar(`SELECT has_table_privilege($1,'private.poll_creation_requests','SELECT') AS result`,[role]),false);
    }
    const funcs=(await db.query(`SELECT p.prosecdef,p.proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE p.proname='create_poll' AND n.nspname IN ('public','poll_private') ORDER BY n.nspname`)).rows;
    assert.equal(funcs.length,2); assert.deepEqual(funcs.map(f=>f.prosecdef),[true,false]);
    assert.ok(funcs.every(f=>f.proconfig.includes('search_path=""')));
  });
  await t.test('migration backfills actual historical funding without changing revoked receipt ownership',async()=>{
    const saved=(await db.query('SELECT * FROM private.poll_pass_funding WHERE poll_id=$1',[legacyPoll])).rows[0];
    assert.equal(saved.creator_id,legacyOwner);assert.equal(saved.event_pass_id,legacyPass);
    assert.equal(await scalar('SELECT user_id AS result FROM public.event_passes WHERE id=$1',[legacyPass]),legacyReceiptOwner);
    const free=await create(legacyOwner);assert.equal(free.entitlement,'free');
    await assert.rejects(create(legacyOwner),code('P0001'));
  });
  await t.test('signed out and null operation identity are rejected',async()=>{
    await assert.rejects(create(null),code('42501'));
    await assert.rejects(create(await user(),creationPayload(),null),code('22023'));
  });
  await t.test('free create returns complete authoritative rows and deadline',async()=>{
    const id=await user(),payload=creationPayload({closes_at:'2099-11-01T12:00:00Z'});
    const r=await create(id,payload);
    assert.equal(r.poll.creator_id,id); assert.equal(r.poll.status,'active'); assert.equal(r.poll.max_participants,10);
    assert.equal(r.poll.is_premium,false); assert.equal(r.entitlement,'free'); assert.equal(r.redeemed_pass_id,null);
    assert.equal(r.time_options.length,2);assert.ok(r.time_options.every(o=>o.poll_id===r.poll.id));
    assert.match(r.poll.share_code,/^[A-Z2-9]{6}$/); assert.deepEqual(await counts(id),{polls:1,options:2,spent:0,requests:1});
  });
  await t.test('unchanged retries and lost replies replay even after closure/deletion',async()=>{
    const id=await user(),op=randomUUID(),payload=creationPayload();
    const first=await create(id,payload,op);
    const retry=await create(id,{...payload},op); assert.deepEqual(retry,{...first,replayed:true});
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1",[first.poll.id]);
    assert.deepEqual(await create(id,payload,op),{...first,replayed:true});
    await db.query('DELETE FROM public.polls WHERE id=$1',[first.poll.id]);
    assert.deepEqual(await create(id,payload,op),{...first,replayed:true});
  });
  await t.test('changed operation payload is rejected without a second poll',async()=>{
    const id=await user(),op=randomUUID(); await create(id,creationPayload(),op);
    await assert.rejects(create(id,creationPayload({title:'Changed'}),op),code('22000'));
    assert.deepEqual(await counts(id),{polls:1,options:2,spent:0,requests:1});
  });
  await t.test('operation IDs belong to an account',async()=>{
    const a=await user(),b=await user(),op=randomUUID();
    const first=await create(a,creationPayload(),op),second=await create(b,creationPayload(),op);
    assert.notEqual(first.poll.id,second.poll.id);assert.equal(second.poll.creator_id,b);
  });
  const invalidPayloads=[
    ['scalar option',{time_options:[42]}], ['null option',{time_options:[null]}],
    ['no options',{time_options:[]}], ['not an option array',{time_options:{}}],
    ['reversed interval',{time_options:[{start_time:'2027-01-01T12:00Z',end_time:'2027-01-01T11:00Z'}]}],
    ['invalid later option',{time_options:[...creationPayload().time_options,{start_time:'bad',end_time:'bad'}]}],
    ['offsetless instant',{time_options:[{start_time:'2027-01-01T12:00:00',end_time:'2027-01-01T13:00:00'}]}],
    ['invalid timezone',{timezone:'Not/AZone'}],['past deadline',{closes_at:'2020-01-01T12:00Z'}],
    ['invalid title',{title:' '}],['oversized description',{description:'x'.repeat(10001)}],
    ['unauthorized premium',{is_premium:true}],['unauthorized capacity',{max_participants:100}],
    ['forged owner',{creator_id:randomUUID()}],['forged status',{status:'draft'}],
    ['unexpected option key',{time_options:[{...creationPayload().time_options[0],poll_id:randomUUID()}]}],
  ];
  for(const [label,extra] of invalidPayloads) await t.test(`reject ${label} without poll, redemption or quota`,async()=>{
    const id=await user();await addPass(id);
    await assert.rejects(create(id,creationPayload({...extra,use_event_pass:true})),code('22023'));
    assert.deepEqual(await counts(id),{polls:0,options:0,spent:0,requests:0});
  });
  await t.test('injected option storage failure rolls back poll, pass and retry receipt',async()=>{
    const id=await user();await addPass(id);const op=randomUUID();
    await db.exec(`CREATE FUNCTION public.fail_creation_option() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
      IF NEW.start_time='2027-11-02T12:00Z' THEN RAISE EXCEPTION 'injected storage failure'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER fail_creation_option BEFORE INSERT ON public.poll_time_options FOR EACH ROW EXECUTE FUNCTION public.fail_creation_option();`);
    await assert.rejects(create(id,creationPayload({use_event_pass:true}),op),/injected storage failure/);
    assert.deepEqual(await counts(id),{polls:0,options:0,spent:0,requests:0});
    await db.exec('DROP TRIGGER fail_creation_option ON public.poll_time_options;DROP FUNCTION public.fail_creation_option()');
    await create(id,creationPayload({use_event_pass:true}),op);
    assert.deepEqual(await counts(id),{polls:1,options:2,spent:1,requests:1});
  });
  await t.test('active quota cannot be bypassed with another operation',async()=>{
    const id=await user();await create(id);await assert.rejects(create(id),code('P0001'));
  });
  for(const tier of ['pro_access','team_access'])await t.test(`${tier} grants current configured capacity and unlimited polls`,async()=>{
    const id=await user();await grant(id,tier);const r=await create(id);await create(id);
    assert.equal(r.poll.max_participants,tier==='team_access'?100:50);assert.equal(r.poll.is_premium,true);assert.equal(r.entitlement,tier);
  });
  await t.test('stale private entitlement and forged public premium boolean do not authorize',async()=>{
    const id=await user();await grant(id,'team_access',"now()-interval '1 second'");
    await db.query(`INSERT INTO public.subscriptions(user_id,entitlement,is_active) VALUES($1,'team_access',true)`,[id]);
    const r=await create(id);assert.equal(r.poll.max_participants,10);assert.equal(r.poll.is_premium,false);
    await assert.rejects(create(id),code('P0001'));
    assert.equal(await as(id,()=>scalar('SELECT public.get_user_entitlement() AS result')),null);
  });
  await t.test('expired team falls back to valid pro from the billing contract',async()=>{
    const id=await user();await grant(id,'team_access',"now()-interval '1 second'");await grant(id,'pro_access');
    const r=await create(id);assert.equal(r.entitlement,'pro_access');assert.equal(r.poll.max_participants,50);
  });
  for(const state of ['missing','expired','revoked','spent','legacy'])await t.test(`${state} pass cannot fund creation`,async()=>{
    const id=await user();if(state!=='missing')await addPass(id,{[state]:true});
    await assert.rejects(create(id,creationPayload({use_event_pass:true})),code('P0002'));
    assert.equal((await counts(id)).polls,0);assert.equal((await counts(id)).requests,0);
  });
  await t.test('pass redemption is atomic and retry cannot spend another unit',async()=>{
    const id=await user();const pass=await addPass(id);await addPass(id);const op=randomUUID(),payload=creationPayload({use_event_pass:true});
    const r=await create(id,payload,op);assert.equal(r.poll.max_participants,50);assert.equal(r.entitlement,'event_pass');assert.equal(r.poll.is_premium,true);
    assert.deepEqual(await create(id,payload,op),{...r,replayed:true});assert.equal((await counts(id)).spent,1);
    assert.equal(await scalar('SELECT poll_id AS result FROM public.event_passes WHERE id=$1',[r.redeemed_pass_id]),r.poll.id);
    assert.ok(pass);
  });
  await t.test('one free slot is independent of pass-funded polls and durable receipt ownership',async()=>{
    const id=await user(),other=await user();await addPass(id);await addPass(id);
    const paid=await create(id,creationPayload({use_event_pass:true}));
    assert.equal(await as(id,()=>scalar('SELECT public.can_create_poll() AS result')),true);
    await create(id);await create(id,creationPayload({use_event_pass:true}));
    await assert.rejects(create(id),code('P0001'));
    await db.query('UPDATE public.event_passes SET user_id=$2,revoked_at=now() WHERE id=$1',[paid.redeemed_pass_id,other]);
    await db.query('DELETE FROM public.event_passes WHERE id=$1',[paid.redeemed_pass_id]);
    const free=(await db.query('SELECT id FROM public.polls WHERE creator_id=$1 AND NOT is_premium',[id])).rows[0].id;
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1",[free]);
    await create(id);await assert.rejects(create(id),code('P0001'));
    assert.equal(await scalar('SELECT count(*)::int AS result FROM private.poll_pass_funding WHERE creator_id=$1',[id]),2);
  });
  await t.test('pass consumption is explicit and selects oldest eligible purchase',async()=>{
    const id=await user();const newer=await addPass(id),older=await addPass(id),revoked=await addPass(id,{revoked:true});
    await db.query("UPDATE public.event_passes SET purchased_at=now()-interval '2 days' WHERE id=$1",[older]);
    await db.query("UPDATE public.event_passes SET purchased_at=now()-interval '3 days' WHERE id=$1",[revoked]);
    const free=await create(id);assert.equal(free.entitlement,'free');assert.equal((await counts(id)).spent,0);
    await assert.rejects(create(id),code('P0001'));assert.equal((await counts(id)).spent,0);
    const paid=await create(id,creationPayload({use_event_pass:true}));assert.equal(paid.redeemed_pass_id,older);
    assert.equal(await scalar('SELECT redeemed_at AS result FROM public.event_passes WHERE id=$1',[newer]),null);
  });
  for(const tier of ['pro_access','team_access'])await t.test(`${tier} preserves pass despite opt-in`,async()=>{
    const id=await user();await grant(id,tier);await addPass(id);const r=await create(id,creationPayload({use_event_pass:true}));
    assert.equal(r.entitlement,tier);assert.equal(r.redeemed_pass_id,null);assert.equal((await counts(id)).spent,0);
  });
  await t.test('subscription premium reopening requires current tier to support saved capacity',async()=>{
    const id=await user();await grant(id,'team_access');const team=(await create(id)).poll;
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1",[team.id]);
    await db.query('DELETE FROM private.billing_entitlements WHERE user_id=$1',[id]);
    await assert.rejects(as(id,()=>db.query("UPDATE public.polls SET status='active' WHERE id=$1",[team.id])),code('42501'));
    await grant(id,'pro_access');
    await assert.rejects(as(id,()=>db.query("UPDATE public.polls SET status='active' WHERE id=$1",[team.id])),code('42501'));
    await grant(id,'team_access');await as(id,()=>db.query("UPDATE public.polls SET status='active' WHERE id=$1",[team.id]));
    assert.equal(await scalar('SELECT max_participants AS result FROM public.polls WHERE id=$1',[team.id]),100);
  });
  await t.test('pass-funded reopening retains funding after revocation or receipt transfer',async()=>{
    const id=await user();await addPass(id);const r=await create(id,creationPayload({use_event_pass:true}));await create(id);
    await db.query("UPDATE public.polls SET status='closed' WHERE id=$1",[r.poll.id]);
    await db.query('UPDATE public.event_passes SET revoked_at=now(),user_id=$2 WHERE id=$1',[r.redeemed_pass_id,await user()]);
    await as(id,()=>db.query("UPDATE public.polls SET status='active' WHERE id=$1",[r.poll.id]));
    assert.equal(await scalar('SELECT max_participants AS result FROM public.polls WHERE id=$1',[r.poll.id]),50);
  });
  await t.test('injected receipt storage failure rolls back an already executed redemption',async()=>{
    const id=await user();await addPass(id);const op=randomUUID(),payload=creationPayload({use_event_pass:true});
    await db.exec(`CREATE FUNCTION public.fail_creation_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
      RAISE EXCEPTION 'injected receipt failure'; END $$;
      CREATE TRIGGER fail_creation_receipt BEFORE INSERT ON private.poll_creation_requests FOR EACH ROW EXECUTE FUNCTION public.fail_creation_receipt();`);
    await assert.rejects(create(id,payload,op),/injected receipt failure/);
    assert.deepEqual(await counts(id),{polls:0,options:0,spent:0,requests:0});
    assert.equal(await scalar('SELECT count(*)::int AS result FROM private.poll_pass_funding WHERE creator_id=$1',[id]),0);
    await db.exec('DROP TRIGGER fail_creation_receipt ON private.poll_creation_requests;DROP FUNCTION public.fail_creation_receipt()');
    await create(id,payload,op);assert.equal((await counts(id)).spent,1);
  });
  await t.test('direct field validation and inherited API roles cannot bypass updates',async()=>{
    const id=await user(),r=await create(id);
    for(const expression of ["status=NULL","title=' '","timezone='Invalid/Zone'","closes_at='infinity'", "description=repeat('x',10001)"]){
      await assert.rejects(as(id,()=>db.query(`UPDATE public.polls SET ${expression} WHERE id=$1`,[r.poll.id])),code('22023'));
    }
    await db.exec('CREATE ROLE api_child INHERIT;GRANT authenticated TO api_child');
    await assert.rejects(as(id,()=>db.query('UPDATE public.polls SET max_participants=100 WHERE id=$1',[r.poll.id]),'api_child'),code('42501'));
    await assert.rejects(as(id,()=>db.query("UPDATE public.poll_time_options SET start_time='infinity' WHERE id=$1",[r.time_options[0].id])),code('22023'));
    await assert.rejects(as(id,()=>db.query("UPDATE public.poll_time_options SET is_all_day=NULL WHERE id=$1",[r.time_options[0].id])),code('22023'));
  });
  await t.test('share code collisions with inaccessible closed poll are retried privately',async()=>{
    const hidden=(await create(await user())).poll;await db.query("UPDATE public.polls SET status='closed',share_code='AAAAAA' WHERE id=$1",[hidden.id]);
    await db.exec(`CREATE SEQUENCE public.creation_code_test;
      CREATE OR REPLACE FUNCTION public.generate_share_code() RETURNS text LANGUAGE plpgsql AS $$ BEGIN
      IF nextval('public.creation_code_test')=1 THEN RETURN 'AAAAAA';END IF;RETURN 'BBBBBB';END $$;`);
    const id=await user();const r=await create(id);assert.equal(r.poll.share_code,'BBBBBB');assert.notEqual(r.poll.id,hidden.id);
    assert.equal(await as(id,()=>scalar('SELECT count(*)::int AS result FROM public.polls WHERE id=$1',[hidden.id])),0);
    await db.exec(`CREATE OR REPLACE FUNCTION public.generate_share_code() RETURNS text LANGUAGE sql AS $$ SELECT substr(md5(random()::text),1,6) $$;`);
  });
  await t.test('direct inserts and paid-field/identity updates cannot bypass command',async()=>{
    const id=await user();const r=await create(id);
    await assert.rejects(as(id,()=>db.query("INSERT INTO public.polls(creator_id,title,status,is_premium,max_participants) VALUES($1,'Bypass','active',true,100)",[id])),code('42501'));
    for(const expression of ["is_premium=true","max_participants=100","share_code='FORGED'",`creator_id='${await user()}'`]){
      await assert.rejects(as(id,()=>db.query(`UPDATE public.polls SET ${expression} WHERE id=$1`,[r.poll.id])),code('42501'));
    }
  });
  await t.test('closed poll reactivation consumes quota under the creation owner lock',async()=>{
    const id=await user();const first=(await create(id)).poll;
    await as(id,()=>db.query("UPDATE public.polls SET status='closed' WHERE id=$1",[first.id]));await create(id);
    await assert.rejects(as(id,()=>db.query("UPDATE public.polls SET status='active' WHERE id=$1",[first.id])),code('P0001'));
  });
  await t.test('member and guest capacity, direct inserts and same-identity retries',async()=>{
    const owner=await user(),r=await create(owner);const members=[];
    for(let i=0;i<9;i++){const id=await user();members.push(id);await as(id,()=>scalar('SELECT public.join_poll($1) AS result',[r.poll.id]));}
    const token='a'.repeat(64);
    const guest=await as(null,()=>scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',[r.poll.id,'Guest',token]),'anon');
    assert.equal(guest.created,true);
    assert.equal((await as(members[0],()=>scalar('SELECT public.join_poll($1) AS result',[r.poll.id]))).created,false);
    assert.equal((await as(null,()=>scalar('SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',[r.poll.id,'Guest',token]),'anon')).created,false);
    await assert.rejects(as(await user(),()=>scalar('SELECT public.join_poll($1) AS result',[r.poll.id])),code('P0003'));
    await assert.rejects(as(null,()=>scalar('SELECT public.join_poll_as_guest($1,$2) AS result',[r.poll.id,'Extra guest']),'anon'),code('P0003'));
    const extra=await user();await assert.rejects(as(extra,()=>db.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)',[r.poll.id,extra])),code('P0003'));
    await assert.rejects(as(null,()=>db.query("INSERT INTO public.poll_participants(poll_id,anonymous_name) VALUES($1,'Extra')",[r.poll.id]),'anon'),code('P0003'));
    assert.equal(await scalar('SELECT count(*)::int AS result FROM public.poll_participants WHERE poll_id=$1',[r.poll.id]),10);
  });
});
