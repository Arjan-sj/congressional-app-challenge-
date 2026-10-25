import test from 'node:test';
import assert from 'node:assert/strict';
import { argumentsFor, configuration, run } from '../../scripts/manage_moderators.mjs';
import { createDatabase } from './database.mjs';

const project='abcdefghijklmnopqrst', id='51000000-0000-0000-0000-000000000001';
const env={SAFEROUTES_ENVIRONMENT:'staging',SAFEROUTES_PROJECT_ID:project,SUPABASE_URL:`https://${project}.supabase.co`,SUPABASE_SERVICE_ROLE_KEY:'sb_secret_synthetic_operator_key'};
const grant=['grant','--user-id',id,'--expected-email','synthetic@example.test','--operator','Synthetic test admin','--reason','Reviewed synthetic account membership'];

test('operator configuration rejects wrong projects, public keys and credential-bearing origins',()=>{
  for(const bad of [
    {...env,SUPABASE_URL:'https://wrong.supabase.co'},
    {...env,SUPABASE_SERVICE_ROLE_KEY:'sb_publishable_public'},
    {...env,SUPABASE_URL:`https://user:password@${project}.supabase.co`},
    {...env,SAFEROUTES_ENVIRONMENT:'local'},
    {...env,SAFEROUTES_ENVIRONMENT:'staging',SAFEROUTES_PROJECT_ID:'bnvmlxgdqgwjtxgtsaak',SUPABASE_URL:'https://bnvmlxgdqgwjtxgtsaak.supabase.co'},
  ])assert.throws(()=>configuration(bad));
  assert.equal(configuration(env).projectId,project);
});
test('exact UUIDs, identity confirmation, operator and reasons are required',()=>{
  assert.throws(()=>argumentsFor(['grant','--user-id',id]));
  assert.throws(()=>argumentsFor(['grant','--user-id','email@example.test']));
  assert.throws(()=>argumentsFor(['lookup','--user-id',id,'--email','synthetic@example.test']));
  assert.throws(()=>argumentsFor(['list','--apply']));
  assert.throws(()=>argumentsFor(['list','--service-role-key','secret']));
  assert.equal(argumentsFor(grant).action,'grant');
});
test('writes require explicit matching project confirmation before any network call',async()=>{
  let calls=0;const noNetwork=()=>{calls++;throw new Error('Unexpected request');};
  await assert.rejects(run([...grant,'--apply'],env,noNetwork),/confirm-project/);
  await assert.rejects(run([...grant,'--apply','--confirm-project','other'],env,noNetwork),/confirm-project/);
  assert.equal(calls,0);
});
test('failed API bodies and credentials do not leak into operator errors',async()=>{
  await assert.rejects(run(['list'],env,async()=>new Response(env.SUPABASE_SERVICE_ROLE_KEY,{status:403})),error=>
    error.message.includes('HTTP 403')&&!error.message.includes(env.SUPABASE_SERVICE_ROLE_KEY));
});
test('trusted workflow integrates with migrated database without invitations or duplicate grants',async t=>{
  const db=await createDatabase();
  try{
    await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[id,'synthetic@example.test']);
    const rpc=async(url,options)=>{
      assert.equal(url,`${env.SUPABASE_URL}/rest/v1/rpc/admin_report_moderators`);
      assert.equal(options.redirect,'error');const p=JSON.parse(options.body);
      await db.exec('set role service_role');
      try{
        const result=await db.query('select public.admin_report_moderators($1,$2,$3,$4,$5,$6,$7,$8) as result',
          [p.p_action,p.p_user_id??null,p.p_email??null,p.p_expected_email??null,p.p_operator??null,p.p_reason??null,p.p_after_id??null,p.p_limit]);
        return Response.json(result.rows[0].result);
      }finally{await db.exec('reset role');}
    };
    await t.test('lookup and dry-run grant are read-only',async()=>{
      const lookup=await run(['lookup','--email','SYNTHETIC@example.test'],env,rpc);assert.equal(lookup.user.id,id);
      const preview=await run(grant,env,rpc);assert.equal(preview.dry_run,true);assert.equal(preview.is_moderator,false);
      assert.equal((await db.query('select count(*)::int n from public.report_moderators')).rows[0].n,0);
      assert.equal((await db.query('select count(*)::int n from private.moderator_membership_history')).rows[0].n,0);
      await assert.rejects(run(grant.map(x=>x==='synthetic@example.test'?'wrong@example.test':x),env,rpc),/identity/);
    });
    await t.test('reviewed grant and repeat grant preserve one membership/audit record',async()=>{
      const args=[...grant,'--apply','--confirm-project',project];
      assert.equal((await run(args,env,rpc)).changed,true);assert.equal((await run(args,env,rpc)).changed,false);
      const listed=await run(['list'],env,rpc);assert.equal(listed.items.length,1);assert.equal(listed.items[0].user_id,id);
      assert.equal((await run(['check','--user-id',id],env,rpc)).is_moderator,true);
      assert.ok(!JSON.stringify(listed).includes(env.SUPABASE_SERVICE_ROLE_KEY));
    });
    await t.test('reviewed revoke is idempotent and preserves private history',async()=>{
      const args=['revoke',...grant.slice(1),'--apply','--confirm-project',project];
      assert.equal((await run(args,env,rpc)).changed,true);assert.equal((await run(args,env,rpc)).changed,false);
      assert.equal((await run(['check','--user-id',id],env,rpc)).is_moderator,false);
      assert.equal((await db.query('select count(*)::int n from private.moderator_membership_history')).rows[0].n,2);
    });
  }finally{await db.close();}
});
