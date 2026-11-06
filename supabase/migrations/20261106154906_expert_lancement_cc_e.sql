-- CC expert E (validé le 06/11/2026) : page de lancement
alter table public.mandates add column if not exists arrived_at timestamptz;

-- Données de la page + heure d'arrivée réelle (première ouverture de la page)
create or replace function public.expert_launch_data(p_mandate_id uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_expert uuid := public.current_expert_id(); v_m public.mandates%rowtype; v jsonb;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into v_m from public.mandates where id = p_mandate_id;
  if not found then raise exception 'Mandat introuvable'; end if;
  if v_m.assigned_expert_id is distinct from v_expert then raise exception 'Ce mandat ne vous est pas attribué'; end if;
  if v_m.arrived_at is null and v_m.status in ('assigned', 'in_progress') then
    update public.mandates set arrived_at = now() where id = p_mandate_id;
    insert into public.expert_performance_logs (expert_id, event_type, mandate_id, metadata)
    values (v_expert, 'arrived_on_site', p_mandate_id,
            jsonb_build_object('planned_at', coalesce(v_m.selected_slot_at, v_m.slot_1_at)));
  end if;
  select jsonb_build_object(
    'id', m.id, 'reference', m.reference, 'mandate_type', m.mandate_type, 'status', m.status,
    'organization', o.name, 'logo_url', o.logo_url,
    'beneficiary_first_name', b.first_name, 'beneficiary_last_name', b.last_name,
    'address', concat_ws(' ', m.address_line_1, m.postal_code, m.city),
    'phone_1', b.mobile_phone, 'phone_2', b.landline_phone, 'email', b.email,
    'description', coalesce(nullif(m.symptoms, ''), nullif(m.comments, ''), m.description),
    'floor', m.floor, 'entry_code', m.entry_code,
    'planned_at', coalesce(m.selected_slot_at, m.slot_1_at),
    'arrived_at', m.arrived_at, 'started_at', m.started_at)
    into v
    from public.mandates m
    left join public.beneficiaries b on b.id = m.beneficiary_id
    left join public.organizations o on o.id = m.insurance_org_id
   where m.id = p_mandate_id;
  return v;
end $$;

-- Quitter l'intervention : abandon (motif + détails) + rapport d'anomalie aux gestionnaires de l'org
create or replace function public.expert_quit_intervention(p_mandate_id uuid, p_motif text, p_details text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_motif text := trim(coalesce(p_motif, '')); v_full text; v_m public.mandates%rowtype; v_expert_name text;
begin
  if v_motif not in ('Urgence médicale', 'Altercation client', 'Risque de blessure grave', 'Insalubrité') then
    raise exception 'Choisissez un motif d''interruption';
  end if;
  v_full := v_motif || coalesce(' — ' || nullif(trim(coalesce(p_details, '')), ''), '');
  perform public.expert_abandon_mandate(p_mandate_id, v_full);
  select * into v_m from public.mandates where id = p_mandate_id;
  select trim(concat_ws(' ', first_name, last_name)) into v_expert_name from public.experts where id = public.current_expert_id();
  insert into public.notifications (user_id, mandate_id, type, title, body, channel, is_read, sent_at, entity_type, entity_id, target_type)
  select up.id, p_mandate_id, 'status_change', 'Anomalie : intervention interrompue',
         'Mandat ' || coalesce(v_m.reference, '') || ' interrompu par ' || coalesce(v_expert_name, 'l''expert') || ' : ' || v_full,
         'in_app', false, now(), 'mandate', p_mandate_id, 'mandate_details'
    from public.user_profiles up
   where up.organization_id = v_m.insurance_org_id and up.role = 'gestionnaire_assurance';
end $$;

do $$ declare f text; begin
  foreach f in array array['expert_launch_data(uuid)', 'expert_quit_intervention(uuid,text,text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
