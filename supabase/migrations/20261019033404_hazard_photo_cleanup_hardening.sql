-- Keep Storage objects and their database metadata attached until the object
-- has been removed through the Storage API.

revoke delete on public.hazard_report_photos from authenticated;
drop policy "Authors or moderators remove photo metadata"
  on public.hazard_report_photos;

-- An upsert requires INSERT as well as UPDATE. Moderators therefore need the
-- INSERT predicate for an existing report photo in order to replace it.
drop policy "Authors upload their hazard photos" on storage.objects;
create policy "Authors or moderators upload hazard photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'hazard-photos'
    and exists (
      select 1
      from public.hazard_report_photos p
      join public.hazard_reports h on h.id = p.report_id
      where p.storage_path = name and (
        (
          p.owner_id = (select auth.uid())
          and h.reporter_id = (select auth.uid())
        )
        or (select public.is_report_moderator())
      )
    )
  );

create function public.prevent_hazard_report_photo_orphan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from storage.objects o
    join public.hazard_report_photos p on p.storage_path = o.name
    where p.report_id = old.id
      and o.bucket_id = 'hazard-photos'
  ) then
    raise exception using
      errcode = '23503',
      message = 'Delete the hazard photo through the Storage API before deleting its report.';
  end if;
  return old;
end;
$$;

revoke all on function public.prevent_hazard_report_photo_orphan() from public;

create trigger prevent_hazard_report_photo_orphan
before delete on public.hazard_reports
for each row execute function public.prevent_hazard_report_photo_orphan();
