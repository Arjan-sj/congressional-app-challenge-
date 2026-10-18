# Connect SafeRoutes to Supabase

The GitHub migration already defines schools, hazard_reports and RLS.
The Flutter client supports optional database access. **Without configuration,
the app still runs as a standalone in-memory demo.**

## IntelliJ on Mac

```bash
git fetch origin
git switch main
git pull --ff-only origin main
flutter pub get
flutter analyze
flutter test
```

Verify the Supabase dashboard shows both tables. Then obtain **only** the
project URL and **publishable** API key from Supabase → Connect / API keys.

Run locally using a fixed port so authentication redirects work:

```bash
flutter run -d chrome --web-port 7357 \
  --dart-define='SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co' \
  --dart-define='SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLIC_PUBLISHABLE_KEY'
```

These are client-visible values. **NEVER** put a secret key, service_role key,
database password or personal access token into Flutter or GitHub.

Supabase → Authentication → URL Configuration: allow `http://localhost:7357`
as a redirect URL for testing email confirmation. Email provider must be
enabled; keep signup limited to internal testers during this pilot.

In SafeRoutes, open the account icon, create or sign in to a test account.
Select a map location, submit a **fictional** issue. It will persist as
`is_demo=true`, `unverified`, visible to its own author, not publicly
verified. Refresh Chrome to test persistence. No moderation workflow exists.

If the screen says database connection failed, check the migration deployed
and RLS rules were applied. **Do not disable RLS** as a workaround.

The production deployment needs abuse safeguards, age-appropriate privacy,
moderator permissions, and an explicit review process. Avoid actual student
locations or commuting patterns for tests.
