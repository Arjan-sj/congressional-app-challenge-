# Phase 1: staging hazard testing

This workflow resets and recreates **registered synthetic fixtures** in a separate
staging or local database. It has no production reset mode and no force switch.
Production and unregistered reports (including old demo rows), their photos and
their audits are protected. No reset, seed, enrollment or schema deployment was
executed against the connected project while implementing Phase 1.

## Audit and dependencies

The October 24 read-only audit of production project `bnvmlxgdqgwjtxgtsaak` found:

| Record | Count |
|---|---:|
| Hazard reports | 14 |
| Demo reports (included above) | 5 |
| Photo metadata / Storage objects | 3 / 3 |
| Report flags | 1 |
| Moderation history | 0 |
| School-correction audits | 0 |

All 14 reports are protected. There were no orphaned hazard Storage metadata
objects. Physical object availability was not checked on production. Its
`hazard-photos` bucket is private, limited to 5 MB, allowing JPEG, PNG and WebP.
The private detailed audit, including IDs and migration/trigger definitions, is
saved in `private/phase1-production-hazard-audit.json` and excluded from Git.
`supabase/checks/hazard_environment_audit.sql` is a repeatable SELECT-only audit
for an operator connection; record the actual connection's project/environment
alongside its output. Counts are snapshots, not an ongoing monitor.

