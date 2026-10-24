-- Disposable migrated database only. Synthetic fixtures and all changes roll back.
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if sqlstate=any(string_to_array(expected,',')) then return; end if;
    raise exception 'Expected %, got %: %',expected,sqlstate,sqlerrm;
  end;
  raise exception 'Expected error %: %',expected,statement;
end $$;

create function pg_temp.district_fact(p_leaid text,p_name text default 'Shared district name',
  p_state text default 'AL',p_opstfips text default '01',p_year text default '2024-2025')
returns jsonb language sql as $$
  select jsonb_build_object('id','nces-lea:'||p_leaid,'nces_lea_id',p_leaid,'name',p_name,
    'state',p_state,'source_year',p_year,
    'source_dataset','EDGE_GEOCODE_PUBLICLEA_'||substr(p_year,3,2)||right(p_year,2),
    'source_url','https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_'||substr(p_year,3,2)||right(p_year,2)||'/MapServer/0',
    'metadata',jsonb_build_object('opstfips',p_opstfips));
$$;
create function pg_temp.upsert_fact(p_fact jsonb) returns void language sql as $$
  select public.upsert_nces_district_sources(jsonb_build_array(p_fact),'Phase 2 SQL reviewer',repeat('a',64));
$$;

select pg_temp.assert_true(public.nces_school_year('2425')='2024-2025','Compact source year is normalized');
select pg_temp.assert_true(public.nces_school_year('2024-2025')='2024-2025','Full source year is retained');
select pg_temp.assert_true(public.nces_school_year('2024-2026') is null,'Inconsistent years are rejected');
select pg_temp.assert_true(public.nces_school_year('2024') is null,'A calendar year is not guessed as a school year');
select pg_temp.upsert_fact(pg_temp.district_fact('0100005'));
select pg_temp.upsert_fact(pg_temp.district_fact('0100005'));
select pg_temp.upsert_fact(pg_temp.district_fact('1300005','Shared district name','GA','13'));
select pg_temp.upsert_fact(pg_temp.district_fact('1100087','DYRS','MD','11'));
select pg_temp.assert_true((select count(*)=1 from public.school_districts where nces_lea_id='0100005'),'Leading-zero LEA has one stable district identity');
select pg_temp.assert_true((select id='nces-lea:0100005' from public.school_districts where nces_lea_id='0100005'),'Stable district ID retains every identifier digit');
select pg_temp.assert_true((select count(*)=1 from public.school_district_sources where district_id='nces-lea:0100005'),'Repeated source import creates one observation');
select pg_temp.expect_error(format('select pg_temp.upsert_fact(%L::jsonb)',pg_temp.district_fact('0100005','Conflicting same-year name')),'23514');
select pg_temp.expect_error(format('select pg_temp.upsert_fact(%L::jsonb)',pg_temp.district_fact('0100005','Shared district name','GA','13')),'23514');
select pg_temp.expect_error(format('select pg_temp.upsert_fact(%L::jsonb)',pg_temp.district_fact('bad-id')),'23514');
select pg_temp.expect_error(format('select pg_temp.upsert_fact(%L::jsonb)',pg_temp.district_fact('0109999')||jsonb_build_object('source_year','2023-2025')),'23514');
select pg_temp.expect_error(format('select pg_temp.upsert_fact(%L::jsonb)',pg_temp.district_fact('0109999')||jsonb_build_object('source_url','https://unverified.example/districts')),'23514');

-- Keep observations from different years; reimporting older data cannot demote
-- the district's current fact or silently replace its immutable older record.
select pg_temp.upsert_fact(pg_temp.district_fact('0109999','Old official district name'));
select pg_temp.upsert_fact(pg_temp.district_fact('0109999','New official district name','AL','01','2025-2026'));
select pg_temp.upsert_fact(pg_temp.district_fact('0109999','Old official district name'));
select pg_temp.assert_true((select name='New official district name' and source_year='2025-2026' from public.school_districts where id='nces-lea:0109999'),'Older reimports do not downgrade current official facts');
select pg_temp.assert_true((select count(*)=2 from public.school_district_sources where district_id='nces-lea:0109999'),'Year-specific observations coexist');
select pg_temp.assert_true((select name='Old official district name' from public.school_district_sources where district_id='nces-lea:0109999' and source_year='2024-2025'),'Historical official evidence is retained');

