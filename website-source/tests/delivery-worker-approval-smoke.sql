\set ON_ERROR_STOP on

-- Disposable PostgreSQL fixture. This intentionally models only the schema
-- needed by the delivery-worker migrations; it is never connected to Supabase.
create schema auth;
create role anon nologin;
create role authenticated nologin;

create function auth.uid()
returns uuid language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create function auth.jwt()
returns jsonb language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;

create table public.mp_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid,
  full_name text,
  phone text,
  preferred_language text,
  role text,
  updated_at timestamptz not null default now()
);
create unique index mp_users_auth_user_id_unique
  on public.mp_users(auth_user_id) where auth_user_id is not null;

create table public.mp_delivery_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.mp_users(id),
  full_name text not null,
  phone text not null,
  service_area text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.mp_orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null,
  fulfillment_method text not null,
  status text not null,
  subtotal_etb numeric not null default 0,
  delivery_address text,
  customer_phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.mp_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.mp_orders(id),
  product_name text not null,
  quantity integer not null
);
create table public.mp_payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.mp_orders(id),
  status text not null
);
create table public.mp_delivery_assignments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.mp_orders(id),
  delivery_user_id uuid references public.mp_users(id),
  provider_name text not null,
  provider_phone text not null,
  fee_etb numeric not null default 0,
  status text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Seed an old active profile to prove the migration disables self-approved
-- worker profiles, then seed the administrator account.
insert into public.mp_users(id,auth_user_id,full_name,phone,preferred_language,role)
values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Old Worker','0911000001','en','customer'),
 ('10000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','Admin','0911000002','en','admin');
insert into public.mp_delivery_profiles(user_id,full_name,phone,service_area,active)
values ('10000000-0000-0000-0000-000000000001','Old Worker','0911000001','Test Area',true);

\ir ../patches/2026-11-26-delivery-worker-atomic-transition.sql
\ir ../patches/2026-11-27-delivery-worker-admin-approval.sql

do $test$
declare
  v_worker_id uuid;
  v_profile_id uuid;
  v_result jsonb;
  v_jobs jsonb;
  v_order_id uuid;
  v_unpaid_order_id uuid;
  v_assignment_id uuid;
  v_failed boolean;
begin
  if exists(select 1 from public.mp_delivery_profiles where active) then
    raise exception 'Migration did not deactivate the pre-existing active worker';
  end if;

  -- A new worker registers but is not active.
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000003","email":"worker@example.test"}',true);
  v_result := public.mp_register_delivery_worker('New Worker','0911000003','Test Area');
  if v_result->>'status' <> 'pending_approval' then
    raise exception 'New worker was not left pending: %',v_result;
  end if;
  select id into v_worker_id from public.mp_users
  where auth_user_id='20000000-0000-0000-0000-000000000003';
  select id into v_profile_id from public.mp_delivery_profiles where user_id=v_worker_id;
  if (select active from public.mp_delivery_profiles where id=v_profile_id) then
    raise exception 'New worker profile became active without approval';
  end if;

  -- Re-registering must not silently reactivate a worker.
  perform public.mp_register_delivery_worker('New Worker Updated','0911000004','New Area');
  if (select active from public.mp_delivery_profiles where id=v_profile_id) then
    raise exception 'Re-registration reactivated a pending worker';
  end if;

  -- Only the administrator can approve.
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000002","email":"mohammedgena@gmail.com"}',true);
  v_result := public.mp_admin_set_delivery_worker_status(v_profile_id,true);
  if v_result->>'status' <> 'active' then
    raise exception 'Admin could not approve worker: %',v_result;
  end if;

  -- Prepare one verified delivery order and one unpaid delivery order.
  insert into public.mp_orders(id,order_code,fulfillment_method,status,subtotal_etb,delivery_address,customer_phone)
  values
   ('30000000-0000-0000-0000-000000000001','TEST-PAID','delivery','paid',500,'Test Address','0911222333'),
   ('30000000-0000-0000-0000-000000000002','TEST-UNPAID','delivery','paid',250,'Other Address','0911444555');
  v_order_id := '30000000-0000-0000-0000-000000000001';
  v_unpaid_order_id := '30000000-0000-0000-0000-000000000002';
  insert into public.mp_payments(order_id,status) values(v_order_id,'verified');
  insert into public.mp_order_items(order_id,product_name,quantity) values(v_order_id,'Test Product',1);

  -- Worker can discover only the verified order.
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000003","email":"worker@example.test"}',true);
  v_jobs := public.mp_delivery_jobs();
  if jsonb_array_length(v_jobs) <> 1 or v_jobs->0->>'order_code' <> 'TEST-PAID' then
    raise exception 'Worker job list did not filter verified payment: %',v_jobs;
  end if;

  v_result := public.mp_claim_delivery_job(v_order_id);
  v_assignment_id := (v_result->>'assignment_id')::uuid;
  if v_assignment_id is null then
    raise exception 'Worker could not claim verified delivery order';
  end if;

  v_result := public.mp_update_delivery_job(v_assignment_id,'picked_up');
  if v_result->>'status' <> 'picked_up' then
    raise exception 'Pickup transition failed: %',v_result;
  end if;
  if (select status from public.mp_orders where id=v_order_id) <> 'out_for_delivery' then
    raise exception 'Pickup did not update order state';
  end if;

  v_result := public.mp_update_delivery_job(v_assignment_id,'delivered');
  if v_result->>'status' <> 'delivered' then
    raise exception 'Delivery completion failed: %',v_result;
  end if;
  if (select status from public.mp_orders where id=v_order_id) <> 'completed' then
    raise exception 'Delivery completion did not update order state';
  end if;

  -- An order without a verified receipt must never be claimable.
  v_failed := false;
  begin
    perform public.mp_claim_delivery_job(v_unpaid_order_id);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Worker claimed an order without a verified receipt';
  end if;

  -- A non-admin cannot approve/deactivate delivery workers.
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000003","email":"worker@example.test"}',true);
  v_failed := false;
  begin
    perform public.mp_admin_set_delivery_worker_status(v_profile_id,false);
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Non-admin user was able to change worker approval';
  end if;

  -- Deactivated workers cannot view available jobs.
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000002","email":"mohammedgena@gmail.com"}',true);
  perform public.mp_admin_set_delivery_worker_status(v_profile_id,false);
  perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',true);
  perform set_config('request.jwt.claims','{"sub":"20000000-0000-0000-0000-000000000003","email":"worker@example.test"}',true);
  v_failed := false;
  begin
    perform public.mp_delivery_jobs();
  exception when sqlstate '42501' then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Deactivated worker could still view available jobs';
  end if;
end;
$test$;

select 'delivery worker approval smoke test: PASS' as result;
