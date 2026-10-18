-- Moderator membership is provisioned only through trusted admin SQL.
create table public.report_moderators (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.report_moderators enable row level security;
revoke all on public.report_moderators from public, anon, authenticated;
grant select on public.report_moderators to authenticated;
create policy "Read own moderator membership" on public.report_moderators
  for select to authenticated using (user_id = (select auth.uid()));

create function public.is_report_moderator() returns boolean
language sql stable security invoker set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.report_moderators where user_id = auth.uid()
  );
$$;
revoke all on function public.is_report_moderator() from public, anon, authenticated;
grant execute on function public.is_report_moderator() to authenticated;

create policy "Moderators read all reports" on public.hazard_reports
  for select to authenticated using ((select public.is_report_moderator()));
grant update (status) on public.hazard_reports to authenticated;
create policy "Moderators change report status" on public.hazard_reports
  for update to authenticated
  using ((select public.is_report_moderator()))
  with check ((select public.is_report_moderator()));

create table public.report_flags (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.hazard_reports(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  unique (report_id, user_id)
);
create index report_flags_user_idx on public.report_flags(user_id);
create index report_flags_reviewer_idx on public.report_flags(reviewed_by);
alter table public.report_flags enable row level security;
revoke all on public.report_flags from public, anon, authenticated;
grant select on public.report_flags to authenticated;
-- Clients cannot forge timestamps or mark their own flags reviewed.
grant insert (report_id, user_id, reason) on public.report_flags to authenticated;
create policy "Read own flags or moderate flags" on public.report_flags
  for select to authenticated using (
    user_id = (select auth.uid()) or (select public.is_report_moderator())
  );
create policy "Flag visible active reports" on public.report_flags
  for insert to authenticated with check (
    user_id = (select auth.uid()) and exists (
      select 1 from public.hazard_reports h
      where h.id = report_id and h.status in ('unverified', 'verified')
    )
  );

create table public.report_moderation_history (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.hazard_reports(id) on delete restrict,
  actor_id uuid references auth.users(id) on delete set null,
  previous_status text not null check (
    previous_status in ('unverified', 'verified', 'rejected', 'resolved')
  ),
  status text not null check (status in ('verified', 'rejected', 'resolved')),
  reason text not null check (char_length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now()
);
create index report_history_report_time_idx
  on public.report_moderation_history(report_id, created_at desc);
create index report_history_actor_idx on public.report_moderation_history(actor_id);
alter table public.report_moderation_history enable row level security;
revoke all on public.report_moderation_history from public, anon, authenticated;
grant select on public.report_moderation_history to authenticated;
create policy "Authors and moderators read moderation history"
  on public.report_moderation_history for select to authenticated using (
    (select public.is_report_moderator()) or exists (
      select 1 from public.hazard_reports h
      where h.id = report_id and h.reporter_id = (select auth.uid())
    )
  );

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
-- This trigger alone can append history and close flags. Definer access is
-- required because clients have no write privileges on those audit fields.
create function private.audit_report_moderation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  note text := btrim(current_setting('saferoutes.moderation_reason', true));
begin
  if actor is null or not exists (
    select 1 from public.report_moderators where user_id = actor
  ) then
    raise exception 'Moderator access required' using errcode = '42501';
  end if;
  if new.status not in ('verified', 'rejected', 'resolved')
      or note is null or char_length(note) not between 5 and 500 then
    raise exception 'Choose a review outcome and provide a reason (5-500 characters)';
  end if;
  if new.status = old.status and not exists (
    select 1 from public.report_flags where report_id = old.id and reviewed_at is null
  ) then
    raise exception 'This report already has that status. Refresh to see the latest review.';
  end if;
  insert into public.report_moderation_history
    (report_id, actor_id, previous_status, status, reason)
    values (old.id, actor, old.status, new.status, note);
  update public.report_flags set reviewed_at = now(), reviewed_by = actor
    where report_id = old.id and reviewed_at is null;
  return new;
end;
$$;
revoke all on function private.audit_report_moderation() from public, anon, authenticated;
create trigger audit_report_moderation before update of status on public.hazard_reports
  for each row execute function private.audit_report_moderation();

-- Invoker RPC uses the same column grants and RLS as a direct update.
-- The status predicate prevents a stale review from overwriting a newer one.
create function public.moderate_hazard_report(
  p_report_id uuid, p_status text, p_reason text, p_expected_status text
) returns setof public.hazard_reports
language plpgsql security invoker set search_path = '' as $$
begin
  if auth.uid() is null or not public.is_report_moderator() then
    raise exception 'Moderator access required' using errcode = '42501';
  end if;
  perform set_config('saferoutes.moderation_reason', btrim(p_reason), true);
  return query update public.hazard_reports set status = p_status
    where id = p_report_id and status = p_expected_status returning *;
  if not found then
    raise exception 'Report changed or is unavailable. Refresh before reviewing again.';
  end if;
end;
$$;
revoke all on function public.moderate_hazard_report(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.moderate_hazard_report(uuid, text, text, text)
  to authenticated;
