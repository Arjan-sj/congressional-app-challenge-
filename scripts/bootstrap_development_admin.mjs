// Explicit trusted terminal only. Never imported by app startup or deployed code.
import {pathToFileURL} from 'node:url';
import {configuration,run as manageModerators} from './manage_moderators.mjs';
const need=(value,message)=>{if(!value)throw Error(message);};
export async function bootstrap(argv,env=process.env,request=fetch){
  const o={},allowed=new Set(['email','operator','apply','confirm-project']);
  for(let i=0;i<argv.length;i++){
    const name=argv[i].replace(/^--/,'');need(argv[i].startsWith('--')&&allowed.has(name)&&!(name in o),'Unknown or duplicate bootstrap option.');
    if(name==='apply')o.apply=true;else{need(argv[i+1]&&!argv[i+1].startsWith('--'),'Missing bootstrap option.');o[name]=argv[++i];}
  }
  const config=configuration(env);
  need(config.environment!=='production','Development administrator bootstrap refuses production.');
  need(env.SAFEROUTES_ALLOW_ADMIN_BOOTSTRAP==='yes','Explicitly enable the development-only bootstrap.');
  need(typeof o.email==='string'&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(o.email)&&o.email.length<=320,'Supply an authorized administrator email.');
  need(o.operator?.trim().length>=3&&o.operator.length<=200,'Supply an authorized operator identifier.');
  need(!o.apply||o['confirm-project']===config.projectId,'Confirm the exact target project.');
  const headers={apikey:config.key,Authorization:`Bearer ${config.key}`,'Content-Type':'application/json'};
  const call=async(path,body)=>{
    const r=await request(config.url+path,{method:'POST',redirect:'error',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
    need(r.ok,`Bootstrap refused (HTTP ${r.status}). No existing identity was overwritten.`);return r.json();
  };
  need(await call('/rest/v1/rpc/bootstrap_account_exists',{})===false,'An adminModerator identity already exists; refusing to overwrite it.');
  const found=await call('/rest/v1/rpc/admin_report_moderators',{p_action:'lookup',p_email:o.email.trim()});
  need(!found.user,'The email already belongs to an Auth identity; bootstrap never overwrites an existing account.');
  if(!o.apply)return {project_id:config.projectId,environment:config.environment,dry_run:true,username:'adminModerator',requires_password_change:true};
  // Credentials are accepted only through an operator-controlled environment,
  // never argv, generated files, logs or a default password.
  const password=env.SAFEROUTES_BOOTSTRAP_PASSWORD;
  need(typeof password==='string'&&password.length>=14&&password.length<=128&&/[a-z]/.test(password)&&/[A-Z]/.test(password)&&/[0-9]/.test(password),'Set a new strong operator-controlled SAFEROUTES_BOOTSTRAP_PASSWORD (14–128 characters).');
  const created=await call('/auth/v1/admin/users',{email:o.email.trim(),password,email_confirm:true,
    user_metadata:{username:'adminModerator'},app_metadata:{development_administrator:true,bootstrap_environment:config.environment,must_change_password:true}});
  const user=created.user??created;
  need(/^[0-9a-f-]{36}$/i.test(user.id??'')&&user.email?.toLowerCase()===o.email.trim().toLowerCase(),'Auth identity could not be verified; no membership was requested.');
  await manageModerators(['grant','--user-id',user.id,'--expected-email',o.email.trim(),'--operator',o.operator.trim(),
    '--reason','Explicit development administrator bootstrap; password change required','--apply','--confirm-project',config.projectId],env,request);
  return {project_id:config.projectId,environment:config.environment,dry_run:false,user_id:user.id,
    username:'adminModerator',requires_password_change:true,action:'development moderator provisioned; change password before moderator access; enroll MFA'};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{console.log(JSON.stringify(await bootstrap(process.argv.slice(2)),null,2));}
  catch(e){console.error(e instanceof Error?e.message:'Bootstrap refused.');process.exitCode=1;}
}
