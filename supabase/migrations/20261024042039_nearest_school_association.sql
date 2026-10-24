-- No historical reports are changed by this migration.
-- A geography expression index is required: the existing geometry index cannot
-- accelerate meter-based ST_DWithin(location::geography, ...).
create index schools_canonical_geography_gist on public.schools
  using gist ((location::extensions.geography)) where canonical_id is null;

-- Single server-owned radius for both suggestions and write validation.
create function public.report_school_radius_meters() returns double precision
language sql immutable security invoker set search_path = '' as $$ select 2000::float8 $$;
revoke all on function public.report_school_radius_meters() from public;
grant execute on function public.report_school_radius_meters() to anon, authenticated, service_role;

create function public.nearest_schools(
  p_latitude double precision, p_longitude double precision,
  p_radius_meters double precision default null
) returns table(school_id text, name text, distance_meters double precision,
  latitude double precision, longitude double precision)
language plpgsql stable security invoker set search_path = '' as $$
declare
  point extensions.geography;
  radius float8 := coalesce(p_radius_meters, public.report_school_radius_meters());
begin
  if p_latitude is null or p_longitude is null
    or not (p_latitude between -90 and 90)
    or not (p_longitude between -180 and 180)
    or not (radius > 0 and radius <= 20000) then
    raise exception 'Invalid coordinates or search radius (1-20,000 meters)' using errcode='22023';
  end if;
  point := extensions.st_setsrid(extensions.st_makepoint(p_longitude,p_latitude),4326)::extensions.geography;
  return query
    select s.id, s.name, extensions.st_distance(s.location::extensions.geography,point),
      s.latitude,s.longitude
    from public.schools s
    where s.canonical_id is null
      and extensions.st_dwithin(s.location::extensions.geography,point,radius)
    order by extensions.st_distance(s.location::extensions.geography,point),s.id;
end $$;
revoke all on function public.nearest_schools(float8,float8,float8) from public;
grant execute on function public.nearest_schools(float8,float8,float8) to anon,authenticated,service_role;

create function private.validate_report_school() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  -- Moderation of historical rows remains possible without rewriting school IDs.
  if tg_op = 'UPDATE' then
    if new.school_id is not distinct from old.school_id
      and new.latitude is not distinct from old.latitude
      and new.longitude is not distinct from old.longitude then return new; end if;
  end if;
  if not exists(select 1 from public.nearest_schools(new.latitude,new.longitude) s
    where s.school_id = new.school_id) then
    raise exception 'Confirm a canonical school within % meters of the hazard location',
      public.report_school_radius_meters() using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function private.validate_report_school() from public,anon,authenticated;
create trigger validate_report_school before insert or update of school_id,latitude,longitude
  on public.hazard_reports for each row execute function private.validate_report_school();

-- Search the nationwide directory on the server; no client 1,000/5,000-row cap.
-- Keep the existing search_schools contract used by Explore.
create function public.search_analytics_schools(p_query text default '', p_after_id text default '',
  p_limit integer default 100)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(s) order by s.id),'[]'::jsonb) from (
    select id,name,district,city,state,zip_code,latitude,longitude from public.schools
    where canonical_id is null and id > coalesce(p_after_id,'')
      and char_length(btrim(p_query)) <= 120
      and (btrim(p_query) = '' or name ilike '%'||btrim(p_query)||'%'
        or district ilike '%'||btrim(p_query)||'%' or city ilike '%'||btrim(p_query)||'%'
        or state ilike '%'||btrim(p_query)||'%' or zip_code ilike btrim(p_query)||'%')
    order by id limit least(greatest(coalesce(p_limit,100),1),500)
  ) s;
$$;
revoke all on function public.search_analytics_schools(text,text,integer) from public;
grant execute on function public.search_analytics_schools(text,text,integer) to anon,authenticated,service_role;

-- Restricted, read-only review. Include every nearby candidate for human review.
create function public.analytics_school_districts() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(district order by district),'[]'::jsonb)
    from (select distinct district from public.schools
      where canonical_id is null and district is not null) d;
$$;
revoke all on function public.analytics_school_districts() from public;
grant execute on function public.analytics_school_districts() to anon,authenticated,service_role;

-- Restricted, read-only review. Include every nearby candidate for human review.
-- A nearby pilot association is retained even when another campus is closer.
create function public.preview_pilot_school_associations()
returns table(report_id uuid,current_school_id text,current_school_name text,
  canonical_school_id text,latitude float8,longitude float8,current_distance_meters float8,
  suggested_school_id text,suggested_school_name text,distance_meters float8,
  candidates jsonb,review_status text)
