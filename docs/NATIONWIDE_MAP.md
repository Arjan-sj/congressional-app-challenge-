# Nationwide map architecture and deployment

Implemented and checked on 2026-10-20. The connected project is
`bnvmlxgdqgwjtxgtsaak`. Its three new migrations and `map-infrastructure` Edge
Function are deployed. A real Geofabrik DC core region with 12,190 infrastructure features is also imported. **124,688 NCES schools are imported: 102,178 public and
22,510 private.** Replaying a 3,000-record batch kept that count unchanged.

## Diagnosis and request inventory

The installed map package is `flutter_map` 8.3.2. The former Explore screen loaded
Urban Institute's CCD state directory during initialization and asked Overpass for
OSM schools and infrastructure after an 850 ms movement debounce. One viewport
expanded into four parallel chunks with retries and provider switching. Rendering
updated on every camera animation frame. Hazard reads silently stopped at 1,000
rows, and photos were loaded for every report in that result.

Current requests:

| Source | Owner | When |
| --- | --- | --- |
| OSM-compatible raster tiles | `TileLayer` | Visible map tiles, normal provider/browser HTTP caching |
| NCES schools in PostGIS | `MapDataService` / `schools_in_view` | Settled visible bounds; geographic memory cache |
| School search/state extent | `search_schools`, `school_state_bounds` | Debounced explicit search or state selection |
| Community hazards | `hazards_in_view` | Visible bounds, 30-second freshness, mutation/auth invalidation |
| Report list/moderation/photos | `SupabaseHazardRepository` | Pilot list at startup; paged full list when Reports/Moderation opens; individual map photos on demand |
| Indexed OSM geometry | `infrastructure_in_view` | Enabled categories only, zoom >= 15 |
| Controlled Overpass fallback | `map-infrastructure` Edge Function | Only if local infrastructure result is empty |
| Walking/cycling routes | `OpenRouteService` | Explicit Compare; geographically scoped hazard read first |
| Analytics | Existing analytics RPCs | Separate Analytics tab; existing RLS and filters |

`UrbanSchoolsRepository` and `OverpassService` remain as legacy compatibility code
with their original tests; Explore no longer calls either network service. The
state-name constants are still reused from the former school repository.

HTTP errors are source-specific. Hosted tests observed Overpass HTTP 406 and a
manual bounded request to the prior configured provider returned 504. Those are
infrastructure-provider failures, independently of raster tiles or Supabase.
Flutter Web cannot reliably distinguish a CORS rejection from a disconnected
transport; diagnostics explicitly combine those two rather than mislabeling them.

## Loading, cache, and visual hierarchy

The coverage-aware loading update and reviewed Schaumburg-area extraction workflow
are documented in [Phase 6 infrastructure](PHASE6_INFRASTRUCTURE.md). Completed
regional imports, including valid empty viewports, no longer require Overpass.

`MapDataService` owns a 300 ms movement debounce, source/detail/classification
cache keys, 15% geographic coverage buffers, a 96-entry memory bound, and separate
source notifiers. There is at most one active viewport load per source and two
active source loads globally. Schools and hazards start together; infrastructure
waits for capacity. Movement stores only the latest desired viewport, invalidates
stale generations immediately, and reuses completed overlapping coverage. Hidden
layers cannot start requests. Toggling a layer preserves the map/controller and
does not invalidate unrelated data. Loaded successful features remain visible
during refresh or failure. Camera labels update after movement settles.

Schools/infrastructure have 24-hour memory freshness. Hazards have 30 seconds,
with immediate targeted invalidation after local creation, moderation, deletion,
refresh, or authentication change. Auth changes clear private hazard cache data.
An idempotent transient read gets at most one retry, with bounded delay/jitter.
Rate limits are not automatically retried. The fallback adds a database-backed
global provider budget and regional locks across Edge isolates, respects
`Retry-After`, and caches successful (including empty) responses for one day.
Explicit Retry cannot bypass a rate-limit cooldown. No automatic public-provider
rotation occurs in the production map path.

The visual stack is base tiles, secondary infrastructure, crossings, hazards,
then schools. Route lines and active navigation markers retain their own visible
layers. School/hazard collisions use a pixel-cell lookup and an offset hazard hit
area that remains clickable. Nearby/co-located schools and reports are also
listed in their information panels. School selection remains highlighted.

| Zoom | Data/display |
| --- | --- |
| < 13 | School grid clusters and RLS-filtered hazard counts; no infrastructure |
| 13–14 | Individual schools unless density exceeds the marker budget; detailed paged hazards |
| 15–16 | Enabled crossings, sidewalks, bicycle paths/lanes; simplified geometry |
| > 16 | Walking paths and finer geometry |

