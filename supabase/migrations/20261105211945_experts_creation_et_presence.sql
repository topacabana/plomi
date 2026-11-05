create or replace function public.create_expert_record(p_manager_id uuid, p_user_id uuid, p_data jsonb)
 returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare
  v_company text := nullif(trim(p_data->>'company_name'), '');
  v_org uuid;
  v_id uuid;
  v_agr text[];
begin
  if auth.role() <> 'service_role' then raise exception 'Réservé au serveur'; end if;
  if not exists (select 1 from public.user_profiles where id = p_manager_id and role = 'gestionnaire_assurance') then
    raise exception 'Réservé aux gestionnaires';
  end if;
  if nullif(trim(p_data->>'first_name'), '') is null or nullif(trim(p_data->>'last_name'), '') is null then
    raise exception 'Le prénom et le nom sont obligatoires';
  end if;
  if v_company is null then raise exception 'La société est obligatoire'; end if;

  select coalesce(array_agg(lower(x)), '{}') into v_agr
    from jsonb_array_elements_text(coalesce(p_data->'agreements', '[]'::jsonb)) x;

  select id into v_org from public.organizations
   where type = 'expert_company' and lower(name) = lower(v_company) limit 1;
  if v_org is null then
    insert into public.organizations (name, type, siret)
    values (v_company, 'expert_company', nullif(trim(p_data->>'siret'), ''))
    returning id into v_org;
  end if;

  update public.user_profiles
     set role = 'expert', organization_id = v_org,
         first_name = trim(p_data->>'first_name'), last_name = trim(p_data->>'last_name'),
         phone = nullif(trim(p_data->>'phone'), '')
   where id = p_user_id;

  insert into public.experts (user_id, organization_id, company_name, trade_name, siret, specialty, coverage_zone,
                              phone, email, address_line_1, address_line_2, postal_code, city,
                              first_name, last_name, agreements, status_experts)
  values (p_user_id, v_org, v_company, nullif(trim(p_data->>'trade_name'), ''), nullif(trim(p_data->>'siret'), ''),
          nullif(trim(p_data->>'specialty'), ''), nullif(trim(p_data->>'coverage_zone'), ''),
          nullif(trim(p_data->>'phone'), ''), lower(trim(p_data->>'email')),
          nullif(trim(p_data->>'address_line_1'), ''), nullif(trim(p_data->>'address_line_2'), ''),
          nullif(trim(p_data->>'postal_code'), ''), nullif(trim(p_data->>'city'), ''),
          trim(p_data->>'first_name'), trim(p_data->>'last_name'), v_agr, 'new')
  returning id into v_id;

  insert into public.expert_kpis (expert_id, user_id)
  select v_id, p_user_id where not exists (select 1 from public.expert_kpis where expert_id = v_id);
  return v_id;
end $$;
revoke execute on function public.create_expert_record(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_expert_record(uuid, uuid, jsonb) to service_role;

alter table public.user_profiles add column if not exists last_seen_at timestamptz;

create or replace function public.touch_presence()
 returns void language sql security definer set search_path to 'public'
as $$
  update public.user_profiles set last_seen_at = now(), presence_status = 'online' where id = auth.uid();
$$;
grant execute on function public.touch_presence() to authenticated;

create or replace view public.experts_with_profiles as
 SELECT e.id, e.user_id, e.organization_id, e.company_name, e.trade_name, e.siret, e.specialty, e.coverage_zone,
    e.rating, e.phone, e.email, e.address_line_1, e.address_line_2, e.postal_code, e.city, e.country,
    e.latitude, e.longitude, e.created_at, e.updated_at, e.photo_url, e.status_experts, e.first_name, e.last_name,
    (COALESCE(json_agg(json_build_object('id', ep.id, 'code', ep.code, 'label', ep.label, 'icon', ep.icon, 'color', ep.color)
       ORDER BY ep.sort_order) FILTER (WHERE ep.id IS NOT NULL), '[]'::json))::jsonb AS profiles,
    count(ep.id) AS profile_count,
    up.last_seen_at,
    coalesce(up.last_seen_at > now() - interval '5 minutes', false) AS is_online
   FROM experts e
     LEFT JOIN expert_profile_assignments epa ON e.id = epa.expert_id
     LEFT JOIN expert_profiles ep ON epa.profile_id = ep.id AND ep.is_active = true
     LEFT JOIN user_profiles up ON up.id = e.user_id
  WHERE auth.role() = 'service_role' OR is_manager() OR e.user_id = auth.uid()
  GROUP BY e.id, up.last_seen_at;
