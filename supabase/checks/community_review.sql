-- Disposable local fixtures only; never creates real hosted participants.
begin;
insert into public.schools(id,name,latitude,longitude) values('community-A','Community School A',44,-90),('community-B','Community School B',45,-90);
insert into auth.users(id,email) values('94000000-0000-0000-0000-000000000001','legacy@example.test');
insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,reporter_id,status) values
 ('95000000-0000-0000-0000-000000000001','community-A',44,-90,'blocked_path',3,'Historical private observation','94000000-0000-0000-0000-000000000001','unverified');
insert into public.hazard_report_photos(report_id,owner_id,storage_path) values('95000000-0000-0000-0000-000000000001','94000000-0000-0000-0000-000000000001','95000000-0000-0000-0000-000000000001/1.jpg');
set local role service_role;
select public.community_action('submit',repeat('a',64),repeat('0',64),'{"id":"95000000-0000-0000-0000-000000000002","school_id":"community-B","latitude":44,"longitude":-90,"type":"blocked_path","severity":3,"description":"Anonymous community observation","status":"verified","is_demo":true,"reporter_id":"94000000-0000-0000-0000-000000000001","photo_path":"95000000-0000-0000-0000-000000000002/1.jpg"}');
select public.community_action('submit',repeat('a',64),repeat('0',64),'{"id":"95000000-0000-0000-0000-000000000002"}');
reset role;
do $$ begin
 assert (select count(*) from public.hazard_reports where id='95000000-0000-0000-0000-000000000002')=1;
 assert exists(select from public.hazard_reports where id='95000000-0000-0000-0000-000000000002' and school_id='community-A' and reporter_id is null and status='unverified' and not is_demo and community_submitted);
 assert (select count(*) from auth.users where id='94000000-0000-0000-0000-000000000001')=1;
end $$;
set local role anon;
do $$ declare result jsonb;begin
 assert (select count(*) from public.hazard_reports where id in ('95000000-0000-0000-0000-000000000001','95000000-0000-0000-0000-000000000002'))=1;
 assert (select count(*) from public.hazard_report_photos where report_id in ('95000000-0000-0000-0000-000000000001','95000000-0000-0000-0000-000000000002'))=1;
 begin perform * from private.community_reviews;raise exception 'Private review identities exposed';exception when insufficient_privilege then null;end;
 begin perform public.community_action('summary',repeat('a',64),repeat('0',64),'{"id":"95000000-0000-0000-0000-000000000002"}');raise exception 'Public service bypass';exception when insufficient_privilege then null;end;
 begin update public.community_review_totals set verified=3;raise exception 'Forged consensus';exception when insufficient_privilege then null;end;
 result:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_school_ids=>array['community-A']);
 assert (result->'deduplication'->>'raw_reports')::integer=1,'New public pending report included, legacy private report excluded';
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','94000000-0000-0000-0000-000000000001',true);
do $$ begin
 begin insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description,reporter_id,community_submitted) values('community-A',44,-90,'blocked_path',3,'Bypass public submission quota',auth.uid(),true);raise exception 'Direct community insert bypass';exception when insufficient_privilege then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','',true);
