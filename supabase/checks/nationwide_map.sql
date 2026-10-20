-- Run as postgres against a migrated database. Read-only assertions; transaction
-- rolls back role/session changes. Works with empty or nationally populated data.
begin;
do $$
declare data jsonb; expected bigint; represented bigint;
begin
  select count(*) into expected from public.schools where canonical_id is null;
  data := public.schools_in_view(-90,-180,90,180,5);
  select coalesce(sum(coalesce((r->>'count')::int,1)),0) into represented
    from jsonb_array_elements(data->'items') r;
  assert (data->>'total')::bigint=expected, 'Nationwide total mismatch';
  assert represented=expected, 'Clustering dropped schools';
  assert jsonb_array_length(data->'items')<=500, 'Unbounded cluster response';
  data := public.schools_in_view(50,170,72,-160,5);
  select count(*) into expected from public.schools where canonical_id is null
    and latitude between 50 and 72 and (longitude>=170 or longitude<=-160);
  assert (data->>'total')::bigint=expected, 'Antimeridian mismatch';
  data := public.schools_in_view(40.6,-74.1,40.9,-73.7,19,5);
  select coalesce(sum(coalesce((r->>'count')::int,1)),0) into represented
    from jsonb_array_elements(data->'items') r;
  assert represented=(data->>'total')::bigint, 'Dense high zoom silently truncated';
  assert jsonb_array_length(data->'items')<=5, 'Dense response exceeds budget';
  data := public.schools_in_view(-90,-180,90,180,5,500,'private');
  select count(*) into expected from public.schools where canonical_id is null and classification='private';
  assert (data->>'total')::bigint=expected, 'Classification mismatch';
  assert public.infrastructure_in_view(20,-120,70,-60,array['crossing'],5)='[]', 'Broad infrastructure fetched';
  assert jsonb_array_length(public.school_members_in_view(-90,-180,90,180))<=100, 'School detail paging failed';
  assert not exists(select 1 from pg_proc where pronamespace='public'::regnamespace
    and proname in ('schools_in_view','hazards_in_view','infrastructure_in_view','school_members_in_view') and prosecdef), 'Map RPC bypasses RLS';
end $$;
set local role anon;
do $$
declare result jsonb;
begin
  result := public.hazards_in_view(-90,-180,90,180,15);
  assert not exists(select 1 from jsonb_array_elements(result->'items') r where r->>'status' not in ('verified','resolved')), 'Anonymous RPC leaked private reports';
  assert not has_table_privilege('anon','public.schools','insert'), 'Public school write access';
  assert not has_function_privilege('anon','public.claim_map_provider(text)','execute'), 'Public cache writes';
end $$;
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000021',true);
set local role authenticated;
do $$
declare result jsonb;
begin
  result := public.hazards_in_view(-90,-180,90,180,15);
  assert not exists(select 1 from jsonb_array_elements(result->'items') r
    where r->>'status' not in ('verified','resolved') and r->>'reporter_id' is distinct from '00000000-0000-0000-0000-000000000021'), 'Member RPC leaked another author report';
end $$;
rollback;
