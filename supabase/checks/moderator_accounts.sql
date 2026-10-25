-- Disposable migrated database only; no real accounts. All fixtures roll back.
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin begin execute statement; exception when others then if sqlstate=expected then return; end if; raise; end;
 raise exception 'Expected %: %',expected,statement; end $$;

insert into auth.users(id,email,email_confirmed_at,banned_until) values
 ('41000000-0000-0000-0000-000000000001','ordinary@example.test',now(),null),
 ('41000000-0000-0000-0000-000000000002','other@example.test',now(),null),
 ('41000000-0000-0000-0000-000000000003','moderator@example.test',now(),null),
 ('41000000-0000-0000-0000-000000000004','unconfirmed@example.test',null,null),
 ('41000000-0000-0000-0000-000000000005','banned@example.test',now(),now()+interval '1 day'),
 ('41000000-0000-0000-0000-000000000006',null,null,null);
set local session_replication_role=replica;
insert into public.school_districts(id,nces_lea_id,name,state,source_dataset,source_year,source_url) values
 ('nces-lea:0101000','0101000','Phase 4 Shared District','AL','EDGE_GEOCODE_PUBLICLEA_2425','2024-2025','https://nces.ed.gov/test'),
 ('nces-lea:1301000','1301000','Phase 4 Shared District','GA','EDGE_GEOCODE_PUBLICLEA_2425','2024-2025','https://nces.ed.gov/test');
insert into public.school_district_sources(district_id,name,state,source_dataset,source_year,source_url)
 select id,name,state,source_dataset,source_year,source_url from public.school_districts where name='Phase 4 Shared District';
insert into public.schools(id,name,latitude,longitude,state,city,district_id,district_source_year,district_source_dataset,source,source_id,source_year,source_dataset,classification) values
 ('010100000001','Phase 4 School A',-66,0,'AL','City A','nces-lea:0101000','2024-2025','EDGE_GEOCODE_PUBLICSCH_2425','nces-public','010100000001','2024-2025','EDGE_GEOCODE_PUBLICSCH_2425','public'),
 ('130100000001','Phase 4 School B',-66,1,'GA','City B','nces-lea:1301000','2024-2025','EDGE_GEOCODE_PUBLICSCH_2425','nces-public','130100000001','2024-2025','EDGE_GEOCODE_PUBLICSCH_2425','public');
insert into public.schools(id,name,latitude,longitude,state,classification) values ('phase4-independent','Phase 4 Independent',-66,2,'AL','private');
insert into public.schools(id,name,latitude,longitude,canonical_id) values ('phase4-alias','Phase 4 Alias',-66,0,'010100000001');
insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,status,reporter_id,created_at,is_demo) values
 ('42000000-0000-0000-0000-000000000001','010100000001',-66,0,'blocked_path',2,'Older pending School A','unverified','41000000-0000-0000-0000-000000000001','2026-10-01',false),
 ('42000000-0000-0000-0000-000000000002','130100000001',-66,1,'missing_sidewalk',5,'High priority School B','unverified','41000000-0000-0000-0000-000000000001','2026-10-05',false),
 ('42000000-0000-0000-0000-000000000003','010100000001',-66,0,'blocked_path',4,'Flagged verified School A','verified','41000000-0000-0000-0000-000000000001','2026-10-02',false),
 ('42000000-0000-0000-0000-000000000004','010100000001',-66,0,'blocked_path',3,'Resolved School A','resolved','41000000-0000-0000-0000-000000000001','2026-10-03',false),
 ('42000000-0000-0000-0000-000000000005','130100000001',-66,1,'blocked_path',2,'Rejected School B','rejected','41000000-0000-0000-0000-000000000001','2026-10-04',false),
 ('42000000-0000-0000-0000-000000000006','phase4-alias',-66,0,'blocked_path',5,'Legacy alias pending','unverified','41000000-0000-0000-0000-000000000001','2026-09-01',false),
 ('42000000-0000-0000-0000-000000000007','phase4-independent',-66,2,'blocked_path',1,'Independent pending','unverified','41000000-0000-0000-0000-000000000002','2026-10-06',false),
 ('42000000-0000-0000-0000-000000000008','010100000001',-66,0,'blocked_path',5,'Demo must be excluded','unverified',null,'2026-10-01',true);
insert into public.report_flags(report_id,user_id,reason) values
 ('42000000-0000-0000-0000-000000000003','41000000-0000-0000-0000-000000000002','Review this synthetic concern');
insert into public.hazard_report_photos(report_id,owner_id,storage_path) values
 ('42000000-0000-0000-0000-000000000007','41000000-0000-0000-0000-000000000002','42000000-0000-0000-0000-000000000007/123'||chr(92)||'.jpg');
