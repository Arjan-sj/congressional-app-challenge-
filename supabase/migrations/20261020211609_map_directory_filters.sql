create or replace function public.search_schools(search_text text, state_code text default null)
returns jsonb language sql stable security invoker set search_path='' as $$
  select coalesce(jsonb_agg(to_jsonb(s)-'location'-'created_at'-'synced_at'),'[]') from (
    select * from public.schools where canonical_id is null and char_length(btrim(search_text)) between 2 and 120
      and (state_code is null or state=state_code)
      and (name ilike '%'||search_text||'%' or city ilike '%'||search_text||'%' or zip_code=search_text
        or district ilike '%'||search_text||'%') order by name,id limit 10
  ) s;
$$;


drop function public.hazards_in_view(float8,float8,float8,float8,float8,uuid);
create function public.hazards_in_view(min_lat float8,min_lon float8,max_lat float8,max_lon float8,
  zoom float8 default 15, after_id uuid default null, hazard_kind text default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb; dx float8; dy float8;
begin
  if zoom is null or zoom < 0 or zoom > 22 then raise exception 'Invalid zoom'; end if;
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
      from public.hazard_reports h where not is_demo and status<>'rejected' and (hazard_kind is null or h.type=hazard_kind)
        and h.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon))) group by 1
    ) b;
  else
    select coalesce(jsonb_agg(to_jsonb(h)-'location'),'[]') into result from (
      select * from public.hazard_reports h where not is_demo and status<>'rejected' and (hazard_kind is null or h.type=hazard_kind)
        and (after_id is null or h.id>after_id)
        and h.location operator(extensions.&&) any(array(select public.map_envelopes(min_lat,min_lon,max_lat,max_lon)))
      order by id limit 500
    ) h;
  end if;
  return jsonb_build_object('items',result,'clustered',zoom<13);
end $$;


revoke all on function public.hazards_in_view(float8,float8,float8,float8,float8,uuid,text) from public;
grant execute on function public.hazards_in_view(float8,float8,float8,float8,float8,uuid,text) to anon,authenticated,service_role;
create function public.school_state_bounds(state_code text) returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('south',min(latitude),'west',min(longitude),'north',max(latitude),'east',max(longitude))
  from public.schools where state=state_code and canonical_id is null;
$$;
revoke all on function public.school_state_bounds(text) from public;
grant execute on function public.school_state_bounds(text) to anon,authenticated,service_role;
-- Explicit known mapping only; generic proximity is insufficient for identity.
create function public.sync_known_school_aliases() returns void
language sql volatile security invoker set search_path='' as $$
  update public.schools legacy set canonical_id=canonical.id from public.schools canonical
    where legacy.id='sample-school' and canonical.id='173045003167'
      and legacy.name=canonical.name and legacy.latitude=canonical.latitude and legacy.longitude=canonical.longitude;
$$;
revoke all on function public.sync_known_school_aliases() from public,anon,authenticated;
grant execute on function public.sync_known_school_aliases() to service_role;
notify pgrst,'reload schema';
