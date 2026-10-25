# Historical account service deployment — 2026-10-25

Superseded later the same day by the requested [anonymous community workflow](COMMUNITY_REVIEW.md). The record below documents what was already applied; it is not an instruction to restore the retired client features. Remaining email/SMTP work was cancelled when that workflow was replaced.

The operator explicitly selected the connected live project `bnvmlxgdqgwjtxgtsaak` after confirming that no separate staging project was available. This deployment fixes the account service outage caused by missing backend prerequisites. No account was created, invited, granted moderator membership or revoked during deployment.

## Applied changes

All other repository migration versions were already present. The missing migrations were applied in dependency order through the Supabase migration API, without replaying prior migrations or changing historical source files:

| Repository migration | Hosted migration record |
| --- | --- |
| `20261024213844_moderator_accounts_and_queue.sql` | `20261025210130_moderator_accounts_and_queue` |
| `20261025201231_accounts_and_moderator_applications.sql` | `20261025210133_accounts_and_moderator_applications` |

The migration API assigns deployment timestamps. Match these recorded names to the source files before future migration operations; do not replay them merely because their timestamp differs. The hosted database also contains the earlier `district_analytics_hierarchy` migration, absent from this checkout. Reconcile the complete source/hosted migration history through a reviewed maintenance process before using a blanket CLI `db push`; no migration history repair was performed here.

`account-auth` version 1 is active, with its own project-key validation and `verify_jwt=false` to support pre-session sign-in. Its `index.ts` and `handler.ts` match the Phase 9 source. It uses built-in server environment secrets, with no new key in Flutter. Existing routing and infrastructure functions were preserved.

The live Auth schema was checked for the required UUID/email/password/metadata/activity columns and the migration owner's read/trigger privileges. Before deployment there were no custom Auth-user triggers; afterward only the two intended account initialization/password-change triggers were added.

## Verification

- Live account preflight: HTTP 200, `{"allowed":true}`.
- Unknown synthetic username login: HTTP 401 with the generic credential/verification error, not an unavailable-service error. No account or email was created.
- Anonymous access to the profile directory, username/email resolver and moderator application administration: HTTP 401 denied.
- RLS enabled on profiles/requests; authenticated users can update usernames but not the password-change guard. Anonymous users cannot execute email resolution, and authenticated users cannot execute application administration.
- Granting private schema usage did not expose another private security-definer function to authenticated users.
- Public Auth settings: email provider enabled, signup enabled, email confirmation required (`mailer_autoconfirm=false`).
- Web release build after backend deployment: passed, with the existing `image 4.3.0` Wasm dry-run warnings.

Pre/post counts matched for 3 Auth users, 0 moderator memberships, 114 reports, 4 photo metadata records, 0 moderation-history records, 124,689 schools and 0 district records. Membership digest also matched. Exactly 3 profiles were added, with no inferred usernames, pending applications or mandatory password changes. No reports, photos or audit records were reset/deleted.

The security advisor reports the intentionally deny-all private audit tables as RLS-without-policy information; their client privileges remain revoked. Its pre-existing leaked-password-protection advisory remains unchanged. Do not add public policies to private audit tables to suppress these informational notices.

## Remaining operator checks

Hosted secure email-change/password/rate-limit settings, exact redirect allowlist, SMTP configuration and email templates require a signed-in dashboard session. The dashboard currently requests sign-in; the Supabase connector does not expose configuration updates. Public email confirmation is already enabled.

The requested Supabase built-in sender can be used for limited testing with project-team addresses. It does not deliver to arbitrary community accounts; public registration needs a supported custom SMTP sender. See [Supabase SMTP restrictions](https://supabase.com/docs/guides/auth/auth-smtp). No SMTP credentials were provided or changed.

The exact deployed web origin is still required before changing the site URL. Documented development/native callbacks are `http://localhost:7357` and `saferoutes://auth-callback`; existing entries must be inspected and preserved as appropriate rather than replaced blindly.

Real verification/reset/email-change delivery, signed-in refresh/account switching, report/photo submission and moderator revocation require explicitly authorized test identities. None was supplied, and no existing live user or membership was used as a test fixture. Local Phase 9 mock/SQL regression results are recorded in [ACCOUNTS.md](ACCOUNTS.md); they do not substitute for real mail/device tests. Native cold/warm callbacks and publishing to a hosting destination remain unverified.
