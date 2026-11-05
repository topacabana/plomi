-- PLOMI — Création / modification des listes d'experts (CC mandataire H), validé le 05/11/2026

create or replace function public.expert_lists_page_data()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return jsonb_build_object(
    'lists', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'name', l.name, 'description', l.description, 'color', l.color,
               'auto_rule', l.auto_rule, 'is_auto', l.auto_rule is not null,
               'member_ids', coalesce((select jsonb_agg(m.expert_id) from public.expert_list_members m where m.list_id = l.id), '[]'::jsonb),
               'member_count', (select count(*) from public.expert_list_members m where m.list_id = l.id))
             order by l.auto_rule is not null, l.name)
        from public.expert_lists l where l.organization_id = v_org and l.is_active), '[]'::jsonb),
    'experts', public.manual_assignment_data(array['00000000-0000-0000-0000-000000000000']::uuid[])->'experts');
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
    from unnest(coalesce(p_expert_ids, '{}')) x where exists (select 1 from public.experts e where e.id = x);
  if cardinality(v_ids) = 0 then raise exception 'Ajoutez au moins un expert à la liste'; end if;

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

create or replace function public.duplicate_expert_list(p_list_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v_src public.expert_lists%rowtype; v_name text; n int := 1; v_id uuid;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select * into v_src from public.expert_lists where id = p_list_id and organization_id = v_org;
  if not found then raise exception 'Liste introuvable dans votre organisation'; end if;
  loop
    v_name := v_src.name || ' ' || n;
    exit when not exists (select 1 from public.expert_lists where organization_id = v_org and lower(name) = lower(v_name));
    n := n + 1;
  end loop;
  insert into public.expert_lists (organization_id, name, description, color, is_active, created_by_user_id)
  values (v_org, v_name, v_src.description, v_src.color, true, auth.uid()) returning id into v_id;
  insert into public.expert_list_members (list_id, expert_id, added_by_user_id)
  select v_id, m.expert_id, auth.uid() from public.expert_list_members m where m.list_id = p_list_id;
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), 'broadcast', v_id, 'expert_list_duplicated', jsonb_build_object('source', p_list_id, 'list_id', v_id, 'name', v_name));
  return jsonb_build_object('id', v_id, 'name', v_name);
end $$;

revoke execute on function public.expert_lists_page_data() from public, anon;
revoke execute on function public.save_expert_list(uuid, text, uuid[], boolean) from public, anon;
revoke execute on function public.duplicate_expert_list(uuid) from public, anon;
grant execute on function public.expert_lists_page_data() to authenticated, service_role;
grant execute on function public.save_expert_list(uuid, text, uuid[], boolean) to authenticated, service_role;
grant execute on function public.duplicate_expert_list(uuid) to authenticated, service_role;
