begin;
set local role anon;
do $$ begin
  begin perform public.claim_address_request(repeat('a',64));
    raise exception 'Anonymous client bypassed proxy';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from public.address_proxy_requests;
    raise exception 'Anonymous client read quota state';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform public.claim_address_request(repeat('a',64));
    raise exception 'Authenticated client bypassed proxy';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('a',64)); assert (r->>'granted')::boolean;
  r:=public.claim_address_request(repeat('b',64)); assert (r->>'granted')::boolean;
  r:=public.claim_address_request(repeat('c',64)); assert not (r->>'granted')::boolean,'Burst cap';
  assert (select count(*) from public.address_proxy_requests)=2,'Denied requests consume no quota';
end $$;
reset role;
delete from public.address_proxy_requests;
insert into public.address_proxy_requests(actor_hash,created_at)
select repeat('a',64),clock_timestamp()-interval '2 seconds' from generate_series(1,10);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('a',64));
  assert (r->>'granted')::boolean,'Autocomplete can continue after ten requests within the unchanged global cap';
end $$;
reset role;
delete from public.address_proxy_requests;
insert into public.address_proxy_requests(actor_hash,created_at)
select repeat('a',64),clock_timestamp()-interval '2 seconds' from generate_series(1,20);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('a',64)); assert not (r->>'granted')::boolean,'Actor minute cap';
end $$;
reset role;
insert into public.address_proxy_requests(actor_hash,created_at)
select repeat('b',64),clock_timestamp()-interval '2 seconds' from generate_series(1,20);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('c',64)); assert not (r->>'granted')::boolean,'Global minute cap';
end $$;
reset role;
delete from public.address_proxy_requests;
insert into public.address_proxy_requests(actor_hash,created_at)
select repeat('a',64),clock_timestamp()-interval '2 minutes' from generate_series(1,100);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('a',64)); assert not (r->>'granted')::boolean,'Actor daily cap';
end $$;
reset role;
insert into public.address_proxy_requests(actor_hash,created_at)
select repeat('b',64),clock_timestamp()-interval '2 minutes' from generate_series(1,300);
set local role service_role;
do $$ declare r jsonb; begin
  r:=public.claim_address_request(repeat('c',64)); assert not (r->>'granted')::boolean,'Global daily cap';
  update public.address_proxy_requests set created_at=clock_timestamp()-interval '25 hours';
  r:=public.claim_address_request(repeat('a',64)); assert (r->>'granted')::boolean,'Window expiry';
end $$;
reset role;
rollback;
