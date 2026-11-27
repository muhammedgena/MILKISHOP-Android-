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