language sql stable security invoker set search_path = '' as $$
  select h.id,s.id,s.name,c.id,h.latitude,h.longitude,
    extensions.st_distance(h.location::extensions.geography,c.location::extensions.geography),
    n.school_id,n.name,n.distance_meters,
    coalesce((select jsonb_agg(to_jsonb(a) order by a.distance_meters,a.school_id)
      from public.nearest_schools(h.latitude,h.longitude) a),'[]'::jsonb),
    case when extensions.st_dwithin(h.location::extensions.geography,c.location::extensions.geography,
           public.report_school_radius_meters()) then 'retain_pilot'
      when n.school_id is null then 'no_match'
      else 'review_required' end
  from public.hazard_reports h
  join public.schools s on s.id=h.school_id
  join public.schools c on c.id=coalesce(s.canonical_id,s.id)
  left join lateral (select * from public.nearest_schools(h.latitude,h.longitude) limit 1) n on true
  where not h.is_demo and (s.id='sample-school' or c.id='173045003167')
  order by h.id;
$$;
revoke all on function public.preview_pilot_school_associations() from public,anon,authenticated;
grant execute on function public.preview_pilot_school_associations() to service_role;

create table private.report_school_corrections (
  report_id uuid primary key,
  previous_school_id text not null references public.schools(id),
  school_id text not null references public.schools(id),
  reviewed_by text not null,
  reason text not null,
  corrected_at timestamptz not null default now()
);
alter table private.report_school_corrections enable row level security;
revoke all on private.report_school_corrections from public,anon,authenticated;

-- Explicit allowlist only. No invocation is part of this migration.
-- Intended for a trusted operator after review and separate approval.
create function public.apply_reviewed_school_corrections(p_approvals jsonb,p_reviewed_by text,p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare a jsonb; h public.hazard_reports; preview record; changed integer := 0;
begin
  if p_reviewed_by is null or char_length(btrim(p_reviewed_by)) < 3
    or p_reason is null or char_length(btrim(p_reason)) < 5
    or p_approvals is null or jsonb_typeof(p_approvals) <> 'array' then
    raise exception 'A reviewed approval array, reviewer and reason are required' using errcode='22023';
  end if;
  for a in select value from jsonb_array_elements(p_approvals) loop
    if not (a ?& array['report_id','current_school_id','latitude','longitude','school_id']) then
      raise exception 'Approval is incomplete' using errcode='22023';
    end if;
    select * into h from public.hazard_reports where id=(a->>'report_id')::uuid for update;
    if not found or h.is_demo or h.latitude is distinct from (a->>'latitude')::float8
      or h.longitude is distinct from (a->>'longitude')::float8 then
      raise exception 'Report changed or is unavailable: %',a->>'report_id';
    end if;
    if exists(select 1 from private.report_school_corrections r where r.report_id=h.id
      and r.previous_school_id=a->>'current_school_id' and r.school_id=h.school_id
      and r.school_id=a->>'school_id') then continue; end if;
    select * into preview from public.preview_pilot_school_associations() p where p.report_id=h.id;
    if not found or preview.review_status <> 'review_required'
      or h.school_id is distinct from a->>'current_school_id'
      or not exists(select 1 from public.nearest_schools(h.latitude,h.longitude) n
        where n.school_id=a->>'school_id') then
      raise exception 'Approval is stale, unrelated, or not an eligible correction: %',h.id;
    end if;
    update public.hazard_reports set school_id=a->>'school_id' where id=h.id;
    insert into private.report_school_corrections(report_id,previous_school_id,school_id,reviewed_by,reason)
      values(h.id,h.school_id,a->>'school_id',btrim(p_reviewed_by),btrim(p_reason));
    changed := changed+1;
  end loop;
  return changed;
end $$;
revoke all on function public.apply_reviewed_school_corrections(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.apply_reviewed_school_corrections(jsonb,text,text) to service_role;

notify pgrst,'reload schema';

-- Resolve legacy aliases at read time without rewriting legitimate pilot reports.
-- Statistics, filters, RLS and deduplication remain unchanged.
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
      h.type,
      h.severity,
      h.status,
      h.latitude,
      h.longitude,
      h.created_at,
      h.resolved_at,
      s.name as school_name,
      coalesce(s.district, 'District unavailable') as district,
      s.city,
      s.state,
      s.latitude as school_latitude,
      s.longitude as school_longitude
    from public.hazard_reports h
    join public.schools original_school on original_school.id = h.school_id
    join public.schools s on s.id = coalesce(original_school.canonical_id, original_school.id)
    where h.is_demo = false
      and h.created_at >= v_previous_from
      and h.created_at < v_to
      and (p_school_ids is null or s.id in (select coalesce(fs.canonical_id,fs.id)
        from public.schools fs where fs.id=any(p_school_ids)))
      and (p_districts is null or s.district = any(p_districts))
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
