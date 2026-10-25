-- Align the actor minute cap with the unchanged global cap. Provider-wide
-- second, minute and daily budgets and actor daily budget remain unchanged.
create or replace function public.claim_address_request(p_actor_hash text) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare stamp timestamptz:=clock_timestamp(); waits float8;
begin
  if p_actor_hash is null or p_actor_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid address actor'; end if;
  -- One short global lock makes both per-actor and global checks atomic.
  perform pg_catalog.pg_advisory_xact_lock(72688315);
  delete from public.address_proxy_requests where created_at <= stamp-interval '24 hours';
  select max(retry) into waits from (
    select extract(epoch from (min(created_at)+interval '60 seconds'-stamp)) retry
    from public.address_proxy_requests where created_at>stamp-interval '60 seconds' having count(*)>=20
    union all
    select extract(epoch from (min(created_at)+interval '24 hours'-stamp))
    from public.address_proxy_requests having count(*)>=400
    union all
    select extract(epoch from (min(created_at)+interval '60 seconds'-stamp))
    from public.address_proxy_requests where actor_hash=p_actor_hash and created_at>stamp-interval '60 seconds' having count(*)>=20
    union all
    select extract(epoch from (min(created_at)+interval '24 hours'-stamp))
    from public.address_proxy_requests where actor_hash=p_actor_hash having count(*)>=100
    union all
    select extract(epoch from (min(created_at)+interval '1 second'-stamp))
    from public.address_proxy_requests where created_at>stamp-interval '1 second' having count(*)>=2
  ) limits;
  if waits is not null then return jsonb_build_object('granted',false,'retry_after',greatest(1,ceil(waits)::int)); end if;
  insert into public.address_proxy_requests(actor_hash) values(p_actor_hash);
  return jsonb_build_object('granted',true,'retry_after',0);
end $$;
revoke all on function public.claim_address_request(text) from public,anon,authenticated;
grant execute on function public.claim_address_request(text) to service_role;
notify pgrst,'reload schema';
