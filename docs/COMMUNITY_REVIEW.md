# Anonymous community reporting and review

SafeRoutes accepts public observations without sign-in, registration, usernames, applications or a privileged review screen. Everyone uses the same Community tab. No Supabase Auth identity is created for a visitor. Existing identities, ownership records and decision history are retained privately for compatibility and auditing; they are not repurposed into public visitor profiles.

## Reporting and consensus

Select a map pin and submit a concern with an optional photo. The server independently chooses the nearest canonical school within the configured 2,000 m radius. Client-supplied school IDs, author IDs, timestamps, status and demo markers are ignored. Locations stay at their reported coordinates. A random UUID is retained for retries of the same form contents so a lost response does not duplicate the report.

New contributions and their photos are public and start unverified. Visitors can choose **Concern exists**, **Resolved**, **Not accurate** or **Flag concern**, with a 5–500 character reason. Reasons and network/browser hashes stay in private review records; the public UI receives counts and the visitor's own choice. Contributors cannot vote on their own submissions. A visitor may revise their choice in the current round.

Three agreeing reviews from distinct browser tokens and network hashes change the stored status to `verified`, `resolved` or `rejected`. The UI labels `verified` as **Reviewed**. Flags raise visibility in the Flagged queue and never change status by themselves. A decision starts a new round and a 15-minute cooldown to limit rapid reversals. The old round's reviews and one append-only decision in the existing history remain intact. A stale round or expected status cannot overwrite a newer decision.

Consensus rejection withdraws a report and its photo from public views without deleting the underlying records. Aggregate IDs/round/count events remain readable for once-public submissions so Realtime can invalidate a previously cached pin; they contain no descriptions, reasons, photo links or identities. Previously copied photo URLs retain their existing 600-second expiry. Historical private reports never receive public aggregates through this workflow.

Community agreement is not professional verification or a safety guarantee. Anonymous review cannot establish that each visitor is a different person. Network restrictions reduce repeat-vote abuse but can limit participation from people sharing a home, school, VPN or carrier connection. Rotating connections/storage can still defeat anonymous identity limits; do not describe this as proof of independent human reviewers.

The browser retains a random 256-bit token, not an email, name or password. Clearing storage loses the ability to recognize that visitor's previous contributions/reviews. The server uses domain-separated HMACs of this token and the gateway's nearest forwarded IP. It stores no raw token or address in review tables and never returns the hashes. The deployed gateway must append/normalize the nearest forwarding address; missing or malformed network metadata fails closed. Multi-network gateway behavior needs validation before claiming stronger abuse resistance. Existing local Auth session persistence is removed during startup, session restoration/refresh and email callbacks are disabled, and no new Auth sessions are created.

Do not include students' names, identifiable children, home addresses or recurring travel schedules. New photos are intended for public community review. Historical private submissions, private photos, identity data and old review notes remain private; the new visibility policy applies only to explicitly marked new community submissions. No historical reports are republished or reassigned.

## Server controls and evidence

`community-reports` validates the project key and streams at most 7.1 MB of JSON. JPEG/PNG/WebP evidence is checked for a matching binary signature and a 5 MB limit. Writes use a service-only RPC; browsers cannot fabricate network hashes, totals or status transitions through the Data API. The service-role key stays in built-in Edge secrets and is never compiled into Flutter.

The database serializes review and quota updates, requires one vote per browser and connection per round, validates the current status/round and records the consensus atomically. Direct legacy inserts cannot set community visibility/round fields. Limits are 20 submissions/day per browser or network, 60 service actions/hour per browser or network, and 1,000/hour project-wide; photo preparation also consumes the hourly quota before Storage writes. These limits bound usage and may need reviewed adjustment for shared networks.

Photos use the supported Storage API. Upload happens before the report/metadata transaction; a known rejected transaction removes only its newly uploaded object. Idempotent retries retain the canonical photo and remove a redundant attempted upload. A temporary signed-URL failure does not undo a saved report. An unknown database commit receipt preserves uploaded evidence and instructs the client to retry the same ID. If that transaction never committed, an unreferenced object can remain: an operator must compare metadata and object inventory before removing it through the Storage API. Never delete objects just because a response timed out. No automatic production cleanup/reset runs.

The existing geographic/RLS queries, photo bucket, analytics deduplication, CSV/advanced exports, route engine and 100 m active-report avoidance are reused. Consensus changes update the same report, not a duplicate record. Realtime events for reports and vote totals refresh lists, maps and Analytics. The Community queue includes all public schools with concerns, school-name filtering, status/flag filters and 25-row pages; it never downloads the nationwide school directory to construct that queue.

## Deployment and retirement

