# Report moderation

The Reports tab includes **Details, flags & history** on every report. Signed-in
users can flag an active report as inaccurate with a 5–500 character reason.
Each account can flag a given report once. A flag leaves the report's status
unchanged until a moderator reviews it.

Provisioned moderators also see the **Moderation** tab. Its queues show pending,
flagged, verified, rejected, resolved, or all reports for the pilot school.
Open **Review report** to inspect the description, severity, coordinates,
submission time, accuracy flags, and decision history.

Choose **Verify**, **Reject**, or **Resolve** and supply a reason. A decision
updates the report, records the moderator's account ID, timestamp, reason,
previous status and outcome, and marks existing flags reviewed in one database
transaction. A verified report with a new open flag can be verified again after
review. Previously reviewed reports can be corrected with a new decision; old
decisions remain in the history. Rejected reports are excluded from the map,
and rejected/resolved reports are excluded from hazard rankings.

Use **Refresh reports** to load new submissions, flags, and moderator membership
changes. A stale decision cannot overwrite a different current status; close
the review, refresh, and reopen it if the server reports a conflict.

## Enable on Supabase

1. Apply the repository's migrations in order, including
   `supabase/migrations/20261018223315_report_moderation.sql`, through your normal
   Supabase migration deployment workflow. This change is provided as a local
   migration; it has not been applied to the hosted project.
2. Create/sign in to the intended moderator account using the app's account icon.
3. In the trusted Supabase SQL Editor, provision the account using its Auth user ID:

   ```sql
   insert into public.report_moderators(user_id)
   values ('REPLACE_WITH_AUTH_USER_UUID')
   on conflict do nothing;
   ```

4. Refresh reports in the app. The Moderation tab appears after membership is read.

To revoke access immediately on the server:

```sql
delete from public.report_moderators
where user_id = 'REPLACE_WITH_AUTH_USER_UUID';
```

The client cannot grant itself moderator membership. Membership is checked
against a database table for each moderation operation, so user-editable
metadata and old JWT role claims do not grant moderation access.

## Access and history

- Visitors see verified/resolved reports. Authors also see their own submissions;
  moderators see all submissions for review.
- Flag reasons are visible to their flagger and moderators.
- Moderation reasons and moderator account IDs are visible to the report author
  and moderators. Visitors and other users see the report's current status.
- Clients cannot insert, edit, or delete audit entries, alter flag review fields,
  or edit report descriptions through moderation privileges. The private audit
  trigger appends history using the authenticated actor and server timestamp.
- Account changes clear the report and flag cache and close an open review.

Without a Supabase client, the app includes a demo moderation workspace. All
demo decisions and flags are in memory and disappear on restart. Verifying a
demo report never removes its fictional/demo label.

## Verification

```bash
flutter analyze
flutter test
```

The Flutter tests cover review outcomes, reason validation, ordinary-user
controls, duplicate errors, retry, save locking, mobile text scaling, and the
demo flag-to-review/history flow.

For database assertions, apply migrations to a **disposable test database** and
run using an administrative database connection:

```bash
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/checks/report_moderation.sql
```

The script creates temporary fixtures, exercises anonymous/user/moderator
permissions, verifies audit integrity and conflict handling, and rolls everything
back. It also runs against PGlite with `anon`/`authenticated` roles and a minimal
Supabase Auth fixture. This local check does not validate hosted PostgREST or
replace a deployed-project smoke test.
