-- Enforce the computer-selected first candidate on every new/changed report.
-- Existing report associations and historical moderation are not rewritten.
create or replace function private.validate_report_school() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare closest_school_id text;
begin
  if tg_op = 'UPDATE' then
    if new.school_id is not distinct from old.school_id
      and new.latitude is not distinct from old.latitude
      and new.longitude is not distinct from old.longitude then return new; end if;
  end if;
  select s.school_id into closest_school_id
    from public.nearest_schools(new.latitude,new.longitude) s limit 1;
  if closest_school_id is null then
    raise exception 'No school was found within % meters of the hazard location',
      public.report_school_radius_meters() using errcode='23514';
  end if;
  if new.school_id is distinct from closest_school_id then
    raise exception 'The report must use the automatically selected closest school. Refresh the location and retry.'
      using errcode='23514';
  end if;
  return new;
end $$;
revoke all on function private.validate_report_school() from public,anon,authenticated;
