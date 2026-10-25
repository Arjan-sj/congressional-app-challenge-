-- Phase 9: additive account data. No Auth identity or moderator membership is provisioned.
create table public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text,
  requires_password_change boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (username is null or (username=lower(username) and username ~ '^[a-z][a-z0-9_]{2,23}$'))
);
create unique index user_profiles_username_ci on public.user_profiles(lower(username)) where username is not null;
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from public,anon,authenticated;
grant select on public.user_profiles to authenticated;
grant update(username) on public.user_profiles to authenticated;
grant all on public.user_profiles to service_role;
create policy "Read own profile" on public.user_profiles for select to authenticated using(user_id=(select auth.uid()));
create policy "Change own username" on public.user_profiles for update to authenticated
  using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

create table public.moderator_access_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  request_status text not null default 'pending' check(request_status in ('pending','approved','declined')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text,
  administrative_note text,
  check ((request_status='pending' and reviewed_at is null and reviewed_by is null)
    or (request_status<>'pending' and reviewed_at is not null and reviewed_by is not null))
);
create index moderator_requests_status_time on public.moderator_access_requests(request_status,created_at,id);
alter table public.moderator_access_requests enable row level security;
revoke all on public.moderator_access_requests from public,anon,authenticated,service_role;
grant select(id,user_id,request_status,created_at,reviewed_at) on public.moderator_access_requests to authenticated;
create policy "Read own application" on public.moderator_access_requests for select to authenticated using(user_id=(select auth.uid()));

create table private.moderator_application_history (
  id uuid primary key default gen_random_uuid(), request_id uuid not null,
  user_id uuid not null, decision text not null check(decision in ('approved','declined')),
  operator text not null, reason text not null, created_at timestamptz not null default now()
);
alter table private.moderator_application_history enable row level security;
revoke all on private.moderator_application_history from public,anon,authenticated,service_role;

-- Triggers need Auth access, isolated in private with fixed search paths. Metadata
-- may request a username/application; it can NEVER grant membership or approval.
create function private.normalize_profile() returns trigger language plpgsql security definer set search_path='' as $$
declare boot boolean;
begin
  new.username:=nullif(lower(btrim(new.username)),'');
  if new.username is not null then
    if new.username !~ '^[a-z][a-z0-9_]{2,23}$' then raise exception 'Invalid username' using errcode='22023'; end if;
    if new.username in ('admin','administrator','adminmoderator','moderator','root','system','support','security','saferoutes') then
      select coalesce(raw_app_meta_data->>'development_administrator','false')='true'
        and raw_app_meta_data->>'bootstrap_environment' in ('local','staging') into boot from auth.users where id=new.user_id;
      if new.username<>'adminmoderator' or not coalesce(boot,false) then
        raise exception 'Username unavailable' using errcode='23505'; end if;
    end if;
  end if;
  new.updated_at:=now(); return new;
end $$;
revoke all on function private.normalize_profile() from public,anon,authenticated,service_role;
create trigger normalize_user_profile before insert or update on public.user_profiles for each row execute function private.normalize_profile();

create function private.initialize_account() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.user_profiles(user_id,username,requires_password_change)
  values(new.id,new.raw_user_meta_data->>'username',
    coalesce(new.raw_app_meta_data->>'must_change_password','false')='true');
  if new.raw_user_meta_data->>'moderator_application'='true' then
    insert into public.moderator_access_requests(user_id) values(new.id) on conflict(user_id) do nothing;
  end if;
  return new;
end $$;
revoke all on function private.initialize_account() from public,anon,authenticated,service_role;
create trigger initialize_saferoutes_account after insert on auth.users for each row execute function private.initialize_account();
-- Existing identities and ownership remain unchanged; no username is inferred.
insert into public.user_profiles(user_id) select id from auth.users on conflict do nothing;

create function private.account_password_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.encrypted_password is distinct from new.encrypted_password then
    update public.user_profiles set requires_password_change=false where user_id=new.id and requires_password_change;
    new.raw_app_meta_data:=coalesce(new.raw_app_meta_data,'{}'::jsonb)-'must_change_password';
  end if;
  return new;
end $$;
revoke all on function private.account_password_changed() from public,anon,authenticated,service_role;
create trigger clear_account_password_requirement before update of encrypted_password on auth.users
  for each row execute function private.account_password_changed();

create or replace function public.is_report_moderator() returns boolean
language sql stable security invoker set search_path='' as $$
  select auth.uid() is not null and exists(select 1 from public.report_moderators where user_id=auth.uid())
    and not exists(select 1 from public.user_profiles where user_id=auth.uid() and requires_password_change);
