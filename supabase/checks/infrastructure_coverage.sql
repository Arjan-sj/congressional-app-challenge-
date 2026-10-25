-- Synthetic fixtures only, always rolled back. No hosted data required.
begin;
insert into public.infrastructure_import_regions(id,bounds,categories,source_url,source_updated_at,fresh_until,feature_count,file_sha256)
values ('test-covered',extensions.st_makeenvelope(-88.13,42,-88.09,42.04,4326),
array['sidewalk','walkingPath','crossing','bikePath','bikeLane'],
'https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf',now()-interval '1 day',now()+interval '1 day',0,repeat('a',64));
set local role anon;
do $$ declare r jsonb; begin
  r:=public.infrastructure_viewport(42.01,-88.12,42.02,-88.10,array['sidewalk'],17);
  assert r->>'import_coverage'='complete';
  assert jsonb_array_length(r->'items')=0;
  assert r->>'fallback_required'='false','Covered empty result must not call Overpass';
  r:=public.infrastructure_viewport(41,-87,41.01,-86.99,array['sidewalk'],17);
  assert r->>'import_coverage'='missing';
  assert r->>'fallback_required'='true';
  r:=public.infrastructure_viewport(42.03,-88.12,42.05,-88.10,array['sidewalk'],17);
  assert r->>'import_coverage'='partial';
  assert r->>'fallback_required'='true';
  r:=public.infrastructure_viewport(41,-87,41.01,-86.99,array['sidewalk'],14);
  assert r->>'fallback_required'='false','Zoom gate must prevent upstream calls';
  begin
    insert into public.infrastructure_import_regions select * from public.infrastructure_import_regions;
    raise exception 'Ordinary client can write coverage';
  exception when insufficient_privilege then null; end;
  begin
    perform public.infrastructure_viewport(42,-88,42.01,-87.99,array['arbitrary'],17);
    raise exception 'Invalid categories accepted';
  exception when raise_exception then assert sqlerrm='Invalid infrastructure viewport'; end;
end $$;
reset role;
-- Adjacent imports may jointly cover a viewport, but every category is required.
update public.infrastructure_import_regions set categories=array['sidewalk'] where id='test-covered';
do $$ declare r jsonb; begin
  r:=public.infrastructure_viewport(42.01,-88.12,42.02,-88.10,array['sidewalk','crossing'],17);
  assert r->>'import_coverage'='partial';
end $$;
update public.infrastructure_import_regions set fresh_until=now()-interval '1 hour' where id='test-covered';
do $$ declare r jsonb; begin
  r:=public.infrastructure_viewport(42.01,-88.12,42.02,-88.10,array['sidewalk'],17);
  assert r->>'import_coverage'='stale';
  assert r->>'coverage'='unknown';
  assert r->>'fallback_required'='true';
end $$;
insert into public.map_infrastructure(id,osm_id,category,geometry,source_region,source_updated_at)
values ('test-import/sidewalk','test-import','sidewalk',extensions.st_setsrid(extensions.st_point(-88.11,42.015),4326),'test-covered',now());
do $$ declare r jsonb; begin
  r:=public.infrastructure_viewport(42.01,-88.12,42.02,-88.10,array['sidewalk'],17);
  assert jsonb_array_length(r->'items')=1;
  assert r->>'fallback_required'='false','Existing usable import avoids upstream even with unknown freshness';
  assert jsonb_array_length(public.infrastructure_in_view(42.01,-88.12,42.02,-88.10,array['sidewalk'],17))=1,'Legacy RPC remains compatible';
end $$;
-- A complete import still paginates; no nationwide response is built in Flutter.
insert into public.map_infrastructure(id,osm_id,category,geometry,source_region,source_updated_at)
select 'test-page-'||lpad(n::text,4,'0'),'test-page-'||n,'sidewalk',
  extensions.st_setsrid(extensions.st_point(-87.995,41.005),4326),'test-pages',now()
from generate_series(1,501) n;
set local role authenticated;
do $$ declare r jsonb; last_id text; begin
  r:=public.infrastructure_viewport(41,-88,41.01,-87.99,array['sidewalk'],17);
  assert jsonb_array_length(r->'items')=500;
  assert r->>'fallback_required'='false';
  last_id := r->'items'->499->>'id';
  r:=public.infrastructure_viewport(41,-88,41.01,-87.99,array['sidewalk'],17,last_id);
  assert jsonb_array_length(r->'items')=1;
end $$;
reset role;
rollback;
