create table if not exists public.org_experts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  expert_id uuid not null references public.experts(id) on delete cascade,
  source text not null default 'recrutement' check (source in ('initial','recrutement','creation')),
  added_by uuid references auth.users(id) on delete set null,
  added_at timestamptz not null default now(),
  unique (organization_id, expert_id));
create index if not exists org_experts_expert_idx on public.org_experts(expert_id);
alter table public.org_experts enable row level security;
drop policy if exists "gestionnaire : base de son org" on public.org_experts;
create policy "gestionnaire : base de son org" on public.org_experts for select to authenticated
  using (public.is_manager() and organization_id = public.current_user_organization_id());

insert into public.org_experts (organization_id, expert_id, source, added_at)
select distinct x.org, x.eid, 'initial', now() from (
  select l.organization_id org, m.expert_id eid from public.expert_list_members m
    join public.expert_lists l on l.id = m.list_id where l.auto_rule is null
  union select insurance_org_id, assigned_expert_id from public.mandates where assigned_expert_id is not null
  union select m.insurance_org_id, a.expert_id from public.mandate_assignments a join public.mandates m on m.id = a.mandate_id) x
 where x.org is not null and x.eid is not null
on conflict do nothing;

create or replace function public.in_my_base(p_expert_id uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $$ select exists (select 1 from public.org_experts where expert_id = p_expert_id
                        and organization_id = public.current_user_organization_id()) $$;
revoke execute on function public.in_my_base(uuid) from public, anon;
grant execute on function public.in_my_base(uuid) to authenticated;

drop policy if exists "insurance read experts" on public.experts;
create policy "insurance read experts" on public.experts for select to authenticated
  using (public.is_manager() and public.in_my_base(id));
drop policy if exists "gestionnaire : KPI des experts" on public.expert_kpis;
create policy "gestionnaire : KPI des experts" on public.expert_kpis for select to authenticated
  using (public.is_manager() and public.in_my_base(expert_id));

create or replace view public.experts_with_profiles as
 SELECT e.id, e.user_id, e.organization_id, e.company_name, e.trade_name, e.siret, e.specialty, e.coverage_zone,
    e.rating, e.phone, e.email, e.address_line_1, e.address_line_2, e.postal_code, e.city, e.country,
    e.latitude, e.longitude, e.created_at, e.updated_at, e.photo_url, e.status_experts, e.first_name, e.last_name,
    (COALESCE(json_agg(json_build_object('id', ep.id, 'code', ep.code, 'label', ep.label, 'icon', ep.icon, 'color', ep.color)
       ORDER BY ep.sort_order) FILTER (WHERE ep.id IS NOT NULL), '[]'::json))::jsonb AS profiles,
    count(ep.id) AS profile_count,
    up.last_seen_at,
    coalesce(up.last_seen_at > now() - interval '5 minutes', false) AS is_online,
    oe.added_at AS base_added_at,
    case when oe.id is null then null
         when exists (select 1 from mandate_assignments a join mandates m on m.id = a.mandate_id
                       where a.expert_id = e.id and m.insurance_org_id = oe.organization_id) then 'actif'
         else 'new' end AS base_status
   FROM experts e
     LEFT JOIN expert_profile_assignments epa ON e.id = epa.expert_id
     LEFT JOIN expert_profiles ep ON epa.profile_id = ep.id AND ep.is_active = true
     LEFT JOIN user_profiles up ON up.id = e.user_id
     LEFT JOIN org_experts oe ON oe.expert_id = e.id AND oe.organization_id = current_user_organization_id()
  WHERE auth.role() = 'service_role' OR (is_manager() AND oe.id IS NOT NULL) OR e.user_id = auth.uid()
  GROUP BY e.id, up.last_seen_at, oe.id, oe.added_at, oe.organization_id;

create or replace function public.manual_assignment_data(p_mandate_ids uuid[] default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select jsonb_build_object(
    'mandates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'reference', m.reference, 'mandate_type', m.mandate_type, 'status', m.status,
               'priority', m.priority, 'address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
               'postal_code', m.postal_code, 'symptom', coalesce(m.symptoms::text, m.description),
               'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
               'beneficiary_email', b.email, 'beneficiary_phone', coalesce(b.mobile_phone, b.landline_phone),
               'locked_by', (select public.lock_holder_name(l.user_id) from public.mandate_locks l
                              where l.mandate_id = m.id and l.user_id <> auth.uid() and l.expires_at > now()))
             order by m.created_at)
        from public.mandates m left join public.beneficiaries b on b.id = m.beneficiary_id
       where m.insurance_org_id = v_org
         and m.status in ('drop_pending','dropped','redrop','suspended')
         and (coalesce(cardinality(p_mandate_ids), 0) = 0 or m.id = any(p_mandate_ids))), '[]'::jsonb),
    'experts', coalesce((
      select jsonb_agg(x order by (x->>'assignments_count')::int desc, x->>'last_name')
        from (select jsonb_build_object(
               'id', e.id, 'company_name', e.company_name, 'siret', e.siret,
               'first_name', e.first_name, 'last_name', e.last_name, 'phone', e.phone, 'email', e.email,
               'address', concat_ws(' ', e.address_line_1, e.postal_code, e.city), 'postal_code', e.postal_code,
               'coverage_zone', e.coverage_zone, 'agreements', to_jsonb(e.agreements), 'rating', e.rating,
               'status', e.status_experts,
               'is_online', coalesce(up.last_seen_at > now() - interval '5 minutes', false),
               'list_ids', coalesce((select jsonb_agg(l.id) from public.expert_list_members lm
                                      join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org
                                     where lm.expert_id = e.id), '[]'::jsonb),
               'list_names', coalesce((select string_agg(l.name, ', ' order by l.name) from public.expert_list_members lm
                                      join public.expert_lists l on l.id = lm.list_id and l.organization_id = v_org
                                     where lm.expert_id = e.id), ''),
               'assignments_count', (select count(*) from public.mandate_assignments a
                                       join public.mandates m2 on m2.id = a.mandate_id and m2.insurance_org_id = v_org
                                      where a.expert_id = e.id)) x
                from public.experts e
                join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
                left join public.user_profiles up on up.id = e.user_id
               where coalesce(e.status_experts::text, 'new') <> 'suspendu') s), '[]'::jsonb)
  ) into v;
  return v;
