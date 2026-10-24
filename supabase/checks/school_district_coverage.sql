-- Read-only post-deployment coverage/consistency report. No report data is read.
select s.classification,s.state,s.source_year,count(*) as schools,
  count(*) filter(where s.canonical_id is not null) as aliases,
  count(*) filter(where s.district_id is not null) as linked,
  count(*) filter(where s.classification='public' and s.source='nces-public'
    and s.canonical_id is null and s.district_id is null) as public_unmatched,
  count(*) filter(where s.classification='private' and s.district_id is not null) as invalid_private_links,
  count(*) filter(where s.district_id is not null and (o.district_id is null
    or public.nces_school_year(s.source_year) is distinct from s.district_source_year
    or s.district_link_metadata->>'ncessch' is distinct from s.source_id
    or s.district_link_metadata->>'school_state' is distinct from btrim(s.state)
    or s.district_link_metadata->>'school_opstfips' is distinct from o.metadata->>'opstfips')) as inconsistent_links,
  count(*) filter(where s.district_id is not null and s.state<>o.state) as verified_cross_physical_state
from public.schools s left join public.school_district_sources o
  on o.district_id=s.district_id and o.source_year=s.district_source_year
group by s.classification,s.state,s.source_year order by s.classification,s.state,s.source_year;
