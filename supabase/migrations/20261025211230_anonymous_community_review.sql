-- Anonymous community contributions. Historical identities/memberships/audits
-- remain private; no Auth identities or role memberships are created here.
alter table public.hazard_reports add column community_submitted boolean not null default false;
alter table public.hazard_reports add column community_review_round integer not null default 0;
alter table public.hazard_reports add column community_decided_at timestamptz;
alter table public.hazard_report_photos alter column owner_id drop not null;
-- Legacy clients may retain their old narrow submission contract, but cannot
-- mark a direct insert as a public community contribution or forge rounds.
revoke insert on public.hazard_reports from authenticated;
grant insert(id,school_id,latitude,longitude,type,severity,description,status,reporter_id,is_demo,created_at) on public.hazard_reports to authenticated;
create policy "Read public community submissions" on public.hazard_reports for select to anon,authenticated
  using(community_submitted and not is_demo and status<>'rejected');
create policy "Read community photo metadata" on public.hazard_report_photos for select to anon,authenticated
  using(owner_id is null and exists(select 1 from public.hazard_reports h where h.id=report_id and h.community_submitted and not h.is_demo and h.status<>'rejected'));
create policy "Read community photo objects" on storage.objects for select to anon,authenticated using(
  bucket_id='hazard-photos' and exists(select 1 from public.hazard_report_photos p join public.hazard_reports h on h.id=p.report_id
    where p.storage_path=name and p.owner_id is null and h.community_submitted and not h.is_demo and h.status<>'rejected'));

