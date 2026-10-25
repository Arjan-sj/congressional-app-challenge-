# Free infrastructure loading and fallback

Supabase remains the primary source. Flutter uses the additive
`infrastructure_viewport` RPC, which wraps the existing indexed/keyset-paged
`infrastructure_in_view` function. Schools, hazards, ORS routes, and raster tiles
remain independent. No Flutter map code calls public Overpass directly.

## Coverage and failure behavior

`infrastructure_import_regions` records reviewed extraction bounds, categories,
source URL/time, checksum, import time, feature count, attribution and freshness.
Only trusted database/service-role operators can write it. Public readers can
read this public OSM metadata through RLS; report visibility policies are unchanged.
Adjacent regions can jointly cover a viewport, but every requested category must
be covered. Coverage queries use a GiST bounding-box filter before geometry union.

| Database result | Action |
| --- | --- |
| Fresh complete import, including zero features | Use Supabase; no fallback |
| Usable imported features, incomplete/stale provenance | Display with partial/unknown coverage; no automatic fallback |
| No features and missing, stale or partial import coverage | Eligible bounded Edge fallback |
| Missing RPC/invalid metadata | Fail closed; no speculative upstream query |
| Successful empty fallback | Cache as a successful empty query |
| Failure without valid current-viewport cache | Hide the five optional chips, keep Schools/Hazards, explain temporary unavailability and offer Retry |

The Edge Function independently rechecks coverage so callers cannot force an
Overpass request for an already covered empty area. Its existing provider allowlist,
database global/regional cooldowns, concurrent coalescing, one-day geographic cache,
18-second upstream timeout, byte/feature limits and Retry-After handling remain.
Flutter retains the 300 ms debounce, one active load per source, latest viewport
scheduling, primary-layer priority, bounded cache, zoom/extent eligibility,
stale-generation guards and cooldown-aware Retry. Cache bounds and original expiry
are preserved. Hiding chips never changes request eligibility or layer preferences.
Legacy list-returning RPC adapters remain supported for injected services; the
production Supabase factory requires the new metadata contract.

“Complete” describes the supported extraction/query, never the real world.
Missing OSM features mean unknown. Old OSM deletions require a separate reviewed
regional reconciliation; this workflow does not delete infrastructure.

## Schaumburg demonstration area: prepare locally, review, then deploy

