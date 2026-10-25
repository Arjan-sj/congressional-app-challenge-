# Moderator accounts and nationwide review (Phase 4)

Moderation reuses Supabase Auth, `public.report_moderators`, the existing `moderate_hazard_report` RPC, report flags, photo evidence and append-only decision history. Ordinary users and moderators cannot administer memberships. No real account, invitation or permission is created by this implementation.

## Deploy the additive migration first

Review and deploy `supabase/migrations/20261024213844_moderator_accounts_and_queue.sql` through the normal staging migration workflow before releasing this Flutter client or using the operator utility. Earlier migrations, including the Phase 2 school/district schema, must already be present. The migration does not grant or revoke any existing membership and does not rewrite reports, photos or school relationships. No historical migration is changed.

It adds a private membership-change audit, service-only administration RPC, moderator-only paginated queue/search RPCs and queue indexes. The existing moderation RPC signature and audit/status transaction are retained. Existing members continue working; their original grant time is reported as unknown until a grant has actually been recorded by this workflow.

These changes have not been applied to a hosted project. Use a disposable/staging project to verify deployment, role restrictions, Auth identities, Storage access and representative queue performance before production rollout.

## Trusted administration

Run `scripts/manage_moderators.mjs` in an operator terminal or trusted server environment with Node 22+. Never put its secret key in Flutter, a `dart-define` file, a public web environment, source control or a command argument.

Set operator environment variables separately from the app's public configuration:

```powershell
$env:SAFEROUTES_ENVIRONMENT = 'staging' # production or local only when intentional
$env:SAFEROUTES_PROJECT_ID = '<EXACT_PROJECT_REFERENCE>'
$env:SUPABASE_URL = 'https://<EXACT_PROJECT_REFERENCE>.supabase.co'
# Supply SUPABASE_SERVICE_ROLE_KEY from the operator's secure environment.
# Use a server secret key (sb_secret_...) or legacy service_role key.
```

Local mode requires project ID `local` and a loopback Supabase API origin. Hosted origins must use HTTPS and exactly match the project reference. The known production project cannot be labelled staging/local. No default project is inferred. Client preflight validates key shape; the Supabase gateway and server-side function permissions enforce the actual role.

1. Obtain explicit authorization for the intended account. If the account needs an invitation, an authorized Supabase administrator must invite it from the trusted Supabase Dashboard/Auth administrative environment. This utility never creates users, sends invitations or modifies Auth metadata. Wait for email confirmation before granting membership.
2. Look up the existing Auth account by exact email or UUID:

   ```powershell
   node scripts/manage_moderators.mjs lookup --email '<AUTHORIZED_EMAIL>'
   node scripts/manage_moderators.mjs lookup --user-id '<VERIFIED_AUTH_UUID>'
   ```

   Review the project/environment, returned UUID, email confirmation, banned/deleted state and existing membership. Ambiguous emails require an exact UUID. Auth credentials and user metadata are not returned.

3. Prepare a grant. **The default is read-only**:

   ```powershell
   node scripts/manage_moderators.mjs grant --user-id '<VERIFIED_AUTH_UUID>' --expected-email '<LOOKUP_EMAIL>' --operator '<ADMIN_IDENTIFIER>' --reason 'Approved school safety report reviewer'
   ```

   The preview shows current membership and target identity; it is not an Auth invitation or a permission change. Actual grants require a confirmed, active Auth account, a 3–200 character operator identifier and a 5–500 character decision reason. Existing accounts are resolved from `auth.users`; identities are never guessed from names or editable JWT metadata.

4. Only after reviewing the identity and authorization, repeat the exact command with:

   ```text
   --apply --confirm-project <EXACT_PROJECT_REFERENCE>
   ```

   The server rechecks the UUID/email and locks the Auth row during the atomic membership/audit change. A repeated grant returns `changed: false` and creates no duplicate audit entry.

5. List memberships and check the current target:

   ```powershell
   node scripts/manage_moderators.mjs list --limit 50
   node scripts/manage_moderators.mjs list --after-id '<LAST_RETURNED_UUID>' --limit 50
   node scripts/manage_moderators.mjs check --user-id '<VERIFIED_AUTH_UUID>'
   ```

   Membership listing is paginated in stable UUID order, with a maximum of 100 rows per call. Legacy grant times remain null rather than receiving invented timestamps. Refresh the app to show a newly granted Moderation tab; normal live mode also checks membership every 20 seconds.

## Revocation

Look up the target again, then preview a revoke with its current email and an administrative reason:

```powershell
node scripts/manage_moderators.mjs revoke --user-id '<VERIFIED_AUTH_UUID>' --expected-email '<LOOKUP_EMAIL>' --operator '<ADMIN_IDENTIFIER>' --reason 'Reviewer access has been withdrawn'
```

After reviewing the target, repeat with `--apply --confirm-project <EXACT_PROJECT_REFERENCE>`. Repeated revokes are idempotent. A legacy membership for an Auth account with no email can be removed using the exact lookup UUID and `--expected-email '[no-email]'`. The UUID is always required for changes.

Revocation removes only membership. It preserves the Auth user, reports, authors, photos, report timestamps/statuses, school relationships, flags and moderation history. The private membership audit records changed grants/revokes with target UUID, action, operator, reason and server timestamp; it retains evidence even if an Auth account is later removed. Use the trusted database administrative environment to inspect this private audit.

