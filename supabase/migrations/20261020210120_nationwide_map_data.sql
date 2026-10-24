-- Additive: preserve school IDs referenced by reports and all hazard RLS.
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

alter table public.schools
  add column if not exists district text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists zip_code text,
  add column if not exists classification text not null default 'public'
    check (classification in ('public','private')),
  add column if not exists source text,
  add column if not exists source_id text,
  add column if not exists source_dataset text,
  add column if not exists source_year text,
  add column if not exists synced_at timestamptz,
  add column if not exists location extensions.geometry(Point,4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)) stored;
create unique index if not exists schools_source_identifier on public.schools(source,source_id);
create index if not exists schools_location_gist on public.schools using gist(location);
create index if not exists schools_state on public.schools(state);
alter table public.hazard_reports add column if not exists location extensions.geometry(Point,4326)
  generated always as (extensions.st_setsrid(extensions.st_makepoint(longitude,latitude),4326)) stored;
create index if not exists hazard_location_gist on public.hazard_reports using gist(location) where not is_demo;

-- Split antimeridian bounds into two indexable envelopes. Inputs are validated.
create function public.map_envelopes(min_lat float8,min_lon float8,max_lat float8,max_lon float8)
returns setof extensions.geometry language plpgsql immutable security invoker set search_path='' as $$
begin
  if min_lat is null or max_lat is null or min_lon is null or max_lon is null
    or not(min_lat between -90 and 90 and max_lat between -90 and 90
      and min_lon between -180 and 180 and max_lon between -180 and 180)
    or min_lat > max_lat then raise exception 'Invalid map bounds'; end if;
  if min_lon <= max_lon then
    return next extensions.st_makeenvelope(min_lon,min_lat,max_lon,max_lat,4326);
  else
    return next extensions.st_makeenvelope(min_lon,min_lat,180,max_lat,4326);
    return next extensions.st_makeenvelope(-180,min_lat,max_lon,max_lat,4326);
  end if;
end $$;

-- A JSON envelope avoids PostgREST's row cap. Dense results aggregate ALL records,
-- including at high zoom: no silently truncated schools. Zoom in / list co-located.
create function public.schools_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  zoom float8 default 15, result_limit int default 500, school_kind text default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; n int; clustered boolean; dx float8; dy float8;
begin
  if zoom is null or zoom < 0 or zoom > 22 or result_limit not between 1 and 1000
    or (school_kind is not null and school_kind not in ('public','private')) then raise exception 'Invalid map options'; end if;
  select count(*) into n from public.schools s
    where s.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
      and (school_kind is null or s.classification=school_kind);
  clustered := zoom < 13 or n > result_limit;
  dx := greatest(case when min_lon>max_lon then max_lon+360-min_lon else max_lon-min_lon end / greatest(floor(sqrt(result_limit)),1),0.000001);
  dy := greatest((max_lat-min_lat)/greatest(floor(sqrt(result_limit)),1),0.000001);
  with visible as (
    select s.* from public.schools s
    where s.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
      and (school_kind is null or s.classification=school_kind)
  ), buckets as (
    select least(floor((case when longitude<min_lon then longitude+360 else longitude end-min_lon)/dx),greatest(floor(sqrt(result_limit))-1,0)) x,
      least(floor((latitude-min_lat)/dy),greatest(floor(sqrt(result_limit))-1,0)) y,
      count(*) count, avg(latitude) latitude,
      avg(case when longitude<min_lon then longitude+360 else longitude end) longitude,
      min(id) first_id
    from visible group by 1,2
  )
  select case when clustered then
    (select coalesce(jsonb_agg(case when b.count=1 then
      (select to_jsonb(v)-'location'-'created_at'-'synced_at' from visible v where v.id=b.first_id)
      else jsonb_build_object('id','cluster:'||b.x||':'||b.y,'count',b.count,'latitude',b.latitude,
        'longitude',case when b.longitude>180 then b.longitude-360 else b.longitude end) end),'[]') from buckets b)
    else (select coalesce(jsonb_agg(to_jsonb(v)-'location'-'created_at'-'synced_at'),'[]') from visible v) end into result;
  return jsonb_build_object('items',result,'total',n,'clustered',clustered,'version','nces-v1');
end $$;

create function public.search_schools(search_text text, state_code text default null)
returns jsonb language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(s)-'location'-'created_at'-'synced_at'),'[]') from (
    select * from public.schools where char_length(btrim(search_text)) between 2 and 120
      and (state_code is null or state=state_code)
      and (name ilike '%'||search_text||'%' or city ilike '%'||search_text||'%' or zip_code=search_text
        or district ilike '%'||search_text||'%') order by name,id limit 10
  ) s;
$$;

