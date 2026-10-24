import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import test from 'node:test';
import pg from 'pg';
import {bootstrapCreationDatabase,creationPayload} from './helpers/creation-database.mjs';
const connectionString=process.env.TEST_DATABASE_URL;
assert.ok(connectionString,'TEST_DATABASE_URL must name a fresh disposable PostgreSQL database');
assert.match(decodeURIComponent(new URL(connectionString).pathname.slice(1)),/^scheduler_test_/);

test('F05/F09 independent PostgreSQL creation, redemption and capacity races', {timeout:90000},async t=>{
  const admin=new pg.Client({connectionString,application_name:'scheduler-creation-observer'});
  const first=new pg.Client({connectionString,application_name:'scheduler-creation-first'});
  const second=new pg.Client({connectionString,application_name:'scheduler-creation-second'});
  await Promise.all([admin.connect(),first.connect(),second.connect()]);
  t.after(()=>Promise.all([admin.end(),first.end(),second.end()]));
  await Promise.all([admin,first,second].map(c=>c.query("SET statement_timeout='10s'")));
  const scalar=async(c,sql,params=[]) => (await c.query(sql,params)).rows[0].result;
  assert.equal(await scalar(admin,`SELECT count(*)::int AS result FROM information_schema.tables
    WHERE table_schema IN ('public','auth','private','poll_private')`),0,'database must be fresh');
  console.log(await scalar(admin,'SELECT version() AS result'));
  await bootstrapCreationDatabase({exec:sql=>admin.query(sql)});
  const user=async()=>{const id=randomUUID();await admin.query('INSERT INTO auth.users(id,email) VALUES($1,$2)',[id,`${id}@test.invalid`]);return id;};
  const role=async(c,id=null,name='authenticated')=>{
    await c.query('RESET ROLE');await c.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id??'']);
    await c.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({role:name,sub:id})]);
    await c.query(`SET ROLE ${name}`);
  };
  const create=(c,payload=creationPayload(),op=randomUUID())=>scalar(c,'SELECT public.create_poll($1,$2) AS result',[op,JSON.stringify(payload)]);
  const addPass=async(id)=>scalar(admin,`INSERT INTO public.event_passes(user_id,transaction_id,store,purchased_at,
    billing_project_id,billing_environment,revenuecat_purchase_id,product_id,store_transaction_id,purchase_unit,verified_until)
    VALUES($1,$2,'APP_STORE',now(),'project','sandbox','purchase','product',$3,1,now()+interval '1 hour') RETURNING id AS result`,[id,randomUUID(),randomUUID()]);
  let waits=0;
  const race=async(winner,loser,expected=null,afterWait=async()=>{})=>{
    await first.query('BEGIN');
    try{
      const won=await winner();const pid=await scalar(second,'SELECT pg_backend_pid() AS result');
      const pending=loser().then(result=>({result}),error=>({error}));
      let observed=false;const until=Date.now()+5000;
      while(Date.now()<until){
        const state=await scalar(admin,'SELECT wait_event_type AS result FROM pg_stat_activity WHERE pid=$1',[pid]);
        if(state==='Lock'){observed=true;break;}await delay(20);
      }
      assert.equal(observed,true,`session ${pid} must wait for a real lock`);waits++;
      await afterWait();
      await first.query('COMMIT');const outcome=await pending;
      if(expected)assert.equal(outcome.error?.code,expected,outcome.error?.message);
      else if(outcome.error)throw outcome.error;
      return {won,outcome};
    }finally{await first.query('ROLLBACK');}
  };
  const count=async(id,table='polls')=>scalar(admin,`SELECT count(*)::int AS result FROM public.${table} WHERE ${table==='polls'?'creator_id':'user_id'}=$1`,[id]);
  await t.test('competing free creates serialize and commit only one active poll',async()=>{
    const id=await user();await role(first,id);await role(second,id);
    await race(()=>create(first),()=>create(second),'P0001');assert.equal(await count(id),1);
  });
  await t.test('same operation after a lost reply waits and returns the original result',async()=>{
    const id=await user(),op=randomUUID();await role(first,id);await role(second,id);
    const {won,outcome}=await race(()=>create(first,creationPayload(),op),()=>create(second,creationPayload(),op));
    assert.deepEqual(outcome.result,{...won,replayed:true});assert.equal(await count(id),1);
  });
  await t.test('changed same-ID payload waits then rejects without a second poll',async()=>{
    const id=await user(),op=randomUUID();await role(first,id);await role(second,id);
    await race(()=>create(first,creationPayload(),op),()=>create(second,creationPayload({title:'Changed'}),op),'22000');
    assert.equal(await count(id),1);
  });
  await t.test('one pass cannot fund competing operations',async()=>{
    const id=await user(),pass=await addPass(id);await role(first,id);await role(second,id);
    const {won}=await race(()=>create(first,creationPayload({use_event_pass:true})),()=>create(second,creationPayload({use_event_pass:true})),'P0002');
    assert.equal(await count(id),1);assert.equal(await scalar(admin,'SELECT poll_id AS result FROM public.event_passes WHERE id=$1',[pass]),won.poll.id);
  });
  for(const mutation of ['revoked_at=now()','redeemed_at=now()',"verified_until=now()-interval '1 second'",'user_id=$2'])await t.test(`locked pass eligibility is rechecked after billing ${mutation}`,async()=>{
    const id=await user(),other=await user(),pass=await addPass(id);await role(first,null,'service_role');await role(second,id);
    await race(()=>first.query(`UPDATE public.event_passes SET ${mutation} WHERE id=$1`,mutation==='user_id=$2'?[pass,other]:[pass]),
      ()=>create(second,creationPayload({use_event_pass:true})),'P0002');assert.equal(await count(id),0);
    assert.equal(await scalar(admin,'SELECT count(*)::int AS result FROM private.poll_creation_requests WHERE creator_id=$1',[id]),0);
  });
  for(const occupied of [false,true])await t.test(`subscription naturally expires while waiting for owner lock (free slot ${occupied?'occupied':'empty'})`,async()=>{
    const id=await user();await role(second,id);if(occupied)await create(second);
    await admin.query(`INSERT INTO private.billing_entitlements(user_id,resource_id,entitlement,store,purchased_at,valid_until)
      VALUES($1,'expiring','pro_access','PROMOTIONAL',clock_timestamp(),clock_timestamp()+interval '500 milliseconds')`,[id]);
    await role(first,null,'service_role');
    const {outcome}=await race(()=>first.query('SELECT id FROM public.profiles WHERE id=$1 FOR UPDATE',[id]),
      ()=>create(second),occupied?'P0001':null,()=>delay(650));
    if(!occupied){assert.equal(outcome.result.entitlement,'free');assert.equal(outcome.result.poll.max_participants,10);}
  });
  await t.test('pass naturally expires while creation waits for its row lock',async()=>{
    const id=await user(),pass=await addPass(id);await role(first,null,'service_role');await role(second,id);
    await admin.query("UPDATE public.event_passes SET verified_until=clock_timestamp()+interval '500 milliseconds' WHERE id=$1",[pass]);
    await race(()=>first.query('SELECT id FROM public.event_passes WHERE id=$1 FOR UPDATE',[pass]),
      ()=>create(second,creationPayload({use_event_pass:true})),'P0002',()=>delay(650));assert.equal(await count(id),0);
    assert.equal(await scalar(admin,'SELECT redeemed_at AS result FROM public.event_passes WHERE id=$1',[pass]),null);
  });
  await t.test('deadline naturally expires while creation waits for pass lock',async()=>{
    const id=await user(),pass=await addPass(id);await role(first,null,'service_role');await role(second,id);
    const payload=creationPayload({use_event_pass:true,closes_at:new Date(Date.now()+500).toISOString()});
    await race(()=>first.query('SELECT id FROM public.event_passes WHERE id=$1 FOR UPDATE',[pass]),
      ()=>create(second,payload),'22023',()=>delay(650));assert.equal(await count(id),0);
    assert.equal(await scalar(admin,'SELECT redeemed_at AS result FROM public.event_passes WHERE id=$1',[pass]),null);
  });
  await t.test('subscription naturally expires while premium reopening waits for owner lock',async()=>{
    const id=await user();await admin.query(`INSERT INTO private.billing_entitlements(user_id,resource_id,entitlement,store,purchased_at,valid_until)
      VALUES($1,'reopen','pro_access','PROMOTIONAL',clock_timestamp(),clock_timestamp()+interval '1 hour')`,[id]);
    await role(second,id);const r=await create(second);await admin.query("UPDATE public.polls SET status='closed' WHERE id=$1",[r.poll.id]);
    await admin.query("UPDATE private.billing_entitlements SET valid_until=clock_timestamp()+interval '500 milliseconds' WHERE user_id=$1",[id]);
    await role(first,null,'service_role');await race(()=>first.query('SELECT id FROM public.profiles WHERE id=$1 FOR UPDATE',[id]),
      ()=>second.query("UPDATE public.polls SET status='active' WHERE id=$1",[r.poll.id]),'42501',()=>delay(650));
  });
  for(const direct of [false,true])await t.test(`join deadline expires while ${direct?'direct insert':'command'} waits for poll lock`,async()=>{
    const id=await user(),member=await user();await role(second,id);const r=await create(second);
    await admin.query("UPDATE public.polls SET closes_at=clock_timestamp()+interval '500 milliseconds' WHERE id=$1",[r.poll.id]);
    await role(first,null,'service_role');await role(second,member);
    await race(()=>first.query('SELECT id FROM public.polls WHERE id=$1 FOR UPDATE',[r.poll.id]),
      ()=>direct?second.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)',[r.poll.id,member]):scalar(second,'SELECT public.join_poll($1) AS result',[r.poll.id]),'42501',()=>delay(650));
  });
  const capacityFixture=async()=>{
    const owner=await user();await role(first,owner);const result=await create(first);const poll=result.poll.id;
    // Owner is not automatically a participant. Exactly nine actual rows occupy
    // nine of the configured ten places, independent of owner identity.
    for(let i=0;i<9;i++)await admin.query('INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)',[poll,await user()]);
    return poll;
  };
  for(const kind of ['member','guest','direct member','direct guest'])await t.test(`competing ${kind} joins cannot exceed final place`,async()=>{
    const poll=await capacityFixture(),a=await user(),b=await user();
    const guest=kind.includes('guest'),direct=kind.startsWith('direct');await role(first,guest?null:a,guest?'anon':'authenticated');await role(second,guest?null:b,guest?'anon':'authenticated');
    const join=(c,id,token)=>direct
      ? c.query(guest?"INSERT INTO public.poll_participants(poll_id,anonymous_name) VALUES($1,'Guest')":'INSERT INTO public.poll_participants(poll_id,user_id) VALUES($1,$2)',guest?[poll]:[poll,id])
      : guest?scalar(c,'SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',[poll,'Guest',token]):scalar(c,'SELECT public.join_poll($1) AS result',[poll]);
    await race(()=>join(first,a,'a'.repeat(64)),()=>join(second,b,'b'.repeat(64)),'P0003');
    assert.equal(await scalar(admin,'SELECT count(*)::int AS result FROM public.poll_participants WHERE poll_id=$1',[poll]),10);
  });
  for(const guest of [false,true])await t.test(`same ${guest?'guest capability':'membership'} concurrent retry succeeds at capacity`,async()=>{
    const poll=await capacityFixture(),id=await user(),token=randomUUID().replaceAll('-','').repeat(2);
    await role(first,guest?null:id,guest?'anon':'authenticated');await role(second,guest?null:id,guest?'anon':'authenticated');
    const join=c=>guest?scalar(c,'SELECT public.join_poll_as_guest($1,$2,NULL,$3) AS result',[poll,'Guest',token]):scalar(c,'SELECT public.join_poll($1) AS result',[poll]);
    const {won,outcome}=await race(()=>join(first),()=>join(second));assert.equal(outcome.result.created,false);
    assert.equal(won.participant.id,outcome.result.participant.id);
  });
  for(const creationFirst of [false,true])await t.test(`${creationFirst?'creation':'reactivation'} serializes before competing ${creationFirst?'reactivation':'creation'}`,async()=>{
    const id=await user();await role(first,id);const prior=await create(first);
    await admin.query("UPDATE public.polls SET status='closed' WHERE id=$1",[prior.poll.id]);
    await role(second,id);const reopen=c=>c.query("UPDATE public.polls SET status='active' WHERE id=$1",[prior.poll.id]);
    await race(()=>creationFirst?create(first):reopen(first),()=>creationFirst?reopen(second):create(second),'P0001');
    assert.equal(await scalar(admin,"SELECT count(*)::int AS result FROM public.polls WHERE creator_id=$1 AND status IN ('draft','active')",[id]),1);
  });
  await t.test('direct option additions serialize at 500-option boundary',async()=>{
    const id=await user();await role(first,id);const r=await create(first);
    await admin.query(`INSERT INTO public.poll_time_options(poll_id,start_time,end_time)
      SELECT $1,'2027-12-01T12:00Z'::timestamptz+g*interval '1 day','2027-12-01T13:00Z'::timestamptz+g*interval '1 day'
      FROM generate_series(1,497) g`,[r.poll.id]);
    await role(second,id);const add=c=>c.query("INSERT INTO public.poll_time_options(poll_id,start_time,end_time) VALUES($1,'2030-01-01T12:00Z','2030-01-01T13:00Z')",[r.poll.id]);
    await race(()=>add(first),()=>add(second),'22023');
    assert.equal(await scalar(admin,'SELECT count(*)::int AS result FROM public.poll_time_options WHERE poll_id=$1',[r.poll.id]),500);
  });
  console.log(`Observed ${waits} independent-session PostgreSQL Lock waits.`);
});