Membership checks query the database on every privileged operation. The same still-valid user JWT cannot moderate, search the moderator directory, read a protected queue or fetch another author's private report/photo metadata after revocation commits. Moderation decisions take a shared per-actor transaction lock; revocation takes the exclusive counterpart, so an already-running decision completes before the revoke commits. Real hosted concurrency/latency is not covered by the local single-database harness.

The Flutter UI checks privileges on refresh and before opening moderator review, polls membership in normal live mode, and fails closed on denied requests. Losing membership closes open review dialogs, removes the tab, clears protected reports/flags, and invalidates map/routing/Analytics caches. A later network failure cannot restore stale protected map data. Normal owner/public access remains available. Previously issued Storage signed URLs retain Supabase's existing 600-second lifetime; clearing the UI does not revoke a URL already copied elsewhere. Future Storage requests obey current RLS.

Use this administration workflow instead of direct membership inserts/deletes so changes have a reason and audit record. Direct membership writes via the service-role REST table are revoked; trusted database owners remain responsible for exceptional SQL maintenance. Neither ordinary users nor moderators can execute either layer of the administrative RPC, access the private audit or grant themselves privileges.

## Nationwide review workflow

The Moderation tab provides **Pending**, **Flagged**, **Verified**, **Resolved**, **Rejected** and **All** queues, scoped to all schools by default. Search and select a school or verified NCES district by name, state or ID. Duplicate district names remain separate through their stable IDs. A separate Unassigned/Independent district option covers private schools and schools without verified district relationships. Legacy aliases resolve to their canonical school for filtering/display while report foreign keys stay unchanged.

School and district discovery runs on the server in bounded keyset pages; it does not download the nationwide directory. Review queues use 25-row pages (server maximum 100) with Previous/Next controls. Counts describe individual reports in the selected school/district. They are not Analytics' deduplicated hazard counts; Flagged overlaps the status queues and counts each flagged report once, even with multiple open flags. Demo reports are excluded.

Choose **Priority first**, **Oldest first** or **Newest first**. Priority sorts severity descending, open flags descending, then oldest submission and stable report ID. Each entry shows school/district, city/state, status, open flag count, severity and report age/time. Pull to refresh, use **Refresh queue**, or reopen the tab to load newly submitted flags. Decisions and report-change notifications refresh the queue, report lists, map markers and Analytics through the existing refresh mechanism.

Open **Review report** for the existing photo, coordinates, flag reasons and decision history. Choose Verify, Reject or Resolve with a reason. The same original report is updated; no duplicate is created. Decision history, resolution timestamps and flag acknowledgement stay atomic. Re-verifying a verified report with a new open flag remains supported. An outdated expected status cannot overwrite a newer decision. Flags and history are paginated beyond the usual API result cap; review details request flags for the exact report.

## Verification and changed files

```powershell
flutter analyze
flutter test --no-pub
npm test --prefix supabase/tests
flutter build web --no-pub
git diff --check
```

The SQL harness uses disposable in-memory PostgreSQL/PostGIS, synthetic Auth identities and rollback-only fixtures. Tests cover ordinary/anonymous denial, service-only management, confirmed/banned accounts, idempotency, duplicate names, canonical aliases, nationwide queues, ordering/pagination, status changes, audit/flag preservation, photos and same-JWT revocation. Node operator tests exercise the actual migrated RPC with simulated HTTP; Flutter tests cover selection, paging, refresh, enlarged mobile layouts, review closure and protected map-cache invalidation. No test creates real users, sends invitations or grants real permissions.

Local verification (2026-10-24): analyzer clean; **130 Flutter tests passed**; **five SQL suites passed**, including the new 86-statement moderator suite; **15 Node tests passed**, including eight administrative-workflow tests; standard web build and diff checks passed. Existing `image 4.3.0` Wasm dry-run warnings remain; Wasm deployment was not validated. A read-only hosted catalog check confirmed the required Auth fields and the migration owner's read/row-lock privileges without reading account records. Hosted migration, real account provisioning/revocation, invitation delivery, and live concurrent-operation smoke tests were not run. Changes remain uncommitted on `main`.

Changed files:

- `supabase/migrations/20261024213844_moderator_accounts_and_queue.sql`: additive administrative/queue RPCs, private audit and indexes.
- `scripts/manage_moderators.mjs`: trusted read-only-by-default operator workflow.
- `lib/models/moderation_queue.dart`, `lib/services/moderation_repository.dart`: typed paginated moderation data and RPC access.
- `lib/screens/live_moderation_screen.dart`, `lib/screens/moderation_scope_picker.dart`, `lib/screens/moderation_screen.dart`: nationwide live queues and searchable filters, retaining the existing widget API.
- `lib/screens/home_screen.dart`: membership refresh, fail-closed revocation handling and review integration.
- `lib/screens/explore_screen.dart`, `lib/screens/analytics_screen.dart`: protected cache/export invalidation on permission changes.
- `lib/services/supabase_hazard_repository.dart`: complete flag/history pagination, exact report flags and retained photo/school metadata after decisions.
- `supabase/checks/moderator_accounts.sql`, `supabase/tests/moderator-admin.test.mjs`: role, workflow and regression tests.
- `supabase/tests/database.mjs`, `supabase/tests/run.mjs`, `supabase/tests/package.json`: realistic synthetic Auth fields and test registration.
- `test/moderation_queue_test.dart`, `test/live_moderation_test.dart`: nationwide UI, permission, refresh and cache regressions.
- `README.md` and this guide: operator/deployment documentation.
