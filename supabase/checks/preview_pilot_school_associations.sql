-- Read-only preview, usable BEFORE deployment. No report descriptions/authors.
-- Store results privately; report IDs/coordinates may belong to unverified rows.
-- After deployment, public.preview_pilot_school_associations() provides the same
-- review plus candidates, restricted to trusted operators.
with pilot as (
  select h.id report_id,h.school_id current_school_id,s.name current_school_name,
    c.id canonical_school_id,h.latitude,h.longitude,h.location,
    extensions.st_distance(h.location::extensions.geography,c.location::extensions.geography) current_distance_meters
  from public.hazard_reports h
  join public.schools s on s.id=h.school_id
  join public.schools c on c.id=coalesce(s.canonical_id,s.id)
  where not h.is_demo and (s.id='sample-school' or c.id='173045003167')
), review as (
  select p.*,coalesce(n.candidates,'[]'::jsonb) candidates
  from pilot p left join lateral (
    select jsonb_agg(to_jsonb(a) order by a.distance_meters,a.school_id) candidates from (
      select s.id school_id,s.name,
        extensions.st_distance(s.location::extensions.geography,p.location::extensions.geography) distance_meters,
        s.latitude,s.longitude
      from public.schools s where s.canonical_id is null
        and extensions.st_dwithin(s.location::extensions.geography,p.location::extensions.geography,2000)
    ) a
  ) n on true
)
select report_id,current_school_id,current_school_name,canonical_school_id,latitude,longitude,
  current_distance_meters,candidates->0->>'school_id' suggested_school_id,
  candidates->0->>'name' suggested_school_name,
  (candidates->0->>'distance_meters')::float8 distance_meters,candidates,
  case when current_distance_meters<=2000 then 'retain_pilot'
    when jsonb_array_length(candidates)=0 then 'no_match' else 'review_required' end review_status
from review order by report_id;
