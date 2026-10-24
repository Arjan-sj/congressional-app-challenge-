import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDatabase } from './database.mjs';
import { configuration, HazardWorkflow, StorageApi, PRODUCTION_PROJECT, fixturePhoto, sha256 } from './hazard-workflow.mjs';

const project='abcdefghijklmnopqrst';
const config={environment:'staging',projectId:project,url:`https://${project}.supabase.co`,serviceKey:'test-only-secret'};
const author='10000000-0000-0000-0000-000000000001';
const moderator='10000000-0000-0000-0000-000000000003';
const seeded={execute:true,confirmProject:project,schoolIds:['test-A','test-B'],reporterId:author,moderatorId:moderator};

test('configuration blocks production substitution, wrong projects, and remote local mode', () => {
  const valid={SAFEROUTES_ENVIRONMENT:'staging',SAFEROUTES_PROJECT_ID:project,
    SUPABASE_URL:`https://${project}.supabase.co`,SAFEROUTES_DATABASE_URL:`postgresql://postgres:password@db.${project}.supabase.co/postgres`};
  assert.equal(configuration(valid).projectId,project);
  assert.throws(()=>configuration({...valid,SUPABASE_URL:`https://${PRODUCTION_PROJECT}.supabase.co`}),/match/);
  assert.throws(()=>configuration({...valid,SAFEROUTES_DATABASE_URL:`postgresql://postgres:password@db.${PRODUCTION_PROJECT}.supabase.co/postgres`}),/match/);
  assert.throws(()=>configuration({...valid,SAFEROUTES_ENVIRONMENT:'local'}),/loopback/);
  assert.throws(()=>configuration({...valid,SAFEROUTES_DATABASE_URL:`postgresql://postgres.${project}:password@aws-0-us-east-1.pooler.supabase.com:6543/postgres`}),/session pooling/);
});

