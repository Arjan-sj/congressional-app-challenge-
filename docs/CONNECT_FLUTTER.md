# Connect SafeRoutes to Supabase

The GitHub migration already defines schools, hazard_reports and RLS.
The Flutter client supports optional database access. **Without configuration,
the map remains available, but report loading and submission are disabled.**

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

Run locally using a fixed port and compile-time environment values so authentication redirects work:

```bash
flutter run -d chrome --web-port 7357 \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

These are client-visible values. **NEVER** put a secret key, service_role key,
database password or personal access token into Flutter or GitHub.

Routing uses the `route-directions` Supabase Edge Function and its server-only
`OPENROUTESERVICE_API_KEY` secret. No ORS Dart define is needed. See
[server routing setup](ROUTING_PROXY.md).

Supabase → Authentication → URL Configuration: allow `http://localhost:7357`
as a redirect URL for testing email confirmation. Enable the email provider and
email confirmation. Deploy the Phase 9 migration and `account-auth` Edge Function
before testing account flows; see [account setup and native callbacks](ACCOUNTS.md).

In SafeRoutes, open the account icon, create or sign in to a test account.
Select a map location and submit an observation without personal information. It will persist as
`is_demo=false`, `unverified`, visible to its own author, not publicly
verified. Refresh Chrome to test persistence. See [Moderation setup](MODERATION.md)
to deploy the moderation migration and provision reviewer accounts.

If the screen says database connection failed, check the migration deployed
and RLS rules were applied. **Do not disable RLS** as a workaround.

The production deployment needs abuse safeguards, age-appropriate privacy,
operational moderator staffing, and an explicit review process. Avoid actual student
locations or commuting patterns for tests.
