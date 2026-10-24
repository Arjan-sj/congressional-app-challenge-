-- Additive Phase 2 schema/RPCs only. No schools or district facts are backfilled.
create table public.school_districts (
  id text primary key check(id='nces-lea:'||nces_lea_id),
  nces_lea_id text not null unique check(nces_lea_id ~ '^[0-9]{7}$' and nces_lea_id<>'0000000'),
  name text not null check(char_length(btrim(name)) between 1 and 500),
  state text not null check(state ~ '^[A-Z]{2}$'),
  source_dataset text not null,
  source_year text not null check(source_year ~ '^20[0-9]{2}-20[0-9]{2}$'),
  source_url text not null check(source_url ~ '^https://nces[.]ed[.]gov/'),
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Keep immutable year-specific official observations. A district's current name
-- may change without erasing the evidence supporting older school relationships.
create table public.school_district_sources (
  district_id text not null references public.school_districts(id) on delete restrict,
  source_year text not null,
  name text not null check(char_length(btrim(name)) between 1 and 500),
  state text not null check(state ~ '^[A-Z]{2}$'),
  source_dataset text not null,
  source_url text not null check(source_url ~ '^https://nces[.]ed[.]gov/'),
  metadata jsonb not null default '{}',
  observed_at timestamptz not null default now(),
  primary key(district_id,source_year)
);
alter table public.schools
  add column district_id text references public.school_districts(id) on delete restrict,
  add column district_source_year text,
  add column district_source_dataset text,
  add column district_link_metadata jsonb,
  add constraint schools_district_observation_fkey foreign key(district_id,district_source_year)
    references public.school_district_sources(district_id,source_year) match full on delete restrict;
create index schools_district_id_idx on public.schools(district_id) where district_id is not null;
create index school_districts_state_name_idx on public.school_districts(state,name,id);
create index school_district_sources_year_idx on public.school_district_sources(source_year,district_id);
alter table public.school_districts enable row level security;
alter table public.school_district_sources enable row level security;
revoke all on public.school_districts,public.school_district_sources from public,anon,authenticated;
grant select on public.school_districts,public.school_district_sources to anon,authenticated;
grant select,insert,update on public.school_districts,public.schools to service_role;
grant select,insert on public.school_district_sources to service_role;
create policy "Public official district directory" on public.school_districts for select to anon,authenticated using(true);
create policy "Public district source observations" on public.school_district_sources for select to anon,authenticated using(true);

create table private.school_district_link_history (
  id uuid primary key default gen_random_uuid(),
  school_id text not null references public.schools(id) on delete restrict,
  previous_district_id text,
  district_id text,
  previous_source_year text,
  source_year text,
  reviewed_by text not null,
  plan_sha256 text not null,
  created_at timestamptz not null default now()
);
alter table private.school_district_link_history enable row level security;
revoke all on private.school_district_link_history from public,anon,authenticated,service_role;

create function public.nces_school_year(p_value text) returns text
language plpgsql immutable security invoker set search_path='' as $$
declare a int; b int;
begin
  if btrim(p_value) ~ '^[0-9]{4}$' then
    a:=2000+left(btrim(p_value),2)::int; b:=2000+right(btrim(p_value),2)::int;
  elsif btrim(p_value) ~ '^20[0-9]{2}-20[0-9]{2}$' then
    a:=left(btrim(p_value),4)::int; b:=right(btrim(p_value),4)::int;
  else return null; end if;
  if b<>a+1 then return null; end if;
  return a::text||'-'||b::text;
end $$;
revoke all on function public.nces_school_year(text) from public;
grant execute on function public.nces_school_year(text) to anon,authenticated,service_role;
alter table public.school_districts add constraint school_districts_consecutive_year
  check(public.nces_school_year(source_year) is not null and public.nces_school_year(source_year)=source_year);
alter table public.school_district_sources add constraint school_district_sources_consecutive_year
  check(public.nces_school_year(source_year) is not null and public.nces_school_year(source_year)=source_year);

create function private.validate_school_district() returns trigger
language plpgsql security invoker set search_path='' as $$
declare observation public.school_district_sources;
begin
  if new.district_id is null then
    if new.district_source_year is not null or new.district_source_dataset is not null or new.district_link_metadata is not null then
      raise exception 'District provenance requires an actual district relationship' using errcode='23514';
    end if;
    return new;
  end if;
  select * into observation from public.school_district_sources
    where district_id=new.district_id and source_year=new.district_source_year;
  if not found or new.classification<>'public' or new.canonical_id is not null
    or new.source is distinct from 'nces-public' or new.source_id is null or new.source_id !~ '^[0-9]{12}$' or new.source_id='000000000000'
    or public.nces_school_year(new.source_year) is distinct from new.district_source_year
    or new.district_source_dataset is distinct from new.source_dataset
    or new.source_dataset is distinct from 'EDGE_GEOCODE_PUBLICSCH_'||substr(new.district_source_year,3,2)||right(new.district_source_year,2)
    or new.district_link_metadata->>'ncessch' is distinct from new.source_id
    or new.district_link_metadata->>'school_state' is distinct from btrim(new.state)
    or new.district_link_metadata->>'school_opstfips' is distinct from observation.metadata->>'opstfips'
    or new.district_link_metadata->>'school_opstfips' !~ '^[0-9]{2}$' then
    raise exception 'District link requires a verified public NCES identity, year, physical school state and operating jurisdiction' using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function private.validate_school_district() from public,anon,authenticated,service_role;
create trigger validate_school_district before insert or update of district_id,district_source_year,
  district_source_dataset,district_link_metadata,classification,canonical_id,state,source,source_id,source_year,source_dataset
  on public.schools for each row execute function private.validate_school_district();

create function private.audit_school_district_link() returns trigger
language plpgsql security definer set search_path='' as $$
declare previous_id text; previous_year text; reviewer text; plan text;
begin
  if tg_op='UPDATE' then
    if new.district_id is not distinct from old.district_id and new.district_source_year is not distinct from old.district_source_year
      and new.district_source_dataset is not distinct from old.district_source_dataset
      and new.district_link_metadata is not distinct from old.district_link_metadata then return new; end if;
    previous_id:=old.district_id; previous_year:=old.district_source_year;
  elsif new.district_id is null then return new;
  end if;
  reviewer:=btrim(current_setting('saferoutes.district_reviewed_by',true));
  plan:=current_setting('saferoutes.district_plan_sha256',true);
  if reviewer is null or char_length(reviewer)<3 or plan is null or plan !~ '^[0-9a-f]{64}$' then
    raise exception 'A reviewed source plan and reviewer are required for district changes' using errcode='42501';
  end if;
  insert into private.school_district_link_history(school_id,previous_district_id,district_id,previous_source_year,source_year,reviewed_by,plan_sha256)
    values(new.id,previous_id,new.district_id,previous_year,new.district_source_year,reviewer,plan);
  return new;
end $$;
revoke all on function private.audit_school_district_link() from public,anon,authenticated,service_role;
create trigger audit_school_district_link after insert or update on public.schools
  for each row execute function private.audit_school_district_link();

create function public.upsert_nces_district_sources(p_rows jsonb,p_reviewed_by text,p_plan_sha256 text)
returns void language plpgsql security invoker set search_path='' as $$
declare r jsonb; district_key text; year text; previous public.school_district_sources;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)>500
    or char_length(btrim(coalesce(p_reviewed_by,'')))<3 or p_plan_sha256 is null or p_plan_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'A bounded reviewed district source batch is required' using errcode='22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    district_key:='nces-lea:'||(r->>'nces_lea_id'); year:=public.nces_school_year(r->>'source_year');
    if r->>'id' is distinct from district_key or r->>'nces_lea_id' !~ '^[0-9]{7}$' or year is null
      or r->>'state' !~ '^[A-Z]{2}$' or char_length(btrim(coalesce(r->>'name',''))) not between 1 and 500
      or r->>'source_url' !~ '^https://nces[.]ed[.]gov/'
      or r->>'source_dataset' is distinct from 'EDGE_GEOCODE_PUBLICLEA_'||substr(year,3,2)||right(year,2)
      or r->'metadata'->>'opstfips' is null or r->'metadata'->>'opstfips' !~ '^[0-9]{2}$' then
      raise exception 'Invalid official NCES district observation' using errcode='23514';
    end if;
    select * into previous from public.school_district_sources where district_id=district_key and source_year=year;
    if found and (previous.name is distinct from r->>'name' or previous.state is distinct from r->>'state'
      or previous.source_dataset is distinct from r->>'source_dataset'
      or previous.source_url is distinct from r->>'source_url'
      or previous.metadata->>'opstfips' is distinct from r->'metadata'->>'opstfips') then
      raise exception 'Conflicting same-year district source; review a separate correction: %',district_key using errcode='23514';
    end if;
    insert into public.school_districts(id,nces_lea_id,name,state,source_dataset,source_year,source_url,metadata)
      values(district_key,r->>'nces_lea_id',r->>'name',r->>'state',r->>'source_dataset',year,r->>'source_url',r->'metadata')
      on conflict(id) do update set name=excluded.name,state=excluded.state,source_dataset=excluded.source_dataset,
        source_year=excluded.source_year,source_url=excluded.source_url,metadata=excluded.metadata,updated_at=now()
        where public.school_districts.source_year<excluded.source_year;
    insert into public.school_district_sources(district_id,source_year,name,state,source_dataset,source_url,metadata)
      values(district_key,year,r->>'name',r->>'state',r->>'source_dataset',r->>'source_url',r->'metadata')
      on conflict(district_id,source_year) do nothing;
  end loop;
