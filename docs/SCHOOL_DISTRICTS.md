# Phase 2: official school district relationships

This change adds the normalized district schema, reviewed import/backfill path
and district-ID Analytics filters. It deploys no production schema or school
relationships. The production work performed for this PR was read-only.

## Official source and identity rules

Use these same-year NCES/CCD-derived sources:

| Official dataset | Year | Fields and purpose |
|---|---|---|
| [Public school geocodes](https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICSCH_2425/MapServer/0) | 2024–25 | 12-digit `NCESSCH`, explicit 7-digit `LEAID`, `STATE`, `OPSTFIPS`, `SCHOOLYEAR` |
| [Public LEA office catalog](https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_2425/MapServer/0) | 2024–25 | `LEAID`, official district `NAME`, physical office `STATE`, operating `OPSTFIPS`, `SCHOOLYEAR` and office metadata |
| [School administrative directory](https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_ADMINDATA_PUBLICSCH_2425/MapServer/1) | 2024–25 | Cross-check `NCESSCH`, `LEAID`, `LEA_NAME`, `LSTATE`, `SURVYEAR`, `ST_LEAID` |

The verified school geocode release contains 102,178 schools, all with explicit
district identifiers present in the 19,636-row LEA catalog. Of those districts,
18,587 are referenced by the school records. The administrative school directory
contains only 101,110 rows and omits 1,068 geocode schools, so it is a cross-check,
not the sole source of relationships. Catalog `NAME` is the district name; three
administrative `LEA_NAME` spelling/diacritic variants do not change identity.