end $$;

create or replace function public.manual_assign_mandates(p_assignments jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); r jsonb; v_ok int := 0; v_err jsonb := '[]'::jsonb;
        v_m uuid; v_e uuid;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if p_assignments is null or jsonb_typeof(p_assignments) <> 'array' or jsonb_array_length(p_assignments) = 0 then
    raise exception 'Aucune attribution à enregistrer';
  end if;
  for r in select * from jsonb_array_elements(p_assignments) loop
    v_m := (r->>'mandate_id')::uuid; v_e := (r->>'expert_id')::uuid;
    begin
      if not exists (select 1 from public.mandates where id = v_m and insurance_org_id = v_org) then
        raise exception 'Mandat introuvable dans votre organisation';
      end if;
      if not exists (select 1 from public.experts e join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
                      where e.id = v_e and coalesce(e.status_experts::text,'new') <> 'suspendu') then
        raise exception 'Expert absent de votre base ou suspendu';
      end if;
      perform public.transition_mandate_status(v_m, 'assigned', v_e, null, 'manual');
      v_ok := v_ok + 1;
    exception when others then
      v_err := v_err || jsonb_build_object('mandate_id', v_m,
                 'reference', (select reference from public.mandates where id = v_m), 'error', sqlerrm);
    end;
  end loop;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'manual_assignment',
          jsonb_build_object('requested', jsonb_array_length(p_assignments), 'assigned', v_ok, 'errors', v_err));
  return jsonb_build_object('assigned', v_ok, 'errors', v_err);
end $$;

create or replace function public.add_experts_to_lists(p_expert_ids uuid[], p_list_ids uuid[])
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer; v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if cardinality(coalesce(p_expert_ids,'{}')) = 0 then raise exception 'Cochez au moins un expert'; end if;
  if cardinality(coalesce(p_list_ids,'{}')) = 0 then raise exception 'Choisissez au moins une liste'; end if;
  if exists (select 1 from unnest(p_list_ids) x
              where not exists (select 1 from public.expert_lists l where l.id = x and l.organization_id = v_org)) then
    raise exception 'Liste introuvable dans votre organisation';
  end if;
  if exists (select 1 from public.expert_lists where id = any(p_list_ids) and auto_rule is not null) then
    raise exception 'Les listes automatiques (KPI, agréments) se remplissent seules et ne peuvent pas être modifiées à la main';
  end if;
  if exists (select 1 from unnest(p_expert_ids) x
              where not exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = v_org)) then
    raise exception 'Recrutez d''abord l''expert dans votre base';
  end if;
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select l.id, e.id, auth.uid()
    from public.expert_lists l cross join public.experts e
   where l.id = any(p_list_ids) and l.organization_id = v_org and e.id = any(p_expert_ids)
  on conflict (list_id, expert_id) do nothing;
  get diagnostics n = row_count;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', gen_random_uuid(), 'experts_added_to_lists',
          jsonb_build_object('expert_ids', p_expert_ids, 'list_ids', p_list_ids, 'added', n));
  return n;
end $$;