end $$;
revoke all on function public.upsert_nces_district_sources(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.upsert_nces_district_sources(jsonb,text,text) to service_role;

create function public.apply_school_district_batch(p_rows jsonb,p_reviewed_by text,p_plan_sha256 text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r jsonb; e jsonb; rel jsonb; h public.schools; key text; facts jsonb; already boolean;
  applied int:=0; unchanged int:=0;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)>500
    or char_length(btrim(coalesce(p_reviewed_by,'')))<3 or p_plan_sha256 is null or p_plan_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'A bounded reviewed school district batch is required' using errcode='22023';
  end if;
  perform set_config('saferoutes.district_reviewed_by',btrim(p_reviewed_by),true);
  perform set_config('saferoutes.district_plan_sha256',p_plan_sha256,true);
  for r in select value from jsonb_array_elements(p_rows) loop
    e:=r->'expected'; rel:=r->'relationship'; key:='nces-lea:'||(rel->>'leaid');
    select * into h from public.schools where id=r->>'school_id' for update;
    if not found then raise exception 'School no longer exists: %',r->>'school_id'; end if;
    already:=h.district_id=key and h.district_source_year=rel->>'source_year';
    if h.classification<>'public' or h.canonical_id is not null or h.source is distinct from 'nces-public'
      or h.source_id is distinct from rel->>'ncessch' or h.source_id !~ '^[0-9]{12}$'
      or btrim(h.state) is distinct from rel->>'school_state'
      or public.nces_school_year(h.source_year) is distinct from rel->>'source_year'
      or h.source_dataset is distinct from rel->>'school_source_dataset'
      or rel->>'school_source_url' !~ '^https://nces[.]ed[.]gov/'
      or rel->>'school_opstfips' is distinct from rel->>'district_opstfips'
      or rel->>'school_opstfips' is null or rel->>'school_opstfips' !~ '^[0-9]{2}$'
      or h.classification is distinct from e->>'classification' or h.canonical_id is distinct from e->>'canonical_id'
      or h.source is distinct from e->>'source' or h.source_id is distinct from e->>'source_id'
      or h.source_dataset is distinct from e->>'source_dataset' or h.source_year is distinct from e->>'source_year'
      or h.state is distinct from e->>'state' then
      raise exception 'School/source identity, state, year or expected snapshot mismatch: %',h.id using errcode='23514';
    end if;
    if not coalesce(already,false) and (h.district_id is not null or h.district_id is distinct from e->>'district_id'
      or h.district_source_year is distinct from e->>'district_source_year'
      or h.district is distinct from e->>'district'
      or (nullif(btrim(h.district),'') is not null and h.district<>rel->>'name')) then
      raise exception 'Existing district relationship/text requires a separately reviewed change: %',h.id using errcode='23514';
    end if;
    facts:=jsonb_build_array(jsonb_build_object('id',key,'nces_lea_id',rel->>'leaid','name',rel->>'name',
      'state',rel->>'district_state','source_year',rel->>'source_year','source_dataset',rel->>'district_source_dataset',
      'source_url',rel->>'source_url','metadata',jsonb_build_object('opstfips',rel->>'district_opstfips')));
    perform public.upsert_nces_district_sources(facts,p_reviewed_by,p_plan_sha256);
    if coalesce(already,false) then
      if h.district_link_metadata->>'ncessch' is distinct from rel->>'ncessch'
        or h.district_link_metadata->>'school_opstfips' is distinct from rel->>'school_opstfips'
        or h.district_link_metadata->>'school_state' is distinct from rel->>'school_state'
        or h.district is distinct from rel->>'name' then
        raise exception 'Previously linked school changed after the reviewed plan: %',h.id using errcode='23514';
      end if;
      unchanged:=unchanged+1; continue;
    end if;
    update public.schools set district_id=key,district=rel->>'name',district_source_year=rel->>'source_year',
      district_source_dataset=rel->>'school_source_dataset',district_link_metadata=jsonb_build_object(
        'ncessch',rel->>'ncessch','school_state',rel->>'school_state','school_opstfips',rel->>'school_opstfips',
        'school_source_url',rel->>'school_source_url','district_source_url',rel->>'source_url') where id=h.id;
    applied:=applied+1;
  end loop;
  return jsonb_build_object('applied',applied,'unchanged',unchanged);
end $$;
revoke all on function public.apply_school_district_batch(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.apply_school_district_batch(jsonb,text,text) to service_role;

create function public.analytics_district_options() returns jsonb
language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.name,x.state,x.id),'[]') from (
    select d.id,d.name,d.state,d.source_year,count(*)::int school_count,false legacy
      from public.school_districts d join public.schools s on s.district_id=d.id
      where s.canonical_id is null and s.classification='public' group by d.id
    union all
    select s.district,s.district,null,null,count(*)::int,true
      from public.schools s where s.canonical_id is null and s.district_id is null and nullif(btrim(s.district),'') is not null
      group by s.district
  ) x;