$$;

create function private.request_moderator_access() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if auth.uid() is null or not exists(select 1 from auth.users where id=auth.uid()
      and email_confirmed_at is not null and deleted_at is null and (banned_until is null or banned_until<=now())) then
    raise exception 'Verified account required' using errcode='42501'; end if;
  insert into public.moderator_access_requests(user_id) values(auth.uid()) on conflict(user_id) do nothing;
  select jsonb_build_object('id',id,'request_status',request_status,'created_at',created_at,'reviewed_at',reviewed_at)
    into result from public.moderator_access_requests where user_id=auth.uid();
  return result;
end $$;
revoke all on function private.request_moderator_access() from public,anon,authenticated,service_role;
-- Public invoker wrapper reaches only this self-scoped private function.
grant usage on schema private to authenticated;
grant execute on function private.request_moderator_access() to authenticated;
create function public.request_moderator_access() returns jsonb language sql security invoker set search_path='' as $$
  select private.request_moderator_access();
$$;
revoke all on function public.request_moderator_access() from public,anon;
grant execute on function public.request_moderator_access() to authenticated;

create function private.admin_moderator_applications(p_action text,p_request_id uuid,p_expected_email text,p_operator text,p_reason text,p_limit int)
returns jsonb language plpgsql security definer set search_path='' as $$
declare target public.moderator_access_requests; identity_result jsonb; result jsonb; decision text;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise exception 'Trusted service role required' using errcode='42501'; end if;
  if p_action='list' then
    select coalesce(jsonb_agg(to_jsonb(r)),'[]') into result from (
      select id,user_id,request_status,created_at,reviewed_at,reviewed_by,administrative_note
      from public.moderator_access_requests where request_status='pending' order by created_at,id limit least(greatest(coalesce(p_limit,50),1),100)
    ) r; return jsonb_build_object('items',result);
  end if;
  if p_action is null or p_action not in ('check','approve','decline') then raise exception 'Invalid application action'; end if;
  select * into target from public.moderator_access_requests where id=p_request_id for update;
  if not found then raise exception 'Application unavailable'; end if;
  identity_result:=public.admin_report_moderators('check',p_user_id=>target.user_id);
  if p_action='check' then return jsonb_build_object('application',to_jsonb(target),'identity',identity_result); end if;
  if p_operator is null or char_length(btrim(p_operator)) not between 3 and 200 or p_reason is null
    or char_length(btrim(p_reason)) not between 5 and 500 then raise exception 'Operator and review reason required'; end if;
  if nullif(btrim(p_expected_email),'') is null or lower(identity_result->'user'->>'email') is distinct from lower(btrim(p_expected_email))
    then raise exception 'Confirm the verified Auth email'; end if;
  -- Idempotent reviewed requests never re-grant a subsequently revoked membership.
  if target.request_status<>'pending' then return jsonb_build_object('application',to_jsonb(target),'changed',false); end if;
  decision:=case when p_action='approve' then 'approved' else 'declined' end;
  if decision='approved' then
    perform public.admin_report_moderators('grant',p_user_id=>target.user_id,p_expected_email=>p_expected_email,
      p_operator=>p_operator,p_reason=>'Moderator application: '||left(p_reason,470));
  end if;
  update public.moderator_access_requests set request_status=decision,reviewed_at=now(),reviewed_by=btrim(p_operator),
    administrative_note=btrim(p_reason) where id=target.id returning * into target;
  insert into private.moderator_application_history(request_id,user_id,decision,operator,reason)
    values(target.id,target.user_id,decision,btrim(p_operator),btrim(p_reason));
  return jsonb_build_object('application',to_jsonb(target),'changed',true);
end $$;
revoke all on function private.admin_moderator_applications(text,uuid,text,text,text,int) from public,anon,authenticated;
grant execute on function private.admin_moderator_applications(text,uuid,text,text,text,int) to service_role;
create function public.admin_moderator_applications(p_action text,p_request_id uuid default null,p_expected_email text default null,
  p_operator text default null,p_reason text default null,p_limit int default 50) returns jsonb language sql security invoker set search_path='' as $$
  select private.admin_moderator_applications(p_action,p_request_id,p_expected_email,p_operator,p_reason,p_limit);
$$;
revoke all on function public.admin_moderator_applications(text,uuid,text,text,text,int) from public,anon,authenticated;
grant execute on function public.admin_moderator_applications(text,uuid,text,text,text,int) to service_role;

