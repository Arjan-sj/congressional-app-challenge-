# Accounts and moderator applications (Phase 9)

Visitors can explore public information without an account. The account icon opens a dedicated responsive sign-in/registration page. Submitting reports still requires Supabase authentication; existing report ownership, photo policies, nationwide moderation and Analytics visibility are preserved.

## Account behavior and privacy

Registration requires an email and a password of 12–128 characters containing uppercase, lowercase and a number. Existing passwords remain usable for sign-in. Usernames are optional, normalized to lowercase, and must contain 3–24 ASCII letters/numbers/underscores beginning with a letter. Uniqueness is enforced in PostgreSQL, including concurrent registrations. Reserved administrative names cannot be registered through the client. Clearing a username returns the account to email-only sign-in.

`public.user_profiles` stores the existing Auth UUID, optional username, timestamps and a server-controlled development password-change requirement. It contains no email, password or role. Owners can read their own profile and update only their username. There is no public profile/email directory. Auth remains the source of email/password identity; editable `user_metadata` never authorizes moderation.

Email login uses the existing Supabase password API. Username login calls `account-auth`, which resolves the email through a service-only RPC and asks ordinary Supabase Auth to verify the password. It returns tokens only after email confirmation; the Flutter SDK refreshes and persists the session using its normal session lifecycle. Unknown usernames use a dummy password verification and receive the same failure text/status, with a minimum jittered failure delay. No anonymous username-to-email endpoint exists. Passwords, tokens and private identifiers are not logged by this handler.

The endpoint applies atomic global, per-network and per-identifier quotas before lookup (120/min globally, 10/min and 100/hour per network, 10/15 minutes per identifier). Quota records contain SHA-256 hashes and expire after an hour on subsequent traffic. These are abuse controls, not anonymous-data guarantees; protect server logs and service credentials. The Edge gateway must supply a trusted client forwarding address. Monitor shared-network false positives and quota exhaustion before increasing limits. Username traffic is also subject to the upstream Auth endpoint's limits.

Email login, signup and email recovery use an additional preflight quota, while retaining Supabase Auth's native rate limits. A client can bypass preflight when calling native Auth directly, so configure hosted Auth rate limits and email delivery limits; preflight is supplementary. CAPTCHA is not enabled by this change; enabling it requires wiring the provider's challenge token into the Flutter flows before rollout.

The Account page supports username changes, verified email-change requests, password changes/recovery, application status and sign-out. Recovery links open the new-password page. Supabase manages expiry/refresh; failed sessions do not authorize privileged operations. Account switching/sign-out clears account fields and triggers the existing private report, flag, map, route and Analytics cache invalidation. Membership is checked server-side for every privileged action even when UI state is stale. Previously issued photo signed URLs retain their existing expiry.

Do not enter home addresses, recurring travel schedules or unnecessary student information. Younger users should ask a trusted adult for help managing their account. Account application status is private to its owner; administrative notes are restricted to the trusted operator workflow.

## Staged deployment

No hosted migration, function deployment, Auth setting, account or membership was changed during implementation. Review and test these steps in an isolated staging project first:

1. Apply all prior migrations, including the existing moderator management migration, followed by `20261025201231_accounts_and_moderator_applications.sql`. It creates profiles for existing Auth IDs without inferring usernames, changing ownership or provisioning memberships. Review its Auth triggers against the staging Auth version.
2. Deploy `supabase functions deploy account-auth --project-ref <STAGING_REFERENCE>`. The function uses Supabase's built-in `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` and `SUPABASE_ANON_KEY` only on the server. `verify_jwt=false` permits login before a session; the handler validates the public project key itself. Do not place a service key in Flutter or a Dart define.
3. In hosted Auth settings enable email/password signup, **email confirmation**, secure/double email-change confirmation and the documented password requirements. `supabase/config.toml` configures local Auth; it does not update hosted settings automatically. Configure a supported SMTP sender and appropriate native Auth/signup/recovery rate limits. Verify the confirmation and recovery templates deliver supported Auth callback links.
4. Configure the exact site URL and redirect allowlist, including the deployed web origin, a fixed development origin such as `http://localhost:7357`, and `saferoutes://auth-callback` for Android/iOS. `AUTH_REDIRECT_URL` can explicitly override the redirect at build time. Web PKCE flows must return to the browser/device that initiated them. Do not allow arbitrary redirect origins.
5. Build/release Flutter only after the migration and function are ready. Android/iOS custom scheme handlers are included; the Supabase app-links integration handles them, with Flutter's competing built-in deep-link handler disabled. Validate cold/warm links on actual devices before release. Desktop native deep-link registration is not implemented here; use web or supply a supported redirect for those targets.
6. Exercise email verification, reset, email change, token refresh, account switching, report submission/photos and moderator revocation with explicitly authorized staging accounts. Never test by changing real hosted users or permissions without authorization.