create table private.community_contributors(
  report_id uuid primary key references public.hazard_reports(id) on delete cascade,
  participant_hash text not null check(participant_hash ~ '^[0-9a-f]{64}$')
);
create table private.community_reviews(
  report_id uuid not null references public.hazard_reports(id) on delete cascade,
  review_round integer not null, participant_hash text not null check(participant_hash ~ '^[0-9a-f]{64}$'),
  network_hash text not null check(network_hash ~ '^[0-9a-f]{64}$'),
  choice text not null check(choice in ('verified','resolved','rejected','flag')),
  reason text not null check(char_length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now(),
  primary key(report_id,review_round,participant_hash),unique(report_id,review_round,network_hash)
);
create table private.community_attempts(
  participant_hash text not null,network_hash text not null,action text not null,created_at timestamptz not null default now()
);
create index community_attempt_participant on private.community_attempts(participant_hash,created_at);
create index community_attempt_network on private.community_attempts(network_hash,created_at);
create index community_attempt_time on private.community_attempts(created_at);
alter table private.community_contributors enable row level security;
alter table private.community_reviews enable row level security;
alter table private.community_attempts enable row level security;
revoke all on private.community_contributors,private.community_reviews,private.community_attempts from public,anon,authenticated,service_role;

create table public.community_review_totals(
  report_id uuid primary key references public.hazard_reports(id) on delete cascade,
  review_round integer not null default 0,
  verified integer not null default 0,rejected integer not null default 0,resolved integer not null default 0,flags integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.community_review_totals enable row level security;
revoke all on public.community_review_totals from public,anon,authenticated,service_role;
grant select on public.community_review_totals to anon,authenticated;
-- Rows are created only for once-public reports by the trusted RPC. These contain
-- counts/IDs only. Keeping aggregate events readable after withdrawal lets clients
-- invalidate their previously public cached report without exposing its contents.
create policy "Read public community totals" on public.community_review_totals for select to anon,authenticated using(true);
alter publication supabase_realtime add table public.community_review_totals;

-- Preserve the existing audit mechanism. Only a trusted service transaction with
-- three recorded independent-network votes can append a community decision.
create or replace function private.audit_report_moderation() returns trigger
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); note text:=btrim(current_setting('saferoutes.moderation_reason',true)); community boolean;
begin
  community:=current_setting('role',true)='service_role'
    and new.community_review_round=old.community_review_round+1
    and (select count(*) from private.community_reviews where report_id=old.id and review_round=old.community_review_round and choice=new.status)>=3;
  if not coalesce(community,false) and (actor is null or not exists(select 1 from public.report_moderators where user_id=actor)) then
    raise exception 'Review authorization required' using errcode='42501'; end if;
  if new.status not in ('verified','rejected','resolved') or note is null or char_length(note) not between 5 and 500 then
    raise exception 'Review outcome and reason required'; end if;
  if new.status=old.status and not exists(select 1 from public.report_flags where report_id=old.id and reviewed_at is null) then
    raise exception 'Report already has that status'; end if;
  insert into public.report_moderation_history(report_id,actor_id,previous_status,status,reason)
    values(old.id,case when community then null else actor end,old.status,new.status,note);
  update public.report_flags set reviewed_at=now(),reviewed_by=case when community then null else actor end where report_id=old.id and reviewed_at is null;
  return new;
end $$;

create function private.community_action(p_action text,p_participant_hash text,p_network_hash text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.hazard_reports; rid uuid; closest text; counts public.community_review_totals;
  v_choice text; note text; photo text; changed boolean:=false; result jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise exception 'Trusted service required' using errcode='42501';end if;
  if p_participant_hash is null or p_network_hash is null or p_participant_hash !~ '^[0-9a-f]{64}$' or p_network_hash !~ '^[0-9a-f]{64}$'
    or p_action is null or p_action not in ('prepare','submit','review','summary') then raise exception 'Invalid contribution';end if;
  rid:=(p_payload->>'id')::uuid;
  if rid is null then raise exception 'Report ID required';end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('community:quota',0));
  delete from private.community_attempts where created_at<now()-interval '1 day';
  if (select count(*) from private.community_attempts where created_at>now()-interval '1 hour')>=1000
    or (select count(*) from private.community_attempts where (participant_hash=p_participant_hash or network_hash=p_network_hash) and created_at>now()-interval '1 hour')>=60
    or (p_action in ('prepare','submit') and (select count(*) from private.community_attempts where action='submit' and (participant_hash=p_participant_hash or network_hash=p_network_hash))>=20)
    then raise exception 'Contribution limit reached. Try again later.' using errcode='P0429';end if;
  insert into private.community_attempts(participant_hash,network_hash,action) values(p_participant_hash,p_network_hash,p_action);
  if p_action='prepare' then return jsonb_build_object('allowed',true);end if;
  select * into target from public.hazard_reports where id=rid for update;
  if p_action='submit' then
    if found then
      if not exists(select 1 from private.community_contributors where report_id=rid and participant_hash=p_participant_hash) then
        raise exception 'Report ID unavailable';end if;
    else
      select school_id into closest from public.nearest_schools((p_payload->>'latitude')::float8,(p_payload->>'longitude')::float8) limit 1;
      if closest is null then raise exception 'No nearby school was found. Move the map pin and retry.';end if;
      photo:=nullif(p_payload->>'photo_path','');
      if photo is not null and photo !~ ('^'||rid::text||'/[0-9]+\.(jpg|png|webp)$') then raise exception 'Invalid photo path';end if;
      insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,reporter_id,status,is_demo,community_submitted)
        values(rid,closest,(p_payload->>'latitude')::float8,(p_payload->>'longitude')::float8,p_payload->>'type',
          (p_payload->>'severity')::smallint,btrim(p_payload->>'description'),null,'unverified',false,true) returning * into target;
      insert into private.community_contributors values(rid,p_participant_hash);
      insert into public.community_review_totals(report_id) values(rid);
      if photo is not null then insert into public.hazard_report_photos(report_id,owner_id,storage_path) values(rid,null,photo);end if;
    end if;
  else
    if not found or target.is_demo or not((target.community_submitted and target.status<>'rejected') or target.status in ('verified','resolved')) then
      raise exception 'Report unavailable';end if;
    if p_action='review' then
      if (p_payload->>'review_round')::integer is distinct from target.community_review_round or p_payload->>'expected_status' is distinct from target.status then
        raise exception 'Report changed. Refresh before reviewing again.' using errcode='P0409';end if;
      if target.community_decided_at>now()-interval '15 minutes' then raise exception 'A recent community decision is cooling down. Try later.' using errcode='P0429';end if;
      if exists(select 1 from private.community_contributors where report_id=rid and participant_hash=p_participant_hash) then
        raise exception 'You cannot review your own submission';end if;
      v_choice:=p_payload->>'choice';note:=btrim(p_payload->>'reason');
      if v_choice is null or v_choice not in ('verified','resolved','rejected','flag') or v_choice=target.status or note is null or char_length(note) not between 5 and 500 then
        raise exception 'Choose a different outcome and provide a reason (5–500 characters)';end if;
      if exists(select 1 from private.community_reviews where report_id=rid and review_round=target.community_review_round and network_hash=p_network_hash and participant_hash<>p_participant_hash) then
        raise exception 'This connection has already reviewed this report';end if;
      insert into private.community_reviews(report_id,review_round,participant_hash,network_hash,choice,reason)
        values(rid,target.community_review_round,p_participant_hash,p_network_hash,v_choice,note)
        on conflict(report_id,review_round,participant_hash) do update set choice=excluded.choice,reason=excluded.reason;
      insert into public.community_review_totals(report_id,review_round,verified,rejected,resolved,flags)
        select rid,target.community_review_round,count(*) filter(where r.choice='verified'),count(*) filter(where r.choice='rejected'),
          count(*) filter(where r.choice='resolved'),count(*) filter(where r.choice='flag')
        from private.community_reviews r where report_id=rid and review_round=target.community_review_round
        on conflict(report_id) do update set review_round=excluded.review_round,verified=excluded.verified,rejected=excluded.rejected,
          resolved=excluded.resolved,flags=excluded.flags,updated_at=now() returning * into counts;
      if v_choice<>'flag' and (select count(*) from private.community_reviews r where report_id=rid and review_round=target.community_review_round and r.choice=v_choice)>=3 then
        perform set_config('saferoutes.moderation_reason','Community consensus: three agreeing reviews on independent network connections.',true);
        update public.hazard_reports set status=v_choice,community_review_round=community_review_round+1,community_decided_at=now() where id=rid returning * into target;
        update public.community_review_totals set review_round=target.community_review_round,verified=0,rejected=0,resolved=0,flags=0,updated_at=now() where report_id=rid;
        changed:=true;
      end if;
    end if;
  end if;
  select * into counts from public.community_review_totals where report_id=rid;
  result:=jsonb_build_object('report',jsonb_build_object('id',target.id,'school_id',target.school_id,'latitude',target.latitude,'longitude',target.longitude,
    'type',target.type,'severity',target.severity,'description',target.description,'status',target.status,'created_at',target.created_at,
    'is_demo',target.is_demo,'school',jsonb_build_object('name',(select name from public.schools where id=target.school_id))),
    'counts',coalesce(to_jsonb(counts),jsonb_build_object('report_id',rid,'review_round',target.community_review_round,'verified',0,'resolved',0,'rejected',0,'flags',0)),
    'own_choice',(select r.choice from private.community_reviews r where report_id=rid and review_round=target.community_review_round and participant_hash=p_participant_hash),
    'can_review',not exists(select 1 from private.community_contributors where report_id=rid and participant_hash=p_participant_hash),
    'changed',changed,'photo_path',(select storage_path from public.hazard_report_photos where report_id=rid));
  -- Never return author identity or legacy private review information.
  return result;
