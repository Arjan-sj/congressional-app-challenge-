-- Phase 4: no accounts or memberships are provisioned by this migration.
revoke insert,update,delete,truncate,references,trigger on public.report_moderators from service_role;
create table private.moderator_membership_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  action text not null check(action in ('grant','revoke')),
  operator text not null check(char_length(btrim(operator)) between 3 and 200),
  reason text not null check(char_length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now()
);
create index moderator_membership_history_user_time on private.moderator_membership_history(user_id,created_at desc);
alter table private.moderator_membership_history enable row level security;
revoke all on private.moderator_membership_history from public,anon,authenticated,service_role;

-- Definer access is isolated in private: Auth lookup and atomic membership/audit
-- writes require privileges unavailable to browser accounts, including moderators.
create function private.admin_report_moderators(p_action text,p_user_id uuid,p_email text,p_expected_email text,
  p_operator text,p_reason text,p_after_id uuid,p_limit integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target auth.users; changed integer; result jsonb; member boolean;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise exception 'Trusted service role required' using errcode='42501';
  end if;
  if p_action not in ('lookup','check','list','grant','revoke') or p_action is null then
    raise exception 'Invalid moderator administration action' using errcode='22023'; end if;
  if p_action='list' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.user_id),'[]') into result from (
      select m.user_id,u.email,u.email_confirmed_at is not null as email_confirmed,
        (select max(h.created_at) from private.moderator_membership_history h where h.user_id=m.user_id and h.action='grant') as granted_at
      from public.report_moderators m join auth.users u on u.id=m.user_id
      where p_after_id is null or m.user_id>p_after_id order by m.user_id
      limit least(greatest(coalesce(p_limit,50),1),100)
    ) x;
    return jsonb_build_object('items',result);
  end if;
  if p_user_id is null and (p_action<>'lookup' or nullif(btrim(p_email),'') is null) then
    raise exception 'An exact Auth user UUID is required' using errcode='22023'; end if;
  if p_email is not null and char_length(p_email)>320 then raise exception 'Invalid email' using errcode='22023'; end if;
  if p_user_id is not null then select * into target from auth.users where id=p_user_id;
  else
    if (select count(*) from auth.users where lower(email)=lower(btrim(p_email)) and deleted_at is null)>1 then
      raise exception 'Ambiguous email; use an exact Auth user UUID' using errcode='22023'; end if;
    select * into target from auth.users where lower(email)=lower(btrim(p_email)) and deleted_at is null;
  end if;
  if target.id is null then
    if p_action in ('lookup','check') then return jsonb_build_object('user',null,'is_moderator',false); end if;
    raise exception 'Auth user does not exist' using errcode='23503';
  end if;
  if p_email is not null and lower(target.email) is distinct from lower(btrim(p_email)) then
    raise exception 'Auth UUID and email do not match' using errcode='22023'; end if;
  if p_action in ('grant','revoke') then
    -- Keep confirmation and account activity checks valid through this change.
    select * into target from auth.users where id=target.id for share;
    if not found then raise exception 'Auth user no longer exists' using errcode='23503'; end if;
    if nullif(btrim(p_expected_email),'') is null or lower(coalesce(target.email,'[no-email]')) is distinct from lower(btrim(p_expected_email)) then
      raise exception 'Confirm the exact email returned by Auth lookup' using errcode='22023'; end if;
    if p_operator is null or char_length(btrim(p_operator)) not between 3 and 200 or p_reason is null or char_length(btrim(p_reason)) not between 5 and 500 then
      raise exception 'Administrative operator and decision reason required' using errcode='22023'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('saferoutes:moderator:'||target.id::text,0));
    if p_action='grant' then
      if target.email_confirmed_at is null or target.deleted_at is not null or target.banned_until>now() then
        raise exception 'Grant requires a confirmed, active Auth account' using errcode='23514'; end if;
      insert into public.report_moderators(user_id) values(target.id) on conflict do nothing;
    else delete from public.report_moderators where user_id=target.id;
    end if;
    get diagnostics changed=row_count;
    if changed>0 then insert into private.moderator_membership_history(user_id,action,operator,reason)
      values(target.id,p_action,btrim(p_operator),btrim(p_reason)); end if;
  end if;
  select exists(select from public.report_moderators where user_id=target.id) into member;
  return jsonb_build_object('user',jsonb_build_object('id',target.id,'email',target.email,
    'email_confirmed',target.email_confirmed_at is not null,'banned_until',target.banned_until,'deleted',target.deleted_at is not null),
    'is_moderator',member,'changed',coalesce(changed,0)>0);
