-- Run on a disposable migrated database (supabase/tests/run.mjs), never production.
-- Synthetic fixtures and role changes are rolled back.
begin;
create function pg_temp.assert_true(ok boolean, label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.expect_error(sql text, expected text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then
    if sqlstate = expected then return; end if;
    raise exception 'Expected %, got %: %',expected,sqlstate,sqlerrm;
  end;
  raise exception 'Expected error %: %',expected,sql;
end $$;

insert into public.schools(id,name,latitude,longitude,district,city,state,zip_code) values
  ('test-A','School A',-60,0,'Test District A','Test City','ZZ','00001'),
  ('test-B','School B',-60,0.1,'Test District B','Test City','ZZ','00002'),
  ('test-campus-1','Shared Campus One',-60,0.2,'Test District','Test City','ZZ','00003'),
  ('test-campus-2','Shared Campus Two',-60,0.2,'Test District','Test City','ZZ','00003'),
  ('173045003167','Schaumburg High School',42.027416,-88.106632,'Township HSD 211','Schaumburg','IL','60194')
on conflict(id) do nothing;
update public.schools set canonical_id='173045003167' where id='sample-school';
insert into public.schools(id,name,latitude,longitude,canonical_id) values
  ('test-alias','School A legacy alias',-60,0,'test-A');
insert into auth.users(id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000003');
insert into public.report_moderators(user_id) values ('10000000-0000-0000-0000-000000000003');

-- Fixture-only legacy rows emulate data written before the new validation.
set local session_replication_role = replica;
insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,status,reporter_id,is_demo) values
  ('20000000-0000-0000-0000-000000000001','sample-school',-60,0,'blocked_path',3,'Legacy incorrect school','unverified','10000000-0000-0000-0000-000000000001',false),
  ('20000000-0000-0000-0000-000000000002','sample-school',42.027416,-88.106632,'blocked_path',3,'Legitimate pilot school','unverified','10000000-0000-0000-0000-000000000001',false),
  ('20000000-0000-0000-0000-000000000003','sample-school',-60,0,'blocked_path',3,'Demo wrong school','verified','10000000-0000-0000-0000-000000000001',true),
  ('20000000-0000-0000-0000-000000000004','test-B',-60,0.1,'blocked_path',3,'Unrelated correct school','verified','10000000-0000-0000-0000-000000000001',false);
set local session_replication_role = origin;
-- An existing photo remains attached through a school correction. Use the
-- installed constraint's accepted legacy path; this test does not alter it.
insert into public.hazard_report_photos(report_id,owner_id,storage_path) values
  ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
   E'20000000-0000-0000-0000-000000000001/123\\.jpg');
insert into storage.objects(bucket_id,name,owner_id) select 'hazard-photos',storage_path,owner_id::text
  from public.hazard_report_photos where report_id='20000000-0000-0000-0000-000000000001';
create temp table original_reports as select id,to_jsonb(h)-'school_id' as snapshot from public.hazard_reports h;
create temp table original_photos as select to_jsonb(p) snapshot from public.hazard_report_photos p;

select pg_temp.assert_true((select school_id='test-A' and distance_meters < 1 from public.nearest_schools(-60,0) limit 1),'School A');
select pg_temp.assert_true((select school_id='test-B' and distance_meters < 1 from public.nearest_schools(-60,0.1) limit 1),'School B');
select pg_temp.assert_true((select school_id='173045003167' from public.nearest_schools(42.027416,-88.106632) limit 1),'Schaumburg canonical identity');
select pg_temp.assert_true((select array_agg(school_id)=array['test-campus-1','test-campus-2'] from public.nearest_schools(-60,0.2)),'Shared campus deterministic candidates');
select pg_temp.assert_true(not exists(select from public.nearest_schools(0,0)),'No distant fallback');
select pg_temp.assert_true(not exists(select from public.nearest_schools(-60,0) where school_id='test-alias'),'Exclude aliases');
select pg_temp.assert_true((select distance_meters between 5000 and 6000 from public.nearest_schools(-60,0,10000) where school_id='test-B'),'Geodesic meters and configurable radius');
select pg_temp.expect_error('select * from public.nearest_schools(91,0)','22023');
select pg_temp.expect_error('select * from public.nearest_schools(null,0)','22023');
select pg_temp.expect_error($q$select * from public.nearest_schools('NaN',0)$q$,'22023');
select pg_temp.expect_error('select * from public.nearest_schools(0,0,-1)','22023');
select pg_temp.assert_true(exists(select from pg_indexes where indexname='schools_canonical_geography_gist'),'Spatial expression index exists');
set local enable_seqscan = off;
do $$ declare plan json; begin
  execute 'explain (format json) select id from public.schools s where canonical_id is null
    and extensions.st_dwithin(s.location::extensions.geography,
      extensions.st_setsrid(extensions.st_makepoint(0,-60),4326)::extensions.geography,2000)' into plan;
  assert plan::text like '%schools_canonical_geography_gist%','Geographic query uses the index';
end $$;
set local enable_seqscan = on;

select pg_temp.assert_true((select review_status='review_required' and suggested_school_id='test-A' from public.preview_pilot_school_associations() where report_id='20000000-0000-0000-0000-000000000001'),'Preview incorrect pilot');
select pg_temp.assert_true((select review_status='retain_pilot' from public.preview_pilot_school_associations() where report_id='20000000-0000-0000-0000-000000000002'),'Retain legitimate pilot alias');
select pg_temp.assert_true(not exists(select from public.preview_pilot_school_associations() where report_id in ('20000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000004')),'Exclude demos and unrelated schools');
select pg_temp.assert_true((select bool_and(o.snapshot=to_jsonb(h)-'school_id' and h.school_id=case when h.id='20000000-0000-0000-0000-000000000004' then 'test-B' else 'sample-school' end) from original_reports o join public.hazard_reports h using(id)),'Preview is read only');

set local role anon;
select pg_temp.assert_true((select count(*)=0 from public.hazard_reports where id='20000000-0000-0000-0000-000000000001'),'Anonymous cannot read unverified');
select pg_temp.assert_true((select count(*)=0 from public.hazard_report_photos where report_id='20000000-0000-0000-0000-000000000001'),'Pending photo is private');
select pg_temp.assert_true((select count(*)=0 from storage.objects),'Pending storage object is private');
select pg_temp.expect_error('select * from public.preview_pilot_school_associations()','42501');
select pg_temp.expect_error($q$select public.apply_reviewed_school_corrections('[]','reviewer','approved')$q$,'42501');
reset role;
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000001',true);
set local role authenticated;
insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description) values
  ('test-A',-60,0,'blocked_path',3,'Correct School A report'),
  ('test-B',-60,0.1,'blocked_path',3,'Correct School B report'),
  ('173045003167',42.027416,-88.106632,'blocked_path',3,'Correct Schaumburg report'),
  ('test-campus-2',-60,0.2,'blocked_path',3,'Confirmed alternate campus');
