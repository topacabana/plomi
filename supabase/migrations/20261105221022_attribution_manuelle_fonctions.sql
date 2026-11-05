-- PLOMI — Attribution manuelle (CC mandataire B), validé le 05/11/2026
-- 1. manual_assignment_data : mandats attribuables + experts (listes, zone, agréments, notes, fréquence d'attribution)
-- 2. manual_assign_mandates : attribue un lot { mandate_id, expert_id } via transition_mandate_status ; refus renvoyés un par un

create or replace function public.manual_assignment_data(p_mandate_ids uuid[] default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
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
                from public.experts e left join public.user_profiles up on up.id = e.user_id
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
      if not exists (select 1 from public.experts where id = v_e and coalesce(status_experts::text,'new') <> 'suspendu') then
        raise exception 'Expert introuvable ou suspendu';
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

revoke execute on function public.manual_assignment_data(uuid[]) from public, anon;
revoke execute on function public.manual_assign_mandates(jsonb) from public, anon;
grant execute on function public.manual_assignment_data(uuid[]) to authenticated, service_role;
grant execute on function public.manual_assign_mandates(jsonb) to authenticated, service_role;
