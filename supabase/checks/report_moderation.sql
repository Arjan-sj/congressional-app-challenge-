-- Run with psql -v ON_ERROR_STOP=1 -f supabase/checks/report_moderation.sql
-- against a disposable Supabase database with migrations applied. All fixtures
-- and assertions are rolled back. Requires an administrative database connection.
begin;

create function pg_temp.assert_true(value boolean, message text) returns void
language plpgsql as $$
begin
  if value is distinct from true then raise exception 'FAILED: %', message; end if;
end;
$$;
create function pg_temp.expect_error(statement text, expected_state text) returns void
language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlstate = expected_state then return; end if;
    raise exception 'Expected %, got %: %', expected_state, sqlstate, sqlerrm;
  end;
  raise exception 'Statement unexpectedly succeeded: %', statement;
end;
$$;

insert into auth.users(id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-000000000003');
insert into public.report_moderators(user_id)
  values ('10000000-0000-0000-0000-000000000003');
insert into public.hazard_reports
  (id, school_id, latitude, longitude, type, severity, description, reporter_id, status)
values
  ('20000000-0000-0000-0000-000000000001', 'sample-school', 42, -88, 'blocked_path', 3,
   'Test own pending report', '10000000-0000-0000-0000-000000000001', 'unverified'),
  ('20000000-0000-0000-0000-000000000002', 'sample-school', 42, -88, 'blocked_path', 3,
   'Test another pending report', '10000000-0000-0000-0000-000000000002', 'unverified');

set local role anon;
select pg_temp.assert_true((select count(*) = 0 from public.hazard_reports
  where id in ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')),
  'Visitors cannot read unreviewed reports');
select pg_temp.expect_error('select * from public.report_flags', '42501');
select pg_temp.expect_error('select * from public.report_moderation_history', '42501');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', 'Forged approval', 'unverified')$q$, '42501');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select pg_temp.assert_true(not public.is_report_moderator(), 'Ordinary users are not moderators');
select pg_temp.assert_true((select count(*) = 1 from public.hazard_reports
  where id in ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')),
  'Authors see only their own pending reports');
select pg_temp.expect_error($q$insert into public.report_moderators values
  ('10000000-0000-0000-0000-000000000001')$q$, '42501');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', 'Forged approval', 'unverified')$q$, '42501');
update public.hazard_reports set status = 'verified'
  where id = '20000000-0000-0000-0000-000000000001';
select pg_temp.assert_true((select status = 'unverified' from public.hazard_reports
  where id = '20000000-0000-0000-0000-000000000001'), 'Direct status update blocked by RLS');
select pg_temp.expect_error($q$insert into public.report_flags(report_id, user_id, reason) values (
  '20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Hidden report flag')$q$, '42501');
select pg_temp.expect_error($q$insert into public.report_flags(report_id, user_id, reason) values (
  '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'Spoofed author flag')$q$, '42501');
select pg_temp.expect_error($q$insert into public.report_flags(report_id, user_id, reason, reviewed_at) values (
  '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Forged reviewed flag', now())$q$, '42501');
insert into public.report_flags(report_id, user_id, reason) values (
  '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'The example description is inaccurate');
select pg_temp.expect_error($q$insert into public.report_flags(report_id, user_id, reason) values (
  '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Duplicate flag attempt')$q$, '23505');
select pg_temp.expect_error('update public.report_flags set reviewed_at = now()', '42501');
select pg_temp.expect_error('delete from public.report_flags', '42501');
select pg_temp.expect_error('insert into public.report_moderation_history default values', '42501');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select pg_temp.assert_true((select count(*) = 0 from public.report_flags), 'Flags are private to flaggers and moderators');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select pg_temp.assert_true(public.is_report_moderator(), 'Provisioned moderator recognized');
select pg_temp.assert_true((select count(*) = 2 from public.hazard_reports
  where id in ('20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')),
  'Moderators see other authors pending reports');
select pg_temp.assert_true((select count(*) = 1 from public.report_flags
  where report_id = '20000000-0000-0000-0000-000000000001'), 'Moderator sees accuracy flags');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', '   ', 'unverified')$q$, 'P0001');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'unverified', 'Invalid review outcome', 'unverified')$q$, 'P0001');
select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', 'Checked example location details', 'unverified');
select pg_temp.assert_true((select count(*) = 1 from public.report_moderation_history
  where report_id = '20000000-0000-0000-0000-000000000001'
    and actor_id = '10000000-0000-0000-0000-000000000003' and previous_status = 'unverified'
    and status = 'verified' and reason = 'Checked example location details'), 'Decision audit records actor, reason and statuses');
select pg_temp.assert_true((select reviewed_at is not null
  and reviewed_by = '10000000-0000-0000-0000-000000000003' from public.report_flags
  where report_id = '20000000-0000-0000-0000-000000000001'), 'Decision closes existing flags atomically');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'rejected', 'Stale review attempt', 'unverified')$q$, 'P0001');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', 'Redundant approval', 'verified')$q$, 'P0001');
select pg_temp.expect_error('update public.hazard_reports set description = ''Forged edit''', '42501');
select pg_temp.expect_error('delete from public.report_moderation_history', '42501');
select pg_temp.expect_error('update public.report_moderation_history set reason = ''Forged history''', '42501');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select pg_temp.assert_true((select count(*) = 1 from public.report_moderation_history
  where report_id = '20000000-0000-0000-0000-000000000001'), 'Report author can inspect decision history');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select pg_temp.assert_true((select count(*) = 0 from public.report_moderation_history
  where report_id = '20000000-0000-0000-0000-000000000001'), 'Other users cannot read private decision notes');
insert into public.report_flags(report_id, user_id, reason) values (
  '20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'New accuracy concern on verified report');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'verified', 'Reviewed the new flag and confirmed details', 'verified');
select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'rejected', 'Rejected after further checking', 'verified');
select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000001', 'resolved', 'Issue is now resolved', 'rejected');
select pg_temp.assert_true((select count(*) = 4 from public.report_moderation_history
  where report_id = '20000000-0000-0000-0000-000000000001'), 'All four reviews remain in history');
select pg_temp.assert_true((select count(*) = 0 from public.report_flags
  where report_id = '20000000-0000-0000-0000-000000000001' and reviewed_at is null), 'New flag was acknowledged');
select set_config('saferoutes.moderation_reason', '', true);
select pg_temp.expect_error($q$update public.hazard_reports set status = 'verified'
  where id = '20000000-0000-0000-0000-000000000002'$q$, 'P0001');

reset role;
delete from public.report_moderators where user_id = '10000000-0000-0000-0000-000000000003';
set local role authenticated;
select pg_temp.assert_true(not public.is_report_moderator(), 'Revoking membership takes effect immediately');
select pg_temp.expect_error($q$select * from public.moderate_hazard_report(
  '20000000-0000-0000-0000-000000000002', 'verified', 'Revoked moderator attempt', 'unverified')$q$, '42501');
reset role;
rollback;
