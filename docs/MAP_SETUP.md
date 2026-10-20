# SafeRoutes interactive map

For the current nationwide architecture, deployed NCES data, import commands,
measurements, and infrastructure coverage limits, see [Nationwide map](NATIONWIDE_MAP.md).

## Implemented data sources

- `flutter_map` with OpenStreetMap-compatible raster tiles for pan/zoom.
- Supabase PostGIS viewport queries for imported NCES schools and cached OSM infrastructure, with a bounded server-side infrastructure fallback.
- Supabase `hazard_reports` for RLS-filtered community reports and authenticated inserts.
- OpenRouteService walking and cycling alternatives with GeoJSON geometry.
- Optional device-location recentering on web, Android, and iOS.

The app does not include fabricated map features or seeded hazard pins. The initial camera remains centered on the pilot community, but nearby features come from live APIs.

## Configuration

The existing public Supabase URL and publishable key are configured in
`lib/main.dart`. Keep service-role credentials on the server. Optional runtime
configuration:

```bash
flutter run -d chrome --web-port 7357 --dart-define=OPENROUTESERVICE_API_KEY=YOUR_ORS_KEY
```

`MAP_TILE_URL` can select a compatible raster provider. Infrastructure provider
configuration is now server-side; see [deployment](NATIONWIDE_MAP.md).

## Infrastructure loading

The map waits 300 ms after movement. Schools and hazards load concurrently;
optional infrastructure starts at zoom 15 with independent loading/error states.
Buffered geographic caches avoid repeat requests. Schools come from the imported
NCES directory, not Overpass. Infrastructure comes from indexed regional data or
the server-cached bounded fallback. See [details](NATIONWIDE_MAP.md).

OpenStreetMap sidewalk and cycleway tagging varies by community. A missing line means **unknown**, not absent or unsafe. Road centerlines carrying `sidewalk=*` or `cycleway=*` indicate mapped tagging; they are not surveyed curb-level geometry.

## Route scores

OpenRouteService is queried for `foot-walking` and `cycling-regular` alternatives. Before routing, a geographically scoped hazard read loads reports around both endpoints. Each active report (`unverified` or `verified`) becomes a 100 m GeoJSON avoid area. Resolved and rejected reports do not block a route. If a start or destination is already inside an avoid area, the app asks the user to move that point.

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
flutter analyze --no-pub
flutter test
```

Widget tests use `SafeRoutesApp(enableMapTiles: false)` so no map, Overpass, or location network/permission work occurs.