set local role service_role;
do $$ declare r jsonb;begin
 begin perform public.community_action('summary',repeat('b',64),repeat('1',64),'{"id":"95000000-0000-0000-0000-000000000001"}');raise exception 'Legacy private report exposed';exception when raise_exception then assert sqlerrm='Report unavailable';end;
 begin perform public.community_action('review',repeat('a',64),repeat('0',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"I submitted this concern"}');raise exception 'Self vote accepted';exception when raise_exception then assert sqlerrm='You cannot review your own submission';end;
 r:=public.community_action('review',repeat('b',64),repeat('1',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"Observed the same blocked path"}');
 assert not (r->>'changed')::boolean and (r->'counts'->>'verified')::int=1;
 r:=public.community_action('review',repeat('b',64),repeat('1',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"Repeat own review must count once"}');
 assert (r->'counts'->>'verified')::int=1;
 begin perform public.community_action('review',repeat('c',64),repeat('1',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"Another browser on same network"}');raise exception 'Network repeat counted';exception when raise_exception then assert sqlerrm='This connection has already reviewed this report';end;
 begin perform public.community_action('review',repeat('c',64),repeat('2',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"unverified","choice":"verified","reason":"Stale round must not vote"}');raise exception 'Stale round accepted';exception when sqlstate 'P0409' then null;end;
 perform public.community_action('review',repeat('c',64),repeat('2',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"Independent observed concern"}');
 r:=public.community_action('review',repeat('d',64),repeat('3',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":0,"expected_status":"unverified","choice":"verified","reason":"Third independent observed concern"}');
 assert (r->>'changed')::boolean and r->'report'->>'status'='verified' and (r->'counts'->>'review_round')::int=1;
 assert not (r->'report' ? 'reporter_id');
 begin perform public.community_action('review',repeat('e',64),repeat('4',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"verified","choice":"resolved","reason":"Immediate status flipping blocked"}');raise exception 'Cooldown bypass';exception when sqlstate 'P0429' then null;end;
end $$;
reset role;
do $$ begin
 assert (select count(*) from public.report_moderation_history where report_id='95000000-0000-0000-0000-000000000002' and actor_id is null)=1;
 assert (select status from public.hazard_reports where id='95000000-0000-0000-0000-000000000001')='unverified';
 assert (select owner_id from public.hazard_report_photos where report_id='95000000-0000-0000-0000-000000000001')='94000000-0000-0000-0000-000000000001';
 assert not exists(select from public.report_moderators where user_id='94000000-0000-0000-0000-000000000001');
 assert jsonb_array_length(private.hazard_reset_preview()#>'{unsafe_records,unknown_foreign_keys}')>=3,'Community evidence must block the old reset until its reviewed backup includes those records';
end $$;
update public.hazard_reports set community_decided_at=now()-interval '16 minutes' where id='95000000-0000-0000-0000-000000000002';
set local role service_role;
do $$ declare r jsonb;begin
 r:=public.community_action('review',repeat('e',64),repeat('4',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"verified","choice":"flag","reason":"Needs another look at the evidence"}');
 assert not (r->>'changed')::boolean and (r->'counts'->>'flags')::int=1 and r->'report'->>'status'='verified';
end $$;
reset role;
-- Consensus withdrawal protects contents/photos while the public aggregate event
-- remains readable so connected clients can discard a previously visible pin.
set local role service_role;
select public.community_action('review',repeat('e',64),repeat('4',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"verified","choice":"rejected","reason":"Evidence does not support this report"}');
select public.community_action('review',repeat('f',64),repeat('5',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"verified","choice":"rejected","reason":"Independent concern was not observed"}');
select public.community_action('review',repeat('1',64),repeat('6',64),'{"id":"95000000-0000-0000-0000-000000000002","review_round":1,"expected_status":"verified","choice":"rejected","reason":"Third independent review of the concern"}');
reset role;
set local role anon;
do $$ begin
 assert not exists(select from public.hazard_reports where id='95000000-0000-0000-0000-000000000002');
 assert not exists(select from public.hazard_report_photos where report_id='95000000-0000-0000-0000-000000000002');
 assert exists(select from public.community_review_totals where report_id='95000000-0000-0000-0000-000000000002' and review_round=2);
end $$;
reset role;
insert into private.community_attempts(participant_hash,network_hash,action) select repeat('f',64),repeat('5',64),'submit' from generate_series(1,20);
set local role service_role;
do $$ begin
 begin perform public.community_action('prepare',repeat('f',64),repeat('5',64),'{"id":"95000000-0000-0000-0000-000000000003"}');raise exception 'Upload quota bypass';exception when sqlstate 'P0429' then null;end;
end $$;
reset role;
set local role service_role;
select public.community_action('submit',repeat('a',64),repeat('0',64),'{"id":"95000000-0000-0000-0000-000000000003","latitude":45,"longitude":-90,"type":"blocked_path","severity":3,"description":"Concern near another nationwide school"}');
select public.community_action('review',repeat('b',64),repeat('1',64),'{"id":"95000000-0000-0000-0000-000000000003","review_round":0,"expected_status":"unverified","choice":"resolved","reason":"Observed this concern has been fixed"}');
select public.community_action('review',repeat('c',64),repeat('2',64),'{"id":"95000000-0000-0000-0000-000000000003","review_round":0,"expected_status":"unverified","choice":"resolved","reason":"Independent observation of the repaired path"}');
select public.community_action('review',repeat('d',64),repeat('3',64),'{"id":"95000000-0000-0000-0000-000000000003","review_round":0,"expected_status":"unverified","choice":"resolved","reason":"Third independent confirmation of repair"}');
reset role;
do $$ begin
 assert exists(select from public.hazard_reports where id='95000000-0000-0000-0000-000000000003' and school_id='community-B' and status='resolved' and resolved_at is not null);
 assert (select count(*) from public.report_moderation_history where report_id='95000000-0000-0000-0000-000000000003')=1;
end $$;
rollback;
