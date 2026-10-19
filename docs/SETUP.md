# SafeRoutes: first setup (macOS + Linux)

## 1. Install tools
- [Git](https://git-scm.com/downloads)
- [Flutter SDK](https://docs.flutter.dev/get-started/install) and the **Flutter + Dart** VS Code extensions
- [VS Code](https://code.visualstudio.com/)
- Google Chrome

Mac typically uses zsh; Linux often uses bash. The actual Git and Flutter commands below work the same after installation.

## 2. Clone and open the project

```bash
git clone https://github.com/Arjan-sj/congressional-app-challenge-.git
cd congressional-app-challenge-
git fetch origin
git switch setup/saferoutes-flutter-foundation
code .
```

If the setup branch is already merged, use `git switch main && git pull` instead.

## 3. Run and verify

```bash
flutter doctor
flutter devices
flutter pub get
flutter run -d chrome --web-port 7357 \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY \
  --dart-define=OPENROUTESERVICE_API_KEY=YOUR_ORS_KEY
```

You should see **SafeRoutes**, with Explore / Reports / Report tabs. Without Supabase values the map still works, but report loading and submission are disabled.

```bash
flutter analyze
flutter test
```

If `flutter` is not found, finish the Flutter SDK installation and ensure its `bin` directory is in PATH. If Chrome is missing, install/locate Chrome and rerun `flutter devices`.

## 4. Working together without overwriting files

Always start a change from an updated `main` branch:

```bash
git switch main
git pull origin main
git switch -c feature/my-task
# edit and test
flutter test
git add .
git commit -m "Describe what changed"
git push -u origin feature/my-task
```

On GitHub, open a **pull request** into `main`. Review and merge. Have one person coordinate edits to `lib/main.dart`, `lib/app.dart`, and `pubspec.yaml`.

## 5. First task owners

**Map/UI developer:** install `flutter_map` and `latlong2` when ready (`flutter pub add flutter_map latlong2`); replace the Explore placeholder with a real map showing only sourced or clearly labeled sample data. Verify map-tile provider terms and attribution.

**Report/backend developer:** draft Supabase tables, RLS policies, and the reporting service. Make `HazardReport` compatible with the agreed schema. Do not use Supabase service_role keys in Flutter.

**Both:** agree on [INTEGRATION_CONTRACT.md](INTEGRATION_CONTRACT.md), add tests and only connect live submissions once security and map selection work.

## 6. Current limitations
This initial scaffold is **not** live. There is no account login, database, geocoding, real-time map, or safety-validated route recommendation. Never describe sample reports as actual hazards.
