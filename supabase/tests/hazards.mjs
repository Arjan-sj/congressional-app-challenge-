import pg from 'pg';
import { readFile } from 'node:fs/promises';
import { configuration, HazardWorkflow, StorageApi } from './hazard-workflow.mjs';

const [command='preview',...args]=process.argv.slice(2);
const value = name => { const i=args.indexOf(name); return i<0 ? undefined : args[i+1]; };
let db;
try {
  if (!['preview','reset','seed'].includes(command) || args.some((arg,i)=>
    arg.startsWith('--') && !['--execute','--dry-run','--confirm-project','--backup'].includes(arg))) {
    throw new Error('Usage: hazards.mjs preview|reset|seed [--dry-run|--execute --confirm-project ID --backup PATH]');
  }
  if (args.includes('--execute') && args.includes('--dry-run')) throw new Error('Choose execute or dry-run, not both.');
  const config=configuration(process.env);
  // TLS validates the hosted database certificate. Local loopback is explicit.
  const dbUrl=new URL(config.databaseUrl);
  for (const key of ['sslmode','sslcert','sslkey','sslrootcert']) dbUrl.searchParams.delete(key);
  db=new pg.Client({connectionString:dbUrl.toString(),connectionTimeoutMillis:10000,
    ssl:config.environment==='local' ? false : {rejectUnauthorized:true,
      ...(process.env.SAFEROUTES_DATABASE_CA_FILE ? {ca:await readFile(process.env.SAFEROUTES_DATABASE_CA_FILE,'utf8')} : {})}});
  await db.connect();
  const workflow=new HazardWorkflow(db,new StorageApi(config),config);
  const options={execute:args.includes('--execute'),confirmProject:value('--confirm-project'),backupPath:value('--backup'),
    schoolIds:process.env.SAFEROUTES_SEED_SCHOOL_IDS?.split(',').map(s=>s.trim()),
    reporterId:process.env.SAFEROUTES_TEST_REPORTER_ID,moderatorId:process.env.SAFEROUTES_TEST_MODERATOR_ID};
  const result=command==='preview' ? await workflow.preview() : await workflow[command](options);
  console.log(JSON.stringify(result,null,2));
} catch(error) {
  // Do not echo credentials, server error details, or raw report/photo data.
  console.error(error.code ? `Database workflow stopped (${error.code}). Check the private operator connection and active run.` : error.message);
  process.exitCode=1;
} finally { if(db) await db.end(); }
