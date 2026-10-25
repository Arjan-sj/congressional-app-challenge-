begin;
set local role anon;
do $$ begin
  begin
    perform public.claim_route_request(repeat('a',64));
    raise exception 'Anonymous client can claim quota';
  exception when insufficient_privilege then null; end;
  begin
    perform count(*) from public.route_proxy_requests;
    raise exception 'Anonymous client can read quota state';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin
    perform public.claim_route_request(repeat('a',64));
    raise exception 'Signed-in client can bypass proxy';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role service_role;
do $$ declare r jsonb; begin
  for n in 1..6 loop
    r:=public.claim_route_request(repeat('a',64));
    assert (r->>'granted')::boolean;
  end loop;
  r:=public.claim_route_request(repeat('a',64));
  assert not (r->>'granted')::boolean;
  assert (r->>'retry_after')::int between 1 and 60;
  assert (select count(*) from public.route_proxy_requests)=6,'Denied requests are not appended';
  update public.route_proxy_requests set created_at=now()-interval '61 seconds';
  r:=public.claim_route_request(repeat('a',64));
  assert (r->>'granted')::boolean,'Minute expiry restores eligibility';
end $$;
reset role;
-- Only this transaction's new quota fixtures, never community data.
delete from public.route_proxy_requests;
set local role service_role;
do $$ declare r jsonb; begin
  for n in 1..20 loop
    r:=public.claim_route_request(md5(n::text)||md5(n::text));
    assert (r->>'granted')::boolean;
  end loop;
  r:=public.claim_route_request(repeat('b',64));
  assert not (r->>'granted')::boolean,'Global sliding minute cap';
end $$;
reset role;
delete from public.route_proxy_requests;
insert into public.route_proxy_requests(actor_hash,created_at)
select repeat('a',64),now()-interval '2 minutes' from generate_series(1,100);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_route_request(repeat('a',64));
  assert not (r->>'granted')::boolean,'Actor rolling day cap';
  assert (r->>'retry_after')::int>60;
end $$;
reset role;
insert into public.route_proxy_requests(actor_hash,created_at)
select repeat('c',64),now()-interval '2 minutes' from generate_series(1,900);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_route_request(repeat('b',64));
  assert not (r->>'granted')::boolean,'Global rolling day cap';
  update public.route_proxy_requests set created_at=now()-interval '25 hours';
  r:=public.claim_route_request(repeat('a',64));
  assert (r->>'granted')::boolean,'Expired quota entries removed';
  assert (select count(*) from public.route_proxy_requests)=1;
end $$;
reset role;
rollback;