select pg_temp.expect_error($q$insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description) values ('sample-school',-60,0,'blocked_path',3,'Malicious pilot school')$q$,'23514');
select pg_temp.expect_error($q$insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description,is_demo) values ('test-B',-60,0,'blocked_path',3,'Malicious distant school',true)$q$,'23514');
select pg_temp.expect_error($q$insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description) values ('test-alias',-60,0,'blocked_path',3,'Malicious legacy alias')$q$,'23514');
select pg_temp.expect_error($q$insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description) values ('test-A',0,0,'blocked_path',3,'No school near the pin')$q$,'23514');
select pg_temp.expect_error($q$insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description,status) values ('test-A',-60,0,'blocked_path',3,'Unapproved verified entry','verified')$q$,'42501');
select pg_temp.expect_error($q$update public.hazard_reports set school_id='test-A' where id='20000000-0000-0000-0000-000000000004'$q$,'42501');
select pg_temp.expect_error('select * from public.preview_pilot_school_associations()','42501');
reset role;

-- Server-side UPDATE validation protects future privileged edit paths as well.
select pg_temp.expect_error($q$update public.hazard_reports set longitude=1 where school_id='test-A'$q$,'23514');
select pg_temp.expect_error($q$select public.apply_reviewed_school_corrections('[{"report_id":"20000000-0000-0000-0000-000000000002","current_school_id":"sample-school","latitude":42.027416,"longitude":-88.106632,"school_id":"173045003167"}]','reviewer','confirmed by review')$q$,'P0001');
select pg_temp.expect_error($q$select public.apply_reviewed_school_corrections('[{"report_id":"20000000-0000-0000-0000-000000000001","current_school_id":"sample-school","latitude":-61,"longitude":0,"school_id":"test-A"}]','reviewer','confirmed by review')$q$,'P0001');
select pg_temp.assert_true(public.apply_reviewed_school_corrections('[{"report_id":"20000000-0000-0000-0000-000000000001","current_school_id":"sample-school","latitude":-60,"longitude":0,"school_id":"test-A"}]','reviewer','confirmed by review')=1,'Approved correction updates exactly one row');
select pg_temp.assert_true(public.apply_reviewed_school_corrections('[{"report_id":"20000000-0000-0000-0000-000000000001","current_school_id":"sample-school","latitude":-60,"longitude":0,"school_id":"test-A"}]','reviewer','confirmed by review')=0,'Correction is idempotent');
select pg_temp.assert_true((select bool_and(o.snapshot=to_jsonb(h)-'school_id') from original_reports o join public.hazard_reports h using(id)),'Correction preserves every other report field including coordinates');
select pg_temp.assert_true((select count(*)=1 from private.report_school_corrections),'Correction audited once');
select pg_temp.assert_true((select bool_and(exists(select from original_photos o where o.snapshot=to_jsonb(p))) from public.hazard_report_photos p),'Photos and their timestamps preserved');
select pg_temp.assert_true((select count(*)=1 from storage.objects),'Photo object preserved');
select pg_temp.assert_true((select school_id='sample-school' from public.hazard_reports where id='20000000-0000-0000-0000-000000000002'),'Legitimate report untouched');

