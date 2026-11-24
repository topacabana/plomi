-- Interruption d'intervention : motif « Autre », obligatoirement précisé dans le champ Détails.
create or replace function public.expert_quit_intervention(p_mandate_id uuid, p_motif text, p_details text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_motif text := trim(coalesce(p_motif, '')); v_details text := nullif(trim(coalesce(p_details, '')), '');
        v_full text; v_m public.mandates%rowtype; v_expert_name text;
begin
  if v_motif not in ('Urgence médicale', 'Altercation client', 'Risque de blessure grave', 'Insalubrité', 'Autre') then
    raise exception 'Choisissez un motif d''interruption';
  end if;
  if v_motif = 'Autre' and length(coalesce(v_details, '')) < 10 then
    raise exception 'Motif « Autre » : expliquez la raison dans le champ Détails (10 caractères minimum)';
  end if;
  v_full := v_motif || coalesce(' — ' || v_details, '');
  select trim(concat_ws(' ', first_name, last_name)) into v_expert_name from public.experts where id = public.current_expert_id();
  perform public.expert_abandon_internal(p_mandate_id, v_full, 'Intervention interrompue sans rapport');
  select * into v_m from public.mandates where id = p_mandate_id;
  insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
  select up.id, p_mandate_id, 'status_change', 'Anomalie : intervention interrompue',
         'Mandat ' || coalesce(v_m.reference, '') || ' interrompu par ' || coalesce(v_expert_name, 'l''expert') || ' : ' || v_full,
         'in_app', false, now(), 'mandate', p_mandate_id, 'mandate_details'
    from public.user_profiles up
   where up.organization_id = v_m.insurance_org_id and up.role = 'gestionnaire_assurance';
end $function$;
