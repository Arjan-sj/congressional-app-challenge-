-- Local synthetic accounts only. Always rolls back; do not run against live users.
begin;
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) values
 ('91000000-0000-0000-0000-000000000001','one@example.test',now(),'{"username":"  Traveler_One ","moderator_application":true}'),
 ('91000000-0000-0000-0000-000000000002','two@example.test',null,'{}');
do $$ begin
  assert not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.prosecdef and has_function_privilege('authenticated',p.oid,'EXECUTE')
    and p.proname<>'request_moderator_access'),'Private-schema usage must not expose another definer';
  assert (select username from public.user_profiles where user_id='91000000-0000-0000-0000-000000000001')='traveler_one';
  assert (select username from public.user_profiles where user_id='91000000-0000-0000-0000-000000000002') is null;
  assert not exists(select from public.report_moderators where user_id::text like '91000000%');
  assert (select request_status from public.moderator_access_requests where user_id='91000000-0000-0000-0000-000000000001')='pending';
  begin
    insert into auth.users(id,email,raw_user_meta_data) values('91000000-0000-0000-0000-000000000003','dupe@example.test','{"username":"TRAVELER_ONE"}');
    raise exception 'Duplicate accepted';
  exception when unique_violation then null; end;
  begin
    insert into auth.users(id,email,raw_user_meta_data) values('91000000-0000-0000-0000-000000000003','spoof@example.test','{"username":"adminModerator","development_administrator":true,"role":"admin"}');
    raise exception 'Reserved spoof accepted';
  exception when unique_violation then null; end;
  begin
    insert into auth.users(id,email,raw_user_meta_data) values('91000000-0000-0000-0000-000000000003','invalid@example.test','{"username":"bad@name"}');
    raise exception 'Invalid username accepted';
  exception when invalid_parameter_value then null; end;
end $$;
set local role anon;
do $$ begin
  begin perform username from public.user_profiles;raise exception 'Anonymous profile directory';exception when insufficient_privilege then null;end;
  begin perform public.resolve_account_login('traveler_one');raise exception 'Public email resolution';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claim.sub='91000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select count(*) from public.user_profiles)=1;
  assert not public.is_report_moderator();
  update public.user_profiles set username=' New_Name ' where user_id=auth.uid();
  assert (select username from public.user_profiles)='new_name';
  assert not public.is_report_moderator();
  begin update public.user_profiles set requires_password_change=false where user_id=auth.uid();raise exception 'Protected field mutable';exception when insufficient_privilege then null;end;
  begin update public.moderator_access_requests set request_status='approved' where user_id=auth.uid();raise exception 'Self approval';exception when insufficient_privilege then null;end;
  begin perform administrative_note from public.moderator_access_requests;raise exception 'Private review note exposed';exception when insufficient_privilege then null;end;
  begin perform public.admin_moderator_applications('list');raise exception 'User administers applications';exception when insufficient_privilege then null;end;
  begin perform public.resolve_account_login('new_name');raise exception 'Authenticated email directory';exception when insufficient_privilege then null;end;
  begin insert into public.report_moderators(user_id) values(auth.uid());raise exception 'Self moderator grant';exception when insufficient_privilege then null;end;
  assert public.request_moderator_access()->>'request_status'='pending';
end $$;
set local request.jwt.claim.sub='91000000-0000-0000-0000-000000000002';
do $$ begin
  begin perform public.request_moderator_access();raise exception 'Unverified application accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role service_role;
do $$ declare target uuid; result jsonb; begin
  assert public.resolve_account_login('NEW_NAME')='one@example.test';
  assert public.resolve_account_login('unknown_user') is null;
  begin perform id from public.moderator_access_requests;raise exception 'Service bypasses reviewed application RPC';exception when insufficient_privilege then null;end;
