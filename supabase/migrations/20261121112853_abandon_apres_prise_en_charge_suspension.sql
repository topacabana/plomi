-- Abandon après prise en charge = pénalisé comme une interruption d'intervention.
-- Dès que l'expert a pris le mandat (créneau choisi, statut assigned), le mandat disparaît de la carte :
-- ne pas honorer le rendez-vous immobilise le dossier et ajoute du post-traitement gestionnaire.
-- => suspension jusqu'à régularisation, rattachement à l'organisation du mandat (notification + levée possibles).
create or replace function public.expert_abandon_internal(p_mandate_id uuid, p_motif text, p_reason text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if nullif(trim(coalesce(p_motif,'')), '') is null then raise exception 'Le motif d''abandon est obligatoire'; end if;
  select * into v_m from public.mandates where id = p_mandate_id for update;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.status not in ('assigned','in_progress') then
    raise exception 'Ce mandat ne peut plus être abandonné (statut actuel : %)', v_m.status;
  end if;
  update public.mandate_assignments set status = 'refused', refused_at = now(), comment = trim(p_motif)
   where mandate_id = p_mandate_id and expert_id = v_expert and status in ('pending','accepted');
  perform public.transition_mandate_status(p_mandate_id, 'drop_pending', null, 'Abandon expert : ' || trim(p_motif));
  insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
  values (v_expert, 'mandate_refused', p_mandate_id, jsonb_build_object('motif', trim(p_motif), 'from_status', v_m.status)),
         (v_expert, 'redrop_caused', p_mandate_id, jsonb_build_object('reason', 'abandon'));
  -- L'expert a travaillé pour cette organisation : il entre dans sa base (notification + levée de suspension possibles)
  insert into public.org_experts (organization_id, expert_id, source)
  values (v_m.insurance_org_id, v_expert, 'intervention')
  on conflict (organization_id, expert_id) do nothing;
  perform public.expert_suspend_internal(
    v_expert, p_reason || ' (mandat ' || coalesce(v_m.reference, '') || ' : ' || trim(p_motif) || ')', null, null);
end $function$;
revoke execute on function public.expert_abandon_internal(uuid, text, text) from public, anon, authenticated;

create or replace function public.expert_abandon_mandate(p_mandate_id uuid, p_motif text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.expert_abandon_internal(p_mandate_id, p_motif, 'Mandat abandonné après prise en charge');
end $function$;
revoke execute on function public.expert_abandon_mandate(uuid, text) from public, anon;
grant execute on function public.expert_abandon_mandate(uuid, text) to authenticated;

create or replace function public.expert_quit_intervention(p_mandate_id uuid, p_motif text, p_details text DEFAULT NULL::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_motif text := trim(coalesce(p_motif, '')); v_full text; v_m public.mandates%rowtype; v_expert_name text;
begin
  if v_motif not in ('Urgence médicale', 'Altercation client', 'Risque de blessure grave', 'Insalubrité') then
    raise exception 'Choisissez un motif d''interruption';
  end if;
  v_full := v_motif || coalesce(' — ' || nullif(trim(coalesce(p_details, '')), ''), '');
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
revoke execute on function public.expert_quit_intervention(uuid, text, text) from public, anon;
grant execute on function public.expert_quit_intervention(uuid, text, text) to authenticated;
