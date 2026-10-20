-- SafeRoutes analytics dashboard
--
-- Aggregation stays inside Postgres and runs as the caller. Row Level Security
-- on hazard_reports therefore remains the source of truth: public users see
-- reviewed reports, authors can also see their own reports, and moderators see
-- the full queue. The returned JSON never includes reporter identifiers or
-- free-form descriptions.

alter table public.schools
  add column if not exists district text,
  add column if not exists city text,
  add column if not exists state text;

-- Complete the existing pilot directory record; no synthetic school rows are
-- inserted for analytics.
update public.schools
set district = coalesce(district, 'Township High School District 211'),
    city = coalesce(city, 'Schaumburg'),
    state = coalesce(state, 'IL')
where id = 'sample-school';

alter table public.hazard_reports
  add column if not exists verified_at timestamptz,
  add column if not exists resolved_at timestamptz;

alter table public.hazard_reports
  drop constraint if exists hazard_reports_type_check;
alter table public.hazard_reports
  add constraint hazard_reports_type_check check (
    type in (
      'missing_sidewalk', 'difficult_crossing', 'poor_lighting',
      'blocked_path', 'bike_route'
    )
  );

create or replace function public.set_hazard_status_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'verified' and old.status is distinct from 'verified' then
    new.verified_at := coalesce(new.verified_at, now());
  end if;
  if new.status = 'resolved' and old.status is distinct from 'resolved' then
    new.resolved_at := coalesce(new.resolved_at, now());
  end if;
  return new;
end;
$$;

revoke all on function public.set_hazard_status_timestamps() from public;

drop trigger if exists set_hazard_status_timestamps on public.hazard_reports;
create trigger set_hazard_status_timestamps
before update of status on public.hazard_reports
for each row execute function public.set_hazard_status_timestamps();

-- Preserve historical resolution timing when moderation history predates this
-- migration. Future decisions are timestamped by the trigger above.
update public.hazard_reports h
set resolved_at = history.resolved_at
from (
  select report_id, min(created_at) as resolved_at
  from public.report_moderation_history
  where status = 'resolved'
  group by report_id
) history
where h.id = history.report_id
  and h.resolved_at is null;

update public.hazard_reports h
set verified_at = history.verified_at
from (
  select report_id, min(created_at) as verified_at
  from public.report_moderation_history
  where status = 'verified'
  group by report_id
) history
where h.id = history.report_id
  and h.verified_at is null;

create index if not exists hazard_reports_analytics_created_idx
  on public.hazard_reports (created_at desc)
  where is_demo = false;
create index if not exists hazard_reports_analytics_school_type_idx
  on public.hazard_reports (school_id, type, created_at desc)
  where is_demo = false;
create index if not exists hazard_reports_analytics_status_severity_idx
  on public.hazard_reports (status, severity, created_at desc)
  where is_demo = false;
create index if not exists schools_analytics_district_idx
  on public.schools (district, state);

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
      h.school_id,
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
    join public.schools s on s.id = h.school_id
    where h.is_demo = false
      and h.created_at >= v_previous_from
      and h.created_at < v_to
      and (p_school_ids is null or h.school_id = any(p_school_ids))
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

comment on function public.get_hazard_analytics(
  timestamptz, timestamptz, text, text[], text[], text[], smallint[], text[],
  double precision, double precision, double precision, double precision,
  integer, integer
) is
  'RLS-aware, deduplicated hazard analytics without reporter or description data.';

revoke all on function public.get_hazard_analytics(
  timestamptz, timestamptz, text, text[], text[], text[], smallint[], text[],
  double precision, double precision, double precision, double precision,
  integer, integer
) from public;
grant execute on function public.get_hazard_analytics(
  timestamptz, timestamptz, text, text[], text[], text[], smallint[], text[],
  double precision, double precision, double precision, double precision,
  integer, integer
) to anon, authenticated;

-- Postgres Changes honors hazard_reports RLS. Add the source table only once;
-- the client re-fetches the aggregate after each visible INSERT/UPDATE/DELETE.
do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'hazard_reports'
  ) then
    alter publication supabase_realtime add table public.hazard_reports;
  end if;
end;
$$;
