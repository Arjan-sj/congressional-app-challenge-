# Server-side OpenRouteService routing

The app calls `route-directions` through its existing Supabase client. The Edge
Function reads the existing `OPENROUTESERVICE_API_KEY` project secret; neither the
ORS key nor the service-role key is copied to Flutter, source control, responses,
or logs. Keep only the Supabase URL and publishable key in client configuration.
Old ORS Dart defines are no longer read by the app and can be removed from local
launch settings. Previously distributed client keys should be rotated separately.

Walking/cycling profiles, ORS GeoJSON decoding, route alternatives, 100 m avoidance
polygons and Flutter PolylineLayer rendering are unchanged. The proxy validates
finite coordinates, allowed profiles, closed/bounded avoidance polygons, sizes and
alternative settings. It uses a fixed HTTPS ORS endpoint. It never accepts a
client-supplied provider URL, credential, extra provider option or safety score.
Avoidance geometry still comes from the existing RLS-aware hazard-loading path;
the proxy does not query or publish reports, authors, photos or moderation data.
Route scores remain decision aids, not guarantees.

The handler validates the project publishable key and verifies any supplied user
session through Supabase Auth. Anonymous routing remains available, matching the
existing app. `verify_jwt=false` is intentional because the handler authenticates
modern publishable keys itself, like the infrastructure function. Cross-origin
requests use explicit CORS headers; no browser cookies or secret headers are added.

## Quotas and caching

`claim_route_request` is `SECURITY INVOKER`, callable only by `service_role`.
Its new RLS-protected `route_proxy_requests` table contains only hashed actor IDs
and timestamps, never route coordinates. A short transaction advisory lock makes
limits atomic across Edge isolates. Sliding limits are deliberately below the
documented ORS default limits:

- Global: 20 upstream requests per rolling minute, 1,000 per rolling 24 hours.
- Per actor: 6 per rolling minute, 100 per rolling 24 hours. Each walking/cycling
  comparison can consume two requests. Signed-in actors use verified Auth IDs;
  anonymous actors use a hash of gateway-forwarded IP or a shared fallback bucket.
  The global cap remains authoritative even if anonymous identity is unreliable.
- Expired quota entries are removed after 24 hours. No community/audit records are
  modified. Errors count against quota because providers can count failed calls.
- Identical in-flight requests coalesce per isolate. Successful exact responses
  have a 30-second, 32-entry memory cache scoped to the actor and full request
  geometry. No route geometry is stored in Postgres or shared between actors.
- Existing Flutter 30-second/24-entry caching and visibility invalidation remain.
- Quota/provider throttles return 429 with Retry-After. There is no automatic
  upstream retry loop. Provider timeout is 18 seconds; Flutter proxy timeout is 30.

Provider restrictions and quotas can change; consult the project's ORS dashboard
and [official restrictions](https://openrouteservice.org/restrictions/) and
[quota FAQ](https://giscience.github.io/openrouteservice/frequently-asked-questions.html).
Avoidance extents are bounded to 20 km, matching the provider's documented limit.

## Deployment and verification

1. Apply the additive `route_proxy_limits` migration. Existing migrations stay intact.
2. Keep `OPENROUTESERVICE_API_KEY` set in the project's Edge Function secrets.
   Deployment reads it through `Deno.env`; no secret value needs to be retrieved.
3. Deploy `supabase/functions/route-directions/` with its handler and
   `verify_jwt=false`; the handler validates the project key and signed-in sessions.
4. Release/rebuild Flutter. No new client routing configuration is needed.
5. Test short walking and cycling routes, avoidance polygons, quota failures,
   invalid coordinates/credentials and UI error recovery. Confirm browser network
   requests target the Supabase function, with no direct ORS Authorization header.

```powershell
flutter analyze
flutter test --no-pub
node supabase/tests/run.mjs
npx --yes deno test supabase/functions/route-directions/
npx --yes deno check supabase/functions/route-directions/index.ts
```

The app no longer displays prototype/environment badges or the map's pilot badge.
Environment configuration and staging/reset safeguards retain their existing names
and behavior. Demo reports remain explicitly labeled to distinguish synthetic data.

## Deployed and verified

Applied `20261025035551_route_proxy_limits.sql` and deployed `route-directions`
version 1 to project `bnvmlxgdqgwjtxgtsaak`. The existing ORS secret was used without
reading or copying its value. Live anonymous requests returned HTTP 200 for walking
(1,808 m), cycling (1,774.2 m), and a walking request carrying a 100 m avoidance
polygon. These sample routes use public Schaumburg-area coordinates.

The fresh Flutter web build was tested in the in-app browser (Chrome was
disconnected). A real app comparison displayed walking 0.56 km / 7 min and cycling
0.58 km / 4 min. Network inspection confirmed Supabase function responses, with no
direct ORS request from the browser. The app header and map have no environment or
pilot badges. Evidence: ignored `build/verification/route-proxy-working.jpg`.

Validation: analyzer clean; all 142 Flutter tests pass; all seven SQL suites pass;
21 Edge tests pass (7 routing + 14 infrastructure); Edge type check and standard
web build pass. Existing dependency Wasm dry-run warnings remain. Security advisors
reported no new routing-table finding; the existing
[leaked-password protection warning](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)
is unrelated and unchanged. No report, school, photo, membership or audit data was
modified. Existing migration SQL was not edited. No Git commit or push was made.

Changed files: `lib/services/open_route_service.dart`,
`lib/screens/explore_screen.dart`, `lib/screens/home_screen.dart`,
`lib/screens/analytics_screen.dart`, `lib/widgets/route_planner_panel.dart`,
`supabase/functions/route-directions/{index.ts,handler.ts,handler_test.ts}`,
`supabase/migrations/20261025035551_route_proxy_limits.sql`,
`supabase/checks/route_proxy_limits.sql`, `supabase/config.toml`,
`supabase/tests/run.mjs`, `test/open_route_service_test.dart`,
`test/widget_test.dart`, `test/live_moderation_test.dart`, `README.md`,
`docs/{CONNECT_FLUTTER.md,SETUP.md,MAP_SETUP.md,PHASE6_INFRASTRUCTURE.md,ROUTING_PROXY.md}`.

Rebuild/restart an existing Flutter development session (uppercase `R` in its
terminal) to load the new client path. A browser refresh alone may keep the old
compiled development code. No ORS client key/flag is required.