end $$;
revoke all on function private.admin_report_moderators(text,uuid,text,text,text,text,uuid,integer) from public,anon,authenticated;
grant usage on schema private to service_role;
grant execute on function private.admin_report_moderators(text,uuid,text,text,text,text,uuid,integer) to service_role;

create function public.admin_report_moderators(p_action text,p_user_id uuid default null,p_email text default null,
  p_expected_email text default null,p_operator text default null,p_reason text default null,
  p_after_id uuid default null,p_limit integer default 50) returns jsonb
language sql security invoker set search_path='' as $$
  select private.admin_report_moderators(p_action,p_user_id,p_email,p_expected_email,p_operator,p_reason,p_after_id,p_limit)
$$;
revoke all on function public.admin_report_moderators(text,uuid,text,text,text,text,uuid,integer) from public,anon,authenticated;
grant execute on function public.admin_report_moderators(text,uuid,text,text,text,text,uuid,integer) to service_role;

-- Serialize a moderation decision with membership revocation. Once revocation
-- commits, a new action using the same old access token cannot pass this check.
create or replace function public.moderate_hazard_report(
  p_report_id uuid,p_status text,p_reason text,p_expected_status text
) returns setof public.hazard_reports language plpgsql security invoker set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Moderator access required' using errcode='42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('saferoutes:moderator:'||auth.uid()::text,0));
  if not public.is_report_moderator() then raise exception 'Moderator access required' using errcode='42501'; end if;
  perform set_config('saferoutes.moderation_reason',btrim(p_reason),true);
  return query update public.hazard_reports set status=p_status
    where id=p_report_id and status=p_expected_status returning *;
  if not found then raise exception 'Report changed or is unavailable. Refresh before reviewing again.'; end if;
end $$;

create index report_flags_open_queue_idx on public.report_flags(report_id) where reviewed_at is null;
create index hazard_reports_moderation_queue_idx on public.hazard_reports(status,severity desc,created_at,id) where not is_demo;

create function public.get_moderation_queue(p_queue text default 'pending',p_school_id text default null,
  p_district_id text default null,p_order text default 'priority',p_limit integer default 25,p_offset integer default 0)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; page_size integer:=least(greatest(coalesce(p_limit,25),1),100); page_offset integer:=greatest(coalesce(p_offset,0),0);