end $$;
reset role;
-- Review calls are made with IDs captured as postgres, not by exposing the table.
select set_config('test.application_one',(select id::text from public.moderator_access_requests where user_id='91000000-0000-0000-0000-000000000001'),true);
set local role service_role;
do $$ declare target uuid:=current_setting('test.application_one')::uuid; r jsonb; begin
  r:=public.admin_moderator_applications('approve',target,'one@example.test','Synthetic operator','Reviewed confirmed applicant');
  assert r->>'changed'='true';
  r:=public.admin_moderator_applications('approve',target,'one@example.test','Synthetic operator','Repeat approved request');
  assert r->>'changed'='false';
  perform public.admin_report_moderators('revoke',p_user_id=>'91000000-0000-0000-0000-000000000001',
    p_expected_email=>'one@example.test',p_operator=>'Synthetic operator',p_reason=>'Test immediate revocation');
  r:=public.admin_moderator_applications('approve',target,'one@example.test','Synthetic operator','Retry after revocation');
  assert r->>'changed'='false';
end $$;
reset role;
do $$ begin
  assert (select count(*) from private.moderator_application_history where user_id='91000000-0000-0000-0000-000000000001')=1;
  assert (select count(*) from private.moderator_membership_history where user_id='91000000-0000-0000-0000-000000000001')=2;
  assert not exists(select from public.report_moderators where user_id='91000000-0000-0000-0000-000000000001');
end $$;
insert into public.moderator_access_requests(user_id) values('91000000-0000-0000-0000-000000000002');
select set_config('test.unverified_request',(select id::text from public.moderator_access_requests where user_id='91000000-0000-0000-0000-000000000002'),true);
set local role service_role;
do $$ begin
  begin
    perform public.admin_moderator_applications('approve',current_setting('test.unverified_request')::uuid,'two@example.test','Synthetic operator','Unverified approval must fail');
    raise exception 'Unverified applicant granted privileges';
  exception when check_violation then null;end;
end $$;
reset role;
update auth.users set email_confirmed_at=now() where id='91000000-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claim.sub='91000000-0000-0000-0000-000000000002';
select public.request_moderator_access();
reset role;
select set_config('test.application_two',(select id::text from public.moderator_access_requests where user_id='91000000-0000-0000-0000-000000000002'),true);
set local role service_role;
select public.admin_moderator_applications('decline',current_setting('test.application_two')::uuid,'two@example.test','Synthetic operator','Declined synthetic request');
reset role;
do $$ begin assert not exists(select from public.report_moderators where user_id='91000000-0000-0000-0000-000000000002');end $$;
-- Reserved development identity is permitted only from trusted app metadata.
insert into auth.users(id,email,email_confirmed_at,encrypted_password,raw_user_meta_data,raw_app_meta_data) values
 ('91000000-0000-0000-0000-000000000003','dev@example.test',now(),'synthetic-initial-hash','{"username":"adminModerator"}',
 '{"development_administrator":true,"bootstrap_environment":"local","must_change_password":true}');
set local role service_role;
select public.admin_report_moderators('grant',p_user_id=>'91000000-0000-0000-0000-000000000003',p_expected_email=>'dev@example.test',p_operator=>'Synthetic operator',p_reason=>'Explicit local fixture bootstrap');
select public.bootstrap_account_exists();
reset role;
set local role authenticated;
set local request.jwt.claim.sub='91000000-0000-0000-0000-000000000003';
do $$ begin assert not public.is_report_moderator(),'Initial password must not enable moderator access';end $$;
reset role;
update auth.users set encrypted_password='synthetic-changed-hash' where id='91000000-0000-0000-0000-000000000003';
set local role authenticated;
do $$ begin assert public.is_report_moderator(),'Password change enables previously granted membership';end $$;
reset role;
set local role service_role;
do $$ begin
  for n in 1..10 loop assert public.claim_account_auth_attempt(repeat('a',64),repeat('b',64));end loop;
  assert not public.claim_account_auth_attempt(repeat('a',64),repeat('c',64));
  assert not public.claim_account_auth_attempt(repeat('d',64),repeat('b',64));
end $$;
reset role;
rollback;