$$;
revoke all on function public.analytics_district_options() from public;
grant execute on function public.analytics_district_options() to anon,authenticated,service_role;

-- Future nationwide imports update geographic fields and verified district
-- provenance together. A district transfer/manual-text conflict needs an
-- explicit reviewed school-ID allowlist; missing facts never clear a link.
create function public.sync_nces_school_batch(p_schools jsonb,p_districts jsonb,p_reviewed_by text,
  p_plan_sha256 text,p_approved_school_ids text[] default '{}')
returns integer language plpgsql security invoker set search_path='' as $$
declare r jsonb; h public.schools; previous public.schools; previous_name text; total int:=0;
begin
  if jsonb_typeof(p_schools) is distinct from 'array' or jsonb_array_length(p_schools)>500 then
    raise exception 'A bounded reviewed NCES school batch is required' using errcode='22023'; end if;
  perform public.upsert_nces_district_sources(p_districts,p_reviewed_by,p_plan_sha256);
  perform set_config('saferoutes.district_reviewed_by',btrim(p_reviewed_by),true);
  perform set_config('saferoutes.district_plan_sha256',p_plan_sha256,true);
  for r in select value from jsonb_array_elements(p_schools) loop
    h:=jsonb_populate_record(null::public.schools,r);
    if h.id is null or h.source_id is null or h.source is distinct from 'nces-'||h.classification
      or (h.classification='public' and (h.source_id !~ '^[0-9]{12}$' or h.id<>h.source_id))
      or (h.classification='private' and h.id<>'nces-private:'||h.source_id) then
      raise exception 'Invalid stable NCES school identity' using errcode='23514';
    end if;
    select * into previous from public.schools where id=h.id for update;
    if found then
      if public.nces_school_year(h.source_year)<public.nces_school_year(previous.source_year) then
        raise exception 'An older NCES release cannot replace a newer school observation: %',h.id using errcode='23514';
      end if;
      if previous.canonical_id is not null or previous.classification<>h.classification
        or (previous.source_id is not null and previous.source_id<>h.source_id) then
        raise exception 'Existing school identity/classification cannot be replaced: %',h.id using errcode='23514';
      end if;
      select name into previous_name from public.school_district_sources
        where district_id=previous.district_id and source_year=previous.district_source_year;
      if (previous.district_id is not null and h.district_id is distinct from previous.district_id)
        or (nullif(btrim(previous.district),'') is not null and h.district is not null and previous.district<>h.district
          and (previous.district_id is null or previous.district is distinct from previous_name)) then
        if not (h.id=any(coalesce(p_approved_school_ids,'{}'))) then
          raise exception 'Review the district transfer/manual-text conflict before importing school %',h.id using errcode='23514';
        end if;
      end if;
    end if;
    if h.classification='public' and h.district_id is null then
      raise exception 'Public imports require compatible explicit district facts; do not silently drop a relationship' using errcode='23514';
    end if;
    insert into public.schools(id,name,address,latitude,longitude,district,city,state,zip_code,classification,
      source,source_id,source_dataset,source_year,synced_at,district_id,district_source_year,district_source_dataset,district_link_metadata)
    values(h.id,h.name,h.address,h.latitude,h.longitude,h.district,h.city,h.state,h.zip_code,h.classification,
      h.source,h.source_id,h.source_dataset,h.source_year,h.synced_at,h.district_id,h.district_source_year,h.district_source_dataset,h.district_link_metadata)
    on conflict(id) do update set name=excluded.name,address=excluded.address,latitude=excluded.latitude,longitude=excluded.longitude,
      district=coalesce(excluded.district,public.schools.district),city=excluded.city,state=excluded.state,zip_code=excluded.zip_code,
      classification=excluded.classification,source=excluded.source,source_id=excluded.source_id,source_dataset=excluded.source_dataset,
      source_year=excluded.source_year,synced_at=excluded.synced_at,district_id=excluded.district_id,
      district_source_year=excluded.district_source_year,district_source_dataset=excluded.district_source_dataset,
      district_link_metadata=excluded.district_link_metadata;
    total:=total+1;
  end loop;
  return total;