School clusters represent **every** record, including dense high-zoom viewports;
they never silently drop schools at a row limit. Clicking zooms in, or opens a
paged directory at close zoom. Public/private school filters are independent of
hazards. Hazard category filters apply to both cluster and detail queries.
Hazard/infrastructure details use stable keyset pages rather than offset or a
silent Supabase result cap. JSON scalar envelopes avoid PostgREST truncating
server-side cluster results. Antimeridian school/hazard viewports split into two
indexed envelopes; optional infrastructure stays disabled across the seam.

Routes fetch exact hazard records around both endpoints plus a 2 km corridor
buffer even if the hazard layer is hidden or the map is broadly zoomed. Existing
100 m ORS avoidance polygons and matching displayed buffers remain in use for
walking and cycling. Missing infrastructure still means **unknown**, with no
safety penalty. School coordinates are campus locations, not verified entrances.

## Database, security, and deployment

Apply migrations in repository order. These changes extend `schools`; they do not
delete schools or rewrite report foreign keys. Public NCES IDs retain leading
zeros; private IDs use `nces-private:<PPIN>`. `(source,source_id)` is unique.
Generated PostGIS Point columns and GiST indexes cover schools and hazards.
`map_infrastructure` has its own GiST geometry index and stable OSM/category IDs.
All map functions use `SECURITY INVOKER` with a fixed search path. Existing hazard
RLS remains authoritative for anonymous visitors, authors, and moderators.

The known pilot school is an explicit alias of NCES `173045003167`, verified by
exact name and coordinates. Its legacy row remains for report foreign keys and
analytics. It is excluded from map/search counts. Other schools are **not** merged
by name/proximity; separate schools may share a building. OSM school discovery has
been removed from the map, avoiding a second competing school source.

The cache table is inaccessible to browser roles. Only the Edge Function can
claim provider locks or write cached responses. Its gateway JWT check is disabled
to support the project's publishable key; the function independently validates
the supplied project API key through Supabase Auth before processing requests.
It is a public, bounded read endpoint, with no arbitrary URLs or Overpass queries
accepted from clients. The service-role key comes only from Edge server secrets.
The existing public Flutter URL/key are preserved.

CLI commands were verified with Supabase CLI 2.121.0. For a new deployment:

```powershell
npx.cmd --yes supabase link --project-ref YOUR_PROJECT_REF
npx.cmd --yes supabase db push --dry-run
npx.cmd --yes supabase db push
npx.cmd --yes supabase functions deploy map-infrastructure --use-api --project-ref YOUR_PROJECT_REF
```

The three map migrations are already applied to the connected project. MCP assigns
hosted migration timestamps independently; compare names/history before using CLI
push on this existing project. Do not replay earlier pilot migrations blindly.
`supabase/config.toml` contains the function-specific setting, not a replacement
for the project's hosted configuration.