The read-only security advisor check also reported the existing closed
`private.report_school_corrections` table having no RLS policies (intentional
operator-only access), and existing disabled Auth leaked-password protection.
No production Auth setting was changed; see the
[password-protection setting](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

| Dependency | Existing behavior | Reset behavior |
|---|---|---|
| `hazard_report_photos.report_id` | Report FK, cascade | Back up bytes and rows; remove files with Storage API first; cascade metadata |
| `storage.objects` | Private files, report deletion guard | Never delete through operator SQL; use authenticated Storage API |
| `report_flags.report_id` | Report FK, cascade | Back up then cascade only synthetic reports' flags |
| `report_moderation_history.report_id` | Report FK, cascade | Back up then cascade only synthetic reports' decisions |
| `private.report_school_corrections.report_id` | No report FK | Back up and explicitly delete only synthetic reports' corrections; orphan audits block reset |
| Schools, district fields, infrastructure | Independent shared data | Never modify; compare pre/post fingerprints |
| Auth users, moderator memberships, migrations | Persistent setup | Never modify; compare pre/post fingerprints |

The repository and hosted migration versions were compared. Existing migration
files, including previously reconciled filenames and the archival
`migrations_backup/` directory, are not rewritten or replayed by this work. Only
`20261024051937_staging_hazard_test_workflow.sql` is added. It creates private
operator control/audit/fixture tables and functions, a maintenance gate, and an
additive photo-path constraint repair. The old regex's double-escaped dot rejected
normal `123.png` metadata; the new check accepts normal filenames **and every
previously accepted legacy path**. It does not rename or delete existing files.
Existing photo access policies, size/type limits and orphan-prevention trigger
remain in force. API users and service-role clients receive no access to the
private reset functions or tables; the operator uses an administrative database
connection. The maintenance trigger needs internal definer access only to inspect
the private gate; it does not grant clients reset access or bypass their RLS.

## Create the separate environment

1. Provision a dedicated Supabase staging project (or a local Supabase stack).
   Only production is currently connected; hosted staging provisioning/deployment
   is a manual step. Never point this setup at the production project. Apply the
   repository's migrations once with the normal reviewed deployment process,
   including the new Phase 1 migration. Do not use `supabase db reset` on a hosted
   database. Copy/import only the public school and infrastructure datasets into
   staging using the existing import scripts. Do not copy community reports or
   production Auth credentials. On an existing staging database, review its
   pending migrations before deploying only the new one.
2. Create dedicated test accounts using staging Auth administration, and provision
   one as a report moderator using the existing documented moderation setup.
   The workflow takes their existing UUIDs; it never creates/deletes users or
   changes moderator membership. Choose two distinct canonical school IDs whose
   campus coordinates resolve to themselves as the closest school. At shared
   coordinates, choose the first school by the existing distance/ID rule.
3. Copy `config/staging.example.json` to `private/staging.json`, fill the staging
   **public** URL/publishable key, then run:

   ```powershell
   flutter run -d chrome --dart-define-from-file=private/staging.json
   ```

   The app visibly says `STAGING`. Missing staging credentials or the production
   URL are rejected; there is no staging fallback to production. For local use,
   copy `config/local.example.json`, fill the local public key, and use that file;
   local mode requires a loopback URL. `config/production.example.json` documents
   the existing public production configuration, which remains the default.
   Secret/server keys and legacy service-role JWTs are rejected by Flutter.
4. Copy `config/staging-operator.env.example` to
   `private/staging-operator.env` and fill the separate staging database password,
   server key, project reference, school IDs and account UUIDs. URL-encode the
   password in the Postgres URL. This file is for the Node operator shell only:
   **never** use it as a Flutter define file or commit it. Hosted database TLS
   verifies certificates; provide `SAFEROUTES_DATABASE_CA_FILE` if needed.
   Use a direct connection or Supavisor **session** port 5432. Transaction pooling
   (port 6543) is unsuitable because the workflow holds a session lock/gate token.
5. After independently checking the staging project's identity, enroll it through
   an administrative `psql` connection to that staging database:

   ```powershell
   psql "$env:SAFEROUTES_DATABASE_URL" -v environment=staging -v project_id=YOUR_STAGING_REF -f supabase/testing/enroll.sql
   ```

   Supply `SAFEROUTES_DATABASE_URL` in that operator shell from the private
   configuration. For a local stack, use `environment=local`, `project_id=local`,
   loopback API/database URLs and its local server key. Enrollment defaults to
   production/blocked after every new database migration; only this explicit
   operator step enables non-production writes. The known production reference
   cannot be enrolled as staging/local. CLI project URL, database host/user,
   registered project/environment and typed confirmation must all agree.

## Preview, seed, reset and repeat

Requires Node 22+, a privileged staging database connection and the staging
Storage server key. Install the locked operator/test dependencies:

```powershell
npm ci --include=dev --prefix supabase/tests
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs preview
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs seed --dry-run
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs seed --execute --confirm-project YOUR_STAGING_REF
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs preview
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs reset --dry-run
node --env-file=private/staging-operator.env supabase/tests/hazards.mjs reset --execute --confirm-project YOUR_STAGING_REF --backup private/backups/reset-001.json
```

`preview`, `reset` and `seed` are read-only by default. Execution requires
`--execute` and an exact typed project reference. Reset additionally requires a
new backup path; it will not overwrite an old archive. The preview prints the
registered project/environment, active operation, all seven counts plus synthetic
membership, and IDs/paths for non-synthetic reports, orphan objects/corrections,
or unexpected FKs into any report dependency. Any such blocker stops a write.
Unknown/unregistered or manually created reports are not silently reclassified
as test data. Review and preserve them; there is no production-cleanup override.

### Synthetic fixture set

Six deterministic IDs (`50000000-0000-0000-0000-000000000001` through `...006`)
use seed version `phase1-v1`, `is_demo=true`, a `[SYNTHETIC phase1-v1]` description
prefix, and membership in an operator-only fixture registry. All three identity
checks are required; the demo flag alone is insufficient.

| Fixture | School | Status | Purpose |
|---|---|---|---|
| 1 / 2 | A | Verified / verified | Same-category, same-coordinate duplicate concern |
| 3 | B | Unverified | Private pending concern at a different school |
| 4 | B | Verified | Reviewed concern |
| 5 | A | Resolved | Resolved concern and timestamps |
| 6 | A | Unverified | Valid PNG evidence with private Storage object |

One flag is created, then closed through the existing moderation RPC. Four
moderation events are recorded through that same RPC, not by disabling the
audit trigger. New timestamps reflect the seed run; IDs, content, statuses and
campus coordinates are reproducible. The fixture PNG is a generated one-pixel
image, not a real person's evidence. Standard application queries and Analytics
continue excluding demo reports, preserving existing behavior; use the operator
preview/SQL to inspect this fixture set. This phase does not add a synthetic-data
viewer or change real Analytics counts.

Running `seed --execute` again is a verified no-op only if the same completed
fixture snapshot, arguments and photo checksum still match. Otherwise reset
first. A successful reset verifies all hazard/dependency counts are zero and the
protected datasets' row counts/digests are unchanged. Repeating reset on that
empty dataset is a no-op. Seed again to recreate the six fixtures. Run-level
operator audit records persist across resets.

### Backup, failure and recovery

Keep staging quiet: stop test submissions, imports, infrastructure refresh jobs
and moderator activity before executing. An advisory session lock prevents two
operator runs. A committed maintenance gate then blocks concurrent hazard and
photo edits, while allowing the specific Storage deletes/uploads needed by the
active synthetic workflow. It survives operator/network failures; ordinary
users receive a temporary maintenance error. Other Storage buckets are unaffected.

Before deleting any object, reset writes a private recovery archive containing
all report/photo/flag/moderation/correction/fixture rows, Storage metadata, actual
photo bytes, project/run identity and pre-reset protected-data fingerprints. It
downloads each object through the Storage API, verifies file checksums and the
archive read-back hash, then stores the archive's SHA-256 in the private run
audit. A missing or unreadable object stops the workflow before any deletion.
Protect these archives with private directory permissions/Windows ACLs and secure
off-machine retention. They contain private evidence; never commit them.

After verified backup, the Storage API removes only the inventoried hazard files
in batches of 100. Only then does a database transaction delete registered
synthetic correction records and reports; the existing FKs cascade photos,
flags, moderation and fixture membership. No Storage object metadata is deleted
by the operator's SQL. The existing orphan-prevention trigger independently
blocks report deletion while files remain.

If upload fails, rerun the identical `seed --execute` command. If reset fails,
rerun the identical reset command with the **same backup file**; a partial API
delete can resume because the archive still contains all original bytes/rows.
The workflow compares unchanged report records and the surviving object inventory
against that archive. A tampered/missing backup or changed protected data stops
recovery; it never invents a new backup after deletion has started. If backup
creation failed before its hash was recorded, no deletes started: fix the cause
and use a fresh backup path. Do not clear the private maintenance gate merely to
make an error disappear. Have the staging operator inspect the run and archive;
if protected imports changed independently, reconcile that change explicitly.

For manual recovery, retain the verified archive and restore only to another
enrolled staging/local project with the same school IDs and test users: reinsert
its report/dependency rows with their original IDs and timestamps using admin
SQL (omit generated `location` columns), then upload `files[].base64` bytes to
their original paths through the Storage API and verify their SHA-256 values.
Do not restore Storage metadata with SQL, disable moderation/RLS constraints, or
restore into production. An automatic disaster-recovery/import command is outside
Phase 1; tested normal failure recovery is by resuming the original run.

Supabase database backups contain Storage metadata, not the actual files; that
is why this workflow separately archives photo bytes. References:
[Storage deletion](https://supabase.com/docs/guides/storage/management/delete-objects),
[database backup limits](https://supabase.com/docs/guides/platform/backups).

## Verification and limits

Verified during Phase 1: analyzer clean, all 77 Flutter tests passing, all three
existing SQL suites passing, seven operator/workflow tests passing, and standard
web build passing. The web build reports existing `image-4.3.0` Wasm dry-run lint
findings; a Wasm build was not validated. The new `Hazard staging workflow` CI job
runs the disposable database/operator checks with no hosted secrets.

```powershell
npm test --prefix supabase/tests
flutter analyze
flutter test --no-pub
flutter build web --no-pub
git diff --check
```

The SQL runner applies all migrations to disposable PostgreSQL with real PostGIS
and runs existing nearest-school, map and moderation checks. The workflow tests
exercise accurate previews, production/project safeguards, blocked real records,
orphan/unexpected dependencies, user permissions, deterministic seed data,
Storage API request paths/order, missing images, upload/delete failures,
checksummed backup/resume, idempotency and preserved-data fingerprints.
Storage HTTP requests are simulated; test-only SQL models the external Storage
service's metadata changes. No live Storage deletion or production write occurs.
The Flutter tests cover configuration isolation, secret-key rejection, environment
labels and existing UI/report/moderation behavior. Hosted staging, real Storage
HTTP cleanup, certificate setup and provider jobs still need staging smoke tests
after manual provisioning; no claim is made that these hosted checks ran.

## Files

- `lib/models/app_environment.dart`, `lib/main.dart`, `lib/app.dart`,
  `lib/screens/home_screen.dart`: public environment configuration and label.
- `config/*.example.json`, `config/staging-operator.env.example`, `.gitignore`:
  public/client templates, separate private operator credentials and exclusions.
- New Phase 1 migration and `supabase/testing/enroll.sql`: private operator-only
  control, audit, synthetic registry, preview, safety gate, reset/seed functions.
- `supabase/checks/hazard_environment_audit.sql`: predeployment read-only audit.
- `supabase/tests/hazard-workflow.mjs`, `hazards.mjs`: preview/dry-run,
  backup, Storage API cleanup, reset, seed, verification and recovery.
- `supabase/tests/database.mjs`, `run.mjs`, `hazard-workflow.test.mjs`,
  `package.json`, `package-lock.json`: reusable disposable database, integration
  coverage and pinned operator dependencies.
- `test/app_environment_test.dart`, `test/live_moderation_test.dart`:
  configuration and label regression tests; `.github/workflows/hazard-testing.yml`
  runs the SQL/operator checks in CI. `README.md` links this guide. Phase 1 only.
