// Extension of the trusted membership operator workflow, never client code.
import {configuration} from './manage_moderators.mjs';
const uuid=v=>/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v??'');
const need=(value,message)=>{if(!value)throw Error(message);};
export async function runApplications(argv,env=process.env,request=fetch){
  const [action,...args]=argv;
  need(['list','check','approve','decline'].includes(action),'Choose applications list, check, approve or decline.');
  const o={},allowed=new Set(['request-id','expected-email','operator','reason','limit','confirm-project','apply']);
  for(let i=0;i<args.length;i++){
    const name=args[i].replace(/^--/,'');need(args[i].startsWith('--')&&allowed.has(name)&&!(name in o),'Unknown or duplicate option.');
    if(name==='apply')o.apply=true;else{need(args[i+1]&&!args[i+1].startsWith('--'),'Missing option value.');o[name]=args[++i];}
  }
  const config=configuration(env),mutation=['approve','decline'].includes(action);
  need(action==='list'||uuid(o['request-id']),'An exact request UUID is required.');
  need(!o.apply||mutation,'--apply requires an approval or decline.');
  const limit=Number(o.limit??50);need(Number.isInteger(limit)&&limit>=1&&limit<=100,'Limit must be 1..100.');
  if(mutation){need(o['expected-email']?.trim(),'Confirm the Auth email from trusted lookup.');
    need(o.operator?.trim().length>=3&&o.operator.length<=200,'Supply an administrative operator.');
    need(o.reason?.trim().length>=5&&o.reason.length<=500,'Supply a review reason.');}
  need(!o.apply||o['confirm-project']===config.projectId,'Confirm the exact target project before applying.');
  const response=await request(config.url+'/rest/v1/rpc/admin_moderator_applications',{
    method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),
    headers:{apikey:config.key,Authorization:`Bearer ${config.key}`,'Content-Type':'application/json'},
    body:JSON.stringify({p_action:mutation&&!o.apply?'check':action,p_request_id:o['request-id']??null,
      p_expected_email:o['expected-email']?.trim()??null,p_operator:o.operator?.trim()??null,p_reason:o.reason?.trim()??null,p_limit:limit}),
  });
  need(response.ok,`Application administration refused (HTTP ${response.status}).`);
  const result=await response.json();
  if(mutation&&!o.apply)need(result.identity?.user?.email?.toLowerCase()===o['expected-email'].trim().toLowerCase(),'Preview Auth identity does not match expected email.');
  return {project_id:config.projectId,environment:config.environment,action,dry_run:mutation&&!o.apply,...result};
}
