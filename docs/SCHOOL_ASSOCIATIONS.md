# Geographic report school associations

New reports use `nearest_schools(latitude, longitude, radius)` over the existing
NCES directory and generated PostGIS location. The default radius is 2,000 m;
distances use spheroidal geography, ordered by distance then school ID. A partial
GiST geography expression index bounds the search across nationwide schools.
Aliases are excluded. The RPC returns every nearby candidate, including shared
campuses; it returns an empty list when none qualify. Coordinates, NaN, infinities,
and invalid radii are rejected. An explicit optional radius supports other uses
up to 20 km. Reporting always uses the server policy radius, returned by
`report_school_radius_meters()`. Change that function in a future additive
migration to adjust reporting policy, and update the form's radius messages.

The form automatically selects the closest school and displays its name and
meter distance. There is no school picker or confirmation step. Shared campuses
use the same distance-then-school-ID ordering as the server. Moving the pin
immediately clears the old selection and stale requests cannot overwrite a newer
lookup. Missing connectivity, missing migration, and empty results block
submission with a retry/location message. Existing insert, authentication,
photo upload/cleanup, status, and moderation paths are reused.
The database independently recomputes the closest candidate on INSERT and on
changes to school/coordinates. It rejects any different school ID, including
another school within the radius or an alternate exact-distance tie. If the
directory changes between lookup and save, the user must retry the location
lookup. Other updates can still moderate historical rows without reassignment.
RLS and existing column permissions remain in force.

Analytics resolves known legacy aliases at read time, so retained Schaumburg
reports appear under its canonical identity. Canonical and legacy filter IDs
both work. The existing summaries, time filters, privacy rules and per-school
duplicate rules are retained. Hazard marker coordinates continue to come from
the report. School selection uses server search and keyset paging, covering
name, city, state, ZIP and district. District choices use the full directory.
Report lists show school names and keep duplicate groups separate by school.
Home subscribes to report changes and refreshes maps/lists; Analytics also
refreshes on writes, tab activation, and visible Realtime changes. Rolling date
ranges advance on refresh so newly submitted reports enter the active range.

## Deployment

1. Review and merge the PR. Apply the additive migrations in order:
   `20261024042039_nearest_school_association.sql`, then
   `20261024045850_automatically_assign_nearest_school.sql`. If the first is
   already deployed, apply only the second to the intended Supabase project
   using the normal migration deployment process (`supabase db push` after linking
   and reviewing pending migrations). Existing migrations must not be edited or
   replayed against production. The first migration creates functions, index,
   trigger and a private correction audit table. The second tightens the existing validation trigger to require
   the single closest candidate. Neither changes historical reports.
2. Deploy the Flutter build after the database migration. Existing clients that
   still submit `sample-school` will receive a validation error; coordinate the
   app rollout. Preserve the existing public Supabase URL/publishable key.
3. Verify the lookup with known NCES schools, same-campus candidates and an empty
   location. Submit under an ordinary authenticated test account in staging;
   verify photo upload, moderation, and anonymous visibility separately.
4. Review security/performance advisors and confirm the spatial index is used.
   Test RLS with anonymous and authenticated sessions. The existing
   `hazard_reports` Realtime publication is reused; no new private data is
   published. No service-role key belongs in Flutter.

## Historical review and backfill (separate explicit approval required)

`supabase/checks/preview_pilot_school_associations.sql` is a standalone SELECT
usable before deployment. After deployment, a trusted operator can call:

```sql
select * from public.preview_pilot_school_associations();
```

The preview includes each non-demo pilot-associated report, its current identity,
canonical identity, current and suggested distances, original coordinates and
all nearby candidates. It excludes aliases from candidate schools. Associations
within the current pilot radius are marked `retain_pilot` even when another
school is closer. Distant rows with candidates are `review_required`; rows with
no match are `no_match`. None are automatically approved. The October 23 live
read-only preview found 8 non-demo rows: 5 require review and 3 are retained;
5 demo rows were excluded. Results with IDs/coordinates are saved only in the
Git-ignored `private/` folder, not in the PR.

After reviewing that private preview and receiving **explicit approval** for each
correction, the operator builds an allowlist. Each item must contain `report_id`,
`current_school_id`, original `latitude` and `longitude`, and the approved
canonical closest `school_id`. The automatic-selection trigger also enforces
the closest candidate during corrections. Re-run the preview immediately before
approval. The following is a dry-run template with an EMPTY allowlist, not an approved backfill:

