-- Phase 1 operator tooling. Defaults to production (read-only); no resets/seeds
-- or environment enrollment are executed by this migration.
create table private.hazard_test_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check(kind in ('reset','seed')),
  state text not null default 'active' check(state in ('active','complete')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  backup_sha256 text,
  protected_snapshot jsonb not null,
  details jsonb not null default '{}'
);
create table private.hazard_test_control (
  singleton boolean primary key default true check(singleton),
  environment text not null default 'production' check(environment in ('production','staging','local')),
  project_id text not null default 'bnvmlxgdqgwjtxgtsaak',
  active_run uuid references private.hazard_test_runs(id),
  check(environment='production' or project_id <> 'bnvmlxgdqgwjtxgtsaak')
);
insert into private.hazard_test_control default values;
create table private.synthetic_hazard_reports (
  report_id uuid primary key references public.hazard_reports(id) on delete cascade,
  fixture_key text not null unique,
  seed_run uuid not null references private.hazard_test_runs(id)
);
alter table private.hazard_test_runs enable row level security;
alter table private.hazard_test_control enable row level security;
alter table private.synthetic_hazard_reports enable row level security;
revoke all on private.hazard_test_runs, private.hazard_test_control,
  private.synthetic_hazard_reports from public,anon,authenticated,service_role;

-- Preserve every legacy-accepted path while accepting normal file extensions.
-- The old double-escaped dot rejected ordinary `123.png` upload metadata.
alter table public.hazard_report_photos drop constraint hazard_report_photos_path_check;
alter table public.hazard_report_photos add constraint hazard_report_photos_path_check check (
  storage_path ~ ('^'||report_id::text||'/[0-9]+[.](jpg|png|webp)$')
  or storage_path ~ ('^'||report_id::text||'/[0-9]+\\.(jpg|png|webp)$')
);

create function private.assert_hazard_test_project(p_project_id text) returns void
language plpgsql security invoker set search_path='' as $$
begin
  if p_project_id is null or p_project_id='bnvmlxgdqgwjtxgtsaak'
    or not exists(select from private.hazard_test_control c
      where c.project_id=p_project_id and c.environment in ('staging','local')) then
    raise exception 'Reset/seed is restricted to an enrolled non-production project' using errcode='42501';
  end if;
end $$;

