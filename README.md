# SafeRoutes 🚸

A Flutter prototype for documenting school walking and biking concerns. Built for the Congressional App Challenge.

> **Current stage: Pilot prototype.** The Flutter app includes a school map, report submission, hazard ranking, accessibility settings, optional Supabase authentication/storage, and report moderation. Demo reports are fictional and are not real safety findings. Route planning is not implemented.

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
  data/demo_reports.dart    # fictional test entries
  screens/home_screen.dart  # main navigation / state
  screens/explore_screen.dart
  screens/report_form_screen.dart
  screens/reports_screen.dart
test/                       # smoke/unit tests
docs/SETUP.md               # installation + collaboration
docs/INTEGRATION_CONTRACT.md# teammate data interface
```

## Developer workflow

1. **Map/UI developer:** build the geographic layer in `explore_screen.dart` using `flutter_map` after checking map data and provider terms.
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

- **An unverified report is not a verified hazard.** No demo content should be presented as evidence of a real location problem.
- Do not store student names, home addresses, school commute routines, or photos of identifiable children.
- Never put Supabase `service_role` / secret keys into client code or GitHub.
- Route recommendations must only use sufficiently verified legal paths and must never promise that a route is safe.

See [Setup instructions](docs/SETUP.md), [data contract](docs/INTEGRATION_CONTRACT.md), and [original logistics plan](docs/LOGISTICS.md).


## Optional Supabase test integration
See [Flutter connection guide](docs/CONNECT_FLUTTER.md).

## Moderation

Review submitted reports, verify/reject/resolve them with a reason, flag
inaccurate reports, and inspect decision history. Live moderation requires the
new database migration and a provisioned moderator account. See
[Moderation setup and verification](docs/MODERATION.md).
