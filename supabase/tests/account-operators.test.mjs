import test from 'node:test';
import assert from 'node:assert/strict';
import {run} from '../../scripts/manage_moderators.mjs';
import {bootstrap} from '../../scripts/bootstrap_development_admin.mjs';
const project='abcdefghijklmnopqrst',id='92000000-0000-0000-0000-000000000001';
const env={SAFEROUTES_ENVIRONMENT:'staging',SAFEROUTES_PROJECT_ID:project,SUPABASE_URL:`https://${project}.supabase.co`,
  SUPABASE_SERVICE_ROLE_KEY:'sb_secret_synthetic_operator_key',SAFEROUTES_ALLOW_ADMIN_BOOTSTRAP:'yes'};
const review=['applications','approve','--request-id',id,'--expected-email','authorized@example.test','--operator','Synthetic operator','--reason','Reviewed applicant identity'];
test('application approval uses the existing trusted CLI and is preview-only by default',async()=>{
  let payload;const response=await run(review,env,async(url,options)=>{
    assert(url.endsWith('/admin_moderator_applications'));payload=JSON.parse(options.body);
    return Response.json({application:{user_id:id},identity:{user:{email:'authorized@example.test'}}});
  });assert.equal(payload.p_action,'check');assert.equal(response.dry_run,true);
});
test('application mutations require exact project, identity confirmation and operator details',async()=>{
  let calls=0;const no=()=>{calls++;throw Error('No network expected');};
  await assert.rejects(run([...review,'--apply'],env,no),/Confirm/);
  await assert.rejects(run([...review,'--apply','--confirm-project','wrong'],env,no),/Confirm/);
  await assert.rejects(run(['applications','approve','--request-id',id],env,no),/email/);
  assert.equal(calls,0);
  const result=await run([...review,'--apply','--confirm-project',project],env,async(_,options)=>{
    assert.equal(JSON.parse(options.body).p_action,'approve');return Response.json({changed:true});});
  assert.equal(result.changed,true);
});
test('bootstrap refuses production, missing authorization and missing/weak passwords before creating users',async()=>{
  const args=['--email','authorized@example.test','--operator','Synthetic operator'];let writes=0;
  const api=async(url)=>{if(url.endsWith('bootstrap_account_exists'))return Response.json(false);
    if(url.endsWith('admin_report_moderators'))return Response.json({user:null});writes++;throw Error('Unexpected write');};
  await assert.rejects(bootstrap(args,{...env,SAFEROUTES_ENVIRONMENT:'production'},api),/refuses production/);
  await assert.rejects(bootstrap(args,{...env,SAFEROUTES_ALLOW_ADMIN_BOOTSTRAP:''},api),/Explicitly/);
  await assert.rejects(bootstrap([...args,'--apply','--confirm-project',project],env,api),/PASSWORD/);
  await assert.rejects(bootstrap([...args,'--apply','--confirm-project',project],{...env,SAFEROUTES_BOOTSTRAP_PASSWORD:'weak'},api),/PASSWORD/);
  assert.equal(writes,0);
});
test('bootstrap never overwrites a reserved identity or existing Auth email',async()=>{
  const args=['--email','authorized@example.test','--operator','Synthetic operator'];
  await assert.rejects(bootstrap(args,env,async()=>Response.json(true)),/already exists/);
  await assert.rejects(bootstrap(args,env,async(url)=>url.endsWith('bootstrap_account_exists')?Response.json(false):Response.json({user:{id}})),/never overwrites/);
});
test('explicit local/staging bootstrap uses an operator secret and existing grant RPC without logging credentials',async()=>{
  const password='Q'.repeat(14)+'x7';let created=false,granted=false;
  const result=await bootstrap(['--email','authorized@example.test','--operator','Synthetic operator','--apply','--confirm-project',project],
    {...env,SAFEROUTES_BOOTSTRAP_PASSWORD:password},async(url,options)=>{
      const p=JSON.parse(options.body);
      if(url.endsWith('bootstrap_account_exists'))return Response.json(false);
      if(url.endsWith('/auth/v1/admin/users')){created=true;assert.equal(p.password,password);
        assert.equal(p.app_metadata.must_change_password,true);assert.equal(p.user_metadata.username,'adminModerator');
        return Response.json({id,email:'authorized@example.test',email_confirmed_at:'2026-01-01'});}
      assert(url.endsWith('admin_report_moderators'));
      if(p.p_action==='lookup')return Response.json({user:null});
      assert.equal(p.p_action,'grant');assert.equal(p.p_user_id,id);granted=true;return Response.json({changed:true});
    });
  assert(created&&granted);assert.equal(result.requires_password_change,true);
  assert(!JSON.stringify(result).includes(password));assert(!JSON.stringify(result).includes(env.SUPABASE_SERVICE_ROLE_KEY));
});