end $$;
revoke all on function private.community_action(text,text,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function private.community_action(text,text,text,jsonb) to service_role;
create function public.community_action(p_action text,p_participant_hash text,p_network_hash text,p_payload jsonb)
returns jsonb language sql security invoker set search_path='' as $$select private.community_action(p_action,p_participant_hash,p_network_hash,p_payload)$$;
revoke all on function public.community_action(text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.community_action(text,text,text,jsonb) to service_role;

-- The legacy staging reset must fail closed if community evidence exists. Empty
-- new child tables do not block the old synthetic fixture workflow. No reset is
-- run here; these records need an extended reviewed backup before any future reset.
alter function private.hazard_reset_preview() rename to hazard_reset_preview_before_community;
create function private.hazard_reset_preview() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare result jsonb:=private.hazard_reset_preview_before_community();unknown jsonb;
begin
  if not exists(select 1 from private.community_contributors) and not exists(select 1 from private.community_reviews)
    and not exists(select 1 from public.community_review_totals) then
    select coalesce(jsonb_agg(x),'[]') into unknown from jsonb_array_elements(result#>'{unsafe_records,unknown_foreign_keys}') x
      where x#>>'{}' not in ('community_contributors_report_id_fkey','community_reviews_report_id_fkey','community_review_totals_report_id_fkey');
    result:=jsonb_set(result,'{unsafe_records,unknown_foreign_keys}',unknown);
  end if;
  return result;
end $$;
revoke all on function private.hazard_reset_preview() from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