insert into public.schools(id,name,latitude,longitude,state,classification,source,source_id,source_dataset,source_year,district) values
  ('010000500001','Phase 2 School A',-60,0,'AL','public','nces-public','010000500001','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025',null),
  ('130000500001','Phase 2 School B',-60,1,'GA','public','nces-public','130000500001','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025',null),
  ('110008700001','Phase 2 cross-office-state school',-60,2,'DC','public','nces-public','110008700001','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025',null),
  ('010000500002','Phase 2 unmatched school',-60,3,'AL','public','nces-public','010000500002','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025',null),
  ('010000500003','Phase 2 existing district text',-60,4,'AL','public','nces-public','010000500003','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025','Previously entered district'),
  ('010000500004','Phase 2 incompatible source year',-60,5,'AL','public','nces-public','010000500004','EDGE_GEOCODE_PUBLICSCH_2324','2023-2024',null),
  ('nces-private:phase2','Phase 2 independent private school',-60,6,'AL','private','nces-private','phase2','EDGE_GEOCODE_PRIVATESCH_2324','2023-2024',null);
insert into public.schools(id,name,latitude,longitude,state,classification,source,source_id,source_dataset,source_year,canonical_id)
  values('phase2-alias','Phase 2 legacy school alias',-60,0,'AL','public','nces-public','010000599999','EDGE_GEOCODE_PUBLICSCH_2425','2024-2025','010000500001');

create function pg_temp.relationship(p_school_id text,p_leaid text default '0100005',
  p_name text default 'Shared district name',p_district_state text default 'AL',p_school_op text default '01',
  p_district_op text default '01',p_year text default '2024-2025') returns jsonb language sql as $$
  select jsonb_build_object('school_id',s.id,'expected',to_jsonb(s),'relationship',jsonb_build_object(
    'ncessch',s.source_id,'leaid',p_leaid,'name',p_name,'school_state',btrim(s.state),
    'district_state',p_district_state,'school_opstfips',p_school_op,'district_opstfips',p_district_op,
    'source_year',p_year,'school_source_dataset','EDGE_GEOCODE_PUBLICSCH_'||substr(p_year,3,2)||right(p_year,2),
    'district_source_dataset','EDGE_GEOCODE_PUBLICLEA_'||substr(p_year,3,2)||right(p_year,2),
    'school_source_url','https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICSCH_'||substr(p_year,3,2)||right(p_year,2)||'/MapServer/0',
    'source_url','https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_'||substr(p_year,3,2)||right(p_year,2)||'/MapServer/0'))
  from public.schools s where s.id=p_school_id;
$$;
create function pg_temp.apply(p_plan jsonb) returns jsonb language sql as $$
  select public.apply_school_district_batch(jsonb_build_array(p_plan),'Phase 2 SQL reviewer',repeat('a',64));
$$;

-- Invalid joins never become inferred associations. Exact identifiers, school
-- location, operating jurisdiction, compatible years and snapshots are required.
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('nces-private:phase2')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('phase2-alias')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('010000500004')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('010000500003')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',jsonb_set(pg_temp.relationship('010000500002'),'{relationship,ncessch}','"010000599998"')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',jsonb_set(pg_temp.relationship('010000500002'),'{relationship,school_state}','"GA"')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',jsonb_set(pg_temp.relationship('010000500002'),'{relationship,district_opstfips}','"13"')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',jsonb_set(pg_temp.relationship('010000500002'),'{expected,state}','"GA"')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',jsonb_set(pg_temp.relationship('010000500002'),'{relationship}','{}')),'23514');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('010000500002','unknown-district')),'23514');
select pg_temp.expect_error($q$select public.apply_school_district_batch('[{"school_id":"no-such-school","expected":{},"relationship":{}}]','Phase 2 SQL reviewer',repeat('a',64))$q$,'P0001');
select pg_temp.expect_error(format('select public.apply_school_district_batch(%L::jsonb,''Phase 2 SQL reviewer'',repeat(''a'',64))',
  jsonb_build_array(pg_temp.relationship('010000500002'),jsonb_build_object('school_id','no-such-school','expected','{}'::jsonb,'relationship','{}'::jsonb))),'P0001');