IDs are strings, preserving leading zeros. Public district IDs are
`nces-lea:<LEAID>`. A school joins its explicit source `LEAID`; the first seven
digits of `NCESSCH` are only a quality check, never a fallback or override.
NCES documents [identifier composition and historical changes](https://nces.ed.gov/pubs2017/2017074.pdf).
No distance, school-name matching or district-name similarity is used.

Physical state and operating jurisdiction are different fields. Seventeen
official school/district pairs have different physical states but identical
operating FIPS: for example, a TX district office serves FL schools, and a MD
district office serves a DC school. BIE jurisdiction `59` is not a physical USPS
state. Validation requires the stored school state to match its school source,
and the school/district operating jurisdictions to agree. Both physical states
are retained; valid cross-state relationships are not replaced by nearby LEAs.

All public sources above report `2024-2025`. Private school geocodes currently
use the separate 2023–24 `PPIN` schema and remain independent of CCD public LEAs.
Source-field schema, complete pagination, duplicate IDs, fixed identifier widths,
source-year compatibility and cache hashes are checked before building a plan.
Unknown fields/releases, missing districts, mismatched state/year/jurisdiction
and conflicting source observations stop or appear as explicit unmatched reasons.
Calendar years such as `2024` are not guessed into a school year.

## Schema and compatibility

Apply only the additive migration
`20261024054838_normalized_school_districts.sql` after reviewing the PR. Historical
migrations are not edited, renamed, reset or replayed by Phase 2.

- `public.school_districts`: stable ID, unique NCES LEA ID, official name, office
  state, latest verified dataset/year, source URL, metadata and timestamps.
- `public.school_district_sources`: immutable observations by district ID/year.
  A newer official name does not erase evidence supporting an older school link.
  Older imports cannot demote the latest district observation. Conflicting facts
  for the same district/year require a separate reviewed correction.
- `public.schools.district_id`: nullable FK to the stable district. A composite
  FK with `district_source_year` references the exact observation; metadata keeps
  school ID/state/jurisdiction and official source URLs. `district_source_dataset`
  tracks the school relationship release. The original `district` text stays
  available and is filled for compatible legacy clients; conflicting existing
  text is not silently overwritten by the backfill.
- Directory tables have RLS with public SELECT only. Import RPCs are executable
  only by the server-side service role/administrative operator. Private link audit
  records hold reviewer, plan SHA-256, old/new IDs and years; ordinary clients
  cannot read or write them. No server key is added to Flutter.
- Indexes cover school district IDs, district state/name/ID, and source year.
  Triggers reject private-school or alias assignments, incompatible identities,
  years and jurisdictions, and unreviewed relationship edits.

Existing school IDs, aliases, classification, coordinates, PostGIS locations,
hazard-report FKs and nearest-school selection are preserved by the backfill.
It updates only district fields and audit records, never hazards or geographic
fields. The existing geographic search/clustering APIs still work; `to_jsonb(s)`
school RPCs expose the new nullable fields automatically, and explicit Analytics
school selections now include `district_id`.

Analytics uses district IDs as filter values, with state and LEA ID in labels.
There are 290 repeated district names across distinct IDs in the source catalog;
these remain separate. The district dialog searches name/state/LEA and builds
visible rows lazily, tested with 19,636 options and enlarged mobile text.
`get_hazard_analytics` keeps its signature, statistics, hazard coordinates,
deduplication and RLS visibility. `p_districts` accepts normalized IDs as well as
legacy exact names for older clients. Legacy string directory RPCs remain;
new clients use `analytics_district_options`. Refresh Analytics after a backfill
to reload district options. District IDs are nullable in the Flutter models,
so older RPC rows and independent schools remain supported.

The Phase 1 preservation fingerprint is extended to include both district tables;
staging hazard resets still leave the school/district catalogs intact.

## Read-only production preview

The October 24 preview of project `bnvmlxgdqgwjtxgtsaak` used its public directory
and verified official sources only. It proposed:

| Disposition | Schools |
|---|---:|
| Exact-ID links for eligible public schools | 102,178 / 102,178 (100%) |
| Private/independent schools excluded | 22,510 |
| Legacy pilot alias excluded | 1 |
| Eligible schools unmatched or inconsistent | 0 |
| Verified cross-physical-state links retained (included above) | 17 |

These are **proposed**, not applied relationships. The backfill creates facts for
the 18,587 referenced districts; unused catalog offices do not receive invented
school memberships. Source snapshots, full per-school expected-state plan, state
coverage and hashes are retained only under Git-ignored `private/`:

- `phase2-district-coverage.md` and `phase2-district-preview-summary.log`
- `phase2-district-plan.json` and `.sha256` (roughly 141 MB; never commit it)
- `phase2-official-public-schools-2425.{json,csv}` and metadata
- `phase2-official-districts-2425.{json,csv}` and metadata
- `phase2-nces-source-evidence.json`

The reviewed plan must have its actual SHA-256 supplied explicitly; a sidecar
alone is not approval. The current private preview SHA-256 is
`921bac58f492a40d1ecd2c51cb0bd201cfb34e944d0129822b2312bc446fff48`.
It has **not** been approved or applied to production.

## Review and resumable backfill

Python uses the standard library. Public configuration can come from the Phase 1
client JSON; service credentials remain in the operator environment only.

```powershell
# Default/explicit preview: source downloads and target directory GETs only.
python scripts/backfill_school_districts.py --preview --client-config config/production.example.json --output private/district-plan-NEW.json

# Reuse already downloaded official archives after checking their provenance.
python scripts/backfill_school_districts.py --preview --client-config config/production.example.json --school-csv private/phase2-official-public-schools-2425.csv --district-csv private/phase2-official-districts-2425.csv --output private/district-plan-REVIEW.json
```

Preview works before migration deployment, probing the optional `district_id`
column and falling back only on a genuine missing-column response. It keyset-pages
the entire school directory, reports coverage/reasons by state, includes exact
expected current fields for every proposed change, and writes an exclusive plan
plus checksum. Use a fresh output path for every new review. Cached source data
is checksummed; use a fresh cache directory to refresh a source snapshot.

Review the source year/URLs and archive hashes, proposed school/LEA pairs, state
coverage, independent schools and every conflict/unmatched reason. Existing
non-null links and conflicting text are excluded for separate review. Missing
facts never clear a relationship. A newer source release must first be reviewed
and configured; do not mix a newer LEA directory with older school facts.

After staging validation, deploy the migration using the normal reviewed Supabase
migration process. **Production application needs separate explicit approval**
of the source data and exact plan. The following is an operator template only:

```powershell
# Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the private operator shell.
# Never use a server key as a Flutter define or commit it.
python scripts/backfill_school_districts.py --apply-plan private/district-plan-REVIEW.json --confirm-project EXACT_PROJECT_REF --reviewed-by "Named reviewer" --reviewed-sha256 EXACT_REVIEWED_SHA256 --batch-size 100
```

Each RPC batch locks the exact schools and checks identity, classification,
alias state, source year/dataset, physical school state, jurisdiction and the
reviewed existing relationship/text. A stale row aborts that whole batch. The
checkpoint advances atomically only after an acknowledgement for every row in
the committed batch. Earlier successful batches stay committed. Rerun the same
command/file to resume. If the server committed but the client lost the reply,
already-equal relationships return unchanged and do not duplicate audit records.
Keep the plan immutable; a new plan gets a new hash/checkpoint. Do not manually
advance a checkpoint to bypass a failed row.

After completion, rerun a fresh preview: `already_linked` plus proposed `link`
counts show verified coverage; a completed checkpoint records prior successful
batches, not a guarantee against later external edits. Run the SELECT-only
`supabase/checks/school_district_coverage.sql` after deployment for current
coverage, private/unmatched/invalid links and cross-state counts. Inspect the
private audit as an operator. Do not delete/recreate schools or reports to fix
counts. This workflow contains no automatic rollback or production force switch.

## Future school imports

`scripts/import_schools.py` now requests explicit `LEAID`/`OPSTFIPS` and loads the
compatible official public LEA catalog. Public imports include district facts,
the FK, legacy text and provenance in the same atomic batch as school fields;
private imports never receive CCD links. Normal geographic synchronization keeps
the importer's prior behavior, but district-only backfills do not touch geography.

```powershell
python scripts/import_schools.py --kind public --dry-run --max-records 100
python scripts/import_schools.py --kind public --sql-dir private/reviewed-import --reviewed-by "Named reviewer"
# Or a reviewed live import with server credentials set in the operator shell:
python scripts/import_schools.py --kind public --confirm-project EXACT_PROJECT_REF --reviewed-by "Named reviewer"
```

Prepared SQL calls the same reviewed sync RPC; inspect it before execution. Live
imports require exact HTTPS project confirmation and a reviewer. Conflicting
existing manual text or a district transfer is rejected unless its individual
school ID is present in the separately reviewed JSON array supplied with
`--approve-school-ids private/reviewed-transfers.json`. This allowlist is not used
by the default production backfill. Older releases cannot replace newer school
observations; same-year district conflicts stop for separate correction. Current
release constants still fail on a newly detected NCES release until its schema
mapping is deliberately reviewed. Idempotent reimports keep IDs and relationship
audits stable; source observations preserve prior-year provenance.

## Validation and files

```powershell
python -m unittest discover -s scripts -p 'test_*.py'
npm ci --include=dev --prefix supabase/tests
npm test --prefix supabase/tests
flutter analyze
flutter test --no-pub
flutter build web --no-pub
git diff --check
```

Verified: 28 Python tests; four PostgreSQL/PostGIS SQL suites (district suite has
106 statements); seven Phase 1 operator regression tests; analyzer clean; all
88 Flutter tests passed. A five-row real-source importer dry-run had zero errors.
The standard web build passed with the existing `image-4.3.0` Wasm dry-run lint
findings; a Wasm build was not validated. Local database tests use
real PostgreSQL/PostGIS with simulated Supabase system interfaces; no live
production write, district import/backfill or hosted migration was run. Hosted
staging deployment/apply checks remain manual before any production approval.

Changed files include the additive migration and district coverage/SQL checks;
`scripts/nces_districts.py`, `backfill_school_districts.py`, `import_schools.py` and
their tests; School/Analytics models; map/Urban parsers; Analytics repository,
screen and district picker; nullable-ID/directory/widget tests; the SQL test
runner and existing CI workflow; and this guide/README link. Existing migrations,
Auth, photos, moderation, hazard storage and school IDs are not rewritten.
