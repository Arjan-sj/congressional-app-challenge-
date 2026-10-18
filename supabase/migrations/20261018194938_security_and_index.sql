revoke execute on function public.rls_auto_enable()
  from public, anon, authenticated;

create index if not exists hazard_reports_reporter_id_idx
  on public.hazard_reports (reporter_id);
