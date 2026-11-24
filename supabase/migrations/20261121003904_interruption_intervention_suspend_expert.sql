-- Interruption d'intervention : l'expert qui quitte sans faire son rapport est suspendu
-- jusqu'à régularisation par un gestionnaire (lift_expert_suspension).
-- La suspension retire la carte (vue available_mandates_for_expert) et prévient les gestionnaires
-- de toutes les organisations liées (trigger notify_expert_suspended).
create or replace function public.expert_quit_intervention(p_mandate_id uuid, p_motif text, p_details text DEFAULT NULL::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_motif text := trim(coalesce(p_motif, '')); v_full text; v_m public.mandates%rowtype; v_expert_name text;
        v_expert uuid := public.current_expert_id();
begin
  if v_motif not in ('Urgence médicale', 'Altercation client', 'Risque de blessure grave', 'Insalubrité') then
    raise exception 'Choisissez un motif d''interruption';
  end if;
  v_full := v_motif || coalesce(' — ' || nullif(trim(coalesce(p_details, '')), ''), '');
  perform public.expert_abandon_mandate(p_mandate_id, v_full);
  select * into v_m from public.mandates where id = p_mandate_id;
  select trim(concat_ws(' ', first_name, last_name)) into v_expert_name from public.experts where id = v_expert;
  insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
  select up.id, p_mandate_id, 'status_change', 'Anomalie : intervention interrompue',
         'Mandat ' || coalesce(v_m.reference, '') || ' interrompu par ' || coalesce(v_expert_name, 'l''expert') || ' : ' || v_full,
         'in_app', false, now(), 'mandate', p_mandate_id, 'mandate_details'
    from public.user_profiles up
   where up.organization_id = v_m.insurance_org_id and up.role = 'gestionnaire_assurance';
  -- Rapport non réalisé : suspension jusqu'à régularisation (le mandat est déjà remis en drop)
  perform public.expert_suspend_internal(
    v_expert,
    'Intervention interrompue sans rapport (mandat ' || coalesce(v_m.reference, '') || ' : ' || v_full || ')',
    null, null);
end $function$;
revoke execute on function public.expert_quit_intervention(uuid, text, text) from public, anon;
grant execute on function public.expert_quit_intervention(uuid, text, text) to authenticated;