Priority box: west **-88.25**, south **41.96**, east **-87.94**, north **42.13**.
It covers Schaumburg and nearby parts of Hoffman Estates, Streamwood, Hanover Park,
Roselle, Elk Grove Village and Rolling Meadows; it is not a municipal boundary.
Use the official [Geofabrik Illinois regional extract](https://download.geofabrik.de/north-america/us/illinois.html),
licensed under [OSM ODbL](https://www.openstreetmap.org/copyright).
Keep downloaded/generated data under ignored `private/`, never in the Flutter bundle.
The initial implementation was local only. The approved production deployment is recorded below.

```powershell
py -3.14 -m venv build/infrastructure-venv
build/infrastructure-venv/Scripts/python.exe -m pip install -r scripts/requirements-infrastructure.txt
New-Item -ItemType Directory -Force private/infrastructure-demo
Invoke-WebRequest https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf -OutFile private/infrastructure-demo/illinois-latest.osm.pbf
build/infrastructure-venv/Scripts/python.exe scripts/export_osm_region.py private/infrastructure-demo/illinois-latest.osm.pbf private/infrastructure-demo/schaumburg-area.geojsonseq --bbox=-88.25,41.96,-87.94,42.13 --source-url=https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf
$manifest = Get-Content private/infrastructure-demo/schaumburg-area.geojsonseq.manifest.json | ConvertFrom-Json
build/infrastructure-venv/Scripts/python.exe scripts/import_infrastructure.py private/infrastructure-demo/schaumburg-area.geojsonseq --region il-schaumburg-area --source-updated-at $manifest.source_updated_at --coverage-manifest private/infrastructure-demo/schaumburg-area.geojsonseq.manifest.json --dry-run
build/infrastructure-venv/Scripts/python.exe scripts/import_infrastructure.py private/infrastructure-demo/schaumburg-area.geojsonseq --region il-schaumburg-area --source-updated-at $manifest.source_updated_at --coverage-manifest private/infrastructure-demo/schaumburg-area.geojsonseq.manifest.json --sql-dir private/infrastructure-demo/sql
```

The exporter generates a manifest only after finishing; unresolved way geometry
marks it incomplete. The importer checks its hash, bounded extent (maximum two
degrees per axis), official HTTPS source, timestamp and complete categories before
any writes. It emits coverage SQL separately and **never applies it automatically**.
The default 14-day freshness starts at the source replication timestamp, not import
time (configurable 1–30 days). An old extract cannot become fresh by reimporting it.

After explicit deployment approval:

1. Apply `20261025005532_infrastructure_coverage.sql` to staging first. Existing
   migrations and the old RPC stay intact. Test the new client/Edge build there.
2. Review the manifest bounds, source timestamp, checksum, batch counts and samples
   around the demonstration schools. Do not infer complete coverage from existing
   rows or register an arbitrary bounding box around the old DC import.
3. For a region refresh, expire its existing coverage metadata **before** the first
   batch, using trusted tooling. For example, set its `fresh_until` to `now()`.
   Never run the final coverage SQL after a partially failed upload.
4. Apply only the numbered feature batches in order, verify category/count/geometry
   samples, then explicitly review/apply `coverage-after-review.sql` last. Feature
   upserts and coverage upserts are repeatable. No report/school/auth data changes.
5. Deploy the Edge Function after the migration; release the Flutter client after
   the function. An older hosted schema fails safely with usable schools/hazards
   and an infrastructure setup error. No secret/service-role key belongs in Flutter.
6. Validate an imported viewport, a covered empty viewport, an uncovered viewport,
   a rate limit and a retry. Refresh extracts before freshness expires. Review
   regional removal of deleted OSM features separately; no automatic deletion.

Use a new SQL directory for each preparation; an existing SQL bundle is rejected
so leftover batches cannot enter a smaller/newer import. Never combine `--dry-run`
and `--sql-dir`. Coverage is not prepared when any geometry was skipped.

## Routing key audit and proposed proxy

Before the routing proxy update, `OpenRouteService` sent `OPENROUTESERVICE_API_KEY` from a Dart define in
the client Authorization header. Compiled web/mobile clients expose that key;
obfuscation and CORS do not secure it. No key values were copied or printed.
This change keeps ORS profiles, GeoJSON decoding, alternatives, 100 m avoidance and
Flutter PolylineLayer rendering. Equivalent exact request bodies share one pending
request and successful routes have a bounded 24-entry, 30-second memory cache.
Changed endpoints/profiles/avoidance geometry use distinct keys; errors are never
cached. Visibility changes and disposal clear the cache. No persistent route cache.

A future, separately approved `route-directions` Edge proxy should:

- Keep the ORS key in an Edge secret and rotate the previously distributed key
  after client migration. Use the existing Supabase publishable key in Flutter.
- Verify Supabase Auth and active sessions server-side (including revoked/deleted
  accounts rather than trusting an unexpired JWT alone), allowlist only walking/cycling profiles and a
  fixed ORS endpoint, validate coordinates, payload size and avoidance geometry,
  and retain server-side hazard visibility/100 m avoidance rules. Never accept an
  arbitrary upstream URL, key, profile or trusted client safety score.
- Enforce atomic per-user and global minute/day quotas in Postgres, below the
  project's actual free ORS and Supabase limits. Count both comparison requests,
  use short locks for duplicate requests, and return 429/Retry-After without loops.
- Use short cache lifetimes keyed by normalized exact geometry, profile, active
  hazard version and authorization scope. Never share private report-derived
  routes across users. Bound concurrency/timeouts and redact location/key logs.
- Return the existing ORS GeoJSON contract so the routing engine and rendering
  remain intact. Test revoked sessions, malicious payloads, quota races, failures,
  alternatives and privacy before enabling; provide a reviewed rollback switch.

The subsequent [routing proxy update](ROUTING_PROXY.md) implements the server-only
secret path. No paid service or new routing engine is used.

## Tiles and verification

`MAP_TILE_URL` already configures the existing TileLayer. `flutter_map` 8.3.2 uses
[built-in caching on native platforms and browser HTTP caching on web](https://docs.fleaflet.dev/layers/tile-layer/caching).
Keep provider cache headers, the app User-Agent, browser Referer and visible
OSM attribution. Follow the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/);
do not add cache-busting, bulk downloads or prefetch. Tile errors have their own
message/retry and cannot hide infrastructure chips. No extra tile dependency added.

```powershell
flutter analyze
flutter test --no-pub
npm test --prefix supabase/tests
npx --yes deno test supabase/functions/map-infrastructure/
npx --yes deno check supabase/functions/map-infrastructure/index.ts
py -3.14 -m unittest discover -s scripts -p 'test_*.py'
# Optional real-extract check: ephemeral local PostgreSQL only, no hosted writes.
node supabase/tests/infrastructure-region.mjs private/infrastructure-demo/sql
```

Request-count measurements are deterministic local tests with injected transports,
not live upstream latency claims: a covered empty viewport now makes zero fallback
calls; 20 repeated views use one database load. Twenty concurrent equivalent routes
plus an immediate repeat use one ORS transport call instead of 21 (95.2% fewer).
Failures, cache expiry, changed hazards/profiles, independent primary layers,
rapid movement, zoom gating, cooldowns, restoration and tile failures are tested.
Hosted coverage migration/Edge deployment, production import and real-device
latency still require the approved deployment workflow above.

## Local validation results, 2026-10-24

The real Geofabrik Illinois extract (345 MB, replication timestamp
`2026-10-23T20:20:51Z`) produced **30,102 OSM features / 30,143 category records**
inside the demonstration bounds, with zero skipped geometries or unresolved ways.
The 101 prepared SQL batches and the separate coverage statement are under ignored
`private/infrastructure-demo/sql/`. GeoJSON SHA-256:
`4e26d2a2f7f7dc2e8682bdd82e63f26f3fe73f884cec1e0796759963213dccf2`.
At initial validation, no data had been uploaded. The subsequent approved upload is recorded below.

An ephemeral local PostgreSQL/PostGIS database loaded all 30,143 records and
verified repeat batch/coverage upserts without duplicates. Anonymous viewport
queries returned the following real data with complete extraction coverage and
zero required Overpass requests:

| Test viewport | Features | Database pages | Overpass requests |
| --- | ---: | ---: | ---: |
| Schaumburg High School area | 76 | 1 | 0 |
| Hoffman Estates area | 265 | 1 | 0 |
| Elk Grove Village area | 851 | 2 | 0 |

Automated verification: Flutter analyzer clean; 139 Flutter tests; six SQL suites;
15 Node workflow tests; 14 Deno tests and Edge type check; 33 Python tests; standard
Flutter web build. The web build reports existing `image` package Wasm dry-run
incompatibilities; Wasm support and native-device performance were not verified.
Live upstream failure scenarios use injected test transports, rather than creating
load on public providers. At initial validation, interactive browser/device checks
were unperformed. Subsequent production API and Chrome checks are recorded below.

## Approved production deployment, 2026-10-24 (Chicago)

After explicit user approval, deployed to project `bnvmlxgdqgwjtxgtsaak`:

- Applied `infrastructure_coverage` (hosted version `20261025005532`). The new
  local migration filename matches that generated hosted version; SQL is unchanged.
- Uploaded all 101 prepared batches: 30,143 category records from 30,102 OSM
  objects, with zero invalid/empty geometries. Registered coverage only after
  verifying counts, source timestamps and categories. Freshness expires
  `2026-11-06T20:20:51Z`; refresh the extract before then.
- Deployed `map-infrastructure` version 5, preserving its existing project-key
  authentication and `verify_jwt=false` setting.
- Preserved the 12,190 DC infrastructure records, 124,689 school records and
  14 hazard reports. No school/report/history/auth records were modified.
- Verified live anonymous HTTP 200 responses at zoom 15.4 for the reported bounds
  `[42.021354196721724,-88.12123435781078,42.03165222276724,-88.08415544274393]`:
  87 features in the exact viewport (389 ms), 248 in the app's 15% buffered viewport
  (140 ms), and 87 from the Edge Function (510 ms). These are single-request
  observations, not latency guarantees. All had complete extraction coverage;
  the RPC returned `fallback_required=false` and Edge reported
  `source='Supabase regional import'` without using Overpass.
- Security advisors reported no finding on the new public coverage table. Existing
  project findings remain: private service-only tables without client policies,
  and [disabled leaked-password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

Reload the app (or use Retry after cooldown) to discard the cached setup failure.
No Git commit or push was made.

## Empty clipped geometry follow-up

Chrome reproduced the remaining unavailable state after deployment. A successful
HTTP 200 viewport response contained 361 rows, including crossing
`n6498454367/crossing` with valid empty GeoJSON `Point` coordinates `[]` after
PostGIS clipping. The decoder indexed that empty coordinate array, causing a
RangeError and marking the whole infrastructure layer unavailable.

`MapDataService.infrastructureFeatures` now skips empty coordinate arrays, just as
it already skipped empty collections/lines. A regression test combines empty
clipped Point/LineString geometries with a valid sidewalk and checks that coverage
stays complete, usable features remain visible, controls stay available, and no
Overpass fallback runs. Analyzer clean; all 140 Flutter tests pass.

For an already running `flutter run -d web-server` session, press uppercase `R`
in its terminal to compile the updated source. A browser refresh by itself can
continue serving that session's old compiled modules.

A fresh standard web build with the production public configuration was served
locally at `http://127.0.0.1:7358/` and verified interactively in Chrome. The map
showed `OSM query coverage: complete` with all optional controls restored:
Sidewalks 88, Crossings 199, Bike paths 28 and Bike lanes 49. Walking paths remain
zoom-dependent. The rendered counts include clipped geometry components.
Screenshot: ignored `build/verification/infrastructure-chrome-fixed.jpg`.
The original debug server on port 7357 still requires a terminal hot restart to
load the changed Dart source. Standard web build passed; existing dependency Wasm
dry-run warnings remain. No commit/push or additional production changes were made.

## Changed files

- `README.md`, `docs/NATIONWIDE_MAP.md`, `docs/PHASE6_INFRASTRUCTURE.md`: entry points,
  deployment/import instructions, measurements, limitations and ORS proxy plan.
- `lib/services/map_data_service.dart`: production coverage RPC adapter, metadata
  validation, fallback eligibility and original coverage expiry.
- `lib/services/open_route_service.dart`, `lib/screens/explore_screen.dart`:
  bounded route cache/coalescing, immutable cached geometry and visibility invalidation.
- `lib/widgets/map_layer_controls.dart`: required temporary-unavailability message.
- `scripts/export_osm_region.py`, `scripts/import_infrastructure.py`,
  `scripts/infrastructure_coverage.py`: bounded extraction provenance, checksum
  validation, safe preparation and separately reviewed coverage SQL.
- `supabase/migrations/20261025005532_infrastructure_coverage.sql`: additive public
  coverage registry, GiST/RLS/grants and invoker RPC; no historical migration edits.
- `supabase/functions/map-infrastructure/index.ts`,
  `supabase/functions/map-infrastructure/infrastructure_response.ts`: server-side
  Supabase-first eligibility check; existing fallback budgets/cache remain.
- `supabase/checks/infrastructure_coverage.sql`, `supabase/tests/run.mjs`,
  `supabase/tests/infrastructure-region.mjs`: coverage/RLS/pagination regression
  checks and optional real-extract local integration check.
- `test/infrastructure_coverage_test.dart`, `test/open_route_service_test.dart`,
  `test/map_layer_availability_test.dart`,
  `supabase/functions/map-infrastructure/infrastructure_response_test.ts`,
  `scripts/test_infrastructure_coverage.py`: focused request-count, safety,
  caching, availability and provenance tests.
