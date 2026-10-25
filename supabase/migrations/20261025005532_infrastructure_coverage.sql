-- Coverage is registered by a trusted importer only AFTER every batch succeeds.
-- It describes extraction/query completeness, never real-world sidewalk coverage.
create table public.infrastructure_import_regions (
  id text primary key,
  bounds extensions.geometry(Polygon,4326) not null,
  categories text[] not null check (cardinality(categories) between 1 and 5 and
    categories <@ array['sidewalk','walkingPath','crossing','bikePath','bikeLane']::text[]),
  source_url text not null check (source_url like 'https://%'),
  attribution text not null default '© OpenStreetMap contributors, ODbL 1.0',
  source_updated_at timestamptz not null,
  imported_at timestamptz not null default now(),
  fresh_until timestamptz not null,
  feature_count bigint not null check (feature_count >= 0),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  check (fresh_until > source_updated_at),
  check (extensions.st_isvalid(bounds) and not extensions.st_isempty(bounds))
);
create index infrastructure_import_bounds on public.infrastructure_import_regions using gist(bounds);
alter table public.infrastructure_import_regions enable row level security;
create policy "Public extraction coverage" on public.infrastructure_import_regions for select to anon,authenticated using(true);
revoke all on public.infrastructure_import_regions from public,anon,authenticated;
grant select on public.infrastructure_import_regions to anon,authenticated;
grant all on public.infrastructure_import_regions to service_role;

-- Additive envelope around the existing indexed, paginated RPC. Its contract stays intact.
create function public.infrastructure_viewport(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  categories text[], zoom float8 default 15, after_id text default '')
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare box extensions.geometry; c text; full_coverage boolean := true;
  any_region boolean; fresh_region boolean; expiry timestamptz; category_expiry timestamptz;
  shape extensions.geometry; items jsonb; coverage text;
begin
  if min_lat is null or max_lat is null or min_lon is null or max_lon is null
    or not(min_lat between -85 and 85 and max_lat between -85 and 85
      and min_lon between -180 and 180 and max_lon between -180 and 180)
    or min_lat>=max_lat or min_lon>=max_lon or max_lat-min_lat>.18 or max_lon-min_lon>.24
    or zoom is null or zoom not between 0 and 22 or categories is null
    or cardinality(categories) not between 1 and 5 or array_position(categories,null) is not null
    or not(categories <@ array['sidewalk','walkingPath','crossing','bikePath','bikeLane']::text[])
    or after_id is null then raise exception 'Invalid infrastructure viewport'; end if;
  box := extensions.st_makeenvelope(min_lon,min_lat,max_lon,max_lat,4326);
  select exists(select 1 from public.infrastructure_import_regions r
    where r.bounds operator(extensions.&&) box) into any_region;
  select exists(select 1 from public.infrastructure_import_regions r
    where r.bounds operator(extensions.&&) box and r.fresh_until>now()) into fresh_region;
  foreach c in array categories loop
    select extensions.st_union(r.bounds), min(r.fresh_until) into shape,category_expiry
      from public.infrastructure_import_regions r where r.bounds operator(extensions.&&) box
      and r.fresh_until>now() and c=any(r.categories);
    if shape is null or not extensions.st_covers(shape,box) then full_coverage := false; end if;
    expiry := least(expiry,category_expiry);
  end loop;
  coverage := case when full_coverage then 'complete' when fresh_region then 'partial'
    when any_region then 'stale' else 'missing' end;
  items := public.infrastructure_in_view(min_lat,min_lon,max_lat,max_lon,categories,zoom,after_id);
  return jsonb_build_object('items',items,'import_coverage',coverage,
    'coverage',case when full_coverage then 'complete' when fresh_region then 'partial' else 'unknown' end,
    'fallback_required',zoom>=15 and not full_coverage and jsonb_array_length(items)=0,
    'expires_at',case when full_coverage then least(expiry,now()+interval '24 hours') else now()+interval '1 hour' end,
    'attribution','© OpenStreetMap contributors, ODbL 1.0');
end $$;
revoke all on function public.infrastructure_viewport(float8,float8,float8,float8,text[],float8,text) from public;
grant execute on function public.infrastructure_viewport(float8,float8,float8,float8,text[],float8,text) to anon,authenticated,service_role;
notify pgrst,'reload schema';