1. Apply all prior migrations, then `20261025211230_anonymous_community_review.sql`. Do not edit historical migrations or delete Auth/audit data. This adds explicitly public community submissions, private contributors/reviews/quotas and public aggregate totals. It extends the existing status audit trigger without granting anonymous direct status updates.
2. Deploy `community-reports` with `index.ts` and `handler.ts`, `verify_jwt=false`; the handler validates the public project key itself. It uses the built-in `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. There are no client secret keys or SMTP requirements.
3. Redeploy the retired `account-auth` endpoint from its new source. It returns HTTP 410 and no longer resolves usernames or creates sessions. Keep this retirement response for old installed clients. Registration/application/bootstrap client code has been removed. Local Auth signup is disabled in config. Hosted Auth settings are separate; existing Auth identities are not deleted, and direct hosted Auth provider settings were not changed without a signed-in dashboard session.
4. Build/reload Flutter. There is no account icon or privileged review tab. Android/iOS email-callback registrations are removed; network/location permissions remain. Existing private legacy schema/RPCs and trusted maintenance scripts are retained only to preserve historical database contracts, not exposed as app features.
5. Validate public submissions/photo upload and three-network consensus using explicitly authorized disposable fixtures in a separate environment. Do not manufacture votes on real community reports. Never grant everyone membership in the historical role table.

The legacy staging reset recognizes the new child tables when they are empty. If community evidence exists it deliberately refuses the old backup/reset workflow, so contributor/review data cannot be silently cascaded away without an extended reviewed backup. Production reset remains prohibited. No reset, existing report deletion, identity deletion or membership change is part of this rollout.

## Rollout on 2026-10-25

The operator-confirmed connected project `bnvmlxgdqgwjtxgtsaak` now has the community migration applied and `community-reports` version 1 active. The migration API recorded it as `20261025215449_anonymous_community_review`, corresponding to source `20261025211230_anonymous_community_review.sql`. Match by this recorded mapping before future migration operations; do not replay the source solely because the timestamp differs. Earlier timestamp mappings are in the [historical deployment record](ACCOUNT_DEPLOYMENT_2026-10-25.md). No migration-history repair or blanket `db push` was performed.

The retired `account-auth` version 2 returns HTTP 410. Live probes confirmed the anonymous service reaches database validation (HTTP 400 for a nonexistent report), while direct anonymous invocation of its service-only write RPC returns HTTP 401. Public report/photo policies and aggregate RLS remain enabled. The security advisor's private deny-all table notices are expected; its pre-existing [password-protection advisory](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection) is unchanged.

Before/after counts and content digests matched for all 114 pre-existing reports, 4 photo metadata records and 4 Storage objects; all 124,689 schools remained. The same 3 Auth identity IDs and 0 memberships remained. There were no new community reports, reviews, sample uploads or synthetic votes in the connected project. Existing reports, authors, statuses, coordinates and photo ownership were not rewritten.

The standard web build passed and was inspected in the local browser: the account icon and privileged review tab are absent, Community is available to visitors, and desktop/narrow navigation works. This is a rebuilt local client and deployed backend; no external frontend hosting destination was supplied or published. Existing installed/debug clients must restart or reload to use the new UI.

## Verification

Run `flutter analyze`, `flutter test --no-pub`, `npm test --prefix supabase/tests`, Deno tests under `supabase/functions/community-reports/`, and `flutter build web --no-pub`. SQL checks use disposable PostgreSQL/PostGIS with rollback-only synthetic identities; HTTP tests use mocked requests. Coverage includes nearest-school enforcement, anonymous privacy, own/repeated/network votes, three-vote transitions, stale rounds, cooldown, flags, legacy audit/photo preservation, quota checks before uploads, supported Storage cleanup, uncertain receipts, pagination and enlarged mobile layouts. Legacy database policy/operator checks remain even though those client screens were removed.

Actual checks: analyzer clean; **129 Flutter tests passed**; **nine SQL suites passed** (483 statements, including 46 community statements); **15 Node operator tests passed**; **30 Edge tests passed** and both new/retired function entrypoints type-checked. The web build, native XML/plist syntax and diff checks passed. Existing `image 4.3.0` Wasm dry-run warnings remain; a Wasm deployment was not tested. No real three-network voting, live photo submission or native-device interaction was exercised against community data; those require authorized disposable fixtures. Browser screenshots are local verification artifacts under `build/verification/`.

## Modified source groups

- Removed active account/authentication/settings pages, application/bootstrap utilities, privileged review screens/repository/models and their superseded UI tests. Historical migrations and database/operator regression checks remain.
- Added `lib/services/community_repository.dart`, `lib/screens/community_screen.dart` and `community_review_dialog.dart`; simplified `home_screen.dart` and the existing hazard repository around anonymous submissions and reviews.
- Updated startup/session storage, report retry IDs/photo feedback, review labels, map/list/Analytics refresh, exports and route explanatory text. Routing calculations, map infrastructure and school geography are unchanged.
- Added the community migration, `supabase/functions/community-reports/` implementation/tests, `supabase/checks/community_review.sql` and `test/community_review_test.dart`; extended the report-form retry test and SQL harness.
- Retired the previous authentication Edge handler, removed obsolete native email callbacks, disabled local signup, and updated README/connection/current workflow documentation.