-- Status changes on old associations continue through the existing moderation RPC.
select set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000003',true);
set local role authenticated;
select * from public.moderate_hazard_report('20000000-0000-0000-0000-000000000001','verified','Checked school and hazard','unverified');
select * from public.moderate_hazard_report('20000000-0000-0000-0000-000000000002','verified','Checked legitimate pilot association','unverified');
select pg_temp.assert_true((select count(*)=1 from public.report_moderation_history where report_id='20000000-0000-0000-0000-000000000001'),'Moderation audit preserved');
reset role;

-- Add an actual duplicate and confirm analytics dedup by stored canonical school.
insert into public.hazard_reports(school_id,latitude,longitude,type,severity,description,status) values
  ('test-A',-60,0,'blocked_path',3,'Duplicate correct School A','verified'),
  ('173045003167',42.027416,-88.106632,'blocked_path',3,'Duplicate pilot canonical record','verified');
set local role anon;
select pg_temp.assert_true((select count(*)=1 from public.hazard_report_photos where report_id='20000000-0000-0000-0000-000000000001'),'Reviewed photo remains readable');
select pg_temp.assert_true((select count(*)=1 from storage.objects),'Reviewed photo object remains readable');
do $$
declare a jsonb; b jsonb; pilot jsonb; legacy jsonb;
begin
  a:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_school_ids=>array['test-A']);
  b:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_school_ids=>array['test-B']);
  pilot:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_school_ids=>array['173045003167']);
  legacy:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_school_ids=>array['sample-school']);
  assert pilot=legacy,'Legacy filter IDs preserve canonical analytics API';
  assert (pilot->'summary'->>'total')::int=1 and (pilot->'deduplication'->>'raw_reports')::int=2,'Alias and canonical reports deduplicate together';
  assert (a->'summary'->>'total')::int=1,'School A unique total';
  assert (a->'deduplication'->>'raw_reports')::int=2,'School A raw total';
  assert (a->'deduplication'->>'duplicates_removed')::int=1,'Duplicate handling unchanged';
  assert (b->'summary'->>'total')::int=1,'School B total independent';
  assert not exists(select from jsonb_array_elements(a->'markers') m where m->>'school_id'<>'test-A' or (m->>'latitude')::float8<>-60),'Marker retains reported coordinates and school';
  assert not exists(select from jsonb_array_elements(a->'markers') m where m ? 'reporter_id' or m ? 'description'),'Analytics privacy';
end $$;
select pg_temp.assert_true(jsonb_array_length(public.search_analytics_schools('00002'))=1,'Nationwide ZIP search');
select pg_temp.assert_true(jsonb_array_length(public.search_analytics_schools('ZZ'))=4,'Nationwide state search excludes aliases');
reset role;
rollback;
