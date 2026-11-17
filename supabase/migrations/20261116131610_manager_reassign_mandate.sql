-- Réattribution depuis la fiche mandat : libère l'expert actuel puis attribue au nouvel expert, motif obligatoire.
create or replace function public.manager_reassign_mandate(p_mandate_id uuid, p_expert_id uuid, p_motif text default null)
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
  if p_expert_id is null then
    return jsonb_build_object('ok', false, 'error', 'Choisissez un expert dans la liste.');
  end if;
  if not exists (select 1 from public.experts e
                 join public.org_experts oe on oe.expert_id = e.id and oe.organization_id = v_org
                 where e.id = p_expert_id and coalesce(e.status_experts::text, 'new') <> 'suspendu') then
    return jsonb_build_object('ok', false, 'error', 'Expert absent de votre base ou suspendu.');
  end if;
  if v_m.assigned_expert_id = p_expert_id and v_m.status = 'assigned' then
    return jsonb_build_object('ok', false, 'error', 'Ce mandat est déjà attribué à cet expert.');
  end if;
  if v_motif is null then
    return jsonb_build_object('ok', false, 'error', 'Saisissez le motif de la réattribution.');
  end if;

  begin
    if v_m.status not in ('drop_pending', 'dropped', 'redrop') then
      perform public.transition_mandate_status(p_mandate_id, 'drop_pending', null, 'Réattribution : ' || v_motif, null, null);
    end if;
    perform public.transition_mandate_status(p_mandate_id, 'assigned', p_expert_id, 'Réattribution : ' || v_motif, 'manual', null);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.manager_reassign_mandate(uuid, uuid, text) from public, anon;
grant execute on function public.manager_reassign_mandate(uuid, uuid, text) to authenticated;