```sql
begin;
select public.apply_reviewed_school_corrections(
  '[]'::jsonb, -- replace ONLY with explicitly reviewed and approved entries
  'reviewer identity',
  'reason for the approved school corrections'
);
-- Inspect the exact affected rows and their photo/moderation associations.
rollback;
```

Use a trusted operator connection or server-side service role; ordinary app users
and moderators cannot execute these review/correction functions. After approved
dry-run verification, an operator may explicitly commit the same allowlist.
Rows are locked and checked against the preview's school and coordinates; stale,
demo, unrelated, nearby-pilot, or invalid-target entries abort the whole call.
Replaying the identical approved correction returns zero changes and creates no
duplicate audit or report records. Only `school_id` is updated; report IDs,
authors, timestamps, status, coordinates, photos and moderation history remain.
The private audit keeps the old/new school, reviewer, reason and correction time.
It intentionally does not block the existing authorized report deletion flow.

## Validation

Verified on this branch: `flutter analyze` reported no issues; all 73 Flutter
tests passed; all three PostgreSQL/PostGIS SQL suites passed (association, map,
moderation); `flutter build web --no-pub` succeeded; `git diff --check` passed.
The web build also reported existing `image-4.3.0` Wasm dry-run lint findings;
this validates the standard web build, not a Wasm build. Production schema/data
were accessed only with SELECTs for inspection and the private preview.

```powershell
flutter analyze
flutter test --no-pub
flutter build web --no-pub
npm ci --prefix supabase/tests
npm test --prefix supabase/tests
git diff --check
```

The Node runner uses disposable in-memory PostgreSQL with the real PostGIS WASM
extension, applies every repository migration unchanged, and runs the new
association checks plus existing map and moderation checks. Minimal Auth/Storage
system tables emulate Supabase's SQL interfaces; this does not test the hosted
Auth, Storage HTTP service or Realtime transport. Fixtures/role changes roll back.
Never run the fixture checks against production. The photo checks preserve
existing metadata/path constraints rather than changing the Storage workflow.
Flutter HTTP/widget tests cover automatic selection without user input, stale
pin lookups, no-match/errors, deterministic shared-campus choices, payloads and
nationwide paging. Live production submissions, hosted writes and the historical backfill are not part
of this change's automated validation.

## Modified files

- `lib/models/nearby_school.dart`: typed server candidates and injectable lookup.
- `lib/models/hazard_report.dart`, `lib/services/hazard_codec.dart`: school display
  name retention and finite-coordinate validation.
- `lib/services/supabase_hazard_repository.dart`: nearest RPC, alias-aware report
  filtering, school name joins, and nationwide flag loading.
- `lib/screens/report_form_screen.dart`: automatic nearest-school selection,
  distance display, retry and stale-request protection.
- `lib/screens/home_screen.dart`, `lib/app.dart`: nationwide report refresh,
  Realtime invalidation and injectable live-update opt-out for widget tests.
- `lib/screens/reports_screen.dart`, `lib/services/hazard_ranking_service.dart`:
  associated school display and school-specific duplicate groups.
- `lib/screens/analytics_screen.dart`, `lib/screens/analytics_school_picker.dart`,
  `lib/services/analytics_repository.dart`: server directory search/paging,
  complete district choices and refreshed rolling analytics.
- Additive migrations named above: lookup/index, strict nearest-school validation,
  directory RPCs, alias-aware analytics, private preview/correction audit and approved-only RPC.
- `supabase/checks/nearest_school_association.sql`: geographic, validation,
  backfill, alias, index, RLS, photo, moderation and analytics assertions.
- `supabase/checks/preview_pilot_school_associations.sql`: predeployment SELECT.
- `supabase/checks/report_moderation.sql`: valid canonical-school test fixture.
- `supabase/tests/{package.json,package-lock.json,run.mjs}`: reproducible local
  PostgreSQL/PostGIS test runner; `.gitignore` excludes installed modules.
- `test/nearest_school_workflow_test.dart`, `test/report_form_test.dart`,
  `test/hazard_ranking_service_test.dart`, `test/live_moderation_test.dart`:
  workflow/regression coverage and isolated network behavior.
- This deployment/review guide. Private live preview files are intentionally
  untracked.