create function private.hazard_test_preserved_state() returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare t text; fingerprint jsonb; result jsonb := '{}';
begin
  foreach t in array array['public.schools','public.map_infrastructure','public.map_provider_cache',
    'auth.users','public.report_moderators','supabase_migrations.schema_migrations'] loop
    if to_regclass(t) is null then
      result := result || jsonb_build_object(t,null);
    else
      execute format('select jsonb_build_object(''count'',count(*),''digest'',
        md5(coalesce(string_agg(hash,'''' order by hash),'''')))
        from (select md5(to_jsonb(r)::text) hash from %s r) q',to_regclass(t)) into fingerprint;
      result := result || jsonb_build_object(t,fingerprint);
    end if;
  end loop;
  return result;
end $$;

create function private.hazard_reset_preview() returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'project_id',c.project_id,'environment',c.environment,'active_run',c.active_run,
    'production_protected',c.environment='production' or c.project_id='bnvmlxgdqgwjtxgtsaak',
    'counts',jsonb_build_object(
      'hazard_reports',(select count(*) from public.hazard_reports),
      'demo_reports',(select count(*) from public.hazard_reports where is_demo),
      'registered_synthetic',(select count(*) from private.synthetic_hazard_reports),
      'photo_metadata',(select count(*) from public.hazard_report_photos),
      'storage_objects',(select count(*) from storage.objects where bucket_id='hazard-photos'),
      'report_flags',(select count(*) from public.report_flags),
      'moderation_history',(select count(*) from public.report_moderation_history),
      'correction_records',(select count(*) from private.report_school_corrections)),
    'unsafe_records',jsonb_build_object(
      'non_synthetic_reports',(select coalesce(jsonb_agg(h.id order by h.id),'[]')
        from public.hazard_reports h left join private.synthetic_hazard_reports f on f.report_id=h.id
        where f.report_id is null or not h.is_demo or h.description not like '[SYNTHETIC phase1-v1] %'),
      'orphan_storage_objects',(select coalesce(jsonb_agg(o.name order by o.name),'[]')
        from storage.objects o where o.bucket_id='hazard-photos' and not exists(
          select from public.hazard_report_photos p where p.storage_path=o.name)),
      'orphan_corrections',(select coalesce(jsonb_agg(a.report_id order by a.report_id),'[]')
        from private.report_school_corrections a where not exists(select from public.hazard_reports h where h.id=a.report_id)),
      'unknown_foreign_keys',(select coalesce(jsonb_agg(k.conname order by k.conname),'[]')
        from pg_catalog.pg_constraint k where k.contype='f'
          and k.confrelid in ('public.hazard_reports'::regclass,'public.hazard_report_photos'::regclass,
            'public.report_flags'::regclass,'public.report_moderation_history'::regclass,
            'private.report_school_corrections'::regclass,'private.synthetic_hazard_reports'::regclass)
          and not (k.confrelid='public.hazard_reports'::regclass and k.conrelid in (
            'public.hazard_report_photos'::regclass,'public.report_flags'::regclass,
            'public.report_moderation_history'::regclass,'private.synthetic_hazard_reports'::regclass)))
    )) from private.hazard_test_control c;
$$;

create function private.hazard_test_snapshot() returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'reports',(select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') from public.hazard_reports r),
    'photos',(select coalesce(jsonb_agg(to_jsonb(r) order by r.report_id),'[]') from public.hazard_report_photos r),
    'flags',(select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') from public.report_flags r),
    'history',(select coalesce(jsonb_agg(to_jsonb(r) order by r.id),'[]') from public.report_moderation_history r),
    'corrections',(select coalesce(jsonb_agg(to_jsonb(r) order by r.report_id),'[]') from private.report_school_corrections r),
    'fixtures',(select coalesce(jsonb_agg(to_jsonb(r) order by r.report_id),'[]') from private.synthetic_hazard_reports r),
    'objects',(select coalesce(jsonb_agg(to_jsonb(r) order by r.name),'[]') from storage.objects r where bucket_id='hazard-photos')
  );
$$;

-- A committed maintenance gate survives a failed Storage API request. Resume
-- with the same backed-up run; application writes remain blocked until complete.
create function private.guard_hazard_test_maintenance() returns trigger
language plpgsql security definer set search_path='' as $$
declare run_id uuid; run_kind text; object_name text; object_bucket text;
begin
  select c.active_run,r.kind into run_id,run_kind from private.hazard_test_control c
    left join private.hazard_test_runs r on r.id=c.active_run;
  if run_id is null or current_setting('saferoutes.hazard_test_run',true)=run_id::text then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  if tg_table_schema='storage' then
    if tg_op='DELETE' then object_name:=old.name; object_bucket:=old.bucket_id;
    else object_name:=new.name; object_bucket:=new.bucket_id; end if;
    if object_bucket<>'hazard-photos' and (tg_op<>'UPDATE' or old.bucket_id<>'hazard-photos') then
      if tg_op='DELETE' then return old; else return new; end if;
    end if;
    if (tg_op='DELETE' and run_kind='reset') or
      (run_kind='seed' and (tg_op='INSERT' or
        (tg_op='UPDATE' and old.bucket_id=new.bucket_id and old.name=new.name))) then
      if exists(select from public.hazard_report_photos p
        join private.synthetic_hazard_reports f on f.report_id=p.report_id
        where p.storage_path=object_name and (run_kind='reset' or f.seed_run=run_id)) then
        if tg_op='DELETE' then return old; else return new; end if;
      end if;
    end if;
  end if;
  raise exception 'Staging hazard maintenance is active; retry after it completes' using errcode='55000';
end $$;

do $$ declare t text; begin
  foreach t in array array['public.hazard_reports','public.hazard_report_photos',
    'public.report_flags','public.report_moderation_history','private.report_school_corrections','storage.objects'] loop
    execute format('create trigger hazard_test_maintenance before insert or update or delete on %s
      for each row execute function private.guard_hazard_test_maintenance()',t);
  end loop;
end $$;

create function private.begin_hazard_test_run(p_project_id text,p_kind text) returns uuid
language plpgsql security invoker set search_path='' as $$
declare run_id uuid; existing_kind text; item record;
begin
  perform private.assert_hazard_test_project(p_project_id);
  if p_kind not in ('reset','seed') then raise exception 'Invalid operation'; end if;
  select c.active_run into run_id from private.hazard_test_control c for update;
  if run_id is not null then
    select kind into existing_kind from private.hazard_test_runs where id=run_id;
    if existing_kind<>p_kind then raise exception 'Resume the active % operation first',existing_kind; end if;
  else
    for item in select * from jsonb_each(private.hazard_reset_preview()->'unsafe_records') loop
      if jsonb_array_length(item.value)>0 then raise exception 'Unsafe records: %',item.key; end if;
    end loop;
    insert into private.hazard_test_runs(kind,protected_snapshot)
      values(p_kind,private.hazard_test_preserved_state()) returning id into run_id;
    update private.hazard_test_control set active_run=run_id;
  end if;
  perform set_config('saferoutes.hazard_test_run',run_id::text,false);
  return run_id;
end $$;

create function private.complete_hazard_test_run(p_project_id text,p_run_id uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
  perform private.assert_hazard_test_project(p_project_id);
  if not exists(select from private.hazard_test_control where active_run=p_run_id)
    or current_setting('saferoutes.hazard_test_run',true) is distinct from p_run_id::text then
    raise exception 'Active maintenance session required';
  end if;
  if private.hazard_test_preserved_state() is distinct from
    (select protected_snapshot from private.hazard_test_runs where id=p_run_id) then
    raise exception 'Protected schools/infrastructure/users/moderators/migrations changed';
  end if;
  update private.hazard_test_runs set state='complete',finished_at=now() where id=p_run_id;
  update private.hazard_test_control set active_run=null;
  perform set_config('saferoutes.hazard_test_run','',false);
end $$;

create function private.finish_hazard_test_reset(p_project_id text,p_run_id uuid,p_backup_sha256 text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item record;
begin
  perform private.assert_hazard_test_project(p_project_id);
  if not exists(select from private.hazard_test_control c join private.hazard_test_runs r on r.id=c.active_run
    where r.id=p_run_id and r.kind='reset' and r.state='active'
      and r.backup_sha256=p_backup_sha256 and p_backup_sha256 ~ '^[0-9a-f]{64}$')
    or current_setting('saferoutes.hazard_test_run',true) is distinct from p_run_id::text then
    raise exception 'Verified backup and active reset session required';
  end if;
  for item in select * from jsonb_each(private.hazard_reset_preview()->'unsafe_records') loop
    if jsonb_array_length(item.value)>0 then raise exception 'Unsafe records: %',item.key; end if;
  end loop;
  if exists(select from storage.objects where bucket_id='hazard-photos') then
    raise exception 'Remove all hazard Storage objects through the Storage API first';
  end if;
  delete from private.report_school_corrections a using private.synthetic_hazard_reports f where f.report_id=a.report_id;
  delete from public.hazard_reports h using private.synthetic_hazard_reports f where f.report_id=h.id;
  if exists(select from public.hazard_reports) or exists(select from public.hazard_report_photos)
    or exists(select from public.report_flags) or exists(select from public.report_moderation_history)
    or exists(select from private.report_school_corrections) then raise exception 'Reset verification failed'; end if;
  perform private.complete_hazard_test_run(p_project_id,p_run_id);
  return private.hazard_reset_preview();
end $$;

create function private.seed_hazard_test_reports(p_project_id text,p_run_id uuid,
  p_school_ids text[],p_reporter_id uuid,p_moderator_id uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare i int; report_id uuid; s public.schools; school_id text; seed_args jsonb;
begin
  perform private.assert_hazard_test_project(p_project_id);
  if not exists(select from private.hazard_test_control c join private.hazard_test_runs r on r.id=c.active_run
    where r.id=p_run_id and r.kind='seed') or current_setting('saferoutes.hazard_test_run',true) is distinct from p_run_id::text
    then raise exception 'Active seed session required'; end if;
  if cardinality(p_school_ids)<>2 or p_school_ids[1]=p_school_ids[2]
    or not exists(select from auth.users where id=p_reporter_id)
    or not exists(select from public.report_moderators where user_id=p_moderator_id) then
    raise exception 'Two different canonical schools, an existing test author and moderator are required';
  end if;
  seed_args:=jsonb_build_object('schools',p_school_ids,'reporter',p_reporter_id,'moderator',p_moderator_id);
  if exists(select from private.hazard_test_runs where id=p_run_id and details ? 'seed_args') then
    if (select details->'seed_args' from private.hazard_test_runs where id=p_run_id)<>seed_args then
      raise exception 'Resume with the original seed arguments'; end if;
    return private.hazard_test_snapshot();
  end if;
  if exists(select from public.hazard_reports) then raise exception 'Reset the staging fixtures before reseeding'; end if;
  update private.hazard_test_runs set details=jsonb_build_object('seed_args',seed_args) where id=p_run_id;
  for i in 1..6 loop
    school_id:=case when i in (3,4) then p_school_ids[2] else p_school_ids[1] end;
    select * into strict s from public.schools where id=school_id and canonical_id is null;
    report_id:=('50000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid;
    insert into public.hazard_reports(id,school_id,latitude,longitude,type,severity,description,reporter_id,is_demo)
      values(report_id,s.id,s.latitude,s.longitude,'blocked_path',3,
        '[SYNTHETIC phase1-v1] '||case i when 1 then 'Duplicate concern A' when 2 then 'Duplicate concern A'
        when 3 then 'Pending concern B' when 4 then 'Verified concern B' when 5 then 'Resolved concern A'
        else 'Photo evidence concern A' end,p_reporter_id,true);
    insert into private.synthetic_hazard_reports values(report_id,'phase1-v1/'||i,p_run_id);
  end loop;
  insert into public.hazard_report_photos(report_id,owner_id,storage_path)
    values('50000000-0000-0000-0000-000000000006',p_reporter_id,'50000000-0000-0000-0000-000000000006/1.png');
  insert into public.report_flags(report_id,user_id,reason)
    values('50000000-0000-0000-0000-000000000001',p_reporter_id,'[SYNTHETIC phase1-v1] Moderator test flag');
  perform set_config('request.jwt.claim.sub',p_moderator_id::text,true);
  for i in select unnest(array[1,2,4,5]) loop
    report_id:=('50000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid;
    perform public.moderate_hazard_report(report_id,case when i=5 then 'resolved' else 'verified' end,
      '[SYNTHETIC phase1-v1] Reproducible seed review','unverified');
  end loop;
  return private.hazard_test_snapshot();
end $$;

-- Private operator connection only. No Data API, user or service-role execution.
do $$ declare f record; begin
  for f in select oid::regprocedure signature from pg_proc where pronamespace='private'::regnamespace
    and (proname like '%hazard_test%' or proname='hazard_reset_preview') loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  end loop;
end $$;
