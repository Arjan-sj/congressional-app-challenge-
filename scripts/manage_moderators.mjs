// Trusted operator terminal only. Never import this file into Flutter/web code.
import { pathToFileURL } from 'node:url';

const productionProject = 'bnvmlxgdqgwjtxgtsaak';
const uuid = value => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value ?? '');
const requireValue = (value,message) => {if (!value) throw new Error(message);};

export function configuration(env) {
  const projectId=env.SAFEROUTES_PROJECT_ID, environment=env.SAFEROUTES_ENVIRONMENT;
  requireValue(['local','staging','production'].includes(environment),'Set SAFEROUTES_ENVIRONMENT explicitly.');
  const url=new URL(env.SUPABASE_URL);
  requireValue(!url.username&&!url.password&&!url.search&&!url.hash&&['','/'].includes(url.pathname),'Use a Supabase API origin without credentials or extra paths.');
  if (environment==='local') requireValue(projectId==='local'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname)&&['http:','https:'].includes(url.protocol),'Local mode requires a loopback origin and project ID local.');
  else requireValue(/^[a-z]{20}$/.test(projectId??'')&&url.protocol==='https:'&&url.hostname===`${projectId}.supabase.co`,'URL must match the exact target project ID.');
  requireValue(projectId!==productionProject||environment==='production','The known production project cannot be labelled staging/local.');
  const key=env.SUPABASE_SERVICE_ROLE_KEY;
  let serviceKey=typeof key==='string'&&key.startsWith('sb_secret_')&&key.length>15;
  if (!serviceKey && key?.split('.').length===3) {
    try { serviceKey=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString()).role==='service_role'; } catch { /* Reject malformed credentials. */ }
  }
  requireValue(serviceKey,'Set an operator-only secret/service-role key in SUPABASE_SERVICE_ROLE_KEY.');
  return {url:url.origin,projectId,environment,key};
}

export function argumentsFor(argv) {
  const action=argv[0];requireValue(['lookup','list','check','grant','revoke'].includes(action),'Choose lookup, list, check, grant or revoke.');
  const options={};
  const allowed=new Set(['user-id','email','expected-email','operator','reason','confirm-project','after-id','limit','apply']);
  for(let i=1;i<argv.length;i++) {
    const name=argv[i].replace(/^--/,'');requireValue(argv[i].startsWith('--')&&allowed.has(name)&&!(name in options),'Unknown or duplicate option.');
    if(name==='apply')options.apply=true;
    else {requireValue(argv[i+1]&&!argv[i+1].startsWith('--'),'Missing option value.');options[name]=argv[++i];}
  }
  if(options['user-id'])requireValue(uuid(options['user-id']),'Use a verified Auth user UUID.');
  if(options['after-id'])requireValue(uuid(options['after-id']),'Invalid membership cursor.');
  if(action==='lookup')requireValue(!!options['user-id']!==!!options.email,'Lookup requires one exact UUID or email.');
  if(['grant','revoke','check'].includes(action))requireValue(uuid(options['user-id']),'An exact Auth user UUID is required.');
  if(['grant','revoke'].includes(action)) {
    requireValue(options['expected-email']?.trim(),'Confirm the email from Auth lookup using --expected-email.');
    requireValue(options.operator?.trim().length>=3&&options.operator.length<=200,'Supply --operator (3-200 characters).');
    requireValue(options.reason?.trim().length>=5&&options.reason.length<=500,'Supply --reason (5-500 characters).');
  } else requireValue(!options.apply,'--apply is only valid for grant/revoke.');
  const limit=Number(options.limit??50);requireValue(Number.isInteger(limit)&&limit>=1&&limit<=100,'Limit must be 1-100.');
  return {action,options,limit};
}

export async function run(argv,env=process.env,request=fetch) {
  const input=argumentsFor(argv), config=configuration(env), o=input.options;
  const mutation=['grant','revoke'].includes(input.action);
  requireValue(!o.apply||o['confirm-project']===config.projectId,'--confirm-project must exactly match before applying a membership change.');
  const params={p_action:mutation&&!o.apply?'check':input.action,p_limit:input.limit};
  const mapping={'user-id':'p_user_id',email:'p_email','expected-email':'p_expected_email',operator:'p_operator',reason:'p_reason','after-id':'p_after_id'};
  for(const [option,param] of Object.entries(mapping))if(o[option])params[param]=o[option].trim();
  const response=await request(`${config.url}/rest/v1/rpc/admin_report_moderators`,{
    method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),
    headers:{apikey:config.key,Authorization:`Bearer ${config.key}`,'Content-Type':'application/json'},body:JSON.stringify(params),
  });
  requireValue(response.ok,`Moderator administration refused (HTTP ${response.status}). Verify the account, migration and administrative role.`);
  const result=await response.json();
  if(mutation&&!o.apply)requireValue(result.user && (result.user.email??'[no-email]').toLowerCase()===o['expected-email'].trim().toLowerCase(),'Preview identity does not match --expected-email.');
  return {project_id:config.projectId,environment:config.environment,action:input.action,dry_run:mutation&&!o.apply,...result};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  try {console.log(JSON.stringify(await run(process.argv.slice(2)),null,2));}
  catch(error){console.error(error instanceof Error?error.message:'Moderator administration failed.');process.exitCode=1;}
}
