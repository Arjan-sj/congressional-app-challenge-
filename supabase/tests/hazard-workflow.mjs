// Trusted operator code. No secrets are embedded or passed as command arguments.
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

export const PRODUCTION_PROJECT = 'bnvmlxgdqgwjtxgtsaak';
export const fixturePhoto = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const canonical = value => Array.isArray(value) ? value.map(canonical) :
  value !== null && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])) : value;
const equal = (a,b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
const requireValue = (value, message) => { if (!value) throw new Error(message); };

export function configuration(env) {
  const environment = env.SAFEROUTES_ENVIRONMENT;
  const projectId = env.SAFEROUTES_PROJECT_ID;
  requireValue(['production','staging','local'].includes(environment), 'Set an explicit production, staging, or local environment.');
  requireValue(projectId, 'SAFEROUTES_PROJECT_ID is required.');
  const url = new URL(env.SUPABASE_URL);
  const databaseUrl = new URL(env.SAFEROUTES_DATABASE_URL);
  const loopback = host => ['localhost','127.0.0.1','[::1]'].includes(host);
  requireValue(!url.username && !url.password && !url.search && !url.hash && ['', '/'].includes(url.pathname), 'Invalid Supabase API origin.');
  if (environment === 'local') {
    requireValue(projectId === 'local' && loopback(url.hostname) && loopback(databaseUrl.hostname) && ['http:','https:'].includes(url.protocol), 'Local mode requires loopback API and database hosts and project ID local.');
  } else {
    requireValue(/^[a-z]{20}$/.test(projectId) && url.protocol === 'https:' && url.hostname === `${projectId}.supabase.co`, 'API host must match the exact Supabase project ID.');
    const direct = databaseUrl.hostname === `db.${projectId}.supabase.co`;
    const pooler = databaseUrl.hostname.endsWith('.pooler.supabase.com') && decodeURIComponent(databaseUrl.username) === `postgres.${projectId}`;
    requireValue(direct || pooler, 'Database host/user does not match the API project.');
    requireValue(!pooler || databaseUrl.port === '5432', 'Use Supavisor session pooling on port 5432, not transaction pooling.');
  }
  requireValue(['postgres:','postgresql:'].includes(databaseUrl.protocol), 'Use a Postgres connection URL.');
  return {environment, projectId, url: url.origin, databaseUrl: databaseUrl.toString(), serviceKey: env.SUPABASE_SERVICE_ROLE_KEY};
}

export function assertWritable(config, preview, confirmation) {
  requireValue(config.environment !== 'production' && config.projectId !== PRODUCTION_PROJECT, 'Production writes are prohibited.');
  requireValue(confirmation === config.projectId, 'Explicit --confirm-project must exactly match the target project ID.');
  requireValue(preview.environment === config.environment && preview.project_id === config.projectId && !preview.production_protected, 'Database environment enrollment does not match this configuration.');
  requireValue(Object.values(preview.unsafe_records).every(rows => rows.length === 0), 'Unsafe/unregistered records or dependencies block this operation. Review the preview.');
}

export class StorageApi {
  constructor(config, request = fetch) { this.config = config; this.request = request; }
  async call(method, path, body, contentType = 'application/json', extraHeaders={}) {
    if (method !== 'GET') {
      requireValue(['staging','local'].includes(this.config.environment) && this.config.projectId !== PRODUCTION_PROJECT, 'Production Storage writes are prohibited.');
    }
    requireValue(this.config.serviceKey, 'Operator-only SUPABASE_SERVICE_ROLE_KEY is required for Storage.');
    const response = await this.request(`${this.config.url}/storage/v1/${path}`, {
      method, redirect: 'error', signal: AbortSignal.timeout(30000),
      headers: {apikey: this.config.serviceKey, Authorization: `Bearer ${this.config.serviceKey}`, 'Content-Type': contentType,...extraHeaders},
      body,
    });
    // Never include server bodies, tokens, or credential-bearing URLs in errors.
    requireValue(response.ok, `Storage ${method} failed (${response.status}); reports have not been deleted. Resume the active operation.`);
    return response;
  }
  objectPath(name) { return `object/authenticated/hazard-photos/${name.split('/').map(encodeURIComponent).join('/')}`; }
  async download(name) { return Buffer.from(await (await this.call('GET',this.objectPath(name))).arrayBuffer()); }
  async remove(names) {
    for (let i=0;i<names.length;i+=100) {
      await this.call('DELETE','object/hazard-photos',JSON.stringify({prefixes:names.slice(i,i+100)}));
    }
  }
  async upload(name, bytes) {
    await this.call('POST',`object/hazard-photos/${name.split('/').map(encodeURIComponent).join('/')}`,bytes,'image/png',{'x-upsert':'true'});
  }
}

export class HazardWorkflow {
  constructor(db, storage, config) { this.db=db; this.storage=storage; this.config=config; }
  async scalar(sql, values=[]) { return (await this.db.query(sql,values)).rows[0].value; }
  async preview() {
    const data = await this.scalar('select private.hazard_reset_preview() value');
    requireValue(data.project_id === this.config.projectId && data.environment === this.config.environment, 'Database enrollment does not match project/environment; writes remain disabled.');
    return {...data,dry_run:true};
  }
  async transaction(action) {
    await this.db.query('begin');
    try { const result=await action(); await this.db.query('commit'); return result; }
    catch(error) { await this.db.query('rollback'); throw error; }
  }
  async lock(action) {
    const acquired = await this.scalar('select pg_try_advisory_lock(6145130301) value');
    requireValue(acquired,'Another hazard test workflow is active.');
    try { return await action(); }
    finally { await this.db.query('select pg_advisory_unlock(6145130301)'); }
  }
  async begin(kind) {
    return this.transaction(() => this.scalar('select private.begin_hazard_test_run($1,$2) value',[this.config.projectId,kind]));
  }
  async snapshot() { return this.scalar('select private.hazard_test_snapshot() value'); }
  async run(id) { return (await this.db.query('select * from private.hazard_test_runs where id=$1',[id])).rows[0]; }

  async reset({execute=false,confirmProject,backupPath}={}) {
    const preview = await this.preview();
    if (!execute) return preview;
    assertWritable(this.config,preview,confirmProject);
    requireValue(backupPath,'An explicit --backup path is required.');
    return this.lock(async () => {
      const fresh = await this.preview(); assertWritable(this.config,fresh,confirmProject);
      if (!fresh.active_run && Object.values(fresh.counts).every(n=>Number(n)===0)) return {...fresh,already_empty:true};
      const runId=await this.begin('reset');
      const run=await this.run(runId);
      let archive, archiveBytes;
      if (run.backup_sha256) {
        archiveBytes=await readFile(backupPath);
        requireValue(sha256(archiveBytes)===run.backup_sha256,'Backup file does not match the active reset. No further deletions attempted.');
        archive=JSON.parse(archiveBytes.toString('utf8'));
      } else {
        const snapshot=await this.snapshot();
        const files=[];
        for (const object of snapshot.objects) {
          const bytes=await this.storage.download(object.name);
          files.push({name:object.name,sha256:sha256(bytes),base64:bytes.toString('base64')});
        }
        archive={format:'saferoutes-hazard-backup-v1',project_id:this.config.projectId,environment:this.config.environment,
          run_id:runId,created_at:new Date().toISOString(),protected_snapshot:run.protected_snapshot,snapshot,files};
        archiveBytes=Buffer.from(JSON.stringify(archive,null,2));
        await mkdir(dirname(backupPath),{recursive:true,mode:0o700});
        // Exclusive creation prevents replacing a previous recovery archive.
        await writeFile(backupPath,archiveBytes,{flag:'wx',mode:0o600,flush:true});
        requireValue(sha256(await readFile(backupPath))===sha256(archiveBytes),'Backup write verification failed.');
        await this.db.query('update private.hazard_test_runs set backup_sha256=$1 where id=$2',[sha256(archiveBytes),runId]);
      }
      requireValue(archive.run_id===runId && archive.project_id===this.config.projectId,'Backup identity mismatch.');
      for (const file of archive.files) requireValue(sha256(Buffer.from(file.base64,'base64'))===file.sha256,'Photo backup checksum mismatch.');
      const current=await this.snapshot();
      for (const key of Object.keys(current).filter(k=>k!=='objects')) {
        requireValue(equal(current[key],archive.snapshot[key]),'Hazard records changed after backup; reset stopped.');
      }
      requireValue(current.objects.every(o=>archive.snapshot.objects.some(saved=>equal(saved,o))),'Storage inventory changed after backup; reset stopped.');
      requireValue(current.objects.every(o=>archive.files.some(f=>f.name===o.name)),'An object is missing from the backup.');
      requireValue(equal(await this.scalar('select private.hazard_test_preserved_state() value'),archive.protected_snapshot),'Protected data changed; reset stopped.');
      await this.storage.remove(current.objects.map(o=>o.name));
      // The existing orphan-prevention trigger independently enforces API-first cleanup.
      const result=await this.transaction(() => this.scalar('select private.finish_hazard_test_reset($1,$2,$3) value',
        [this.config.projectId,runId,sha256(archiveBytes)]));
      return {...result,dry_run:false,backup:backupPath,backup_sha256:sha256(archiveBytes)};
    });
  }

  async seed({execute=false,confirmProject,schoolIds,reporterId,moderatorId}={}) {
    const preview=await this.preview();
    if (!execute) return {...preview,seed_plan:{version:'phase1-v1',reports:6,photos:1,schools:schoolIds}};
    assertWritable(this.config,preview,confirmProject);
    requireValue(Array.isArray(schoolIds) && schoolIds.length===2 && reporterId && moderatorId,'Set two school IDs and existing staging author/moderator user IDs.');
    return this.lock(async () => {
      const fresh=await this.preview(); assertWritable(this.config,fresh,confirmProject);
      const args={schools:schoolIds,reporter:reporterId,moderator:moderatorId};
      if (!fresh.active_run && Number(fresh.counts.hazard_reports)>0) {
        const latest=(await this.db.query("select * from private.hazard_test_runs where kind='seed' and state='complete' order by started_at desc,id desc limit 1")).rows[0];
        const current=await this.snapshot();
        requireValue(latest && equal(latest.details.seed_args,args) && equal(latest.details.seed_snapshot,current), 'Existing fixtures differ from the completed seed. Reset before reseeding.');
        const bytes=await this.storage.download('50000000-0000-0000-0000-000000000006/1.png');
        requireValue(sha256(bytes)===sha256(fixturePhoto),'Fixture photo changed. Reset before reseeding.');
        return {...fresh,already_seeded:true};
      }
      const runId=await this.begin('seed');
      await this.transaction(() => this.scalar('select private.seed_hazard_test_reports($1,$2,$3,$4,$5) value',
        [this.config.projectId,runId,schoolIds,reporterId,moderatorId]));
      const path='50000000-0000-0000-0000-000000000006/1.png';
      // Idempotently repair this active run's known synthetic image, including
      // a previous upload that committed metadata but lost its HTTP response.
      await this.storage.upload(path,fixturePhoto);
      requireValue(sha256(await this.storage.download(path))===sha256(fixturePhoto),'Seeded photo failed verification; resume the seed.');
      const completeSnapshot=await this.snapshot();
      requireValue(completeSnapshot.reports.length===6 && completeSnapshot.photos.length===1 && completeSnapshot.objects.length===1 &&
        completeSnapshot.history.length===4 && completeSnapshot.flags.length===1 && completeSnapshot.fixtures.length===6,'Seed verification failed.');
      await this.transaction(async () => {
        await this.db.query("update private.hazard_test_runs set details=details || jsonb_build_object('seed_snapshot',$1::jsonb) where id=$2",[JSON.stringify(completeSnapshot),runId]);
        await this.scalar('select private.complete_hazard_test_run($1,$2) value',[this.config.projectId,runId]);
      });
      return {...await this.preview(),dry_run:false};
    });
  }
}