select pg_temp.assert_true((select district_id is null from public.schools where id='010000500002'),'Unmatched public school remains unlinked');
select pg_temp.assert_true(not exists(select from private.school_district_link_history where school_id='010000500002'),'A failed batch rolls back preceding links and their audit records');
select pg_temp.assert_true((select district_id is null and classification='private' from public.schools where id='nces-private:phase2'),'Private school remains independent');

-- School/report identities and reported hazard coordinates survive linking.
insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,status,created_at) values
  ('60000000-0000-0000-0000-000000000001','010000500001',-60,0.00001,'blocked_path',3,'Phase 2 real-report SQL fixture A','verified',now()-interval '1 day'),
  ('60000000-0000-0000-0000-000000000002','130000500001',-60,1.00001,'blocked_path',3,'Phase 2 real-report SQL fixture B','verified',now()-interval '1 day'),
  ('60000000-0000-0000-0000-000000000003','010000500001',-60,0.00001,'blocked_path',3,'Phase 2 duplicate-report SQL fixture A','verified',now()-interval '1 day'),
  ('60000000-0000-0000-0000-000000000004','130000500001',-60,1.00001,'blocked_path',3,'Phase 2 pending-report SQL fixture B','unverified',now()-interval '1 day');
create temporary table phase2_original_reports as select id,to_jsonb(h) snapshot from public.hazard_reports h where id::text like '60000000-%';
create temporary table phase2_original_schools as select id,to_jsonb(s)-'district'-'district_id'-'district_source_year'-'district_source_dataset'-'district_link_metadata' snapshot
  from public.schools s where name like 'Phase 2%';
create temporary table phase2_plans(id text primary key,plan jsonb);
insert into phase2_plans values('A',pg_temp.relationship('010000500001')),
  ('B',pg_temp.relationship('130000500001','1300005','Shared district name','GA','13','13')),
  ('C',pg_temp.relationship('110008700001','1100087','DYRS','MD','11','11'));
select pg_temp.assert_true((pg_temp.apply((select plan from phase2_plans where id='A'))->>'applied')::int=1,'Verified LEA relationship applied');
select pg_temp.assert_true((pg_temp.apply((select plan from phase2_plans where id='B'))->>'applied')::int=1,'Same-name district in another state applied by ID');
select pg_temp.assert_true((pg_temp.apply((select plan from phase2_plans where id='C'))->>'applied')::int=1,'Verified operating jurisdiction accepts an office across physical state lines');
select pg_temp.assert_true((pg_temp.apply((select plan from phase2_plans where id='A'))->>'unchanged')::int=1,'Reviewed plan is resumable and idempotent');
select pg_temp.assert_true((select count(*)=1 from private.school_district_link_history where school_id='010000500001'),'Repeated plan audits the association once');
select pg_temp.assert_true((select count(*)=3 from private.school_district_link_history where school_id in ('010000500001','130000500001','110008700001')),'One audit per changed school');
select pg_temp.assert_true((select s.state='DC' and d.state='MD' and s.district_link_metadata->>'school_opstfips'=d.metadata->>'opstfips'
  from public.schools s join public.school_districts d on d.id=s.district_id where s.id='110008700001'),'Both physical states and verified jurisdiction remain distinct');
select pg_temp.assert_true((select bool_and(o.snapshot=to_jsonb(h)) from phase2_original_reports o join public.hazard_reports h using(id)),'Hazard IDs, authors, statuses and original coordinates are unchanged');
select pg_temp.assert_true((select bool_and(o.snapshot=to_jsonb(s)-'district'-'district_id'-'district_source_year'-'district_source_dataset'-'district_link_metadata') from phase2_original_schools o join public.schools s using(id)),'School IDs, classifications, geographic locations and import fields are unchanged');
select pg_temp.assert_true((select school_id='010000500001' from public.nearest_schools(-60,0.00001) limit 1),'Nearest-school assignment still uses original school geography');
select pg_temp.expect_error(format('select pg_temp.apply(%L::jsonb)',pg_temp.relationship('010000500001','1300005','Shared district name','GA','13','13')),'23514');
select pg_temp.expect_error($q$update public.schools set district_id='nces-lea:9999999' where id='010000500001'$q$,'23514');
select pg_temp.expect_error($q$delete from public.school_districts where id='nces-lea:0100005'$q$,'23503,23001');
select pg_temp.expect_error($q$delete from public.school_district_sources where district_id='nces-lea:0100005' and source_year='2024-2025'$q$,'23503,23001');