begin
  if auth.uid() is null or not public.is_report_moderator() then raise exception 'Moderator access required' using errcode='42501'; end if;
  if p_queue not in ('pending','flagged','verified','resolved','rejected','all') or p_order not in ('priority','oldest','newest') or p_queue is null or p_order is null then
    raise exception 'Invalid queue or ordering' using errcode='22023'; end if;
  with scoped as materialized (
    select h.*,s.id as canonical_school_id,s.name as school_name,s.city,s.state,s.district_id,
      coalesce(d.name,s.district,'Unassigned/Independent') as district_name,
      (select count(*) from public.report_flags f where f.report_id=h.id and f.reviewed_at is null) as open_flags
    from public.hazard_reports h join public.schools original on original.id=h.school_id
      join public.schools s on s.id=coalesce(original.canonical_id,original.id)
      left join public.school_districts d on d.id=s.district_id
    where not h.is_demo and (p_school_id is null or s.id=(select coalesce(a.canonical_id,a.id) from public.schools a where a.id=p_school_id))
      and (p_district_id is null or s.district_id=p_district_id or p_district_id='unassigned' and s.district_id is null)
  ), selected as materialized (
    select * from scoped where p_queue='all' or p_queue='flagged' and open_flags>0 or status=case when p_queue='pending' then 'unverified' else p_queue end
  ), page as (
    select * from selected order by
      case when p_order='priority' then severity end desc,
      case when p_order='priority' then open_flags end desc,
      case when p_order in ('priority','oldest') then created_at end asc,
      case when p_order='newest' then created_at end desc,id
    limit page_size offset page_offset
  ), rows as (
    select jsonb_build_object('report',jsonb_build_object('id',p.id,'school_id',p.school_id,'school',jsonb_build_object('name',p.school_name),
      'type',p.type,'severity',p.severity,'description',p.description,'status',p.status,'reporter_id',p.reporter_id,
      'latitude',p.latitude,'longitude',p.longitude,'created_at',p.created_at,'is_demo',p.is_demo),
      'canonical_school_id',p.canonical_school_id,'school_city',p.city,'school_state',p.state,'district_id',p.district_id,
      'district_name',p.district_name,'open_flags',p.open_flags) as value,
      row_number() over () as ordinal from page p
  ) select jsonb_build_object('items',coalesce((select jsonb_agg(value order by ordinal) from rows),'[]'),
    'counts',(select jsonb_build_object('pending',count(*) filter(where status='unverified'),
      'flagged',count(*) filter(where open_flags>0),'verified',count(*) filter(where status='verified'),
      'resolved',count(*) filter(where status='resolved'),'rejected',count(*) filter(where status='rejected'),'all',count(*)) from scoped),
    'total',(select count(*) from selected),'offset',page_offset,'limit',page_size,
    'has_more',page_offset+page_size<(select count(*) from selected)) into result;
  return result;
end $$;
revoke all on function public.get_moderation_queue(text,text,text,text,integer,integer) from public,anon;
grant execute on function public.get_moderation_queue(text,text,text,text,integer,integer) to authenticated;

create function public.search_moderation_scopes(p_kind text,p_query text default '',p_district_id text default null,
  p_after_id text default '',p_limit integer default 50) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_report_moderator() then raise exception 'Moderator access required' using errcode='42501'; end if;
  if p_kind not in ('school','district') or p_kind is null or char_length(coalesce(p_query,''))>120 then
    raise exception 'Invalid search scope or query' using errcode='22023'; end if;
  with directory as (
    select s.id,s.name,s.state,coalesce(s.city,'') as city,s.district_id,coalesce(d.name,s.district,'Unassigned/Independent') as district_name
    from public.schools s left join public.school_districts d on d.id=s.district_id
    where p_kind='school' and s.canonical_id is null
      and (p_district_id is null or s.district_id=p_district_id or p_district_id='unassigned' and s.district_id is null)
    union all select d.id,d.name,d.state,''::text,d.id,d.name from public.school_districts d where p_kind='district'
    union all select 'unassigned','Unassigned/Independent Schools','', '',null,'Unassigned/Independent' where p_kind='district'
  ), page_plus as materialized (
    select * from directory where id>coalesce(p_after_id,'') and (coalesce(p_query,'')='' or name ilike '%'||p_query||'%'
      or city ilike '%'||p_query||'%' or state ilike '%'||p_query||'%' or id ilike '%'||p_query||'%')
    order by id limit least(greatest(coalesce(p_limit,50),1),100)+1
  ), page as (
    select * from page_plus order by id limit least(greatest(coalesce(p_limit,50),1),100)
  ) select jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(p) order by id) from page p),'[]'),
    'has_more',(select count(*) from page_plus)>(select count(*) from page),
    'next_cursor',(select id from page order by id desc limit 1)) into result;
  return result;
end $$;
revoke all on function public.search_moderation_scopes(text,text,text,text,integer) from public,anon;
grant execute on function public.search_moderation_scopes(text,text,text,text,integer) to authenticated;