set local session_replication_role=origin;

set local role anon;
select pg_temp.expect_error($q$select public.admin_report_moderators('list')$q$,'42501');
select pg_temp.expect_error('select public.get_moderation_queue()','42501');
set local role authenticated;
select set_config('request.jwt.claim.sub','41000000-0000-0000-0000-000000000001',true);
select pg_temp.expect_error($q$select public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000001')$q$,'42501');
select pg_temp.expect_error('select public.get_moderation_queue()','42501');
select pg_temp.expect_error($q$select public.search_moderation_scopes('school')$q$,'42501');
select pg_temp.expect_error($q$insert into public.report_moderators values ('41000000-0000-0000-0000-000000000001')$q$,'42501');
select pg_temp.expect_error('select * from private.moderator_membership_history','42501');

set local role service_role;
select pg_temp.assert_true(public.admin_report_moderators('lookup',p_email=>'MODERATOR@example.test')->'user'->>'id'='41000000-0000-0000-0000-000000000003','Exact verified Auth email lookup');
select pg_temp.assert_true(public.admin_report_moderators('lookup',p_email=>'missing@example.test')->'user'='null'::jsonb,'Missing user not invented');
select pg_temp.expect_error($q$select public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000003',p_expected_email=>'wrong@example.test',p_operator=>'Test admin',p_reason=>'Synthetic reviewed grant')$q$,'22023');
select pg_temp.expect_error($q$select public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000004',p_expected_email=>'unconfirmed@example.test',p_operator=>'Test admin',p_reason=>'Synthetic reviewed grant')$q$,'23514');
select pg_temp.expect_error($q$select public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000005',p_expected_email=>'banned@example.test',p_operator=>'Test admin',p_reason=>'Synthetic reviewed grant')$q$,'23514');
select pg_temp.expect_error($q$insert into public.report_moderators values ('41000000-0000-0000-0000-000000000003')$q$,'42501');
select pg_temp.assert_true((public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000003',p_expected_email=>'moderator@example.test',p_operator=>'Test admin',p_reason=>'Synthetic reviewed grant')->>'changed')::boolean,'Grant membership through trusted workflow');
select pg_temp.assert_true(not(public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000003',p_expected_email=>'moderator@example.test',p_operator=>'Test admin',p_reason=>'Repeated reviewed grant')->>'changed')::boolean,'Repeated grant is idempotent');
select pg_temp.assert_true(jsonb_array_length(public.admin_report_moderators('list')->'items')=1,'List current memberships only');
select pg_temp.assert_true((public.admin_report_moderators('check','41000000-0000-0000-0000-000000000003')->>'is_moderator')::boolean,'Check privileges server-side');

set local role authenticated;
select set_config('request.jwt.claim.sub','41000000-0000-0000-0000-000000000003',true);
select pg_temp.assert_true(public.is_report_moderator(),'Provisioned moderator has access');
select pg_temp.expect_error($q$select public.admin_report_moderators('list')$q$,'42501');
select pg_temp.expect_error($q$select public.admin_report_moderators('grant','41000000-0000-0000-0000-000000000001')$q$,'42501');
select pg_temp.assert_true((public.get_moderation_queue()->>'total')::int=4,'Nationwide pending queue spans all schools');
select pg_temp.assert_true((public.get_moderation_queue()->'counts'->>'all')::int=7,'Demo excluded and counts are individual reports');
select pg_temp.assert_true(public.get_moderation_queue()->'items'->0->'report'->>'id'='42000000-0000-0000-0000-000000000006','Priority ties use oldest then stable ID');
select pg_temp.assert_true(public.get_moderation_queue(p_order=>'newest')->'items'->0->'report'->>'id'='42000000-0000-0000-0000-000000000007','Newest order');
select pg_temp.assert_true((public.get_moderation_queue(p_school_id=>'010100000001')->>'total')::int=2,'School filter includes canonical aliases');
select pg_temp.assert_true((public.get_moderation_queue(p_district_id=>'nces-lea:1301000')->>'total')::int=1,'District ID disambiguates duplicate names');
select pg_temp.assert_true((public.get_moderation_queue(p_district_id=>'unassigned')->>'total')::int=1,'Independent schools have a usable queue');
select pg_temp.assert_true((public.get_moderation_queue(p_queue=>'flagged')->>'total')::int=1,'Open flagged reports');
select pg_temp.assert_true((public.get_moderation_queue(p_queue=>'verified')->>'total')::int=1,'Verified queue');
select pg_temp.assert_true((public.get_moderation_queue(p_queue=>'resolved')->>'total')::int=1,'Resolved queue');
select pg_temp.assert_true((public.get_moderation_queue(p_queue=>'rejected')->>'total')::int=1,'Rejected queue');
select pg_temp.assert_true(jsonb_array_length(public.get_moderation_queue(p_limit=>1)->'items')=1 and (public.get_moderation_queue(p_limit=>1)->>'has_more')::boolean,'Bounded queue pagination');
select pg_temp.assert_true(public.get_moderation_queue(p_limit=>1,p_offset=>1)->'items'->0->'report'->>'id'='42000000-0000-0000-0000-000000000002','Second page no repeated report');
select pg_temp.assert_true(jsonb_array_length(public.search_moderation_scopes('school','Phase 4')->'items')=3,'Nationwide directory excludes aliases');
select pg_temp.assert_true(jsonb_array_length(public.search_moderation_scopes('district','Shared District')->'items')=2,'Duplicate district names retain distinct IDs');
select pg_temp.assert_true(jsonb_array_length(public.search_moderation_scopes('school','Phase 4','nces-lea:1301000')->'items')=1,'School discovery follows selected district');
select pg_temp.expect_error($q$select public.get_moderation_queue(p_queue=>'unknown')$q$,'22023');
select pg_temp.expect_error($q$select public.get_moderation_queue(p_order=>'bad')$q$,'22023');
select pg_temp.expect_error($q$select public.search_moderation_scopes('bad')$q$,'22023');
select pg_temp.assert_true((select count(*)=1 from public.hazard_report_photos where report_id='42000000-0000-0000-0000-000000000007'),'Moderator can read pending photo metadata');

select * from public.moderate_hazard_report('42000000-0000-0000-0000-000000000003','verified','Reviewed the accuracy flag','verified');
select pg_temp.assert_true((public.get_moderation_queue(p_queue=>'flagged')->>'total')::int=0,'Same-status flag review closes flags atomically');
select * from public.moderate_hazard_report('42000000-0000-0000-0000-000000000002','verified','Verified nationwide school concern','unverified');
select * from public.moderate_hazard_report('42000000-0000-0000-0000-000000000002','resolved','Resolved after documented repair','verified');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report('42000000-0000-0000-0000-000000000002','rejected','A stale reviewer cannot overwrite','unverified')$q$,'P0001');
select pg_temp.assert_true((select count(*)=2 from public.report_moderation_history where report_id='42000000-0000-0000-0000-000000000002'),'Status decisions remain audited');
select pg_temp.assert_true((select resolved_at is not null from public.hazard_reports where id='42000000-0000-0000-0000-000000000002'),'Resolution timestamp maintained');

set local role service_role;
select pg_temp.assert_true((public.admin_report_moderators('revoke','41000000-0000-0000-0000-000000000003',p_expected_email=>'moderator@example.test',p_operator=>'Test admin',p_reason=>'Synthetic permission revocation')->>'changed')::boolean,'Revoke existing membership');
select pg_temp.assert_true(not(public.admin_report_moderators('revoke','41000000-0000-0000-0000-000000000003',p_expected_email=>'moderator@example.test',p_operator=>'Test admin',p_reason=>'Repeated permission revocation')->>'changed')::boolean,'Revocation is idempotent');
set local role authenticated;
-- Same JWT subject after revocation; no refresh/re-login required by the server.
select pg_temp.assert_true(not public.is_report_moderator(),'Stale JWT does not retain privileges');
select pg_temp.expect_error('select public.get_moderation_queue()','42501');
select pg_temp.expect_error($q$select public.search_moderation_scopes('school')$q$,'42501');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report('42000000-0000-0000-0000-000000000001','verified','Revoked actor attempted review','unverified')$q$,'42501');
select pg_temp.assert_true((select count(*)=0 from public.hazard_reports where status='unverified' and not is_demo),'RLS removes other authors pending reports');
select pg_temp.assert_true((select count(*)=0 from public.hazard_report_photos where report_id='42000000-0000-0000-0000-000000000007'),'Photo permissions revoked too');
select pg_temp.assert_true((select count(*)=0 from public.report_moderation_history),'Revoked non-author cannot read audit notes');
reset role;
select pg_temp.assert_true((select count(*)=2 from private.moderator_membership_history),'One grant and one revoke, no duplicate audit records');
select pg_temp.assert_true((select count(*)=3 from public.report_moderation_history),'Membership revocation preserves decision history');
-- Legacy membership for an Auth account without email can still be revoked.
insert into public.report_moderators values('41000000-0000-0000-0000-000000000006');
set local role service_role;
select pg_temp.assert_true((public.admin_report_moderators('revoke','41000000-0000-0000-0000-000000000006',p_expected_email=>'[no-email]',p_operator=>'Test admin',p_reason=>'Remove legacy unconfirmed membership')->>'changed')::boolean,'Revoke a legacy account without email');
reset role;
rollback;
