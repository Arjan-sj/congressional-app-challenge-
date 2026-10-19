# SafeRoutes interactive map

## Implemented data sources

- `flutter_map` with OpenStreetMap-compatible raster tiles for pan/zoom.
- Overpass API viewport queries for schools, mapped sidewalks, pedestrian crossings, bike paths, and bike lanes.
- Supabase `hazard_reports` for RLS-filtered community reports and authenticated inserts.
- OpenRouteService walking and cycling alternatives with GeoJSON geometry.
- Optional device-location recentering on web, Android, and iOS.

The app does not include fabricated map features or seeded hazard pins. The initial camera remains centered on the pilot community, but nearby features come from live APIs.

## Configuration

Pass public client configuration at build/run time. Never use a Supabase secret or `service_role` key in Flutter.

```bash
flutter run -d chrome --web-port 7357 \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY \
  --dart-define=OPENROUTESERVICE_API_KEY=YOUR_ORS_KEY
```

Optional endpoints:

```bash
--dart-define=MAP_TILE_URL=https://tile.openstreetmap.org/{z}/{x}/{y}.png
--dart-define=OVERPASS_URL=https://maps.mail.ru/osm/tools/overpass/api/interpreter
```

Client-side keys are visible in web/mobile builds. Restrict provider keys where supported and use a server-side proxy before high-volume production use.

## Infrastructure loading

The map waits 850 ms after movement, queries only at zoom 14 or closer, expands the viewport slightly, and loads it as four bounded chunks with at most two requests in flight. Completed chunks appear immediately, ten-minute cache entries are reused, stale responses are ignored, and connection or server failures automatically try the fallback endpoint. HTTP 429, total outages, and empty results are shown without disabling the basemap, hazards, or other controls.

OpenStreetMap sidewalk and cycleway tagging varies by community. A missing line means **unknown**, not absent or unsafe. Road centerlines carrying `sidewalk=*` or `cycleway=*` indicate mapped tagging; they are not surveyed curb-level geometry.

## Route scores

OpenRouteService is queried for `foot-walking` and `cycling-regular` alternatives. Before routing, each visible active report (`unverified` or `verified`) becomes a 100 m GeoJSON avoid area. Resolved and rejected reports do not block a route. If a start or destination is already inside an avoid area, the app asks the user to move that point.

Each returned route begins at 80 points:

- subtract up to 15 points for extra distance compared with the shortest route of the same mode;
- subtract `severity × 4` for each verified, unresolved hazard within 50 m, capped at 40 points;
- add up to 20 points for route samples close to mapped mode-appropriate infrastructure.

Unverified, rejected, and resolved reports do not reduce a route score. Missing or partially loaded infrastructure receives no penalty and is called out as unknown. Scores are transparent comparisons, not collision-risk models or promises of safety.

## Map/provider responsibilities

- Retain visible OpenStreetMap attribution and follow the tile provider's usage policy.
- The public Overpass instance is appropriate for a low-volume pilot, not a high-volume production backend. Cache, debounce, and consider a hosted/self-managed instance at scale.
- OpenRouteService API restrictions and quotas apply. Production deployments should restrict keys or proxy calls.
- Android requests coarse/fine foreground location; iOS contains a when-in-use purpose string. Location is requested only after the user taps the location control and is not persisted.

## Verification

```bash
flutter pub get
dart analyze lib test
flutter test
```

Widget tests use `SafeRoutesApp(enableMapTiles: false)` so no map, Overpass, or location network/permission work occurs.