end $$;
revoke all on function public.sync_nces_school_batch(jsonb,jsonb,text,text,text[]) from public,anon,authenticated;
grant execute on function public.sync_nces_school_batch(jsonb,jsonb,text,text,text[]) to service_role;

create or replace function public.search_analytics_schools(p_query text default '',p_after_id text default '',p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]') from (
    select s.id,s.name,coalesce(d.name,s.district) district,s.district_id,s.city,s.state,s.zip_code,s.latitude,s.longitude
    from public.schools s left join public.school_districts d on d.id=s.district_id
    where s.canonical_id is null and s.id>coalesce(p_after_id,'') and char_length(btrim(p_query))<=120
      and (btrim(p_query)='' or s.name ilike '%'||btrim(p_query)||'%' or coalesce(d.name,s.district) ilike '%'||btrim(p_query)||'%'
        or s.city ilike '%'||btrim(p_query)||'%' or s.state ilike '%'||btrim(p_query)||'%' or s.zip_code ilike btrim(p_query)||'%')
    order by s.id limit least(greatest(coalesce(p_limit,100),1),500)
  ) x;
$$;

-- Keep Phase 1 resets from overlooking the new independent district datasets.
create or replace function private.hazard_test_preserved_state() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare t text; fingerprint jsonb; result jsonb:='{}';
begin
  foreach t in array array['public.schools','public.school_districts','public.school_district_sources',
    'public.map_infrastructure','public.map_provider_cache','auth.users','public.report_moderators','supabase_migrations.schema_migrations'] loop
    if to_regclass(t) is null then result:=result||jsonb_build_object(t,null);
    else
      execute format('select jsonb_build_object(''count'',count(*),''digest'',md5(coalesce(string_agg(hash,'''' order by hash),'''')))
        from (select md5(to_jsonb(r)::text) hash from %s r) q',to_regclass(t)) into fingerprint;
      result:=result||jsonb_build_object(t,fingerprint);
    end if;
  end loop;
  return result;
end $$;
revoke all on function private.hazard_test_preserved_state() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';

-- Existing API and statistics remain; new clients filter duplicate names by ID.
create or replace function public.get_hazard_analytics(
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_bucket text default 'day',
  p_school_ids text[] default null,
  p_districts text[] default null,
  p_types text[] default null,
  p_severities smallint[] default null,
  p_statuses text[] default null,
  p_min_lat double precision default null,
  p_min_lng double precision default null,
  p_max_lat double precision default null,
  p_max_lng double precision default null,
  p_limit integer default 500,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_from timestamptz := coalesce(p_from, now() - interval '30 days');
  v_to timestamptz := coalesce(p_to, now());
  v_duration interval;
  v_previous_from timestamptz;
  v_bucket text := lower(coalesce(p_bucket, 'day'));
  v_limit integer := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_from >= v_to then
    raise exception 'p_from must be earlier than p_to' using errcode = '22023';
  end if;
  if v_bucket not in ('day', 'week', 'month') then
    raise exception 'p_bucket must be day, week, or month' using errcode = '22023';
  end if;
  if (p_min_lat is null) <> (p_max_lat is null)
     or (p_min_lng is null) <> (p_max_lng is null) then
    raise exception 'geographic bounds require all four coordinates' using errcode = '22023';
  end if;
  if p_min_lat is not null and (p_min_lat > p_max_lat or p_min_lng > p_max_lng) then
    raise exception 'minimum geographic bounds must not exceed maximum bounds' using errcode = '22023';
  end if;

  v_duration := v_to - v_from;
  v_previous_from := v_from - v_duration;

  with visible as materialized (
    select
      h.id,
      s.id as school_id,
      s.district_id,
      h.type,
      h.severity,
      h.status,
      h.latitude,
      h.longitude,
      h.created_at,
      h.resolved_at,
      s.name as school_name,
      coalesce(d.name,s.district, 'District unavailable') as district,
      s.city,
      s.state,
      s.latitude as school_latitude,
      s.longitude as school_longitude
    from public.hazard_reports h
    join public.schools original_school on original_school.id = h.school_id
    join public.schools s on s.id = coalesce(original_school.canonical_id, original_school.id)
    left join public.school_districts d on d.id=s.district_id
    where h.is_demo = false
      and h.created_at >= v_previous_from
      and h.created_at < v_to
      and (p_school_ids is null or s.id in (select coalesce(fs.canonical_id,fs.id)
        from public.schools fs where fs.id=any(p_school_ids)))
      and (p_districts is null or s.district_id=any(p_districts) or s.district=any(p_districts) or d.name=any(p_districts))
      and (p_types is null or h.type = any(p_types))
      and (p_severities is null or h.severity = any(p_severities))
      and (p_statuses is null or h.status = any(p_statuses))
      and (p_min_lat is null or (
        h.latitude between p_min_lat and p_max_lat
        and h.longitude between p_min_lng and p_max_lng
      ))
  ),
  ranked as materialized (
    select
      v.*,
      min(v.created_at) over (
        partition by v.school_id, v.type,
          round(v.latitude::numeric, 4), round(v.longitude::numeric, 4),
          case when v.created_at >= v_from then 1 else 0 end
      ) as first_reported_at,
      count(*) over (
        partition by v.school_id, v.type,
          round(v.latitude::numeric, 4), round(v.longitude::numeric, 4),
          case when v.created_at >= v_from then 1 else 0 end
      )::integer as duplicate_count,
      row_number() over (
        partition by v.school_id, v.type,
          round(v.latitude::numeric, 4), round(v.longitude::numeric, 4),
          case when v.created_at >= v_from then 1 else 0 end
        order by
          case v.status
            when 'verified' then 4
            when 'unverified' then 3
            when 'resolved' then 2
            else 1
          end desc,
          v.severity desc,
          v.created_at desc,
          v.id
      ) as cluster_rank
    from visible v
  ),
  canonical as materialized (
    select * from ranked where cluster_rank = 1
  ),
  current_hazards as materialized (
    select * from canonical where created_at >= v_from
  ),
  previous_hazards as materialized (
    select * from canonical where created_at < v_from
  ),
  current_summary as (
    select
      count(*)::integer as total,
      count(*) filter (where status = 'unverified')::integer as pending,
      count(*) filter (where status = 'verified')::integer as verified,
      count(*) filter (where status = 'resolved')::integer as resolved,
      count(*) filter (where status = 'rejected')::integer as rejected,
      count(*) filter (
        where severity >= 4 and status not in ('resolved', 'rejected')
      )::integer as high_priority,
      count(distinct school_id)::integer as affected_schools,
      coalesce(sum(duplicate_count), 0)::integer as raw_reports,
      coalesce(sum(duplicate_count - 1), 0)::integer as duplicates_removed,
      round(
        100.0 * count(*) filter (where status = 'resolved')
        / nullif(count(*) filter (where status <> 'rejected'), 0),
        1
      ) as resolution_rate,
      round(avg(
        extract(epoch from (resolved_at - first_reported_at)) / 3600.0
      ) filter (where status = 'resolved' and resolved_at is not null), 1)
        as average_resolution_hours
    from current_hazards
  ),
  previous_summary as (
    select
      count(*)::integer as total,
      count(*) filter (where status = 'unverified')::integer as pending,
      count(*) filter (where status = 'verified')::integer as verified,
      count(*) filter (where status = 'resolved')::integer as resolved,
      count(*) filter (where status = 'rejected')::integer as rejected,
      count(*) filter (
        where severity >= 4 and status not in ('resolved', 'rejected')
      )::integer as high_priority,
      count(distinct school_id)::integer as affected_schools,
      round(
        100.0 * count(*) filter (where status = 'resolved')
        / nullif(count(*) filter (where status <> 'rejected'), 0),
        1
      ) as resolution_rate,
      round(avg(
        extract(epoch from (resolved_at - first_reported_at)) / 3600.0
      ) filter (where status = 'resolved' and resolved_at is not null), 1)
        as average_resolution_hours
    from previous_hazards
  ),
  trend as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'period', bucket,
      'total', total,
      'pending', pending,
      'verified', verified,
      'resolved', resolved
    ) order by bucket), '[]'::jsonb) as value
    from (
      select
        date_trunc(v_bucket, first_reported_at) as bucket,
        count(*)::integer as total,
        count(*) filter (where status = 'unverified')::integer as pending,
        count(*) filter (where status = 'verified')::integer as verified,
        count(*) filter (where status = 'resolved')::integer as resolved
      from current_hazards
      group by 1
    ) grouped
  ),
  categories as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', type,
      'count', count,
      'percentage', percentage,
      'previous_count', previous_count
    ) order by count desc, type), '[]'::jsonb) as value
    from (
      select
        types.type,
        count(c.id)::integer as count,
        round(100.0 * count(c.id) / nullif((select count(*) from current_hazards), 0), 1)
          as percentage,
        (select count(*)::integer from previous_hazards p where p.type = types.type)
          as previous_count
      from (select distinct type from canonical) types
      left join current_hazards c on c.type = types.type
      group by types.type
    ) grouped
  ),
  severities as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', severity,
      'count', count,
      'percentage', percentage
    ) order by severity), '[]'::jsonb) as value
    from (
      select
        values.severity,
        count(c.id)::integer as count,
        round(100.0 * count(c.id) / nullif((select count(*) from current_hazards), 0), 1)
          as percentage
      from generate_series(1, 5) values(severity)
      left join current_hazards c on c.severity = values.severity
      group by values.severity
    ) grouped
  ),
  statuses as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', status,
      'count', count,
      'percentage', percentage
    ) order by status), '[]'::jsonb) as value
    from (
      select
        values.status,
        count(c.id)::integer as count,
        round(100.0 * count(c.id) / nullif((select count(*) from current_hazards), 0), 1)
          as percentage
      from unnest(array['unverified', 'verified', 'resolved', 'rejected']) values(status)
      left join current_hazards c on c.status = values.status
      group by values.status
    ) grouped
  ),
  school_rollup as (
    select
      h.school_id,
      max(h.school_name) as name,
      max(h.district) as district,
      max(h.district_id) as district_id,
      max(h.city) as city,
      max(h.state) as state,
      max(h.school_latitude) as latitude,
      max(h.school_longitude) as longitude,
      count(*)::integer as total,
      count(*) filter (where h.status = 'unverified')::integer as pending,
      count(*) filter (where h.status = 'verified')::integer as verified,
      count(*) filter (where h.status = 'resolved')::integer as resolved,
      count(*) filter (
        where h.severity >= 4 and h.status not in ('resolved', 'rejected')
      )::integer as high_priority,
      round(avg(h.severity), 1) as average_severity,
      round(
        100.0 * count(*) filter (where h.status = 'resolved')
        / nullif(count(*) filter (where h.status <> 'rejected'), 0),
        1
      ) as resolution_rate,
      round(avg(
        extract(epoch from (h.resolved_at - h.first_reported_at)) / 3600.0
      ) filter (where h.status = 'resolved' and h.resolved_at is not null), 1)
        as average_resolution_hours
    from current_hazards h
    group by h.school_id
  ),
  schools_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', sr.school_id,
      'name', sr.name,
      'district', sr.district,
      'district_id', sr.district_id,
      'city', sr.city,
      'state', sr.state,
      'latitude', sr.latitude,
      'longitude', sr.longitude,
      'total', sr.total,
      'pending', sr.pending,
      'verified', sr.verified,
      'resolved', sr.resolved,
      'high_priority', sr.high_priority,
      'average_severity', sr.average_severity,
      'resolution_rate', sr.resolution_rate,
      'average_resolution_hours', sr.average_resolution_hours,
      'categories', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'key', c.type, 'count', c.count
        ) order by c.count desc, c.type), '[]'::jsonb)
        from (
          select h.type, count(*)::integer as count
          from current_hazards h
          where h.school_id = sr.school_id
          group by h.type
        ) c
      ),
      'severities', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'key', sev.severity, 'count', sev.count
        ) order by sev.severity), '[]'::jsonb)
        from (
          select h.severity, count(*)::integer as count
          from current_hazards h
          where h.school_id = sr.school_id
          group by h.severity
        ) sev
      )
    ) order by sr.total desc, sr.name), '[]'::jsonb) as value
    from school_rollup sr
  ),
  marker_page as (
    select h.*,
      round((111320.0 * sqrt(
        power(h.latitude - h.school_latitude, 2)
        + power(
          (h.longitude - h.school_longitude)
          * cos(radians((h.latitude + h.school_latitude) / 2.0)),
          2
        )
      ))::numeric, 1) as distance_to_school_meters
    from current_hazards h
    order by h.first_reported_at desc, h.id
    limit v_limit offset v_offset
  ),
  markers_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', id,
      'school_id', school_id,
      'school_name', school_name,
      'type', type,
      'severity', severity,
      'status', status,
      'latitude', latitude,
      'longitude', longitude,
      'first_reported_at', first_reported_at,
      'resolved_at', resolved_at,
      'duplicate_count', duplicate_count,
      'distance_to_school_meters', distance_to_school_meters
    ) order by first_reported_at desc, id), '[]'::jsonb) as value
    from marker_page
  )
  select jsonb_build_object(
    'generated_at', now(),
    'range', jsonb_build_object(
      'from', v_from,
      'to', v_to,
      'bucket', v_bucket
    ),
    'summary', to_jsonb(cs),
    'previous_summary', to_jsonb(ps),
    'trend', trend.value,
    'categories', categories.value,
    'severities', severities.value,
    'statuses', statuses.value,
    'schools', schools_json.value,
    'markers', markers_json.value,
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'total', cs.total,
      'has_more', v_offset + v_limit < cs.total
    ),
    'deduplication', jsonb_build_object(
      'method', 'same school, category, and approximately 11 meter coordinate cell',
      'raw_reports', cs.raw_reports,
      'unique_hazards', cs.total,
      'duplicates_removed', cs.duplicates_removed
    )
  ) into v_result
  from current_summary cs
  cross join previous_summary ps
  cross join trend
  cross join categories
  cross join severities
  cross join statuses
  cross join schools_json
  cross join markers_json;

  return v_result;
end;
$$;
