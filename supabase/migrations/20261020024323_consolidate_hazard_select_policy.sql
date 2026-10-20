-- Preserve the existing visibility rules while evaluating a single permissive
-- SELECT policy per role. This removes the database advisor warning caused by
-- separate public/author and moderator policies.
drop policy if exists "Moderators read all reports"
  on public.hazard_reports;
drop policy if exists "Read reviewed or own hazard reports"
  on public.hazard_reports;

create policy "Read permitted hazard reports"
  on public.hazard_reports
  for select
  to anon, authenticated
  using (
    status in ('verified', 'resolved')
    or reporter_id = (select auth.uid())
    or (select public.is_report_moderator())
  );