create function private.resolve_account_login(p_username text) returns text language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true) is distinct from 'service_role' then raise exception 'Trusted service role required' using errcode='42501'; end if;
  return (select u.email from public.user_profiles p join auth.users u on u.id=p.user_id
    where lower(p.username)=lower(btrim(p_username)) and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now()));
end $$;
revoke all on function private.resolve_account_login(text) from public,anon,authenticated;
grant execute on function private.resolve_account_login(text) to service_role;
create function public.resolve_account_login(p_username text) returns text language sql stable security invoker set search_path='' as $$
  select private.resolve_account_login(p_username);
$$;
revoke all on function public.resolve_account_login(text) from public,anon,authenticated;
grant execute on function public.resolve_account_login(text) to service_role;

create table public.account_auth_attempts (
  id bigint generated always as identity primary key, actor_hash text not null, identifier_hash text not null,
  created_at timestamptz not null default clock_timestamp()
);
create index account_auth_actor_recent on public.account_auth_attempts(actor_hash,created_at);
create index account_auth_identifier_recent on public.account_auth_attempts(identifier_hash,created_at);
create index account_auth_created on public.account_auth_attempts(created_at);
alter table public.account_auth_attempts enable row level security;
create policy "Service manages authentication quota" on public.account_auth_attempts for all to service_role using(true) with check(true);
revoke all on public.account_auth_attempts from public,anon,authenticated;
grant all on public.account_auth_attempts to service_role;
grant usage,select on sequence public.account_auth_attempts_id_seq to service_role;
create function public.claim_account_auth_attempt(p_actor_hash text,p_identifier_hash text) returns boolean
language plpgsql security invoker set search_path='' as $$
declare stamp timestamptz:=clock_timestamp();
begin
  if p_actor_hash !~ '^[0-9a-f]{64}$' or p_identifier_hash !~ '^[0-9a-f]{64}$' or p_actor_hash is null or p_identifier_hash is null
    then raise exception 'Invalid authentication quota'; end if;
  perform pg_catalog.pg_advisory_xact_lock(72688315);
  delete from public.account_auth_attempts where created_at<=stamp-interval '1 hour';
  if (select count(*) from public.account_auth_attempts where created_at>stamp-interval '1 minute')>=120
    or (select count(*) from public.account_auth_attempts where actor_hash=p_actor_hash and created_at>stamp-interval '1 minute')>=10
    or (select count(*) from public.account_auth_attempts where identifier_hash=p_identifier_hash and created_at>stamp-interval '15 minutes')>=10
    or (select count(*) from public.account_auth_attempts where actor_hash=p_actor_hash)>=100 then return false; end if;
  insert into public.account_auth_attempts(actor_hash,identifier_hash) values(p_actor_hash,p_identifier_hash); return true;
end $$;
revoke all on function public.claim_account_auth_attempt(text,text) from public,anon,authenticated;
grant execute on function public.claim_account_auth_attempt(text,text) to service_role;

create function private.bootstrap_account_exists() returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  if current_setting('role',true) is distinct from 'service_role' then raise exception 'Trusted service role required' using errcode='42501'; end if;
  return exists(select 1 from public.user_profiles where username='adminmoderator') or
    exists(select 1 from auth.users where raw_app_meta_data->>'development_administrator'='true');
end $$;
revoke all on function private.bootstrap_account_exists() from public,anon,authenticated;
grant execute on function private.bootstrap_account_exists() to service_role;
create function public.bootstrap_account_exists() returns boolean language sql stable security invoker set search_path='' as $$select private.bootstrap_account_exists()$$;
revoke all on function public.bootstrap_account_exists() from public,anon,authenticated;
grant execute on function public.bootstrap_account_exists() to service_role;
-- Account/application records are preserved by the existing staging hazard workflow.
create or replace function private.hazard_test_preserved_state() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare t text; fingerprint jsonb; result jsonb:='{}';
begin
  foreach t in array array['public.schools','public.school_districts','public.school_district_sources',
    'public.map_infrastructure','public.map_provider_cache','auth.users','public.report_moderators',
    'public.user_profiles','public.moderator_access_requests','private.moderator_application_history',
    'supabase_migrations.schema_migrations'] loop
    if to_regclass(t) is null then result:=result||jsonb_build_object(t,null);
    else
      execute format('select jsonb_build_object(''count'',count(*),''digest'',md5(coalesce(string_agg(hash,'''' order by hash),'''')))
        from (select md5(to_jsonb(r)::text) hash from %s r) q',to_regclass(t)) into fingerprint;
      result:=result||jsonb_build_object(t,fingerprint);
    end if;
  end loop;
  return result;
end $$;
notify pgrst,'reload schema';