If the account function is missing/unavailable, account submission fails with an actionable error; public exploration remains available. Roll back the client release if necessary rather than disabling RLS. Do not drop account/application/audit data to roll back.

## Trusted moderator application review

Selecting “Request moderator access” creates a pending request, not membership. The applicant must complete ordinary registration and email verification. Existing signed-in users can request access on their Account page. A unique request per Auth UUID prevents duplicate applications. Approved/declined requests retain their history; changing usernames has no effect on membership. An approved request may show inactive access after a later revocation.

Use the environment setup in [MODERATION.md](MODERATION.md), with the service key supplied through the trusted operator environment. No client or moderator may run administrative RPCs. Preview first:

```powershell
node scripts/manage_moderators.mjs applications list --limit 50
node scripts/manage_moderators.mjs applications check --request-id '<REQUEST_UUID>'
node scripts/manage_moderators.mjs applications approve --request-id '<REQUEST_UUID>' --expected-email '<VERIFIED_AUTH_EMAIL>' --operator '<AUTHORIZED_OPERATOR>' --reason 'Reviewed and approved moderator application'
```

After reviewing the exact Auth identity, add `--apply --confirm-project <EXACT_PROJECT_REFERENCE>` to the approval command. Use `decline` with the same review safeguards to reject it. Listing is bounded to the oldest 100 pending requests; reviewing them exposes the next pending batch. Application review is a trusted terminal workflow, not a new public admin endpoint or an in-app self-approval screen.

Approval calls the existing `admin_report_moderators` grant mechanism inside the same database transaction as the application decision and private application audit. Confirmed/active Auth checks and the existing membership audit remain in force. Repeating an already reviewed approval returns unchanged and cannot re-grant revoked membership. Use the existing explicit grant/revoke workflow for later membership changes. Only the request owner sees the safe status columns; review identity/notes remain private.

## Optional development administrator bootstrap

This utility is never run by startup, migrations or tests against a hosted project. It refuses production, existing Auth emails and any existing `adminModerator` identity. Use it only for an explicitly authorized local/staging administrator email. It creates a development **moderator**, not a Supabase administrator, service key or role that can approve other users.

Set the trusted operator variables from MODERATION.md, then:

```powershell
$env:SAFEROUTES_ALLOW_ADMIN_BOOTSTRAP = 'yes'
node scripts/bootstrap_development_admin.mjs --email '<AUTHORIZED_EMAIL>' --operator '<AUTHORIZED_OPERATOR>'
# Review the read-only preview. Supply SAFEROUTES_BOOTSTRAP_PASSWORD through
# an operator-controlled secret environment, never a command argument or file.
node scripts/bootstrap_development_admin.mjs --email '<AUTHORIZED_EMAIL>' --operator '<AUTHORIZED_OPERATOR>' --apply --confirm-project '<EXACT_STAGING_REFERENCE_OR_local>'
Remove-Item Env:SAFEROUTES_BOOTSTRAP_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:SAFEROUTES_ALLOW_ADMIN_BOOTSTRAP
```