create or replace function public.save_expert_list(p_list_id uuid, p_name text, p_expert_ids uuid[], p_force boolean default false)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v_id uuid := p_list_id; v_name text := nullif(trim(coalesce(p_name,'')), '');
        v_ids uuid[]; v_warn jsonb := '[]'::jsonb; v_dup text; v_new boolean := p_list_id is null;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_name is null then raise exception 'Nommez votre liste'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_ids
    from unnest(coalesce(p_expert_ids, '{}')) x
   where exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = v_org);
  if cardinality(v_ids) = 0 then raise exception 'Ajoutez au moins un expert de votre base à la liste'; end if;
  if not v_new then
    if not exists (select 1 from public.expert_lists where id = v_id and organization_id = v_org) then
      raise exception 'Liste introuvable dans votre organisation';
    end if;
    if exists (select 1 from public.expert_lists where id = v_id and auto_rule is not null) then
      raise exception 'Les listes automatiques (KPI, agréments) se remplissent seules et ne peuvent pas être modifiées à la main';
    end if;
  end if;
  if not coalesce(p_force, false) then
    select string_agg(l.name, ', ') into v_dup from public.expert_lists l
     where l.organization_id = v_org and l.is_active and lower(trim(l.name)) = lower(v_name)
       and l.id is distinct from v_id;
    if v_dup is not null then v_warn := v_warn || to_jsonb('Une liste porte déjà ce nom : ' || v_dup); end if;
    select string_agg(l.name, ', ') into v_dup from public.expert_lists l
     where l.organization_id = v_org and l.is_active and l.id is distinct from v_id
       and (select coalesce(array_agg(m.expert_id order by m.expert_id), '{}') from public.expert_list_members m where m.list_id = l.id)
           = (select array_agg(x order by x) from unnest(v_ids) x);
    if v_dup is not null then v_warn := v_warn || to_jsonb('Mêmes membres que : ' || v_dup); end if;
    if jsonb_array_length(v_warn) > 0 then
      return jsonb_build_object('status', 'warning', 'warnings', v_warn);
    end if;
  end if;
  if v_new then
    insert into public.expert_lists (organization_id, name, is_active, created_by_user_id)
    values (v_org, v_name, true, auth.uid()) returning id into v_id;
  else
    update public.expert_lists set name = v_name, updated_at = now() where id = v_id;
  end if;
  delete from public.expert_list_members where list_id = v_id and expert_id <> all(v_ids);
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select v_id, x, auth.uid() from unnest(v_ids) x
  on conflict (list_id, expert_id) do nothing;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', v_id, case when v_new then 'expert_list_created' else 'expert_list_updated' end,
          jsonb_build_object('list_id', v_id, 'name', v_name, 'members', cardinality(v_ids), 'forced', coalesce(p_force,false)));
  return jsonb_build_object('status', 'saved', 'id', v_id, 'members', cardinality(v_ids));
end $$;

create or replace function public.refresh_auto_expert_lists()
 returns integer language plpgsql security definer set search_path to 'public'
as $$
declare l record; v_changes integer := 0; n integer;
begin
  for l in select id, auto_rule, organization_id from public.expert_lists where auto_rule is not null and is_active loop
    delete from public.expert_list_members m
     where m.list_id = l.id
       and (m.expert_id not in (select public.expert_list_rule_members(l.auto_rule))
            or not exists (select 1 from public.org_experts oe where oe.expert_id = m.expert_id and oe.organization_id = l.organization_id));
    get diagnostics n = row_count; v_changes := v_changes + n;
    insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
    select l.id, x, null from public.expert_list_rule_members(l.auto_rule) x
     where exists (select 1 from public.org_experts oe where oe.expert_id = x and oe.organization_id = l.organization_id)
    on conflict (list_id, expert_id) do nothing;
    get diagnostics n = row_count; v_changes := v_changes + n;
  end loop;
  return v_changes;
end $$;

create or replace function public.trg_org_experts_refresh()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$ begin perform public.refresh_auto_expert_lists(); return null; end $$;
revoke execute on function public.trg_org_experts_refresh() from public, anon, authenticated;
drop trigger if exists org_experts_refresh on public.org_experts;
create trigger org_experts_refresh after insert or delete on public.org_experts
  for each statement execute function public.trg_org_experts_refresh();

create or replace function public.create_expert_record(p_manager_id uuid, p_user_id uuid, p_data jsonb)
 returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare
  v_company text := nullif(trim(p_data->>'company_name'), '');
  v_org uuid; v_id uuid; v_agr text[]; v_mgr_org uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'Réservé au serveur'; end if;
  select organization_id into v_mgr_org from public.user_profiles where id = p_manager_id and role = 'gestionnaire_assurance';
  if v_mgr_org is null then raise exception 'Réservé aux gestionnaires'; end if;
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
  insert into public.org_experts (organization_id, expert_id, source, added_by)
  values (v_mgr_org, v_id, 'creation', p_manager_id) on conflict do nothing;
  return v_id;
end $$;
revoke execute on function public.create_expert_record(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.create_expert_record(uuid, uuid, jsonb) to service_role;

select public.refresh_auto_expert_lists();
