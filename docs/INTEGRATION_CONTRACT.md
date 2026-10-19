# SafeRoutes: teammate integration contract (v0)

Agree on these names before connecting Flutter to Supabase. This is a **proposal**; update both code and docs together if you change it.

## 1. One shared report

| Field | Client type | Backend role |
| --- | --- | --- |
| `id` | String | generated unique ID |
| `schoolId` | String | FK to `schools` |
| `type` | HazardType | controlled category |
| `severity` | int, 1–5 | **self-reported** severity |
| `description` | String | limited plain text |
| `latitude`, `longitude` | double? | actual map-selected location; required before remote submission |
| `status` | ReportStatus | server defaults to `unverified` |
| `createdAt` | DateTime | server timestamp for production |
| `isDemo` | bool | true only for fictional/test data |

For production JSON, use `snake_case` column names such as `school_id`, `created_at`, `latitude`, `longitude`. Define a single conversion function in a repository/service class. Never let the client control the verification status.

## 2. Division of work

**Frontend:** school search and selection, map layers, hazard pins, reporting flow, route comparison only on verified paths.

**Backend:** database tables, verification/moderation, row-level security, duplicate suggestions, persistence and queries.

**Shared interface:**
- `Future<List<HazardReport>> fetchHazards(String schoolId)`
- `Future<void> submitHazard(HazardReport report)` (must reject missing location for production)
- A way to refresh the map after successful submission

## 3. Privacy & safety rules

- No child names, personal addresses, travel times or precise recurring student routes.
- Public submissions are **unverified** by default; verification is performed by authorized moderators, not report submitters.
- Uploads, if eventually enabled, need review and metadata stripping.
- Reports are observations, NOT certified hazards; ranking is prioritization for review, NOT crash-risk probability.
- If sidewalk/crossing source data is incomplete, say so rather than routing over unknown geometry.
- Test fixtures must remain isolated from the running map. Live entries retain their server-provided verification status.

## 4. MVP acceptance tests

- [ ] Shared report model matches Supabase schema.
- [ ] Explore renders map pins from fetched report data.
- [ ] A validated report with real map coordinates persists after refresh.
- [ ] Report cannot be created as verified by an anonymous client.
- [ ] Duplicate reports do not artificially inflate prioritization.
- [ ] Any routing output clearly indicates unknown infrastructure.
