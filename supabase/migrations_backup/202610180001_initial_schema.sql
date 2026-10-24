-- SafeRoutes first Supabase migration (pilot MVP)
-- Run in a NEW Supabase project's SQL Editor once, or use the Supabase CLI.
-- This creates data tables and deliberately conservative Row Level Security.
-- All community-submitted hazards remain UNVERIFIED until reviewed by an
-- administrator using a trusted/server-side workflow (not implemented yet).

create table if not exists public.schools (
  id text primary key,
  name text not null,
  address text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  created_at timestamptz not null default now()
);

create table if not exists public.hazard_reports (
  id uuid primary key default gen_random_uuid(),
  school_id text not null references public.schools(id) on delete restrict,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  type text not null check (
    type in ('missing_sidewalk', 'difficult_crossing', 'blocked_path', 'bike_route')
  ),
  severity smallint not null check (severity between 1 and 5),
  description text not null check (
    char_length(btrim(description)) between 5 and 250
  ),
  status text not null default 'unverified' check (
    status in ('unverified', 'verified', 'resolved', 'rejected')
  ),
  reporter_id uuid references auth.users(id) on delete set null
    default auth.uid(),
  is_demo boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists hazard_reports_school_created_idx
  on public.hazard_reports (school_id, created_at desc);
create index if not exists hazard_reports_status_idx
  on public.hazard_reports (status);

-- Both tables are API-exposed; Row Level Security is mandatory.
alter table public.schools enable row level security;
alter table public.hazard_reports enable row level security;

-- Explicitly grant only the minimum API privileges.
revoke all on public.schools from anon, authenticated;
revoke all on public.hazard_reports from anon, authenticated;
grant select on public.schools to anon, authenticated;
grant select, insert on public.hazard_reports to authenticated;
grant select on public.hazard_reports to anon;

-- Schools can be listed by the app. Only privileged backend/admin SQL
-- may create or edit schools.
drop policy if exists "Public school directory" on public.schools;
create policy "Public school directory"
  on public.schools for select to anon, authenticated
  using (true);

-- Members of the public only see reviewed records. Signed-in users can
-- also see their own unverified submissions for feedback/tracking.
drop policy if exists "Read reviewed or own hazard reports"
  on public.hazard_reports;
create policy "Read reviewed or own hazard reports"
  on public.hazard_reports for select to anon, authenticated
  using (
    status in ('verified', 'resolved')
    or reporter_id = (select auth.uid())
  );

-- A signed-in user can submit a report only for themself and never
-- mark it verified. The status and author are also validated by RLS
-- even if an attacker bypasses the Flutter form.
drop policy if exists "Create own unverified report"
  on public.hazard_reports;
create policy "Create own unverified report"
  on public.hazard_reports for insert to authenticated
  with check (
    (select auth.uid()) is not null
    and reporter_id = (select auth.uid())
    and status = 'unverified'
  );

-- No UPDATE or DELETE privileges/policies for anonymous or authenticated
-- clients. Moderation must be implemented as a separate privileged flow
-- with server-side role checks before production.

-- Sample *school* only. This is an approximate public campus location,
-- not a verified entrance or walking-route endpoint.
insert into public.schools (
  id, name, address, latitude, longitude
) values (
  'sample-school',
  'Schaumburg High School',
  '1100 W Schaumburg Rd, Schaumburg, IL',
  42.027416, -88.106632
)
on conflict (id) do nothing;

-- No sample hazards are inserted: nobody should mistake an invented pin
-- for a verified safety concern.
