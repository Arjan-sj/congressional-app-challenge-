-- ONLY a separately provisioned staging/local database. Never production.
-- psql "$env:SAFEROUTES_DATABASE_URL" -v environment=staging -v project_id=REF -f supabase/testing/enroll.sql
\set ON_ERROR_STOP on
begin;
create temporary table enrollment_input (
  environment text not null check(environment in ('staging','local')),
  project_id text not null check(project_id<>'bnvmlxgdqgwjtxgtsaak'),
  check((environment='local' and project_id='local') or (environment='staging' and project_id ~ '^[a-z]{20}$'))
) on commit drop;
insert into enrollment_input values(:'environment',:'project_id');
do $$ begin
  if exists(select from private.hazard_test_control where active_run is not null) then
    raise exception 'Finish the active operation before changing enrollment';
  end if;
  update private.hazard_test_control c set environment=i.environment,project_id=i.project_id
    from enrollment_input i;
end $$;
commit;