set local role anon;
select pg_temp.assert_true((select count(*)=2 from public.school_districts where name='Shared district name'),'Public district directory preserves same-name entities');
select pg_temp.assert_true((select count(*)=1 from public.school_district_sources where district_id='nces-lea:0100005'),'Public source observations are readable');
select pg_temp.assert_true(jsonb_array_length(public.analytics_district_options())>=3,'Normalized district filter options are public');
select pg_temp.assert_true((select count(*)=2 from jsonb_array_elements(public.analytics_district_options()) d where d->>'name'='Shared district name' and d->>'id' in ('nces-lea:0100005','nces-lea:1300005')),'Same-name options keep distinct stable IDs');
select pg_temp.assert_true((select s->>'district_id'='nces-lea:0100005' from jsonb_array_elements(public.search_analytics_schools('Phase 2 School A')) s),'School search exposes its normalized district ID');
do $$ declare a jsonb; b jsonb; legacy jsonb; empty_data jsonb; begin
  a:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_districts=>array['nces-lea:0100005']);
  b:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_districts=>array['nces-lea:1300005']);
  legacy:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_districts=>array['Shared district name']);
  empty_data:=public.get_hazard_analytics(p_to=>now()+interval '1 second',p_districts=>array['nces-lea:9999999']);
  assert (a->'summary'->>'total')::int=1,'District A has one deduplicated hazard';
  assert (a->'deduplication'->>'raw_reports')::int=2 and (a->'deduplication'->>'duplicates_removed')::int=1,'District filters preserve existing deduplication';
  assert (b->'summary'->>'total')::int=1 and (b->'deduplication'->>'raw_reports')::int=1,'District B excludes A and its own private pending report';
  assert (legacy->'summary'->>'total')::int=2,'Legacy district name filters retain their existing behavior';
  assert (empty_data->'summary'->>'total')::int=0,'Unknown normalized district IDs do not match another district';
  assert not exists(select from jsonb_array_elements(a->'markers') m where m->>'school_id'<>'010000500001' or (m->>'longitude')::float8<>0.00001),'Normalized district filter retains actual hazard coordinates';
  assert (a->'schools'->0->>'district_id')='nces-lea:0100005','Analytics school rollups expose stable district identity';
  assert not exists(select from jsonb_array_elements(a->'markers') m where m ? 'reporter_id' or m ? 'description'),'District analytics preserve aggregate privacy';
end $$;
select pg_temp.expect_error('insert into public.school_districts default values','42501');
select pg_temp.expect_error('update public.school_district_sources set name=''Unauthorized''','42501');
select pg_temp.expect_error($q$select public.upsert_nces_district_sources('[]','Unauthorized',repeat('a',64))$q$,'42501');
select pg_temp.expect_error($q$select public.apply_school_district_batch('[]','Unauthorized',repeat('a',64))$q$,'42501');
select pg_temp.expect_error($q$select public.sync_nces_school_batch('[]','[]','Unauthorized',repeat('a',64),'{}')$q$,'42501');
select pg_temp.expect_error('select * from private.school_district_link_history','42501');
reset role;
set local role authenticated;
select pg_temp.assert_true((select count(*)=2 from public.school_districts where name='Shared district name'),'Authenticated directory access works');
select pg_temp.expect_error('update public.schools set district_id=null','42501');
select pg_temp.expect_error($q$select public.apply_school_district_batch('[]','Unauthorized',repeat('a',64))$q$,'42501');
select pg_temp.expect_error($q$select public.sync_nces_school_batch('[]','[]','Unauthorized',repeat('a',64),'{}')$q$,'42501');
select pg_temp.expect_error('select * from private.school_district_link_history','42501');
reset role;

