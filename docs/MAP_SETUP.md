# SafeRoutes interactive map — Mac and Linux

## What is implemented

- A **real OpenStreetMap basemap** in Flutter using `flutter_map`.
- Pilot focus: **Schaumburg High School**, 1100 W Schaumburg Rd, Schaumburg, IL.
- A school marker using approximate published campus coordinates; **not** a verified pedestrian entrance.
- Click/tap the map to select a location, then select **Report this location (demo)**.
- The report form uses the selected latitude/longitude; the newly created **fictional report** appears on the map as a marker and in the Reports tab.
- A marker opens its issue type, severity, and **unverified** status.
- Filter visible markers by category and recenter the map.

**Not yet implemented:** real school search, sidewalk data validation, walk/bike route comparisons, backend storage, official reporting, verification, or geocoding. App state is **memory-only** and resets on restart.

## How to run in IntelliJ IDEA (Mac)

1. Open the repo's **root folder** in IntelliJ, not `android/`.
2. Choose the `feature/interactive-school-map` branch. This branch builds on the still-open `setup/saferoutes-flutter-foundation` branch.
3. Open Terminal:

```bash
git fetch origin
git switch feature/interactive-school-map
flutter pub get
flutter analyze
flutter test
flutter run -d chrome
```

These same terminal commands work on Linux in VS Code after Flutter, Dart, Git and Chrome are installed.

## Try the whole map/report flow

1. Open Explore. You should see street tiles and a school icon.
2. Zoom and pan. Press the recenter icon to return to the pilot school.
3. Tap a nearby location. A purple selection pin and coordinate card should appear.
4. Click **Report this location (demo)**.
5. Enter a fictional issue description (5+ characters); click **Save demo report locally**.
6. You should return to Explore and see an orange report marker. Tap it for details.
7. Tap Reports and find the new entry. Reload the page: the new report should disappear, because Supabase has not been connected.

**Do not submit a real student's path, home address, or personal details.**

## Map tile source and production setup

For low-volume development, this uses the standard `https://tile.openstreetmap.org/{z}/{x}/{y}.png` tile endpoint, with visible `© OpenStreetMap contributors` attribution and an identifying user agent where supported. It is **not a production tile hosting contract**. Follow the [OSMF tile policy](https://operations.osmfoundation.org/policies/tiles/): no bulk/preloading, maintain browser referrer, respect caching, and do not overburden their servers.

**Before publishing or heavy use, choose a production tile provider** (e.g. MapTiler) and check its pricing/terms. The map accepts a configurable `MAP_TILE_URL` (must be a valid XYZ PNG tile URL with any required provider public key, and retain all required provider attribution). Example for your chosen provider:

```bash
flutter run -d chrome --dart-define='MAP_TILE_URL=https://YOUR_TILE_HOST/{z}/{x}/{y}.png?key=YOUR_PUBLIC_KEY'
```

Do not paste privileged secrets into map URLs. Tile URLs and public browser keys are visible to users. MapTiler or another provider may require additional branding/attribution: update the UI before deploying.

## Important technical details

- Flutter map coordinates use `LatLng(latitude, longitude)`.
- GeoJSON coordinates use `[longitude, latitude]`. Never reverse them.
- School map point is approximate and comes from public school directory coordinates:
  [Schaumburg High School directory](https://www.usacitymap.com/schaumburg-high-school-173045003167-school-detail.html).
- Sample issues should NEVER be described as verified safety hazards.
- No sidewalk/path dataset is loaded yet; a basemap's road lines are **not** a verified walkable route graph.
- In widget tests, `SafeRoutesApp(enableMapTiles: false)` avoids network requests; the actual map layers and markers still render.
