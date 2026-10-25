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

Run locally using a fixed port and compile-time environment values for a repeatable development URL:

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

Apply the existing migrations followed by `20261025211230_anonymous_community_review.sql`, then deploy the `community-reports` Edge Function before releasing the new client. See [anonymous community setup and privacy](COMMUNITY_REVIEW.md).

Select a map pin and share a concern. It starts unverified and is visible for public community review. Photos on new submissions are also public; avoid identifiable children and personal travel details. Three agreeing reviews from independent connections are required to change the status. No email sender or personal identity setup is required.

If report loading fails, check the deployed migrations, function and RLS policies. **Do not disable RLS** as a workaround. Historical private reports/photos remain protected. Use an explicitly authorized isolated test environment for fixture submissions and consensus testing; do not cast synthetic votes on real concerns.
