# SafeRoutes 🚸

A Flutter application for documenting school walking and biking concerns. Built for the Congressional App Challenge.

The Flutter app includes imported nationwide NCES schools and cached OpenStreetMap infrastructure, walking/cycling route comparison through OpenRouteService, anonymous Supabase-backed reports and community review, hazard ranking, device location, and accessibility settings. Route scores are decision aids, not safety guarantees.

The separate Analytics workspace adds RLS-aware overview metrics, trends,
interactive hazard heatmaps, school/category comparisons, Realtime refresh,
and privacy-safe CSV, XLSX, PDF, JSON, and GeoJSON exports. See
[Analytics architecture and verification](docs/ANALYTICS.md).

The nationwide map now uses indexed geographic queries, independent layer loading,
clustering, and bounded server-side infrastructure caching. See
[architecture, imports, deployment, and measured checks](docs/NATIONWIDE_MAP.md).

Optional infrastructure failures now hide the five infrastructure selection chips
when no valid current-area cache exists, while keeping Schools, Hazards and Retry
available. See [Phase 6 map availability, caching and recovery](docs/MAP_INFRASTRUCTURE_AVAILABILITY.md).

Coverage-aware Supabase loading, the reviewed Schaumburg-area import workflow,
route request deduplication, tile caching audit and routing proxy plan are in
[Phase 6 infrastructure optimization](docs/PHASE6_INFRASTRUCTURE.md).

Routing uses the server-only `OPENROUTESERVICE_API_KEY` Supabase Edge secret through
the [route-directions proxy](docs/ROUTING_PROXY.md); no ORS key is compiled into Flutter.

For isolated testing, see the [Phase 1 staging hazard workflow](docs/STAGING_HAZARD_WORKFLOW.md):
separate environment settings, read-only previews, backed-up Storage API cleanup,
and reproducible synthetic fixtures. Production resets are blocked.

For verified NCES public-school district relationships, see the
[Phase 2 district schema, preview and reviewed backfill workflow](docs/SCHOOL_DISTRICTS.md).

Anyone can report a concern, vote or flag through the Community tab. Three agreeing
reviews from independent connections change a report's status. See
[anonymous reporting, consensus, privacy and deployment](docs/COMMUNITY_REVIEW.md).

## Run locally (macOS or Linux)

Install [Flutter](https://docs.flutter.dev/get-started/install), Git, and Google Chrome first. Then:

```bash
git clone https://github.com/Arjan-sj/congressional-app-challenge-.git
cd congressional-app-challenge-
flutter doctor
flutter pub get
flutter run -d chrome
```

To try the setup changes **before they are merged**, check out `setup/saferoutes-flutter-foundation` after cloning:

```bash
git fetch origin
git switch setup/saferoutes-flutter-foundation
flutter pub get
flutter run -d chrome
```

## Repository structure

```text
lib/
  main.dart                 # launches SafeRoutesApp
  app.dart                  # MaterialApp/theme
  models/hazard_report.dart # shared in-memory report model
  models/                   # reports, infrastructure, bounds, and routes
  services/                 # Overpass, OpenRouteService, Supabase, scoring
  screens/home_screen.dart  # main navigation / state
  screens/explore_screen.dart
  screens/report_form_screen.dart
  screens/reports_screen.dart
test/                       # smoke/unit tests
docs/SETUP.md               # installation + collaboration
docs/INTEGRATION_CONTRACT.md# teammate data interface
```

## Developer workflow

1. **Map/UI developer:** maintain the geographic layer in `explore_screen.dart` and the reusable API services after checking provider terms.
2. **Backend developer:** implement Supabase tables + Row Level Security, then replace in-memory report creation with a repository implementation.
3. Agree on the report fields documented in [INTEGRATION_CONTRACT.md](docs/INTEGRATION_CONTRACT.md) before either side adds an API.
4. Both work on separate GitHub branches and open pull requests.
5. Run checks before merging:

```bash
flutter pub get
flutter analyze
flutter test
```

## Safety and privacy

- **Community agreement is not professional verification.** The map always shows each report's review status.
- Walking and cycling requests avoid 100 m buffers around active visible reports as a precaution; only reviewed reports affect the numeric safety score.
- Missing OpenStreetMap infrastructure is unknown; it must never be described as unsafe.
- Do not store student names, home addresses, school commute routines, or photos of identifiable children.
- Never put Supabase `service_role` / secret keys into client code or GitHub.
- Route recommendations must only use sufficiently verified legal paths and must never promise that a route is safe.

See [Setup instructions](docs/SETUP.md), [data contract](docs/INTEGRATION_CONTRACT.md), and [original logistics plan](docs/LOGISTICS.md).


## Optional Supabase test integration
See [Flutter connection guide](docs/CONNECT_FLUTTER.md).

## Community review

New reports and photos are public. Share an observation, review concerns or flag
inaccuracies. Review counts and consensus refresh the existing report, map and
Analytics; no special role is needed. See [Community review](docs/COMMUNITY_REVIEW.md).
