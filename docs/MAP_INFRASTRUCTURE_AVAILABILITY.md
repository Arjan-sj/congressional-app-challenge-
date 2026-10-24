# Optional map infrastructure: availability and recovery (Phase 6)

Schools and Hazards remain available when optional OSM infrastructure fails. When the current viewport has no valid infrastructure cache, the five infrastructure selection chips are **removed**: Sidewalks, Walking paths, Crossings, Bike paths and Bike lanes. A small infrastructure-unavailable message and **Retry infrastructure** button remain. Successful responses restore all five controls automatically; a successful empty response restores them with an empty-mapping explanation.

This changes neither report visibility/RLS nor school records, report associations, moderation, photos or basemap providers. No migration, data reset, remote deployment, commit or push is part of this phase.

## Availability and coverage

`InfrastructureStatus` describes the current viewport and requested category set:

| Availability | Controls and display |
| --- | --- |
| Not requested | Controls available; enable layers or zoom closer |
| Loading | Initial controls remain; after failure they stay hidden until success unless a valid cache exists |
| Available | Show controls and returned features |
| Successfully loaded but empty | Show controls and explicit empty-data feedback |
| Failed/unavailable | Hide all five optional chips if no valid cache; keep Schools, Hazards and Retry |
| Valid cached data | Show controls and cached features, preserving their original bounds and timestamps |

Coverage is separate: **complete**, **partial**, **unknown** or **unavailable**. Complete means the requested Overpass query completed; it never means that every real-world sidewalk, path or crossing has been mapped. Partial identifies a feature-budget truncation. Indexed regional data has unknown geographic completeness unless the response explicitly establishes more. Missing OSM data is not proof that infrastructure does not exist and does not create a safety-score penalty.

Basemap tile failures only affect the existing tile warning/retry action. They cannot change infrastructure availability. Infrastructure failures cannot disable school/hazard requests or trigger tile retries.

## Scheduling, cache and retry rules

- Infrastructure remains optional at zoom 15+; ordinary walking paths remain at zoom >16. The buffered query must fit the Edge Function's 0.08° latitude/longitude limits and cannot cross the antimeridian. Retry explains when closer zoom is required.
- Chip visibility does not change remembered layer preferences or request eligibility. Even if the user turned every infrastructure preference off before a failure, explicit Retry can issue a bounded availability probe without selecting those layers.
- Retain the existing 300 ms camera debounce and geographic buffer. Only the latest viewport waits behind each source's in-flight work. Stale responses cannot replace current data; stale failures do not cool down an unrelated viewport, except provider-wide rate limits.
- Schools and Hazards start first. An already-running optional request does not occupy either primary request slot. At most two primary sources and one optional source can be running; identical source reads are coalesced.
- Preserve valid containing-viewport caches, including successful empty results. A full category cache can satisfy a subset without another request. Data is never relabelled with a new viewport's bounds. Cache expiry also invalidates displayed infrastructure without requiring a camera event.
- Keep existing 30-second hazard freshness and 24-hour directory/infrastructure cache limits. Edge cache timestamps cap client freshness at the original source expiry; reading a server cache cannot restart its TTL. Wrong bounds, expired entries and invalid provenance are rejected.
- One automatic retry is permitted for transient RPC reads. Edge fallback has a bounded timeout. Manual infrastructure retries respect all cooldowns, including 429 responses and HTTP-200 failure envelopes. Rate limits do not rotate Overpass providers.
- A failed infrastructure scope does not automatically retry forever when periodic hazard refreshes repeat the same viewport. Explicit Retry or a different eligible viewport can request recovery after cooldown. Remember at most 64 failed scopes; successful recovery clears its failure. Cooldown timers enable the button without sending requests themselves.
- Repeated cached camera events do not notify/rebuild the infrastructure UI. Infra RPC pagination stops if the keyset fails to advance; infrastructure responses are capped at 5,000 features and marked partial at the cap. These limits do not truncate hazard report pagination.

The older direct `OverpassService` also coalesces forced requests, uses exact bounds for in-flight identities, honors numeric and HTTP-date Retry-After values, rejects incomplete/remark responses and only caches fully completed chunk requests.

## Edge Function

`map-infrastructure` retains its existing API-key validation, server-only credentials, database claim locks and provider cooldown. New `osm-v3` cache payloads contain query bounds, coverage, original fetched time and expiry. Expired or legacy unscoped payloads are not returned as successful data during cooldown. Concurrent identical reads share work within an isolate; database locks still enforce the cross-isolate provider budget. Cache database operations, auth checks and upstream fetches have explicit timeouts. Category and zoom inputs are validated.

Review and deploy the updated Edge Function through the existing Supabase deployment workflow before shipping the client. No database migration or production data modification is needed. Existing public Flutter keys and server secret configuration stay unchanged. Old cache rows can expire normally; no cache deletion/reset is required. The Flutter client also validates timestamps when communicating with an older deployment, but the new Edge metadata is needed for explicit complete/partial query coverage.

## Verification

```powershell
flutter analyze
flutter test --no-pub
npx --yes deno check supabase/functions/map-infrastructure/index.ts
npx --yes deno test supabase/functions/map-infrastructure/
flutter build web --no-pub
git diff --check
```

Tests cover success, all six availability states, empty responses, malformed data, timeouts, SDK and HTTP-200 rate limits, cooldowns, cache expiry, wrong viewport rejection, late results, geometry decoding, bounded pagination, category superset reuse, primary-layer independence, forced request deduplication, recovery with all preferences off, lack of periodic retry loops, enlarged mobile controls, live Explore recovery and independent tile failures. Test infrastructure HTTP/database responses are simulated; they do not exercise or alter a hosted project.

Before a deployment, verify the real Edge Function on a small viewport, then simulate provider loss and recovery in staging. This local work does not establish upstream uptime, nationwide OSM completeness or production-volume latency. Standard web build success does not validate Wasm compatibility.

Local results (2026-10-24): `flutter analyze` is clean; all **121 Flutter tests** and **13 Deno tests** pass; the Edge Function passes `deno check`; `git diff --check` is clean; the standard web build passes. The existing `image 4.3.0` dependency still emits Wasm dry-run warnings. No hosted deployment, live-provider reliability check or production data changes were performed. Changes remain uncommitted on `main`.

## Changed files

- `lib/models/infrastructure_availability.dart`: explicit availability/coverage/status model.
- `lib/models/osm_infrastructure.dart`: snapshot coverage metadata.
- `lib/services/map_data_service.dart`: viewport-safe caches, independent scheduling, bounded requests, cooldowns, expiry and recovery.
- `lib/services/overpass_service.dart`: direct-provider deduplication, scoped cache, Retry-After and response validation.
- `lib/screens/explore_screen.dart`: source bounds/timestamps, availability wiring and isolated service/tile test injection.
- `lib/widgets/map_layer_controls.dart`: hide/restore optional chips, coverage/empty feedback and guarded Retry.
- `supabase/functions/map-infrastructure/index.ts`: scoped cache validation, failure envelopes, input checks, timeouts and request coalescing.
- `supabase/functions/map-infrastructure/infrastructure_response.ts`: cache/response and in-flight helpers.
- `supabase/functions/map-infrastructure/infrastructure_response_test.ts`: Edge helper regression tests.
- `test/infrastructure_availability_test.dart`: scheduler/cache/retry state regressions.
- `test/map_layer_availability_test.dart`: control and Explore recovery/tile/mobile regressions.
- `test/overpass_service_test.dart`: direct-provider recovery and request identity regressions.
- `README.md` and this guide: workflow and test/deployment documentation.
