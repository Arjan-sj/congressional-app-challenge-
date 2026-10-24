-- Optional photo evidence for hazard reports.
-- Objects stay private and are served only through short-lived signed URLs.

create table public.hazard_report_photos (
  report_id uuid primary key
    references public.hazard_reports(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  storage_path text not null unique,
  created_at timestamptz not null default now(),
  constraint hazard_report_photos_path_check check (
    storage_path ~ (
      '^' || report_id::text ||
      '/[0-9]+\\.(jpg|png|webp)$'
    )
  )
);

create index hazard_report_photos_owner_idx
  on public.hazard_report_photos(owner_id);

alter table public.hazard_report_photos enable row level security;
revoke all on public.hazard_report_photos from public, anon, authenticated;
grant select on public.hazard_report_photos to anon, authenticated;
grant insert (report_id, owner_id, storage_path)
  on public.hazard_report_photos to authenticated;
grant delete on public.hazard_report_photos to authenticated;

create policy "Public reads photos for reviewed reports"
  on public.hazard_report_photos for select to anon
  using (
    exists (
      select 1 from public.hazard_reports h
      where h.id = report_id and h.status in ('verified', 'resolved')
    )
  );

create policy "Members read visible report photos"
  on public.hazard_report_photos for select to authenticated
  using (
    exists (
      select 1 from public.hazard_reports h
      where h.id = report_id and (
        h.status in ('verified', 'resolved')
        or h.reporter_id = (select auth.uid())
        or (select public.is_report_moderator())
      )
    )
  );

create policy "Authors attach one photo to their own report"
  on public.hazard_report_photos for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and exists (
      select 1 from public.hazard_reports h
      where h.id = report_id and h.reporter_id = (select auth.uid())
    )
  );

create policy "Authors or moderators remove photo metadata"
  on public.hazard_report_photos for delete to authenticated
  using (
    owner_id = (select auth.uid())
    or (select public.is_report_moderator())
  );

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'hazard-photos',
  'hazard-photos',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "Public reads reviewed hazard photos"
  on storage.objects for select to anon
  using (
    bucket_id = 'hazard-photos'
    and exists (
      select 1
      from public.hazard_report_photos p
      join public.hazard_reports h on h.id = p.report_id
      where p.storage_path = name
        and h.status in ('verified', 'resolved')
    )
  );

create policy "Members read visible hazard photos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'hazard-photos'
    and exists (
      select 1
      from public.hazard_report_photos p
      join public.hazard_reports h on h.id = p.report_id
      where p.storage_path = name and (
        h.status in ('verified', 'resolved')
        or h.reporter_id = (select auth.uid())
        or (select public.is_report_moderator())
      )
    )
  );

create policy "Authors upload their hazard photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'hazard-photos'
    and exists (
      select 1
      from public.hazard_report_photos p
      join public.hazard_reports h on h.id = p.report_id
      where p.storage_path = name
        and p.owner_id = (select auth.uid())
        and h.reporter_id = (select auth.uid())
    )
  );

-- Storage upsert requires SELECT as well as INSERT and UPDATE. A viewer gets
-- SELECT only; these write predicates still restrict replacement to the owner
-- or a moderator.
create policy "Authors or moderators replace hazard photos"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'hazard-photos'
    and exists (
      select 1 from public.hazard_report_photos p
      where p.storage_path = name and (
        p.owner_id = (select auth.uid())
        or (select public.is_report_moderator())
      )
    )
  )
  with check (
    bucket_id = 'hazard-photos'
    and exists (
      select 1 from public.hazard_report_photos p
      where p.storage_path = name and (
        p.owner_id = (select auth.uid())
        or (select public.is_report_moderator())
      )
    )
  );

create policy "Authors or moderators delete hazard photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'hazard-photos'
    and exists (
      select 1 from public.hazard_report_photos p
      where p.storage_path = name and (
        p.owner_id = (select auth.uid())
        or (select public.is_report_moderator())
      )
    )
  );

grant delete on public.hazard_reports to authenticated;
create policy "Authors or moderators delete reports"
  on public.hazard_reports for delete to authenticated
  using (
    reporter_id = (select auth.uid())
    or (select public.is_report_moderator())
  );

-- A deleted report should also remove its moderation records. The app removes
-- the Storage object through the authenticated Storage API before this cascade.
alter table public.report_moderation_history
  drop constraint report_moderation_history_report_id_fkey;
alter table public.report_moderation_history
  add constraint report_moderation_history_report_id_fkey
  foreign key (report_id) references public.hazard_reports(id) on delete cascade;