-- Exact keyset pages at close zoom; grid counts at broad zoom. Invoker preserves
-- existing public/author/moderator policies. Never includes photo storage tokens.
create function public.hazards_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  zoom float8 default 15, after_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; dx float8; dy float8;
begin
  dx := greatest(case when min_lon>max_lon then max_lon+360-min_lon else max_lon-min_lon end/16,0.000001);
  dy := greatest((max_lat-min_lat)/16,0.000001);
  if zoom < 13 then
    select coalesce(jsonb_agg(to_jsonb(b)),'[]') into result from (
      select floor((case when longitude<min_lon then longitude+360 else longitude end-min_lon)/dx)::text||':'||floor((latitude-min_lat)/dy)::text id,
        count(*) count, avg(latitude) latitude,
        case when avg(case when longitude<min_lon then longitude+360 else longitude end)>180
          then avg(case when longitude<min_lon then longitude+360 else longitude end)-360
          else avg(case when longitude<min_lon then longitude+360 else longitude end) end longitude,
        max(severity) severity
      from public.hazard_reports h where not is_demo and status<>'rejected'
        and h.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon))) group by 1
    ) b;
  else
    select coalesce(jsonb_agg(to_jsonb(h)-'location'),'[]') into result from (
      select * from public.hazard_reports h where not is_demo and status<>'rejected'
        and (after_id is null or h.id>after_id)
        and h.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
      order by id limit 500
    ) h;
  end if;
  return jsonb_build_object('items',result,'clustered',zoom<13);
end $$;

create table public.map_infrastructure (
  id text primary key, osm_id text not null, category text not null
    check(category in ('crossing','sidewalk','bikePath','bikeLane','walkingPath')),
  geometry extensions.geometry(Geometry,4326) not null,
  tags jsonb not null default '{}', source_region text not null,
  source_updated_at timestamptz not null, synced_at timestamptz not null default now()
);
create index infrastructure_geometry_gist on public.map_infrastructure using gist(geometry);
create index infrastructure_region on public.map_infrastructure(source_region);
alter table public.map_infrastructure enable row level security;
create policy "Public infrastructure" on public.map_infrastructure for select to anon,authenticated using(true);
revoke all on public.map_infrastructure from anon,authenticated;
grant select on public.map_infrastructure to anon,authenticated;
grant all on public.map_infrastructure to service_role;

create function public.infrastructure_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  categories text[], zoom float8 default 15, after_id text default '')
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if zoom<15 then return '[]'::jsonb; end if;
  if max_lat-min_lat>0.18 or abs(max_lon-min_lon)>0.24 then raise exception 'Zoom in for infrastructure'; end if;
  select coalesce(jsonb_agg(to_jsonb(f)),'[]') into result from (
    select i.id,i.category,i.tags,extensions.st_asgeojson(extensions.st_simplifypreservetopology(
      extensions.st_intersection(i.geometry,extensions.st_makeenvelope(min_lon,min_lat,max_lon,max_lat,4326)),
      case when zoom>16 then 0.000005 else 0.00002 end),6)::jsonb geometry
    from public.map_infrastructure i where i.id>after_id and i.category=any(categories)
      and i.geometry operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
    order by i.id limit 500
  ) f;
  return result;
end $$;

-- Shared backend cache/circuit breaker, never writable by browser clients.
create table public.map_provider_cache (
  cell text primary key, payload jsonb, expires_at timestamptz not null default now(),
  retry_at timestamptz not null default now()
);
alter table public.map_provider_cache enable row level security;
revoke all on public.map_provider_cache from anon,authenticated;
grant all on public.map_provider_cache to service_role;
create function public.claim_map_provider(cache_cell text)
returns boolean language sql volatile security invoker set search_path='' as $$
  with claimed as (
    insert into public.map_provider_cache(cell,retry_at) values(cache_cell,now()+interval '60 seconds')
    on conflict(cell) do update set retry_at=excluded.retry_at
      where public.map_provider_cache.retry_at<=now() returning cell
  ) select exists(select 1 from claimed);
$$;
revoke all on function public.claim_map_provider(text) from public,anon,authenticated;
grant execute on function public.claim_map_provider(text) to service_role;

revoke all on function public.map_envelopes(float8,float8,float8,float8),
  public.schools_in_view(float8,float8,float8,float8,float8,int,text),
  public.search_schools(text,text), public.hazards_in_view(float8,float8,float8,float8,float8,uuid),
  public.infrastructure_in_view(float8,float8,float8,float8,text[],float8,text) from public;
grant execute on function public.map_envelopes(float8,float8,float8,float8),
  public.schools_in_view(float8,float8,float8,float8,float8,int,text),
  public.search_schools(text,text), public.hazards_in_view(float8,float8,float8,float8,float8,uuid),
  public.infrastructure_in_view(float8,float8,float8,float8,text[],float8,text) to anon,authenticated,service_role;
notify pgrst,'reload schema';