Set `OVERPASS_URL` as an **Edge Function secret** to select a managed provider;
the fallback now defaults to `https://overpass.private.coffee/api/interpreter`,
the [Private.coffee public mirror](https://overpass.private.coffee/).
The endpoint change is deployed as Edge Function version 3. Requests include a
project-identifying User-Agent. Explicit `OVERPASS_URL` overrides remain supported.
Changing a Flutter dart-define no longer configures production infrastructure.
Successful cache rows can be pruned by an operator after their expiry plus a
retention window; preserve active `overpass:<provider-host>` cooldowns. Cache keys
include the provider host so an explicit endpoint switch is not held behind the
previous provider's cooldown. Automatic rotation after a rate limit is disabled.

Endpoint-switch verification: an initial bounded Private.coffee probe returned
HTTP 200 with 68 elements in 3,134 ms. The full hosted request subsequently hit
the 18-second upstream timeout, and later standalone probes also timed out.
Consequently the mirror change is verified as deployed, but it is **not evidence
that public-provider timeouts are resolved**. Six Edge tests cover normalization,
default/override selection, and provider-specific cooldown keys. No tile or
geocoding endpoint change was needed to perform this infrastructure switch.

Security advisors show no new schema/RLS warnings. A pre-existing
[leaked-password-protection warning](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)
remains in hosted Auth settings. Performance advisors list unused indexes on the
small pilot tables and newly created infrastructure table; they were retained
for the intended workload rather than dropped based on a short observation window.

## Reproducible NCES synchronization

Official sources, checked against the live service directory on 2026-10-20:

- [Public school locations 2024–25](https://catalog.data.gov/dataset/public-school-locations-2024-25)
  / [official layer](https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICSCH_2425/MapServer/0).
- [Private school locations 2023–24](https://catalog.data.gov/dataset/private-school-locations-2023-24)
  / [official layer](https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PRIVATESCH_2324/MapServer/0).
- [Official service directory](https://nces.ed.gov/opengis/rest/services/K12_School_Locations?f=pjson).

The importer checks for newer releases before each remote import and stops for
schema review if a newer source is listed. It inspects the actual fields and
downloads complete, explicitly identified pages. Public records use `NCESSCH`;
private records use `PPIN`; both use `NAME`, `LAT`, `LON`, `STREET`, `CITY`, `STATE`,
`ZIP`, `SCHOOLYEAR`. It preserves IDs, validates finite coordinates and required
values, rejects duplicate source IDs, reports progress, writes errors to JSONL,
and upserts in configurable batches. Only server-side Python downloads national
data. Neither Flutter nor a browser downloads the national file.

```powershell
python scripts/import_schools.py --kind both --dry-run
python scripts/import_schools.py --kind both --dry-run --max-records 20
# Supply server-only environment variables through your secret manager:
# SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
python scripts/import_schools.py --kind both --batch-size 500
# Or prepare escaped SQL for a trusted database importer, with no local key:
python scripts/import_schools.py --kind both --sql-dir private/nces-batches
# An official downloaded CSV is supported for one source at a time:
python scripts/import_schools.py --kind private --csv private/private-schools.csv --dry-run
```

Re-run after an official dataset release. Imports update synchronization time and
source year without duplicating rows. The last alias synchronization preserves
the pilot linkage. Failed batches are replayable. Imports do not automatically
delete retired schools or change their historical reports; retirement requires a
reviewed source lifecycle decision. Bump the client source-version key when
changing the schema/detail contract; dataset refreshes otherwise become visible
after the cache freshness interval or app restart.

## Regional OpenStreetMap ingestion

Use [Geofabrik state extracts](https://download.geofabrik.de/north-america/us.html)
on a backend ingestion machine. Start with a small region; never ship a PBF or
state GeoJSON file to Flutter. With the official `osmium-tool` installed:

```bash
# Download an operator-selected state extract from Geofabrik first.
osmium extract --bbox=-88.13,42.00,-88.07,42.05 illinois-latest.osm.pbf -o pilot.osm.pbf
osmium tags-filter pilot.osm.pbf n/highway=crossing w/highway=footway,path,pedestrian,cycleway w/sidewalk w/sidewalk:left w/sidewalk:right w/sidewalk:both w/cycleway w/cycleway:left w/cycleway:right w/cycleway:both -o pilot-filtered.osm.pbf
osmium export pilot-filtered.osm.pbf --geometry-types=point,linestring --add-unique-id=type_id -f geojsonseq -o pilot.geojsonseq
python scripts/import_infrastructure.py pilot.geojsonseq --region il-pilot --source-updated-at 2026-10-19T20:21:11Z --dry-run
python scripts/import_infrastructure.py pilot.geojsonseq --region il-pilot --source-updated-at 2026-10-19T20:21:11Z
```

An equivalent Python exporter avoids a separate osmium CLI installation. Install
its optional dependency on a backend Python version supported by the wheel:

```powershell
py -3.14 -m pip install -r scripts/requirements-infrastructure.txt
py -3.14 scripts/export_osm_region.py private/dc-latest.osm.pbf private/dc-core.geojsonseq --bbox=-77.06,38.88,-77.02,38.92
python scripts/import_infrastructure.py private/dc-core.geojsonseq --region dc-core --source-updated-at 2026-10-19T20:21:11Z --dry-run
python scripts/import_infrastructure.py private/dc-core.geojsonseq --region dc-core --source-updated-at 2026-10-19T20:21:11Z
```

The trial used Geofabrik's official `district-of-columbia-latest.osm.pbf`
(21,035,037 bytes; replication timestamp 2026-10-19T20:21:11Z), not a nationwide
extract. The exporter streams a region and emits only relevant features. For
operators using trusted SQL tools instead of local service credentials,
`import_infrastructure.py --sql-dir private/region-batches` prepares repeatable
upserts, just as the school importer does.

Use the extract's actual replication timestamp, not the example timestamp. The
script validates geometry and stable IDs, imports only supported categories,
keeps selected attributes, and performs batched upserts. Refresh a region by
rerunning the filtered pipeline against a newer extract; deleted OSM objects
require a reviewed regional reconciliation. OSM relation member ways are selected
by their own relevant tags; arbitrary route relations are not imported as extra
duplicate lines. Explicit tagged MultiLineString features are supported.

Ordinary footways are walking paths, not automatically sidewalks. Directional
sidewalk/cycleway tags and access restrictions are respected. The fallback
deduplicates crossing nodes and adjoining crossing ways. Regional ingestion
deduplicates crossing nodes against nearby connecting ways while retaining way-only crossings.
Road-tagged sidewalks/cycleways remain road-centerline indications, not surveyed
curb geometry. See official [crossing](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dcrossing),
[footway crossing](https://wiki.openstreetmap.org/wiki/Tag:footway%3Dcrossing),
[sidewalk](https://wiki.openstreetmap.org/wiki/Key:sidewalk), and
[cycleway](https://wiki.openstreetmap.org/wiki/Key:cycleway) tagging documentation.

NCES source data is public domain. Display OSM attribution and follow
[ODbL](https://www.openstreetmap.org/copyright) for the derived OSM database and
[tile usage policy](https://operations.osmfoundation.org/policies/tiles/).
No public raster tile bulk download or cache bypass is introduced. Vector tiles
were deferred: this map uses Flutter polylines, and adding a vector renderer is
not justified without a measured infrastructure bottleneck.

## Measurements, checks, and remaining limits

Live public-key HTTP smoke measurements from this Windows machine (two samples,
2026-10-20; first/second request, not a statistically controlled benchmark):

| Query | First / second latency | Decoded payload | Results |
| --- | --- | --- | --- |
| Local school viewport | 984 / 250 ms | 4,048 bytes | 10 schools |
| Worldwide school viewport | 1,285 / 502 ms | 3,014 bytes | 27 clusters representing all 124,688 schools |
| Local anonymous hazards | 240 / 169 ms | 33 bytes | 0 RLS-visible reports; no invented markers |
| Indexed DC infrastructure viewport | 1,144 / 241 ms | 60,385 bytes | 264 features, one page, no Overpass |
| Infrastructure fallback / cooldown | 1,656 / 419 ms | 67 / 72 bytes | Nonblocking provider warning / cooldown |

`EXPLAIN (ANALYZE,BUFFERS)` for a local school envelope selected
`Bitmap Index Scan on schools_location_gist`; that cold sample executed in
17.071 ms, with 251.221 ms separate planning time. A DC crossing query used `infrastructure_geometry_gist` and executed in 18.858 ms (57.457 ms separate planning). Nationwide queries naturally
aggregate a broad dataset. Automated panning tests verify **zero additional RPCs**
within buffered coverage, and 100 rapid viewport changes produce only the running
request plus the final viewport request. Low zoom generates zero infrastructure
queries. A failed optional layer does not delay successful school/hazard data.
There is no measured before/after startup speedup claim: the old browser startup
was not timed under matching conditions.

Development builds expose **Map diagnostics**: zoom, bounds, source state/errors,
feature/marker counts, active/completed requests, durations, decoded JSON byte
estimates, parsing time, cache hit rate, and elapsed first map/school/hazard data.
These are disabled in release UI. The clock begins at map-service construction;
first-map means `onMapReady`, not first raster image. HTTP compression/wire bytes
and end-to-end Flutter startup-to-first-paint require browser DevTools/profiling.
Initial targets are local first-school data within 2 seconds on a healthy
connection, cached-region movement with zero network requests, and no optional
infrastructure load below zoom 15. Validate targets in the deployment environment.

Checks:

```powershell
flutter analyze --no-pub
flutter test
flutter build web
python -m unittest discover -s scripts -p test_imports.py
npx.cmd --yes deno check supabase/functions/map-infrastructure/index.ts
npx.cmd --yes deno test supabase/functions/map-infrastructure/osm_normalize_test.ts
git diff --check
```

Run `supabase/checks/nationwide_map.sql` through trusted SQL tooling. It checks
lossless national/dense clusters, antimeridian bounds, classification, detail
limits, function invoker security, and anonymous/unrelated-member hazard RLS.
The regional GeoJSON-to-PostGIS-to-RPC path was tested both with a synthetic record in a rolled-back transaction and the real DC extract. No fabricated infrastructure was retained.

The nationwide NCES import, real regional OSM import, and RPC checks were executed. A real Geofabrik District of Columbia extract was downloaded and filtered to
`dc-core` (-77.06,38.88,-77.02,38.92). The regional pipeline imports 12,190
normalized category features. Other regions continue to use the bounded fallback
until their extracts are ingested. Public Overpass remains
unreliable; keep a managed provider or regional ingestion for production. The
configured fallback intentionally has a conservative shared upstream budget.
No nationwide OSM extract was downloaded or imported; the DC trial is the only preprocessed region. Browser inventory
was empty in this session, so manual visual testing and real device/network
startup measurements were unavailable. Automated responsive/accessibility widget tests and live API checks cover the implemented behavior. The suite passes 63 Flutter tests, 8 Python import tests, and 3 Edge parser tests, plus the SQL assertions. Replaying 300 imported infrastructure records kept the DC count at 12,190. The standard web build
passes; its Wasm dry run warns about the existing transitive `image` dependency.