test('disposable staging seed/reset integration with Storage API simulation', async t => {
  const db=await createDatabase();
  const directory=await mkdtemp(join(tmpdir(),'saferoutes-workflow-'));
  const files=new Map(); const requests=[];
  let failUpload=false, failDelete=false, failAfterUpload=false;
  const scalar=async(sql,args=[]) => (await db.query(sql,args)).rows[0].value;
  // Emulate a separate Storage service session; SQL here belongs only to the
  // in-memory test double, never to the operator's Storage cleanup implementation.
  const api=async(url,options) => {
    requests.push({url,method:options.method});
    const path=decodeURIComponent(new URL(url).pathname.replace(/^\/storage\/v1\/object\/(?:authenticated\/)?hazard-photos\/?/,''));
    const previous=await scalar("select current_setting('saferoutes.hazard_test_run',true) value");
    await db.query("select set_config('saferoutes.hazard_test_run','',false)");
    try {
      if(options.method==='GET') return files.has(path) ? new Response(files.get(path)) : new Response('',{status:404});
      if(options.method==='POST') {
        if(failUpload) return new Response('',{status:503});
        assert.equal(options.headers['x-upsert'],'true');
        if(await scalar("select exists(select from storage.objects where bucket_id='hazard-photos' and name=$1) value",[path])) {
          await db.query("update storage.objects set owner_id=$2 where bucket_id='hazard-photos' and name=$1",[path,author]);
        } else {
          await db.query("insert into storage.objects(bucket_id,name,owner_id) values('hazard-photos',$1,$2)",[path,author]);
        }
        files.set(path,Buffer.from(options.body));
        return failAfterUpload ? new Response('',{status:503}) : new Response('{}');
      }
      if(options.method==='DELETE') {
        for(const name of JSON.parse(options.body).prefixes) {
          await db.query("delete from storage.objects where bucket_id='hazard-photos' and name=$1",[name]); files.delete(name);
          if(failDelete) return new Response('',{status:503});
        }
        return new Response('[]');
      }
      throw new Error('Unexpected Storage method');
    } finally { await db.query("select set_config('saferoutes.hazard_test_run',$1,false)",[previous??'']); }
  };
  const workflow=new HazardWorkflow(db,new StorageApi(config,api),config);
  try {
    await t.test('production previews accurately but cannot reset or seed',async()=>{
      const prod=new HazardWorkflow(db,new StorageApi({...config,projectId:PRODUCTION_PROJECT},api),
        {...config,environment:'production',projectId:PRODUCTION_PROJECT});
      assert.equal((await prod.preview()).production_protected,true);
      await assert.rejects(prod.reset({execute:true,confirmProject:PRODUCTION_PROJECT,backupPath:join(directory,'never.json')}),/Production/);
      await assert.rejects(prod.seed({...seeded,confirmProject:PRODUCTION_PROJECT}),/Production/);
      await assert.rejects(new StorageApi({...config,environment:'production',projectId:PRODUCTION_PROJECT},api).remove(['anything.png']),/Production/);
      await assert.rejects(db.query("update private.hazard_test_control set environment='staging'"),/check constraint/);
      assert.equal(requests.length,0);
      await db.exec(`set role authenticated;`);
      await assert.rejects(db.query('select private.hazard_reset_preview()'),/permission denied/);
      await db.exec('reset role;');
    });
    await db.query("update private.hazard_test_control set environment='staging',project_id=$1",[project]);
    await db.exec(`
      insert into public.schools(id,name,latitude,longitude) values ('test-A','Test School A',-60,0),('test-B','Test School B',-60,1);
      insert into auth.users(id) values ('${author}'),('${moderator}');
      insert into public.report_moderators(user_id) values ('${moderator}');
      insert into public.map_infrastructure values('fixture-sidewalk','123','sidewalk',extensions.st_geomfromtext('LINESTRING(0 -60,0.01 -60)',4326),'{}','fixture',now(),now());
    `);
    const protectedBefore=await scalar('select private.hazard_test_preserved_state() value');
    await t.test('real, orphan and unexpected dependent records fail closed before Storage writes',async()=>{
      await db.exec(`insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,reporter_id)
        values('20000000-0000-0000-0000-000000000001','test-A',-60,0,'blocked_path',3,'Simulated real report in disposable test','${author}');`);
      const preview=await workflow.preview(); assert.equal(preview.counts.hazard_reports,1);
      assert.equal(preview.unsafe_records.non_synthetic_reports.length,1);
      await assert.rejects(workflow.reset({execute:true,confirmProject:project,backupPath:join(directory,'unsafe.json')}),/Unsafe/);
      await db.query("delete from public.hazard_reports where id='20000000-0000-0000-0000-000000000001'");
      await db.query("insert into storage.objects(bucket_id,name) values('hazard-photos','orphan.png')");
      assert.deepEqual((await workflow.preview()).unsafe_records.orphan_storage_objects,['orphan.png']);
      await assert.rejects(workflow.reset({execute:true,confirmProject:project,backupPath:join(directory,'unsafe.json')}),/Unsafe/);
      await db.query("delete from storage.objects where name='orphan.png'");
      await db.exec('create table public.unexpected_dependency(report_id uuid references public.hazard_reports(id) on delete cascade)');
      assert.equal((await workflow.preview()).unsafe_records.unknown_foreign_keys.length,1);
      await assert.rejects(workflow.seed(seeded),/Unsafe/);
      await db.exec('drop table public.unexpected_dependency');
      await db.exec('create table public.unexpected_flag_dependency(flag_id uuid references public.report_flags(id) on delete cascade)');
      assert.equal((await workflow.preview()).unsafe_records.unknown_foreign_keys.length,1);
      await assert.rejects(workflow.seed(seeded),/Unsafe/);
      await db.exec('drop table public.unexpected_flag_dependency');
      await db.query("insert into private.report_school_corrections values('20000000-0000-0000-0000-000000000099','test-A','test-B','test operator','Synthetic orphan correction test',now())");
      assert.equal((await workflow.preview()).unsafe_records.orphan_corrections.length,1);
      await assert.rejects(workflow.seed(seeded),/Unsafe/);
      await db.query("delete from private.report_school_corrections where report_id='20000000-0000-0000-0000-000000000099'");
      assert.equal(requests.length,0);
    });
    await t.test('seed dry-run is read-only; failed uploads resume without duplicate reports',async()=>{
      await workflow.seed({...seeded,execute:false}); assert.equal((await workflow.preview()).counts.hazard_reports,0);
      failUpload=true; await assert.rejects(workflow.seed(seeded),/Storage POST/);
      assert.equal((await workflow.preview()).counts.hazard_reports,6);
      assert.ok((await workflow.preview()).active_run);
      failUpload=false; failAfterUpload=true;
      await assert.rejects(workflow.seed(seeded),/Storage POST/);
      assert.equal((await workflow.preview()).counts.storage_objects,1);
      failAfterUpload=false; const seededPreview=await workflow.seed(seeded);
      assert.deepEqual(seededPreview.counts,{hazard_reports:6,demo_reports:6,registered_synthetic:6,photo_metadata:1,storage_objects:1,report_flags:1,moderation_history:4,correction_records:0});
      const snapshot=await workflow.snapshot();
      assert.equal(snapshot.reports.filter(r=>r.status==='unverified').length,2);
      assert.equal(snapshot.reports.filter(r=>r.status==='verified').length,3);
      assert.equal(snapshot.reports.filter(r=>r.status==='resolved').length,1);
      assert.equal(snapshot.reports[0].latitude,snapshot.reports[1].latitude);
      assert.equal(snapshot.reports[0].school_id,snapshot.reports[1].school_id);
      assert.ok(snapshot.reports.every(r=>r.is_demo && r.description.startsWith('[SYNTHETIC phase1-v1]')));
      assert.equal(sha256(files.values().next().value),sha256(fixturePhoto));
      assert.equal((await workflow.seed(seeded)).already_seeded,true);
      assert.deepEqual(await scalar('select private.hazard_test_preserved_state() value'),protectedBefore);
    });
    await t.test('reset requires confirmation and backup; API failure preserves reports and resumes safely',async()=>{
      await assert.rejects(workflow.reset({execute:true,confirmProject:'wrong',backupPath:join(directory,'backup.json')}),/confirm-project/);
      await assert.rejects(workflow.reset({execute:true,confirmProject:project}),/backup/);
      await db.query("insert into private.report_school_corrections(report_id,previous_school_id,school_id,reviewed_by,reason) values('50000000-0000-0000-0000-000000000001','test-B','test-A','synthetic tester','[SYNTHETIC phase1-v1] Test correction dependency')");
      assert.equal((await workflow.preview()).counts.correction_records,1);
      const options={execute:true,confirmProject:project,backupPath:join(directory,'backup.json')};
      const dry=await workflow.reset(); assert.equal(dry.dry_run,true); assert.equal(dry.counts.hazard_reports,6);
      const path='50000000-0000-0000-0000-000000000006/1.png';
      const deletesBefore=requests.filter(r=>r.method==='DELETE').length;
      files.delete(path);
      await assert.rejects(workflow.reset(options),/Storage GET/);
      assert.equal((await workflow.preview()).counts.hazard_reports,6);
      assert.equal(requests.filter(r=>r.method==='DELETE').length,deletesBefore);
      files.set(path,fixturePhoto);
      failDelete=true; await assert.rejects(workflow.reset(options),/Storage DELETE/);
      const preview=await workflow.preview(); assert.equal(preview.counts.hazard_reports,6); assert.ok(preview.active_run);
      const backupBytes=await readFile(options.backupPath);
      const backup=JSON.parse(backupBytes); assert.equal(backup.snapshot.reports.length,6); assert.equal(backup.snapshot.corrections.length,1);
      assert.equal(backup.files[0].sha256,sha256(fixturePhoto));
      // An unrelated session cannot write while the persistent gate is active.
      const runId=preview.active_run; await db.query("select set_config('saferoutes.hazard_test_run','',false)");
      await assert.rejects(db.query("update public.hazard_reports set description='Changed during backup'"),/maintenance/);
      await db.query("select set_config('saferoutes.hazard_test_run',$1,false)",[runId]);
      await writeFile(options.backupPath,'tampered');
      await assert.rejects(workflow.reset(options),/Backup file/);
      assert.equal((await workflow.preview()).counts.hazard_reports,6);
      await writeFile(options.backupPath,backupBytes); failDelete=false;
      const result=await workflow.reset(options);
      assert.ok(Object.values(result.counts).every(n=>n===0)); assert.equal(result.active_run,null); assert.equal(files.size,0);
      assert.deepEqual(await scalar('select private.hazard_test_preserved_state() value'),protectedBefore);
      assert.equal((await workflow.reset(options)).already_empty,true);
    });
    await t.test('seed/reset can repeat while preserving users, schools, infrastructure and migrations',async()=>{
      await workflow.seed(seeded);
      const reset=await workflow.reset({execute:true,confirmProject:project,backupPath:join(directory,'second.json')});
      assert.equal(reset.counts.hazard_reports,0);
      assert.deepEqual(await scalar('select private.hazard_test_preserved_state() value'),protectedBefore);
      assert.ok(requests.some(r=>r.method==='DELETE'&&r.url.endsWith('/storage/v1/object/hazard-photos')));
      assert.equal(await scalar("select count(*)::int value from private.hazard_test_runs where state='complete'"),4);
    });
  } finally { await db.close(); await rm(directory,{recursive:true,force:true}); }
});