-- Future school imports use the same stable school row and retain immutable
-- district observations. A real LEA transfer needs an explicit reviewed allowlist.
create function pg_temp.school_payload(p_school_id text,p_district_id text,p_name text,
  p_year text default '2024-2025') returns jsonb language sql as $$
  select (to_jsonb(s)-'location')||jsonb_build_object('district_id',p_district_id,'district',p_name,
    'source_year',p_year,'source_dataset','EDGE_GEOCODE_PUBLICSCH_'||substr(p_year,3,2)||right(p_year,2),
    'district_source_year',p_year,'district_source_dataset','EDGE_GEOCODE_PUBLICSCH_'||substr(p_year,3,2)||right(p_year,2),
    'district_link_metadata',jsonb_build_object('ncessch',s.source_id,'school_state',btrim(s.state),
      'school_opstfips','01','school_source_url','https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICSCH_'||substr(p_year,3,2)||right(p_year,2)||'/MapServer/0',
      'district_source_url','https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_'||substr(p_year,3,2)||right(p_year,2)||'/MapServer/0'))
  from public.schools s where s.id=p_school_id;
$$;
create function pg_temp.sync_school(p_school jsonb,p_facts jsonb default '[]',p_allow text[] default '{}')
returns int language sql as $$
  select public.sync_nces_school_batch(jsonb_build_array(p_school),p_facts,'Reviewed future import',repeat('b',64),p_allow);
$$;
select pg_temp.assert_true(pg_temp.sync_school(pg_temp.school_payload('010000500001','nces-lea:0100005','Shared district name'),jsonb_build_array(pg_temp.district_fact('0100005')))=1,'A repeated importer batch retains the original school ID');
select pg_temp.assert_true((select count(*)=1 from private.school_district_link_history where school_id='010000500001'),'A repeated importer batch does not duplicate district audit');
select pg_temp.expect_error(format('select pg_temp.sync_school(%L::jsonb)',(select to_jsonb(s)-'location' from public.schools s where id='010000500002')),'23514');
select pg_temp.assert_true(pg_temp.sync_school((select to_jsonb(s)-'location' from public.schools s where id='nces-private:phase2'))=1,'A private-school import remains supported without public district assignment');
select pg_temp.assert_true((select district_id is null and district_source_year is null from public.schools where id='nces-private:phase2'),'Private imports keep all public district provenance empty');
create temporary table phase2_transfer as select
  pg_temp.school_payload('010000500001','nces-lea:0100006','Next official district','2025-2026') payload,
  jsonb_build_array(pg_temp.district_fact('0100006','Next official district','AL','01','2025-2026')) facts;
select pg_temp.expect_error(format('select pg_temp.sync_school(%L::jsonb,%L::jsonb)',(select payload from phase2_transfer),(select facts from phase2_transfer)),'23514');
select pg_temp.assert_true((select district_id='nces-lea:0100005' from public.schools where id='010000500001'),'An unapproved future transfer leaves the existing relationship unchanged');
select pg_temp.assert_true(pg_temp.sync_school((select payload from phase2_transfer),(select facts from phase2_transfer),array['010000500001'])=1,'An explicitly approved future transfer is applied to the existing stable school ID');
select pg_temp.assert_true((select district_id='nces-lea:0100006' and district_source_year='2025-2026' from public.schools where id='010000500001'),'Future relationship uses its own source year');
select pg_temp.assert_true((select count(*)=2 from private.school_district_link_history where school_id='010000500001'),'An approved transfer appends one review audit');
select pg_temp.assert_true((select count(*)=1 from public.school_district_sources where district_id='nces-lea:0100005' and source_year='2024-2025'),'A transfer preserves the previous district source observation');
select pg_temp.assert_true((select bool_and(o.snapshot=to_jsonb(h)) from phase2_original_reports o join public.hazard_reports h using(id)),'Repeated imports and approved district transfers preserve hazard foreign keys and coordinates');
-- The real Data API importer runs as service_role, not as the database owner.
set local role service_role;
select pg_temp.assert_true((pg_temp.apply(pg_temp.relationship('010000500002'))->>'applied')::int=1,
  'Server service role can import a verified relationship through the private audit trigger');
select pg_temp.expect_error('select * from private.school_district_link_history','42501');
reset role;
rollback;