The initial password must be newly chosen, 14–128 characters, mixed-case with a number; no default is supplied. Do not reuse passwords shared in messages. The operator verifies ownership/authorization of the email; the trusted Auth Admin API creates that verified identity and the existing utility grants membership. The profile's normalized username is `adminmoderator`. A server-side password-change requirement blocks moderation until a real Auth password change; the Account page requires the new password. Provisioning output excludes credentials. If provisioning fails after Auth creation, inspect the existing identity through the trusted utility; rerunning bootstrap deliberately refuses to overwrite it.

Recommend MFA for all privileged accounts. Before public release revoke this development membership through the existing audited workflow and disable/remove the development account through an explicitly authorized trusted Auth process. This coding task neither provisions nor removes any account.

## Reproducible verification

```powershell
flutter analyze
flutter test --no-pub
npm test --prefix supabase/tests
deno test supabase/functions/account-auth/handler_test.ts supabase/functions/route-directions/handler_test.ts supabase/functions/map-infrastructure/overpass_provider_test.ts supabase/functions/map-infrastructure/osm_normalize_test.ts supabase/functions/map-infrastructure/infrastructure_response_test.ts
deno check supabase/functions/account-auth/index.ts
flutter build web --no-pub
git diff --check
```

SQL checks run with disposable PostgreSQL/PostGIS and rollback-only synthetic Auth fixtures, including profile privacy, reserved/duplicate usernames, verified applications, service-only review, auditing, revocation/replayed approval, bootstrap password guards and auth quotas. Operator tests use mocked HTTP. Flutter tests use the real Supabase SDK with a mock transport for email/username login, session refresh/expiration, verification, recovery, settings, switching and narrow/enlarged-text layouts. Existing report/photo/moderation tests remain in the full suite. Edge tests validate private resolution, ordinary password verification, generic failures, quotas and server errors.

These checks do not replace real email delivery, a deployed Edge/gateway rate-limit test, native device deep links or hosted concurrent Auth signup/recovery tests. Perform those in an authorized staging environment before release.

Local verification on 2026-10-25: analyzer clean; **155 Flutter tests passed**, including narrow 320-pixel layouts with 1.7× text; **eight SQL suites passed** (437 statements, including 52 account statements); **20 Node operator tests passed**; **26 Edge handler tests passed** and the account function type-check passed. The standard web build passed; existing `image 4.3.0` WebAssembly dry-run warnings remain, and a Wasm deployment was not tested. Android XML/iOS plist syntax and `git diff --check` passed. Browser inspection verified sign-in/registration navigation and a narrow 480 CSS-pixel registration page without submitting any account form. No hosted account, email delivery or permission mutation was performed.

## Changed files

- `lib/screens/authentication_page.dart`, `account_page.dart`, `auth_dialog.dart` and `home_screen.dart`: dedicated account pages, recovery navigation and private cache/error handling.
- `lib/services/account_repository.dart`: native Auth operations, private username sign-in and own-account data access.
- `supabase/migrations/20261025201231_accounts_and_moderator_applications.sql`: additive profiles, applications/audits, trusted helper RPCs, quotas and development password guard.
- `supabase/functions/account-auth/`: server authentication handler and focused tests; `supabase/config.toml`: function configuration and local email/password protections.
- `scripts/manage_moderators.mjs`, `manage_moderator_applications.mjs`, `bootstrap_development_admin.mjs`: extended trusted operator workflow and opt-in local/staging bootstrap.
- `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`: Auth callback registration and Android network access.
- `test/account_fixtures.dart`, `account_repository_test.dart`, `authentication_page_test.dart`, `live_moderation_test.dart`: mock-backed SDK, responsive UI, refresh failure/recovery navigation and ownership regression checks.
- `supabase/checks/accounts.sql`, `supabase/tests/account-operators.test.mjs`, `database.mjs`, `run.mjs`, `package.json`: local SQL/operator coverage and realistic synthetic Auth fixtures.
- `README.md`, `docs/CONNECT_FLUTTER.md`, `docs/MODERATION.md`, this guide: setup, privacy, operator and deployment documentation.
