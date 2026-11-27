-- MILKISHOP: delivery workers must be explicitly approved by an administrator.
-- Apply only in a disposable/non-production Supabase project first.
-- Existing active workers are deactivated by this migration and must be reviewed
-- and re-approved by the administrator before receiving customer delivery jobs.

update public.mp_delivery_profiles
set active = false,
    updated_at = now()
where active = true;

create or replace function public.mp_register_delivery_worker(
  p_full_name text,
  p_phone text,
  p_service_area text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_auth_id uuid := auth.uid();
  v_user_id uuid;
  v_profile public.mp_delivery_profiles%rowtype;
begin
  if v_auth_id is null then
    raise exception 'Please sign in first' using errcode = '42501';
  end if;

  if length(trim(coalesce(p_full_name,''))) not between 2 and 120 then
    raise exception 'Enter your full name' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_phone,''))) not between 7 and 30 then
    raise exception 'Enter a valid phone number' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_service_area,''))) not between 2 and 160 then
    raise exception 'Enter your delivery service area' using errcode = '22023';
  end if;

  insert into public.mp_users(auth_user_id,full_name,phone,preferred_language,role)
  values(v_auth_id,trim(p_full_name),trim(p_phone),'en','customer')
  on conflict(auth_user_id) where auth_user_id is not null
  do update set full_name = excluded.full_name,
                phone = excluded.phone,
                updated_at = now()
  returning id into v_user_id;

  insert into public.mp_delivery_profiles(
    user_id,full_name,phone,service_area,active
  )
  values(
    v_user_id,trim(p_full_name),trim(p_phone),trim(p_service_area),false
  )
  on conflict(user_id) do update
    set full_name = excluded.full_name,
        phone = excluded.phone,
        service_area = excluded.service_area,
        updated_at = now()
  returning * into v_profile;

  return jsonb_build_object(
    'success',true,
    'delivery_profile_id',v_profile.id,
    'status',case when v_profile.active then 'active' else 'pending_approval' end
  );
end;
$function$;

create or replace function public.mp_admin_set_delivery_worker_status(
  p_delivery_profile_id uuid,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid;
  v_profile public.mp_delivery_profiles%rowtype;
begin
  if auth.uid() is null
     or lower(coalesce(auth.jwt() ->> 'email','')) <> 'mohammedgena@gmail.com' then
    raise exception 'Not authorized to approve delivery workers' using errcode = '42501';
  end if;

  select id into v_admin_id
  from public.mp_users
  where auth_user_id = auth.uid()
  limit 1;

  if v_admin_id is null then
    raise exception 'Admin profile not found' using errcode = 'P0002';
  end if;

  if p_active is null then
    raise exception 'Choose whether to approve or deactivate this worker' using errcode = '22023';
  end if;

  update public.mp_delivery_profiles
  set active = p_active,
      updated_at = now()
  where id = p_delivery_profile_id
  returning * into v_profile;

  if not found then
    raise exception 'Delivery worker application not found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'success',true,
    'delivery_profile_id',v_profile.id,
    'status',case when v_profile.active then 'active' else 'pending_approval' end
  );
end;
$function$;

revoke all on function public.mp_register_delivery_worker(text,text,text) from public, anon;
grant execute on function public.mp_register_delivery_worker(text,text,text) to authenticated;

revoke all on function public.mp_admin_set_delivery_worker_status(uuid,boolean) from public, anon;
grant execute on function public.mp_admin_set_delivery_worker_status(uuid,boolean) to authenticated;

-- Keep worker job discovery and claiming behind a verified customer receipt.
create or replace function public.mp_delivery_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_jobs jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select u.id into v_user_id
  from public.mp_users u
  join public.mp_delivery_profiles d on d.user_id = u.id
  where u.auth_user_id = auth.uid()
    and d.active = true
  limit 1;

  if v_user_id is null then
    raise exception 'Your delivery-worker account is awaiting administrator approval' using errcode = '42501';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'order_id',o.id,
        'order_code',o.order_code,
        'subtotal_etb',o.subtotal_etb,
        'created_at',o.created_at,
        'item_count',coalesce(x.item_count,0),
        'items',coalesce(x.items,'[]'::jsonb),
        'job_status','available'
      ) order by o.created_at
    ),
    '[]'::jsonb
  )
  into v_jobs
  from public.mp_orders o
  left join lateral (
    select count(*) item_count,
           jsonb_agg(jsonb_build_object('product_name',i.product_name,'quantity',i.quantity)) items
    from public.mp_order_items i
    where i.order_id = o.id
  ) x on true
  where o.fulfillment_method = 'delivery'
    and o.status in ('paid','processing')
    and exists (
      select 1 from public.mp_payments p
      where p.order_id = o.id and p.status = 'verified'
    )
    and not exists (
      select 1 from public.mp_delivery_assignments a
      where a.order_id = o.id
        and a.status in ('assigned','picked_up','delivered')
    );

  return v_jobs;
end;
$function$;

create or replace function public.mp_claim_delivery_job(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
  v_worker public.mp_delivery_profiles%rowtype;
  v_order public.mp_orders%rowtype;
  v_assignment public.mp_delivery_assignments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select u.id into v_user_id
  from public.mp_users u
  join public.mp_delivery_profiles d on d.user_id = u.id
  where u.auth_user_id = auth.uid()
    and d.active = true
  limit 1;

  if v_user_id is null then
    raise exception 'Your delivery-worker account is awaiting administrator approval' using errcode = '42501';
  end if;

  select * into v_worker
  from public.mp_delivery_profiles
  where user_id = v_user_id and active = true;

  if not found then
    raise exception 'Active delivery-worker profile not found' using errcode = '42501';
  end if;

  -- Lock the order first so two workers cannot claim the same order concurrently.
  select * into v_order
  from public.mp_orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Delivery job not found' using errcode = 'P0002';
  end if;

  if v_order.fulfillment_method <> 'delivery' then
    raise exception 'This order is pickup only' using errcode = '55000';
  end if;

  if v_order.status not in ('paid','processing','ready_for_pickup') then
    raise exception 'Order is not ready for delivery' using errcode = '55000';
  end if;

  if not exists (
    select 1 from public.mp_payments p
    where p.order_id = p_order_id and p.status = 'verified'
  ) then
    raise exception 'A verified customer payment receipt is required' using errcode = '55000';
  end if;

  insert into public.mp_delivery_assignments(
    order_id,delivery_user_id,provider_name,provider_phone,fee_etb,status
  )
  values(
    p_order_id,v_user_id,v_worker.full_name,v_worker.phone,0,'assigned'
  )
  on conflict(order_id) do update
    set delivery_user_id = excluded.delivery_user_id,
        provider_name = excluded.provider_name,
        provider_phone = excluded.provider_phone,
        status = 'assigned',
        updated_at = now()
    where public.mp_delivery_assignments.status = 'cancelled'
  returning * into v_assignment;

  if v_assignment.id is null then
    raise exception 'This delivery job has already been taken' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'success',true,
    'assignment_id',v_assignment.id,
    'order_code',v_order.order_code,
    'delivery_address',v_order.delivery_address,
    'customer_phone',v_order.customer_phone,
    'status','assigned'
  );
end;
$function$;

revoke all on function public.mp_delivery_jobs() from public, anon;
grant execute on function public.mp_delivery_jobs() to authenticated;
revoke all on function public.mp_claim_delivery_job(uuid) from public, anon;
grant execute on function public.mp_claim_delivery_job(uuid) to authenticated;
