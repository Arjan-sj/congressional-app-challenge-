-- Anonymous users cannot execute the moderator membership helper. Keep one
-- SELECT policy per role so each path evaluates only predicates it may use.
drop policy if exists "Read permitted hazard reports"
  on public.hazard_reports;

create policy "Public reads reviewed hazard reports"
  on public.hazard_reports
  for select
  to anon
  using (status in ('verified', 'resolved'));

create policy "Members read permitted hazard reports"
  on public.hazard_reports
  for select
  to authenticated
  using (
    status in ('verified', 'resolved')
    or reporter_id = (select auth.uid())
    or (select public.is_report_moderator())
  );
