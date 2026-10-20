-- Explicit aliases preserve all legacy foreign keys; never merge by proximity alone.
alter table public.schools add column canonical_id text references public.schools(id) on delete restrict;
create index schools_canonical on public.schools(canonical_id) where canonical_id is not null;
create policy "Service manages provider cache" on public.map_provider_cache for all to service_role using(true) with check(true);
create or replace function public.schools_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  zoom float8 default 15, result_limit int default 500, school_kind text default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; n int; clustered boolean; dx float8; dy float8;
begin
  if zoom is null or zoom < 0 or zoom > 22 or result_limit is null or result_limit not between 1 and 1000
    or (school_kind is not null and school_kind not in ('public','private')) then raise exception 'Invalid map options'; end if;
  select count(*) into n from public.schools s
    where s.canonical_id is null and s.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
      and (school_kind is null or s.classification=school_kind);
  clustered := zoom < 13 or n > result_limit;
  dx := greatest(case when min_lon>max_lon then max_lon+360-min_lon else max_lon-min_lon end / greatest(floor(sqrt(result_limit)),1),0.000001);
  dy := greatest((max_lat-min_lat)/greatest(floor(sqrt(result_limit)),1),0.000001);
  with visible as (
    select s.* from public.schools s
    where s.canonical_id is null and s.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
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


create function public.school_members_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  after_id text default '', school_kind text default null)
returns jsonb language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(s)-'location'-'created_at'-'synced_at'),'[]') from (
    select * from public.schools s where s.id > after_id and s.canonical_id is null
      and (school_kind is null or s.classification=school_kind)
      and s.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
    order by id limit 100
  ) s;
$$;
revoke all on function public.school_members_in_view(float8,float8,float8,float8,text,text) from public;
grant execute on function public.school_members_in_view(float8,float8,float8,float8,text,text) to anon,authenticated,service_role;
-- Exact known pilot alias only, validated by stable NCES ID + name + coordinates.
-- Safe on a fresh database before import; importer repeats this explicit mapping.
update public.schools legacy set canonical_id=canonical.id from public.schools canonical
  where legacy.id='sample-school' and canonical.id='173045003167'
    and legacy.name=canonical.name and legacy.latitude=canonical.latitude and legacy.longitude=canonical.longitude;
notify pgrst,'reload schema';
