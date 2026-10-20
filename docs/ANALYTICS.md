# SafeRoutes analytics

The Analytics tab is backed by the `get_hazard_analytics` Supabase RPC in
`supabase/migrations/20261020024242_analytics_dashboard.sql`.

## Data and permissions

- The function is `SECURITY INVOKER`, so the existing `hazard_reports` Row
  Level Security policies determine every report included in the result.
- Signed-out visitors see reviewed public reports. Authors may also see their
  own pending reports. Moderators see the queue allowed by the moderator RLS
  policy.
- The response and every export omit `reporter_id`, descriptions, and other
  private user data.
- Reports with the same school, hazard category, and approximately 11-meter
  coordinate cell are consolidated before aggregation. The response reports
  both raw and unique counts so the behavior is visible.
- `is_demo=true` rows are excluded.

## Aggregation and Realtime

The RPC calculates overview metrics, equal-length previous-period comparisons,
daily/weekly/monthly trends, category/status/severity distributions, school
rollups, resolution timing, and paginated map records in Postgres. Partial and
composite indexes support common date, school, type, status, and severity
filters.

`hazard_reports` is added to the `supabase_realtime` publication once. The
Flutter client listens for RLS-visible Postgres changes, debounces bursts, and
re-fetches the aggregate after inserts, verification, resolution, or deletion.

## Filters and exports

The global date, school, district, map bounds, category, severity, and status
filters are sent directly to the RPC and therefore affect every metric, chart,
map, school comparison, and export. Exports support CSV, XLSX, PDF, JSON, and
GeoJSON. PDF reports render overview, time-series, and category charts. Large
hazard-location exports fetch every RPC page before creating the file.

## Verification

After applying the migration:

1. Call `get_hazard_analytics` as `anon`, an author, and a moderator to confirm
   the response matches each role's RLS visibility.
2. Add or moderate a report and confirm the open Analytics tab refreshes.
3. Run `flutter test`, `dart analyze lib test`, and `git diff --check`.
4. Run Supabase security and performance advisors after schema changes.

Community severity remains self-reported. An unverified report is not a
verified hazard, and neither the analytics map nor an export is a safety audit.
