-- Redrop depuis la fiche mandat (popup « MotifModal ») : remplace la mise à jour
-- directe de la table par une fonction contrôlée (gestionnaire, organisation,
-- motif obligatoire, transitions autorisées, journal via transition_mandate_status).

create or replace function public.manager_redrop_mandate(p_mandate_id uuid, p_motif text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_m public.mandates%rowtype;
  v_motif text := nullif(btrim(coalesce(p_motif, '')), '');
begin
  if not public.is_manager() then
    return jsonb_build_object('ok', false, 'error', 'Réservé aux gestionnaires.');
  end if;
  select * into v_m from public.mandates where id = p_mandate_id and insurance_org_id = v_org for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Mandat introuvable dans votre organisation.');
  end if;
  if v_motif is null then
    return jsonb_build_object('ok', false, 'error', 'Saisissez la justification du redrop.');
  end if;
  if v_m.status = 'redrop' then
    return jsonb_build_object('ok', false, 'error', 'Ce mandat est déjà en redrop.');
  end if;

  begin
    perform public.transition_mandate_status(p_mandate_id, 'redrop', null, 'Redrop : ' || v_motif, null, null);
    update public.mandates
       set redrop_count = coalesce(redrop_count, 0) + 1,
           workflow_stage = 'pending'
     where id = p_mandate_id;
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.manager_redrop_mandate(uuid, text) from public, anon;
grant execute on function public.manager_redrop_mandate(uuid, text) to authenticated;
